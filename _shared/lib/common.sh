#!/usr/bin/env bash
# =============================================================================
# lib/common.sh —— 公共函数库
# 由上层脚本 source，不要直接执行
# =============================================================================
set -o pipefail

AE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AE_ROOT

# ---------- 颜色（非终端或设置 NO_COLOR 时自动关闭） ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi

AE_PASS=0
AE_WARN=0
AE_FAIL=0

info()  { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; AE_PASS=$((AE_PASS + 1)); }
warn()  { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; AE_WARN=$((AE_WARN + 1)); }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; AE_FAIL=$((AE_FAIL + 1)); }
die()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
hint()  { printf '       %s↳ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
sect()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

# ---------- 配置加载 ----------
# 用法： load_config                  # 取 ./config.env（部署目录内执行）
#        load_config <path>           # 显式指定
#        AE_CONFIG=<path> load_config
load_config() {
    local cfg="${1:-${AE_CONFIG:-}}"
    if [ -z "$cfg" ] && [ -f ./config.env ]; then
        cfg="$PWD/config.env"
    fi
    if [ -z "$cfg" ]; then
        die "未找到配置文件
       在部署目录内执行（目录下有 config.env），或显式指定：
         bash _shared/preflight.sh --config <部署目录>/config.env"
    fi
    [ -f "$cfg" ] || die "配置文件不存在：$cfg"
    AE_CONFIG="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
    export AE_CONFIG
    AE_DEPLOY_DIR="$(dirname "$AE_CONFIG")"
    export AE_DEPLOY_DIR

    set -a
    # shellcheck disable=SC1090
    . "$AE_CONFIG"
    set +a

    : "${DEPLOY_MODE:=single}"
    export DEPLOY_MODE

    [ -n "${MODEL_PATH:-}" ] || die "config 中 MODEL_PATH 未设置"
    [ -n "${SERVED_MODEL_NAME:-}" ] || SERVED_MODEL_NAME="$(basename "$MODEL_PATH")"
    export SERVED_MODEL_NAME

    : "${NIC_NAME:=eth0}"
    : "${CONTAINER_NAME:=ascend-deploy}"
    : "${WORKDIR_CTR:=/opt/ascend-model-deploy}"
    : "${SHM_SIZE:=64g}"
    export NIC_NAME CONTAINER_NAME WORKDIR_CTR SHM_SIZE
}

# ---------- 基础工具 ----------
have() { command -v "$1" >/dev/null 2>&1; }

npu_count() {
    local n
    n=$(npu-smi info -l 2>/dev/null | grep -c 'NPU ID' || true)
    if [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; then
        n=$(ls -d /dev/davinci[0-9]* 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf '%s' "${n:-0}"
}

port_busy() {
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

http_get() {
    curl --noproxy '*' -fsS -m "${2:-5}" "$1" 2>/dev/null
}

http_code() {
    curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m "${2:-5}" "$1" 2>/dev/null
}

wait_http() {  # url timeout_s label
    local url="$1" t="${2:-60}" label="${3:-$url}" i=0
    while [ "$i" -lt "$t" ]; do
        if http_get "$url" 3 >/dev/null; then
            ok "$label"
            return 0
        fi
        i=$((i + 3))
        sleep 3
    done
    err "$label（等待 ${t}s 未就绪）"
    return 1
}

# 列表工具：把 "a b c" 按行展开
list_lines() {
    local s="${1:-}"
    # shellcheck disable=SC2086
    printf '%s\n' $s | sed '/^[[:space:]]*$/d'
}

list_count() {
    list_lines "$1" | wc -l | tr -d ' '
}

# 汇总 + 退出码
summary() {
    printf '\n%s汇总%s  通过 %s%d%s  警告 %s%d%s  失败 %s%d%s\n' \
        "$C_BLD" "$C_RST" \
        "$C_GRN" "$AE_PASS" "$C_RST" \
        "$C_YEL" "$AE_WARN" "$C_RST" \
        "$C_RED" "$AE_FAIL" "$C_RST"
    [ "$AE_FAIL" -eq 0 ] || exit 1
}

# ---------- 容器内/外执行 ----------
# 若当前环境本身有 vllm（已在容器内），直接执行；否则 docker exec 进容器
in_env() {
    if have vllm; then
        "$@"
        return
    fi
    local ct="${CONTAINER_NAME:-ascend-deploy}"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$ct" \
        || die "容器 $ct 未运行，先执行： make up"
    local cmd
    cmd=$(printf '%q ' "$@")
    docker exec -i "$ct" bash -lc "$cmd"
}
