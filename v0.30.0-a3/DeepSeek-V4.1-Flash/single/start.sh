#!/bin/bash
# =============================================================================
# DeepSeek-V4.1-Flash 单机启动（1 台 × 16 卡）
#
#   bash start.sh     启动并跟随日志（Ctrl+C 只退出日志，服务继续跑）
#   bash check.sh     验证能不能真的推理
#   bash stop.sh      停止
#
# 只改 config.env，本文件一般不用动。
# =============================================================================
set -e
cd "$(dirname "$0")"
. ./config.env

# ---------------------------------------------------------------- 1. 动手前先确认，避免跑到一半失败
[ -d "$MODEL_PATH" ] || { echo "权重目录不存在：$MODEL_PATH"; exit 1; }

# 内网没有外网：镜像必须已经导入本地，否则 docker run 会尝试 pull 然后报网络错误
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "本机没有镜像：$IMAGE"
    echo "先导入镜像包： docker load -i vllm-ascend-v0.30.0-a3-openeuler.tar"
    echo "本机已有的 vllm-ascend 镜像（tag 不一样就改 config.env 的 IMAGE）："
    docker images --format '    {{.Repository}}:{{.Tag}}' 2>/dev/null | grep vllm-ascend \
        || echo "    （本机没有 vllm-ascend 镜像）"
    exit 1
}

CARDS=$(npu-smi info -l 2>/dev/null | grep -c "NPU ID" || true)
[ "$CARDS" -ge $((SINGLE_TP * SINGLE_DP)) ] || {
    echo "本机识别到 ${CARDS:-0} 张卡，少于 TP×DP = $((SINGLE_TP * SINGLE_DP))"
    exit 1
}

ss -lnt 2>/dev/null | grep -qE "[:.]$SINGLE_PORT\b" && {
    echo "端口 $SINGLE_PORT 已被占用，先执行 bash stop.sh 清掉上次的容器"
    exit 1
}

MY_IP=$(ip -4 -o addr show "$NIC_NAME" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$MY_IP" ] || {
    echo "网卡 $NIC_NAME 没有 IPv4 地址，检查 config.env 的 NIC_NAME（要填业务口）"
    exit 1
}

# ---------------------------------------------------------------- 2. 挂载：驱动路径缺失时跳过，别让 docker run 直接报错
MOUNTS=""
for p in /usr/local/Ascend/driver /usr/local/dcmi /usr/local/bin/npu-smi /etc/ascend_install.info /etc/hccn.conf; do
    if [ -e "$p" ]; then
        MOUNTS="$MOUNTS -v $p:$p"
    else
        echo "提示：宿主机没有 $p，跳过挂载（驱动可能没装全）"
    fi
done

# ---------------------------------------------------------------- 3. 起容器（命令就是 serve.sh）
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --name "$CONTAINER_NAME" \
    --ipc=host \
    --network=host \
    --privileged \
    --shm-size="$SHM_SIZE" \
    --ulimit nofile=1048576:1048576 \
    $MOUNTS \
    -v "$MODEL_PATH:$MODEL_PATH" \
    -v "$PWD:$PWD" \
    -w "$PWD" \
    -e HCCL_IF_IP="$MY_IP" \
    "$IMAGE" \
    bash serve.sh

echo
echo "已启动： 容器 $CONTAINER_NAME   服务 http://$MY_IP:$SINGLE_PORT"
echo "首次加载权重 + 图捕获要 5~15 分钟，看到 Application startup complete. 才算起来。"
echo "下面是日志（Ctrl+C 只退出日志，服务继续运行）："
echo
docker logs -f "$CONTAINER_NAME"
