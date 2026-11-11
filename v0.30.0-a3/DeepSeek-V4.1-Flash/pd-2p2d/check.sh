#!/bin/bash
# =============================================================================
# 验证 PD 分离服务
#
#   bash check.sh            全查：每个后端 → 代理 → 真实推理
#   bash check.sh backends   只查后端（start.sh proxy 用它做就绪闸）
#
# 退出码 0 = 全过；1 = 有失败。
#
# 顺序不能跳：先逐个后端 /health，全绿了再看代理。
# 代理的 /healthcheck 只反映"注册了几个实例"，不代表后端可用。
# =============================================================================
cd "$(dirname "$0")"
. ./config.env

MODE="${1:-all}"
FAIL=0

echo "== 1. Prefill 后端（$(echo $PREFILL_NODES | wc -w) 台 × $PREFILL_DP_LOCAL）"
for ip in $PREFILL_NODES; do
    for i in $(seq 0 $((PREFILL_DP_LOCAL - 1))); do
        p=$((PREFILL_BASE_PORT + i))
        if curl --noproxy '*' -fsS -m 5 "http://$ip:$p/health" >/dev/null 2>&1; then
            echo "   [ OK ] $ip:$p"
        else
            echo "   [FAIL] $ip:$p"
            FAIL=1
        fi
    done
done

echo "== 2. Decode 后端（$(echo $DECODE_NODES | wc -w) 台 × $DECODE_DP_LOCAL）"
for ip in $DECODE_NODES; do
    for i in $(seq 0 $((DECODE_DP_LOCAL - 1))); do
        p=$((DECODE_BASE_PORT + i))
        if curl --noproxy '*' -fsS -m 5 "http://$ip:$p/health" >/dev/null 2>&1; then
            echo "   [ OK ] $ip:$p"
        else
            echo "   [FAIL] $ip:$p"
            FAIL=1
        fi
    done
done

if [ "$FAIL" != "0" ]; then
    echo
    echo "有后端没就绪。看日志： docker logs $CONTAINER_NAME 2>&1 | tail -50"
    echo "（每个 rank 都应打印 Application startup complete.）"
    exit 1
fi

[ "$MODE" = "backends" ] && { echo; echo "后端全部就绪。"; exit 0; }

# ---------------------------------------------------------------- 代理与真实推理
PROXY_HOST="${PROXY_NODE:-$(echo $PREFILL_NODES | awk '{print $1}')}"
BASE="http://$PROXY_HOST:$PROXY_PORT"

echo "== 3. 代理 /healthcheck"
if curl --noproxy '*' -fsS -m 10 "$BASE/healthcheck" >/dev/null 2>&1; then
    echo "   [ OK ] $BASE/healthcheck（只代表注册了实例，不代表可用）"
else
    echo "   [FAIL] 代理不通，先确认代理节点已执行 bash start.sh proxy"
    exit 1
fi

echo "== 4. 真实推理（唯一能证明 P→D 的 KV 传输通了的一步）"
ANSWER=$(curl --noproxy '*' -sS -m 180 "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$SERVED_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"用一句话介绍你自己。\"}],\"max_tokens\":64}" \
    2>/dev/null | head -c 300)

if echo "$ANSWER" | grep -q '"content"'; then
    echo "   [ OK ] 推理成功"
    echo "        $ANSWER"
    echo
    echo "全部通过。"
    exit 0
else
    echo "   [FAIL] 推理失败或超时"
    echo "        ${ANSWER:-（无响应）}"
    echo
    echo "后端全绿但请求挂住，八成是 KV 端口被防火墙拦了："
    echo "  从 P 节点执行  telnet <D节点IP> 30100"
    echo "  需要放开 30000-30031 的 TCP"
    exit 1
fi
