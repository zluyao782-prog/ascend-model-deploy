#!/usr/bin/env bash
# =============================================================================
# run_dp_template_p.sh —— Prefill 单 rank 启动模板
#
# 由官方 launch_online_dp.py 调用，8 个位置参数：
#   $1 ASCEND_RT_VISIBLE_DEVICES  $2 --port
#   $3 --data-parallel-size       $4 --data-parallel-rank
#   $5 --data-parallel-address    $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size     $8 --prefill-context-parallel-size
#
# 由 start_role.sh 复制为 .run/prefill/run_dp_template.sh 后执行，
# 其余参数通过环境变量传入。
#
# ⚠ P/D 两份模板是角色特定的，不可互相复制：
#   Prefill 独有 PCP / MegaMoE / prefix-caching / eager；
#   Decode  独有 async-scheduling / 图捕获 / 多流 / 重计算。
# =============================================================================
set -uo pipefail

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

: "${MODEL_PATH:?必须通过 start_role.sh 启动}"
: "${LOCAL_IP:?缺少 LOCAL_IP}"

RANK="${4:-0}"

export HCCL_IF_IP="$LOCAL_IP"
export GLOO_SOCKET_IFNAME="${NIC_NAME}"
export TP_SOCKET_IFNAME="${NIC_NAME}"
export HCCL_SOCKET_IFNAME="${NIC_NAME}"
export ASCEND_RT_VISIBLE_DEVICES="$1"
export VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-36000}"
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE_P:-1024}"
[ -n "${HCCL_EXEC_TIMEOUT:-}" ] && export HCCL_EXEC_TIMEOUT

# KV Producer 侧：拓扑必须与 Decode 侧完全一致，否则连接器初始化失败
KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "${KV_CONNECTOR:-MooncakeHybridConnector}",
  "kv_role": "kv_producer",
  "kv_port": "$((KV_PRODUCER_PORT + RANK))",
  "kv_connector_extra_config": {
    "prefill": {"dp_size": ${P_DP_SIZE}, "tp_size": ${P_TP}},
    "decode":  {"dp_size": ${D_DP_SIZE}, "tp_size": ${D_TP}}
  }
}
JSON
)

ARGS=(
    "$MODEL_PATH"
    --host 0.0.0.0
    --port "$2"
    --data-parallel-size "$3"
    --data-parallel-rank "$4"
    --data-parallel-address "$5"
    --data-parallel-rpc-port "$6"
    --tensor-parallel-size "$7"
    --prefill-context-parallel-size "$8"
    --served-model-name "${SERVED_MODEL_NAME}"
    --max-model-len "${MAX_MODEL_LEN:-32768}"
    --max-num-batched-tokens "${P_MAX_NUM_BATCHED_TOKENS:-8192}"
    --max-num-seqs "${P_MAX_NUM_SEQS:-16}"
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.9}"
    --block-size "${BLOCK_SIZE:-128}"
    --trust-remote-code
    --enforce-eager
    --enable-prefix-caching
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
)

[ -n "${QUANTIZATION:-}" ] && [ "$QUANTIZATION" != "none" ] && ARGS+=(--quantization "$QUANTIZATION")

# shellcheck disable=SC2206
[ -n "${EXTRA_VLLM_ARGS:-}" ] && ARGS+=($EXTRA_VLLM_ARGS)

exec vllm serve "${ARGS[@]}"
