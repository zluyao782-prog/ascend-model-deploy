# =============================================================================
# PD 2P2D 部署快捷入口（实现都在 ../../../_shared）
# 顺序：up → fetch → d → p → proxy → check
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help
SHARED := ../../../_shared
CFG := config.env

.PHONY: help preflight up fetch d p proxy check env stop clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

preflight: ## 环境体检（多机建议加 ALL=1 走 ssh）
	@bash $(SHARED)/preflight.sh --config $(CFG) $(if $(ALL),--all,)

up: ## 拉起容器（每台各执行一次）
	@bash $(SHARED)/start_container.sh --config $(CFG)

fetch: ## 从镜像提取官方 launcher 与代理脚本
	@bash $(SHARED)/pd/fetch_official.sh --config $(CFG)

d: ## 启动本机 Decode 角色
	@bash ./start_d.sh

p: ## 启动本机 Prefill 角色
	@bash ./start_p.sh

proxy: ## 启动 PD 代理（先 dry-run）
	@bash ./start_proxy.sh --dry-run
	@bash ./start_proxy.sh -d

check: ## 分层自检（全部后端 + 代理 + 推理）
	@bash $(SHARED)/health_check.sh --config $(CFG) --pd

env: ## 采集环境快照
	@bash $(SHARED)/collect_env.sh --config $(CFG)

stop: ## 停止容器
	@bash $(SHARED)/stop.sh --config $(CFG)

clean: ## 清理运行产物
	@rm -rf logs .run artifacts
