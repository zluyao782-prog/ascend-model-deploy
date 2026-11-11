---
name: ascend-env-preflight
description: 昇腾 NPU 部署前的环境体检、内网镜像准备与环境快照采集。当需要判断机器能否跑 vLLM Ascend、部署前跑 preflight、确认镜像已导入本地、或为排错与交付留证据时使用。触发词：环境检查、体检、preflight、镜像导入、docker load、容器起不来、nofile 1024、HCCL 建链失败、/dev/shm 不足、环境快照、上现场验收。
---

# 昇腾部署环境预检与内网准备

部署失败的根因，八成在拉容器之前就埋好了。本 skill 的目标是：**在启动引擎之前把必然失败的因素全部排除**，并留一份可复现的环境证据。

现场大多在内网，所以这里**没有任何联网动作**：镜像靠 `docker load`，权重靠预先拷贝。

## 适用与边界

| 适用 | 不适用 |
|---|---|
| 新机器 / 新现场上架前的验收 | 服务已起来后的分层验证（走 `ascend-deploy-single` / `ascend-deploy-pd`） |
| 内网镜像与权重就位检查 | 已有明确报错的现象排障（走 `ascend-troubleshoot`） |
| 部署前统一体检（单机、多机） | 调优与性能基线（走 `ascend-perf-tuning`） |
| 排错或交付前采集快照 | |

## 步骤

### 1. 内网两件事先做完

**镜像**（脚本不会替你 pull，没导入就一定失败）：

```bash
# 有网的机器导出 → 拷到现场
docker save quay.io/ascend/vllm-ascend:v0.30.0-a3 -o vllm-ascend-v0.30.0-a3.tar

# 每台现场机器导入
docker load -i vllm-ascend-v0.30.0-a3.tar
docker images | grep vllm-ascend
```

**权重**：预下载到宿主机（ModelScope 必须带 `--revision`），多机时**同一绝对路径**，且宿主机 = 容器内。

```bash
ls /data/weights/<模型>/config.json /data/weights/<模型>/*.safetensors | head
```

### 2. 体检

```bash
# 仓库根目录执行
bash _shared/preflight.sh --config <版本>/<模型>/<形态>/config.env
bash _shared/preflight.sh --config <...> --all      # 多机额外 ssh 探测（需免密）
```

覆盖 11 类：发行版、NPU 与驱动、CANN、docker、权重与磁盘、内存与 `/dev/shm`、文件句柄、通信网卡、端口占用、跨节点连通性、代理环境变量。

**退出码**：`0` 全部通过（WARN 不算失败）；`1` 存在 FAIL 项。有 FAIL 就不要进下一步。

### 3. 判读：FAIL 必须修，WARN 必须解释

| 输出 | 含义 | 处置 |
|---|---|---|
| `nofile` 小于 1048576 | 多机 HCCL 建链失败的**头号根因**，引擎只打 WARNING 不退出 | `start.sh` 已带 `--ulimit nofile=1048576:1048576`；宿主机也建议同步 `limits.conf` |
| 网卡 DOWN / 不存在 | `NIC_NAME` 多半填了管理口 | 换成有对端网段 IP 的业务口，`ip -o addr show` 确认 |
| MTU < 4200 | RoCE 场景大包被分片，吞吐异常 | 与交换机侧对齐调到 4200 / 9000 |
| `/dev/shm` < 32G | 容器内共享内存不足 | `start.sh` 已带 `--ipc=host` 与 `--shm-size` |
| 内存 < `HOST_MEM_MIN_GB` | offload 与图捕获都吃主机内存 | 经验值 ≥ 2 倍权重体积；不足先减 offload |
| 权重目录不存在 / 缺 `config.json` | 路径错或权重不完整 | 多机必须同一绝对路径且容器内外一致 |
| 端口已占用 | 上一次的容器还在 | `bash stop.sh` |
| 检测到 `http_proxy` 等变量 | 本机 curl 会被代理劫持 | 后续所有本地探测一律加 `--noproxy '*'` |
| docker daemon 不可访问 | 权限或未启动 | `systemctl start docker`，或把用户加进 docker 组 |

> WARN 项没有解释就往下部署，等于把问题推到压测现场。交付文档里要写清每个 WARN 为何可接受。

### 4. 手工确认三件脚本查不了的事

1. **通信网卡是哪一块**：`ip -o addr show | grep -v ' lo '` 找带对端网段的业务口；`for i in $(seq 0 7); do hccn_tool -i $i -link -g; done` 逐卡看 Link UP。填错不会明确报错，表现是集合通信卡住到超时。
2. **权重完整性**：`ls "$MODEL_PATH"/config.json "$MODEL_PATH"/*.safetensors | head`；多机逐台 `md5sum` 比对 `config.json`。
3. **主机内存**：`free -g`，对照 `HOST_MEM_MIN_GB`。

### 5. 容器参数：由 start.sh 拉起，改脚本时别改坏这几项

容器不再单独起（没有 `start_container.sh` 了），由各形态的 `start.sh` 一次拉起。核对/维护 `start.sh` 时，下面这些**缺了会直接失败**：

| 参数 | 为什么必需 |
|---|---|
| `--ipc=host` | 多 DP rank 共享主机内存（Engram / offload），漏了起服务阶段就报错 |
| `--network=host` | PD 跨节点直连，bridge 网络下 KV 传输不可达 |
| `--privileged` | `npu-smi` / `hccn_tool` 需要 |
| `--ulimit nofile=1048576:1048576` | 默认 1024 直接导致 HCCL 建链失败 |
| `--shm-size` | 对应 `/dev/shm` 检查项 |
| 驱动五件套 `-v` | `/usr/local/Ascend/driver`、`/usr/local/dcmi`、`npu-smi`、`ascend_install.info`、`hccn.conf` |
| `--device` davinci* | 按实际卡数挂，少挂会导致可见卡数不匹配 |

`start.sh` 会跳过宿主机不存在的驱动路径并打印提示——**提示出现说明驱动装得不完整**，先修驱动再继续。

容器起来后确认：

```bash
docker exec -it <CONTAINER_NAME> bash -lc 'ulimit -n; python3 -c "import torch_npu; print(torch_npu.npu.device_count())"'
```

`device_count()` 必须等于本机卡数、`ulimit -n` 必须 ≥ 1048576。偏小就先停，别往下走。

### 6. 留证据

```bash
bash _shared/collect_env.sh --config <...>          # 本机
bash _shared/collect_env.sh --config <...> --nodes  # 附带其他节点（需免密）
```

产出 `artifacts/env-<时间戳>.tar.gz`，含版本、拓扑、`dmesg` 尾、日志片段、脱敏后的 `config.env`；刻意不收权重正文与密钥。**改之前的现场是唯一的一份**。

## 硬规则

- **不许出现 `docker pull`**。镜像只能 `docker load`。脚本缺镜像时的正确行为是提示后 `exit 1`。
- 不顺手动系统配置：不开防火墙、不调内核参数、不重装驱动。确需变更就显式说明并等用户确认。
- 不跳过 `nofile` 与网卡两项——它们的失败表现是"卡住不报错"，排查成本最高。
- 不用裸 `docker run` 绕开 `start.sh`。要加挂载就改 `start.sh` 里的 `MOUNTS`。

## 通过标准

- 镜像已 `docker load`，`docker images` 能看到该 tag；
- `preflight.sh` 退出码 0，每条 WARN 有解释；
- 容器内 `ulimit -n` ≥ 1048576、`device_count()` 等于卡数；
- `collect_env.sh` 快照已归档。

下一步：单机 → `ascend-deploy-single`；多机 PD → `ascend-deploy-pd`。
