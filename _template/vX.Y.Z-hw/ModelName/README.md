# <模型名> 昇腾部署

<!--
  这份 README 是该模型的交付物之一，六节内容缺一不可。
  参考 v0.30.0-a3/DeepSeek-V4.1-Flash/README.md 的写法。
-->

## 1. 模型与版本

| 项 | 取值 |
|---|---|
| 模型 | TODO |
| 参数量 / 结构 | TODO（MoE/稠密、激活参数、上下文长度） |
| 推荐权重 | TODO（精确名称，标注量化格式） |
| 下载地址 | TODO |
| 镜像 | TODO（精确到 tag） |
| 对外模型名 | TODO |

## 2. 硬件与拓扑

| 形态 | 硬件 | 拓扑 |
|---|---|---|
| 单机 | TODO | TP? × DP? |
| 组网 | TODO | P: DP?(PCP?) + D: DP?(TP?) |

端口规划：引擎 7100 起 / DP 协调 12321 / KV 30000·30100 / 代理 1999。

## 3. 配置要点

必须改的字段，以及"为什么是这个值"：

```bash
MODEL_PATH="..."    # 多机必须同一绝对路径，且容器内外一致
NIC_NAME="eth0"     # RoCE 业务口；填错不会报错，只会集合通信卡住
SINGLE_TP=8         # 8 卡机 TP=卡数，单卡显存压力最小
```

## 4. 启动步骤

```bash
cd <形态目录>
bash ../../../_shared/preflight.sh --config config.env
bash ../../../_shared/start_container.sh --config config.env
bash ./start.sh          # 单机；组网则 start_d.sh → start_p.sh → start_proxy.sh
bash ../../../_shared/health_check.sh --config config.env
```

就绪判定：TODO（看到什么日志才算起来，预计耗时）

## 5. 关键参数

| 参数 | 值 | 理由 |
|---|---|---|
| TODO | TODO | TODO |

角色差异（组网时）：TODO

## 6. 踩过的坑

> **现象**
> 根因与规避方式。

- TODO

## 7. 参考

- 官方教程：TODO
- 通用排错：`../../../docs/05-troubleshooting.md`
