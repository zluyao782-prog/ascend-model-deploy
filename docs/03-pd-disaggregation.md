# 03 PD 分离部署

Prefill（算 prompt，吃算力）与 Decode（逐 token 生成，吃显存带宽）拆到不同节点，各自独立扩缩。适用于长 prompt、高并发、以及 P/D 资源配比有明显差异的场景。

> **官方立场**：vLLM Ascend 的 PD 分离示例标注为「参考设计，不建议直接用于生产」，生产推荐 MindIE Motor + vLLM Ascend。本项目用于验证、评测、交付预演。

## 1. 拓扑设计

先定三件事：**几个 P、几个 D、每组每台跑几个引擎**。

```bash
# config/env
DEPLOY_MODE="pd"

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

全局 DP 由脚本计算：`DP_LOCAL × 节点数`。上例即 P: DP8、D: DP32，与 `2P2D` 的 4 台 A3（16 卡/台）刚好填满。

### 常见拓扑配比

| 场景特征 | P 组 | D 组 | 说明 |
|---|---|---|---|
| 平衡（默认） | 本地 4/台 ×2 | 本地 16/台 ×2 | 上例，2P2D |
| 长输出、低并发 prompt | 1 台 | 3 台 | P 少、D 多 |
| 长 prompt、短输出 | 3 台 | 1 台 | P 多、D 少 |
| 单机可容纳 | 不拆 | | 直接用单机模式，PD 的代理与 KV 传输都是额外开销 |

## 2. 首次准备：提取官方脚本

`launch_online_dp.py`（多机 DP 启动器）与 `load_balance_proxy_server_example.py`（代理）随镜像分发，不随本项目提交（避免版本漂移）：

```bash
bash scripts/pd/fetch_official.sh
```

脚本会在容器内 `find` 定位并复制到 `.tools/`。若定位失败，可手工确认镜像内路径：

```bash
docker exec -it <容器> bash -lc 'find / -name launch_online_dp.py 2>/dev/null'
```

## 3. 启动顺序（不可颠倒）

```
Decode 全组  →  Prefill 全组  →  Proxy
```

理由：Prefill 会向 Decode 发起 KV 传输，Decode 未就绪时 Prefill 的初始化会挂在连接上，表现为"卡住"而不是报错。

```bash
# 每个 Decode 节点各执行（按节点顺序，D1 先）
make pd-d

# 每个 Prefill 节点各执行（P1 先）
make pd-p

# 代理节点
python3 scripts/pd/start_proxy.py --dry-run    # 先核对端点数量
make proxy
```

每台机器执行 `start_role.sh` 时会自动：

1. 用 `hostname -I` 匹配本机属于哪个角色、第几台；
2. 推导本机 `dp-rank-start`（前序节点 `DP_LOCAL` 累加）；
3. 把对应角色模板放到 `.run/<role>/run_dp_template.sh`；
4. 调官方 launcher 拉起本地 `DP_LOCAL` 个引擎。

想看它们算得对不对，启动前先看打印的拓扑块：

```
== prefill 节点启动 ==
   本机 IP        : 10.0.0.12 （prefill 组第 2/2 台）
   全局 DP        : 8（本地 4/台 × 2 台）
   本机 rank 区间 : 4 - 7
   TP / PCP       : 1 / 4
   DP 协调地址    : 10.0.0.11:12321
```

## 4. 等待就绪

大模型加载 + 图捕获耗时长，**单个引擎初始化上限 `VLLM_ENGINE_READY_TIMEOUT_S=36000`（10 小时）是官方给的兜底值，不要调小**。

```bash
tail -f .run/prefill/log/prefill.log
tail -f .run/decode/log/decode.log
```

判定标准：**每个 rank 都打印 `Application startup complete.`**。32 个 Decode 引擎就要看到 32 条。

## 5. 代理与端点

```bash
python3 scripts/pd/start_proxy.py --dry-run
```

输出会列出端点总数，应与 `DP_LOCAL × 节点数` 对上：

```
[proxy] prefill  : 8 个端点  ['10.0.0.11', '10.0.0.12']  (2 台 × 4)
[proxy] decode   : 32 个端点 ['10.0.0.21', '10.0.0.22']  (2 台 × 16)
```

端点数量对不上就是配置错了，**不要带着错的数量去启动** —— 官方代理要求 host 与 port 列表严格等长，不等长会直接退出。

## 6. 验证

```bash
bash scripts/health_check.sh --pd
```

四层，逐层过：

| 层 | 检查 | 说明 |
|---|---|---|
| 1 | 每个后端 `GET /health` | P 的 8 个 + D 的 32 个，逐个点名 |
| 2 | 代理 `/healthcheck` | **只反映注册了几个实例，不代表后端可用** |
| 3 | `/v1/models` | 服务面正常暴露 |
| 4 | 真实 chat 请求 | 唯一能证明 KV 传输链路通的一步 |

> 第 2 层是最大的陷阱：代理 `/healthcheck` 返回 200 但请求挂住，几乎都是后端没全绿或 KV 端口被防火墙拦。所以脚本在第 1 层有异常时直接跳过第 4 层，避免干等。

## 7. 参数一致性约束

`kv_connector_extra_config` 两侧**必须完全一致**，否则连接器初始化失败：

```json
{
  "prefill": {"dp_size": 8,  "tp_size": 1},
  "decode":  {"dp_size": 32, "tp_size": 1}
}
```

PCP（`--prefill-context-parallel-size`）只由启动参数表达，**不要**写进 connector 的 `tp_size`。这是排错时最容易被误改的一处。

## 8. 换拓扑怎么改

只动两处：

1. `config/env` 里的 `*_NODES`、`*_DP_LOCAL`、`*_TP`、`*_PCP`；
2. 如果单机卡数变了（比如从 16 卡换 8 卡），调整 `*_DP_LOCAL` 使其乘 TP 等于卡数。

`start_role.sh` 的 rank 推导、`start_proxy.py` 的端点数都是算出来的，不需要改脚本。

## 9. 收尾

```bash
bash scripts/stop.sh --services     # 停服务保留容器
bash scripts/stop.sh                # 停容器
bash scripts/stop.sh --purge        # 删容器
```

残留进程会占住 7100 起的端口，下次启动会在 `start_role.sh` 的端口检查处被拦下 —— 这是设计如此，比让引擎在初始化一半时因端口冲突退出更好查。
