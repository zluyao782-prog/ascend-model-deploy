# =============================================================================
# 单机部署快捷入口（所有实现都在 ../../../_shared，这里只做管道）
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help
SHARED := ../../../_shared
CFG := config.env

.PHONY: help preflight up single shell check env stop clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

preflight: ## 环境体检
	@bash $(SHARED)/preflight.sh --config $(CFG)

up: ## 拉起容器
	@bash $(SHARED)/start_container.sh --config $(CFG)

single: ## 启动单机服务
	@bash ./start.sh

shell: ## 进入容器
	@bash $(SHARED)/start_container.sh --config $(CFG) --shell

check: ## 分层健康自检
	@bash $(SHARED)/health_check.sh --config $(CFG)

env: ## 采集环境快照
	@bash $(SHARED)/collect_env.sh --config $(CFG)

stop: ## 停止容器
	@bash $(SHARED)/stop.sh --config $(CFG)

clean: ## 清理运行产物
	@rm -rf logs .run artifacts
