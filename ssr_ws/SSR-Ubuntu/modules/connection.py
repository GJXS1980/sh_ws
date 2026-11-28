#!/usr/bin/env python3
"""TCP peer-IP accounting from ss; UDP is deliberately reported separately."""
import argparse
import concurrent.futures
import ipaddress
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote
from urllib.request import Request, urlopen


def split_endpoint(value):
    value = value.strip()
    if value.startswith("["):
        end = value.rfind("]:")
        if end < 0:
            return value, None
        return value[1:end], value[end + 2:]
    if ":" not in value:
        return value, None
    host, port = value.rsplit(":", 1)
    return host, port


def normal_ip(host):
    if host.startswith("::ffff:"):
        host = host[7:]
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        return host


def tcp_connections():
    proc = subprocess.run(["ss", "-Htn", "state", "established"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "ss 命令执行失败")
    records = []
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        local_host, local_port = split_endpoint(fields[3])
        remote_host, remote_port = split_endpoint(fields[4])
        if local_port and remote_host:
            records.append((int(local_port), normal_ip(remote_host)))
    return records


def udp_listeners():
    proc = subprocess.run(["ss", "-Huan"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        return []
    result = []
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 5:
            _, port = split_endpoint(fields[3])
            if port and port.isdigit():
                result.append(int(port))
    return sorted(set(result))


def geo_lookup_one(ip):
    url = "https://ipapi.co/%s/json/" % quote(ip, safe=":.")
    req = Request(url, headers={"User-Agent": "SSR-Ubuntu/0.1 (optional IP geolocation)"})
    with urlopen(req, timeout=4) as response:
        data = json.loads(response.read().decode("utf-8"))
    if not isinstance(data, dict) or data.get("error"):
        return None
    parts = [data.get("city"), data.get("region"), data.get("country_name") or data.get("country")]
    return ", ".join(str(x) for x in parts if x) or None


def geo_batch(ips):
    cache_path = pathlib.Path(os.environ.get("SSR_GEO_CACHE", "/var/cache/ssr-ubuntu/geo-cache.json"))
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(cache_path.parent, 0o700)
    except OSError:
        pass
    try:
        cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    except Exception:
        cache = {}
    now = int(time.time())
    result = {}
    pending = []
    for ip in ips:
        try:
            addr = ipaddress.ip_address(ip)
            if not addr.is_global:
                result[ip] = "非公网地址"
                continue
        except ValueError:
            result[ip] = "地址格式无效"
            continue
        item = cache.get(ip)
        if isinstance(item, dict) and now - int(item.get("timestamp", 0)) < 30 * 86400 and item.get("location"):
            result[ip] = item["location"]
        else:
            pending.append(ip)
    if pending:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            future_map = {pool.submit(geo_lookup_one, ip): ip for ip in pending}
            for future in concurrent.futures.as_completed(future_map):
                ip = future_map[future]
                try:
                    location = future.result()
                except Exception:
                    location = None
                if location:
                    result[ip] = location
                    cache[ip] = {"timestamp": now, "location": location}
                else:
                    result[ip] = "查询失败/限流"
    try:
        fd, temp_name = tempfile.mkstemp(prefix=".geo-cache-", dir=str(cache_path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, cache_path)
    except OSError:
        pass
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="/etc/shadowsocksr/user-config.json")
    p.add_argument("--geo", action="store_true", help="将公网远端 IP 通过 HTTPS 发送给 ipapi.co 查询归属地；默认关闭")
    args = p.parse_args()
    try:
        cfg = json.load(open(args.config, encoding="utf-8"))
        ports = [int(x) for x in cfg["port_password"].keys()] if isinstance(cfg.get("port_password"), dict) else [int(cfg["server_port"])]
        peers = tcp_connections()
        all_ips = sorted({ip for _, ip in peers})
        print("TCP ESTABLISHED 唯一远端 IP 数量：%d" % len(all_ips))
        geo = geo_batch(all_ips) if args.geo and all_ips else {}
        print("TCP 远端 IP：%s" % (", ".join(all_ips) if all_ips else "无"))
        if geo:
            for ip in all_ips:
                print("  %s：%s" % (ip, geo.get(ip, "未查询")))
        for port in ports:
            ips = sorted({ip for local_port, ip in peers if local_port == port})
            labels = [ip + (" (" + geo[ip] + ")" if ip in geo else "") for ip in ips]
            print("端口 %d：TCP 唯一远端 IP %d；%s" % (port, len(ips), ", ".join(labels) if labels else "无"))
        udp = udp_listeners()
        print("UDP：ss 只能显示本机 UDP socket/监听端口，不能据此计算 TCP ESTABLISHED 式的 UDP 会话数。")
        print("本机 UDP socket 端口：%s" % (", ".join(map(str, udp)) if udp else "未发现"))
    except Exception as e:
        print("错误：%s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
