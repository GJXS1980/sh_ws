#!/usr/bin/env python3
"""SSR/SS link generator matching Toyo ssr.sh v2.0.38 encoding rules."""
import argparse
import base64
import ipaddress
import json
import pathlib
import sys
import os
import subprocess


def b64url(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def make_ssr(ip: str, port: str, password: str, method: str, protocol: str, obfs: str) -> str:
    protocol_clean = protocol.replace("_compatible", "")
    obfs_clean = obfs.replace("_compatible", "")
    password_b64 = b64url(password)
    raw = "%s:%s:%s:%s:%s:%s" % (ip, port, protocol_clean, method, obfs_clean, password_b64)
    return "ssr://" + b64url(raw)


def ss_allowed(protocol: str, obfs: str) -> bool:
    protocol_suffix = protocol.split("_")[-1]
    obfs_suffix = obfs.split("_")[-1]
    if protocol == "origin":
        return obfs == "plain" or obfs_suffix == "compatible"
    if protocol_suffix != "compatible":
        return False
    return obfs_suffix in ("plain", "compatible")


def make_ss(ip: str, port: str, password: str, method: str) -> str:
    # Preserve the exact legacy ss:// Base64 payload shape.
    return "ss://" + b64url("%s:%s@%s:%s" % (method, password, ip, port))


def get_accounts(cfg):
    global_method = str(cfg.get("method", "aes-256-cfb"))
    global_protocol = str(cfg.get("protocol", "origin"))
    global_obfs = str(cfg.get("obfs", "plain"))
    if isinstance(cfg.get("port_password"), dict):
        result = []
        for port, value in sorted(cfg["port_password"].items(), key=lambda x: int(x[0])):
            if isinstance(value, str):
                password, method, protocol, obfs = value, global_method, global_protocol, global_obfs
            elif isinstance(value, list):
                password = value[0]
                method = global_method
                obfs = value[1] if len(value) > 1 else global_obfs
                protocol = value[2] if len(value) > 2 else global_protocol
            elif isinstance(value, dict):
                password = value.get("password", cfg.get("password", "m"))
                method = value.get("method", global_method)
                protocol = value.get("protocol", global_protocol)
                obfs = value.get("obfs", global_obfs)
            else:
                raise ValueError("port_password 用户配置类型无效")
            result.append((str(port), str(password), str(method), str(protocol), str(obfs)))
        return result
    return [(str(cfg.get("server_port", 8388)), str(cfg["password"]), global_method, global_protocol, global_obfs)]


def shutil_which(command):
    from shutil import which
    return which(command)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file", default="/etc/shadowsocksr/user-config.json")
    p.add_argument("--ip", required=True, help="服务器公网 IP 或域名；不会自动猜测公网地址")
    p.add_argument("--qr-dir", help="可选：使用本机 qrencode 生成二维码 PNG")
    args = p.parse_args()
    path = pathlib.Path(args.file)
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            raise ValueError("配置顶层不是 object")
        ip = args.ip.strip()
        if not ip:
            raise ValueError("服务器地址不能为空")
        # Validate IP literals, but allow hostnames. Do not rewrite the value,
        # because the legacy link encodes the supplied address verbatim.
        try:
            ipaddress.ip_address(ip.strip("[]"))
        except ValueError:
            if any(ch.isspace() for ch in ip) or "://" in ip or "/" in ip:
                raise ValueError("服务器地址格式无效")
        print("全局默认参数：method=%s protocol=%s obfs=%s" % (cfg.get("method", "aes-256-cfb"), cfg.get("protocol", "origin"), cfg.get("obfs", "plain")))
        qr_dir = pathlib.Path(args.qr_dir) if args.qr_dir else None
        if qr_dir:
            qr_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(qr_dir, 0o700)
            if not shutil_which("qrencode"):
                print("提示：本机未安装 qrencode，跳过二维码生成。", file=sys.stderr)
                qr_dir = None
        for port, password, method, protocol, obfs in get_accounts(cfg):
            print("\n端口：%s" % port)
            print("参数：method=%s protocol=%s obfs=%s" % (method, protocol, obfs))
            ssr_link = make_ssr(ip, port, password, method, protocol, obfs)
            print("SSR：%s" % ssr_link)
            if qr_dir:
                qr_path = qr_dir / ("ssr-%s.png" % port)
                subprocess.run(["qrencode", "-t", "PNG", "-o", str(qr_path)], input=ssr_link.encode("utf-8"), check=True)
                os.chmod(qr_path, 0o600)
                print("SSR 二维码：%s" % qr_path)
            if ss_allowed(protocol, obfs):
                ss_link = make_ss(ip, port, password, method)
                print("SS ：%s" % ss_link)
                if qr_dir:
                    qr_path = qr_dir / ("ss-%s.png" % port)
                    subprocess.run(["qrencode", "-t", "PNG", "-o", str(qr_path)], input=ss_link.encode("utf-8"), check=True)
                    os.chmod(qr_path, 0o600)
                    print("SS 二维码：%s" % qr_path)
            else:
                print("SS ：不满足原版 ss_ssr_determine() 的兼容条件，不生成")
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as e:
        print("错误：%s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
