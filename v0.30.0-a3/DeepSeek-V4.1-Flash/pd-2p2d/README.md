# 四台 PD 分离（2P2D，4 台 × 16 卡）

两台 Prefill、两台 Decode。**四台共用同一份 `config.env`。**

## 拓扑

| 节点 | 角色 | DP / TP | 全局 rank | 端口 |
|---|---|---|---|---|
| P1 | Prefill | 4 / 4 | 0–3 | 7100–7103 |
| P2 | Prefill | 4 / 4 | 4–7 | 7100–7103 |
| D1 | Decode | 16 / 1 | 0–15 | 7100–7115 |
| D2 | Decode | 16 / 1 | 16–31 | 7100–7115 |

connector 是 `prefill dp 8 / decode dp 32`，代理对外 8 + 32 = 40 个端点。

## 改什么

```bash
vim config.env
```

| 字段 | 填什么 |
|---|---|
| `PREFILL_NODES` | 两台 P 的 IP，**顺序就是 rank 顺序** |
| `DECODE_NODES` | 两台 D 的 IP |
| `PROXY_NODE` | 代理跑哪台，一般 P1 |
| `MODEL_PATH` | 四台必须同一绝对路径 |

拓扑参数不用动。

## 起（顺序不能颠倒）

```bash
# 每个 Decode 节点，D1 先
bash start.sh decode

# 每个 Prefill 节点，P1 先
bash start.sh prefill

# 代理节点
bash start.sh proxy
```

Decode 先起是因为 Prefill 会向它发 KV。反过来的表现是卡住、不报错。

启动前会打印本机算出来的拓扑（第几台、全局 DP、rank 区间），**先核对再往下**。本机 IP 不在节点列表里会直接报错退出。

## 验

```bash
bash check.sh
```

逐个后端（P 8 个 + D 32 个）→ 代理 → 经代理的真实请求。

就绪条数：Decode 32 条、Prefill 8 条。

```bash
docker logs dsv41-2p2d-decode 2>&1 | grep -c 'Application startup complete'
```

## 四台之间要放开

`7100-7115`、`12321`、`30000-30007`、`30100-30131`、`1999`（TCP）。

## 停

```bash
bash stop.sh
```

## 起不来

先看 `../../README.md` 的「踩过的坑」。`VLLM_ENGINE_READY_TIMEOUT_S=36000` 是官方兜底值，别因为等太久就调小、重启。
