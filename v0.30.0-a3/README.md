# v0.30.0-a3 · vLLM Ascend 镜像版本

本目录对应**一个镜像版本 × 一个硬件系列**，其下按模型分目录。同一镜像版本能跑的所有模型都放在这里。

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
└── <模型名>/                 一个模型一个目录
    ├── README.md            ★ 该模型的部署讲解（必填）
    ├── single/              单机形态
    │   ├── config.env       现场唯一要改的文件
    │   ├── serve.sh         那条 vllm serve 命令
    │   ├── start.sh         检查 + 起容器 + 跟日志
    │   ├── check.sh         服务能不能用
    │   └── stop.sh
    └── pd-2p2d/             组网形态（拓扑不同就再开一个目录，如 pd-1p3d）
        ├── config.env
        ├── start.sh         按角色起： prefill | decode | proxy
        ├── run_p.sh         Prefill 单个引擎的命令
        ├── run_d.sh         Decode 单个引擎的命令
        ├── check.sh
        └── stop.sh
```

## 在本版本下新增一个模型

复制一个已经跑通的模型目录，改配置和模型参数即可：

```bash
cp -r DeepSeek-V4.1-Flash ./<新模型名>
vim ./<新模型名>/single/config.env        # 权重路径 / 拓扑 / 端口
vim ./<新模型名>/single/serve.sh          # 模型参数（parser / 量化 / 投机解码）
```

只需要单机就删掉 `pd-2p2d/`，只需要组网就删掉 `single/`。**不要留空目录占位**。

## 官方脚本

`launch_online_dp.py` 与 `load_balance_proxy_server_example.py` 随镜像分发，**不提交到仓库**（避免版本漂移），`start.sh` 直接从镜像里执行：

```bash
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/launch_online_dp.py
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py
```

换镜像版本后如果路径变了，`start.sh` 会明确报"镜像里找不到 xxx"并给出 `find` 命令，改 `start.sh` 顶部那两行即可。
