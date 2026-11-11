---
name: ascend-deploy-single
description: 在单台 Atlas 800（A2/A3）上以 vLLM Ascend 起单机多卡服务，用于 POC、功能验证、小并发与小规模基线。当需要在单机内完成 TP/DP 切分、改 config.env、启动服务并做三层验证时使用。触发词：单机部署、vllm serve、single、TP/DP 怎么切、起服务、POC 验证、单机基线。
---

# 单机部署（`single/` 形态）

单机形态是**所有后续工作的地基**：它能跑通，说明镜像、权重、CANN 三者匹配；这时再上 PD，引入的新变量就只有网络与 KV 传输。

单机内 P/D 同进程共置，**不是分离**：不需要 KV 传输、不需要 RoCE、不需要代理。

## 现场只需要三条命令

```bash
cd <版本>/<模型>/single
vim config.env      # 改 MODEL_PATH / IMAGE / NIC_NAME
bash start.sh       # 检查 → 起容器 → 跟日志
bash check.sh       # 另开窗口：验证能不能真推理
bash stop.sh        # 停止
```

没有 Makefile，没有 `make up`，没有多层转发。**不要给现场加这层东西。**

## 1. 配置：只改 `config.env`

| 字段 | 说明 |
|---|---|
| `MODEL_PATH` | 权重绝对路径，宿主机与容器内一致 |
| `IMAGE` | 与所在版本目录一致；A2 与 A3 的 tag 不通用 |
| `NIC_NAME` | 业务口，不是管理口 |
| `SINGLE_TP` / `SINGLE_DP` | 拓扑，见下 |
| `SINGLE_PORT` | 默认 8000 |

模型参数（parser、量化、投机解码、offload）**不在 config.env**，在 `serve.sh` 里逐行列着。要改模型行为就去改那几行，不要往配置里塞。

## 2. 算拓扑：`卡数 = TP × DP`

```
本机 NPU 数 = SINGLE_TP × SINGLE_DP
```

- 16 卡机跑 16 个引擎 → `TP1 × DP16`；跑 4 个引擎 → `TP4 × DP4`。
- **权重单卡放不下时 TP 必须 > 1**（分片），先满足"放得下"，再谈性能。552B 权重在 64G 卡上 `TP=1` 必然失败。
- 填错时 `start.sh` 会在启动前拦下（`卡数 < TP×DP` 直接退出），不会跑到一半挂。

`MAX_MODEL_LEN` 跟着显存走：单机比 PD 紧张，先按 128K 级别起，实测再加。把 PD 的 1M 直接搬过来大概率 OOM。

## 3. 启动：`start.sh` 会先做完四项检查

| 检查 | 不通过时的提示 |
|---|---|
| 权重目录 | `权重目录不存在：...` |
| 镜像在本地 | `本机没有镜像 ... 先执行 docker load -i ...` |
| 卡数够 | `识别到 N 张卡，少于 TP×DP = M` |
| 端口空闲 | `端口 8000 已被占用，先执行 bash stop.sh` |

**这就是内网的关键设计**：镜像没导入时当场停住并说清怎么办，绝不让 `docker run` 去 pull 然后卡到超时、报一个和真实原因无关的网络错误。

检查通过后 `docker run -d` 起容器（命令就是 `serve.sh`），再 `docker logs -f`。**`Ctrl+C` 只退出日志，服务继续跑。**

首次启动 5–15 分钟起步（权重加载 + 图捕获 + 编译）。日志出现 `Application startup complete.` 才算起来，**不要用"进程还在"判断成功**，也别在中途反复重启。

## 4. 验证：三层，逐层过

```bash
bash check.sh       # 退出码 0 才算交付
```

| 层 | 内容 | 不过说明 |
|---|---|---|
| 1 | `GET /health` | 引擎没起来或还在加载 |
| 2 | `GET /v1/models` | 服务面没暴露，看 `--host 0.0.0.0` |
| 3 | 真实 `/v1/chat/completions` | 唯一能证明"真能推理"的一步 |

手工打一发时**必须带 `--noproxy '*'`**：

```bash
curl --noproxy '*' http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<SERVED_MODEL_NAME>","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

宿主机有 `http_proxy` 时，不带它 curl 会把本地请求发给代理，看到的是假故障。这个坑浪费的时间比它值得的多。

结果异常（重复、乱码、中英混杂）不是"模型就这样"：先查 `--tokenizer-mode` / `--reasoning-parser` / `--tool-call-parser` 三项是否与该模型匹配。

## 5. 改模型参数：动 `serve.sh`，别动脚本骨架

`serve.sh` 就是一条 `vllm serve`，参数逐行列着。常见要改的：

```bash
--quantization ascend                    # 有量化权重填 ascend；FP16 原始权重填 none
--block-size 128                         # 部分量化格式要求固定值，不是调优旋钮
--speculative-config '{"...":"..."}'     # 投机解码；不需要就整行删掉
--engram-config '{"cpu_offload":true}'   # 平台特定，删之前先确认显存够
```

JSON 参数用单引号整块包住即可（脚本里已经是这么写的）。**不要把它改回 `config.env` 里的字符串变量**——那层转义就是以前最容易配错的地方。

改完先 `bash -n serve.sh` 看语法，再 `bash start.sh`。

## 交接前要做完

1. `check.sh` 退出码 0（含真实推理）；
2. 多轮对话一次（验证 KV / prefix cache）；
3. 长上下文一次（验证 `MAX_MODEL_LEN` 与显存边界）；
4. 并发跑 10 分钟，`npu-smi info` 看显存无单调爬升；
5. 把实测拓扑、参数与踩坑写进 `<模型>/README.md`。

## 硬规则

- **不把 `single/` 的参数集直接搬到 PD**。两套是不同资产，单机的"最优解"到 PD 会掉性能甚至起不来。
- 不给现场加 Makefile 或命令别名。三条 `bash *.sh` 就是全部入口。
- 不引入联网动作。缺镜像就 `docker load`，不要"顺手 pull 一下试试"。
- 端口被占用时用 `bash stop.sh` 清掉，不要改端口绕过。
- 交付判定不是"起来了"，是 `check.sh` 退出码 0。

## 排错指针

起不来 / 起来了不能服务 / 结果异常 → `ascend-troubleshoot`。
想调吞吐或延迟 → `ascend-perf-tuning`。
