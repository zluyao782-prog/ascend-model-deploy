#!/usr/bin/env bash
# =============================================================================
# start_role.sh —— PD 分离：按角色启动本节点的 DP 引擎组
#
# 用法：
#   bash scripts/pd/start_role.sh prefill          # 自动用本机 IP 匹配 P 组
#   bash scripts/pd/start_role.sh decode           # 自动用本机 IP 匹配 D 组
#   bash scripts/pd/start_role.sh prefill 10.0.0.11  # 手动指定本机 IP
#
# 做的事：
#   1. 校验本机 IP 是否在该角色节点列表
#   2. 由节点序号推导 dp-rank-start（前序节点 dp_local 累加）
#   3. 把对应角色的单 rank 模板放到独立工作目录（launcher 要求 ./run_dp_template.sh）
#   4. 调官方 launch_online_dp.py 拉起本地 dp_local 个引擎
#
# 顺序约定：先全部 Decode，再全部 Prefill，最后 Proxy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/common.sh"

load_config

ROLE="${1:-}"
case "$ROLE" in
    prefill | p) ROLE="prefill" ;;
    decode | d) ROLE="decode" ;;
    *) die "用法： bash scripts/pd/start_role.sh <prefill|decode> [本机IP]" ;;
esac

[ "$DEPLOY_MODE" = "pd" ] || die "当前 DEPLOY_MODE=$DEPLOY_MODE，请先在 config/env 设为 pd"

if [ "$ROLE" = "prefill" ]; then
    NODES="$PREFILL_NODES"
    DP_LOCAL="$PREFILL_DP_LOCAL"
    TP="$PREFILL_TP"
    PCP="$PREFILL_PCP"
    BASE_PORT="$PREFILL_BASE_PORT"
    TEMPLATE="$SCRIPT_DIR/run_dp_template_p.sh"
else
    NODES="$DECODE_NODES"
    DP_LOCAL="$DECODE_DP_LOCAL"
    TP="$DECODE_TP"
    PCP=1
    BASE_PORT="$DECODE_BASE_PORT"
    TEMPLATE="$SCRIPT_DIR/run_dp_template_d.sh"
fi

NODE_ARR=($(list_lines "$NODES"))
NODE_COUNT="${#NODE_ARR[@]}"
[ "$NODE_COUNT" -gt 0 ] || die "$ROLE 节点列表为空，检查 config/env"

# ---------- 1. 确定本机 IP ----------
LOCAL_IP="${2:-}"
if [ -z "$LOCAL_IP" ]; then
    for ip in $(hostname -I 2>/dev/null); do
        for n in "${NODE_ARR[@]}"; do
            if [ "$ip" = "$n" ]; then LOCAL_IP="$ip"; break 2; fi
        done
    done
fi
[ -n "$LOCAL_IP" ] || die "未识别到本机属于 $ROLE 组：${NODE_ARR[*]}
       手动执行： bash scripts/pd/start_role.sh $ROLE <本机IP>"

# ---------- 2. 推导全局 DP rank 起点 ----------
NODE_INDEX=-1
for i in "${!NODE_ARR[@]}"; do
    if [ "${NODE_ARR[$i]}" = "$LOCAL_IP" ]; then NODE_INDEX=$i; break; fi
done
[ "$NODE_INDEX" -ge 0 ] || die "$LOCAL_IP 不在 $ROLE 节点列表：${NODE_ARR[*]}"

DP_RANK_START=$((NODE_INDEX * DP_LOCAL))
DP_ADDRESS="${NODE_ARR[0]}"          # DP 协调固定用该角色第一台

P_COUNT=$(list_count "$PREFILL_NODES")
D_COUNT=$(list_count "$DECODE_NODES")
P_GLOBAL=$((P_COUNT * PREFILL_DP_LOCAL))
D_GLOBAL=$((D_COUNT * DECODE_DP_LOCAL))
DP_GLOBAL=$([ "$ROLE" = "prefill" ] && echo "$P_GLOBAL" || echo "$D_GLOBAL")

# ---------- 3. 准备运行目录 ----------
RUNDIR="$AE_ROOT/.run/$ROLE"
mkdir -p "$RUNDIR/log"
cp -f "$TEMPLATE" "$RUNDIR/run_dp_template.sh"
chmod +x "$RUNDIR/run_dp_template.sh"

LAUNCHER="$AE_ROOT/.tools/launch_online_dp.py"
[ -f "$LAUNCHER" ] || die "缺少官方启动器 $LAUNCHER
       先执行： bash scripts/pd/fetch_official.sh"

# ---------- 4. 导出供模板读取的变量 ----------
export AE_ROLE="$ROLE"
export LOCAL_IP NIC_NAME MODEL_PATH SERVED_MODEL_NAME
export P_DP_SIZE="$P_GLOBAL" D_DP_SIZE="$D_GLOBAL"
export P_TP="$PREFILL_TP" D_TP="$DECODE_TP"
export KV_CONNECTOR
export KV_PRODUCER_PORT KV_CONSUMER_PORT
export MAX_MODEL_LEN GPU_MEM_UTIL QUANTIZATION BLOCK_SIZE
export MAX_NUM_BATCHED_TOKENS_P MAX_NUM_BATCHED_TOKENS_D
export MAX_NUM_SEQS_P MAX_NUM_SEQS_D
export HCCL_BUFFSIZE_P HCCL_BUFFSIZE_D
export HCCL_EXEC_TIMEOUT VLLM_ENGINE_READY_TIMEOUT_S
export EXTRA_VLLM_ARGS
export DP_RANK_GLOBAL_START="$DP_RANK_START"

if [ "$ROLE" = "prefill" ]; then
    export P_MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS_P"
    export P_MAX_NUM_SEQS="$MAX_NUM_SEQS_P"
else
    export D_MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS_D"
    export D_MAX_NUM_SEQS="$MAX_NUM_SEQS_D"
fi

# ---------- 5. 打印拓扑 ----------
cat <<EOF
== $ROLE 节点启动 ==
   本机 IP        : $LOCAL_IP （$ROLE 组第 $((NODE_INDEX + 1))/$NODE_COUNT 台）
   通信网卡       : $NIC_NAME
   全局 DP        : $DP_GLOBAL（本地 $DP_LOCAL/台 × $NODE_COUNT 台）
   本机 rank 区间 : $DP_RANK_START - $((DP_RANK_START + DP_LOCAL - 1))
   TP / PCP       : $TP / $PCP
   DP 协调地址    : $DP_ADDRESS:$DP_RPC_PORT
   引擎端口       : $BASE_PORT - $((BASE_PORT + DP_LOCAL - 1))
   权重           : $MODEL_PATH
   跨角色拓扑     : P DP$P_GLOBAL(TP$PREFILL_TP)  →  D DP$D_GLOBAL(TP$DECODE_TP)
EOF

# 端口占用是常见的"起了一半"原因，先挡一次
for ((i = 0; i < DP_LOCAL; i++)); do
    p=$((BASE_PORT + i))
    port_busy "$p" && die "端口 $p 已被占用，先清理残留 vllm 进程"
done

# ---------- 6. 拉起 ----------
LOG="$RUNDIR/log/$ROLE.log"
cd "$RUNDIR"
nohup python3 "$LAUNCHER" \
    --dp-size "$DP_GLOBAL" \
    --tp-size "$TP" \
    --pcp-size "$PCP" \
    --dp-size-local "$DP_LOCAL" \
    --dp-rank-start "$DP_RANK_START" \
    --dp-address "$DP_ADDRESS" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$BASE_PORT" \
    >"$LOG" 2>&1 </dev/null &

info "已提交后台启动 pid=$!"
info "日志： tail -f $LOG"
warn "每个 rank 都打印 'Application startup complete.' 后再进入下一步；大模型加载可能数小时"
