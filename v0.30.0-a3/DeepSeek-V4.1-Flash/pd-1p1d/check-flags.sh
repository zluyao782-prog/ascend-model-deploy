#!/bin/bash
# =============================================================================
# 检查模板里的 vllm 参数，这台镜像到底认不认
#
#   bash check-flags.sh
#
# 换镜像版本后先跑一次。不认识的参数会让引擎在启动时 unrecognized arguments，
# 而那时你可能已经等了半小时。这里几秒钟就能全部列出来。
#
# 退出码：0 全部支持；非 0 = 不支持的个数
# =============================================================================
cd "$(dirname "$0")"
. ./config.env

FILES=$(ls serve.sh run_p.sh run_d.sh 2>/dev/null)
[ -n "$FILES" ] || { echo "当前目录没有 serve.sh / run_p.sh / run_d.sh"; exit 1; }

# 只取行首的 --参数，避开注释里提到的名字
FLAGS=$(grep -hoE '^[[:space:]]*--[a-z0-9-]+' $FILES | tr -d ' ' | sort -u)

echo "镜像： $IMAGE"
echo "参数： $(echo $FLAGS | wc -w) 个（来自 $FILES）"
echo "拉一次 vllm serve -h ..."
HELP=$(docker run --rm "$IMAGE" vllm serve -h 2>&1)

bad=0
for f in $FLAGS; do
    if ! echo "$HELP" | grep -q -- "$f"; then
        echo "  ✗ $f"
        bad=$((bad + 1))
    fi
done

echo
if [ "$bad" = "0" ]; then
    echo "这些参数这台镜像都支持。"
else
    echo "有 $bad 个参数这台镜像不支持，把模板里对应的行删掉再启动。"
    echo "注意：参数行都以 \\ 结尾，要删整行——注释掉会把下一行一起吞掉。"
fi
exit "$bad"
