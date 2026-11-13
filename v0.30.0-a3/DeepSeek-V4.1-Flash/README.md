# DeepSeek-V4.1-Flash 部署

DeepSeek-V4.1-Flash 在 Atlas 800 A3 上的两套部署：单机一台 16 卡，和 PD 分离四台 2P2D。权重、镜像都一样，差别在拓扑和参数配比。

## 模型本身

552B 总参，MoE 结构，Prefill 激活 8B、Decode 激活 16B，带多模态，最长 1M 上下文，有 DSpark 投机解码。用 w4a8 量化。

| | |
|---|---|
| 权重 | `DeepSeek-V4.1-Flash-1017-w4a8` |
| 下载 | <https://www.modelscope.cn/models/Eco-Tech/DeepSeek-V4.1-Flash-1017-w4a8> |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 对外模型名 | `dsv41` |

权重里有两块容易漏的：DSpark 的 draft 参数（投机解码用，缺了要么起不来，要么 `--speculative-config` 直接报错），和 INT8 Engram 表（24 个 head 在 16 卡上分不匀，必须走 cpu_offload 加 DP 共享内存，脚本里已经写死了）。

## 单机还是 PD

| | `single/` | `pd-1p1d/` | `pd-2p2d/` |
|---|---|---|---|
| 硬件 | A3 × 1，16 卡 | A3 × 2，32 卡 | A3 × 4，64 卡 |
| 拓扑 | DP4 × TP4 | P: DP4（PCP4）+ D: DP16 | P: DP8（PCP4）+ D: DP32 |
| 上下文 | 建议 128K 起 | 能到 1M | 能到 1M |
| 什么时候用 | POC、功能验证、小并发 | 现场只有两台，或者先做小规模 PD 验证 | 长 prompt、高并发、交付预演 |
| 多机网络 | 不需要 | 两台之间放开 20 个 KV 端口 | 四台，40 个 KV 端口 |

建议先单机跑通再上 PD。单机能跑说明权重、镜像、CANN 三者匹配，PD 无非多引入网络和 KV 传输两个变量，出问题范围小得多。

`pd-1p1d` 和 `pd-2p2d` 是同一份东西的两种规模：**每台的引擎配比完全一样**（P 一台 4 引擎 × PCP4，D 一台 16 引擎 × TP1），区别只是各几台。所以 `run_p.sh`、`run_d.sh` 两边一模一样，扩缩容只改 `config.env` 里的节点列表和 `*_DP_LOCAL`，脚本一个字都不动。

另外官方对 PD 分离的表述是「参考设计，不建议直接用于生产」，生产推荐 MindIE Motor 加 vLLM Ascend。这个目录是拿来做验证、评测和交付预演的。

## 上现场前

内网没有外网，脚本不会下载东西，镜像和权重先搬进去。

```bash
# 镜像：有网的机器导出，拷过去，每台导入
docker save quay.io/ascend/vllm-ascend:v0.30.0-a3 -o vllm-ascend-v0.30.0-a3.tar
docker load -i vllm-ascend-v0.30.0-a3.tar
docker images | grep vllm-ascend

# 权重：预下载到宿主机，只读挂进容器
ls /data/weights/DeepSeek-V4.1-Flash-1017-w4a8/config.json
```

`start.sh` 第一件事是查本地镜像。没有就提示 `docker load` 然后退出，不会去 pull。多机的话权重每台都要在同一绝对路径，宿主机和容器内保持一致。

## 单机

改 `config.env` 三项：

```bash
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"
IMAGE="quay.io/ascend/vllm-ascend:v0.30.0-a3"
NIC_NAME="eth0"          # 业务口，不是管理口
```

拓扑固定 `SINGLE_TP=4` × `SINGLE_DP=4`，正好 16 卡。552B 单卡放不下，TP 不能取 1。

```bash
bash start.sh
```

脚本先确认四件事，任何一件不对就停：权重目录、镜像、卡数够不够 `TP×DP`、端口有没有被占。都过了才 `docker run`，然后跟日志。第一次启动 5 到 15 分钟（加载权重、捕获图、编译），看到 `Application startup complete.` 才算起来。`Ctrl+C` 只是退出日志，服务还在跑。

另开窗口验证：

```bash
bash check.sh
```

三层：`/health`、`/v1/models`、一次真实对话。退出码 0 才算交付。

手工打一发也行，注意带上 `--noproxy '*'`：

```bash
curl --noproxy '*' http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"用一句话介绍你自己。"}],"max_tokens":128}'
```

宿主机有 `http_proxy` 的话，不带这个参数 curl 会把本地请求发给代理，拿到的是超时或者 502，然后你会去怀疑服务。

停止用 `bash stop.sh`。

## PD 分离

先看四台 2P2D（`pd-2p2d/`）：

| 节点 | 角色 | 本地 DP / TP / PCP | 全局 rank | 逻辑设备 | 端口 |
|---|---|---|---|---|---|
| P1 | Prefill | 4 / 1 / 4 | 0–3 | 0–15 | 7100–7103 |
| P2 | Prefill | 4 / 1 / 4 | 4–7 | 0–15 | 7100–7103 |
| D1 | Decode | 16 / 1 / 1 | 0–15 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 / 1 | 16–31 | 0–15 | 7100–7115 |

Prefill 全局 DP8，8 个引擎 ×（TP1 × PCP4）= 32 卡。Decode 全局 DP32，32 个引擎 × TP1 = 32 卡。合起来 64 卡，正好四台。

```
客户端 → PD Proxy:1999
              ├─→ P1 (DP4·PCP4) ─┐
              ├─→ P2 (DP4·PCP4) ─┤ KV producer 30000+rank
              │                  ↓
              └─→ D1 (DP16) ←──  KV consumer 30100+rank
                  D2 (DP16)
```

四台用同一份 `config.env`，改四项：

```bash
PREFILL_NODES="192.168.0.11 192.168.0.12"   # 顺序就是 rank 顺序
DECODE_NODES="192.168.0.21 192.168.0.22"
PROXY_NODE="192.168.0.11"                    # 代理跑哪台
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"   # 四台必须一样
```

本机是这组第几台、rank 从几开始、DP 协调地址是哪个，脚本自己算，启动前会打印出来让你核。

启动，顺序不能颠倒：

```bash
bash start.sh decode      # 每个 Decode 节点，D1 先，再 D2
bash start.sh prefill     # 每个 Prefill 节点，P1 先，再 P2
bash start.sh proxy       # 代理节点
```

`start.sh` 就干三件事：确认镜像和官方脚本在、算本机 rank、用 `docker run` 把官方 `launch_online_dp.py` 拉起来。官方脚本直接从镜像里执行，不往仓库里抄。

Decode 先起是因为 Prefill 会向 Decode 发 KV。Decode 没起来，Prefill 初始化就挂在连接上，表现是卡住、不报错，很容易当成加载慢。

就绪判定看每个 rank 有没有打印 `Application startup complete.`，Decode 应该 32 条，Prefill 8 条：

```bash
docker logs dsv41-2p2d-decode 2>&1 | grep -c 'Application startup complete'
```

（容器按角色分开命名，`dsv41-2p2d-prefill` / `-decode` / `-proxy`。这样代理和 Prefill 落在同一台时不会互相顶掉。）

`VLLM_ENGINE_READY_TIMEOUT_S=36000` 是官方兜底值，别调小。权重在共享存储上加载慢、Decode 图捕获也慢，几十分钟很正常，当成挂了白重启一轮更浪费。

代理启动前会逐个检查 P 的 8 个和 D 的 32 个后端，有一个没起来就拒绝启动，同时把端点数打出来核对。端点数量对不上就是配置算错了，别带着错的数去起——官方代理要求 host 和 port 列表严格等长，不等长直接退出。

```bash
bash check.sh        # 后端 → 代理 → 经代理的真实推理
```

代理 `/healthcheck` 返回 200 不代表能用，它只说明注册了几个实例。真实请求能出内容，才证明 P→D 的 KV 传输通了。

停下用 `bash stop.sh`。

### 双机（`pd-1p1d/`）

只有两台机器时就是 1P1D：一台全做 Prefill，一台全做 Decode。每台的引擎配比和上面一样，所以参数、镜像、权重都不用动。

| 节点 | 角色 | 本地 DP / TP / PCP | 全局 rank | 逻辑设备 | 端口 |
|---|---|---|---|---|---|
| P1 | Prefill | 4 / 1 / 4 | 0–3 | 0–15 | 7100–7103 |
| D1 | Decode | 16 / 1 / 1 | 0–15 | 0–15 | 7100–7115 |

全局 DP 变成 P 4、D 16，connector 里也跟着变成 `{"prefill":{"dp_size":4,...},"decode":{"dp_size":16,...}}`——这两个数是 `config.env` 算出来的，`run_p.sh` / `run_d.sh` 不用改。

`config.env` 只改节点：

```bash
PREFILL_NODES="192.168.0.11"
DECODE_NODES="192.168.0.21"
PROXY_NODE="192.168.0.11"
```

启动顺序还是那个顺序，只是每台各一条：

```bash
# Decode 那台
bash start.sh decode
# Prefill 那台
bash start.sh prefill
# 还在 Prefill 那台，等后端全绿
bash start.sh proxy
```

Prefill 那台会同时有 `dsv41-1p1d-prefill` 和 `dsv41-1p1d-proxy` 两个容器，各自独立。就绪条数：Decode 16 条，Prefill 4 条。

两台之间的防火墙放开 `7100-7115`、`12321`、`30000-30003`、`30100-30115` 就行，比四台少了 D2 那一段。上下文仍然按 1M 配，但 Decode 只有 16 个引擎，并发能撑住的量是 2P2D 的一半；如果压测时显存吃紧，先把 `MAX_MODEL_LEN` 降到 524288。

## 参数

两侧共用的：

| 参数 | 值 | 说明 |
|---|---|---|
| `--served-model-name` | `dsv41` | 对外名字 |
| `--quantization` | `ascend` | w4a8 |
| `--block-size` | 128 | 这个量化格式要求的值 |
| `--enable-expert-parallel` | 开 | MoE 专家并行 |
| `--speculative-config` | `{"num_speculative_tokens":5,"method":"dspark"}` | 投机解码 |
| `--tokenizer-mode` / `--reasoning-parser` / `--tool-call-parser` | `deepseek_v41` | 三个必须一致，配错会输出重复或解析失败 |
| `--safetensors-load-strategy` | `lazy` | 降加载峰值内存 |
| `--engram-config` | `{"cpu_offload":true,"dp_shared_memory":true}` | A3 必需 |

P 和 D 不一样的：

| | Prefill（`run_p.sh`） | Decode（`run_d.sh`） |
|---|---|---|
| `--max-num-batched-tokens` | 8192 | 512 |
| `--max-num-seqs` | 16 | 72 |
| `gpu-memory-utilization` | 0.9 | 0.95 |
| 调度 | 默认 | `--async-scheduling` |
| 前缀缓存 | `--enable-prefix-caching` | `--no-enable-prefix-caching` |
| SWA 重放 | `--swa-bounded-replay` | `--no-swa-bounded-replay` |
| 图模式 | `--enforce-eager` | `cudagraph_mode=FULL_DECODE_ONLY` |
| `additional-config` | `fused_mc2=2`（MegaMoE），多流关 | 多流开，`recompute_scheduler_enable=true` |
| `HCCL_BUFFSIZE` | 1024 | 4096 |
| KV 角色 | `kv_producer` 30000+rank | `kv_consumer` 30100+rank |

这两份不要互相抄。把 Prefill 的 MegaMoE 或 PCP 搬到 Decode，或者反过来把图模式、多流、重计算搬到 Prefill，轻则掉性能，重则起不来。

connector 的拓扑两侧必须一模一样，否则连接器初始化就失败：

```json
{
  "prefill": {"dp_size": 8,  "tp_size": 1},
  "decode":  {"dp_size": 32, "tp_size": 1}
}
```

这两个数在两个脚本里都是从 `config.env` 的 `P_DP_SIZE` / `D_DP_SIZE` 带进去的，不要手改。PCP 只由 `--prefill-context-parallel-size` 表达，别写进 connector 的 `tp_size` —— 排错时最容易改错的就是这里。

## 踩过的坑

**容器 nofile 只有 1024，HCCL 建链失败。** 四台里只要有一台是默认的 1024，那台就报 `HCCL Communication_Error_Ranktable_Detect (EI0015)`，而 vLLM 只打 WARNING，不退出，很容易漏看。`start.sh` 里统一加了 `--ulimit nofile=1048576:1048576`。

**代理 `/healthcheck` 200 不代表可用。** 它只反映注册了多少实例。必须逐个后端 `GET /health` 过了再打业务请求，否则就是"代理 200 但请求卡住"。`start.sh proxy` 已经把这一步做成就绪闸。

**KV 端口没放开，表现是挂住，不是报错。** 30000–30007 和 30100–30131 跨节点被拦的时候，请求一直等 KV 传输。看到"后端全绿、代理正常、请求 180 秒超时"，先查这 40 个端口。

**内网没有镜像就 `docker run`，会卡到超时。** 这是内网最常见的一类"莫名其妙的报错"。现在脚本先 `docker image inspect`，缺镜像直接提示去 load。

其他几个：

- `--ipc=host` 漏了会在起服务阶段报错。A3 上 Engram 表要在本地 DP rank 之间共享主机内存，这条不能省。
- 四台权重路径必须同一绝对路径，容器内外也要一致。不一致时各 rank 加载的分片对不上，报错指向算子而不是路径。
- 主机内存要提前算，Engram offload 加上 32 个 Decode 引擎，四台建议 512G 往上。主机内存 OOM 的表现是进程直接消失，`dmesg` 里能看到 `killed process`，没有 Python 栈。
- 顺序还是那个顺序：Decode（D1→D2）→ Prefill（P1→P2）→ Proxy。

## 参考

- vLLM Ascend 教程里的 DeepSeek-V4.1-Flash 章节（A3 系列 5.1 / 5.2.1）
  <https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html>
- PD 分离（Mooncake 多机）和代理参数
  <https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/features/pd_disaggregation_mooncake_multi_node.html>
- 通用排错 `../../../docs/05-troubleshooting.md`
- 调优方法 `../../../docs/04-tuning.md`
