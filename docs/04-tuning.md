# 04 关键参数与调优

调优的前提是**有可复现的对照基线**。没有基线时调参数，只是在制造随机数。

## 1. 先分清三类参数

| 类别 | 例子 | 调错的后果 |
|---|---|---|
| **正确性参数**（不能乱动） | `--quantization`、`--block-size`、`--max-model-len` | 起不来，或静默算错 |
| **资源参数**（按硬件算） | `--tensor-parallel-size`、`--data-parallel-size`、`--gpu-memory-utilization` | OOM 或卡利用率低 |
| **性能参数**（按业务调） | `--max-num-seqs`、`--max-num-batched-tokens`、`--async-scheduling` | 吞吐或延迟劣化 |

先保证第一类正确，第二类算对，第三类才是调优空间。

## 2. 资源参数的算法

### TP 与 DP 的取舍

单机 NPU 数 = 每个引擎占用卡数 × 引擎数：

```
NPU 数 = TP × DP_LOCAL
```

例：16 卡 A3，跑 16 个引擎 → TP1 × DP16；跑 4 个引擎 → TP4 × DP4。

经验规则：

- **Decode 侧**偏好大 DP + 小 TP：解码每步的通信量与 TP 强相关，TP 越大跨卡同步开销越明显。16 卡机常见 `TP1 × DP16`。
- **Prefill 侧**要靠并行把长序列切开：长 prompt 的注意力计算最吃这一块。openEuler 构建没有 PCP，用 `TP4 × DP4`；官方构建可以 `TP1 × PCP4 × DP4`，序列并行对长 prompt 更友好，但需要镜像支持 `--pcp-size`。
- 模型单卡放不下时，TP 是必须的（权重分片），此时先满足"放得下"，再谈性能。

### gpu-memory-utilization

`0.9` 起步。Decode 侧可以推到 `0.95`（KV cache 越多并发越高），但要注意：

- 峰值显存不只由权重决定，图捕获、临时 buffer 都算在内；
- 推到 0.95 后若出现不定期 OOM，先降到 0.92，别急着怀疑框架。

## 3. 性能参数的相互作用

### max-num-batched-tokens

单个调度步内允许的 token 总量，直接决定「吞吐」与「首 token 延迟」的平衡。

| 侧 | 建议 | 理由 |
|---|---|---|
| Prefill | 8192 起 | prompt 吞吐优先，大 batch 摊薄固定开销 |
| Decode | 512 左右 | 解码步本来就小，过大只会拉高单步延迟 |

这两个值不应该相同。见到有人两侧都填 8192，基本可以判断是照抄的。

### max-num-seqs

每个引擎同时调度的序列数。**这是并发上限，不是越大越好**：

- 太小 → 显存里 KV cache 用不满，吞吐上不去；
- 太大 → 排队等待变长，P99 延迟爆炸，且可能触发 KV cache 争抢。

估算方法：`可用 KV 显存 / 单序列平均 KV 占用`。先按保守值跑，观察 `npu-smi` 显存占用与实测并发的关系再往上加。

### async-scheduling

Decode 侧专属。开启后调度与计算流水化，能提升解码并发下的 GPU/NPU 利用率。Prefill 侧开了没意义，反而增加复杂度。

### prefix caching

- Prefill **开**：多轮对话 / 相同 system prompt 场景收益很大，直接省掉重复 prefill。
- Decode **关**：Decode 侧不做 prefill，缓存只会白占显存，关掉改走重计算更划算。

## 4. 图捕获（cudagraph）

Decode 侧建议开图模式，`FULL_DECODE_ONLY` 是常见选择。收益是解码步骤的调度开销大幅下降；代价是启动时多花几分钟捕获。

若遇到：

- 捕获阶段 OOM → 降 `gpu-memory-utilization`，或改 `PIECEWISE` 分段捕获；
- 捕获卡住不动 → 检查是否同时开了 `--enforce-eager`（两者互斥）。

Prefill 侧通常 `--enforce-eager`，因为 prefill 的 shape 变化大，整图捕获收益不明显。

## 5. 环境变量里的三个坑

| 变量 | 默认 | 说明 |
|---|---|---|
| `HCCL_BUFFSIZE` | 200 | 调大可减少小包通信次数，Decode 侧常用 4096，代价是显存 |
| `HCCL_EXEC_TIMEOUT` | 很长（分钟级） | 出故障时要干等，压测前可调到 600s 加快失败暴露 |
| `VLLM_ENGINE_READY_TIMEOUT_S` | 视镜像 | 大模型加载慢时的兜底，**不要调小** |

`HCCL_BUFFSIZE` 两侧不必一致，但要各自匹配角色负载：Prefill 偏小、Decode 偏大。

## 6. 调优实验方法

一次只动一个参数，记录三组指标：

```bash
# 简单压测：固定并发与输入输出长度
for c in 1 4 16 32; do
  echo "concurrency=$c"
  # 用你的压测工具，如 evalscope / benchmark_serving
  # 记录: 吞吐(tokens/s)、TTFT、TPOT、P99
done
```

对照表至少包含：**单机基线** 与 **PD 配置**，否则无法判断拆分到底带来了收益还是负担。

记录模板：

| 配置 | 并发 | 输出吞吐 | TTFT | TPOT | P99 | 显存峰值 |
|---|---|---|---|---|---|---|
| 单机 TP8 | 16 | | | | | |
| 2P2D | 16 | | | | | |

## 7. 常见"调了没用"的原因

- **瓶颈不在 NPU**：权重在慢速存储、代理单点、网卡带宽不足，都会让参数调整完全无效。先看 `npu-smi` 的利用率是否真的高。
- **没有清缓存**：两次实验之间没重启服务，prefix cache 命中率不同，数据不可比。
- **输入长度不一致**：压测用的随机长度会掩盖真实特征，按业务实际分布构造。
- **只看平均值**：P99 才是用户感知的延迟，平均值好看但 P99 恶化是常见现象。
