#!/usr/bin/env bash
# =============================================================================
# Decode 启动入口（D1 / D2 各执行一次）
#
#   ./start_d.sh              自动用本机 IP 匹配 D 组并推导 rank
#   ./start_d.sh <本机IP>     手动指定
#
# 顺序：先全部 Decode（D1 → D2），再 Prefill，最后代理
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(cd "$HERE/../../.." && pwd)/_shared"

[ -f "$SHARED/lib/common.sh" ] || {
    echo "未找到 $SHARED/lib/common.sh" >&2
    echo "本目录需位于仓库内（<版本>/<模型>/<形态>）" >&2
    exit 1
}

ARGS=(--config "$HERE/config.env" --role decode --template "$HERE/run_dp_template_d.sh")
[ -n "${1:-}" ] && ARGS+=(--ip "$1")
exec bash "$SHARED/pd/start_role.sh" "${ARGS[@]}"
