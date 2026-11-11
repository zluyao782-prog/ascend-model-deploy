#!/usr/bin/env bash
# =============================================================================
# Prefill 启动入口（P1 / P2 各执行一次）
#
#   ./start_p.sh              自动用本机 IP 匹配 P 组并推导 rank
#   ./start_p.sh <本机IP>     手动指定
#
# 顺序：先全部 Decode，再 P1 → P2，最后代理
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(cd "$HERE/../../.." && pwd)/_shared"

[ -f "$SHARED/lib/common.sh" ] || {
    echo "未找到 $SHARED/lib/common.sh" >&2
    echo "本目录需位于仓库内（<版本>/<模型>/<形态>）" >&2
    exit 1
}

ARGS=(--config "$HERE/config.env" --role prefill --template "$HERE/run_dp_template_p.sh")
[ -n "${1:-}" ] && ARGS+=(--ip "$1")
exec bash "$SHARED/pd/start_role.sh" "${ARGS[@]}"
