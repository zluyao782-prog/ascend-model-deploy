# Skills —— 仓库能力的 Agent 化封装

这个目录把仓库里已经沉淀好的流程，封装成可直接被 Agent 调用的 skill。目标只有一个：**让下一个接手的人（或 Agent）不用先读 6 篇文档，也能把事做对**。

## 三条硬约束（先看这个）

现场是一线同事在跑，大多在内网。写 skill、写脚本、给建议，都要满足这三条：

| 约束 | 具体含义 | 违反的样子 |
|---|---|---|
| **不联网** | 不 `docker pull`、不 `curl` 外网、不 `pip install`、不 `git clone`。镜像必须已 `docker load`，权重必须已在本地 | 脚本跑一半卡在拉镜像，报一个和真实原因无关的网络错误 |
| **不引入构建层** | 没有 Makefile、没有命令别名、没有多层转发。`bash start.sh` 是现场最长的命令 | 一线同事看不懂 `make up` 到底做了什么 |
| **命令要看得见** | 那条 `vllm serve` 就逐行列在 `serve.sh` / `run_*.sh` 里；参数不要用变量拼接藏起来 | 改一个参数要在三个文件之间跳 |

一句话：**能让现场自己改得动的方案，优先于抽象漂亮的方案。**

## 一条原则：skill 不复制实现

skill 里**没有一行部署实现**。所有动作都调用仓库里的脚本（`start.sh` / `check.sh` / `stop.sh` / `_shared/preflight.sh`）。skill 只负责：

- 判断该走哪条路径（并拦住不该走的路）；
- 给出确切的命令顺序；
- 说清每步的判定闸与退出码语义；
- 把"踩过才知道"的硬规则前置成禁令。

脚本改一次，所有 skill 自动跟着对。

## 六个 skill 与仓库能力域的对应

| Skill | 对应文档 | 管什么 | 典型触发 |
|---|---|---|---|
| [`ascend-env-preflight`](ascend-env-preflight/) | `docs/01` | 环境体检、内网镜像准备、快照留证 | 「这台机器能跑吗」「镜像怎么弄进去」 |
| [`ascend-deploy-single`](ascend-deploy-single/) | `docs/02` | 单机 TP/DP 切分与三层验证 | 「单机起一个」「POC 验证」 |
| [`ascend-deploy-pd`](ascend-deploy-pd/) | `docs/03` | 组网拓扑、rank 推导、启动顺序、代理 | 「PD 分离」「pd-2p2d」 |
| [`ascend-troubleshoot`](ascend-troubleshoot/) | `docs/05` | 按现象分流的根因定位 | 「卡住」「HCCL 报错」「代理 200 但超时」 |
| [`ascend-perf-tuning`](ascend-perf-tuning/) | `docs/04` | 参数取舍、单变量实验、基线记录 | 「怎么调快」「为什么慢」 |
| [`ascend-model-onboarding`](ascend-model-onboarding/) | `docs/06` | 新模型/新版本接入与评审 | 「加一个模型」「换镜像」 |

## 场景 → skill 路由

```
要动一台/一批机器之前
├─ 镜像还没导入 / 不确定环境行不行    → ascend-env-preflight

要把服务起起来
├─ 只有一台机器                      → ascend-deploy-single
└─ 多台、要拆 P/D                    → ascend-deploy-pd（前提：单机已跑通）

起不来 / 起来了不对
├─ 有明确报错或现象                  → ascend-troubleshoot
└─ 只是慢，功能正常                  → ascend-perf-tuning

要让某个模型成为仓库资产
└─ 新模型 / 新镜像版本               → ascend-model-onboarding
```

**顺序不可跳**：内网准备 → 预检 → 单机 → PD。单机能跑说明镜像、权重、CANN 三者匹配；此时再上 PD，新增的变量只有网络与 KV 传输。

## 仓库脚本的分工（skill 会反复引用）

| 文件 | 谁改 | 说明 |
|---|---|---|
| `<形态>/config.env` | 现场实施 | 权重路径、节点 IP、拓扑、端口。**唯一必改的文件** |
| `<形态>/serve.sh`、`run_p.sh`、`run_d.sh` | 调参的人 | 模型参数（parser / 量化 / 投机解码 / offload） |
| `<形态>/start.sh` | 基本不改 | 前置检查 → `docker run` → 跟日志 |
| `<形态>/check.sh` | 基本不改 | 分层验证，退出码 0 才算通过 |
| `<形态>/stop.sh` | 基本不改 | 删除容器 |
| `_shared/preflight.sh`、`collect_env.sh` | 基本不改 | 可选的上现场体检与证据采集 |

## 安装

```bash
# 1) 用户级：本机所有项目可用
cp -r skills/ascend-* ~/.workbuddy/skills/

# 2) 项目级：只在本仓库生效
mkdir -p .workbuddy/skills && cp -r skills/ascend-* .workbuddy/skills/
```

## 新增一个 skill 的判断标准

不是所有内容都值得做成 skill。满足以下三条才建：

1. **有明确的触发场景**，且这个场景会重复发生；
2. **有顺序或有禁令**——顺序错了会返工、禁令破了会踩坑。只是"知识点"的，写进 `docs/` 就够；
3. **能指向已有脚本或文档**，不需要在 skill 里重写实现。

反过来，如果发现自己要在 skill 里贴一大段 bash，那说明该写的是仓库里的脚本，不是 skill。

## 维护

- `config.env` 字段或脚本名变了，同步检查相关 skill 的命令与判定闸；
- skill 里的硬规则如果来自某次现场事故，在该条后面保留一句原因（否则半年后会被当成教条删掉）；
- 结论失效时标 `DEPRECATED` 并指向新结论，不要直接删——与 `docs/` 的弃用规则一致。
