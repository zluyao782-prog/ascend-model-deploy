#!/usr/bin/env bash
# =============================================================================
# fetch_official.sh —— 从镜像内提取官方脚本到 .tools/
#
# 需要两个官方文件（不随本项目分发，避免版本漂移）：
#   launch_online_dp.py                        —— DP 多机启动器
#   load_balance_proxy_server_example.py       —— PD 负载均衡代理
#
# 镜像内常见路径：
#   /vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/
#   /vllm-workspace/vllm-ascend/examples/offline_disaggregated_prefill/
#
# 用法：
#   bash scripts/pd/fetch_official.sh              # 自动探测（在容器内或宿主机均可）
#   bash scripts/pd/fetch_official.sh --path DIR   # 指定镜像内目录
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/common.sh"

load_config

TOOLS="$AE_ROOT/.tools"
mkdir -p "$TOOLS"

SEARCH_DIR=""
if [ "${1:-}" = "--path" ] && [ -n "${2:-}" ]; then
    SEARCH_DIR="$2"
fi

# 在容器内执行的探测脚本
PROBE='
set -u
DIR="${1:-}"
TARGETS="launch_online_dp.py load_balance_proxy_server_example.py"
if [ -n "$DIR" ]; then
    SEARCH_ROOTS="$DIR"
else
    SEARCH_ROOTS="/vllm-workspace /usr/local/lib/python3*/site-packages /opt"
fi
for t in $TARGETS; do
    found=""
    for r in $SEARCH_ROOTS; do
        found=$(find $r -name "$t" -type f 2>/dev/null | head -1)
        [ -n "$found" ] && break
    done
    if [ -n "$found" ]; then
        echo "FOUND $t $found"
    else
        echo "MISS  $t"
    fi
done
'

sect "探测官方脚本"
if have vllm || [ -d /vllm-workspace ]; then
    OUT=$(bash -c "$PROBE" _ "$SEARCH_DIR")
else
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" \
        || die "容器 $CONTAINER_NAME 未运行且本机无镜像环境，先执行： make up"
    OUT=$(docker exec "$CONTAINER_NAME" bash -c "$PROBE" _ "$SEARCH_DIR")
fi

printf '%s\n' "$OUT"

# 逐个复制
missing=0
while read -r tag name path; do
    case "$tag" in
        FOUND)
            if have vllm || [ -d /vllm-workspace ]; then
                cp -f "$path" "$TOOLS/$name"
            else
                docker cp "$CONTAINER_NAME:$path" "$TOOLS/$name" >/dev/null
            fi
            ok "$name  ←  $path"
            ;;
        MISS)
            warn "$name 未找到"
            missing=$((missing + 1))
            ;;
    esac
done <<<"$OUT"

if [ "$missing" -gt 0 ]; then
    cat <<'TIP'

       未找到的脚本可手动定位：
         docker exec -it <容器> bash -lc 'find / -name launch_online_dp.py 2>/dev/null'
       通常位于 vllm-ascend 源码树 examples/ 下，确认镜像版本包含 PD 示例。
TIP
    [ -f "$TOOLS/launch_online_dp.py" ] || exit 1
fi

chmod +x "$TOOLS"/*.py 2>/dev/null || true
ok "已就绪：$TOOLS"
