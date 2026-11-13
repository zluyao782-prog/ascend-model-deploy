# 双机 PD 分离（1P1D，2 台 × 16 卡）

两台机器，一台全做 Prefill，一台全做 Decode。**两台共用同一份 `config.env`。**

## 拓扑

| 节点 | 角色 | DP / TP | 全局 rank | 端口 |
|---|---|---|---|
| P1 | Prefill | 4 / 4 | 0–3 | 7100–7103 |
| D1 | Decode | 16 / 1 | 0–15 | 7100–7115 |

connector 是 `prefill dp 4 / decode dp 16`，代理对外 4 + 16 = 20 个端点。

## 改什么

```bash
vim config.env
```

| 字段 | 填什么 |
|---|---|
| `PREFILL_NODES` | P 那台的 IP |
| `DECODE_NODES` | D 那台的 IP |
| `PROXY_NODE` | 代理跑哪台，一般 P1 |
| `MODEL_PATH` | 两台必须同一绝对路径 |

拓扑参数（`*_DP_LOCAL` / `*_TP`）不用动，已经是 16 卡/台的配法：P 侧 `TP4 × DP4`，D 侧 `TP1 × DP16`。

P 侧为什么是 TP4 不是 PCP4：这个镜像（openEuler 构建）没有 `--pcp-size`，PCP 用不了，只能靠 TP 占满 16 卡。`PREFILL_PCP` 保持 1，模板会整条参数不传。

## 起（顺序不能颠倒）

```bash
# D 那台
bash start.sh decode

# P 那台
bash start.sh prefill

# 还在 P 那台，等后端全绿
bash start.sh proxy
```

Decode 先起是因为 Prefill 会向它发 KV。反过来的表现是**卡住、不报错**，很容易当成权重加载慢。

容器按角色命名（`dsv41-1p1d-prefill` / `-decode` / `-proxy`），所以代理和 Prefill 挤在 P1 上不会互相顶掉。

## 验

```bash
bash check.sh
```

先逐个后端 `/health`（P 4 个 + D 16 个），再代理，最后经代理打一次真实请求——最后这步才证明 KV 通了。

就绪条数：Decode 16 条、Prefill 4 条。

```bash
docker logs dsv41-1p1d-decode 2>&1 | grep -c 'Application startup complete'
```

## 两台之间要放开

`7100-7115`、`12321`、`30000-30003`、`30100-30115`、`1999`（TCP）。

KV 端口被拦的表现是请求挂到 180 秒超时，不是报错。

## 停

```bash
bash stop.sh
```

## 起不来

先看 `../../README.md` 的「踩过的坑」。代理 200 但请求挂住，基本是后端没全绿或 KV 端口没放开。
