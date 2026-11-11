# DeepSeek-V4.1-Flash · Atlas 800 A3 ×4（2P2D）

本目录是该工具包的**实测案例**，用于验证 `scripts/pd/` 流程在真实大模型上的可用性，同时作为其他模型适配的参照。

## 已验证组合

| 项 | 取值 |
|---|---|
| 模型 | DeepSeek-V4.1-Flash（552B 总参，Prefill 激活 8B / Decode 激活 16B，多模态，最长 1M 上下文） |
| 权重 | `DeepSeek-V4.1-Flash-1017-w4a8`（含 draft 投机解码参数 + INT8 Engram 表，A3 推荐） |
| 硬件 | Atlas 800 A3（64G × 16 逻辑设备）× 4 台 |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 拓扑 | 2P2D：Prefill DP8（本地 4/台，PCP4 / TP1）+ Decode DP32（本地 16/台，TP1） |
| 对外模型名 | `dsv41` |

## 拓扑与端口

| 节点 | 角色 | 本地 DP / TP / PCP | 全局 DP rank | 引擎端口 |
|---|---|---|---|---|
| P1 | Prefill | 4 / 1 / 4 | 0–3 | 7100–7103 |
| P2 | Prefill | 4 / 1 / 4 | 4–7 | 7100–7103 |
| D1 | Decode | 16 / 1 / 1 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 / 1 | 16–31 | 7100–7115 |

- Prefill 全局 DP8：8 引擎 × (TP1 × PCP4) = 32 卡
- Decode 全局 DP32：32 引擎 × TP1 = 32 卡
- 合计 64 卡

KV 端口：Producer `30000 + rank`（30000–30007），Consumer `30100 + rank`（30100–30131）。这 40 个端口跨机必须放开。

## 与官方 1P1D 示例的差异

| 项 | 官方（2 台 A3） | 本例（4 台 A3） |
|---|---|---|
| 角色分布 | P1 + D1 | P1/P2 + D1/D2 |
| Prefill 启动 | `--dp-size 4 --dp-size-local 4 --dp-rank-start 0` | `--dp-size 8 --dp-size-local 4`，P1 rank 0 / P2 rank 4 |
| Decode 启动 | `--dp-size 16 --dp-size-local 16 --dp-rank-start 0` | `--dp-size 32 --dp-size-local 16`，D1 rank 0 / D2 rank 16 |
| connector 拓扑 | P4-D16 | P8-D32 |
| 单引擎超参 | — | **完全不变** |

单引擎超参一字未改，是本例能跑通的前提：模型本身的调度参数不该跟着节点数变动。

## 本模型特有参数

`run_dp_template_p.sh` / `run_dp_template_d.sh` 的公共参数之外，本例需要在 `EXTRA_VLLM_ARGS` 或模板中补：

```bash
# Prefill 侧额外
--enable-expert-parallel
--speculative-config '{"num_speculative_tokens":5,"method":"dspark"}'
--tokenizer-mode deepseek_v41
--reasoning-parser deepseek_v41
--tool-call-parser deepseek_v41
--enable-auto-tool-choice
--safetensors-load-strategy lazy
--swa-bounded-replay
--engram-config '{"cpu_offload":true,"dp_shared_memory":true}'
--additional-config '{"enable_cpu_binding":true,"enable_fused_mc2":2,"enable_flashcomm1":false,"multistream_overlap_shared_expert":false}'

# Decode 侧差异
--multistream_overlap_shared_expert true
--no-swa-bounded-replay
recompute_scheduler_enable = true
```

> **P/D 参数不可交叉复制**。把 Prefill 的 MegaMoE / PCP 搬到 Decode，或把 Decode 的图模式 / 多流 / 重计算搬到 Prefill，都会掉性能甚至起不来。

## 用到这个案例的四个坑

1. **`--ipc=host` 必需**：A3 上 Engram 表要在本地 DP rank 间共享主机内存，漏了会在起服务阶段报错。
2. **`nofile` 统一 1048576**：4 台里只要有一台是默认 1024，该节点报 `HCCL Communication_Error_Ranktable_Detect (EI0015)`，且 vLLM 只打 WARNING 不退出。
3. **启动等待预期要放宽**：32 个 Decode 引擎的权重加载 + 图捕获耗时很长，`VLLM_ENGINE_READY_TIMEOUT_S=36000` 是官方值，不要调小。
4. **主机内存**：Engram offload + 32 个 Decode 引擎的占用要提前算，别只看显存。

## 用法

```bash
cp examples/deepseek-v41-flash/env.example config/env
vim config/env                       # 改 4 台 IP、网卡、权重路径
make preflight
make up                              # 4 台各一次
bash scripts/pd/fetch_official.sh
make pd-d                            # D1 → D2
make pd-p                            # P1 → P2
make proxy
bash scripts/health_check.sh --pd    # 40 后端 + 代理 + 推理
```

## 参考

- vLLM Ascend 教程 DeepSeek-V4.1-Flash（A3 系列）
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html`
- PD 分离（Mooncake 多机）
  `https://docs.vllm.ai/projects/vllm-ascend-cn/zh-cn/latest/tutorials/features/pd_disaggregation_mooncake_multi_node.html`
- 权重：`https://www.modelscope.cn/models/Eco-Tech/DeepSeek-V4.1-Flash-1017-w4a8`
