# 五台 PD 分离（3P2D，5 台 × 16 卡）

三台 Prefill、两台 Decode，KV 走 Mooncake 池化。**五台共用同一份 `config.env`。**
目录里只有四个脚本：`start.sh`（按角色起）、`run_p.sh` / `run_d.sh`（单引擎命令）、`stop.sh`。

## 拓扑

| 节点 | 角色 | DP / TP | 全局 rank | 端口 |
|---|---|---|---|---|
| P1 | Prefill | 4 / 4 | 0–3 | 7100–7103 |
| P2 | Prefill | 4 / 4 | 4–7 | 7100–7103 |
| P3 | Prefill | 4 / 4 | 8–11 | 7100–7103 |
| D1 | Decode | 16 / 1 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 | 16–31 | 7100–7115 |

connector 是 `prefill dp 12 / decode dp 32`，代理对外 12 + 32 = 44 个端点。

P 侧是 `TP4 × DP4`，不是 PCP——这个镜像（openEuler 构建）没有 `--pcp-size`，只能靠 TP 占满 16 卡。

## 改哪几项

```bash
vim config.env
```

| 字段 | 填什么 |
|---|---|
| `MODEL_PATH` | 五台同一个绝对路径，容器内外一致 |
| `NIC_NAME` | 业务网卡名，脚本靠它认出本机是哪台 |
| `PREFILL_NODES` | 三台 P 的 IP，**顺序就是 rank 顺序** |
| `DECODE_NODES` | 两台 D 的 IP |
| `IMAGE` | 只有现场 tag 和默认值不同时才改 |

拓扑和端口不用动。`PREFILL_TP` 保持 4、`PREFILL_PCP` 保持 1。

## 起（顺序不能颠倒）

```bash
bash start.sh master     # 池化 master，只在一台起（一般 P1）
bash start.sh decode     # 两台 D，先起
bash start.sh prefill    # 三台 P
bash start.sh proxy      # 最后起代理，会先逐个确认后端 /health
```

每台只跑自己那一条。脚本会自己认出「本机是这一组的第几台」，算出 rank 起点，起之前在屏幕上打出来供核对。

顺序的原因：Decode 没起来就起 Prefill，Prefill 会挂在 KV 连接上，现象是**卡住不报错**；代理先起，客户端只会等到超时，而代理自己的 `/healthcheck` 反而是 200。

停止：`bash stop.sh`（把本机四个容器一起删）。

## 怎么算起来了

```bash
# 每个 rank 一行，Decode 应为 32，Prefill 应为 12
docker logs dsv41-3p2d-decode 2>&1 | grep -c 'Application startup complete'

# 代理
docker logs dsv41-3p2d-proxy 2>&1 | tail
curl --noproxy '*' http://127.0.0.1:1999/healthcheck
```

真实请求能出内容，才证明 P→D 的 KV 传输通了：

```bash
curl --noproxy '*' http://127.0.0.1:1999/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"你好"}],"max_tokens":32}'
```

## 池化占多少主机内存

按引擎乘，不是整台一个值（`MOONCAKE_SEGMENT` + `MOONCAKE_BUFFER`）：

| 节点 | 引擎数 | 占用 |
|---|---|---|
| P1–P3 | 4 | 约 12 GB |
| D1–D2 | 16 | 约 48 GB |

D 台原本就要 384G 起（16 个引擎 + Engram offload），加上这 48G，机器按 512G 准备。

## 防火墙

| 端口 | 谁连谁 |
|---|---|
| `7100-7115` | 代理 → 各引擎，以及节点互访 |
| `12321` | P/D 组内的 DP 协调 |
| `1999` | 客户端 → 代理 |
| `30000-30011`、`30100-30131` | P ↔ D 的 KV 传输 |
| `50099` | 五台 → master 那台 |
| `52000-52999` | 五台互访（HCCL 走 RoCE） |

## 起不来先看这几处

- **P 那台只有 4 张卡有显存** → `PREFILL_TP` 被改回 1 了，应该是 4。
- **后端全绿、请求 180 秒超时** → KV 端口没放开，或两侧 connector 不一致。看 `run_p.sh` / `run_d.sh` 里 `kv_connector_extra_config` 的 `dp_size` / `tp_size`。
- **进程凭空消失，`dmesg` 里有 `killed process`** → 池化内存给多了，降 `MOONCAKE_SEGMENT`。
- **报「镜像里没有 launch_online_dp.py」** → 路径不对，用 `docker run --rm $IMAGE find / -name launch_online_dp.py` 查出来填 `IMAGE_DIR`。
- **报 `unrecognized arguments: --pcp-size`** → 有人把 `PREFILL_PCP` 改成大于 1 了，这个镜像不认。
