#!/bin/bash
# =============================================================================
# 容器内真正执行的命令：一条 vllm serve
#
# 模型相关参数改这里；路径、卡数、端口在 config.env。
# 本文件由 docker 挂进容器执行，不需要手工调用。
# =============================================================================
set -e
cd "$(dirname "$0")"
. ./config.env

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# 通信网卡与 IP（HCCL_IF_IP 由 start.sh 传进来，避免容器内没有 ip 命令）
export HCCL_IF_IP="${HCCL_IF_IP:-127.0.0.1}"
export HCCL_SOCKET_IFNAME="$NIC_NAME"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export VLLM_ENGINE_READY_TIMEOUT_S=36000      # 官方兜底值，加载慢也别调小
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True

vllm serve "$MODEL_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --host 0.0.0.0 \
    --port "$SINGLE_PORT" \
    --tensor-parallel-size "$SINGLE_TP" \
    --data-parallel-size "$SINGLE_DP" \
    --max-model-len "$MAX_MODEL_LEN" \
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    --quantization ascend \
    --block-size 128 \
    --trust-remote-code \
    --enable-expert-parallel \
    --speculative-config '{"num_speculative_tokens":5,"method":"dspark"}' \
    --tokenizer-mode deepseek_v41 \
    --reasoning-parser deepseek_v41 \
    --tool-call-parser deepseek_v41 \
    --enable-auto-tool-choice \
    --safetensors-load-strategy lazy \
    --engram-config '{"cpu_offload":true,"dp_shared_memory":true}'
