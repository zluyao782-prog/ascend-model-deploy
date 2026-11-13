---
name: ascend-perf-tuning
description: 昇腾 vLLM Ascend 服务的性能调优与基线管理，含 TP/DP 配比计算、吞吐与延迟参数取舍、图捕获、HCCL 环境变量、单变量实验方法与基线记录模板。当需要提升吞吐、降低首 token 延迟、判断"升级后是否变慢"，或为调优 PR 提供前后对照数据时使用。触发词：调优、性能、吞吐、TTFT、TPOT、P99、并发、基线、bench、为什么慢。
---

# 性能调优与基线

**没有可复现的基线时调参数，只是在制造随机数。** 先有对照组，再动一个参数。

## 第 0 步：先分清三类参数

| 类别 | 例子 | 调错的后果 | 能不能动 |
|---|---|---|---|
| 正确性参数 | `--quantization`、`--block-size`、`--max-model-len`、`--prefill-context-parallel-size` | 起不来，或**静默算错** | 按模型/量化格式定，不为性能改 |
| 资源参数 | `--tensor-parallel-size`、`--data-parallel-size`、`--gpu-memory-utilization` | OOM 或卡利用率低 | 按硬件算 |
| 性能参数 | `--max-num-seqs`、`--max-num-batched-tokens`、`--async-scheduling` | 吞吐或延迟劣化 | 唯一的调优空间 |

顺序不能反：先保证第一类正确，第二类算对，第三类才谈调优。**在量化格式或 `max-model-len` 配错的情况下调 `max-num-seqs`，得到的全是噪声。**

## 资源参数怎么算

```
单机 NPU 数 = TP × DP_LOCAL（× PCP）
```

| 角色 | 偏好 | 理由 |
|---|---|---|
| Decode | 大 DP + 小 TP（16 卡机常见 `TP1 × DP16`） | 解码每步通信量与 TP 强相关，TP 越大跨卡同步开销越明显 |
| Prefill | 用并行把长序列切开（openEuler 构建 `TP4 × DP4`；官方构建可 `TP1 × PCP4 × DP4`） | 长 prompt 的注意力最吃显存和算力 |
| 权重单卡放不下 | TP 必须 > 1 | 先满足"放得下"，再谈性能 |

`gpu-memory-utilization`：`0.9` 起步，Decode 可推到 `0.95`（KV cache 越多并发越高）。峰值显存不只由权重决定——图捕获、临时 buffer 都算在内。推到 0.95 后出现不定期 OOM，先降到 0.92，别急着怀疑框架。

## 性能参数的相互作用

### `--max-num-batched-tokens`：吞吐与首 token 延迟的平衡点

| 侧 | 建议 | 理由 |
|---|---|---|
| Prefill | 8192 起 | prompt 吞吐优先，大 batch 摊薄固定开销 |
| Decode | 512 左右 | 解码步本来就小，过大只拉高单步延迟 |

**这两个值不应该相同。** 看到两侧都填 8192，基本可以判断是照抄的。

### `--max-num-seqs`：并发上限，不是越大越好

- 太小 → KV cache 用不满，吞吐上不去；
- 太大 → 排队变长，P99 爆炸，甚至触发 KV cache 争抢。

估算：`可用 KV 显存 / 单序列平均 KV 占用`。先按保守值跑，观察 `npu-smi` 显存占用与实测并发的关系再往上加。

### `--async-scheduling`：Decode 专属

开启后调度与计算流水化，提升解码并发下的利用率。Prefill 侧开了没意义，只增加复杂度。

### prefix caching：P 开 D 关

- Prefill **开**：多轮对话、相同 system prompt 场景直接省掉重复 prefill；
- Decode **关**：Decode 不做 prefill，缓存只白占显存，改走重计算更划算。

### 图捕获（cudagraph）

Decode 侧开 `FULL_DECODE_ONLY`，解码步调度开销大幅下降，代价是启动多花几分钟捕获。

- 捕获阶段 OOM → 降 `gpu-memory-utilization`，或改 `PIECEWISE`；
- 捕获卡住不动 → 检查是否同时开了 `--enforce-eager`（两者互斥）。
- Prefill 侧通常 `--enforce-eager`：prefill 的 shape 变化大，整图捕获收益不明显。

## 环境变量里的三个坑

| 变量 | 默认 | 说明 |
|---|---|---|
| `HCCL_BUFFSIZE` | 200 | 调大可减少小包通信次数；Decode 常用 4096，代价是显存。两侧不必一致 |
| `HCCL_EXEC_TIMEOUT` | 分钟级 | 压测前可调 600s 加快失败暴露；生产留默认 |
| `VLLM_ENGINE_READY_TIMEOUT_S` | 视镜像 | 大模型加载兜底，**不要调小** |

## 实验方法：一次只动一个参数

```bash
for c in 1 4 16 32; do
  echo "concurrency=$c"
  # vllm bench serve / AISBench，固定输入输出长度
  # 记录: 输出 tok/s、TTFT、TPOT、P99、显存峰值
done
```

每次实验之间**重启服务**：不重启则 prefix cache 命中率不同，数据不可比。

记录模板（调优 PR 必须附前后两组）：

| 配置 | 并发 | 输出吞吐 tok/s | TTFT P90 | TPOT P90 | P99 | 显存峰值 |
|---|---|---|---|---|---|---|
| 单机 TP4×DP4 | 16 | | | | | |
| 2P2D（P DP8 / D DP32） | 16 | | | | | |

完整基线还要写清：硬件与拓扑、并行配置（dp/tp/pcp/EP/是否投机解码）、负载（输入长度/输出长度/并发/请求总数）、指标、工具与**完整命令**。

不开基线，下游就无法区分"升级后变慢"和"本来就这样"。

## 「调了没用」的五个原因

1. **瓶颈不在 NPU**：权重在慢存储、代理单点、网卡带宽不足，参数调整完全无效。先看 `npu-smi` 的 AICore 利用率是否真的高。
2. **没有清缓存**：两次实验间没重启服务，prefix cache 命中率不同。
3. **输入长度不一致**：压测用随机长度会掩盖真实特征，按业务实际分布构造。
4. **只看平均值**：P99 才是用户感知的延迟，平均值好看但 P99 恶化是常见现象。
5. **一次改了多个参数**：无法归因，只能重来。

## 硬规则

- 不为性能动正确性参数。`--block-size` 是量化格式的要求值，不是调优旋钮。
- 不把单机参数集搬到 PD，也不把 P 的参数搬到 D；两侧角色特定。
- 性能相关改动必须附前/后基线，否则视为未验证，不予合并。
- 报数必须带 P90/P99，不给平均值的"提升 X%"。
- 参数改在 `serve.sh` / `run_p.sh` / `run_d.sh` 里对应的那一行，**不要为了"方便调"把它们挪进 `config.env`**。配置只描述这一次部署怎么起，混进模型参数后，下一个现场就分不清哪个该改。

## 相关

`ascend-deploy-single` / `ascend-deploy-pd` 负责把服务起对；先能起、能验证，再谈调优。
若性能问题伴随报错或请求挂住，先走 `ascend-troubleshoot` 的 C3 分流。
