#!/usr/bin/env bash
# =============================================================================
# stop.sh —— 停止服务 / 容器
#
# 用法：
#   bash ../../../_shared/stop.sh              # 停容器（服务随之结束）
#   bash ../../../_shared/stop.sh --services   # 只杀 vllm / 代理进程，保留容器
#   bash ../../../_shared/stop.sh --purge      # 停容器并删除（留下镜像）
#   可加 --config <部署目录>/config.env
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

MODE="container"
CFG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CFG="${2:-}"; shift 2 ;;
        --services | services) MODE="services"; shift ;;
        --purge | purge) MODE="purge"; shift ;;
        -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

load_config "$CFG"

if [ "$MODE" = "--services" ] || [ "$MODE" = "services" ]; then
    sect "停止推理服务（保留容器）"
    pat='vllm serve|launch_online_dp|load_balance_proxy_server_example'
    if have vllm; then
        pkill -f "$pat" 2>/dev/null && ok "已发送 TERM" || info "无匹配进程"
    else
        docker exec "$CONTAINER_NAME" bash -lc "pkill -f '$pat'" 2>/dev/null \
            && ok "已发送 TERM（容器内）" || info "容器内无匹配进程"
    fi
    sleep 3
    # 残留则强杀
    if have vllm; then
        pkill -9 -f "$pat" 2>/dev/null || true
    else
        docker exec "$CONTAINER_NAME" bash -lc "pkill -9 -f '$pat'" 2>/dev/null || true
    fi
    info "查残留： ps -ef | grep -E 'vllm|launch_online_dp' | grep -v grep"
    exit 0
fi

sect "停止容器"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    docker stop "$CONTAINER_NAME" >/dev/null && ok "已停止 $CONTAINER_NAME"
else
    info "容器 $CONTAINER_NAME 未在运行"
fi

if [ "$MODE" = "--purge" ] || [ "$MODE" = "purge" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 && ok "已删除容器" || true
fi
