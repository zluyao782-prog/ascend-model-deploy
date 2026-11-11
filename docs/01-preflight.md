# 01 环境准备与预检

> 部署失败的根因，八成在开始部署之前就已经埋好了。这一章的目标是：**在拉容器之前把必然失败的因素全部排除**。

## 1. 硬件与软件基线

| 层 | 要求 | 检查方式 |
|---|---|---|
| 服务器 | Atlas 800 训练/推理服务器（A2 或 A3） | `npu-smi info -l` 能看到卡 |
| 驱动 + 固件 | 与 CANN 版本配套，**驱动版本升级后必须重启** | `cat /usr/local/Ascend/driver/version.info` |
| CANN | 与 vLLM Ascend 镜像内版本匹配 | `cat /usr/local/Ascend/ascend-toolkit/latest/version.cfg` |
| 容器 | Docker 20.10+，daemon 可访问 | `docker info` |
| 通信 | 多机需 RoCE/HCCS 业务网口互通，MTU ≥ 4200 | `hccn_tool -i 0 -link -g` |

**版本搭配的原则**：镜像 tag 决定了 CANN 与 vLLM Ascend 的版本，宿主机驱动必须是该 CANN 支持的版本。驱动高于要求通常可以，低于要求会出现「容器里设备数量正常但初始化报错」。

## 2. 一键预检

```bash
make init          # 生成 config/env
vim config/env     # 填 MODEL_PATH / IMAGE / NIC_NAME
make preflight     # 每台机器各跑一次
```

多节点还可以加 `--all`：会 ssh 到其他节点探测 NPU 数与免密可用性（需先配好免密）。

```bash
bash scripts/preflight.sh --all
```

预检覆盖 11 类：发行版、NPU 与驱动、CANN、docker、权重与磁盘、内存与 `/dev/shm`、文件句柄、通信网卡、端口占用、跨节点连通性、代理环境变量。

**结果语义**：

- `OK` —— 通过
- `WARN` —— 不阻断，但很可能在压测时变成问题（如 MTU 偏小、`/dev/shm` 不足）
- `FAIL` —— 必然导致部署失败，必须先修

## 3. 三个必须手工确认的点

脚本查不了的，只能人看：

### 3.1 通信网卡是哪一个

多机场景下 `NIC_NAME` 填错**不会有明确报错**，表现为集合通信卡住直到超时。确认方法：

```bash
# 看哪块网卡有对端网段的 IP，通常是业务口而非管理口
ip -o addr show | grep -v " lo "

# 逐卡看链路状态，都有 Link UP 才算通
for i in $(seq 0 7); do hccn_tool -i $i -link -g; done
```

### 3.2 权重是否完整且路径一致

```bash
ls "$MODEL_PATH"/config.json "$MODEL_PATH"/*.safetensors | head
```

多机时逐台 `md5sum` 比对 `config.json`，能挡住「只拷了一半」这类低级问题。

### 3.3 主机内存是否够

大模型的 CPU offload（Engram 表、MoE 专家卸载）、Decode 图捕获都吃主机内存。经验值：**至少 2 倍权重体积**（量化权重另算），16 卡 A3 起步建议 512G 以上。

```bash
free -g
```

## 4. 端口规划

部署前先定端口，避免"起了一半发现端口被占"。

| 用途 | 默认 | 说明 |
|---|---|---|
| 单机服务 | 8000 | OpenAI 兼容入口 |
| P 引擎 | 7100 起 | 第 n 个 rank = 7100 + n |
| D 引擎 | 7100 起 | 与 P 不同机器，可复用同一段 |
| DP 协调 RPC | 12321 | 每组（P 组 / D 组）各一个 |
| KV producer | 30000 起 | **按 rank 递增**，范围最易漏 |
| KV consumer | 30100 起 | 同上 |
| PD 代理 | 1999 | 对外入口 |

多机防火墙需要放开：`7100-7115`、`12321`、`30000-30031`、`1999`（TCP）。KV 端口被拦的表现是**请求挂住而不是报错**，很难查。

## 5. 预检之后

```bash
make up        # 拉起容器
docker exec -it $(grep CONTAINER_NAME config/env | cut -d'"' -f2) bash
```

容器内再确认一次：

```bash
python3 -c "import vllm, torch, torch_npu; print(vllm.__version__, torch.__version__, torch_npu.npu.device_count())"
```

`device_count()` 应等于本机 NPU 数；偏小说明 `ASCEND_RT_VISIBLE_DEVICES` 或设备挂载有问题。

下一步：单机选 [02-single-node.md](02-single-node.md)，多机 PD 选 [03-pd-disaggregation.md](03-pd-disaggregation.md)。
