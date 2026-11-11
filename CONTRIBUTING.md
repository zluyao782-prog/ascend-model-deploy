# 贡献指南

这个仓库是团队共用的现场资产，几条约定减少互相踩脚。

## 一、目录与命名

| 层 | 命名 | 例 |
|---|---|---|
| 镜像版本 | `v<版本>-<硬件系列>` | `v0.30.0-a3`、`v0.28.0-a2` |
| 模型 | 与官方模型名一致（大小写、连字符保持原样） | `DeepSeek-V4.1-Flash`、`Qwen3-32B` |
| 部署形态 | `single` / `pd-<P数量>p<D数量>` | `pd-2p2d`、`pd-1p3d` |

- 一个模型一个目录，一个形态一个子目录。**拓扑变了就新开目录**，不要在同一个 `config.env` 里加分支。
- 不需要的形态删掉，不留空目录。
- 别在模型目录里放权重、日志、截图大文件（`.gitignore` 已挡一部分）。

## 二、每个模型 README 必填内容

模型目录下的 `README.md` 是交付物的一部分，缺了视为没做完。至少包含：

1. **模型与版本**：参数量、结构特点、推荐权重名、镜像 tag（精确到 tag）
2. **硬件与拓扑**：几台、几卡、P/D 如何分工、端口规划
3. **配置要点**：哪些字段必须改、为什么
4. **启动步骤**：可直接复制执行的命令，含顺序要求
5. **关键参数**：模型私有参数（tokenizer / parser / 量化 / offload）及取值理由
6. **踩过的坑**：现象 + 根因 + 规避方式

第 6 项最有价值。三个月后接手的人（可能是你自己）只想知道这个。

## 三、`config.env` 规范

- 只写**这一次部署**需要的东西：权重路径、节点 IP、拓扑、端口、模型私有参数。
- 通用能力（预检、容器、健康检查）不写进配置，那些由 `_shared/` 提供。
- 每个字段带一行注释，说明"为什么是这个值"而不是"这是什么"。
  ```bash
  DECODE_DP_LOCAL=16     # 16 引擎 × TP1 = 16 卡，刚好占满 A3
  ```
- 不提交真实内网 IP 之外的敏感信息；如含 token，提交前删掉。

## 四、脚本规范

新增脚本请遵守以下几条，与现有代码保持一致：

```bash
#!/usr/bin/env bash
set -euo pipefail                       # 或 set -uo pipefail（需要收集多个失败时）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/<相对路径>/lib/common.sh"

CFG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CFG="${2:-}"; shift 2 ;;
        -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done
load_config "$CFG"
```

- 一律支持 `--config`，默认回落 `./config.env`，这样在部署目录里直接跑也能用。
- 用 `_shared/lib/common.sh` 的 `info / ok / warn / err / die`，不要另造日志格式。
- 遇到必然失败的前置条件（端口占用、权重缺失、容器未起）直接 `die`，不要带病继续。
- 不加 `sudo`、不改系统配置、不清用户数据。脚本只做部署该做的事。
- 新能力优先加进 `_shared/`，被多个模型复用的东西不要复制到模型目录。

提交前自检：

```bash
bash -n <脚本>            # 语法
shellcheck <脚本>         # 有条件就跑
python -m py_compile <脚本.py>
```

## 五、提交流程

```bash
git checkout -b feat/<模型或版本>-<形态>
# ... 改动
git add -A
git commit -m "feat(<版本>/<模型>): 新增 <形态> 部署"
git push origin HEAD
```

commit 前缀沿用：`feat`（新增模型/形态）、`fix`（修脚本或参数）、`docs`（补 README/排错）、`chore`（目录调整）。

## 六、评审清单

合并前逐条确认：

- [ ] 目标硬件上**实际跑通**，不是"看起来能跑"
- [ ] `preflight.sh` 无 FAIL 项，WARN 项有解释
- [ ] `health_check.sh` 分层全过（含真实推理请求）
- [ ] 长上下文请求成功、并发压测 10 分钟显存无爬升
- [ ] 模型 `README.md` 六项内容齐全
- [ ] `config.env` 每个字段有"为什么"的注释
- [ ] 没提交权重、日志、`.tools/` 里的官方脚本
- [ ] Shell 脚本可执行位正确（`git ls-files -s` 看得到 `100755`）
