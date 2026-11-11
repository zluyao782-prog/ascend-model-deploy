#!/usr/bin/env bash
# =============================================================================
# health_check.sh —— 分层健康自检
#
# 用法：
#   bash scripts/health_check.sh                # 单机
#   bash scripts/health_check.sh --pd           # PD 全链路：40 个后端 + 代理 + 真实推理
#   bash scripts/health_check.sh --pd --no-chat # 跳过推理请求
#
# 分层原则（现场最容易踩的坑）：
#   1) 后端 /health  —— 引擎自身是否起来
#   2) 代理 /healthcheck —— 只反映注册了几个实例，不代表后端可用
#   3) /v1/models —— 服务面是否正常暴露
#   4) 真实 chat 请求 —— 唯一能证明 KV 传输链路通的一步
# 三层不过就不要往下测，否则只会看到"代理 200 但请求卡住"
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

load_config

MODE="$DEPLOY_MODE"
DO_CHAT=1
for a in "$@"; do
    case "$a" in
        --pd) MODE="pd" ;;
        --single) MODE="single" ;;
        --no-chat) DO_CHAT=0 ;;
        *) die "未知参数：$a" ;;
    esac
done

chat_test() {  # base_url model
    local url="$1" model="$2"
    local payload body code
    payload="{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"用一句话说明你是什么模型。\"}],\"temperature\":0,\"max_tokens\":64}"
    body=$(curl --noproxy '*' -sS -m 180 -w '\n%{http_code}' "$url/v1/chat/completions" \
        -H 'Content-Type: application/json' -d "$payload" 2>/dev/null) || true
    code=$(printf '%s' "$body" | tail -1)
    if [ "$code" = "200" ]; then
        ok "真实推理请求成功（$url）"
        printf '       %s\n' "$(printf '%s' "$body" | head -n -1 | head -c 400)"
    else
        err "真实推理失败（$url，HTTP $code）"
        printf '       %s\n' "$(printf '%s' "$body" | head -n -1 | head -c 400)"
    fi
}

if [ "$MODE" = "single" ]; then
    BASE="http://127.0.0.1:${SINGLE_PORT}"
    sect "1. 后端健康"
    wait_http "$BASE/health" 10 "HTTP /health" || true

    sect "2. 模型列表"
    models=$(http_get "$BASE/v1/models" 10 || true)
    if [ -n "$models" ]; then
        ok "/v1/models 可访问"
        printf '       %s\n' "$(printf '%s' "$models" | head -c 300)"
    else
        err "/v1/models 不可访问"
    fi

    if [ "$DO_CHAT" = "1" ]; then
        sect "3. 真实推理"
        chat_test "$BASE" "$SERVED_MODEL_NAME"
    fi

else
    pl=$(list_count "$PREFILL_NODES")
    dl=$(list_count "$DECODE_NODES")
    [ "$pl" -gt 0 ] && [ "$dl" -gt 0 ] || die "PD 模式需要 PREFILL_NODES / DECODE_NODES"

    proxy_host="${PROXY_NODE:-$(list_lines "$PREFILL_NODES" | head -1)}"
    total=0
    bad=0

    sect "1. Prefill 后端（每台 $PREFILL_DP_LOCAL 个）"
    for ip in $(list_lines "$PREFILL_NODES"); do
        for ((i = 0; i < PREFILL_DP_LOCAL; i++)); do
            p=$((PREFILL_BASE_PORT + i))
            total=$((total + 1))
            code=$(http_code "http://$ip:$p/health" 5)
            if [ "$code" = "200" ]; then
                printf '       %s[ OK ]%s %s:%s\n' "$C_GRN" "$C_RST" "$ip" "$p"
            else
                printf '       %s[FAIL]%s %s:%s (HTTP %s)\n' "$C_RED" "$C_RST" "$ip" "$p" "${code:-timeout}"
                bad=$((bad + 1))
            fi
        done
    done

    sect "2. Decode 后端（每台 $DECODE_DP_LOCAL 个）"
    for ip in $(list_lines "$DECODE_NODES"); do
        for ((i = 0; i < DECODE_DP_LOCAL; i++)); do
            p=$((DECODE_BASE_PORT + i))
            total=$((total + 1))
            code=$(http_code "http://$ip:$p/health" 5)
            if [ "$code" = "200" ]; then
                printf '       %s[ OK ]%s %s:%s\n' "$C_GRN" "$C_RST" "$ip" "$p"
            else
                printf '       %s[FAIL]%s %s:%s (HTTP %s)\n' "$C_RED" "$C_RST" "$ip" "$p" "${code:-timeout}"
                bad=$((bad + 1))
            fi
        done
    done

    printf '\n       后端合计 %d 个，异常 %d 个\n' "$total" "$bad"
    [ "$bad" -eq 0 ] && ok "全部后端 /health 通过" || err "$bad 个后端未就绪"

    sect "3. PD 代理"
    pbase="http://$proxy_host:$PROXY_PORT"
    pcode=$(http_code "$pbase/healthcheck" 5)
    if [ "$pcode" = "200" ]; then
        ok "代理 /healthcheck HTTP 200（注意：只代表注册数，不代表后端可用）"
        printf '       %s\n' "$(http_get "$pbase/healthcheck" 5 | head -c 300)"
    else
        err "代理不可用（HTTP ${pcode:-timeout}）"
    fi

    models=$(http_get "$pbase/v1/models" 10 || true)
    [ -n "$models" ] && ok "代理 /v1/models 可访问" || err "代理 /v1/models 不可访问"

    if [ "$DO_CHAT" = "1" ]; then
        sect "4. 真实推理（唯一能证明 KV 链路通的一步）"
        if [ "$bad" -gt 0 ]; then
            warn "仍有后端未就绪，推理大概率挂住，已跳过"
        else
            chat_test "$pbase" "$SERVED_MODEL_NAME"
        fi
    fi
fi

summary
