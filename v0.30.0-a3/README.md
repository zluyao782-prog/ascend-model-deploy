# v0.30.0-a3

vLLM Ascend 的 v0.30.0，A3 硬件。这个目录下一个模型一个文件夹，共用同一套镜像和端口约定。

| | |
|---|---|
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3` |
| 硬件 | Atlas 800 A3，64G × 16 逻辑设备每台 |
| vLLM Ascend | v0.30.0rc1 及以上 |
| 端口 | 引擎 7100 起，DP 协调 12321，KV 30000 / 30100，代理 1999 |

A2 和 A3 的 tag 不能混用。要跑 A2 就新建一个 `v0.30.0-a2/`，别在同一个目录里换 tag 凑合。

## 收录的模型

| 模型 | 形态 | 硬件 | 备注 |
|---|---|---|---|
| [DeepSeek-V4.1-Flash](DeepSeek-V4.1-Flash/) | 单机 / PD 2P2D | A3 ×1 / A3 ×4 | 552B MoE，w4a8，1M 上下文 |

## 加一个模型

复制一个跑通的，改配置和模型参数：

```bash
cp -r DeepSeek-V4.1-Flash ./Qwen3-32B
vim ./Qwen3-32B/single/config.env      # 权重路径、拓扑、端口
vim ./Qwen3-32B/single/serve.sh        # tokenizer、parser、量化这些模型参数
```

只要单机就把 `pd-2p2d/` 删掉，只要组网就把 `single/` 删掉。别留空目录占位。

## 官方脚本

`launch_online_dp.py` 和 `load_balance_proxy_server_example.py` 都随镜像分发，不进仓库——放进来过几个月就跟镜像版本对不上了。`start.sh` 直接从镜像里执行：

```
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/launch_online_dp.py
/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py
```

换镜像版本后如果路径变了，`start.sh` 会直接报"镜像里找不到 xxx"并给一条 find 命令。照着查出来，改脚本顶部那两行就行。
