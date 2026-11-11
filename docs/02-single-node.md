# 02 单机部署

适用：模型能被单机 NPU 显存容纳，不需要 Prefill / Decode 分离。这是最简路径，也是验证镜像、权重、CANN 版本是否匹配的最快方式 —— **在搞多机 PD 之前，先用单机确认模型本身能跑起来**。

单机内 P/D 同进程共置，**不是分离**：不需要 KV 传输、不需要 RoCE、不需要代理。

## 1. 配置

配置在 `<版本>/<模型>/single/config.env`。已有该模型目录时直接改；没有就先复制一个跑通的模型目录：

```bash
cp -r v0.30.0-a3/DeepSeek-V4.1-Flash v0.30.0-a3/<新模型名>
cd v0.30.0-a3/<新模型名>/single
vim config.env
```

必改三项 + 拓扑：

```bash
MODEL_PATH="/data/weights/Qwen3-32B"     # 权重绝对路径，宿主机=容器内
IMAGE="quay.io/ascend/vllm-ascend:v0.30.0-a3"
NIC_NAME="eth0"

SINGLE_TP=4
SINGLE_DP=4          # 卡数 = TP × DP
SINGLE_PORT=8000
MAX_MODEL_LEN=131072
```

`SINGLE_TP` 的选取：

- 权重单卡放不下 → TP 必须 > 1（这是硬约束，先满足"放得下"）；
- 放得下又想提吞吐 → 加 DP（`TP1 × DP16`）；
- 模型小到单卡能放下、且只追低延迟 → `TP=1`，跨卡通信是有代价的。

## 2. 启动

```bash
bash start.sh
```

一条命令做完四件事，任何一件不满足就当场退出并说明原因：

| 检查 | 不通过时提示 |
|---|---|
| 权重目录在不在 | `权重目录不存在：...` |
| 镜像导没导入本地 | `本机没有镜像 ... 先执行 docker load -i ...` |
| 卡数够不够 `TP×DP` | `识别到 N 张卡，少于 TP×DP = M` |
| 端口占没占 | `端口 8000 已被占用，先执行 bash stop.sh` |

然后 `docker run -d` 起容器（命令就是 `serve.sh`），最后 `docker logs -f` 跟日志。**`Ctrl+C` 只退出日志，服务继续跑。**

容器里补的几项不是"优化"，缺了会直接失败：

| 参数 | 缺了会怎样 |
|---|---|
| `--ipc=host` | 多 DP rank 需共享主机内存，缺失时起服务阶段报错 |
| `--ulimit nofile=1048576` | 默认 1024，HCCL 建链失败，日志只有 WARNING 不退出 |
| `--shm-size` | 共享内存不足，表现为进程被杀（OOM killer，无 Python 栈） |
| `--device /dev/davinci*` + 驱动挂载 | 容器内看不到卡 |

首次启动耗时构成（30B 量级、8 卡参考）：

| 阶段 | 耗时 | 观察点 |
|---|---|---|
| 加载权重 | 2–10 min | 日志出现分片加载进度 |
| 图捕获（cudagraph） | 5–20 min | `Capturing cudagraphs` |
| 编译 / 预热 | 1–5 min | `Application startup complete.` |

看到 `Application startup complete.` 才是真的起来了。**不要用"进程还在"判断成功**。

## 3. 验证

```bash
bash check.sh          # 退出码 0 才算交付
```

三层，逐层过：

```bash
# 1. 引擎自身
curl --noproxy '*' http://127.0.0.1:8000/health

# 2. 服务面
curl --noproxy '*' http://127.0.0.1:8000/v1/models

# 3. 真实推理
curl --noproxy '*' http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<SERVED_MODEL_NAME>","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

> 一定带 `--noproxy '*'`。宿主机若有 `http_proxy` 指向外网，curl 会把本地请求也发给代理，得到 502 或超时，然后你会去怀疑服务。

## 4. 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `only one device visible` / 只能看到 1 卡 | 设备节点没挂全 | 确认 `npu-smi info -l` 的卡数，重新 `bash start.sh` |
| 启动几十秒退出，无 Python 栈 | 共享内存不足 | 加 `--shm-size` 或 `--ipc=host` |
| `HCCL Communication_Error` | `nofile` 太小 / `NIC_NAME` 错 | 用 `start.sh` 起的容器已带 ulimit；核对网卡 |
| 显存 OOM | `GPU_MEM_UTIL` 过高或 `MAX_MODEL_LEN` 过大 | 降到 0.85，缩短上下文 |
| 加载到一半卡住 | 权重在慢速共享存储上 | 拷到本地 NVMe |
| 端口 8000 被占 | 上次容器还在 | `bash stop.sh` |
| `docker run` 卡很久后报网络错误 | 镜像没导入，docker 在尝试 pull | `docker load -i <镜像包>` |

详细排查见 [05-troubleshooting.md](05-troubleshooting.md)。

## 5. 准备上多机

单机跑通后，如果目标是 PD 分离，先确认三件事再继续：

1. 单机能跑通 → 模型、权重、镜像组合没问题；
2. 记录下单机的 `max-num-seqs` 与实测吞吐 → 作为 PD 的对照基线；
3. 检查主机内存余量 → PD 会把 P 和 D 的 offload 都压上来，比单机更吃内存。

继续阅读：[03-pd-disaggregation.md](03-pd-disaggregation.md)。
