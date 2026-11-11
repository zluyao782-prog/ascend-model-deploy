# 昇腾模型部署脚本库

团队共享的 **vLLM Ascend 部署脚本与实战记录**。一个镜像版本一个目录，版本下面按模型分，模型下面按部署形态（单机 / 组网）分，形态目录里是可以直接跑、也可以整目录复制到现场的脚本。

解决的问题很实际：同一个模型每换一次现场就重写一遍脚本，同一个坑每个人踩一遍。这里的原则是——**脚本只写一次，经验写进 README，坑写进排错文档**。

## 目录约定

```
ascend-model-deploy/
├── README.md                     本文件：仓库约定
├── CONTRIBUTING.md               提交规范与评审清单
├── _shared/                      跨版本跨模型的通用实现（只读复用，不复制）
├── _template/                    新增版本/模型时复制骨架
├── docs/                         通用知识：预检、调优、排错、模型接入
│
└── <镜像版本>/                    例：v0.30.0-a3
    ├── README.md                 该版本支持的模型清单
    ├── .tools/                   官方 launcher / 代理脚本（自动生成，gitignore）
    └── <模型名>/                  例：DeepSeek-V4.1-Flash
        ├── README.md             ★ 该模型的部署讲解（必填）
        ├── single/               单机形态
        │   ├── config.env        现场唯一要改的文件
        │   ├── start.sh          启动入口
        │   └── Makefile          快捷命令
        └── pd-2p2d/              组网形态（拓扑不同就再开一个目录）
            ├── config.env
            ├── start_p.sh / start_d.sh / start_proxy.sh
            ├── run_dp_template_p.sh / run_dp_template_d.sh
            └── Makefile
```

三个层次各管一件事：

| 层 | 内容 | 什么时候改 |
|---|---|---|
| `_shared/` | 环境体检、容器拉起、健康自检、rank 推导、代理端点生成 | 逻辑有 bug 或通用能力要加时才改，**改一处全体受益** |
| `<版本>/` | 镜像 tag、CANN 搭配、该版本收录了哪些模型 | 换了镜像版本 |
| `<模型>/<形态>/` | 权重路径、拓扑、端口、模型私有参数 | 每个现场都要改 `config.env` |

## 已收录

| 镜像版本 | 硬件 | 模型 | 形态 |
|---|---|---|---|
| [v0.30.0-a3](v0.30.0-a3/) | Atlas 800 A3 | [DeepSeek-V4.1-Flash](v0.30.0-a3/DeepSeek-V4.1-Flash/) | 单机（16 卡）/ PD 2P2D（4 台） |

## 快速开始

以 DeepSeek-V4.1-Flash 单机为例：

```bash
git clone <repo> && cd ascend-model-deploy/v0.30.0-a3/DeepSeek-V4.1-Flash/single

vim config.env                                                # 改 MODEL_PATH / IMAGE / NIC_NAME

bash ../../../_shared/preflight.sh --config config.env        # 1. 体检
bash ../../../_shared/start_container.sh --config config.env  # 2. 容器
bash ./start.sh                                               # 3. 启动
bash ../../../_shared/health_check.sh --config config.env     # 4. 验证
```

目录内 `make help` 可看全部快捷命令（`make preflight / up / single / check`）。

## 新增一个模型

```bash
cp -r _template/vX.Y.Z-hw/ModelName v0.30.0-a3/<新模型名>
```

然后按顺序做四件事：

1. 写 `<模型>/README.md`：硬件、拓扑、参数、踩过的坑（**这一项不做完不要提交**）
2. 填 `single/config.env` 或 `pd-*/config.env`：权重路径、TP/DP、端口
3. 组网形态补 `run_dp_template_p.sh` / `run_dp_template_d.sh`：模型私有启动参数从这里起（参考 DeepSeek 的模板改）
4. 实际跑通一遍：`preflight` → `health_check` → 长上下文 + 并发压测

不需要的形态（比如只需要单机）直接删掉对应目录，不要留空目录占位。

## 新增一个镜像版本

换硬件系列（A2 ↔ A3）或大版本升级时：

```bash
cp -r _template/vX.Y.Z-hw v0.30.0-a2-next
```

已跑通的旧版本目录**保持原样不动**——现场环境五花八门，旧版本随时可能被重新用到。

## 通用文档

| 文档 | 内容 |
|---|---|
| [01 环境准备与预检](docs/01-preflight.md) | 硬件软件基线、11 类检查项、端口规划 |
| [02 单机部署](docs/02-single-node.md) | 最简路径，验证镜像与权重 |
| [03 PD 分离部署](docs/03-pd-disaggregation.md) | 拓扑设计、启动顺序、代理端点、一致性约束 |
| [04 关键参数与调优](docs/04-tuning.md) | TP/DP 算法、性能参数相互作用、调优实验方法 |
| [05 排错手册](docs/05-troubleshooting.md) | 按现象分流的排查路径 |
| [06 新模型接入检查清单](docs/06-model-onboarding.md) | 换模型前必过的一遍 |

## 设计约定

1. **脚本不复制**：`_shared/` 里的实现被所有版本、所有模型调用，参数靠 `--config` 传入。避免"每个模型一份 preflight，改一处漏九处"。
2. **配置进目录**：每个部署形态一个 `config.env`，只描述"这一套怎么起"，不写通用逻辑。
3. **官方脚本不落库**：`launch_online_dp.py`、代理脚本由 `fetch_official.sh` 从镜像提取到 `<版本>/.tools/`，避免抄进仓库后版本漂移。
4. **P/D 模板不合并**：两侧参数集角色特定，混用会掉性能甚至起不来，宁可两份文件带互斥注释。
5. **README 是交付物**：脚本能跑只是及格，能让人三个月后照着 README 再跑一遍才算完成。
