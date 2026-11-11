---
name: ascend-model-onboarding
description: 在仓库中接入一个新模型或新镜像版本，含支持性核查、权重与量化校验、显存估算、并行切分可行性、骨架复制、config.env 与 README 六节填写、以及提交前评审。当要新增模型目录、换镜像 tag、或把跑通的现场脚本沉淀成仓库资产时使用。触发词：新模型接入、新增模型、onboarding、加一个模型、换镜像版本、写模型 README、提交评审。
---

# 新模型 / 新版本接入

换模型时最容易出错的不是脚本，是**想当然**。按顺序过一遍，能把「跑起来了但不对」挡在部署前。

## 第 0 步：确认这个模型能被支持

| 检查项 | 怎么确认 | 不支持的表现 |
|---|---|---|
| 架构在 vLLM 注册表内 | 查 vLLM / vLLM Ascend 支持的模型列表 | 启动报 `architecture is not supported` |
| 昇腾侧已适配 | 查 vLLM Ascend 教程是否有该模型 | 能加载但算子回落 CPU，慢到不可用 |
| 镜像版本够新 | 模型发布日期 vs 镜像 tag | 新模型需新版才支持，别用旧镜像硬上 |

先查再动手。官方教程明确列出的模型，成功率远高于"看起来架构一样"的猜测。

## 1. 权重与量化

| 检查项 | 说明 |
|---|---|
| 格式 | 优先 HF safetensors 原始格式；`*-w4a8` / `*-w8a8` 是量化版，需硬件匹配 |
| 量化与硬件 | w4a8 类通常面向 A3；放 A2 上可能起不来或精度异常 |
| 分片完整 | `*.safetensors` 数量与 `model.safetensors.index.json` 的 `weight_map` 一致 |
| 附加参数 | 部分模型带 draft 参数（投机解码）或额外 embedding 表，缺了加载失败 |
| 路径 | 多机必须同一绝对路径，宿主机 = 容器内 |

```bash
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

**`w4a8` 被误挂成 `w8a8`（或反之）是最隐蔽的一类故障**：服务能起、结果出得来，精度与性能全部错位。

## 2. 显存估算：决定 TP 怎么切

单位为 GB（bf16；量化按位宽折算）：

```
权重       ≈ 参数量 × 每参数字节数（bf16=2，w8=1，w4≈0.5）
KV cache   ≈ 2 × 层数 × 隐藏维度 × 序列长度 × 并发数 × 字节数
激活/临时  ≈ 权重的 10%~20%（随 batch 增长）
图捕获     ≈ 固定开销，Decode 侧预留 3~8GB
```

```
单卡可用显存 × TP ≥ 权重 + KV 预留 + 激活
```

放不下就加 TP；放得下但想提并发就加 DP；两者都加不了才去找量化版本。**别忘了主机内存**：offload 与图捕获吃主机内存，经验值 ≥ 2 倍权重体积。

## 3. 服务参数与模型匹配

这几项填错时服务能起来但输出不对，最难查：

| 参数 | 怎么定 |
|---|---|
| `--tokenizer-mode` | 特殊模型需专用 tokenizer，普通模型用默认 `auto` |
| `--reasoning-parser` | 有思维链输出时需要（deepseek / qwen 各有专用值） |
| `--tool-call-parser` | 需要 function calling 时配；配错会解析失败或返回原文 |
| `--chat-template` | 权重里没带 `chat_template` 时必须手动指定 |
| `--max-model-len` | 不超过训练长度，也不超过显存承受范围 |
| `--block-size` | 多数模型 16/32/128 均可，部分量化格式要求特定值 |
| `--quantization` | 有量化权重填 `ascend`；FP16 原始权重填 `none` |

验证方法：用官方最简 prompt 打一次，与自己用 transformers 在 CPU 上的输出对比前 20 个 token。差异大就是上面某项配错了。

## 4. 并行切分可行性

| 约束 | 说明 |
|---|---|
| TP 整除 | TP 必须整除注意力头数，`num_key_value_heads` 也要能分 |
| MoE 专家 | 专家数不能被 EP 整除时，需退化处理或走 offload |
| PCP | 序列维切分，要求序列长度能被切 |
| 特殊模块 | 某些 embedding / Engram 表无法在卡间均分，需 CPU offload |

算不整就换 TP 值。**不要靠"能起来"判断正确**：TP 切错有时能启动，只是结果错。

## 5. 在仓库里建目录

**复制一个已经跑通的模型目录**，不要从零写、也不要维护一份骨架模板：

```bash
cp -r v0.30.0-a3/DeepSeek-V4.1-Flash v0.30.0-a3/<新模型名>
cd v0.30.0-a3/<新模型名>
```

命名严格按约定：

| 层 | 命名 | 例 |
|---|---|---|
| 镜像版本 | `v<版本>-<硬件系列>` | `v0.30.0-a3`、`v0.28.0-a2` |
| 模型 | 与官方名完全一致 | `DeepSeek-V4.1-Flash`、`Qwen3-32B` |
| 形态 | `single` / `pd-<P>p<D>` | `pd-2p2d`、`pd-1p3d` |

- **拓扑变了就新开目录**，不在同一个 `config.env` 里加 `if` 分支；`pd-1p1d` 与 `pd-2p2d` 是两份资产。
- 不需要的形态直接删掉，不留空目录占位。
- 换硬件系列（A2 ↔ A3）**新建版本目录**，不要把两种镜像 tag 混在一处。

`start.sh` / `check.sh` / `stop.sh` 与模型无关，**原样保留**——它们只读 `config.env` 和几个常量。真正要改的是 `config.env`、`serve.sh`、`pd-*/run_p.sh`、`pd-*/run_d.sh`、`README.md`。

## 6. 写 `config.env`

只描述"**这一次部署**怎么起"，模型参数与通用能力都不进配置：

- 权重路径、节点 IP、拓扑、端口收敛于此，脚本正文不出现硬编码的 IP / 路径；
- 每个字段带一行注释，说明**为什么是这个值**而不是"这是什么"：

```bash
DECODE_DP_LOCAL=16     # 16 引擎 × TP1 = 16 卡，刚好占满 A3
```

- 字段分块写：[必改] → [拓扑] → [容器] → [只有体检脚本用]。一线同事按块找比按字母找快；
- 前置检查放 `start.sh` 开头，一次查完镜像 / 权重 / 卡数 / 端口，缺什么当场说缺什么；
- 卡数一致性：`可见卡数 == DP_LOCAL × TP × PCP`，不匹配在启动前就退出——这是 HCCL 卡死最常见的前置原因；
- 不提交凭证 / Token / 客户真实密码。`config.env` 随仓库提交以便复现，只能放占位 IP。

## 7. 组网形态改 `run_p.sh` / `run_d.sh`

模型私有启动参数（parser、投机解码、offload、MoE 相关）写在这两个文件里，就是一条逐行列出的 `vllm serve`。两侧参数角色特定，**不要合并成一份带 `if` 的模板**，也不要抽成变量再拼接——现场要能一行一行看懂。

## 8. 写 `<模型>/README.md`（六节，缺一不可）

1. **模型与版本**：参数量、结构特点、推荐权重名、镜像 tag（精确到 tag）
2. **硬件与拓扑**：几台、几卡、P/D 如何分工、端口规划
3. **配置要点**：哪些字段必须改、为什么
4. **启动步骤**：可直接复制执行的命令，含顺序要求
5. **关键参数**：模型私有参数及取值理由
6. **踩过的坑**：现象 + 根因 + 规避方式

第 6 项最有价值——三个月后接手的人（可能是你自己）只想知道这个。**这一项不写完不要提交。**

## 9. 版本锚定（强制）

每个版本目录 README 与每个形态脚本头部注释，必须锁定：

| 项 | 要求 |
|---|---|
| 镜像锚点 | `@sha256:<digest>`；无法用 digest 时用 `tag` + 拉取日期（**tag 会被重推**） |
| 镜像内 CANN | 容器内 `version.cfg` 的**实测**输出 |
| 宿主驱动 | `npu-smi info` 的 Driver / Firmware |
| 软件栈 | `vllm` / `vllm-ascend` / `torch-npu` / Python 实测版本 |
| 硬件拓扑 | 机型、节点数、单机卡数、单卡 HBM、节点内/跨节点互联 |
| 参考文档 | **版本化 URL**（`/zh-cn/<version>/`），不用 `latest` |
| 参考代码 | `<repo>/blob/<tag>/examples/<file>` |
| 权重锚点 | ModelScope `model_id` + `--revision <tag>` + 量化格式 |

三条纪律：官方文档与 GitHub `main` 不一致时以锁定版本为准；不凭经验放宽或收紧版本依赖；版本信息必须是**实测输出**，PR 里贴原始输出比写"已验证"有说服力。

权重下载优先 ModelScope，**必须显式 `--revision`**，禁止默认 `master`——不同时间拉到的权重不同，复现性直接失效。离线环境先预下载到宿主机，再只读挂载进容器。

## 10. 验证与评审

部署后必须做的四项：`bash check.sh` 退出码 0 → 单轮问答 → 多轮（验证 KV / prefix cache）→ 长上下文（验证 `max-model-len` 与显存边界）。再加**并发跑 10 分钟看显存是否单调爬升**——泄漏类问题只在这时暴露。

合并前逐条确认：

- [ ] 目标硬件上**实际跑通**，不是"看起来能跑"
- [ ] **内网环境（无外网）下全程无联网动作**：镜像 `docker load`、权重本地挂载
- [ ] `preflight.sh` 无 FAIL，WARN 有解释
- [ ] `check.sh` 退出码 0（含真实推理）
- [ ] `start.sh` 的前置检查覆盖：镜像、权重、卡数、端口
- [ ] 长上下文成功、并发 10 分钟显存无爬升
- [ ] 模型 `README.md` 六节齐全、版本精确到 tag
- [ ] `config.env` 每个字段有"为什么"的注释，且没有混入模型参数
- [ ] 没有 Makefile、没有多余的转发脚本
- [ ] 没提交权重、日志、镜像包、官方脚本副本
- [ ] Shell 脚本可执行位正确（`git ls-files -s` 看到 `100755`）
- [ ] `bash -n` / `shellcheck` 通过

commit 前缀：`feat`（新增模型/形态）、`fix`（修脚本或参数）、`docs`（补 README/排错）、`chore`（目录调整）。

## 沉淀与弃用

- 坑按影响范围归三处：`docs/05-troubleshooting.md`（通用）、模型 README（模型专属）、`start.sh` 头部注释（代码级规避）。五字段：症状 / 触发条件 / 根因 / 处置 / **适用版本**。
- 已跑通的旧版本目录**保留**，只在 README 顶部注明 `维护中` / `仅存档` / `已被 <新版本> 取代`。
- 参数与结论过期的标 `DEPRECATED` + 取代关系，**不直接删**。
