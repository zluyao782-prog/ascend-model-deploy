# 五台 PD 分离（3P2D，5 台 × 16 卡）

三台 Prefill、两台 Decode，A3 rank 组网 + Mooncake 池化。**五台共用同一份 `config.env`。**

## 拓扑

| 节点 | 角色 | DP / TP / PCP | 全局 rank | 端口 |
|---|---|---|---|---|
| P1 | Prefill | 4 / 1 / 4 | 0–3 | 7100–7103 |
| P2 | Prefill | 4 / 1 / 4 | 4–7 | 7100–7103 |
| P3 | Prefill | 4 / 1 / 4 | 8–11 | 7100–7103 |
| D1 | Decode | 16 / 1 / 1 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 / 1 | 16–31 | 7100–7115 |

connector 是 `prefill dp 12 / decode dp 32`，代理对外 12 + 32 = 44 个端点。

## 改什么

```bash
vim config.env
```

| 字段 | 填什么 |
|---|---|
| `PREFILL_NODES` | 三台 P 的 IP，**顺序就是 rank 顺序** |
| `DECODE_NODES` | 两台 D 的 IP |
| `PROXY_NODE` | 代理跑哪台，一般 P1 |
| `MODEL_PATH` | 五台必须同一绝对路径 |

## rank 组网：三项五台必须一样

```bash
HCCL_INTER_HCCS_DISABLE="TRUE"   # 跨机走 RoCE
HCCL_INTRA_ROCE_ENABLE=1         # 机内也走 RoCE
HCCL_IF_BASE_PORT=52000          # HCCL 端口基址
```

差一个值就是建链卡住、或只连上一部分 rank，而且不会告诉你哪台配错。**改完必须整体 `stop.sh` + `start.sh`**，这两个变量只在进程启动时读一次。

核对办法：

```bash
docker inspect dsv41-3p2d-decode --format '{{range .Config.Env}}{{println .}}{{end}}' | grep HCCL_
```

## 池化：先起 master

代理那台（或任意一台）先跑：

```bash
mooncake_master --port 50099 --default_kv_lease_ttl 11000 \
  --eviction_high_watermark_ratio 0.9 --eviction_ratio 0.1
```

端口要和 `config.env` 的 `MOONCAKE_MASTER_PORT` 对上。`mooncake.json` 由 `start.sh` 按配置生成，不用手改。

**内存账**：`global_segment_size` 是每个引擎给的，不是整机给的。

| 节点 | 引擎 | 段 2GB + 缓冲 1GB | 合计 |
|---|---|---|---|
| P 台 | 4 | 8 + 4 | 约 12 GB |
| D 台 | 16 | 32 + 16 | 约 48 GB |

要叠加在本来的主机内存上（D 台 384G 打底）。启动时会打印本机要占多少。

## 起（顺序不能颠倒）

```bash
# 两台 Decode
bash start.sh decode

# 三台 Prefill
bash start.sh prefill

# 代理那台
bash start.sh proxy
```

## 验

```bash
bash check.sh
```

逐个后端（P 12 个 + D 32 个）→ 代理 → 经代理的真实请求。

就绪条数：Decode 32 条、Prefill 12 条。

## 五台之间要放开

`7100-7115`、`12321`、`1999`、`30000-30011`、`30100-30131`、`52000-52999`（TCP）。

## 停

```bash
bash stop.sh
```

## 起不来

先看 `../../README.md` 的「踩过的坑」。三个高频原因：KV 端口没放开（挂住不报错）、池化内存算多了（进程凭空消失、`dmesg` 有 `killed process`）、rank 组网变量某台不一致（建链卡住）。
