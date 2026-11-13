#!/bin/bash
# =============================================================================
# 单个 Decode 引擎的启动命令
#
# 由官方 launch_online_dp.py 调用，固定传 8 个参数（顺序不能改）：
#   $1 本引擎用的卡号（ASCEND_RT_VISIBLE_DEVICES）   $2 端口
#   $3 --data-parallel-size      $4 --data-parallel-rank
#   $5 --data-parallel-address   $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size    $8 --prefill-context-parallel-size（D 侧恒为 1）
#
# start.sh 会把它复制成 .run/<角色>/run_dp_template.sh（launcher 只认这个名字）。
#
# ⚠ 不要照抄 Prefill 的 PCP / MegaMoE / prefix-caching / eager / swa-bounded-replay。
# =============================================================================
set -u
# 配置路径由 start.sh 用 -e AE_CONFIG 传进来；单独手跑时回落到 ../../config.env
. "${AE_CONFIG:-$(dirname "$0")/../../config.env}"

RANK=$4

# ---------------------------------------------------------------- 通信环境
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export ASCEND_RT_VISIBLE_DEVICES="$1"
export HCCL_IF_IP="${HCCL_IF_IP:-127.0.0.1}"
export HCCL_SOCKET_IFNAME="$NIC_NAME"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export VLLM_ENGINE_READY_TIMEOUT_S=36000     # 官方兜底值，加载慢也别调小
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=4096                    # D 侧偏大：解码小包多
export VLLM_USE_V2_MODEL_RUNNER=1
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

# ---------------------------------------------------------------- rank 组网（A3 走 RoCE）
# 来自 config.env，五台必须一致。只在进程启动时读一次，改了要全部重启。
export HCCL_INTER_HCCS_DISABLE="$HCCL_INTER_HCCS_DISABLE"
export HCCL_INTRA_ROCE_ENABLE="$HCCL_INTRA_ROCE_ENABLE"
export HCCL_IF_BASE_PORT="$HCCL_IF_BASE_PORT"

# ---------------------------------------------------------------- Mooncake 池化
# 每个引擎按这份 json 里的 global_segment_size 往共享池贡献内存。
# 路径由 start.sh 用 -e 传进来；单独手跑时回落到 ../../.run/mooncake.json
export MOONCAKE_CONFIG_PATH="${MOONCAKE_CONFIG_PATH:-$(dirname "$0")/../../.run/mooncake.json}"

# ---------------------------------------------------------------- KV 消费端
# prefill/decode 的 dp_size 与 tp_size 必须与 P 侧完全一致
KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "$KV_CONNECTOR",
  "kv_role": "kv_consumer",
  "kv_port": $((KV_CONSUMER_PORT + RANK)),
  "kv_connector_extra_config": {
    "prefill": {"dp_size": $P_DP_SIZE, "tp_size": $PREFILL_TP},
    "decode":  {"dp_size": $D_DP_SIZE, "tp_size": $DECODE_TP}
  }
}
JSON
)

ENGRAM_CONFIG='{"cpu_offload":true,"dp_shared_memory":true}'
SPEC_CONFIG='{"num_speculative_tokens":5,"method":"dspark"}'
ADDITIONAL_CONFIG='{"enable_cpu_binding":true,"multistream_overlap_shared_expert":true,"recompute_scheduler_enable":true}'
# 图模式：整理解码步的调度开销。捕获阶段 OOM 就改 PIECEWISE，或删掉这一项
CUDAGRAPH_CONFIG='{"cudagraph_mode":"FULL_DECODE_ONLY"}'

vllm serve "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$2" \
    --data-parallel-size "$3" \
    --data-parallel-rank "$4" \
    --data-parallel-address "$5" \
    --data-parallel-rpc-port "$6" \
    --tensor-parallel-size "$7" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --max-model-len "$MAX_MODEL_LEN" \
    --max-num-batched-tokens 512 \
    --max-num-seqs 72 \
    --gpu-memory-utilization 0.95 \
    --quantization ascend \
    --block-size 128 \
    --trust-remote-code \
    --enable-expert-parallel \
    --seed 1024 \
    --speculative-config "$SPEC_CONFIG" \
    --tokenizer-mode deepseek_v41 \
    --reasoning-parser deepseek_v41 \
    --tool-call-parser deepseek_v41 \
    --enable-auto-tool-choice \
    --safetensors-load-strategy lazy \
    --engram-config "$ENGRAM_CONFIG" \
    --additional-config "$ADDITIONAL_CONFIG" \
    --async-scheduling \
    --no-swa-bounded-replay \
    --no-enable-prefix-caching \
    --compilation-config "$CUDAGRAPH_CONFIG" \
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
