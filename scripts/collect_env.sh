#!/usr/bin/env bash
# =============================================================================
# collect_env.sh —— 一键采集环境快照（排错 / 反馈用）
#
# 用法：
#   bash scripts/collect_env.sh              # 采集到 artifacts/env-<时间戳>.tar.gz
#   bash scripts/collect_env.sh --nodes      # 额外 ssh 采集 P/D 其他节点（需免密）
#
# 采集内容刻意避开权重正文与任何密钥，只收版本、拓扑、日志片段。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

load_config

TS=$(date +%Y%m%d-%H%M%S)
OUT="$AE_ROOT/artifacts/env-$TS"
mkdir -p "$OUT"
export OUT

ALL_NODES=0
[ "${1:-}" = "--nodes" ] && ALL_NODES=1

grab() {  # 标题 命令...
    local title="$1"; shift
    {
        echo "### $title"
        echo "\$ $*"
        "$@" 2>&1 | head -200
        echo
    } >>"$OUT/env.txt"
}

sect "采集环境快照 → $OUT"

grab "时间"            date
grab "主机名"          hostname
grab "内核"            uname -a
grab "发行版"          bash -c 'cat /etc/os-release 2>/dev/null'
grab "NPU 概览"        npu-smi info -l
grab "NPU 详情"        npu-smi info
grab "驱动版本"        bash -c 'cat /usr/local/Ascend/driver/version.info 2>/dev/null'
grab "CANN 版本"       bash -c 'cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg 2>/dev/null'
grab "内存"            free -g
grab "磁盘"            df -h
grab "句柄限制"        bash -c 'ulimit -a'
grab "网卡"            ip -o addr show
grab "路由"            ip route
grab "MTU"             bash -c 'for i in /sys/class/net/*/mtu; do echo "$i $(cat $i)"; done'
grab "监听端口"        bash -c 'ss -lntp 2>/dev/null'
grab "hccn 配置"       bash -c 'cat /etc/hccn.conf 2>/dev/null'
grab "docker 容器"     docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
grab "docker 版本"     docker --version
grab "容器内版本"      bash -c "docker exec $CONTAINER_NAME bash -lc 'python3 -c \"import vllm,torch,torch_npu;print(vllm.__version__,torch.__version__,torch_npu.__version__)\"' 2>&1"
grab "dmesg 尾"        bash -c 'dmesg 2>/dev/null | tail -50'

# 进程与日志片段
grab "vllm 进程" bash -c 'ps -eo pid,etime,rss,cmd | grep -E "vllm|launch_online_dp|load_balance_proxy" | grep -v grep'

for f in "$AE_ROOT"/logs/*.log "$AE_ROOT"/.run/*/log/*.log; do
    [ -f "$f" ] || continue
    cp -f "$f" "$OUT/$(echo "${f#$AE_ROOT/}" | tr '/' '_')" 2>/dev/null || true
done

# 配置（脱敏：去掉可能含 token/password 的行后缀）
if [ -f "$AE_CONFIG" ]; then
    sed -E 's/(TOKEN|PASSWORD|SECRET|KEY)=.*/\1=***/I' "$AE_CONFIG" >"$OUT/config.sanitized" 2>/dev/null || true
fi

cp -f "$AE_ROOT/config/env.example" "$OUT/" 2>/dev/null || true

# 其他节点
if [ "$ALL_NODES" = "1" ] && [ "$DEPLOY_MODE" = "pd" ]; then
    for ip in $(list_lines "$PREFILL_NODES $DECODE_NODES"); do
        if ssh -o BatchMode=yes -o ConnectTimeout=3 "$ip" true 2>/dev/null; then
            ssh -o BatchMode=yes "$ip" 'npu-smi info; free -g; ss -lnt' >"$OUT/remote-$ip.txt" 2>&1 || true
            ok "已采集 $ip"
        else
            warn "$ip 无法免密 ssh，跳过"
        fi
    done
fi

TAR="$AE_ROOT/artifacts/env-$TS.tar.gz"
tar -czf "$TAR" -C "$AE_ROOT/artifacts" "env-$TS" 2>/dev/null || die "打包失败"
rm -rf "$OUT"

ok "快照： $TAR"
info "体积： $(du -h "$TAR" | awk '{print $1}')"
