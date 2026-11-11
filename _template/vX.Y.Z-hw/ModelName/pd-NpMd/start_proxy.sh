#!/usr/bin/env bash
# =============================================================================
# PD 代理启动入口（在代理节点执行，默认复用 P1）
#
#   ./start_proxy.sh --dry-run   先核对端点数量（应等于 本地DP × 节点数）
#   ./start_proxy.sh             前台启动
#   ./start_proxy.sh -d          后台启动，日志 logs/proxy.log
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(cd "$HERE/../../.." && pwd)/_shared"
CFG="$HERE/config.env"

[ -f "$SHARED/pd/start_proxy.py" ] || {
    echo "未找到 $SHARED/pd/start_proxy.py" >&2
    exit 1
}

if [ "${1:-}" = "-d" ]; then
    mkdir -p "$HERE/logs"
    nohup python3 "$SHARED/pd/start_proxy.py" --config "$CFG" >"$HERE/logs/proxy.log" 2>&1 </dev/null &
    echo "已后台启动 pid=$!，日志： $HERE/logs/proxy.log"
    echo "验证： bash ../../../../_shared/health_check.sh"
    exit 0
fi

exec python3 "$SHARED/pd/start_proxy.py" --config "$CFG" "$@"
