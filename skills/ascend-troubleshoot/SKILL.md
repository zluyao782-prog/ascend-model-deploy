---
name: ascend-troubleshoot
description: 昇腾 vLLM Ascend 部署与运行期故障的现象分流排查，覆盖容器起不来、HCCL 建链失败、权重加载卡住、端口不通、代理 200 但请求挂住、结果异常、OOM、假死、性能偏低。当现场报错或服务行为异常需要定位根因时使用。触发词：起不来、卡住、HCCL、EI0015、报错、OOM、进程消失、请求超时、代理 200、输出乱码、排错。
---

# 昇腾部署排错：按现象分流

排错不是猜。先分流到具体分支，再按"确认 → 根因 → 处置"执行。**跳过确认步骤直接改参数，等于在制造新的变量。**

## 第 0 步：先留证据，再动手

```bash
bash _shared/collect_env.sh --config "$CFG"           # 本机
bash _shared/collect_env.sh --config "$CFG" --nodes   # 附带其他节点（需免密）
```

改之前的现场是唯一的一份。产出 `artifacts/env-<时间戳>.tar.gz`，含版本、拓扑、`dmesg` 尾、日志片段。

同时记住三条纪律：

1. **一次只改一个变量**。同时改三处然后好了，等于什么都没学到。
2. **区分「必然失败」与「偶发」**。偶发优先怀疑资源竞争与超时，不要从代码逻辑猜。
3. **区分「引擎崩了」与「被 OOM killer 杀了」**。后者没有 Python 栈，看起来就像"进程凭空消失"。

## 分流树

```
起不来（进程退出 / 报错）
├─ 容器就没起来              → A1
├─ 容器在、引擎退出          → A2 / A3
└─ 引擎在跑但端口不通        → A4

能起来但用不了
├─ /health 不通              → B1
├─ 代理 200 但请求挂住        → B2
└─ 能返回但结果异常           → B3

运行期 / 性能
├─ 不定期 OOM / 进程被杀      → C1
├─ 长时间没有进展（假死）      → C2
└─ 性能远低于预期             → C3 → 转 ascend-perf-tuning
```

## A. 起不来

### A1 容器启动失败 / 起来就退出

```bash
docker ps -a | grep ascend
docker logs <容器名> --tail 50
```

| 报错关键词 | 原因 | 修复 |
|---|---|---|
| `docker run` 卡很久后报 `connection refused` / `TLS handshake timeout` | **镜像没导入，docker 在尝试 pull**（内网最常见） | `docker load -i <镜像包>`；`start.sh` 已有此检查，别绕过它 |
| `no such file: /dev/davinci0` | 宿主驱动未装或装完没重启 | 装驱动后 `reboot`，先让 `npu-smi info` 能跑 |
| `permission denied` 挂载驱动 | 缺 `--privileged` | 用 `bash start.sh` 起，别手改 `docker run` |
| `cannot mount /usr/local/Ascend/driver` | 路径不存在 | 确认驱动安装路径；`start.sh` 会提示并跳过该挂载 |
| 无报错但 `Exited (0)` | 启动命令被改过（不是 `serve.sh`） | 回到 `bash start.sh` |

### A2 HCCL 建链失败（多机）

**现象**：`HCCL Communication_Error_Ranktable_Detect`、`EI0015`、`build connection timeout`，但进程**不退出**，只有 WARNING 刷屏。

按顺序确认，前一项不通过就不要看后一项：

```bash
docker exec <容器> ulimit -n                    # 必须 ≥ 1048576，1024 必挂
docker exec <容器> env | grep -E 'HCCL_IF_IP|HCCL_SOCKET_IFNAME'
ping -c 2 <对端IP>
for i in $(seq 0 7); do hccn_tool -i $i -link -g; done
```

| 根因 | 修复 |
|---|---|
| 容器内 `nofile=1024` | `bash stop.sh` 后重新 `bash start.sh`（脚本已带 `--ulimit nofile=1048576:1048576`） |
| `NIC_NAME` 填成管理口 | 换成有对端网段的业务口 |
| 多机驱动/固件版本不一致 | 逐台核对 `version.info`，对齐后重启 |
| 防火墙拦了 `12321` / `30000-30031` | 放开 TCP |

> 这类问题最坑的是**单机正常、多机才挂**，且不报错。所以 preflight 把 nofile 与网卡单独列成检查项。

### A3 权重加载失败 / 中途卡住

```bash
docker exec <容器> ls -la "$MODEL_PATH" | head
docker exec <容器> cat "$MODEL_PATH/config.json" | head -5
df -h "$(dirname "$MODEL_PATH")"
```

- **路径不一致**（多机最常见）：各 rank 加载的分片对不上，报错往往指向算子而不指向路径。4 台必须同一绝对路径，且宿主机 = 容器内。
- **文件不全**：比对 `config.json` 的 `md5sum`，`*.safetensors` 数量与 `weight_map` 一致。
- **共享存储慢**：加载耗时会差一个数量级，容易被误判为卡死。优先拷到本地 NVMe。

### A4 引擎在跑但端口不通

```bash
ss -lnt | grep -E '7100|8000|1999'
docker exec <容器> ss -lnt | grep 7100
```

- 端口被上次残留占着 → `bash stop.sh`
- 只监听 `127.0.0.1` → 启动参数需 `--host 0.0.0.0`
- PD 用了 bridge 网络 → 必须 `--network=host`

## B. 能起来但用不了

### B1 `/health` 不通

```bash
curl --noproxy '*' -v http://<IP>:<PORT>/health
```

**先加 `--noproxy '*'` 排除代理劫持，再去查服务。** 这个坑浪费的时间比它值得的多。

### B2 代理 `/healthcheck` 200 但请求挂住

PD 场景的头号问题，且**代理的健康检查会骗人**：它只反映注册了多少实例。

必须按顺序分层确认：

```bash
# 1. 逐个后端点名——只要有一个不是 OK，问题就不在代理
bash check.sh backends
# 2. 后端全绿后才看代理
curl --noproxy '*' http://<proxy>:1999/healthcheck
# 3. 最后才打真实请求
curl --noproxy '*' -m 180 http://<proxy>:1999/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<name>","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

| 根因 | 确认方式 | 修复 |
|---|---|---|
| 后端未全部就绪 | 第 1 步点名 | 等每个 rank 打印 `Application startup complete.` |
| KV 端口被防火墙拦 | 从 P 节点 `telnet <D_IP> 30100` | 放开 `30000-30031` |
| connector 两侧拓扑不一致 | 对比 P/D 模板的 `kv_connector_extra_config` | `dp_size` / `tp_size` 必须完全一致；`tp_size` 就是各侧的 TP（P 侧 4、D 侧 1） |
| 启动顺序错（先 P 后 D） | 看日志时间戳 | 严格 D → P → Proxy |

> **KV 端口不通的表现是挂住到超时，不是报错。** 看到"能连上代理、请求 180s 超时、后端全绿"，先查 KV 端口，不要怀疑模型。

### B3 能返回但结果异常

| 现象 | 原因 |
|---|---|
| 输出重复 / 乱码 | `--tokenizer-mode` 或 chat template 与模型不匹配 |
| 只输出几十字就停 | `max_tokens` 太小，或 EOS 判断问题 |
| 中英混杂、格式怪异 | `--reasoning-parser` / `--tool-call-parser` 选错 |
| 精度明显下降 | 量化格式与硬件不匹配（w4a8 权重跑在非 A3） |
| 能起但结果错、无报错 | TP 切分错误——**不要用"能起来"判断切分正确** |

新模型接入期这类问题集中出现，先过一遍 `ascend-model-onboarding` 的检查清单。

## C. 运行期

### C1 不定期 OOM / 进程被杀

```bash
dmesg | grep -i "killed process"     # 有输出就是 OOM killer，不是框架崩
docker stats --no-stream <容器>
free -g
```

| 类型 | 证据 | 处置 |
|---|---|---|
| 显存 OOM | 日志有 `NPU out of memory` | 降 `GPU_MEM_UTIL`（0.95 → 0.92）、缩 `MAX_MODEL_LEN` |
| 主机内存 OOM | `dmesg` 有 `killed process`，无 Python 栈 | 减 offload、降并发、加内存 |

第二种常被误判为"框架 bug"，因为它看起来就是进程突然消失。

### C2 超时设置造成的"假死"

| 变量 | 建议 |
|---|---|
| `VLLM_ENGINE_READY_TIMEOUT_S` | 保持 36000，**不要调小** |
| `HCCL_EXEC_TIMEOUT` | 压测阶段可设 600s 加快失败暴露；生产留默认 |

### C3 性能远低于预期

按顺序排除，别跳步：

1. `npu-smi info` 看 AICore 利用率——不高说明瓶颈不在算力；
2. `docker stats` 看 CPU / 内存是否打满；
3. 权重所在存储的读带宽；
4. 网卡带宽（PD 的 KV 传输很吃网卡）；
5. 最后才是模型参数。

确认瓶颈在 NPU 之后再转 `ascend-perf-tuning`。

## 修完之后：把结论沉淀成五字段

坑的归宿只有三处：`docs/05-troubleshooting.md`（通用）、模型 README「踩过的坑」（模型专属）、`_shared/` 里代码级规避的注释。

```markdown
### <一句话症状，便于搜索>

- 症状: 完整报错关键行（原样粘贴，不要改写）
- 触发条件: 机型 / 卡数 / 形态 / 并发
- 根因: 为什么会这样
- 处置: 可执行步骤
- 适用版本: 镜像 tag + CANN + vllm-ascend 版本
```

**「适用版本」必填**。不带版本结论的踩坑记录，半年后就是误导。结论失效时标题前标 `DEPRECATED` 并指向新结论，不要直接删。
