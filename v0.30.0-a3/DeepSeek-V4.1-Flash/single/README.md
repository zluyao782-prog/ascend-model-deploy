# 单机部署（1 台 × 16 卡）

这个目录整包拷到现场就能用。**要改的只有 `config.env`。**

## 拓扑

DP4 × TP4 = 16 卡。552B 权重单卡放不下，TP 不能取 1。

## 改什么

```bash
vim config.env
```

| 字段 | 填什么 |
|---|---|
| `MODEL_PATH` | 权重绝对路径，宿主机和容器内一致 |
| `IMAGE` | 默认 `quay.io/ascend/vllm-ascend:v0.30.0-a3-openeuler`，要和现场 `docker load` 进来的 tag 完全一致 |
| `NIC_NAME` | 业务口，不是管理口 |

`MAX_MODEL_LEN` 默认 128K。显存不够先降这个。

## 起

```bash
bash start.sh
```

脚本先查五件事：权重目录、本地镜像、卡数 ≥ TP×DP、8000 端口空闲、网卡有没有 IPv4。任何一件不对当场退出并说明原因，**不会去 pull 镜像**。

检查通过后跟日志。首次 5–15 分钟，看到 `Application startup complete.` 才算起来。`Ctrl+C` 只退出日志，服务继续跑。

## 验

```bash
bash check.sh
```

`/health` → `/v1/models` → 一次真实对话，三层全过退出码才是 0。

## 停

```bash
bash stop.sh
```

## 起不来

先看 `../../README.md` 的「踩过的坑」，再查 `../../docs/05-troubleshooting.md`。

最常见两个：宿主机有 `http_proxy` 导致 curl 假故障（命令里带 `--noproxy '*'`）；显存 OOM 就降 `MAX_MODEL_LEN` 或 `GPU_MEM_UTIL`。
