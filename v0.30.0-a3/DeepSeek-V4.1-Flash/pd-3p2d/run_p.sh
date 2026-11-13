#!/bin/bash
# =============================================================================
# 单个 Prefill 引擎的启动命令
#
# 由官方 launch_online_dp.py 调用，固定传 8 个参数（顺序不能改）：
#   $1 本引擎用的卡号（ASCEND_RT_VISIBLE_DEVICES）   $2 端口
#   $3 --data-parallel-size      $4 --data-parallel-rank
#   $5 --data-parallel-address   $6 --data-parallel-rpc-port
#   $7 --tensor-parallel-size    $8 --prefill-context-parallel-size
#
# start.sh 会把它复制成 .run/<角色>/run_dp_template.sh（launcher 只认这个名字），
# 所以配置文件从上一级目录读。
#
# ⚠ 这是 Prefill 专用参数，不要抄到 Decode 用：PCP / MegaMoE / prefix-caching /
#   eager / swa-bounded-replay 都是 P 侧独有，搬到 D 上会掉性能甚至起不来。
# 注：SWA 重放（--swa-bounded-replay）这台镜像的 vllm 不支持，传了会
# unrecognized arguments，先去掉。换到支持它的镜像版本时再加回来。
# =============================================================================
set -u
# 配置路径由 start.sh 用 -e AE_CONFIG 传进来；单独手跑时回落到 ../../config.env
. "${AE_CONFIG:-$(dirname "$0")/../../config.env}"

RANK=$4
# PCP 优先用 launcher 传来的第 8 个参数；老版本 launcher 只传 7 个，回落到 config
PCP="${8:-${PREFILL_PCP:-1}}"

# ---------------------------------------------------------------- 通信环境
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export ASCEND_RT_VISIBLE_DEVICES="$1"
export HCCL_IF_IP="${HCCL_IF_IP:-127.0.0.1}"
export HCCL_SOCKET_IFNAME="$NIC_NAME"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export VLLM_ENGINE_READY_TIMEOUT_S=36000     # 官方兜底值，加载慢也别调小
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=1024                    # P 侧偏小：prompt 吞吐优先
export HCCL_OP_EXPANSION_MODE=AIV
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

# ---------------------------------------------------------------- KV 生产端
# 这里的 prefill/decode 的 dp_size 与 tp_size 必须与 D 侧写的一模一样，
# 否则连接器初始化失败。PCP 只体现在 --prefill-context-parallel-size，不要写进 tp_size。
KV_TRANSFER_CONFIG=$(cat <<JSON
{
  "kv_connector": "$KV_CONNECTOR",
  "kv_role": "kv_producer",
  "kv_port": $((KV_PRODUCER_PORT + RANK)),
  "kv_connector_extra_config": {
    "prefill": {"dp_size": $P_DP_SIZE, "tp_size": $PREFILL_TP},
    "decode":  {"dp_size": $D_DP_SIZE, "tp_size": $DECODE_TP}
  }
}
JSON
)

# Engram 表 24 个 head 在 16 卡上分不匀，A3 必须走 cpu_offload + DP 共享内存
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
    --prefill-context-parallel-size "$PCP" \
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
