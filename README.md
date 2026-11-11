# 昇腾模型部署脚本库

团队共享的 **vLLM Ascend 部署脚本与实战记录**。一个镜像版本一个目录，版本下面按模型分，模型下面按部署形态（单机 / 组网）分，形态目录里是可以直接跑、也可以整目录复制到现场的脚本。

解决的问题很实际：同一个模型每换一次现场就重写一遍脚本，同一个坑每个人踩一遍。这里的原则是——**脚本只写一次，经验写进 README，坑写进排错文档**。

## 三条写脚本的原则

现场执行的是一线同事，不是专职脚本开发。所以：

1. **一个文件只做一件事，命令写在能看见的地方。** `serve.sh` / `run_p.sh` / `run_d.sh` 里就是那条 `vllm serve`，参数逐行列出来，不藏在函数和变量拼接里。改参数就改这几行。
2. **配置只描述"这一次部署"。** 权重路径、节点 IP、拓扑、端口放 `config.env`；通用逻辑不写进配置，模型参数不写进配置。
3. **不联网、不猜、不半路失败。** 内网环境没有外网：不 `docker pull`、不下载、不 `pip install`。所有前置条件在脚本开头一次性检查完，缺什么就直接说缺什么，不要跑到一半才报网络错误。

不需要 `make`，不需要记命令别名。每个目录就四五个 `.sh`，`bash start.sh` 是最长的命令。

## 目录约定

```
ascend-model-deploy/
├── README.md                     本文件：规则总纲
├── CONTRIBUTING.md               提交规范与评审清单
├── _shared/                      可选工具：上现场前的环境体检与证据采集（不参与部署）
├── docs/                         通用知识：预检、调优、排错、模型接入
├── skills/                       Agent 可加载的流程封装（只路由，不含实现）
│
└── <镜像版本>/                    例：v0.30.0-a3
    ├── README.md                 该版本的版本信息与模型清单
    └── <模型名>/                  例：DeepSeek-V4.1-Flash
        ├── README.md             ★ 该模型的部署讲解（必填）
        ├── single/               单机形态
        │   ├── config.env        现场唯一要改的文件
        │   ├── serve.sh          那条 vllm serve 命令
        │   ├── start.sh          检查 + 起容器 + 跟日志
        │   ├── check.sh          服务能不能用
        │   └── stop.sh
        └── pd-2p2d/              组网形态（拓扑不同就再开一个目录）
            ├── config.env
            ├── start.sh          按角色起： prefill | decode | proxy
            ├── run_p.sh          Prefill 单个引擎的命令
            ├── run_d.sh          Decode 单个引擎的命令
            ├── check.sh
            └── stop.sh
```

每个形态目录里的分工是固定的：

| 文件 | 谁来看 | 什么时候改 |
|---|---|---|
| `config.env` | 现场实施 | **每个现场都要改**：权重路径、节点 IP、拓扑、端口 |
| `serve.sh` / `run_*.sh` | 调参的人 | 模型参数（parser、量化、投机解码、offload）变了才改 |
| `start.sh` / `check.sh` / `stop.sh` | 基本不看 | 换机型、挂载方式变了才改，平时原样用 |

## 部署形态（禁止混用）

形态目录名即拓扑声明，**不同形态的写法不得互相套用**：

| 形态目录 | 官方参考位置 | 关键差异（必须在脚本中体现） |
|---|---|---|
| `single/` | 官方「单节点共置部署」章节 | 单机内 P/D 同进程共置，**不是分离**；不需要 KV 传输、不需要 RoCE；DP/TP 在同一台机器内划分 |
| `pd-<P>p<D>/` | `examples/disaggregated_prefill_v1/` | P / D 各自独立 `dp` / `tp` / `pcp`；Mooncake KV 连接器；`PROMPT_DEVICE_ID` / `DECODE_DEVICE_ID`；proxy 端点列表长度必须等于 P+D 实例数 |
| `pd-colocated/`（如新增） | 同 PD，单机内划分卡组 | 同机 P/D 分组，**端口段不得重叠**；`gpu-memory-utilization` 按卡算而非整机 |

几条硬约束：

- **拓扑变了就新开目录**，不要在同一个 `config.env` 里加 `if` 分支；`pd-1p1d` 与 `pd-2p2d` 是两份资产；
- **A2 与 A3 镜像 tag 不通用**，换硬件系列新建版本目录，不要混用；
- `single/` 里的参数集是单机最优解，直接搬到 PD 会掉性能甚至起不来；P / D 两侧同理，**不合并**。

## 已收录

| 镜像版本 | 硬件 | 模型 | 形态 |
|---|---|---|---|
| [v0.30.0-a3](v0.30.0-a3/) | Atlas 800 A3 | [DeepSeek-V4.1-Flash](v0.30.0-a3/DeepSeek-V4.1-Flash/) | 单机（16 卡）/ PD 2P2D（4 台） |

## 内网部署：先准备镜像和权重

现场没有外网，这两件事必须**提前**做完，脚本不会替你下载任何东西。

```bash
# 1. 在有网的机器上导出镜像，拷到现场
docker save quay.io/ascend/vllm-ascend:v0.30.0-a3 -o vllm-ascend-v0.30.0-a3.tar

# 2. 每台现场机器导入（脚本会检查，没导入就停在这一步，不会去 pull）
docker load -i vllm-ascend-v0.30.0-a3.tar
docker images | grep vllm-ascend

# 3. 权重预下载到宿主机，只读方式挂进容器（不要在容器里在线拉）
#    ModelScope 下载时必须带 --revision，不要用默认 master
```

权重目录要求：**每台机器同一绝对路径**，宿主机与容器内路径一致。

## 快速开始

单机（1 台 16 卡）：

```bash
cd v0.30.0-a3/DeepSeek-V4.1-Flash/single
vim config.env        # 改 MODEL_PATH / IMAGE / NIC_NAME 三项
bash start.sh         # 检查环境 → 起容器 → 跟日志
bash check.sh         # 另开窗口：验证能不能真推理
```

PD 分离（4 台，2P2D）：

```bash
cd v0.30.0-a3/DeepSeek-V4.1-Flash/pd-2p2d
vim config.env        # 4 台用同一份：节点 IP、拓扑、权重路径

bash start.sh decode    # 每个 Decode 节点，D1 先
bash start.sh prefill   # 每个 Prefill 节点，P1 先
bash start.sh proxy     # 代理节点，等后端全绿
bash check.sh           # 任意能访问代理的机器
```

顺序不可颠倒：**Decode 全组 → Prefill 全组 → 代理**。任何一步没全绿就往下走，请求会挂在 KV 传输上而不是报错。

## 验证与交付标准

"脚本能起来"不等于"能交付"。交付判定标准是 **`check.sh` 退出码为 0**，分层逐级通过：

| 层 | 内容 |
|---|---|
| 1 环境 | `bash _shared/preflight.sh`（可选但建议）：`npu-smi`、可见卡数、driver/CANN、nofile、网卡、端口 |
| 2 容器与进程 | 容器在跑、引擎进程数符合预期、端口都在监听 |
| 3 服务健康 | 单机 `GET /health`；PD 逐个后端 `GET /health` |
| 4 真实推理 | 一次 `/v1/chat/completions`；PD 还要经代理走一遍（唯一能证明 P→D KV 传输通的一步） |

**输出与退出码统一**：

```
[ OK ] 10.0.0.21:7100
[FAIL] 10.0.0.21:7115

退出码 0 = 全过，1 = 有失败
```

**就绪闸（PD 强制）**：`start.sh proxy` 会先逐个检查后端 `/health`，有一个没起来就拒绝启动。代理的 `/healthcheck` 只反映"注册了多少实例"，不代表后端可用——先起 proxy 后起引擎，客户端必然收到 `All connection attempts failed` 或长时间挂住。这一条是现场踩出来的，不要再踩。

## 新增一个模型

**复制一个已经跑通的模型目录**，不要从零写：

```bash
cp -r v0.30.0-a3/DeepSeek-V4.1-Flash v0.30.0-a3/<新模型名>
cd v0.30.0-a3/<新模型名>
```

然后按顺序做五件事：

1. 改 `single/config.env` 与 `pd-*/config.env`：权重路径、拓扑、端口、节点 IP
2. 改 `single/serve.sh` 与 `pd-*/run_p.sh`、`run_d.sh` 里的模型参数（tokenizer / parser / 量化 / 投机解码 / offload）——**这是唯一需要懂模型的地方**
3. 删掉不需要的形态目录，不要留空目录占位
4. 实际跑通：`start.sh` → `check.sh` → 长上下文 + 并发压测
5. 写 `<模型>/README.md` 六节，其中「踩过的坑」没写完不要提交

## 新增一个镜像版本

换硬件系列（A2 ↔ A3）或大版本升级时，复制整个版本目录：

```bash
cp -r v0.30.0-a3 v0.30.0-a2-next
# 再把 config.env 里的 IMAGE 换成新 tag，逐台 docker load 新镜像
```

已跑通的旧版本目录**保持原样不动**——现场环境五花八门，旧版本随时可能被重新用到。

## 版本与硬件锚定（强制）

"能跑"的前提是**知道跑的是什么**。每个版本目录的 `README.md` 与每个形态脚本的头部注释，必须锁定以下全部信息：

| 项 | 要求 |
|---|---|
| 镜像锚点 | `quay.io/ascend/vllm-ascend@sha256:<digest>`；无法用 digest 时用 `tag` + 拉取日期。**tag 会被重推**，同一 tag 今天拉和三个月后拉可能不是同一层 |
| 镜像内 CANN | 容器内 `cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg` 的**实测**输出 |
| 宿主驱动 | `npu-smi info` 的 Driver / Firmware 版本，须满足镜像要求（不满足会在容器里表现为"找不到设备"） |
| 软件栈 | `vllm --version`、`vllm-ascend`、`torch-npu`、Python 的实测版本号 |
| 硬件拓扑 | 机型（Atlas 800T A2 / A3）、节点数、单机卡数、单卡 HBM、节点内/跨节点互联 |
| 参考文档 | vLLM-Ascend 文档的**版本化 URL**，或 tag `vX.Y.Z` + commit sha |
| 参考代码 | `<repo>/blob/<tag>/examples/<file>`，必要时附该文件的 commit sha |
| 权重锚点 | ModelScope `model_id` + `--revision <tag>` + 量化格式（`w8a8` / `w4a8` / BF16） |

三条纪律：

1. 官方文档与 GitHub `main` 不一致时，**以锁定版本的官方文档为准**，并在模型 README 里注明分支差异；
2. 不凭经验放宽或收紧版本依赖；
3. 版本信息必须是**实测输出**，不是抄来的——PR 里贴一段 `npu-smi info` + `vllm --version` + `version.cfg` 的原始输出，比写"已验证"有说服力得多。

## 模型下载与权重校验

1. 优先 **ModelScope**；离线 / 内网环境**先预下载到宿主机，再只读挂载进容器**，禁止容器内在线拉取；
2. **必须显式 `--revision`**，禁止默认 `master`——不同时间拉到的权重不同，复现性直接失效；
3. 下载后校验，写进 `config.env` 的前置注释或 `start.sh` 检查：

| 检查项 | 做法 |
|---|---|
| 完整性 | 文件数与总大小与模型仓库页面一致 |
| 量化格式 | `config.json` 的量化字段与 `quant_model_description.json` 同时存在且一致 |
| 版本一致 | P / D / 各节点挂载的路径完全相同，`revision` 相同 |
| 可读性 | 容器内 `ls <MODEL_PATH>/*.safetensors \| wc -l` 与预期一致 |

> `w4a8` 被误挂成 `w8a8`（或反之）是最隐蔽的一类故障：服务能起、结果出得来，但精度与性能全部错位。这条校验不要省。

## 配置与可变项

- `config.env` 只描述"**这一次部署**怎么起"，通用能力与模型参数不写进去；
- 每个字段带一行注释，说明"为什么是这个值"而不是"这是什么"：

```bash
DECODE_DP_LOCAL=16     # 16 引擎 × TP1 = 16 卡，刚好占满 A3
```

- 脚本正文不出现硬编码的 IP / 路径；确需保留时注释标注「**需按实际环境修改**」；
- `start.sh` 开头一次性检查前置条件（镜像在不在、权重在不在、卡数够不够、端口占没占），缺项当场退出并指名缺哪个；
- 卡数一致性：`可见卡数 == DP_LOCAL × TP × PCP`，不匹配在启动前就退出——这是 HCCL 卡死最常见的前置原因；
- 禁止提交凭证 / Token / 客户真实密码。`config.env` 随仓库提交以便复现，因此只能放占位 IP。

## 性能基线

每个模型目录必须记录一次可复现的基线，写在模型 README 或 `docs/`：

| 字段 | 说明 |
|---|---|
| 硬件与拓扑 | 机型 / 节点数 / 卡数 |
| 并行配置 | `dp` / `tp` / `pcp` / EP / 是否开投机解码 |
| 负载 | 输入长度 / 输出长度 / 并发数 / 请求总数 |
| 指标 | TTFT（P90）、TPOT（P90）、输出 tok/s、总吞吐 |
| 工具 | `vllm bench serve` 或 AISBench，附完整命令 |

不开基线，下游就无法区分"升级后变慢"和"本来就这样"。调优类 PR 必须附前/后两组数据。

## 踩坑与排错沉淀

坑的归宿只有三处，按影响范围选：`docs/05-troubleshooting.md`（通用）、模型 README「踩过的坑」（模型专属）、脚本头部注释（代码级规避）。

每条记录固定五字段：

```markdown
### <一句话症状，便于搜索>

- 症状: 完整报错关键行（原样粘贴，不要改写）
- 触发条件: 机型 / 卡数 / 形态 / 并发
- 根因: 为什么会这样
- 处置: 可执行步骤
- 适用版本: 镜像 tag + CANN + vllm-ascend 版本
```

> **「适用版本」是必填项。** 不带版本结论的踩坑记录，半年后就是误导。结论失效时在标题前标 `DEPRECATED` 并指向新结论，不要直接删除。

## 通用文档

| 文档 | 内容 |
|---|---|
| [01 环境准备与预检](docs/01-preflight.md) | 硬件软件基线、11 类检查项、端口规划、内网镜像准备 |
| [02 单机部署](docs/02-single-node.md) | 最简路径，验证镜像与权重 |
| [03 PD 分离部署](docs/03-pd-disaggregation.md) | 拓扑设计、启动顺序、代理端点、一致性约束 |
| [04 关键参数与调优](docs/04-tuning.md) | TP/DP 算法、性能参数相互作用、调优实验方法 |
| [05 排错手册](docs/05-troubleshooting.md) | 按现象分流的排查路径 |
| [06 新模型接入检查清单](docs/06-model-onboarding.md) | 换模型前必过的一遍 |

## 复用能力（skills）

`skills/` 把上面这些流程封装成 Agent 可加载的 skill。skill 只做判断与约束，**所有动作都调用本仓库的脚本**，不另写一套。

| Skill | 管什么 |
|---|---|
| [env-preflight](skills/ascend-env-preflight/) | 环境体检、容器加固、快照留证 |
| [deploy-single](skills/ascend-deploy-single/) | 单机 TP/DP 切分与三层验证 |
| [deploy-pd](skills/ascend-deploy-pd/) | 组网拓扑、rank 推导、启动顺序、代理端点 |
| [troubleshoot](skills/ascend-troubleshoot/) | 按现象分流的根因定位 |
| [perf-tuning](skills/ascend-perf-tuning/) | 参数取舍、单变量实验、基线记录 |
| [model-onboarding](skills/ascend-model-onboarding/) | 新模型 / 新镜像版本接入与评审 |

安装与路由表见 [skills/README.md](skills/README.md)。**顺序不可跳**：预检 → 单机 → PD。

## 弃用与归档

- 已跑通的旧版本目录**保留**，只在其 `README.md` 顶部注明状态（`维护中` / `仅存档` / `已被 <新版本> 取代`）；
- 参数、结论过期的，标 `DEPRECATED` + 取代关系，**不直接删**；
- 每季度清理一次：确认无人引用后再物理删除。

> 不写这条，半年后仓库会变成考古现场，没人敢判断哪份才是当前的。

## 设计约定

1. **脚本自包含**：形态目录里的脚本不依赖别的脚本仓库外的文件，整目录拷到现场就能跑。可读性优先于复用——现场改得动比抽象漂亮重要。
2. **不引入构建层**：没有 Makefile、没有命令别名、没有多层转发。`bash start.sh` 就是全部。
3. **配置进目录**：每个部署形态一个 `config.env`，只描述"这一套怎么起"。
4. **官方脚本不落库**：`launch_online_dp.py`、代理脚本直接从镜像里执行，不复制进仓库，避免版本漂移。
5. **P/D 不合并**：两侧参数集角色特定，混用会掉性能甚至起不来，宁可两份文件带互斥注释。
6. **README 是交付物**：脚本能跑只是及格，能让人三个月后照着 README 再跑一遍才算完成。
7. **变更可回退**：性能相关改动必须附前/后基线，否则视为未验证。

## 参考资源

- vLLM Ascend 官方文档：<https://docs.vllm.ai/projects/ascend/zh-cn/latest/getting_started/overview.html>
- vLLM-Ascend GitHub：<https://github.com/vllm-project/vllm-ascend>
- 模型下载（ModelScope）：<https://modelscope.cn/models>
- 昇腾社区（驱动 / CANN 版本配套表）：<https://www.hiascend.com/>

> 引用官方文档时请带版本段（`/zh-cn/<version>/`），`latest` 会滚动更新，无法作为锚点。

---

## 本文件与 CONTRIBUTING 的分工

| 文件 | 管什么 |
|---|---|
| `README.md`（本文件） | **规则总纲**：目录结构、形态区分、内网准备、验证标准、基线、踩坑、弃用 |
| `CONTRIBUTING.md` | **执行细则**：命名规范、`config.env` 写法、脚本骨架、commit 前缀、评审勾选 |

两者冲突时以本文件为准，并同步修正 `CONTRIBUTING.md`。
