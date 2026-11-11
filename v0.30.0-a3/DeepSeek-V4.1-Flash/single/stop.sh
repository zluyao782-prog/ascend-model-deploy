#!/bin/bash
# 停止单机服务：删除容器（服务随之结束）
cd "$(dirname "$0")"
. ./config.env

if docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "已停止 $CONTAINER_NAME"
else
    echo "$CONTAINER_NAME 不存在，无需停止"
fi
