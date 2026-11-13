---
name: ascend-deploy-pd
description: 在多台 Atlas 800 上做 vLLM Ascend 的 Prefill/Decode 分离部署（pd-NpMd 形态），含拓扑设计、rank 推导、启动顺序、代理端点校验与四层验证。当需要跨节点拆分 P/D、排查 KV 传输、或把单机拓扑升级为组网拓扑时使用。触发词：PD 分离、P/D 拆分、pd-1p1d、pd-2p2d、pd-3p2d、双机部署、3P2D、rank 组网、HCCL_INTER_HCCS_DISABLE、Mooncake 池化、启动顺序、代理端点、KV 传输、dp-rank。
---

# PD 分离部署（`pd-<P>p<D>/` 形态）

Prefill 吃算力、Decode 吃显存带宽，拆开各自扩缩。代价是多了一层网络与 KV 传输——**PD 引入的新变量只有这两样**，所以务必先让单机跑通再来。

> 官方立场：vLLM Ascend 的 PD 分离示例标注为「参考设计，不建议直接用于生产」，生产推荐 MindIE Motor + vLLM Ascend。本形态用于验证、评测、交付预演。

## 前置

- 单机形态已跑通（`check.sh` 退出码 0）；
- 每台机器 `preflight.sh --all` 无 FAIL，镜像已 `docker load`；
- 已确定 P 组 / D 组的节点 IP，且**节点列表顺序就是 DP rank 顺序**。

## 现场只有一条命令（每台按角色执行）

```bash
cd <版本>/<模型>/pd-2p2d    # 两台用 pd-1p1d、五台用 pd-3p2d，命令一样
vim config.env          # 每台用同一份

bash start.sh decode    # 每个 Decode 节点，D1 先
bash start.sh prefill   # 每个 Prefill 节点，P1 先
bash start.sh proxy     # 代理节点，等后端全绿
bash check.sh           # 任意能访问代理的机器
bash stop.sh
```

没有 `start_p.sh` / `start_d.sh` / `start_proxy.sh` 三个入口，也没有 `fetch_official.sh`。**角色作为参数传进去，脚本仍然是同一个、可读的那一个。**

容器按角色命名（`<CONTAINER_NAME>-prefill` / `-decode` / `-proxy`），所以代理和 Prefill 落在同一台时不会互相顶掉——现场通常就是这种摆法（代理跑在 P1 上）。看到 `docker logs` 里的容器名就别奇怪为什么带后缀。

## 1. 设计拓扑：三个数定全局

```
单台卡数 = *_TP × *_PCP × *_DP_LOCAL
全局 DP  = *_DP_LOCAL × 该角色节点数
```

配比经验：

| 场景特征 | P 组 | D 组 |
|---|---|---|
| 平衡（默认） | 每台 4 引擎 × 2 台 → DP8 | 每台 16 引擎 × 2 台 → DP32 |
| 只有两台机器 | 1 台 → DP4 | 1 台 → DP16 |
| P 侧吃紧（5 台） | 3 台 × 4 引擎 → DP12 | 2 台 × 16 引擎 → DP32 |
| 长输出、低并发 prompt | 1 台 | 3 台 |
| 长 prompt、短输出 | 3 台 | 1 台 |
| 单机放得下 | 不拆，直接用 `single/` | |

扩缩容只改节点列表和 `*_DP_LOCAL`：**每台的引擎配比不变**，所以 `run_p.sh` / `run_d.sh` 一个字都不用动，connector 里的 `dp_size` 也是 `config.env` 算出来的。

- **Decode 偏好大 DP + 小 TP**：解码每步通信量与 TP 强相关，`TP1 × DP16` 是 16 卡机的常态。
- **Prefill 偏好用 PCP 分担长序列**：`TP1 × PCP4 × DP4` 是常见解。

## 1.5 rank 组网（A3 走 RoCE）

节点数上去以后（3P2D 起步），A3 上常见做法是显式让 HCCL 走 RoCE 而不是默认路径：

```bash
HCCL_INTER_HCCS_DISABLE="TRUE"   # 跨机不走 HCCS，改走 RoCE
HCCL_INTRA_ROCE_ENABLE=1         # 机内也走 RoCE
HCCL_IF_BASE_PORT=52000          # HCCL 通信端口基址
```

放在 `config.env` 里由模板统一 export，三条纪律：

1. **所有节点必须完全一样**。差一个值就是建链卡住或只连上一部分 rank，报错不会告诉你是哪台配错了，只能逐台 `docker inspect ... | grep HCCL_` 比。
2. **只在进程启动时读一次**。改完必须整体 `stop.sh` + `start.sh`，热改无效。
3. 数据面从 `NIC_NAME` 出去，MTU/PFC 要和交换机侧对齐；`HCCL_IF_BASE_PORT` 起的端口段在防火墙上整段放开（建议 `52000-52999`）。

## 1.6 Mooncake 池化

池化要三样：跑着的 `mooncake_master`、每台一份 `mooncake.json`、指向它的 `MOONCAKE_CONFIG_PATH`。模板里只读环境变量，json 由 `start.sh` 按 `config.env` 生成。

**内存是按引擎乘出来的**，不是整机给一个数：

```
单台池化占用 ≈ 引擎数 × (global_segment_size + local_buffer_size)
```

D 那台 16 引擎、段填 2GB，就是 32G 段 + 16G 缓冲 = 48G，要叠加在原本的主机内存账上。段是显式预留并注册给传输引擎的，`free` 里直接少掉，不是按需增长。内存紧的话用 `standalone-store` 模式，引擎侧段设 0。

默认值给的是 2GB / 1GB，现场先按这个起，压测看命中率再往上加——一次给到 8GB/rank，D 台就是 128G，很容易 OOM。

## 2. 改 `config.env`：只有节点与拓扑

```bash
MODEL_PATH="/data/weights/..."              # 所有节点必须同一绝对路径
PREFILL_NODES="192.168.0.11 192.168.0.12"   # 顺序 = rank 顺序，第一台兼 DP 协调
DECODE_NODES="192.168.0.21 192.168.0.22"
PROXY_NODE="192.168.0.11"                   # 留空则用 P 组第一台

PREFILL_DP_LOCAL=4 ; PREFILL_TP=1 ; PREFILL_PCP=4
DECODE_DP_LOCAL=16 ; DECODE_TP=1
```

全局 `P_DP_SIZE` / `D_DP_SIZE` 由 `config.env` 底部两行自动算，不要手改。

端口段（**跨节点防火墙必须放开 TCP**）：

| 用途 | 范围 |
|---|---|
| P / D 引擎 | `7100 + i`，i < `*_DP_LOCAL` |
| DP 协调 RPC | `12321` |
| KV producer | `30000 + 全局 rank` |
| KV consumer | `30100 + 全局 rank` |
| 代理 | `1999` |

KV 端口被拦的表现是**请求挂住到超时，不是报错**。

## 3. 官方脚本：从镜像里执行，不落仓库

`launch_online_dp.py` 与 `load_balance_proxy_server_example.py` 随镜像分发，`start.sh` 直接执行镜像内路径：

```
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/
```

启动前会 `docker run --rm "$IMAGE" test -f` 确认存在。换镜像版本后路径变了，它会明确提示并给出 `find` 命令；查到目录填进 `config.env` 的 `IMAGE_DIR` 即可，不用改脚本——**不要把它复制进仓库**，抄进来就会随镜像漂移。

## 4. 启动顺序：D 全组 → P 全组 → Proxy（不可颠倒）

理由：Prefill 会向 Decode 发起 KV 传输，Decode 未就绪时 Prefill 初始化会挂在连接上，表现为"卡住"而不是报错。

每次启动会先打印它算出来的拓扑，**先核对这三行**：

```
本机 IP     : 192.168.0.12（prefill 组第 2 / 2 台）
全局 DP     : 8（每台 4 个引擎）
本机 rank   : 4 - 7
```

`dp-rank-start = 节点序号 × DP_LOCAL`，由脚本从 `hostname`/网卡 IP 匹配节点列表算出。**本机 IP 不在列表里会直接报错退出**，不会带着错误 rank 启动。算错就是 `config.env` 的节点列表或 `NIC_NAME` 有问题。

## 5. 就绪闸：每个 rank 都要 `Application startup complete.`

```bash
docker logs <CONTAINER_NAME>-decode 2>&1 | grep -c 'Application startup complete'
# 2P2D：Decode 32 条（2 台 × 16），Prefill 8 条（2 台 × 4）
# 1P1D：Decode 16 条，Prefill 4 条
```

条数对不上就不进下一步。`VLLM_ENGINE_READY_TIMEOUT_S=36000`（10 小时）是官方兜底值，**不要调小**：权重在共享存储上加载、Decode 图捕获都可能几十分钟，误判成"挂了"会白重启一轮。

## 6. 代理：两个闸门都在 `start.sh proxy` 里

1. **就绪闸**：逐个检查 P 的 8 个 + D 的 32 个后端 `/health`，有一个没起来就拒绝启动（调 `check.sh backends`）。
2. **端点等长**：按 `DP_LOCAL × 节点数` 生成列表并打印数量核对：

```
Prefill 端点 : 8 个（2 台 × 4）
Decode 端点  : 32 个（2 台 × 16）
```

官方代理要求 host 与 port 列表严格等长，不等长直接退出。**不要带着错的数量去启动**——那是配置算错了，不是代理的问题。

## 7. 四层验证

```bash
bash check.sh              # 全查
bash check.sh backends     # 只查后端（代理启动前的闸门）
```

| 层 | 检查 | 陷阱 |
|---|---|---|
| 1 | 每个后端 `GET /health` | 逐个点名，P 8 个 + D 32 个 |
| 2 | 代理 `/healthcheck` | **只反映注册了几个实例，不代表后端可用** |
| 3 | `/v1/models` | 服务面是否正常暴露 |
| 4 | 真实 chat 请求 | 唯一能证明 P→D KV 链路通的一步 |

## 角色参数不得交叉复制

| 项 | Prefill（`run_p.sh`） | Decode（`run_d.sh`） |
|---|---|---|
| `--max-num-batched-tokens` | 8192 | 512 |
| `--max-num-seqs` | 16 | 72 |
| `gpu-memory-utilization` | 0.9 | 0.95 |
| 调度 | 默认 | `--async-scheduling` |
| 前缀缓存 | 开 | 关 |
| 图模式 | `--enforce-eager` | `cudagraph_mode=FULL_DECODE_ONLY` |
| `HCCL_BUFFSIZE` | 1024 | 4096 |
| KV 角色 | `kv_producer` `30000+rank` | `kv_consumer` `30100+rank` |

`kv_connector_extra_config` 两侧必须**完全一致**，且由 `config.env` 的 `P_DP_SIZE` / `D_DP_SIZE` 自动代入：

```json
{"prefill": {"dp_size": 8, "tp_size": 1}, "decode": {"dp_size": 32, "tp_size": 1}}
```

PCP 只由 `--prefill-context-parallel-size` 表达，**不要写进 connector 的 `tp_size`**。这是排错时最容易被误改的一处。

## 收尾

```bash
bash stop.sh        # 删除本机容器
```

残留容器会占住 7100 起的端口，下次 `start.sh` 会在端口检查处拦下——这是设计如此，比让引擎初始化到一半因端口冲突退出更好查。

## 硬规则

- **不联网**：镜像只能 `docker load`。`start.sh` 已做镜像存在性检查；不要加 `docker pull`，也不要"先 pull 一下试试"。
- **不加 Makefile、不加 `start_p.sh` 这类转发入口**。一个 `start.sh` + 角色参数，比三个转发脚本更好维护。
- 不把 P 与 D 的模板合并成一份带 `if` 的文件。两侧参数集角色特定，宁可两份带互斥注释。
- 拓扑变了就新开目录（`pd-1p3d` 与 `pd-2p2d` 是两份资产），不在同一个 `config.env` 里加分支。
- 不要把官方脚本复制进仓库；也不要调小 `VLLM_ENGINE_READY_TIMEOUT_S`。

## 排错指针

"后端全绿、代理 200、请求 180s 超时" → 先查 40 个 KV 端口与 connector 一致性，见 `ascend-troubleshoot`。
