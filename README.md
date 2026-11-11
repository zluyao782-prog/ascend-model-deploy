# 昇腾模型部署工具包（ascend-model-deploy）

面向 **Atlas 800 / Atlas 800 A2·A3** 的 vLLM Ascend 模型部署脚手架：把「环境体检 → 拉起容器 → 单机 / PD 分离部署 → 分层自检 → 现场排错」固化成可复用脚本，换模型只改配置，不重写流程。

> 目标不是再写一份官方文档的复述，而是把每次现场都会踩的坑前置成脚本检查项：文件句柄、共享内存、DP rank 推导、KV 端口、健康检查的层次、启动顺序。

## 这套东西解决什么

| 现场常见问题 | 本项目的对策 |
|---|---|
| 容器 `nofile=1024` 导致 HCCL 建链失败，日志只有 WARNING | `start_container.sh` 强制 `--ulimit nofile=1048576`，`preflight.sh` 提前检查 |
| 多机 PD 的 DP rank 靠手工数，改拓扑就错 | `start_role.sh` 由「本机 IP → 节点序号 → rank 起点」自动推导 |
| 40 个后端端点手写列表，host/port 长度不一致代理直接退出 | `start_proxy.py` 由配置生成端点，`--dry-run` 可先核对 |
| 代理 `/healthcheck` 200 但请求挂住 | `health_check.sh` 分四层：后端 `/health` → 代理 → `/v1/models` → 真实推理 |
| 大模型加载慢，误判为"挂了" | `VLLM_ENGINE_READY_TIMEOUT_S` 显式配置，默认不调小 |
| 每换一个模型就复制一套脚本，越堆越乱 | 单机 / PD 共用一份 `config/env`，模型差异只在模板与参数 |

## 目录结构

```
ascend-model-deploy/
├── config/
│   └── env.example              配置模板（复制为 config/env 后修改，已被 gitignore）
├── scripts/
│   ├── lib/common.sh            公共函数（日志、计数、端口、HTTP 等待）
│   ├── preflight.sh             部署前环境体检（11 类检查项）
│   ├── start_container.sh       拉起 vLLM Ascend 容器（含现场加固）
│   ├── serve_single.sh          单机多卡部署
│   ├── health_check.sh          分层健康自检
│   ├── collect_env.sh           一键环境快照（排错/反馈）
│   ├── stop.sh                  停止服务 / 容器
│   └── pd/
│       ├── start_role.sh        按角色启动本机 DP 引擎组
│       ├── run_dp_template_p.sh Prefill 单 rank 模板（角色特定）
│       ├── run_dp_template_d.sh Decode  单 rank 模板（角色特定）
│       ├── start_proxy.py       PD 代理启动器（自动生成端点）
│       └── fetch_official.sh    从镜像提取官方脚本到 .tools/
├── docs/
│   ├── 01-preflight.md          环境准备与预检
│   ├── 02-single-node.md        单机部署
│   ├── 03-pd-disaggregation.md  PD 分离部署
│   ├── 04-tuning.md             关键参数与调优
│   ├── 05-troubleshooting.md    排错手册
│   └── 06-model-onboarding.md   新模型接入检查清单
├── examples/
│   └── deepseek-v41-flash/      DeepSeek-V4.1-Flash A3 2P2D 实测配置
├── Makefile                     快捷入口（make help）
└── .gitignore / .gitattributes
```

## 快速开始

```bash
# 0. 生成配置
make init                       # 等价于 cp config/env.example config/env
vim config/env                  # 至少改 MODEL_PATH / IMAGE / NIC_NAME

# 1. 体检（每台机器都跑一次，比出问题后再查便宜得多）
make preflight

# 2. 拉起容器（所有节点各执行一次）
make up

# 3A. 单机多卡
make single                     # 后台启动 + 等 /health
make check                      # 分层自检

# 3B. PD 分离
bash scripts/pd/fetch_official.sh       # 首次：提取官方 launcher 与代理
make pd-d                       # 所有 Decode 节点（先 D1 再 D2）
make pd-p                       # 所有 Prefill 节点（先 P1 再 P2）
make proxy                      # 代理节点
make check                      # 40 后端 + 代理 + 真实推理
```

## 两种部署模式

| | 单机（single） | PD 分离（pd） |
|---|---|---|
| 适用 | 通用对话、单机可容纳的模型 | 长 prompt / 高并发、P 与 D 资源配比有讲究的场景 |
| 脚本入口 | `serve_single.sh` | `start_role.sh` + `start_proxy.py` |
| 拓扑表达 | `SINGLE_TP` / `SINGLE_DP` | `*_NODES` + `*_DP_LOCAL`，全局 DP 自动相乘 |
| 生产建议 | 可直接用 | 官方明确 PD 示例**仅供验证/评测**；生产走 MindIE Motor + vLLM Ascend |

## 配置要点

配置文件 `config/env` 分六段：模型 / 镜像与容器 / 硬件与网络 / 运行模式 / 单机 / PD / 推理参数，每项都有注释。最容易被忽略的三个：

- **`MODEL_PATH`**：多机必须**同一绝对路径**，且宿主机与容器内一致，否则各 rank 加载的分片对不上。
- **`NIC_NAME`**：HCCL / Gloo 绑定的业务网口，不是管理口。填错的表现通常不是报错，而是多机集合通信卡死。
- **`PREFILL_DP_LOCAL` / `DECODE_DP_LOCAL`**：单台机器上的引擎数。全局 DP = 单台 × 节点数，脚本自动算，不用手填。

## 设计约定

1. **官方脚本不落库**：`launch_online_dp.py`、`load_balance_proxy_server_example.py` 由 `fetch_official.sh` 从镜像提取到 `.tools/`（已 gitignore），避免版本漂移。
2. **P/D 模板不合并**：两边参数集是角色特定的，混用会掉性能甚至起不来，宁可两份文件带注释互斥。
3. **检查项先失败**：脚本遇到会必然导致失败的前置条件（端口占用、权重缺失、容器未起）直接 `die`，不"带病继续"。
4. **配置不进版本库**：`config/env` 含现场 IP 与路径，模板保留在 `env.example`。

## 已验证环境

| 项 | 取值 |
|---|---|
| 硬件 | Atlas 800 A3（64G × 16 逻辑设备）× 4 台，2P2D |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 案例模型 | DeepSeek-V4.1-Flash-1017-w4a8（见 `examples/`） |
| 拓扑 | Prefill DP8（本地 4 × 2 台，PCP4 / TP1）+ Decode DP32（本地 16 × 2 台，TP1） |

其他硬件 / 模型请按 `docs/06-model-onboarding.md` 走一遍检查清单，再改 `examples/` 下新增目录适配。

## 许可与边界

本项目只包含**部署流程与配置**，不包含模型权重、CANN 驱动、vLLM Ascend 源码与其官方示例脚本（这些随镜像分发）。使用前请确认符合对应上游许可。

---
维护：FAE 现场沉淀。遇到新坑请补进 `docs/05-troubleshooting.md`，比记在聊天记录里可靠。
