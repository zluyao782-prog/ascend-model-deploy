# 06 新模型接入检查清单

换模型时最容易出错的不是脚本，是**想当然**。这份清单按顺序过一遍，能把大部分「跑起来了但不对」的问题在部署前挡掉。

## 1. 模型本身是否被支持

| 检查项 | 怎么确认 | 不支持的表现 |
|---|---|---|
| 架构在 vLLM 注册表内 | 查 vLLM/vLLM Ascend 支持的模型列表 | 启动报 `architecture is not supported` |
| 昇腾侧已适配 | 查 vLLM Ascend 教程是否有该模型 | 能加载但算子回落 CPU，慢到不可用 |
| 镜像版本够新 | 模型发布日期 vs 镜像 tag | 新模型在新版才支持，别用旧镜像硬上 |

先查再动手。官方教程里明确列出的模型，成功率远高于"看起来架构一样"的猜测。

## 2. 权重格式与量化

| 检查项 | 说明 |
|---|---|
| 格式 | 优先 HF safetensors 原始格式；`*-w4a8` / `*-w8a8` 是量化版，需硬件匹配 |
| 量化与硬件 | w4a8 类量化通常面向 A3；放到 A2 上可能起不来或精度异常 |
| 分片完整 | `*.safetensors` 数量与 `model.safetensors.index.json` 的 `weight_map` 一致 |
| 附加参数 | 部分模型带 draft 参数（投机解码）或额外 embedding 表，缺了会加载失败 |
| 路径 | 多机必须同一绝对路径，宿主机 = 容器内 |

```bash
# 分片完整性快速核对
python3 - <<'PY'
import json, os
p = os.environ["MODEL_PATH"]
idx = json.load(open(os.path.join(p, "model.safetensors.index.json")))
need = sorted(set(idx["weight_map"].values()))
have = sorted(f for f in os.listdir(p) if f.endswith(".safetensors"))
print("索引要求:", len(need), " 实际存在:", len(have))
print("缺失:", [f for f in need if f not in have][:5])
PY
```

## 3. 显存估算（决定 TP/DP 怎么切）

粗略估算，单位为 GB（bfloat16，量化按位宽折算）：

```
权重       ≈ 参数量 × 每参数字节数（bf16=2，w8=1，w4≈0.5）
KV cache   ≈ 2 × 层数 × 隐藏维度 × 序列长度 × 并发数 × 字节数
激活/临时  ≈ 权重的 10%~20%（随 batch 增长）
图捕获     ≈ 固定开销，Decode 侧预留 3~8GB
```

判断能否放下：

```
单卡可用显存 × TP ≥ 权重 + KV预留 + 激活
```

放不下就加 TP；放得下但想提并发就加 DP。两者都加不了才是找量化版本的时候。

## 4. 服务参数与模型匹配

这几个参数填错，服务能起来但输出不对，最难查。

| 参数 | 怎么定 |
|---|---|
| `--tokenizer-mode` | 特殊模型需专用 tokenizer，普通模型用默认 `auto` |
| `--reasoning-parser` | 有思维链输出的模型需要（如 deepseek / qwen 系列各有专用值） |
| `--tool-call-parser` | 需要 function calling 时配；配错会解析失败或返回原文 |
| `--chat-template` | 权重里没带 `chat_template` 时必须手动指定 |
| `--max-model-len` | 不超过模型训练长度，也不超过显存承受范围 |
| `--block-size` | 多数模型 16/32/128 均可，部分量化格式要求特定值（如 128） |
| `--quantization` | 有量化权重时填 `ascend`；FP16 原始权重填 `none` |

验证方法：用**官方推荐的最简 prompt** 打一次，与自己用 transformers 在 CPU 上的输出对比前 20 个 token。差异大就是上面某项配错了。

## 5. 并行切分可行性

| 约束 | 说明 |
|---|---|
| TP 整除 | TP 必须整除注意力头数；`num_key_value_heads` 也要能分 |
| MoE 专家 | 专家数不能被 EP 整除时，需退化处理或走 offload |
| PCP | 序列维切分，要求接近严格是序列长度能被切 |
| 特殊模块 | 某些模型的 embedding / Engram 表无法在卡间均分，需 CPU offload |

算不整就换 TP 值。**不要靠"能起来"判断正确**：TP 切错有时能启动，只是结果错。

## 6. 部署后必须做的四项验证

```bash
# 1. 服务面
bash ../../../_shared/health_check.sh

# 2. 单轮问答（最简）
# 3. 多轮（验证 KV / prefix cache）
# 4. 长上下文（验证 max-model-len 与显存边界）
```

再加一项**并发压力下的稳定性**：至少跑 10 分钟持续请求，观察显存是否爬升。显存随时间单调上涨 = 有泄漏或 KV 回收不正常，这类问题只在长时间跑后暴露。

## 7. 在仓库里新增一个模型目录

从骨架模板复制到对应镜像版本下：

```bash
cp -r _template/vX.Y.Z-hw/ModelName v0.30.0-a3/<新模型名>
cd v0.30.0-a3/<新模型名>
grep -rn TODO .                          # 逐个替换
vim single/config.env                    # 单机形态
vim pd-NpMd/config.env                   # 组网形态
```

组网形态的 `run_dp_template_p.sh` / `run_dp_template_d.sh` 需要按模型补私有参数，从 `v0.30.0-a3/DeepSeek-V4.1-Flash/pd-2p2d/` 复制后改。

`config.env` 只放**这一次部署**的差异项（权重路径、拓扑、端口、模型私有参数），通用逻辑与公共默认值由 `_shared/` 与模板提供。

`<模型>/README.md` 必须写全六节，其中三件最重要：

1. 验证过的硬件与镜像版本（**精确到 tag**）
2. 关键参数及为什么这么设
3. 踩过的坑

第 3 条最有价值 —— 三个月后接手的人（可能是你自己）只想知道这个。

## 8. 交付前的最后一遍

- [ ] `preflight.sh` 全绿（WARN 项有合理解释）
- [ ] `health_check.sh` 四层通过
- [ ] 长上下文请求成功
- [ ] 并发压测 10 分钟无显存爬升
- [ ] `collect_env.sh` 快照归档
- [ ] `<模型>/README.md` 六节齐全、版本精确到 tag
