#!/bin/bash
# =============================================================================
# 单个 Prefill 引擎的启动命令
#
# 由镜像里的 launch_online_dp.py 调用，固定传 7 个位置参数（顺序不能改）：
#   $1 本引擎用的卡号（ASCEND_RT_VISIBLE_DEVICES）   $2 端口
#   $3 --data-parallel-size      $4 --data-parallel-rank
#   $5 --data-parallel-address   $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size
#
# start.sh 会把它复制成 .run/prefill/run_dp_template.sh（launcher 只认这个名字），
# 所以配置从上一级目录读。
#
# ⚠ P 侧独有的参数不要搬到 Decode：MegaMoE、prefix-caching、eager。
# ⚠ 这个镜像没有 --prefill-context-parallel-size，P 侧靠 TP4 占卡，别加回来。
# =============================================================================
set -u
. "${AE_CONFIG:-$(dirname "$0")/../../config.env}"

RANK=$4

# ---------------------------------------------------------------- 通信环境
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export ASCEND_RT_VISIBLE_DEVICES="$1"
export HCCL_IF_IP="${HCCL_IF_IP:-127.0.0.1}"
export HCCL_SOCKET_IFNAME="$NIC_NAME"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export VLLM_ENGINE_READY_TIMEOUT_S=36000     # 加载慢也别调小
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=1024                    # P 侧偏小：prompt 吞吐优先
export HCCL_OP_EXPANSION_MODE=AIV
export VLLM_USE_V2_MODEL_RUNNER=1
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

# ---------------------------------------------------------------- A3 rank 组网（五台一致）
export HCCL_INTER_HCCS_DISABLE="$HCCL_INTER_HCCS_DISABLE"
export HCCL_INTRA_ROCE_ENABLE="$HCCL_INTRA_ROCE_ENABLE"
export HCCL_IF_BASE_PORT="$HCCL_IF_BASE_PORT"

# ---------------------------------------------------------------- Mooncake（P→D KV 传输）
export MOONCAKE_CONFIG_PATH="${MOONCAKE_CONFIG_PATH:-$(dirname "$0")/../../.run/mooncake.json}"

# ---------------------------------------------------------------- KV 生产端
# 传输连接器：P→D 的 KV 靠它。dp_size / tp_size 两侧必须一模一样
TRANSFER='{"kv_connector": "'"$KV_CONNECTOR"'", "kv_role": "kv_producer", "kv_port": '"$((KV_PRODUCER_PORT + RANK))"', "kv_connector_extra_config": {"prefill": {"dp_size": '"$P_DP_SIZE"', "tp_size": '"$PREFILL_TP"'}, "decode": {"dp_size": '"$D_DP_SIZE"', "tp_size": '"$DECODE_TP"'}}}'

# 池化连接器：把 KV 写进 Mooncake 共享池
STORE='{"kv_connector": "AscendStoreConnector", "kv_role": "kv_producer", "kv_connector_extra_config": {"backend": "'"$KV_STORE_BACKEND"'", "lookup_rpc_port": "0", "use_layerwise": false}}'

if [ "$KV_STORE" = "on" ]; then
    # 两个一起用，必须套 MultiConnector；hybrid 模型只能 fail，不能 recompute
    KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "MultiConnector",
  "kv_role": "kv_producer",
  "engine_id": "0",
  "kv_load_failure_policy": "fail",
  "kv_connector_extra_config": {"connectors": [$TRANSFER, $STORE]}
}
JSON
)
else
    KV_TRANSFER_CONFIG=$TRANSFER
fi

ENGRAM_CONFIG='{"cpu_offload":true,"dp_shared_memory":true}'
SPEC_CONFIG='{"num_speculative_tokens":5,"method":"dspark"}'
ADDITIONAL_CONFIG='{"enable_cpu_binding":true,"enable_fused_mc2":2,"enable_flashcomm1":false,"multistream_overlap_shared_expert":false}'

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
    --max-num-batched-tokens 8192 \
    --max-num-seqs 16 \
    --gpu-memory-utilization 0.9 \
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
    --enforce-eager \
    --enable-prefix-caching \
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
