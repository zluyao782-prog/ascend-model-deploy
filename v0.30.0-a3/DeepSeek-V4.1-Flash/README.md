# DeepSeek-V4.1-Flash 昇腾部署

DeepSeek-V4.1-Flash 在 Atlas 800 A3 上的两套部署形态：**单机（1 台 16 卡）** 与 **PD 分离（4 台 2P2D）**。两套共用同一份权重与镜像，差异只在拓扑与参数配比。

每套只改一个文件 —— `config.env`；模型参数在 `serve.sh` / `run_p.sh` / `run_d.sh` 里逐行列着。

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
- **INT8 Engram 表**：24 个 Engram head 在 16 卡上无法均分，必须走 `cpu_offload` + DP 共享内存（脚本里已写死在 `--engram-config`）。

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

## 3. 上现场前：镜像和权重

内网没有外网，脚本不会下载任何东西。**先做这两步，再做部署。**

```bash
# 镜像：有网的机器导出 → 拷到现场 → 每台导入
docker save quay.io/ascend/vllm-ascend:v0.30.0-a3 -o vllm-ascend-v0.30.0-a3.tar
docker load -i vllm-ascend-v0.30.0-a3.tar
docker images | grep vllm-ascend          # 确认导入成功

# 权重：预下载到宿主机（带 --revision），只读挂进容器
ls /data/weights/DeepSeek-V4.1-Flash-1017-w4a8/config.json
```

`start.sh` 会先检查镜像在不在本地。**没有镜像就停在这一步并提示 `docker load`，绝不会去 `docker pull`**——内网 pull 一定卡到超时，然后报一个和真实原因无关的网络错误。

多机时权重必须**每台同一绝对路径**，且宿主机与容器内一致。

## 4. 单机部署（`single/`）

### 4.1 改三项

```bash
cd single
vim config.env
```

```bash
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"
IMAGE="quay.io/ascend/vllm-ascend:v0.30.0-a3"
NIC_NAME="eth0"          # 业务口，不是管理口
```

拓扑固定 `SINGLE_TP=4` × `SINGLE_DP=4` = 16 卡。552B 权重单卡放不下，TP 不能取 1。

### 4.2 启动

```bash
bash start.sh        # 检查 → 起容器 → 跟日志
```

脚本会先确认四件事，任何一件不满足就当场退出并说明原因：权重目录在不在、镜像导没导入、卡数够不够 `TP×DP`、端口占没占。

首次启动 **5–15 分钟**（权重加载 + 图捕获 + 编译），日志出现 `Application startup complete.` 才算起来。`Ctrl+C` 只退出日志，服务继续跑。

### 4.3 验证

```bash
bash check.sh        # 另开一个窗口
```

三层逐级过：`/health` → `/v1/models` → 一次真实对话。退出码 0 才算交付。

手工打一发（注意 `--noproxy '*'`，宿主机有代理变量时 curl 会把本地请求发给代理）：

```bash
curl --noproxy '*' http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"用一句话介绍你自己。"}],"max_tokens":128}'
```

### 4.4 停止

```bash
bash stop.sh
```

## 5. PD 分离部署（`pd-2p2d/`）

### 5.1 拓扑

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

### 5.2 改四项（4 台用同一份 `config.env`）

```bash
cd pd-2p2d
vim config.env
```

```bash
PREFILL_NODES="192.168.0.11 192.168.0.12"   # 顺序即 rank 顺序
DECODE_NODES="192.168.0.21 192.168.0.22"
PROXY_NODE="192.168.0.11"                    # 代理节点
MODEL_PATH="/data/weights/DeepSeek-V4.1-Flash-1017-w4a8"   # 4 台必须一致
```

本机是这一组第几台、rank 从几开始、DP 协调地址是谁，都由 `start.sh` 算，启动前会打印出来核对。

### 5.3 启动顺序（不可颠倒）

```bash
# 每个 Decode 节点（D1 先，再 D2）
bash start.sh decode

# 每个 Prefill 节点（P1 先，再 P2）
bash start.sh prefill

# 代理节点
bash start.sh proxy
```

`start.sh` 只做三件事：确认镜像和官方脚本在、算出本机 rank、用 `docker run` 把官方 `launch_online_dp.py` 起起来。官方脚本直接从镜像里执行，不复制到仓库。

之所以 Decode 先：Prefill 会向 Decode 发起 KV 传输，Decode 没起来时 Prefill 初始化会挂在连接上，表现是"卡住"而不是报错。

### 5.4 就绪判定

每个 rank 都要打印 `Application startup complete.`：Decode 32 条、Prefill 8 条。

```bash
docker logs dsv41-pd 2>&1 | grep -c 'Application startup complete'
```

`VLLM_ENGINE_READY_TIMEOUT_S=36000`（10 小时）是官方兜底值，**不要调小**。权重从共享存储加载慢、Decode 图捕获慢，很容易超过几十分钟，误判成"挂了"会白重启一轮。

### 5.5 代理与验证

`bash start.sh proxy` 会先逐个检查 P 的 8 个 + D 的 32 个后端 `/health`，**有一个没起来就拒绝启动**，并把端点数打出来核对（P 8 个 / D 32 个，与 `DP_LOCAL × 节点数` 对上）。

后端全绿后：

```bash
bash check.sh        # 后端 → 代理 → 经代理的真实推理
```

> 代理 `/healthcheck` 返回 200 不代表可用，它只反映注册了多少实例。真实请求能返回内容，才证明 P→D 的 KV 传输通了。

### 5.6 停止

```bash
bash stop.sh
```

## 6. 关键参数

### 6.1 两侧共用

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

### 6.2 角色差异（不可交叉复制）

| 项 | Prefill（`run_p.sh`） | Decode（`run_d.sh`） |
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

### 6.3 connector 拓扑一致性

`kv_connector_extra_config` 两侧必须完全一致，否则连接器初始化失败：

```json
{
  "prefill": {"dp_size": 8,  "tp_size": 1},
  "decode":  {"dp_size": 32, "tp_size": 1}
}
```

PCP 只由 `--prefill-context-parallel-size` 表达，**不要**写进 connector 的 `tp_size`。排错时这一处最容易被误改。

## 7. 现场踩过的坑

> **容器 nofile 只有 1024 → HCCL 建链失败**
> 4 台里若只有一台是默认 `nofile=1024`，该节点报 `HCCL Communication_Error_Ranktable_Detect (EI0015)`，vLLM 只打 WARNING 不退出。`start.sh` 已统一加 `--ulimit nofile=1048576:1048576`。

> **代理 `/healthcheck` 200 不代表可用**
> 它只反映注册了多少实例。必须逐个后端 `GET /health` 通过后再打业务请求，否则会出现"代理 200 但请求卡住"。`start.sh proxy` 已把这一步做成就绪闸。

> **KV 端口没放开的表现是挂住，不是报错**
> 30000–30007 / 30100–30131 跨节点被拦时，请求会一直等 KV 传输。看到"后端全绿、代理正常、请求 180s 超时"，先查这 40 个端口。

> **内网 `docker image` 没有就 `docker run`，会卡到超时**
> 这是内网最常见的一类"莫名其妙的报错"。脚本现在会先 `docker image inspect`，缺镜像直接提示 `docker load`。

- **`--ipc=host` 漏了**：A3 上 Engram 表要在本地 DP rank 间共享主机内存，漏了会在起服务阶段报错。
- **权重路径不一致**：4 台必须同一绝对路径且容器内外一致，否则各 rank 加载的分片对不上，报错往往指向算子而不指向路径。
- **主机内存不足**：Engram offload + 32 个 Decode 引擎的占用要提前算，4 台建议 512G 以上。主机内存 OOM 的表现是进程直接消失（`dmesg` 有 `killed process`），没有 Python 栈。
- **启动顺序**：Decode（D1→D2）→ Prefill（P1→P2）→ Proxy。任意角色未全绿就起代理，长 prompt 会挂在 KV 传输上。

## 8. 参考

- vLLM Ascend 教程 DeepSeek-V4.1-Flash（A3 系列 5.1 / 5.2.1 章节）
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html`
- PD 分离（Mooncake 多机）与代理参数
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/features/pd_disaggregation_mooncake_multi_node.html`
- 通用排错：`../../../docs/05-troubleshooting.md`
- 调优方法：`../../../docs/04-tuning.md`
