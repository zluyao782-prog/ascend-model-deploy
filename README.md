# 昇腾模型部署脚本

团队自己在用的 vLLM Ascend 部署脚本和现场记录。一个镜像版本一个目录，下面按模型分，模型下面按部署形态（单机 / 组网）分。形态目录里的东西可以整包拷到现场直接用。

做这个仓库的原因很朴素：同一个模型，每换一个现场就得重写一遍脚本；同一个坑，每个人轮流踩。现在分工很清楚：脚本写一次放这儿，经验写进各自 README，排错路径写进 docs。

## 目录长这样

```
ascend-model-deploy/
├── _shared/        上现场前的体检和证据采集（可选，不参与部署）
├── docs/           通用知识：预检、调优、排错、接新模型
├── skills/         给 Agent 用的流程封装，只有判断和约束，不含实现
└── v0.30.0-a3/     一个镜像版本
    ├── README.md
    └── DeepSeek-V4.1-Flash/
        ├── README.md
        ├── single/   config.env  serve.sh  start.sh  check.sh  stop.sh
        ├── pd-1p1d/  config.env  start.sh  run_p.sh  run_d.sh  check.sh  stop.sh
        └── pd-2p2d/  config.env  start.sh  run_p.sh  run_d.sh  check.sh  stop.sh
```

进到某个形态目录，要改的基本只有 `config.env`。模型参数在 `serve.sh` / `run_p.sh` / `run_d.sh` 里，打开就是一条 `vllm serve`，参数一行一个。`start.sh`、`check.sh`、`stop.sh` 平时不用动。

## 三种形态

| 目录 | 官方参考 | 要注意的地方 |
|---|---|---|
| `single/` | 官方「单节点共置部署」 | 单机内 P/D 同进程共置，不是分离。不需要 KV 传输，不需要 RoCE |
| `pd-<P>p<D>/` | `examples/disaggregated_prefill_v1/` | P、D 各自独立 dp/tp/pcp；走 Mooncake；proxy 端点列表长度必须等于 P+D 的实例数 |
| `pd-colocated/`（如果要加） | 同 PD | 单机内分卡组，端口段不能重叠，`gpu-memory-utilization` 按卡算 |

`pd-1p1d/` 和 `pd-2p2d/` 现在都有：前者两台各跑一个角色，后者每侧两台。每台的引擎配比是一样的，所以 `run_p.sh` / `run_d.sh` 两份文件内容相同，扩缩容只改 `config.env` 的节点列表和 `*_DP_LOCAL`。

有几个地方是栽过跟头的：

- 拓扑变了就新开目录。`pd-1p3d` 和 `pd-2p2d` 是两份资产，不要在一个 `config.env` 里加 `if`。
- A2 和 A3 的镜像 tag 不通用，换硬件系列就新建版本目录。
- `single/` 的参数是单机的最优解，搬到 PD 会掉性能，有些直接起不来。P 和 D 两侧同理。

## 内网现场：先把镜像和权重搬进去

现场基本没有外网，脚本里也没有任何下载动作。这两样得提前准备好，否则卡在半路，报的错还跟真实原因没关系。

镜像在有网的机器上导出，拷过去：

```bash
docker save quay.io/ascend/vllm-ascend:v0.30.0-a3 -o vllm-ascend-v0.30.0-a3.tar
```

每台现场机器导入：

```bash
docker load -i vllm-ascend-v0.30.0-a3.tar
docker images | grep vllm-ascend
```

`start.sh` 第一步就是查本地有没有这个镜像。没有就提示去 `docker load`，然后退出，不会去 pull。内网 pull 的结果是等几分钟、然后报一个 TLS 相关的错误，看起来像网络问题，实际是根本没有出口。

权重用 ModelScope 预下载到宿主机，下的时候带 `--revision`，别用 `master`，同一个月拉两次可能不是同一份。挂载时宿主机路径和容器内保持一致，多机每台都得一样。路径不一致的表现很坑：各 rank 加载的分片对不上，报错却指向算子，顺着报错查半天也查不到路径头上。

## 起来

单机，1 台 16 卡：

```bash
cd v0.30.0-a3/DeepSeek-V4.1-Flash/single
vim config.env        # 三项：MODEL_PATH / IMAGE / NIC_NAME
bash start.sh         # 检查环境 → 起容器 → 跟日志
bash check.sh         # 另开一个窗口验证
```

PD 分离，2 台 1P1D：

```bash
cd v0.30.0-a3/DeepSeek-V4.1-Flash/pd-1p1d
vim config.env        # 两台用同一份：P 节点、D 节点、权重路径

bash start.sh decode      # Decode 那台
bash start.sh prefill     # Prefill 那台
bash start.sh proxy       # 还在 Prefill 那台，等后端全绿
bash check.sh
```

PD 分离，4 台 2P2D：目录换成 `pd-2p2d`，命令一样，只是每侧多起一台（D1→D2、P1→P2）。

顺序别颠倒。Decode 没起来就起 Prefill，Prefill 会挂在 KV 连接上，现象是卡住、不报错，很容易误判成权重加载慢。代理也一样，后端没全绿就起，客户端只会等到超时——代理自己的 `/healthcheck` 返回 200 只说明注册了几个实例，不代表能用。

`stop.sh` 停掉本机。PD 的容器按角色分开命名（`dsv41-1p1d-prefill` / `-decode` / `-proxy`），所以代理和 Prefill 挤在同一台也不会互相顶掉；`stop.sh` 三个一起删。残留容器会占着 7100 起的端口，下次 `start.sh` 会在端口检查那一步拦下来，这比让引擎初始化到一半因端口冲突退出好查。

## 怎么算跑完

不是"进程还活着"就算。判定标准是 `bash check.sh` 退出码 0，能自动查的它都查了。

单机三层：`/health` → `/v1/models` → 一次真实对话。PD 是先按后端逐个点名（P 8 个、D 32 个）→ 代理 → 经代理打一次真实请求。最后一层是唯一能证明 P→D 的 KV 传输通了的一步。

退出码 0 全过，1 有失败。

环境那一层不在这里——驱动、CANN、nofile、网卡、端口，用 `bash _shared/preflight.sh --config <config.env>` 单独跑。不是必须的，但能省掉一批"到了现场才发现"的问题。

PD 的代理启动前还有一道闸：`start.sh proxy` 会先逐个检查后端，有一个没起来就拒绝启动。这条是踩出来的——先起代理后起引擎，客户端必然收到 `All connection attempts failed`，或者挂到 180 秒超时。

## 加一个模型

最快的办法是复制一个已经跑通的：

```bash
cp -r v0.30.0-a3/DeepSeek-V4.1-Flash v0.30.0-a3/Qwen3-32B
```

然后：

1. 改 `config.env`：权重路径、拓扑、端口、节点 IP
2. 改 `serve.sh`、`run_p.sh`、`run_d.sh` 里的模型参数。tokenizer、parser、量化、投机解码、offload 这几个是真需要懂模型的，也是唯一需要动脑的地方
3. 不需要的形态目录直接删掉，不要留空目录占位
4. 实际跑一遍：`start.sh` → `check.sh` → 长上下文 → 并发十分钟
5. 写 `<模型>/README.md`，六节。「踩过的坑」不写完别提交

## 加一个版本

换硬件系列（A2 ↔ A3）或者大版本升级时，整个版本目录复制一份：

```bash
cp -r v0.30.0-a3 v0.28.0-a2
```

再把各 `config.env` 里的 `IMAGE` 换掉，每台机器 `docker load` 新镜像。跑通的旧版本目录保持原样，现场情况五花八门，旧版本说不定哪天又要用。

## 版本信息要锁死

"能跑"的前提是知道跑的是什么。每个版本目录的 README、每个形态脚本的头部注释，都要写清这些：

| 项 | 要求 |
|---|---|
| 镜像 | `@sha256:<digest>`，实在拿不到就 tag + 拉取日期。tag 会被重推，同一个 tag 今天拉和三个月后拉可能不是一层 |
| 镜像内 CANN | 容器里 `cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg` 的真实输出 |
| 宿主驱动 | `npu-smi info` 里的 Driver / Firmware。低于镜像要求时，表现是容器里"找不到设备" |
| 软件栈 | `vllm --version`、vllm-ascend、torch-npu、Python，都写实测值 |
| 硬件 | 机型、节点数、单机卡数、单卡 HBM、节点内和跨节点怎么连 |
| 参考文档 | 带版本段的 URL（`/zh-cn/<version>/`）。`latest` 会滚动，不能当锚点 |
| 参考代码 | `<repo>/blob/<tag>/examples/<file>`，必要时附 commit sha |
| 权重 | ModelScope `model_id` + `--revision <tag>` + 量化格式 |

官方文档和 GitHub main 对不上时，以锁定版本为准，并在模型 README 里写一句分支差异。不要凭经验放宽版本依赖。版本信息写实测输出，PR 里贴一段 `npu-smi info` 和 `vllm --version` 的原文，比写"已验证"有用。

## 权重校验

下载完核这几项：

- 文件数和总大小对得上模型仓库页面
- `config.json` 的量化字段和 `quant_model_description.json` 同时存在且一致
- P / D / 各节点挂的路径完全一样，revision 一样
- 容器里 `ls <MODEL_PATH>/*.safetensors | wc -l` 数量对

`w4a8` 被当成 `w8a8` 挂上（或者反过来）是最隐蔽的一类故障：服务能起，结果也出得来，但精度和性能全错位，事后很难往回追。所以下载完顺手核一下，尤其量化格式。

## 性能基线

每个模型至少留一次可复现的基线，写在模型 README 或 `docs/` 里：硬件和拓扑、并行配置（dp/tp/pcp/EP/有没有开投机解码）、负载（输入输出长度、并发、请求总数）、指标（TTFT P90、TPOT P90、输出 tok/s、总吞吐）、用什么工具跑的、完整命令是什么。

没有基线，下游就分不清"升级后变慢"和"本来就这样"。调优的 PR 附前、后两组数据。

## 踩过的坑记在哪

三个地方，看影响范围：通用的进 `docs/05-troubleshooting.md`，模型特有的进模型 README，代码层面能规避的写进脚本注释。

每条记五项：

```markdown
### <一句话症状，方便搜>

- 症状: 完整报错的关键行，原样粘贴，不要改写
- 触发条件: 机型 / 卡数 / 形态 / 并发
- 根因: 为什么会这样
- 处置: 能照着做的步骤
- 适用版本: 镜像 tag + CANN + vllm-ascend 版本
```

「适用版本」是必填的。不带版本的结论，半年后就是误导。结论失效了在标题前标 `DEPRECATED` 并指向新结论，别直接删。

## 文档

| 文档 | 内容 |
|---|---|
| [01 环境准备与预检](docs/01-preflight.md) | 软硬件基线、11 类检查、端口规划、内网准备 |
| [02 单机部署](docs/02-single-node.md) | 最简路径，先验证镜像和权重 |
| [03 PD 分离部署](docs/03-pd-disaggregation.md) | 拓扑设计、启动顺序、代理端点、一致性约束 |
| [04 关键参数与调优](docs/04-tuning.md) | TP/DP 怎么算、参数之间怎么互相影响 |
| [05 排错手册](docs/05-troubleshooting.md) | 按现象分流 |
| [06 新模型接入清单](docs/06-model-onboarding.md) | 换模型前过一遍 |

## Skills

`skills/` 里是给 Agent 用的流程封装，只做判断和约束，动作还是调仓库里的脚本。

| Skill | 干什么 |
|---|---|
| [env-preflight](skills/ascend-env-preflight/) | 环境体检、镜像准备、快照留证 |
| [deploy-single](skills/ascend-deploy-single/) | 单机 TP/DP 切分与三层验证 |
| [deploy-pd](skills/ascend-deploy-pd/) | 拓扑、rank 推导、启动顺序、代理端点 |
| [troubleshoot](skills/ascend-troubleshoot/) | 按现象定位根因 |
| [perf-tuning](skills/ascend-perf-tuning/) | 参数取舍、单变量实验、基线记录 |
| [model-onboarding](skills/ascend-model-onboarding/) | 新模型 / 新版本接入 |

安装方式和场景路由在 [skills/README.md](skills/README.md)。

## 写脚本的约定

现场执行的是实施同事，不一定熟 shell，所以：

- **一个文件一件事。** 那条 `vllm serve` 就逐行列在 `serve.sh` 里，别用函数拼参数、别包多层 `source`。改一个值应该十秒内能找到位置。
- **不加构建层。** 没有 Makefile，没有命令别名，不做转发入口。`bash start.sh` 已经是现场最长的命令。
- **不联网。** 不 pull、不 pip、不 clone。缺什么就在开头提示，然后退出。
- **前置检查一次做完。** 镜像、权重、卡数、端口，缺哪个说哪个，别跑到一半才崩。
- **不加 sudo，不改系统配置，不清用户数据。**

别为了"复用"把二十行逻辑抽到别处再包三层。现场看不懂的抽象，等于没有。

## 归档

跑通过的旧版本目录保留，在 README 顶部标一下状态：`维护中` / `仅存档` / `已被 <新版本> 取代`。参数和结论过期的标 `DEPRECATED` 加取代关系，不直接删。每季度清一次，确认没人引用再物理删除。

不写这条，半年后这个仓库就没人敢判断哪份是当前的了。

## 参考

- vLLM Ascend 文档：<https://docs.vllm.ai/projects/ascend/zh-cn/latest/getting_started/overview.html>
- vLLM-Ascend 仓库：<https://github.com/vllm-project/vllm-ascend>
- 权重：<https://modelscope.cn/models>
- 驱动 / CANN 配套：<https://www.hiascend.com/>

引用官方文档带版本段，`latest` 会滚动。

---

`README.md` 管规则：目录结构、形态区分、内网准备、验收标准、基线、踩坑、归档。`CONTRIBUTING.md` 管执行细则：命名、`config.env` 怎么写、脚本骨架、commit、评审勾选。冲突时以本文件为准，并顺手把 CONTRIBUTING 改过来。
