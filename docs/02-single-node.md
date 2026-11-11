# 02 单机部署

适用：模型能被单机 NPU 显存容纳，不需要 Prefill / Decode 分离。这是最简路径，也是验证镜像、权重、CANN 版本是否匹配的最快方式 —— **在搞多机 PD 之前，先用单机确认模型本身能跑起来**。

## 1. 配置

单机形态的配置在 `<版本>/<模型>/single/config.env`。已有该模型目录时直接改；没有就先从模板复制：

```bash
cp -r _template/vX.Y.Z-hw/ModelName v0.30.0-a3/<新模型名>
cd v0.30.0-a3/<新模型名>/single
vim config.env
```

关键项：

```bash
MODEL_PATH="/data/weights/Qwen3-32B"     # 权重绝对路径，宿主机=容器内
IMAGE="quay.io/ascend/vllm-ascend:v0.30.0-a2"
NIC_NAME="eth0"
DEPLOY_MODE="single"

SINGLE_TP=8          # 张量并行卡数
SINGLE_PORT=8000
QUANTIZATION="ascend"
MAX_MODEL_LEN=32768
```

`SINGLE_TP` 的选取：优先让 **TP = 单机 NPU 数**（8 卡机就填 8），这样单卡显存压力最小。模型小到单卡能放下时填 1 反而延迟更低，TP 跨卡通信是有代价的。

## 2. 拉起容器

```bash
bash ../../../_shared/start_container.sh
```

相比裸 `docker run`，脚本补了四项现场必需项，这四项不是"优化"，缺了会直接失败：

| 参数 | 缺了会怎样 |
|---|---|
| `--ipc=host` | 多 DP rank 需共享主机内存，缺失时起服务阶段报错 |
| `--ulimit nofile=1048576` | 默认 1024，HCCL 建链失败，日志只有 WARNING 不退出 |
| `--shm-size` | 共享内存不足，表现为进程被杀（OOM killer，无 Python 栈） |
| `/dev/davinci*` 设备挂载 | 容器内看不到卡 |

## 3. 启动服务

```bash
bash ./start.sh                 # 后台，日志 logs/single.log
bash ./start.sh --foreground    # 前台，便于观察加载过程
```

脚本在宿主机上执行会自动 `docker exec` 进容器；已在容器内则直接启动。启动后会自动等 `/health` 就绪（超时取 `VLLM_ENGINE_READY_TIMEOUT_S`）。

首次启动耗时构成（30B 量级、8 卡参考）：

| 阶段 | 耗时 | 观察点 |
|---|---|---|
| 加载权重 | 2–10 min | 日志出现分片加载进度 |
| 图捕获（cudagraph） | 5–20 min | `Capturing cudagraphs` |
| 编译 / 预热 | 1–5 min | `Application startup complete.` |

看到 `Application startup complete.` 才是真的起来了。**不要用"进程还在"判断成功**。

## 4. 验证

```bash
bash ../../../_shared/health_check.sh
```

三层验证，全部通过才算部署完成：

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

## 5. 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `ASCEND_RT_VISIBLE_DEVICES` 无效 / 只能看到 1 卡 | 设备节点没挂全 | `--device=/dev/davinciN` 逐个补，确认 `npu_count` |
| 启动几十秒退出，无 Python 栈 | 共享内存不足 | 加 `--shm-size` 或 `--ipc=host` |
| `HCCL Communication_Error` | `nofile` 太小 / `NIC_NAME` 错 | 加 ulimit；核对网卡 |
| 显存 OOM | `GPU_MEM_UTIL` 过高或 `MAX_MODEL_LEN` 过大 | 降到 0.85，缩短上下文 |
| 加载到一半卡住 | 权重在慢速共享存储上 | 拷到本地 NVMe |
| 端口 8000 被占 | 上次进程未退 | `bash ../../../_shared/stop.sh --services` |

详细排查见 [05-troubleshooting.md](05-troubleshooting.md)。

## 6. 准备上多机

单机跑通后，如果目标是 PD 分离，先确认三件事再继续：

1. 单机能跑通 → 模型、权重、镜像组合没问题；
2. 记录下单机的 `max-num-seqs` 与实测吞吐 → 作为 PD 的对照基线；
3. 检查主机内存余量 → PD 会把 P 和 D 的 offload 都压上来，比单机更吃内存。

继续阅读：[03-pd-disaggregation.md](03-pd-disaggregation.md)。
