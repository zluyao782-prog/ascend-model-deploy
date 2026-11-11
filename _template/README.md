# 新增骨架模板

新增**镜像版本**或**模型**时复制这里，避免每次都从零搭目录。

## 用法

```bash
# 新增一个模型（版本目录已存在）
cp -r _template/vX.Y.Z-hw/ModelName v0.30.0-a3/Qwen3-32B
cd v0.30.0-a3/Qwen3-32B

# 新增一个镜像版本
cp -r _template/vX.Y.Z-hw v0.30.0-a2
cd v0.30.0-a2 && mv ModelName <第一个模型名>
```

复制后按顺序做：

1. 把所有 `TODO` 换掉（`grep -rn TODO .`）
2. 写 `README.md` 六节内容
3. 组网形态补 `run_dp_template_p.sh` / `run_dp_template_d.sh`
   —— 从 `v0.30.0-a3/DeepSeek-V4.1-Flash/pd-2p2d/` 复制后改模型私有参数
4. 不需要的形态目录（`single/` 或 `pd-NpMd/`）删掉
5. 实测跑通再提交，见 `CONTRIBUTING.md` 评审清单

## 模板里有什么

```
vX.Y.Z-hw/ModelName/
├── README.md            六节骨架，必须填完
├── single/
│   ├── config.env       字段带 TODO 标记
│   ├── start.sh         调用 _shared/serve_single.sh（一般不用改）
│   └── Makefile         快捷命令（一般不用改）
└── pd-NpMd/
    ├── config.env       节点列表 / 拓扑 / KV 端口待填
    ├── start_p.sh       调 _shared/pd/start_role.sh（一般不用改）
    ├── start_d.sh       同上
    ├── start_proxy.sh   调 _shared/pd/start_proxy.py（一般不用改）
    └── Makefile
```

`start*.sh` 与 `Makefile` 是纯转发入口，不含模型信息，**通常原样使用**。
真正要写的是 `config.env`（现场参数）、`run_dp_template_*.sh`（模型私有启动参数）和 `README.md`（经验）。

## 目录名约定

| 占位 | 实际写法 |
|---|---|
| `vX.Y.Z-hw` | `v0.30.0-a3`、`v0.28.0-a2` |
| `ModelName` | 与官方模型名一致，如 `Qwen3-32B` |
| `pd-NpMd` | 按实际拓扑，如 `pd-2p2d`、`pd-1p3d` |
