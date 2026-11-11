#!/usr/bin/env bash
# =============================================================================
# serve_single.sh —— 单机多卡部署（vllm serve 直起）
#
# 用法：
#   bash scripts/serve_single.sh             # 后台启动，日志 logs/single.log
#   bash scripts/serve_single.sh --foreground # 前台启动，便于看加载过程
#
# 说明：宿主机上执行时会自动 docker exec 进容器；若已在容器内则直接启动
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

load_config

[ "$DEPLOY_MODE" = "single" ] || die "当前 DEPLOY_MODE=$DEPLOY_MODE，单机启动请设为 single"

FG=0
[ "${1:-}" = "--foreground" ] && FG=1

LOG_DIR="$AE_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/single.log"

NPU=$(npu_count)
if [ "$NPU" -gt 0 ] 2>/dev/null; then
    if [ $((NPU % SINGLE_TP)) -ne 0 ] 2>/dev/null; then
        warn "NPU 数 $NPU 不能被 TP=$SINGLE_TP 整除，按 vLLM 规则 TP 应整除卡数"
    fi
    if [ "$NPU" -lt "$SINGLE_TP" ] 2>/dev/null; then
        die "本机 NPU=$NPU < SINGLE_TP=$SINGLE_TP"
    fi
fi

port_busy "$SINGLE_PORT" && die "端口 $SINGLE_PORT 已被占用（可能是上一次未退出的服务）"

# 本机 IP（用于 HCCL 绑定，多机扩展时同样适用）
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# ---------- 组装 vllm serve 参数 ----------
ARGS=(vllm serve "$MODEL_PATH")
ARGS+=(--served-model-name "$SERVED_MODEL_NAME")
ARGS+=(--host 0.0.0.0 --port "$SINGLE_PORT")
ARGS+=(--tensor-parallel-size "$SINGLE_TP")
if [ "${SINGLE_DP:-1}" -gt 1 ] 2>/dev/null; then
    ARGS+=(--data-parallel-size "$SINGLE_DP")
fi
ARGS+=(--max-model-len "$MAX_MODEL_LEN")
ARGS+=(--max-num-seqs "${MAX_NUM_SEQS_D:-72}")
ARGS+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS_D:-512}")
ARGS+=(--gpu-memory-utilization "$GPU_MEM_UTIL")
ARGS+=(--block-size "$BLOCK_SIZE")
ARGS+=(--trust-remote-code)
[ -n "${QUANTIZATION:-}" ] && [ "$QUANTIZATION" != "none" ] && ARGS+=(--quantization "$QUANTIZATION")

# shellcheck disable=SC2206
[ -n "${SINGLE_EXTRA_ARGS:-}" ] && ARGS+=($SINGLE_EXTRA_ARGS)

CMD=$(printf '%q ' "${ARGS[@]}")

# ---------- 环境变量（HCCL 绑定通信网卡） ----------
ENV_PREFIX="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; "
ENV_PREFIX+="export HCCL_IF_IP='${LOCAL_IP}' GLOO_SOCKET_IFNAME='${NIC_NAME}' TP_SOCKET_IFNAME='${NIC_NAME}' HCCL_SOCKET_IFNAME='${NIC_NAME}' "
ENV_PREFIX+="VLLM_ENGINE_READY_TIMEOUT_S='${VLLM_ENGINE_READY_TIMEOUT_S}' PYTORCH_NPU_ALLOC_CONF=expandable_segments:True "
[ -n "${HCCL_EXEC_TIMEOUT:-}" ] && ENV_PREFIX+="HCCL_EXEC_TIMEOUT='${HCCL_EXEC_TIMEOUT}' "

cat <<INFO
== 单机部署 ==
   模型      : $MODEL_PATH
   对外模型名: $SERVED_MODEL_NAME
   TP / DP   : $SINGLE_TP / ${SINGLE_DP:-1}
   通信网卡  : $NIC_NAME（$LOCAL_IP）
   监听      : 0.0.0.0:$SINGLE_PORT
   日志      : $LOG_FILE
INFO

if have vllm; then
    # 已在容器内
    if [ "$FG" = "1" ]; then
        eval "${ENV_PREFIX}${CMD}"
    else
        nohup bash -c "${ENV_PREFIX}${CMD}" >"$LOG_FILE" 2>&1 < /dev/null &
        info "已后台启动 pid=$!"
    fi
else
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" || die "容器 $CONTAINER_NAME 未运行，先执行： make up"
    if [ "$FG" = "1" ]; then
        docker exec -it "$CONTAINER_NAME" bash -lc "${ENV_PREFIX}exec ${CMD}"
    else
        docker exec -d "$CONTAINER_NAME" bash -lc "${ENV_PREFIX}exec ${CMD} > '${WORKDIR_CTR}/logs/single.log' 2>&1"
        info "已在容器内后台启动"
    fi
fi

if [ "$FG" = "0" ]; then
    sect "等待服务就绪"
    wait_http "http://127.0.0.1:${SINGLE_PORT}/health" "${VLLM_ENGINE_READY_TIMEOUT_S:-600}" "HTTP /health" || {
        warn "首次加载大模型可能耗时很长，可持续观察： tail -f $LOG_FILE"
        exit 1
    }
    ok "服务已就绪，验证： bash scripts/health_check.sh"
fi
