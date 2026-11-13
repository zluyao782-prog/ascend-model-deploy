# 03 PD 分离部署

Prefill（算 prompt，吃算力）与 Decode（逐 token 生成，吃显存带宽）拆到不同节点，各自独立扩缩。适用于长 prompt、高并发、以及 P/D 资源配比有明显差异的场景。

> **官方立场**：vLLM Ascend 的 PD 分离示例标注为「参考设计，不建议直接用于生产」，生产推荐 MindIE Motor + vLLM Ascend。本项目用于验证、评测、交付预演。

## 1. 拓扑设计

先定三件事：**几个 P、几个 D、每组每台跑几个引擎**。

```bash
# config.env
PREFILL_NODES="10.0.0.11 10.0.0.12"   # 顺序 = DP rank 顺序，第一台是 P 组协调节点
DECODE_NODES="10.0.0.21 10.0.0.22"
PROXY_NODE=""                          # 留空则用 P 组第一台

PREFILL_DP_LOCAL=4      # 单台 P 起 4 个引擎
DECODE_DP_LOCAL=16      # 单台 D 起 16 个引擎
PREFILL_TP=1            # 单 rank 的 TP，通常 1，卡数靠 DP 堆
DECODE_TP=1
PREFILL_PCP=4           # 上下文并行，仅 Prefill

PREFILL_BASE_PORT=7100
DECODE_BASE_PORT=7100
DP_RPC_PORT=12321
KV_PRODUCER_PORT=30000
KV_CONSUMER_PORT=30100
PROXY_PORT=1999
```

全局 DP 由 `config.env` 自动算：`DP_LOCAL × 节点数`。上例即 P: DP8、D: DP32，与 `2P2D` 的 4 台 A3（16 卡/台）刚好填满。

### 常见拓扑配比

| 场景特征 | P 组 | D 组 | 说明 |
|---|---|---|---|
| 平衡（默认） | 本地 4/台 ×2 | 本地 16/台 ×2 | 上例，2P2D |
| 长输出、低并发 prompt | 1 台 | 3 台 | P 少、D 多 |
| 长 prompt、短输出 | 3 台 | 1 台 | P 多、D 少 |
| 单机可容纳 | 不拆 | | 直接用单机模式，PD 的代理与 KV 传输都是额外开销 |

## 2. 官方脚本：从镜像里执行，不落仓库

`launch_online_dp.py`（多机 DP 启动器）与 `load_balance_proxy_server_example.py`（代理）随镜像分发。抄进仓库就会随镜像版本漂移，所以 `start.sh` 直接执行镜像内的路径：

```
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/launch_online_dp.py
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py
```

`start.sh` 启动前会先 `docker run --rm "$IMAGE" test -f` 确认文件在。换镜像版本后路径变了，它会明确提示并给出查找命令：

```bash
docker run --rm $IMAGE find / -name launch_online_dp.py
```

确认后改 `start.sh` 顶部那两行即可，不需要额外"提取脚本"的步骤。

## 3. 启动顺序（不可颠倒）

```
Decode 全组  →  Prefill 全组  →  Proxy
```

理由：Prefill 会向 Decode 发起 KV 传输，Decode 未就绪时 Prefill 的初始化会挂在连接上，表现为"卡住"而不是报错。

```bash
# 每个 Decode 节点各执行（按节点顺序，D1 先）
bash start.sh decode

# 每个 Prefill 节点各执行（P1 先）
bash start.sh prefill

# 代理节点
bash start.sh proxy
```

每台机器执行时，`start.sh` 会先打印它算出来的拓扑，**启动前先核对这三行**：

```
本机 IP     : 10.0.0.12（prefill 组第 2 / 2 台）
全局 DP     : 8（每台 4 个引擎）
本机 rank   : 4 - 7
```

算错就说明 `config.env` 的节点列表或 `NIC_NAME` 有问题——本机 IP 不在列表里会直接报错退出，不会带着错误 rank 启动。

## 4. 等待就绪

大模型加载 + 图捕获耗时长，**`VLLM_ENGINE_READY_TIMEOUT_S=36000`（10 小时）是官方给的兜底值，不要调小**。

判定标准：**每个 rank 都打印 `Application startup complete.`**。32 个 Decode 引擎就要看到 32 条：

```bash
docker logs dsv41-pd 2>&1 | grep -c 'Application startup complete'
```

## 5. 代理与端点

```bash
bash start.sh proxy
```

它做两件事：

1. **就绪闸**：逐个检查 P 的 8 个 + D 的 32 个后端 `/health`，有一个没起来就拒绝启动。
2. **端点等长**：按 `DP_LOCAL × 节点数` 生成列表，并打印数量核对：

```
Prefill 端点 : 8 个（2 台 × 4）
Decode 端点  : 32 个（2 台 × 16）
```

官方代理要求 host 与 port 列表严格等长，不等长会直接退出。**端点数量对不上就是配置错了，不要带着错的数量去启动。**

## 6. 验证

```bash
bash check.sh
```

四层，逐层过：

| 层 | 检查 | 说明 |
|---|---|---|
| 1 | 每个后端 `GET /health` | P 的 8 个 + D 的 32 个，逐个点名 |
| 2 | 代理 `/healthcheck` | **只反映注册了几个实例，不代表后端可用** |
| 3 | `/v1/models` | 服务面正常暴露 |
| 4 | 真实 chat 请求 | 唯一能证明 KV 传输链路通的一步 |

> 第 2 层是最大的陷阱：代理 `/healthcheck` 返回 200 但请求挂住，几乎都是后端没全绿或 KV 端口被防火墙拦。

## 7. 参数一致性约束

`kv_connector_extra_config` 两侧**必须完全一致**，否则连接器初始化失败：

```json
{
  "prefill": {"dp_size": 8,  "tp_size": 1},
  "decode":  {"dp_size": 32, "tp_size": 1}
}
```

这两组数在 `run_p.sh` / `run_d.sh` 里都由 `config.env` 的 `P_DP_SIZE` / `D_DP_SIZE` 自动代入，**不要手改成别的值**。PCP（`--prefill-context-parallel-size`）只由启动参数表达，不要写进 connector 的 `tp_size`。这是排错时最容易被误改的一处。

### A3 走 RoCE 时多三个变量

节点数上去以后（3P2D 起步），A3 上常见做法是让 HCCL 显式走 RoCE：

```bash
HCCL_INTER_HCCS_DISABLE="TRUE"   # 跨机不走 HCCS，改走 RoCE
HCCL_INTRA_ROCE_ENABLE=1         # 机内也走 RoCE，不用机内 HCCS
HCCL_IF_BASE_PORT=52000          # HCCL 通信端口基址
```

写进 `config.env` 由模板统一 export，两条要记住：**所有节点必须完全一致**（差一个值就是建链卡住或只连上一部分 rank，不会告诉你哪台配错）；**只在进程启动时读一次**，改完要整体重启。数据面从 `NIC_NAME` 出，MTU/PFC 要和交换机对齐，`HCCL_IF_BASE_PORT` 起的端口段在防火墙上整段放开。

确认变量进了容器：`docker inspect <容器> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep HCCL_`

## 8. 换拓扑怎么改

只动 `config.env` 两处：

1. `*_NODES` 节点列表（顺序即 rank 顺序）；
2. `*_DP_LOCAL` 使其乘 `*_TP × *_PCP` 等于单台卡数。

rank 推导、全局 DP、端点数都是算出来的，脚本不用改。

## 9. 收尾

```bash
bash stop.sh
```

残留的容器会占住 7100 起的端口，下次 `start.sh` 会在端口检查处拦下来 —— 这是设计如此，比让引擎初始化到一半因端口冲突退出更好查。
