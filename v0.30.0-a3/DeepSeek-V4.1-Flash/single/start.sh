#!/usr/bin/env bash
# =============================================================================
# 单机启动入口 —— DeepSeek-V4.1-Flash @ Atlas 800 A3 ×1
#
#   ./start.sh              后台启动，等 /health 就绪
#   ./start.sh --foreground 前台启动，便于观察加载过程
#   ./start.sh --ip <ip>    预留：单机不需要，保持接口一致
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(cd "$HERE/../../.." && pwd)/_shared"

[ -f "$SHARED/lib/common.sh" ] || {
    echo "未找到 $SHARED/lib/common.sh" >&2
    echo "本目录需位于仓库内（<版本>/<模型>/<形态>），或把 _shared 一并拷贝" >&2
    exit 1
}

exec bash "$SHARED/serve_single.sh" --config "$HERE/config.env" "$@"
