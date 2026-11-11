#!/usr/bin/env bash
# =============================================================================
# run_dp_template_p.sh —— DeepSeek-V4.1-Flash Prefill 单 rank 模板
#
# 由官方 launch_online_dp.py 调用，8 个位置参数：
#   $1 ASCEND_RT_VISIBLE_DEVICES  $2 --port
#   $3 --data-parallel-size       $4 --data-parallel-rank
#   $5 --data-parallel-address    $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size     $8 --prefill-context-parallel-size
#
# 调用链：start_p.sh → _shared/pd/start_role.sh → 复制到 .run/prefill/
#        → launch_online_dp.py → 本模板
# 其余参数由 start_role.sh 通过环境变量注入。
#
# ⚠ 与 run_dp_template_d.sh 是角色特定的一对，不可交叉复制：
#   P 独有：PCP4 / MegaMoE(fused_mc2) / prefix-caching / eager / swa-bounded-replay
#   D 独有：async-scheduling / FULL_DECODE_ONLY 图模式 / 多流 / 重计算
# =============================================================================
set -uo pipefail

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

: "${MODEL_PATH:?必须通过 start_p.sh 启动}"
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
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE_P:-1024}"
export HCCL_OP_EXPANSION_MODE="AIV"
[ -n "${HCCL_EXEC_TIMEOUT:-}" ] && export HCCL_EXEC_TIMEOUT

# KV Producer 侧：拓扑必须与 Decode 侧完全一致
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

# Engram 表 24 个 head 无法在 16 卡均分，A3 必须走 cpu_offload + DP 共享内存
ENGRAM_CONFIG='{"cpu_offload":true,"dp_shared_memory":true}'
ADDITIONAL_CONFIG='{"enable_cpu_binding":true,"enable_fused_mc2":2,"enable_flashcomm1":false,"multistream_overlap_shared_expert":false}'
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
    --prefill-context-parallel-size "$8"
    --served-model-name "${SERVED_MODEL_NAME}"
    --max-model-len "${MAX_MODEL_LEN:-1048576}"
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS_P:-8192}"
    --max-num-seqs "${MAX_NUM_SEQS_P:-16}"
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.9}"
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
    --enforce-eager                     # P 侧 shape 变化大，整图捕获收益低
    --swa-bounded-replay
    --enable-prefix-caching             # 多轮 / 相同 system prompt 直接省 prefill
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
)

[ -n "${QUANTIZATION:-}" ] && [ "$QUANTIZATION" != "none" ] && ARGS+=(--quantization "$QUANTIZATION")

exec vllm serve "${ARGS[@]}"
