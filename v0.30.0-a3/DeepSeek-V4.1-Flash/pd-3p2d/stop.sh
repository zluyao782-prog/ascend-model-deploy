#!/bin/bash
# 停止本机所有容器：master / prefill / decode / proxy 各一个
cd "$(dirname "$0")"
. ./config.env

found=0
for role in master prefill decode proxy; do
    if docker rm -f "$CONTAINER_NAME-$role" >/dev/null 2>&1; then
        echo "已停止 $CONTAINER_NAME-$role"
        found=1
    fi
done

[ "$found" = "1" ] || echo "本机没有在跑的容器（$CONTAINER_NAME-{master,prefill,decode,proxy}）"
