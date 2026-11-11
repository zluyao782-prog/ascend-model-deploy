# =============================================================================
# 昇腾模型部署工具包 —— 快捷入口
# 说明：所有能力都有对应的 bash scripts/*.sh，Make 只是方便记忆
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help init preflight up shell single pd-p pd-d proxy check env stop clean

help: ## 显示帮助
	@echo "昇腾模型部署工具包"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "首次使用： make init  →  编辑 config/env  →  make preflight"

init: ## 由模板生成 config/env
	@if [ -f config/env ]; then \
		echo "config/env 已存在，跳过（如需重置： rm config/env）"; \
	else \
		cp config/env.example config/env && echo "已生成 config/env，请编辑 MODEL_PATH / IMAGE / NIC_NAME"; \
	fi

preflight: ## 环境体检
	@bash scripts/preflight.sh

up: ## 拉起容器
	@bash scripts/start_container.sh

shell: ## 进入容器
	@bash scripts/start_container.sh --shell

single: ## 单机部署
	@bash scripts/serve_single.sh

pd-p: ## 启动本机 Prefill 角色
	@bash scripts/pd/start_role.sh prefill

pd-d: ## 启动本机 Decode 角色
	@bash scripts/pd/start_role.sh decode

proxy: ## 启动 PD 代理（先 --dry-run 核对端点）
	@python3 scripts/pd/start_proxy.py --dry-run
	@python3 scripts/pd/start_proxy.py

check: ## 健康自检
	@bash scripts/health_check.sh

env: ## 采集环境快照
	@bash scripts/collect_env.sh

stop: ## 停止容器
	@bash scripts/stop.sh

clean: ## 清理本地运行产物（保留 config/env）
	@rm -rf .run logs artifacts .tools/*.py
	@echo "已清理 .run / logs / artifacts / .tools"
