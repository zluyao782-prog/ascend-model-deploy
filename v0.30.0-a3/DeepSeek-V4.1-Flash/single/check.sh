#!/bin/bash
# =============================================================================
# 验证单机服务能不能用：三层，逐层过
#
#   1. /health        引擎起来没有
#   2. /v1/models     服务面正常没有
#   3. 真实推理        真的能出字没有（唯一能证明可用的一步）
#
# 退出码 0 = 全过；1 = 有失败。不通过就不要往下压测。
#
# 注意：每处 curl 都带 --noproxy '*'。宿主机有 http_proxy 时，不带它
#       curl 会把 http://127.0.0.1 的请求发给代理，看到的是假故障。
# =============================================================================
cd "$(dirname "$0")"
. ./config.env

BASE="http://127.0.0.1:$SINGLE_PORT"
FAIL=0

echo "== 1. 引擎健康 /health"
if curl --noproxy '*' -fsS -m 10 "$BASE/health" >/dev/null 2>&1; then
    echo "   [ OK ] $BASE/health"
else
    echo "   [FAIL] $BASE/health 不通（还在加载？看日志： docker logs -f $CONTAINER_NAME）"
    FAIL=1
fi

echo "== 2. 模型列表 /v1/models"
if curl --noproxy '*' -fsS -m 10 "$BASE/v1/models" | grep -q "$SERVED_MODEL_NAME"; then
    echo "   [ OK ] 已暴露模型 $SERVED_MODEL_NAME"
else
    echo "   [FAIL] /v1/models 里没有 $SERVED_MODEL_NAME"
    FAIL=1
fi

echo "== 3. 真实推理 /v1/chat/completions"
ANSWER=$(curl --noproxy '*' -sS -m 180 "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$SERVED_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"用一句话介绍你自己。\"}],\"max_tokens\":64}" \
    2>/dev/null | head -c 300)
if echo "$ANSWER" | grep -q '"content"'; then
    echo "   [ OK ] 推理成功"
    echo "        $ANSWER"
else
    echo "   [FAIL] 推理失败或没有返回内容"
    echo "        ${ANSWER:-（无响应）}"
    FAIL=1
fi

echo
if [ "$FAIL" = "0" ]; then
    echo "全部通过。"
else
    echo "有失败项，先看模型 README 的《排错》一节，别急着加并发。"
fi
exit "$FAIL"
