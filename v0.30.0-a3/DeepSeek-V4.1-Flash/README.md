# DeepSeek-V4.1-Flash 昇腾部署

DeepSeek-V4.1-Flash 在 Atlas 800 A3 上的两套部署形态：**单机（1 台 16 卡）** 与 **PD 分离（4 台 2P2D）**。两套共用同一份模型权重与镜像，差异只在拓扑与参数配比。

## 1. 模型与版本

| 项 | 取值 |
|---|---|
| 模型 | DeepSeek-V4.1-Flash |
| 参数量 | 552B 总参，Prefill 激活 8B / Decode 激活 16B |
| 结构 | MoE + 多模态，最长 1M 上下文，带 DSpark 投机解码 |
| 推荐权重 | `DeepSeek-V4.1-Flash-1017-w4a8`（含 DSpark draft 参数 + INT8 Engram 表） |
| 下载 | `https://www.modelscope.cn/models/Eco-Tech/DeepSeek-V4.1-Flash-1017-w4a8` |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 对外模型名 | `dsv41` |

权重里有两个容易被忽略的部分，缺一不可：

- **DSpark draft 参数**：投机解码用，缺了要么起不来，要么 `--speculative-config` 报错；
- **INT8 Engram 表**：24 个 Engram head 在 16 卡上无法均分，必须走 `cpu_offload` + DP 共享内存。

## 2. 两种形态怎么选

| | 单机 `single/` | PD 分离 `pd-2p2d/` |
|---|---|---|
| 硬件 | A3 × 1（16 卡） | A3 × 4（64 卡） |
| 拓扑 | DP4 × TP4 | P: DP8(PCP4/TP1) + D: DP32(TP1) |
| 上下文 | 建议 128K 起 | 可到 1M |
| 适用 | POC、功能验证、小并发 | 长 prompt / 高并发 / 交付预演 |
| 多机网络 | 不需要 | 需要 RoCE/HCCS + 40 个 KV 端口开放 |

**建议路径：先单机跑通，再做 PD。** 单机能跑说明权重、镜像、CANN 三者匹配；PD 引入的变量只有网络与 KV 传输，出问题范围小得多。

> 官方立场：PD 分离示例标注为「参考设计，不建议直接用于生产」，生产推荐 MindIE Motor + vLLM Ascend。本目录用于验证与评测。

---

## 3. 单机部署（`single/`）

### 3.1 配置

```bash
cd single
vim config.env
```

必改三项：

```bash
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"
IMAGE="quay.io/ascend/vllm-ascend:v0.30.0-a3"
NIC_NAME="eth0"
```

单机拓扑固定为 `SINGLE_TP=4` × `SINGLE_DP=4` = 16 卡。552B 权重单卡放不下，TP 不能取 1。

### 3.2 启动

```bash
cd single

bash ../../../_shared/preflight.sh --config config.env   # 体检
bash ../../../_shared/start_container.sh --config config.env   # 拉起容器
bash ./start.sh                                          # 前台加 --foreground
```

等价于 `make preflight / make up / make single`。

首次启动耗时：权重加载 5–15 min + 图捕获 + 编译，日志出现 `Application startup complete.` 才算起来。

### 3.3 验证

```bash
bash ../../../_shared/health_check.sh --config config.env
```

```bash
curl --noproxy '*' http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"用一句话介绍你自己。"}],"max_tokens":128}'
```

---

## 4. PD 分离部署（`pd-2p2d/`）

### 4.1 拓扑

| 节点 | 角色 | 本地 DP / TP / PCP | 全局 DP rank | 逻辑设备 | 引擎端口 |
|---|---|---|---|---|---|
| P1 | Prefill | 4 / 1 / 4 | 0–3 | 0–15 | 7100–7103 |
| P2 | Prefill | 4 / 1 / 4 | 4–7 | 0–15 | 7100–7103 |
| D1 | Decode | 16 / 1 / 1 | 0–15 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 / 1 | 16–31 | 0–15 | 7100–7115 |

- Prefill 全局 DP8：8 引擎 × (TP1 × PCP4) = 32 卡
- Decode 全局 DP32：32 引擎 × TP1 = 32 卡
- 合计 64 卡，正好 4 台

```
客户端 → PD Proxy:1999
              ├─→ P1 (DP4·PCP4) ─┐
              ├─→ P2 (DP4·PCP4) ─┤ KV producer 30000+rank
              │                  ↓
              └─→ D1 (DP16) ←──  KV consumer 30100+rank
                  D2 (DP16)
```

### 4.2 配置

```bash
cd pd-2p2d
vim config.env
```

必改四项：

```bash
PREFILL_NODES="192.168.0.11 192.168.0.12"   # 顺序即 rank 顺序
DECODE_NODES="192.168.0.21 192.168.0.22"
PROXY_NODE="192.168.0.11"                    # 代理节点
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"   # 4 台必须一致
```

### 4.3 启动顺序（不可颠倒）

```bash
# 0) 4 台各执行一次
bash ../../../_shared/preflight.sh --config config.env
bash ../../../_shared/start_container.sh --config config.env

# 1) 首次：提取官方 launcher 与代理脚本（落盘到 ../../.tools/）
bash ../../../../_shared/pd/fetch_official.sh --config config.env

# 2) 每个 Decode 节点（D1 → D2）
bash ./start_d.sh

# 3) 每个 Prefill 节点（P1 → P2）
bash ./start_p.sh

# 4) 代理节点
bash ./start_proxy.sh --dry-run    # 应先看到 8 + 32 个端点
bash ./start_proxy.sh -d

# 5) 验证
bash ../../../_shared/health_check.sh --config config.env --pd
```

等价于 `make fetch / make d / make p / make proxy / make check`。

`start_p.sh` / `start_d.sh` 会自动完成：识别本机属于哪组第几台 → 推导 `dp-rank-start` → 把模板放进 `.run/<role>/` → 调官方 launcher 拉起本地引擎。

### 4.4 就绪判定

```bash
tail -f logs/decode.log     # 要看到 32 条 Application startup complete.
tail -f logs/prefill.log    # 要看到 8 条
```

`VLLM_ENGINE_READY_TIMEOUT_S=36000`（10 小时）是官方兜底值，**不要调小**。权重从共享存储加载慢、Decode 图捕获慢，很容易超过几十分钟，误判成"挂了"会白重启一轮。

---

## 5. 关键参数

### 5.1 两侧共用

| 参数 | 值 | 说明 |
|---|---|---|
| `--served-model-name` | `dsv41` | 对外模型名 |
| `--quantization` | `ascend` | w4a8 权重 |
| `--block-size` | 128 | 该量化格式要求 |
| `--enable-expert-parallel` | 开 | MoE 专家并行 |
| `--speculative-config` | `{"num_speculative_tokens":5,"method":"dspark"}` | DSpark 投机解码 |
| `--tokenizer-mode` / `--reasoning-parser` / `--tool-call-parser` | `deepseek_v41` | 三者需一致，配错会输出重复或解析失败 |
| `--safetensors-load-strategy` | `lazy` | 降低加载峰值内存 |
| `--engram-config` | `{"cpu_offload":true,"dp_shared_memory":true}` | A3 必需 |

### 5.2 角色差异（不可交叉复制）

| 项 | Prefill | Decode |
|---|---|---|
| `--max-num-batched-tokens` | 8192 | 512 |
| `--max-num-seqs` | 16 | 72 |
| `--gpu-memory-utilization` | 0.9 | 0.95 |
| 调度 | 默认 | `--async-scheduling` |
| 前缀缓存 | `--enable-prefix-caching` | `--no-enable-prefix-caching` |
| SWA 重放 | `--swa-bounded-replay` | `--no-swa-bounded-replay` |
| 图模式 | `--enforce-eager` | `cudagraph_mode=FULL_DECODE_ONLY` |
| `additional-config` | `fused_mc2=2`（MegaMoE）, 多流关 | 多流开, `recompute_scheduler_enable=true` |
| `HCCL_BUFFSIZE` | 1024 | 4096 |
| KV 角色 | `kv_producer` 30000+rank | `kv_consumer` 30100+rank |

把 Prefill 的 MegaMoE / PCP 搬到 Decode，或把 Decode 的图模式 / 多流 / 重计算搬到 Prefill，都会掉性能甚至起不来。

### 5.3 connector 拓扑一致性

`kv_connector_extra_config` 两侧必须完全一致，否则连接器初始化失败：

```json
{
  "prefill": {"dp_size": 8,  "tp_size": 1},
  "decode":  {"dp_size": 32, "tp_size": 1}
}
```

PCP 只由 `--prefill-context-parallel-size` 表达，**不要**写进 connector 的 `tp_size`。排错时这一处最容易被误改。

---

## 6. 现场踩过的坑

> **容器 nofile 只有 1024 → HCCL 建链失败**
> 4 台里若只有一台是默认 `nofile=1024`，该节点报 `HCCL Communication_Error_Ranktable_Detect (EI0015)`，vLLM 只打 WARNING 不退出。`start_container.sh` 已统一加 `--ulimit nofile=1048576:1048576`。

> **代理 `/healthcheck` 200 不代表可用**
> 它只反映注册了多少实例。必须逐个后端 `GET /health` 通过后再打业务请求，否则会出现"代理 200 但请求卡住"。`health_check.sh --pd` 就是按这个顺序做的。

> **KV 端口没放开的表现是挂住，不是报错**
> 30000–30007 / 30100–30131 跨节点被拦时，请求会一直等 KV 传输。看到"后端全绿、代理正常、请求 180s 超时"，先查这 40 个端口。

- **`--ipc=host` 漏了**：A3 上 Engram 表要在本地 DP rank 间共享主机内存，漏了会在起服务阶段报错。
- **权重路径不一致**：4 台必须同一绝对路径且容器内外一致，否则各 rank 加载的分片对不上，报错往往指向算子而不指向路径。
- **主机内存不足**：Engram offload + 32 个 Decode 引擎的占用要提前算，4 台建议 512G 以上。主机内存 OOM 的表现是进程直接消失（`dmesg` 有 `killed process`），没有 Python 栈。
- **启动顺序**：Decode（D1→D2）→ Prefill（P1→P2）→ Proxy。任意角色未全绿就起代理，长 prompt 会挂在 KV 传输上。

## 7. 参考

- vLLM Ascend 教程 DeepSeek-V4.1-Flash（A3 系列 5.1 / 5.2.1 章节）
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html`
- PD 分离（Mooncake 多机）与代理参数
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/features/pd_disaggregation_mooncake_multi_node.html`
- 通用排错：`../../../docs/05-troubleshooting.md`
- 调优方法：`../../../docs/04-tuning.md`
