#!/usr/bin/env bash
# =============================================================================
# run_dp_template_d.sh —— DeepSeek-V4.1-Flash Decode 单 rank 模板
#
# 由官方 launch_online_dp.py 调用，8 个位置参数（与 P 侧一致）：
#   $1 ASCEND_RT_VISIBLE_DEVICES  $2 --port
#   $3 --data-parallel-size       $4 --data-parallel-rank
#   $5 --data-parallel-address    $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size     $8 --prefill-context-parallel-size（D 侧恒为 1）
#
# ⚠ 不要照搬 Prefill 的 PCP / MegaMoE / prefix-caching / eager / swa-bounded-replay
# =============================================================================
set -uo pipefail

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

: "${MODEL_PATH:?必须通过 start_d.sh 启动}"
: "${LOCAL_IP:?缺少 LOCAL_IP}"

RANK="${4:-0}"

export HCCL_IF_IP="$LOCAL_IP"
export GLOO_SOCKET_IFNAME="${NIC_NAME}"
export TP_SOCKET_IFNAME="${NIC_NAME}"
export HCCL_SOCKET_IFNAME="${NIC_NAME}"
export ASCEND_RT_VISIBLE_DEVICES="$1"
export VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-36000}"
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export VLLM_USE_V2_MODEL_RUNNER=1
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE_D:-4096}"
[ -n "${HCCL_EXEC_TIMEOUT:-}" ] && export HCCL_EXEC_TIMEOUT

# KV Consumer 侧：dp_size / tp_size 必须与 Producer 侧完全一致
KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "${KV_CONNECTOR:-MooncakeHybridConnector}",
  "kv_role": "kv_consumer",
  "kv_port": "$((KV_CONSUMER_PORT + RANK))",
  "kv_connector_extra_config": {
    "prefill": {"dp_size": ${P_DP_SIZE}, "tp_size": ${P_TP}},
    "decode":  {"dp_size": ${D_DP_SIZE}, "tp_size": ${D_TP}}
  }
}
JSON
)

ENGRAM_CONFIG='{"cpu_offload":true,"dp_shared_memory":true}'
ADDITIONAL_CONFIG='{"enable_cpu_binding":true,"multistream_overlap_shared_expert":true,"recompute_scheduler_enable":true}'
SPEC_CONFIG='{"num_speculative_tokens":5,"method":"dspark"}'

ARGS=(
    "$MODEL_PATH"
    --host 0.0.0.0
    --port "$2"
    --data-parallel-size "$3"
    --data-parallel-rank "$4"
    --data-parallel-address "$5"
    --data-parallel-rpc-port "$6"
    --tensor-parallel-size "$7"
    --served-model-name "${SERVED_MODEL_NAME}"
    --max-model-len "${MAX_MODEL_LEN:-1048576}"
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS_D:-512}"
    --max-num-seqs "${MAX_NUM_SEQS_D:-72}"
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.95}"
    --block-size "${BLOCK_SIZE:-128}"
    --trust-remote-code
    --enable-expert-parallel
    --seed 1024
    --speculative-config "$SPEC_CONFIG"
    --tokenizer-mode deepseek_v41
    --reasoning-parser deepseek_v41
    --tool-call-parser deepseek_v41
    --enable-auto-tool-choice
    --safetensors-load-strategy lazy
    --engram-config "$ENGRAM_CONFIG"
    --additional-config "$ADDITIONAL_CONFIG"
    --async-scheduling                  # D 专属：调度与计算流水化
    --no-swa-bounded-replay
    --no-enable-prefix-caching          # D 侧不做 prefill，缓存只白占显存
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
)

[ -n "${QUANTIZATION:-}" ] && [ "$QUANTIZATION" != "none" ] && ARGS+=(--quantization "$QUANTIZATION")

# Decode 侧图捕获。整图捕获失败/显存吃紧时可改 PIECEWISE 或 off
if [ "${DECODE_CUDAGRAPH:-FULL_DECODE_ONLY}" != "off" ]; then
    ARGS+=(--compilation-config "{\"cudagraph_mode\":\"${DECODE_CUDAGRAPH:-FULL_DECODE_ONLY}\"}")
fi

exec vllm serve "${ARGS[@]}"
