#!/usr/bin/env bash
# =============================================================================
# preflight.sh —— 部署前环境体检
#
# 用法：
#   cd <版本>/<模型>/<部署形态> && bash ../../../_shared/preflight.sh
#   bash _shared/preflight.sh --config v0.30.0-a3/DeepSeek-V4.1-Flash/single/config.env
#
#   --all   额外 ssh 探测其他节点（需已配免密）
#
# 退出码：0 全部通过（警告不算失败）；1 存在 FAIL 项
# 原则：能在部署前发现的问题，绝不留到压测现场
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

CHECK_ALL=0
CFG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CFG="${2:-}"; shift 2 ;;
        --all) CHECK_ALL=1; shift ;;
        -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

load_config "$CFG"

printf '%s昇腾部署预检%s  模式=%s  模型=%s\n' "$C_BLD" "$C_RST" "$DEPLOY_MODE" "${MODEL_NAME:-$SERVED_MODEL_NAME}"

# ---------------------------------------------------------------- 1. 操作系统
sect "1. 操作系统与内核"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "发行版: ${PRETTY_NAME:-unknown}"
    case "${ID:-}" in
        ubuntu | debian | openEuler | kylin | centos | openeuler) ok "发行版在 Ascend 支持列表内" ;;
        *) warn "发行版 ${ID:-unknown} 未在常见支持列表，确认驱动有对应包" ;;
    esac
else
    warn "无法读取 /etc/os-release"
fi
info "内核: $(uname -r)  架构: $(uname -m)"
huge=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' || true)
[ -n "$huge" ] && info "THP: $huge"

# ---------------------------------------------------------------- 2. NPU 与驱动
sect "2. NPU 与驱动"
if ! have npu-smi; then
    err "npu-smi 不存在，驱动未安装或未加入 PATH"
    hint "检查 /usr/local/Ascend/driver，必要时重装驱动+固件"
else
    n=$(npu_count)
    if [ "$n" -gt 0 ] 2>/dev/null; then
        ok "识别到 NPU 数量: $n"
    else
        err "未识别到 NPU 设备"
    fi

    if [ "$NPU_COUNT" != "auto" ] && [ "$n" != "$NPU_COUNT" ] 2>/dev/null; then
        err "NPU 数量 $n 与配置 NPU_COUNT=$NPU_COUNT 不符"
    fi

    # 逐卡健康状态：vLLM 只 WARNING 不退出，必须提前看
    unhealthy=$(npu-smi info 2>/dev/null | grep -ciE 'error|warning|alarm' || true)
    if [ "${unhealthy:-0}" -gt 0 ]; then
        warn "npu-smi 输出含 ${unhealthy} 处 error/warning 字样，人工核对"
        hint "npu-smi info  →  关注 Health / Alarm 列"
    else
        ok "各卡健康状态无明显告警"
    fi

    drv=$(npu-smi info -t board -i 0 2>/dev/null | grep -iE 'Version|版本' | head -4 || true)
    [ -n "$drv" ] && info "驱动/固件: $(echo "$drv" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 3. CANN
sect "3. CANN 工具包"
CANN_VER=""
for vf in /usr/local/Ascend/ascend-toolkit/latest/version.cfg \
          /usr/local/Ascend/ascend-toolkit/latest/*/ascend_toolkit_install.info; do
    if [ -r "$vf" ]; then
        CANN_VER=$(grep -iE '^version|^Version' "$vf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ')
        [ -n "$CANN_VER" ] && break
    fi
done
if [ -n "$CANN_VER" ]; then
    ok "CANN: $CANN_VER"
else
    warn "未解析到 CANN 版本；确认 /usr/local/Ascend/ascend-toolkit/latest 存在"
fi

# ---------------------------------------------------------------- 4. 容器运行时
sect "4. 容器运行时"
if have docker; then
    ok "docker: $(docker --version 2>/dev/null | cut -d, -f1)"
    docker info >/dev/null 2>&1 && ok "docker daemon 可访问" || err "docker daemon 不可访问（权限或未启动）"
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        warn "同名容器已存在：$CONTAINER_NAME（重建请先 make down）"
    fi
else
    err "未安装 docker"
fi

# ---------------------------------------------------------------- 5. 权重与磁盘
sect "5. 权重与磁盘"
if [ -d "$MODEL_PATH" ]; then
    sz=$(du -sh "$MODEL_PATH" 2>/dev/null | awk '{print $1}')
    ok "权重目录存在：$MODEL_PATH（$sz）"
    nf=$(ls "$MODEL_PATH"/*.safetensors 2>/dev/null | wc -l | tr -d ' ')
    [ "$nf" -gt 0 ] && info "safetensors 分片数: $nf"
    [ -r "$MODEL_PATH/config.json" ] && ok "config.json 可读" || warn "缺少 config.json，确认是完整 HF 格式权重"
else
    err "权重目录不存在：$MODEL_PATH"
    hint "4 台机器必须同一绝对路径，且与容器内路径一致"
fi

disk_free=$(df -BG "$MODEL_PATH" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ -n "$disk_free" ]; then
    if [ "$disk_free" -lt "$DISK_MIN_GB" ] 2>/dev/null; then
        err "权重盘剩余 ${disk_free}G < 要求 ${DISK_MIN_GB}G"
    else
        ok "权重盘剩余 ${disk_free}G"
    fi
fi

# ---------------------------------------------------------------- 6. 内存
sect "6. 主机内存与共享内存"
mem_gb=$(free -g 2>/dev/null | awk 'NR==2 {print $2}')
[ -z "$mem_gb" ] && mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null)
if [ -z "$mem_gb" ]; then
    warn "无法读取内存信息（free 与 /proc/meminfo 均不可用）"
elif [ -n "$mem_gb" ]; then
    if [ "$mem_gb" -lt "$HOST_MEM_MIN_GB" ] 2>/dev/null; then
        err "内存 ${mem_gb}G < 要求 ${HOST_MEM_MIN_GB}G"
        hint "大模型 cpu_offload / 图捕获都吃主机内存，别只看显存"
    else
        ok "内存 ${mem_gb}G（要求 ≥ ${HOST_MEM_MIN_GB}G）"
    fi
fi
shm_kb=$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')
if [ -n "$shm_kb" ]; then
    shm_gb=$((shm_kb / 1024 / 1024))
    if [ "$shm_gb" -lt 32 ]; then
        warn "/dev/shm 仅 ${shm_gb}G；容器需 --shm-size 或 --ipc=host"
    else
        ok "/dev/shm ${shm_gb}G"
    fi
fi

# ---------------------------------------------------------------- 7. 文件句柄
sect "7. 文件句柄限制"
nofile=$(ulimit -n)
if [ "$nofile" -lt 1048576 ] 2>/dev/null; then
    warn "当前 nofile=$nofile；容器内小于 1048576 易触发 HCCL 建链失败"
    hint "启动脚本已加 --ulimit nofile=1048576:1048576，宿主机也建议同步"
else
    ok "nofile=$nofile"
fi

# ---------------------------------------------------------------- 8. 网络
sect "8. 通信网卡"
if ! have ip; then
    warn "ip 命令不可用（iproute2 未安装），跳过网卡检查"
    hint "dnf/yum install iproute  或  apt install iproute2"
elif ip link show "$NIC_NAME" >/dev/null 2>&1; then
    state=$(ip -o link show "$NIC_NAME" | awk -F'[,:]' '{print $3}' | tr -d ' ')
    mtu=$(cat "/sys/class/net/$NIC_NAME/mtu" 2>/dev/null)
    ipaddr=$(ip -4 -o addr show "$NIC_NAME" 2>/dev/null | awk '{print $4}' | head -1)
    if [ "$state" = "UP" ]; then
        ok "$NIC_NAME UP  地址=${ipaddr:-none}  MTU=$mtu"
    else
        err "$NIC_NAME 状态 $state（应为 UP）"
    fi
    if [ -n "$mtu" ] && [ "$mtu" -lt 4200 ] 2>/dev/null; then
        warn "MTU=$mtu 偏小，RoCE 场景建议 4200/9000"
    fi
else
    err "网卡 $NIC_NAME 不存在"
    info "可用网卡: $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 9. 端口
sect "9. 端口占用"
portcheck() {
    if port_busy "$1"; then
        err "端口 $1 已被占用（$2）"
    else
        ok "端口 $1 空闲（$2）"
    fi
}
if [ "$DEPLOY_MODE" = "single" ]; then
    portcheck "$SINGLE_PORT" "单机服务端口"
else
    pl=$(list_count "$PREFILL_NODES"); dl=$(list_count "$DECODE_NODES")
    [ "$pl" -gt 0 ] || err "PREFILL_NODES 为空"
    [ "$dl" -gt 0 ] || err "DECODE_NODES 为空"

    local_ip=$(hostname -I 2>/dev/null || true)
    if echo " $local_ip " | grep -qE " ($PREFILL_NODES|$DECODE_NODES) "; then
        portcheck "$DP_RPC_PORT" "DP 协调"
        portcheck "$PREFILL_BASE_PORT" "Prefill 引擎起点"
        portcheck "$DECODE_BASE_PORT" "Decode 引擎起点"
        portcheck "$PROXY_PORT" "PD 代理"
    else
        info "本机不在 PD 节点列表内，跳过端口检查"
    fi
fi

# ---------------------------------------------------------------- 10. 跨节点
if [ "$CROSS_NODE" = "1" ] && [ "$DEPLOY_MODE" = "pd" ]; then
    sect "10. 跨节点连通性"
    all_nodes="$PREFILL_NODES $DECODE_NODES"
    local_ip=$(hostname -I 2>/dev/null || true)
    for ip in $(list_lines "$all_nodes"); do
        if echo " $local_ip " | grep -q " $ip "; then
            ok "$ip 是本机，跳过"
            continue
        fi
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            ok "$ip ping 通"
        else
            err "$ip ping 不通"
        fi
        if [ "$CHECK_ALL" = "1" ] && have ssh; then
            if ssh -o BatchMode=yes -o ConnectTimeout=3 "$ip" true 2>/dev/null; then
                ok "$ip ssh 免密可用"
                remote_np=$(ssh -o BatchMode=yes "$ip" 'npu-smi info -l 2>/dev/null | grep -c "NPU ID"' 2>/dev/null)
                [ -n "$remote_np" ] && info "$ip NPU 数: $remote_np"
            else
                warn "$ip ssh 免密不可用（--all 需要）"
            fi
        fi
    done
    hint "HCCL 建链还需 hccn_tool 校验：hccn_tool -i 0 -link -g（每卡逐一看）"
fi

# ---------------------------------------------------------------- 11. 侧信道
sect "11. 其他"
[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" ] && \
    warn "存在代理环境变量，容器内访问本机服务需 curl --noproxy '*'" || ok "无代理环境变量干扰"
if have nproc; then info "CPU 核数: $(nproc)"; fi

summary
