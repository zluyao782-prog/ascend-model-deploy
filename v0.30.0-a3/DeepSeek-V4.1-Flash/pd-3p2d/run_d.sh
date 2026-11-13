#!/bin/bash
# =============================================================================
# 单个 Decode 引擎的启动命令
#
# 由镜像里的 launch_online_dp.py 调用，固定传 7 个位置参数（顺序不能改）：
#   $1 本引擎用的卡号（ASCEND_RT_VISIBLE_DEVICES）   $2 端口
#   $3 --data-parallel-size      $4 --data-parallel-rank
#   $5 --data-parallel-address   $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size
#
# start.sh 会把它复制成 .run/decode/run_dp_template.sh（launcher 只认这个名字）。
#
# ⚠ 不要照抄 Prefill 的 MegaMoE / prefix-caching / eager：D 侧这三项都要反过来。
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
export HCCL_BUFFSIZE=4096                    # D 侧偏大：解码小包多
export VLLM_USE_V2_MODEL_RUNNER=1
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

# ---------------------------------------------------------------- A3 rank 组网（五台一致）
export HCCL_INTER_HCCS_DISABLE="$HCCL_INTER_HCCS_DISABLE"
export HCCL_INTRA_ROCE_ENABLE="$HCCL_INTRA_ROCE_ENABLE"
export HCCL_IF_BASE_PORT="$HCCL_IF_BASE_PORT"

# ---------------------------------------------------------------- Mooncake（P→D KV 传输）
export MOONCAKE_CONFIG_PATH="${MOONCAKE_CONFIG_PATH:-$(dirname "$0")/../../.run/mooncake.json}"

# ---------------------------------------------------------------- KV 消费端
# 传输连接器：dp_size / tp_size 必须和 P 侧一模一样
TRANSFER='{"kv_connector": "'"$KV_CONNECTOR"'", "kv_role": "kv_consumer", "kv_port": '"$((KV_CONSUMER_PORT + RANK))"', "kv_connector_extra_config": {"prefill": {"dp_size": '"$P_DP_SIZE"', "tp_size": '"$PREFILL_TP"'}, "decode": {"dp_size": '"$D_DP_SIZE"', "tp_size": '"$DECODE_TP"'}}}'

# 池化连接器：D 默认不读池，KV_STORE_D_READ=on 才从池里捞前缀
[ "$KV_STORE_D_READ" = "on" ] && D_LOAD=true || D_LOAD=false
STORE='{"kv_connector": "AscendStoreConnector", "kv_role": "kv_consumer", "kv_connector_extra_config": {"backend": "'"$KV_STORE_BACKEND"'", "lookup_rpc_port": "0", "use_layerwise": false, "consumer_is_to_load": '"$D_LOAD"', "consumer_is_to_put": false}}'

if [ "$KV_STORE" = "on" ]; then
    KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "MultiConnector",
  "kv_role": "kv_consumer",
  "engine_id": "1",
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
ADDITIONAL_CONFIG='{"enable_cpu_binding":true,"multistream_overlap_shared_expert":true,"recompute_scheduler_enable":true}'
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
    --no-enable-prefix-caching \
    --compilation-config "$CUDAGRAPH_CONFIG" \
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
