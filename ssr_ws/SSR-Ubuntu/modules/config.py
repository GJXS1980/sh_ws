#!/usr/bin/env python3
"""Transactional JSON configuration manager for the legacy SSR manyuser core.

This module deliberately does not implement or replace any proxy protocol.
It edits the original manyuser JSON schema and preserves unknown fields.
"""
from __future__ import annotations

import argparse
import copy
import datetime as _dt
import fcntl
import hashlib
import grp
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, Optional

DEFAULT_CONFIG = pathlib.Path(os.environ.get("SSR_CONFIG_FILE", "/etc/shadowsocksr/user-config.json"))
METHODS = {
    "none", "rc4", "rc4-md5", "rc4-md5-6",
    "aes-128-ctr", "aes-192-ctr", "aes-256-ctr",
    "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
    "aes-128-cfb8", "aes-192-cfb8", "aes-256-cfb8",
    "salsa20", "chacha20", "chacha20-ietf",
}
PROTOCOLS = {
    "origin", "auth_sha1_v4", "auth_aes128_md5", "auth_aes128_sha1",
    "auth_chain_a", "auth_chain_b",
}
OBFS = {"plain", "http_simple", "http_post", "random_head", "tls1.2_ticket_auth"}
GLOBAL_FIELDS = {
    "method", "protocol", "protocol_param", "obfs", "obfs_param",
    "speed_limit_per_con", "speed_limit_per_user", "connect_verbose_info",
    "timeout", "udp_timeout", "dns_ipv6", "fast_open", "server", "server_ipv6",
}


class ConfigError(Exception):
    pass


def _port(value: Any, label: str = "端口") -> int:
    if isinstance(value, bool):
        raise ConfigError("%s必须是整数" % label)
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise ConfigError("%s必须是整数" % label)
    if n < 1 or n > 65535:
        raise ConfigError("%s必须在 1-65535 之间" % label)
    return n


def _limit(value: Any, label: str) -> int:
    if isinstance(value, bool):
        raise ConfigError("%s必须是非负整数" % label)
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise ConfigError("%s必须是非负整数" % label)
    if n < 0 or n > 131072:
        raise ConfigError("%s必须在 0-131072 之间" % label)
    return n


def _valid_plugin(value: Any, allowed: set[str], label: str, compatible: bool = False) -> None:
    if not isinstance(value, str):
        raise ConfigError("%s必须是字符串" % label)
    if value.endswith("_compatible"):
        if not compatible:
            raise ConfigError("%s不支持 _compatible 后缀" % label)
        value = value[:-11]
    if value not in allowed:
        raise ConfigError("不支持的%s：%s" % (label, value))


def validate_config(cfg: Any) -> Dict[str, Any]:
    if not isinstance(cfg, dict):
        raise ConfigError("配置顶层必须是 JSON object")
    if not isinstance(cfg.get("server", "0.0.0.0"), str):
        raise ConfigError("server 必须是字符串")
    if "server_ipv6" in cfg and not isinstance(cfg["server_ipv6"], str):
        raise ConfigError("server_ipv6 必须是字符串")
    method_value = cfg.get("method", "aes-256-cfb")
    if not isinstance(method_value, str):
        raise ConfigError("method 必须是字符串")
    _valid_plugin(method_value, METHODS, "加密方式")
    protocol_value = cfg.get("protocol", "origin")
    _valid_plugin(protocol_value, PROTOCOLS, "协议插件", compatible=True)
    if protocol_value.endswith("_compatible") and protocol_value[:-11] != "auth_sha1_v4":
        raise ConfigError("当前兼容模式仅开放 auth_sha1_v4_compatible")
    obfs_value = cfg.get("obfs", "plain")
    _valid_plugin(obfs_value, OBFS, "混淆插件", compatible=True)
    if obfs_value == "plain_compatible":
        raise ConfigError("plain 混淆不使用 _compatible 后缀")
    for key, label in (("speed_limit_per_con", "单线程限速"), ("speed_limit_per_user", "端口总限速")):
        if key in cfg:
            _limit(cfg[key], label)
    for key in ("timeout", "udp_timeout"):
        if key in cfg:
            try:
                if isinstance(cfg[key], bool) or int(cfg[key]) < 1:
                    raise ValueError()
            except (TypeError, ValueError):
                raise ConfigError("%s必须是正整数" % key)
    if "additional_ports" in cfg and not isinstance(cfg["additional_ports"], dict):
        raise ConfigError("additional_ports 必须是 JSON object")
    for key in ("protocol_param", "obfs_param", "redirect", "out_bind", "out_bindv6"):
        if key in cfg and not isinstance(cfg[key], str):
            raise ConfigError("%s 必须是字符串" % key)
    if "connect_verbose_info" in cfg and type(cfg["connect_verbose_info"]) is not int:
        raise ConfigError("connect_verbose_info 必须是整数")
    for key in ("dns_ipv6", "fast_open"):
        if key in cfg and not isinstance(cfg[key], bool):
            raise ConfigError("%s 必须是布尔值" % key)
    if "port_password" in cfg:
        users = cfg["port_password"]
        if not isinstance(users, dict) or not users:
            raise ConfigError("port_password 必须是至少包含一个用户的 JSON object")
        for p, pw in users.items():
            _port(p, "用户端口")
            if isinstance(pw, str):
                if not pw:
                    raise ConfigError("端口 %s 的密码不能为空" % p)
            elif isinstance(pw, list):
                if not pw or not isinstance(pw[0], str) or not pw[0]:
                    raise ConfigError("端口 %s 的扩展用户配置必须以非空密码开头" % p)
                if len(pw) > 1:
                    _valid_plugin(pw[1], OBFS, "用户混淆插件", compatible=True)
                    if pw[1] == "plain_compatible":
                        raise ConfigError("端口 %s 的 plain 混淆不使用 compatible 后缀" % p)
                if len(pw) > 2:
                    _valid_plugin(pw[2], PROTOCOLS, "用户协议插件", compatible=True)
                    if pw[2].endswith("_compatible") and pw[2][:-11] != "auth_sha1_v4":
                        raise ConfigError("端口 %s 的 protocol compatible 覆盖值无效" % p)
            elif isinstance(pw, dict):
                if "password" in pw and (not isinstance(pw["password"], str) or not pw["password"]):
                    raise ConfigError("端口 %s 的 password 必须是非空字符串" % p)
                for field in ("method", "protocol", "protocol_param", "obfs", "obfs_param", "out_bind", "out_bindv6"):
                    if field in pw and not isinstance(pw[field], str):
                        raise ConfigError("端口 %s 的 %s 必须是字符串" % (p, field))
                if "method" in pw:
                    _valid_plugin(pw["method"], METHODS, "用户加密方式")
                if "protocol" in pw:
                    _valid_plugin(pw["protocol"], PROTOCOLS, "用户协议插件", compatible=True)
                    if pw["protocol"].endswith("_compatible") and pw["protocol"][:-11] != "auth_sha1_v4":
                        raise ConfigError("端口 %s 的 protocol compatible 覆盖值无效" % p)
                if "obfs" in pw:
                    _valid_plugin(pw["obfs"], OBFS, "用户混淆插件", compatible=True)
                    if pw["obfs"] == "plain_compatible":
                        raise ConfigError("端口 %s 的 obfs compatible 覆盖值无效" % p)
            else:
                raise ConfigError("端口 %s 的用户配置必须是字符串、数组或对象" % p)
    else:
        _port(cfg.get("server_port", 8388), "server_port")
        if not isinstance(cfg.get("password"), str) or not cfg["password"]:
            raise ConfigError("单端口模式必须设置非空 password")
    return cfg


def load(path: pathlib.Path) -> Dict[str, Any]:
    if path.is_symlink():
        raise ConfigError("拒绝修改符号链接配置文件：%s" % path)
    try:
        with path.open("r", encoding="utf-8") as f:
            return validate_config(json.load(f))
    except FileNotFoundError:
        raise ConfigError("配置文件不存在：%s" % path)
    except json.JSONDecodeError as e:
        raise ConfigError("JSON 格式错误：%s" % e)


def _backup(path: pathlib.Path) -> pathlib.Path:
    backup_dir = path.parent / "backups"
    if backup_dir.is_symlink():
        raise ConfigError("拒绝写入符号链接备份目录：%s" % backup_dir)
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    dest = backup_dir / (path.name + "." + stamp + ".bak")
    shutil.copy2(path, dest)
    os.chmod(dest, 0o600)
    return dest


def _write_bytes_atomic(path: pathlib.Path, payload: bytes, mode: int = 0o640) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=str(path.parent))
    tmp = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        if os.geteuid() == 0:
            try:
                gid = grp.getgrnam("ssr").gr_gid
                os.chown(tmp, 0, gid)
            except KeyError:
                pass
        os.replace(tmp, path)
        dirfd = os.open(str(path.parent), os.O_DIRECTORY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def _write_atomic(path: pathlib.Path, data: Dict[str, Any], mode: int = 0o640) -> None:
    payload = (json.dumps(data, ensure_ascii=False, indent=4) + "\n").encode("utf-8")
    _write_bytes_atomic(path, payload, mode)


def _restart_service() -> None:
    if os.environ.get("SSR_SKIP_SYSTEMCTL") == "1":
        return
    if shutil.which("systemctl") is None:
        raise ConfigError("找不到 systemctl，无法验证配置变更后的服务状态")
    cat = subprocess.run(["systemctl", "cat", "ssr.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if cat.returncode != 0:
        raise ConfigError("ssr.service 尚未安装；为避免留下未生效配置，本次修改已取消")
    restart = subprocess.run(["systemctl", "restart", "ssr.service"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    active = subprocess.run(["systemctl", "is-active", "--quiet", "ssr.service"])
    if restart.returncode != 0 or active.returncode != 0:
        detail = (restart.stderr or restart.stdout or "systemd 未报告服务 active").strip()
        raise ConfigError("SSR 重启或状态检查失败：%s" % detail)


def _run_firewall(action: str, port: str):
    """Run the installed firewall helper and return (exit_code, combined_output)."""
    if os.environ.get("SSR_SKIP_FIREWALL") == "1":
        return 3, "[测试] 已跳过防火墙操作"
    helper = pathlib.Path(os.environ.get("SSR_FIREWALL_HELPER", str(pathlib.Path(__file__).with_name("firewall.sh"))))
    if not helper.is_file():
        return 2, "找不到防火墙管理脚本：%s" % helper
    proc = subprocess.run(
        ["bash", str(helper), action, str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return proc.returncode, (proc.stdout or "").strip()


def _service_status_text(restart_requested: bool) -> str:
    if not restart_requested:
        return "未执行重启（--no-restart）"
    if os.environ.get("SSR_SKIP_SYSTEMCTL") == "1":
        return "测试模式跳过 systemd 检查"
    if shutil.which("systemctl") is None:
        return "无法检查（systemctl 不存在）"
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", "ssr.service"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return "运行正常（active）" if result.returncode == 0 else "未运行或状态异常"


def transact(
    path: pathlib.Path,
    mutator,
    restart: bool = True,
    expected_sha256: Optional[str] = None,
    before_commit=None,
    rollback_hook=None,
) -> pathlib.Path:
    if path.is_symlink():
        raise ConfigError("拒绝通过符号链接修改配置文件：%s" % path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.parent / ("." + path.name + ".lock")
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    lock_fd = os.open(str(lock_path), flags, 0o600)
    with os.fdopen(lock_fd, "a+") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        old_bytes = path.read_bytes()
        if expected_sha256 and hashlib.sha256(old_bytes).hexdigest() != expected_sha256:
            raise ConfigError("配置文件在编辑期间已被其他操作修改；为避免覆盖新配置，本次手动编辑已取消")
        old_cfg = validate_config(json.loads(old_bytes.decode("utf-8")))
        new_cfg = copy.deepcopy(old_cfg)
        mutator(new_cfg)
        validate_config(new_cfg)
        backup = _backup(path)
        prepared = None
        prepare_completed = False
        try:
            # For add-user, open the port before committing the account. If any
            # subsequent write/restart step fails, rollback_hook removes only
            # the firewall rules created by this operation.
            if before_commit is not None:
                prepared = before_commit(old_cfg, new_cfg)
                prepare_completed = True
            _write_atomic(path, new_cfg)
            if restart:
                try:
                    _restart_service()
                except Exception:
                    _write_bytes_atomic(path, old_bytes, 0o640)
                    try:
                        _restart_service()
                    except Exception as rollback_error:
                        raise ConfigError(
                            "新配置启动失败，旧配置已恢复，但旧服务重启也失败：%s。备份：%s"
                            % (rollback_error, backup)
                        )
                    raise
            return backup
        except Exception:
            if prepare_completed and rollback_hook is not None:
                try:
                    rollback_hook(prepared)
                except Exception as firewall_rollback_error:
                    raise ConfigError(
                        "配置事务失败，且防火墙回滚失败：%s。请人工检查防火墙规则。备份：%s"
                        % (firewall_rollback_error, backup)
                    )
            raise


def _mode(cfg: Dict[str, Any]) -> str:
    return "multi" if "port_password" in cfg else "single"


def _set_global(cfg: Dict[str, Any], key: str, value: Any) -> None:
    if key not in GLOBAL_FIELDS and key not in {"password", "server_port"}:
        raise ConfigError("不允许直接修改字段：%s" % key)
    if key == "method":
        _valid_plugin(value, METHODS, "加密方式")
    elif key == "protocol":
        _valid_plugin(value, PROTOCOLS, "协议插件", compatible=True)
        if value.endswith("_compatible") and value[:-11] != "auth_sha1_v4":
            raise ConfigError("当前兼容模式仅开放 auth_sha1_v4_compatible")
    elif key == "obfs":
        _valid_plugin(value, OBFS, "混淆插件", compatible=True)
        if value == "plain_compatible":
            raise ConfigError("plain 混淆不使用 _compatible 后缀")
    elif key in ("speed_limit_per_con", "speed_limit_per_user"):
        value = _limit(value, key)
    elif key == "server_port":
        if _mode(cfg) != "single":
            raise ConfigError("多端口模式请通过 update-user 修改端口")
        value = _port(value)
    elif key == "password":
        if _mode(cfg) != "single":
            raise ConfigError("多端口模式请通过 update-user 修改对应用户密码")
        if not isinstance(value, str) or not value:
            raise ConfigError("密码不能为空")
    cfg[key] = value


def cmd_validate(args) -> None:
    load(pathlib.Path(args.file))
    print("VALID")


def cmd_accounts(args) -> None:
    cfg = load(pathlib.Path(args.file))
    if _mode(cfg) == "single":
        accounts = [{"port": str(cfg.get("server_port", 8388)), "password": cfg["password"]}]
    else:
        accounts = []
        for p, value in sorted(cfg["port_password"].items(), key=lambda x: int(x[0])):
            if isinstance(value, str):
                pw, method, protocol, obfs, extended = value, cfg.get("method", "aes-256-cfb"), cfg.get("protocol", "origin"), cfg.get("obfs", "plain"), False
            elif isinstance(value, list):
                pw = value[0]
                obfs = value[1] if len(value) > 1 else cfg.get("obfs", "plain")
                protocol = value[2] if len(value) > 2 else cfg.get("protocol", "origin")
                method, extended = cfg.get("method", "aes-256-cfb"), True
            else:
                pw = value.get("password", cfg.get("password", "m"))
                method = value.get("method", cfg.get("method", "aes-256-cfb"))
                protocol = value.get("protocol", cfg.get("protocol", "origin"))
                obfs = value.get("obfs", cfg.get("obfs", "plain"))
                extended = True
            accounts.append({"port": str(p), "password": pw, "method": method, "protocol": protocol, "obfs": obfs, "extended": extended})
    print(json.dumps({"mode": _mode(cfg), "accounts": accounts, "method": cfg.get("method", "aes-256-cfb"), "protocol": cfg.get("protocol", "origin"), "obfs": cfg.get("obfs", "plain"), "protocol_param": cfg.get("protocol_param", ""), "speed_limit_per_con": cfg.get("speed_limit_per_con", 0), "speed_limit_per_user": cfg.get("speed_limit_per_user", 0)}, ensure_ascii=False, indent=2))


def cmd_set(args) -> None:
    if args.json_stdin:
        value = json.loads(sys.stdin.read())
    elif args.json_value is not None:
        value = json.loads(args.json_value)
    else:
        raise ConfigError("缺少 JSON 值")
    backup = transact(pathlib.Path(args.file), lambda c: _set_global(c, args.key, value), not args.no_restart)
    print("配置已更新。备份：%s" % backup)


def cmd_set_many(args) -> None:
    if args.json_stdin:
        values = json.loads(sys.stdin.read())
    elif args.json_object is not None:
        values = json.loads(args.json_object)
    else:
        raise ConfigError("缺少批量 JSON object")
    if not isinstance(values, dict) or not values:
        raise ConfigError("批量修改参数必须是非空 JSON object")
    def mutate(c):
        for key, value in values.items():
            _set_global(c, key, value)
    backup = transact(pathlib.Path(args.file), mutate, not args.no_restart)
    print("批量配置已更新。备份：%s" % backup)


def cmd_add_user(args) -> None:
    port = str(_port(args.port))
    password = sys.stdin.readline().rstrip("\n") if args.password_stdin else args.password
    if not password:
        raise ConfigError("密码不能为空")

    firewall_state = {"status": "尚未检查", "output": ""}

    def mutate(c):
        if _mode(c) != "multi":
            raise ConfigError("当前是单端口模式，请先切换为多端口模式")
        if port in c["port_password"]:
            raise ConfigError("端口 %s 已存在" % port)
        c["port_password"][port] = password

    def prepare_firewall(_old_cfg, _new_cfg):
        rc, output = _run_firewall("allow", port)
        firewall_state["output"] = output
        if rc == 0:
            firewall_state["status"] = "TCP/UDP 已自动放行"
            return True
        if rc == 3:
            firewall_state["status"] = "未自动放行（没有可安全管理的已启用防火墙）"
            return False
        raise ConfigError(
            "防火墙自动放行失败，用户配置未提交：%s"
            % (output or "防火墙管理脚本返回错误")
        )

    def rollback_firewall(prepared):
        if prepared is True:
            rc, output = _run_firewall("remove", port)
            if rc != 0:
                raise ConfigError(output or "无法移除本次创建的防火墙规则")

    restart_requested = not args.no_restart
    backup = transact(
        pathlib.Path(args.file),
        mutate,
        restart_requested,
        before_commit=prepare_firewall,
        rollback_hook=rollback_firewall,
    )

    print("[完成] SSR 用户已添加。")
    print("用户端口：%s" % port)
    print("防火墙状态：%s" % firewall_state["status"])
    if firewall_state["output"]:
        for line in firewall_state["output"].splitlines():
            print("  " + line)
    print("SSR 服务状态：%s" % _service_status_text(restart_requested))
    print("配置备份：%s" % backup)
    if firewall_state["status"].startswith("未自动放行"):
        print("[注意] 请手动检查 VPS 防火墙及云平台安全组，确保 TCP/UDP %s 已放行。" % port)


def cmd_delete_user(args) -> None:
    port = str(_port(args.port))
    def mutate(c):
        if _mode(c) != "multi":
            raise ConfigError("当前不是多端口模式")
        if port not in c["port_password"]:
            raise ConfigError("端口 %s 不存在" % port)
        if len(c["port_password"]) <= 1:
            raise ConfigError("不能删除最后一个用户；请使用模式转换功能")
        del c["port_password"][port]
    backup = transact(pathlib.Path(args.file), mutate, not args.no_restart)
    print("用户已删除。备份：%s" % backup)


def cmd_update_user(args) -> None:
    old_port, new_port = str(_port(args.old_port)), str(_port(args.new_port))
    password = sys.stdin.readline().rstrip("\n") if args.password_stdin else args.password
    def mutate(c):
        if _mode(c) != "multi":
            raise ConfigError("当前不是多端口模式")
        users = c["port_password"]
        if old_port not in users:
            raise ConfigError("原端口不存在")
        if new_port != old_port and new_port in users:
            raise ConfigError("新端口已被其他用户占用")
        old_value = copy.deepcopy(users[old_port])
        if password is not None:
            if isinstance(old_value, str):
                old_value = password
            elif isinstance(old_value, list):
                old_value[0] = password
            elif isinstance(old_value, dict):
                old_value["password"] = password
        del users[old_port]
        users[new_port] = old_value
    backup = transact(pathlib.Path(args.file), mutate, not args.no_restart)
    print("用户已修改。备份：%s" % backup)


def cmd_mode(args) -> None:
    def mutate(c):
        current = _mode(c)
        if args.target == "multi":
            if current == "multi":
                return
            port = str(_port(c.get("server_port", 8388)))
            c["port_password"] = {port: c["password"]}
            c.pop("server_port", None)
            c.pop("password", None)
            return
        if current == "single":
            return
        users = c["port_password"]
        selected = str(_port(args.port))
        if selected not in users:
            raise ConfigError("指定端口不存在")
        pw = users[selected]
        if len(users) > 1 and not args.confirm_drop:
            raise ConfigError("多端口模式共有 %d 个用户；转换将保留端口 %s 并删除其余用户。请明确传入 --confirm-drop" % (len(users), selected))
        if isinstance(pw, str):
            c["password"] = pw
        elif isinstance(pw, list):
            if len(pw) > 3:
                raise ConfigError("所选用户包含未识别的扩展数组字段；为避免丢失数据，拒绝转换")
            c["password"] = pw[0]
            if len(pw) > 1:
                c["obfs"] = pw[1]
            if len(pw) > 2:
                c["protocol"] = pw[2]
        elif isinstance(pw, dict):
            # Promote the selected port's effective overrides to global fields
            # so its connection parameters survive the mode conversion.
            supported = {"password", "method", "protocol", "protocol_param", "obfs", "obfs_param", "out_bind", "out_bindv6"}
            unknown = set(pw) - supported
            if unknown:
                raise ConfigError("所选用户包含未识别的扩展字段 %s；为避免丢失数据，拒绝转换" % ", ".join(sorted(unknown)))
            c["password"] = pw.get("password", c.get("password", "m"))
            for key in ("method", "protocol", "protocol_param", "obfs", "obfs_param", "out_bind", "out_bindv6"):
                if key in pw:
                    c[key] = pw[key]
        else:
            raise ConfigError("所选用户的 manyuser 配置结构不受支持；未修改配置")
        c["server_port"] = int(selected)
        c.pop("port_password", None)
    backup = transact(pathlib.Path(args.file), mutate, not args.no_restart)
    print("端口模式已转换。备份：%s" % backup)


def cmd_replace(args) -> None:
    candidate = pathlib.Path(args.candidate)
    try:
        new_cfg = validate_config(json.loads(candidate.read_text(encoding="utf-8")))
    except json.JSONDecodeError as e:
        raise ConfigError("候选配置 JSON 格式错误：%s" % e)
    backup = transact(pathlib.Path(args.file), lambda c: (c.clear(), c.update(new_cfg)), not args.no_restart, args.expected_sha256)
    print("配置已替换。备份：%s" % backup)


def cmd_restore(args) -> None:
    backup = pathlib.Path(args.backup)
    if backup.is_symlink():
        raise ConfigError("拒绝从符号链接恢复配置")
    restored = validate_config(json.loads(backup.read_text(encoding="utf-8")))
    dest = pathlib.Path(args.file)
    current_backup = transact(dest, lambda c: (c.clear(), c.update(restored)), not args.no_restart)
    print("备份已恢复。恢复前配置备份：%s" % current_backup)


def cmd_runtime(args) -> None:
    cfg = load(pathlib.Path(args.source))
    # server.py daemonizes when the config contains "daemon". Remove only
    # process-management keys from this ephemeral copy; persistent config is untouched.
    for key in ("daemon", "pid-file", "log-file", "user"):
        cfg.pop(key, None)
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    _write_atomic(out, cfg, 0o640)
    print("runtime config generated")


def build_parser():
    p = argparse.ArgumentParser(description="SSR manyuser JSON manager")
    sub = p.add_subparsers(dest="command", required=True)
    for name, fn in (("validate", cmd_validate), ("accounts", cmd_accounts)):
        q = sub.add_parser(name)
        q.add_argument("--file", default=str(DEFAULT_CONFIG))
        q.set_defaults(func=fn)
    q = sub.add_parser("set")
    q.add_argument("key")
    q.add_argument("json_value", nargs="?")
    q.add_argument("--json-stdin", action="store_true")
    q.add_argument("--file", default=str(DEFAULT_CONFIG))
    q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_set)
    q = sub.add_parser("set-many")
    q.add_argument("json_object", nargs="?")
    q.add_argument("--json-stdin", action="store_true")
    q.add_argument("--file", default=str(DEFAULT_CONFIG))
    q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_set_many)
    q = sub.add_parser("add-user")
    q.add_argument("port"); q.add_argument("password", nargs="?")
    q.add_argument("--password-stdin", action="store_true")
    q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_add_user)
    q = sub.add_parser("delete-user")
    q.add_argument("port"); q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_delete_user)
    q = sub.add_parser("update-user")
    q.add_argument("old_port"); q.add_argument("new_port"); q.add_argument("--password")
    q.add_argument("--password-stdin", action="store_true")
    q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_update_user)
    q = sub.add_parser("mode")
    q.add_argument("target", choices=("single", "multi")); q.add_argument("--port", help="转换为单端口时要保留的端口")
    q.add_argument("--confirm-drop", action="store_true", help="明确确认丢弃未选中的多端口用户")
    q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_mode)
    q = sub.add_parser("replace")
    q.add_argument("--candidate", required=True); q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--expected-sha256")
    q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_replace)
    q = sub.add_parser("restore")
    q.add_argument("--backup", required=True); q.add_argument("--file", default=str(DEFAULT_CONFIG)); q.add_argument("--no-restart", action="store_true")
    q.set_defaults(func=cmd_restore)
    q = sub.add_parser("runtime")
    q.add_argument("--source", default=str(DEFAULT_CONFIG)); q.add_argument("--output", required=True)
    q.set_defaults(func=cmd_runtime)
    return p


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.func(args)
        return 0
    except (ConfigError, OSError, ValueError, json.JSONDecodeError) as e:
        print("错误：%s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
