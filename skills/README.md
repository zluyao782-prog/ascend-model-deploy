# Skills

把仓库里现成的流程包成 Agent 能加载的 skill。目的很实际：下一个接手的人，或者 Agent 自己，不用先读完六篇文档也能把事做对。

## 里面没有部署代码

skill 里没有一行实现，全部调仓库里的脚本——`start.sh`、`stop.sh`、`_shared/preflight.sh`（`check.sh` 只在单机 / 1P1D / 2P2D 有，3P2D 精简版砍掉了）。它只干四件事：判断该走哪条路，拦住不该走的路，给出命令顺序，把踩过的坑写成禁令。

这样脚本改了，skill 跟着对，不用两边维护。skill 里如果出现一大段 bash，那说明该写的是仓库里的脚本，不是 skill。

## 现场什么样，skill 就约束成什么样

- **不联网。** 不 pull、不 pip、不 clone。镜像只能 `docker load`，权重只能本地挂载。破例的后果不是"慢一点"，是脚本跑到一半卡住，报一个跟真实原因毫无关系的网络错误。
- **不加构建层。** 没有 Makefile，没有命令别名，没有多层转发。现场最长的命令是 `bash start.sh`。
- **命令要看得见。** 那条 `vllm serve` 逐行列在 `serve.sh` 里，别用函数拼参数，也别包多层 `source`。改一个值应该在十秒内找到位置。

现场自己改得动的方案，优先于结构漂亮的方案。

## 六个 skill

| skill | 对应文档 | 管什么 | 什么时候用得上 |
|---|---|---|---|
| [ascend-env-preflight](ascend-env-preflight/) | `docs/01` | 环境体检、镜像准备、快照留证 | 「这台机器能跑吗」「镜像怎么弄进去」 |
| [ascend-deploy-single](ascend-deploy-single/) | `docs/02` | 单机 TP/DP 切分与三层验证 | 「单机起一个」「POC 验证」 |
| [ascend-deploy-pd](ascend-deploy-pd/) | `docs/03` | 拓扑、rank 推导、启动顺序、代理端点 | 「PD 分离」「pd-2p2d」 |
| [ascend-troubleshoot](ascend-troubleshoot/) | `docs/05` | 按现象定位根因 | 「卡住」「HCCL 报错」「代理 200 但超时」 |
| [ascend-perf-tuning](ascend-perf-tuning/) | `docs/04` | 参数取舍、单变量实验、基线记录 | 「怎么调快」「为什么慢」 |
| [ascend-model-onboarding](ascend-model-onboarding/) | `docs/06` | 新模型 / 新版本接入与评审 | 「加一个模型」「换镜像」 |

## 什么情况找哪个

```
要动机器之前
├─ 镜像还没导进去，或者不确定环境行不行   → ascend-env-preflight

要把服务起起来
├─ 只有一台机器                          → ascend-deploy-single
└─ 多台，要拆 P/D                        → ascend-deploy-pd
                                           （前提：单机已经跑通）

起不来，或者起来了不对
├─ 有明确报错或现象                      → ascend-troubleshoot
└─ 只是慢，功能正常                      → ascend-perf-tuning

要把某个模型变成仓库资产
└─ 新模型 / 新镜像版本                   → ascend-model-onboarding
```

顺序别跳：内网准备 → 预检 → 单机 → PD。单机能跑说明镜像、权重、CANN 都对上了，这时候再上 PD，多出来的变量只有网络和 KV 传输。

## 安装

```bash
# 本机所有项目可用
cp -r skills/ascend-* ~/.workbuddy/skills/

# 只在本仓库生效
mkdir -p .workbuddy/skills && cp -r skills/ascend-* .workbuddy/skills/
```

## 仓库脚本的分工

skill 会反复提到这几个文件，分工是固定的：

| 文件 | 谁改 | 说明 |
|---|---|---|
| `<形态>/config.env` | 现场实施 | 权重路径、节点 IP、拓扑、端口。基本只改这个 |
| `<形态>/serve.sh`、`run_p.sh`、`run_d.sh` | 调参的人 | tokenizer、parser、量化、投机解码、offload |
| `<形态>/start.sh` | 一般不动 | 前置检查 → `docker run` → 跟日志 |
| `<形态>/check.sh` | 一般不动 | 分层验证，退出码 0 才算通过（3P2D 没有，验证命令写在它的 README） |
| `<形态>/stop.sh` | 一般不动 | 删容器 |
| `_shared/preflight.sh`、`collect_env.sh` | 一般不动 | 可选的上现场体检和证据采集 |

## 加 skill 之前先想清楚

三条都满足再建：

1. 这个场景会反复出现，不是一次性的
2. 有顺序或者有禁令。顺序错了要返工，禁令破了要踩坑。纯粹的知识点写进 `docs/` 就够了
3. 能指向已有的脚本或文档，不用在 skill 里重写实现

## 维护

`config.env` 的字段名或脚本名变了，回头检查相关 skill 里的命令和判定闸。skill 里的禁令如果是某次事故换来的，最好在后面留一句原因，不然半年后会被当成教条删掉。结论失效了标 `DEPRECATED` 指向新结论，别直接删——跟 `docs/` 一个规矩。
