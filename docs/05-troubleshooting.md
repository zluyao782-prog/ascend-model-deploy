# 05 排错手册

按「现象 → 大概率原因 → 怎么确认 → 怎么修」组织。现场先做一件事：**先跑 `bash scripts/collect_env.sh` 留证据**，再动手改。改完说不清改动前后差异的排错，等于重来一遍。

## 快速分流

```
起不来（进程退出/报错）
├─ 容器就没起来        → A1
├─ 容器起来了，引擎退   → A2 / A3
└─ 引擎在跑但不服务     → A4

能起来但用不了
├─ /health 不通        → B1
├─ 代理 200 但请求挂住  → B2
└─ 能返回但结果异常     → B3

性能不对
└─ 见 04-tuning.md 第 7 节
```

---

## A. 起不来

### A1 容器启动失败 / 起来就退出

**确认**

```bash
docker ps -a | grep ascend
docker logs <容器名> --tail 50
```

**常见原因**

| 报错关键词 | 原因 | 修复 |
|---|---|---|
| `no such file: /dev/davinci0` | 宿主机驱动未装或未重启 | 装驱动后 `reboot`，`npu-smi info` 先能跑 |
| `permission denied` 挂载驱动 | 未加 `--privileged` | 脚本已带，手动改过命令的要补回 |
| `cannot mount /usr/local/Ascend/driver` | 路径不存在 | 确认驱动安装路径，或让脚本跳过该挂载 |
| 无报错但 `Exited (0)` | 命令是 `sleep infinity` 被改写 | 用 `bash scripts/start_container.sh` 标准命令 |

### A2 HCCL 建链失败（多机）

**现象**：日志出现 `HCCL Communication_Error_Ranktable_Detect`、`EI0015`、`build connection timeout`，但进程**不退出**，只有 WARNING 刷屏。

**确认**

```bash
# 1. 文件句柄（最常见的根因）
docker exec <容器> ulimit -n        # 必须 ≥ 1048576，1024 必挂
# 2. 网卡是否一致
docker exec <容器> env | grep -E 'HCCL_IF_IP|HCCL_SOCKET_IFNAME'
# 3. 对端可达
ping -c 2 <对端IP>
# 4. 逐卡链路
for i in $(seq 0 7); do hccn_tool -i $i -link -g; done
```

**修复**

- `nofile` 小 → 重建容器（`start_container.sh` 已带 `--ulimit nofile=1048576:1048576`）
- 网卡填错 → 改 `NIC_NAME`，必须是有对端网段的业务口，不是管理口
- 驱动版本不一 → 多机驱动/固件版本必须一致，逐台核对 `version.info`
- 防火墙拦了 12321 / 30000-30031 → 放开 TCP

> 这类问题最坑的地方是**单机正常、多机才挂**，且不报错。所以 `preflight.sh` 把 nofile 和网卡单独列成检查项。

### A3 权重加载失败 / 中途卡住

**确认**

```bash
docker exec <容器> ls -la "$MODEL_PATH" | head
docker exec <容器> cat "$MODEL_PATH/config.json" | head -5
df -h "$(dirname "$MODEL_PATH")"
```

**原因与修复**

- 路径不一致（多机最常见）→ 4 台必须**同一绝对路径**，且宿主机与容器内一致。路径不同时各 rank 加载的分片对不上，报的错往往指向算子而不指向路径
- 文件不全 → 比对 `config.json` 的 `md5sum`，逐个 `*.safetensors` 数量一致
- 共享存储慢 → 拷到本地 NVMe。共享存储上的加载耗时会差一个数量级，且容易被误判为"卡死"

### A4 引擎在跑但端口不通

**确认**

```bash
ss -lnt | grep -E '7100|8000|1999'
docker exec <容器> ss -lnt | grep 7100
```

**原因**

- 端口被上一次的残留进程占着 → `bash scripts/stop.sh --services`
- 服务只监听 127.0.0.1 → 启动参数需 `--host 0.0.0.0`
- 容器用了 bridge 网络而 PD 需要跨机直连 → 用 `--network=host`

---

## B. 能起来但用不了

### B1 `/health` 不通

**确认**：`curl --noproxy '*' -v http://IP:PORT/health`

**注意**：宿主机若有 `http_proxy` 环境变量，curl 会把本地请求发给代理。**先加 `--noproxy '*'` 排除这种可能，再去查服务**。这个坑浪费的时间比它值得的多。

### B2 代理 `/healthcheck` 200 但请求挂住

这是 PD 场景的头号问题，且**代理的健康检查会骗人**。`/healthcheck` 只反映注册了多少实例，不反映后端是否可用。

**分层确认（必须按顺序）**

```bash
# 1. 逐个后端
bash scripts/health_check.sh --pd
# 只要有一个后端不是 OK，问题就不在代理

# 2. 后端全绿后再看代理
curl --noproxy '*' http://<proxy>:1999/healthcheck

# 3. 最后才打真实请求
curl --noproxy '*' -m 180 http://<proxy>:1999/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<name>","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

**常见根因**

| 根因 | 确认方式 | 修复 |
|---|---|---|
| 后端未全部就绪 | 第 1 步点名检查 | 等所有 rank 打印 `Application startup complete.` |
| KV 端口被防火墙拦 | 从 P 节点 `telnet D_IP 30100` | 放开 30000-30031 |
| connector 两侧拓扑不一致 | 对比 P/D 模板的 `kv_connector_extra_config` | 两侧 `dp_size`/`tp_size` 必须完全一致 |
| 启动顺序错（先 P 后 D） | 看日志时间戳 | 严格 D → P → Proxy |

> KV 端口不通的表现是**请求挂住到超时**，不是报错。看到"能连上代理、请求 180s 超时、后端全绿"，先查 KV 端口。

### B3 能返回但结果异常

| 现象 | 原因 |
|---|---|
| 输出重复 / 乱码 | `--tokenizer-mode` 或 chat template 与模型不匹配 |
| 只输出几十字就停 | `max_tokens` 太小，或模型自带 EOS 判断问题 |
| 中英混杂、格式怪异 | `--reasoning-parser` / `--tool-call-parser` 选错 |
| 精度明显下降 | 量化格式与硬件不匹配（如 w4a8 权重跑在非 A3 上） |

新模型接入时这类问题集中出现，先走一遍 [06-model-onboarding.md](06-model-onboarding.md) 的检查清单。

---

## C. 运行时问题

### C1 不定期 OOM / 进程被杀

**确认**

```bash
dmesg | grep -i "killed process"     # 有输出就是 OOM killer，不是框架崩
docker stats --no-stream <容器>
free -g
```

**区分两种 OOM**

- **显存 OOM**：日志有 `NPU out of memory` → 降 `GPU_MEM_UTIL`、缩 `MAX_MODEL_LEN`
- **主机内存 OOM**：`dmesg` 有 `killed process`，无 Python 栈 → 减 offload、降并发、加内存

第二种常被误判为"框架 bug"，因为它看起来就是进程突然消失。

### C2 超时设置造成的"假死"

| 变量 | 默认行为 | 建议 |
|---|---|---|
| `VLLM_ENGINE_READY_TIMEOUT_S` | 大模型加载慢会超时 | 保持 36000，**不要调小** |
| `HCCL_EXEC_TIMEOUT` | 故障时要干等很久 | 压测阶段可设 600s 加快失败暴露 |

### C3 性能远低于预期

按这个顺序排除，别跳步：

1. `npu-smi info` 看 AICore 利用率 —— 不高说明瓶颈不在算力
2. `docker stats` 看 CPU / 内存是否打满
3. 权重所在存储的读带宽
4. 网卡带宽（PD 的 KV 传输很吃网卡）
5. 最后才是模型参数

---

## D. 排错纪律

1. **先留证据再动手**：`bash scripts/collect_env.sh`，改之前的现场是唯一的一份。
2. **一次只改一个变量**：同时改三处然后好了，等于什么都没学到。
3. **区分「必然失败」与「偶发」**：偶发问题优先怀疑资源竞争与超时，不要从代码逻辑猜。
4. **记下来**：修完把现象与根因补进本文档。同一个坑踩两次是浪费，第三次是事故。
