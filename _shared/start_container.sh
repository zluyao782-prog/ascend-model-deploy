#!/usr/bin/env bash
# =============================================================================
# start_container.sh —— 拉起 vLLM Ascend 容器
#
# 用法：
#   cd <版本>/<模型>/<部署形态> && bash ../../../_shared/start_container.sh
#   bash _shared/start_container.sh --config <部署目录>/config.env [--shell|--rebuild]
#
#   --shell    拉起后直接进入交互 shell
#   --rebuild  删除同名容器后重建
#
# 说明：在裸 docker run 基础上补了现场必备的几项加固，见下方注释
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"

MODE="run"
CFG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CFG="${2:-}"; shift 2 ;;
        --shell) MODE="shell"; shift ;;
        --rebuild) MODE="rebuild"; shift ;;
        -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "未知参数：$1（可选 --config / --shell / --rebuild）" ;;
    esac
done

load_config "$CFG"

have docker || die "未安装 docker"
[ -d "$MODEL_PATH" ] || die "权重目录不存在：$MODEL_PATH"

# ---------- 处理同名容器 ----------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    case "$MODE" in
        rebuild)
            info "删除旧容器 $CONTAINER_NAME"
            docker rm -f "$CONTAINER_NAME" >/dev/null
            ;;
        shell | run)
            if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
                warn "容器 $CONTAINER_NAME 已在运行，直接复用"
                if [ "$MODE" = "shell" ]; then
                    exec docker exec -it "$CONTAINER_NAME" bash
                fi
                exit 0
            fi
            info "启动已存在的容器 $CONTAINER_NAME"
            docker start "$CONTAINER_NAME" >/dev/null
            if [ "$MODE" = "shell" ]; then
                exec docker exec -it "$CONTAINER_NAME" bash
            fi
            exit 0
            ;;
    esac
fi

[ -n "${IMAGE:-}" ] || die "config 中 IMAGE 未设置"

# ---------- 设备与驱动挂载 ----------
DOCKER_ARGS=(
    --name "$CONTAINER_NAME"
    -d
    --ipc=host                    # 必需：多 DP rank 共享主机内存（Engram / SHM 场景）
    --network=host                # PD 分离需要跨节点直连，host 网络最省事
    --privileged                  # npu-smi / hccn_tool 需要
    --shm-size="$SHM_SIZE"
    --ulimit nofile=1048576:1048576   # 必需：默认 1024 会导致 HCCL 建链失败
    --ulimit memlock=-1
    -w "$WORKDIR_CTR"
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver
    -v /usr/local/dcmi:/usr/local/dcmi
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi
    -v /etc/ascend_install.info:/etc/ascend_install.info
    -v /etc/hccn.conf:/etc/hccn.conf
)

# 驱动路径不存在时跳过挂载，避免 docker 直接报错
for p in /usr/local/Ascend/driver /usr/local/dcmi /usr/local/bin/npu-smi /etc/ascend_install.info /etc/hccn.conf; do
    if [ ! -e "$p" ]; then
        warn "宿主机缺失 $p，已跳过该挂载"
        for i in "${!DOCKER_ARGS[@]}"; do
            if [ "${DOCKER_ARGS[$i]}" = "-v" ] && [ "${DOCKER_ARGS[$((i + 1))]}" = "$p:$p" ]; then
                unset 'DOCKER_ARGS[i]' 'DOCKER_ARGS[i+1]'
            fi
        done
    fi
done

# NPU 设备节点
n=$(npu_count)
if [ "$n" -gt 0 ] 2>/dev/null; then
    DOCKER_ARGS+=(--device=/dev/davinci_manager --device=/dev/devmm_svm --device=/dev/hisi_hdc)
    for ((i = 0; i < n; i++)); do
        if [ -e "/dev/davinci$i" ]; then
            DOCKER_ARGS+=(--device="/dev/davinci$i")
        fi
    done
    info "挂载 $n 张 NPU 设备节点"
else
    warn "未识别到 NPU，容器将以无卡模式启动（仅能验证镜像）"
fi

# 权重与工程目录
DOCKER_ARGS+=(-v "$MODEL_PATH:$MODEL_PATH")
DOCKER_ARGS+=(-v "$AE_ROOT:$WORKDIR_CTR")

# 额外挂载
if [ -n "${EXTRA_MOUNTS:-}" ]; then
    for m in $EXTRA_MOUNTS; do
        DOCKER_ARGS+=(-v "$m")
    done
fi

DOCKER_ARGS+=("$IMAGE" sleep infinity)

info "镜像: $IMAGE"
info "容器: $CONTAINER_NAME"
docker run "${DOCKER_ARGS[@]}" >/dev/null || die "docker run 失败"

# ---------- 拉起后自检 ----------
sleep 2
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" || die "容器未能保持运行，docker logs $CONTAINER_NAME 查看"

sect "容器内自检"
docker exec "$CONTAINER_NAME" bash -lc '
    echo "[npu-smi] $(npu-smi info -l 2>/dev/null | grep -c "NPU ID") NPU"
    echo "[nofile ] $(ulimit -n)"
    python3 -c "import vllm, torch, torch_npu; print(\"[vllm   ]\", vllm.__version__); print(\"[torch  ]\", torch.__version__); print(\"[npu    ]\", torch_npu.npu.device_count())" 2>&1 | sed "s/^/         /"
' || warn "容器内自检未全部通过"

ok "容器就绪：docker exec -it $CONTAINER_NAME bash"
info "工程目录已挂载到：$WORKDIR_CTR"

if [ "$MODE" = "shell" ]; then
    exec docker exec -it "$CONTAINER_NAME" bash
fi
