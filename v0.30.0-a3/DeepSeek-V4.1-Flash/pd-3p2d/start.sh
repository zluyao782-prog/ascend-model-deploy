#!/bin/bash
# =============================================================================
# DeepSeek-V4.1-Flash 3P2D 启动（3 台 Prefill + 2 台 Decode）
#
# 每台按自己的角色执行一条，顺序不能颠倒：
#   bash start.sh master     # Mooncake master，一台就够（一般 P1）
#   bash start.sh decode     # 两台 Decode 节点
#   bash start.sh prefill    # 三台 Prefill
#   bash start.sh proxy      # 最后起代理，会先确认后端全绿
#
# 停止： bash stop.sh     看日志： docker logs -f dsv41-3p2d-decode
# 只改 config.env，本文件不用动。
# =============================================================================
set -e
cd "$(dirname "$0")"
. ./config.env

ROLE="${1:-}"
case "$ROLE" in
    master | prefill | decode | proxy) ;;
    *)
        echo "用法： bash start.sh master | prefill | decode | proxy"
        exit 1
        ;;
esac

CTR="$CONTAINER_NAME-$ROLE"
LAUNCHER="$IMAGE_DIR/launch_online_dp.py"
PROXY="$IMAGE_DIR/load_balance_proxy_server_example.py"

# =============================================================================
# 动手前确认：镜像在不在、官方脚本在不在，缺了当场退出
# =============================================================================
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "本机没有镜像：$IMAGE"
    echo "先导入： docker load -i vllm-ascend-v0.30.0-a3-openeuler.tar"
    echo "本机已有的（tag 不一样就改 config.env 的 IMAGE）："
    docker images --format '    {{.Repository}}:{{.Tag}}' 2>/dev/null | grep vllm-ascend \
        || echo "    （没有 vllm-ascend 镜像）"
    exit 1
}

case "$ROLE" in
    proxy)  WANT="$PROXY" ;;
    master) WANT="" ;;
    *)      WANT="$LAUNCHER" ;;
esac
if [ -n "$WANT" ]; then
    docker run --rm "$IMAGE" bash -c "test -f '$WANT'" 2>/dev/null || {
        echo "镜像里没有 $WANT"
        echo "找实际路径： docker run --rm $IMAGE find / -name $(basename "$WANT")"
        echo "查到后填 config.env 的 IMAGE_DIR"
        exit 1
    }
fi

# =============================================================================
# 挂载：驱动路径缺了就跳过，权重和脚本目录按原路径挂进去
# =============================================================================
MOUNTS=""
for p in /usr/local/Ascend/driver /usr/local/dcmi /usr/local/bin/npu-smi \
         /etc/ascend_install.info /etc/hccn.conf; do
    if [ -e "$p" ]; then
        MOUNTS="$MOUNTS -v $p:$p"
    fi
done
MOUNTS="$MOUNTS -v $MODEL_PATH:$MODEL_PATH -v $PWD:$PWD"

# =============================================================================
# Mooncake：按 config.env 生成 mooncake.json，再挂给每个引擎
# =============================================================================
mkdir -p "$PWD/.run"
sed -e "s|@MASTER@|$MOONCAKE_MASTER|" \
    -e "s|@SEGMENT@|$MOONCAKE_SEGMENT|" \
    -e "s|@BUFFER@|$MOONCAKE_BUFFER|" \
    "$PWD/mooncake.json" > "$PWD/.run/mooncake.json"
MC_ENV="-e MOONCAKE_CONFIG_PATH=$PWD/.run/mooncake.json"

# 本机 IP：业务网卡上的第一个 IPv4
MY_IP=$(ip -4 -o addr show "$NIC_NAME" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$MY_IP" ] || { echo "网卡 $NIC_NAME 没有 IPv4，检查 config.env 的 NIC_NAME"; exit 1; }

# =============================================================================
# 角色 0：Mooncake master（一台就够，一般放在 P1）
# 没起它，P/D 引擎连不上池子，报错指向对端地址，很难看出是 master 缺席
# =============================================================================
if [ "$ROLE" = "master" ]; then
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    echo "== Mooncake master =="
    echo "   监听 $MOONCAKE_MASTER，五台的引擎都连这个地址"
    docker run -d --name "$CTR" \
        --network=host \
        --entrypoint mooncake_master \
        "$IMAGE" \
        --port "$MOONCAKE_MASTER_PORT" \
        --default_kv_lease_ttl 11000 \
        --eviction_high_watermark_ratio 0.9 \
        --eviction_ratio 0.1
    echo
    docker logs -f "$CTR"
    exit 0
fi

# =============================================================================
# 角色 1 / 2：Prefill 或 Decode
# =============================================================================
if [ "$ROLE" != "proxy" ]; then

    [ -d "$MODEL_PATH" ] || { echo "权重目录不存在：$MODEL_PATH"; exit 1; }

    if [ "$ROLE" = "prefill" ]; then
        NODES="$PREFILL_NODES"; EACH="$PREFILL_DP_LOCAL"; TP="$PREFILL_TP"
        BASE_PORT="$PREFILL_BASE_PORT"; GLOBAL_DP="$P_DP_SIZE"; TEMPLATE="$PWD/run_p.sh"
    else
        NODES="$DECODE_NODES";  EACH="$DECODE_DP_LOCAL";  TP="$DECODE_TP"
        BASE_PORT="$DECODE_BASE_PORT";  GLOBAL_DP="$D_DP_SIZE";  TEMPLATE="$PWD/run_d.sh"
    fi

    # 本机是这一组的第几台（顺序即 rank 顺序）
    IDX=-1; i=0
    for ip in $NODES; do
        if [ "$ip" = "$MY_IP" ]; then IDX=$i; fi
        i=$((i + 1))
    done
    [ "$IDX" -ge 0 ] || {
        echo "本机 $MY_IP 不在 $ROLE 节点列表里：$NODES"
        exit 1
    }

    RANK_START=$((IDX * EACH))
    DP_ADDR=$(echo $NODES | awk '{print $1}')      # DP 协调固定用该组第一台

    # 端口被上次的残留占着，是"起了一半"最常见的原因
    for p in $(seq "$BASE_PORT" $((BASE_PORT + EACH - 1))); do
        if ss -lnt 2>/dev/null | grep -qE "[:.]$p\b"; then
            echo "端口 $p 被占用，先执行 bash stop.sh"
            exit 1
        fi
    done

    # 官方 launcher 只认 ./run_dp_template.sh 这个名字
    RUNDIR="$PWD/.run/$ROLE"
    mkdir -p "$RUNDIR"
    cp "$TEMPLATE" "$RUNDIR/run_dp_template.sh"
    chmod +x "$RUNDIR/run_dp_template.sh"

    echo "== $ROLE 节点启动 =="
    echo "   本机 IP    : $MY_IP（$ROLE 组第 $((IDX + 1)) / $(echo $NODES | wc -w) 台）"
    echo "   全局 DP    : $GLOBAL_DP（每台 $EACH 个引擎，TP $TP）"
    echo "   本机 rank  : $RANK_START - $((RANK_START + EACH - 1))"
    echo "   引擎端口   : $BASE_PORT - $((BASE_PORT + EACH - 1))"
    echo "   Mooncake   : $MOONCAKE_MASTER（KV 走传输引擎，不是外部池）"
    echo "   注册内存   : 每引擎 $MOONCAKE_SEGMENT + $MOONCAKE_BUFFER，本机 $EACH 个引擎"
    echo

    docker rm -f "$CTR" >/dev/null 2>&1 || true

    docker run -d --name "$CTR" \
        --ipc=host \
        --network=host \
        --privileged \
        --shm-size="$SHM_SIZE" \
        --ulimit nofile=1048576:1048576 \
        $MOUNTS \
        -w "$RUNDIR" \
        -e HCCL_IF_IP="$MY_IP" \
        -e AE_CONFIG="$PWD/config.env" \
        $MC_ENV \
        "$IMAGE" \
        python3 "$LAUNCHER" \
        --dp-size "$GLOBAL_DP" \
        --tp-size "$TP" \
        --dp-size-local "$EACH" \
        --dp-rank-start "$RANK_START" \
        --dp-address "$DP_ADDR" \
        --dp-rpc-port "$DP_RPC_PORT" \
        --vllm-start-port "$BASE_PORT"

    echo "已启动。每个 rank 打印 Application startup complete. 才算就绪，大模型几十分钟。"
    echo "确认： docker logs $CTR 2>&1 | grep -c 'Application startup complete'"
    echo
    docker logs -f "$CTR"
    exit 0
fi

# =============================================================================
# 角色 3：代理。端点 = 每台 × 每台引擎数，host / port 四个列表必须等长
# =============================================================================
EP_P=""
for ip in $PREFILL_NODES; do
    for i in $(seq 0 $((PREFILL_DP_LOCAL - 1))); do EP_P="$EP_P $ip:$((PREFILL_BASE_PORT + i))"; done
done
EP_D=""
for ip in $DECODE_NODES; do
    for i in $(seq 0 $((DECODE_DP_LOCAL - 1))); do EP_D="$EP_D $ip:$((DECODE_BASE_PORT + i))"; done
done

P_HOSTS=$(echo $EP_P | tr ' ' '\n' | cut -d: -f1); P_PORTS=$(echo $EP_P | tr ' ' '\n' | cut -d: -f2)
D_HOSTS=$(echo $EP_D | tr ' ' '\n' | cut -d: -f1); D_PORTS=$(echo $EP_D | tr ' ' '\n' | cut -d: -f2)

echo "== 代理节点启动 =="
echo "   本机 IP     : $MY_IP"
echo "   Prefill 端点: $(echo $P_HOSTS | wc -w) 个（$(echo $PREFILL_NODES | wc -w) 台 × $PREFILL_DP_LOCAL）"
echo "   Decode 端点 : $(echo $D_HOSTS | wc -w) 个（$(echo $DECODE_NODES | wc -w) 台 × $DECODE_DP_LOCAL）"
echo "   对外入口    : http://$MY_IP:$PROXY_PORT"
echo

# 就绪闸：后端起齐之前起代理，客户端只会等到超时，而代理自己的 /healthcheck 是 200
echo "检查后端就绪..."
bad=0
for ep in $EP_P $EP_D; do
    curl -sf --noproxy '*' -m 5 "http://$ep/health" >/dev/null \
        || { echo "   未就绪 $ep"; bad=1; }
done
[ "$bad" = "0" ] || {
    echo
    echo "有后端没起来。先等全部 rank 打印 Application startup complete.，再起代理。"
    exit 1
}
echo "   全部就绪"
echo

docker rm -f "$CTR" >/dev/null 2>&1 || true

docker run -d --name "$CTR" \
    --ipc=host \
    --network=host \
    --privileged \
    --ulimit nofile=1048576:1048576 \
    $MOUNTS \
    -w "$PWD" \
    "$IMAGE" \
    python3 "$PROXY" \
    --host 0.0.0.0 \
    --port "$PROXY_PORT" \
    --prefiller-hosts $P_HOSTS \
    --prefiller-ports $P_PORTS \
    --decoder-hosts $D_HOSTS \
    --decoder-ports $D_PORTS

echo "已启动代理。试一发："
echo "  curl --noproxy '*' http://127.0.0.1:$PROXY_PORT/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$SERVED_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":16}'"
echo
docker logs -f "$CTR"
