# v0.30.0-a3 · vLLM Ascend 镜像版本

本目录对应**一个镜像版本 × 一个硬件系列**，其下按模型分目录。同一镜像版本能跑的所有模型都放在这里，共享 `_shared/` 通用脚本和本目录的 `.tools/`（官方 launcher 与代理脚本）。

## 版本信息

| 项 | 取值 |
|---|---|
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 硬件系列 | Atlas 800 **A3**（64G × 16 逻辑设备/台） |
| vLLM Ascend | v0.30.0rc1 及以上 |
| 对外端口约定 | 引擎 7100 起、DP 协调 12321、KV 30000/30100、代理 1999 |

> A2 与 A3 的镜像 tag 不通用。换硬件系列时**新建版本目录**（如 `v0.30.0-a2/`），不要在同目录里混用两种 tag。

## 本版本已收录模型

| 模型 | 部署形态 | 硬件 | 说明 |
|---|---|---|---|
| [DeepSeek-V4.1-Flash](DeepSeek-V4.1-Flash/) | 单机 / PD 2P2D | A3 ×1 / A3 ×4 | 552B MoE，w4a8 量化，1M 上下文 |

## 本目录内容

```
v0.30.0-a3/
├── README.md                本文件
├── .tools/                  官方脚本落盘位置（fetch_official.sh 生成，已 gitignore）
└── <模型名>/                 一个模型一个目录
    ├── README.md            ★ 该模型的部署讲解（必填）
    ├── single/              单机形态
    │   ├── config.env       本形态的配置
    │   ├── start.sh         启动入口
    │   └── Makefile         快捷命令
    └── pd-2p2d/             组网形态（拓扑不同就再开一个目录，如 pd-1p3d）
        ├── config.env
        ├── start_p.sh       Prefill 角色入口
        ├── start_d.sh       Decode 角色入口
        ├── run_dp_template_p.sh   Prefill 单 rank 模板（角色特定）
        ├── run_dp_template_d.sh   Decode  单 rank 模板（角色特定）
        ├── start_proxy.sh   PD 代理入口
        └── Makefile
```

## 在本版本下新增一个模型

```bash
# 从模板复制结构
cp -r ../../_template/v0.30.0-a3/ModelName ./<新模型名>
vim ./<新模型名>/README.md              # 写讲解：硬件、拓扑、参数、坑
vim ./<新模型名>/single/config.env      # 权重路径 / TP / 端口
vim ./<新模型名>/pd-2p2d/config.env     # 节点 IP / 拓扑 / KV 端口
```

如果新模型只需要单机，删掉 `pd-2p2d/`；只需要组网，删掉 `single/`。**不要留空目录占位**。

## 官方脚本

`launch_online_dp.py` 与 `load_balance_proxy_server_example.py` 随镜像分发，不提交到仓库（避免版本漂移）。首次使用任一 PD 部署时执行：

```bash
cd <模型>/pd-2p2d
bash ../../../../_shared/pd/fetch_official.sh
```

落盘到本目录 `.tools/`，同版本下所有模型共用。
