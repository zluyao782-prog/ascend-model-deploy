#!/bin/bash
# =============================================================================
# DeepSeek-V4.1-Flash PD 分离 2P2D（4 台 × 16 卡）
#
# 每台机器按自己的角色执行，顺序不能颠倒：
#   1) 每个 Decode 节点：  bash start.sh decode     （D1 先，再 D2）
#   2) 每个 Prefill 节点： bash start.sh prefill    （P1 先，再 P2）
#   3) 代理节点：          bash start.sh proxy      （等后端全绿再起）
#
# 其他： bash check.sh   验证       bash stop.sh  停止
#
# 只改 config.env，本文件一般不用动。
# =============================================================================
set -e
cd "$(dirname "$0")"
. ./config.env

ROLE="${1:-}"
case "$ROLE" in
    prefill | decode | proxy) ;;
    *)
        echo "用法： bash start.sh prefill | decode | proxy"
        exit 1
        ;;
esac

# 一台机器可能同时跑两个角色（1P1D 里代理就落在 Prefill 那台），容器名必须按角色分开，
# 否则起代理时那条 docker rm -f 会把正在跑的 Prefill 一起删掉。
CTR="$CONTAINER_NAME-$ROLE"

# 官方脚本随镜像分发，不落仓库（避免版本漂移）。
# 路径默认是 vllm-ascend 0.30 的位置；报「镜像里找不到」时把 find 出来的目录
# 填进 config.env 的 IMAGE_DIR，不用改这个脚本。
IMAGE_DIR="${IMAGE_DIR:-/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1}"
LAUNCHER="$IMAGE_DIR/launch_online_dp.py"
PROXY="$IMAGE_DIR/load_balance_proxy_server_example.py"

# ---------------------------------------------------------------- 动手前先确认，避免跑到一半失败
# 内网没有外网：镜像必须已经导入，否则 docker run 会尝试 pull 然后报网络错误
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "本机没有镜像：$IMAGE"
    echo "先导入镜像包： docker load -i vllm-ascend-v0.30.0-a3.tar"
    exit 1
}

if [ "$ROLE" = "proxy" ]; then
    WANT="$PROXY"
else
    WANT="$LAUNCHER"
fi
docker run --rm "$IMAGE" bash -c "test -f '$WANT'" 2>/dev/null || {
    echo "镜像里找不到 $WANT"
    echo
    echo "先手工跑这两条，分清是路径变了还是文件根本不在："
    echo "    docker run --rm $IMAGE find / -name $(basename "$WANT")"
    echo "    docker run --rm $IMAGE bash -c \"test -f '$WANT'; echo 退出码=\$?\""
    echo
    echo "查到目录后填进 config.env，不用改脚本："
    echo "    IMAGE_DIR=/实际/所在/目录"
    exit 1
}

MY_IP=$(ip -4 -o addr show "$NIC_NAME" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$MY_IP" ] || {
    echo "网卡 $NIC_NAME 没有 IPv4 地址，检查 config.env 的 NIC_NAME（要填业务口）"
    exit 1
}

# 驱动路径缺失时跳过挂载，别让 docker run 直接报错
MOUNTS=""
for p in /usr/local/Ascend/driver /usr/local/dcmi /usr/local/bin/npu-smi /etc/ascend_install.info /etc/hccn.conf; do
    if [ -e "$p" ]; then
        MOUNTS="$MOUNTS -v $p:$p"
    else
        echo "提示：宿主机没有 $p，跳过挂载（驱动可能没装全）"
    fi
done
MOUNTS="$MOUNTS -v $MODEL_PATH:$MODEL_PATH -v $PWD:$PWD"

# =============================================================================
# 角色 1 / 2：Prefill 或 Decode 节点
# =============================================================================
if [ "$ROLE" != "proxy" ]; then

    [ -d "$MODEL_PATH" ] || { echo "权重目录不存在：$MODEL_PATH"; exit 1; }

    if [ "$ROLE" = "prefill" ]; then
        NODES="$PREFILL_NODES"
        EACH="$PREFILL_DP_LOCAL"
        TP="$PREFILL_TP"
        PCP="$PREFILL_PCP"
        BASE_PORT="$PREFILL_BASE_PORT"
        GLOBAL_DP="$P_DP_SIZE"
        TEMPLATE="$PWD/run_p.sh"
    else
        NODES="$DECODE_NODES"
        EACH="$DECODE_DP_LOCAL"
        TP="$DECODE_TP"
        PCP=1
        BASE_PORT="$DECODE_BASE_PORT"
        GLOBAL_DP="$D_DP_SIZE"
        TEMPLATE="$PWD/run_d.sh"
    fi

    # 本机是这一组的第几台？（顺序即 rank 顺序）
    IDX=-1
    i=0
    for ip in $NODES; do
        if [ "$ip" = "$MY_IP" ]; then IDX=$i; fi
        i=$((i + 1))
    done
    [ "$IDX" -ge 0 ] || {
        echo "本机 $MY_IP 不在 $ROLE 节点列表里：$NODES"
        echo "检查 config.env 的 ${ROLE^^}_NODES 和 NIC_NAME"
        exit 1
    }

    NODE_COUNT=$(echo $NODES | wc -w)
    RANK_START=$((IDX * EACH))
    DP_ADDR=$(echo $NODES | awk '{print $1}')      # DP 协调固定用该组第一台

    # 端口占用是"起了一半"的常见原因，先挡一次
    for p in $(seq "$BASE_PORT" $((BASE_PORT + EACH - 1))); do
        if ss -lnt 2>/dev/null | grep -qE "[:.]$p\b"; then
            echo "端口 $p 已被占用，先执行 bash stop.sh"
            exit 1
        fi
    done

    # 官方 launcher 只认 ./run_dp_template.sh 这个名字，所以复制一份到运行目录
    RUNDIR="$PWD/.run/$ROLE"
    mkdir -p "$RUNDIR"
    cp "$TEMPLATE" "$RUNDIR/run_dp_template.sh"
    chmod +x "$RUNDIR/run_dp_template.sh"

    echo "== $ROLE 节点启动 =="
    echo "   本机 IP     : $MY_IP（$ROLE 组第 $((IDX + 1)) / $NODE_COUNT 台）"
    echo "   全局 DP     : $GLOBAL_DP（每台 $EACH 个引擎）"
    echo "   本机 rank   : $RANK_START - $((RANK_START + EACH - 1))"
    echo "   TP / PCP    : $TP / $PCP"
    echo "   DP 协调地址 : $DP_ADDR:$DP_RPC_PORT"
    echo "   引擎端口    : $BASE_PORT - $((BASE_PORT + EACH - 1))"
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
        "$IMAGE" \
        python3 "$LAUNCHER" \
        --dp-size "$GLOBAL_DP" \
        --tp-size "$TP" \
        --pcp-size "$PCP" \
        --dp-size-local "$EACH" \
        --dp-rank-start "$RANK_START" \
        --dp-address "$DP_ADDR" \
        --dp-rpc-port "$DP_RPC_PORT" \
        --vllm-start-port "$BASE_PORT"

    echo
    echo "已启动。每个 rank 都要打印 Application startup complete. 才算就绪，大模型可能几十分钟。"
    echo "确认就绪： docker logs $CTR 2>&1 | grep -c 'Application startup complete'"
    echo "下面是日志（Ctrl+C 只退出日志，服务继续运行）："
    echo
    docker logs -f "$CTR"
    exit 0
fi

# =============================================================================
# 角色 3：代理节点
# =============================================================================
# 端点列表 = 每台 × 每台的引擎数，两者必须等长，官方代理不等长会直接退出
P_HOSTS=""
P_PORTS=""
for ip in $PREFILL_NODES; do
    for i in $(seq 0 $((PREFILL_DP_LOCAL - 1))); do
        P_HOSTS="$P_HOSTS $ip"
        P_PORTS="$P_PORTS $((PREFILL_BASE_PORT + i))"
    done
done

D_HOSTS=""
D_PORTS=""
for ip in $DECODE_NODES; do
    for i in $(seq 0 $((DECODE_DP_LOCAL - 1))); do
        D_HOSTS="$D_HOSTS $ip"
        D_PORTS="$D_PORTS $((DECODE_BASE_PORT + i))"
    done
done

echo "== 代理节点启动 =="
echo "   本机 IP      : $MY_IP"
echo "   Prefill 端点 : $(echo $P_HOSTS | wc -w) 个（$(echo $PREFILL_NODES | wc -w) 台 × $PREFILL_DP_LOCAL）"
echo "   Decode 端点  : $(echo $D_HOSTS | wc -w) 个（$(echo $DECODE_NODES | wc -w) 台 × $DECODE_DP_LOCAL）"
echo "   对外入口     : http://$MY_IP:$PROXY_PORT"
echo

# 就绪闸：后端没全绿就起代理，客户端只会收到超时。代理自己的 /healthcheck 会骗人。
if ! bash ./check.sh backends; then
    echo
    echo "还有后端没就绪，先等全部 rank 打印 Application startup complete.，再起代理。"
    exit 1
fi

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

echo
echo "已启动代理。验证： bash check.sh"
echo
docker logs -f "$CTR"
