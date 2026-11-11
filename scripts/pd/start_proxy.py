#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
start_proxy.py —— PD 代理启动器（通用版）

职责：读 config/env 里的节点列表与端口规划，自动生成
     (节点数 × 每台 DP 数) 个 Prefill / Decode 端点，
     再 exec 官方代理脚本 load_balance_proxy_server_example.py。

为什么需要这层包装：多机 PD 的后端端点数量是 节点数×每台引擎数，
     官方示例要求 --prefiller-hosts 与 --prefiller-ports 严格等长，
     手写列表极易出错且改拓扑时要改两处。

用法：
    python3 scripts/pd/start_proxy.py --dry-run      # 只打印将执行的命令
    python3 scripts/pd/start_proxy.py                # 前台启动
    nohup python3 scripts/pd/start_proxy.py > logs/proxy.log 2>&1 &
"""

import argparse
import os
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_CONFIG = os.path.join(ROOT, "config", "env")
PROXY_SCRIPT_NAME = "load_balance_proxy_server_example.py"


def _clean(val):
    """去引号、去行尾注释，与 shell 的 KEY=VALUE # 注释语义一致。"""
    val = val.strip()
    if val[:1] in ('"', "'"):
        q = val[0]
        end = val.find(q, 1)
        return val[1:end] if end != -1 else val[1:]
    return val.split("#", 1)[0].strip()


def load_config(path):
    cfg = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = _clean(v)
    return cfg


def split_nodes(value):
    """空格/逗号分隔的节点列表。"""
    return [n for n in value.replace(",", " ").split() if n]


def build_endpoints(hosts, base_port, per_host):
    return [(h, base_port + i) for h in hosts for i in range(per_host)]


def find_proxy_script(explicit):
    cands = []
    if explicit:
        cands.append(explicit)
    cands += [
        os.path.join(ROOT, ".tools", PROXY_SCRIPT_NAME),
        os.path.join(HERE, PROXY_SCRIPT_NAME),
        "/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/" + PROXY_SCRIPT_NAME,
    ]
    for p in cands:
        if p and os.path.isfile(p):
            return os.path.abspath(p)
    return None


def main():
    ap = argparse.ArgumentParser(description="PD 代理启动器（通用版）")
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=None, help="默认取 PROXY_PORT")
    ap.add_argument("--proxy-script", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.config):
        sys.stderr.write("配置文件不存在：%s\n先执行 cp config/env.example config/env\n" % args.config)
        return 1

    cfg = load_config(os.path.abspath(args.config))

    p_hosts = split_nodes(cfg.get("PREFILL_NODES", ""))
    d_hosts = split_nodes(cfg.get("DECODE_NODES", ""))
    if not p_hosts or not d_hosts:
        sys.stderr.write("config 中 PREFILL_NODES / DECODE_NODES 不能为空\n")
        return 1

    p_local = int(cfg.get("PREFILL_DP_LOCAL", 4))
    d_local = int(cfg.get("DECODE_DP_LOCAL", 16))
    p_base = int(cfg.get("PREFILL_BASE_PORT", 7100))
    d_base = int(cfg.get("DECODE_BASE_PORT", 7100))
    port = args.port or int(cfg.get("PROXY_PORT", 1999))

    prefills = build_endpoints(p_hosts, p_base, p_local)
    decoders = build_endpoints(d_hosts, d_base, d_local)

    script = find_proxy_script(args.proxy_script)
    if script is None:
        sys.stderr.write(
            "未找到官方代理脚本 %s\n"
            "  先执行： bash scripts/pd/fetch_official.sh\n" % PROXY_SCRIPT_NAME
        )
        return 2

    cmd = [sys.executable, script, "--host", args.host, "--port", str(port)]
    cmd += ["--prefiller-hosts"] + [h for h, _ in prefills]
    cmd += ["--prefiller-ports"] + [str(p) for _, p in prefills]
    cmd += ["--decoder-hosts"] + [h for h, _ in decoders]
    cmd += ["--decoder-ports"] + [str(p) for _, p in decoders]

    print("[proxy] script   : %s" % script)
    print("[proxy] listen   : %s:%d" % (args.host, port))
    print("[proxy] prefill  : %d 个端点  %s  (%d 台 × %d)" % (len(prefills), p_hosts, len(p_hosts), p_local))
    print("[proxy] decode   : %d 个端点  %s  (%d 台 × %d)" % (len(decoders), d_hosts, len(d_hosts), d_local))
    print("[proxy] cmd      : %s" % " ".join(shlex.quote(c) for c in cmd))

    if args.dry_run:
        return 0

    os.execv(sys.executable, cmd)


if __name__ == "__main__":
    sys.exit(main())
