#!/usr/bin/env python3
"""Install a locally supplied, commit-pinned SSR manyuser archive.

No network fetches and no protocol-core substitutions are performed here.
The archive must be supplied with a 40-hex commit and a SHA256 from a trusted
out-of-band source. The only source patch redacts a startup log line.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import tarfile
import tempfile
import zipfile

REQUIRED = [
    "shadowsocks/server.py",
    "shadowsocks/daemon.py",
    "shadowsocks/shell.py",
    "shadowsocks/encrypt.py",
    "shadowsocks/crypto/openssl.py",
    "shadowsocks/crypto/sodium.py",
    "shadowsocks/obfs.py",
    "shadowsocks/obfsplugin/auth.py",
    "shadowsocks/obfsplugin/auth_chain.py",
    "shadowsocks/obfsplugin/http_simple.py",
    "shadowsocks/obfsplugin/obfs_tls.py",
    "shadowsocks/obfsplugin/plain.py",
]
OLD_LOG = '''        logging.info("server start with protocol[%s] password [%s] method [%s] obfs [%s] obfs_param [%s]" %
                (protocol, password, method, obfs, obfs_param))'''
NEW_LOG = '''        # Passwords and obfs parameters are credentials; never write them to logs.
        logging.info("server start with protocol[%s] password [REDACTED] method [%s] obfs [%s] obfs_param [REDACTED]" %
                (protocol, method, obfs))'''


def safe_extract(archive: pathlib.Path, dest: pathlib.Path):
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            for member in zf.infolist():
                target = (dest / member.filename).resolve()
                if not str(target).startswith(str(dest.resolve()) + os.sep):
                    raise RuntimeError("压缩包包含越界路径")
                mode = (member.external_attr >> 16) & 0o170000
                if mode == stat.S_IFLNK:
                    raise RuntimeError("拒绝包含符号链接的核心压缩包")
            zf.extractall(dest)
        return
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive) as tf:
            for member in tf.getmembers():
                target = (dest / member.name).resolve()
                if not str(target).startswith(str(dest.resolve()) + os.sep):
                    raise RuntimeError("压缩包包含越界路径")
                if member.issym() or member.islnk():
                    raise RuntimeError("拒绝包含符号链接的核心压缩包")
                if not (member.isfile() or member.isdir()):
                    raise RuntimeError("拒绝包含设备文件/FIFO 等特殊文件的核心压缩包")
            tf.extractall(dest)
        return
    raise RuntimeError("核心文件必须是 zip 或 tar 压缩包")


def locate_root(root: pathlib.Path) -> pathlib.Path:
    matches = list(root.rglob("shadowsocks/server.py"))
    if len(matches) != 1:
        raise RuntimeError("压缩包中未能唯一定位 shadowsocks/server.py")
    return matches[0].parent.parent


def patch_log(core: pathlib.Path):
    path = core / "shadowsocks/server.py"
    text = path.read_text(encoding="utf-8")
    if NEW_LOG in text:
        return "already-redacted"
    if OLD_LOG not in text:
        raise RuntimeError("server.py 日志代码与已审查版本不匹配；拒绝盲目打补丁")
    path.write_text(text.replace(OLD_LOG, NEW_LOG, 1), encoding="utf-8")
    return "password-log-redaction-only"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--archive", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--destination", default="/usr/local/shadowsocksr")
    args = p.parse_args()
    archive = pathlib.Path(args.archive).resolve()
    dest = pathlib.Path(args.destination)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.commit):
        raise SystemExit("错误：必须提供 40 位固定 Git commit SHA")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
        raise SystemExit("错误：必须提供可信来源的 64 位 SHA256")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest.lower() != args.sha256.lower():
        raise SystemExit("错误：核心压缩包 SHA256 不匹配；拒绝安装")
    with tempfile.TemporaryDirectory(prefix="ssr-core-verify-") as tmp:
        extract = pathlib.Path(tmp)
        safe_extract(archive, extract)
        root_names = [x.name for x in extract.iterdir()]
        expected_root = "shadowsocksr-" + args.commit.lower()
        if expected_root not in root_names:
            raise RuntimeError("压缩包顶层目录必须严格为 %s；请使用 prepare-core-archive.sh 从固定 commit 生成归档，不要使用 manyuser 浮动分支压缩包" % expected_root)
        core = locate_root(extract)
        missing = [name for name in REQUIRED if not (core / name).is_file()]
        if missing:
            raise SystemExit("错误：核心文件不完整：" + ", ".join(missing))
        setup_text = (core / "setup.py").read_text(encoding="utf-8") if (core / "setup.py").exists() else ""
        version_match = re.search(r"version\s*=\s*[\'\"]([^\'\"]+)", setup_text)
        package_version = version_match.group(1) if version_match else "unknown"
        if package_version != "2.6.12":
            raise RuntimeError("核心 setup.py 版本不是预期的 2.6.12（实际：%s）；拒绝安装未审查版本" % package_version)
        if not re.search(r"install_requires\s*=\s*\[\s*\]", setup_text):
            raise RuntimeError("setup.py 的 install_requires 不为空或格式未知；必须重新审查 Python 依赖后再部署")
        patch_state = patch_log(core)
        # Normalize archive permissions: no setuid/setgid or world-writable code.
        for current, dirs, files in os.walk(core):
            os.chmod(current, 0o755)
            for name in files:
                item = pathlib.Path(current) / name
                if item.is_symlink():
                    raise RuntimeError("核心源码不允许包含符号链接：%s" % item)
                os.chmod(item, 0o755 if item.suffix == ".sh" else 0o644)
        patch_file = pathlib.Path(__file__).resolve().parents[1] / "patches" / "redact-server-password.patch"
        patch_hash = hashlib.sha256(patch_file.read_bytes()).hexdigest() if patch_file.is_file() else "unavailable"
        metadata = {
            "repository": "https://github.com/ToyoDAdoubiBackup/shadowsocksr",
            "branch_at_source": "manyuser",
            "commit": args.commit.lower(),
            "archive_sha256": digest,
            "package_version": package_version,
            "python_install_requires": [],
            "archive_preparation": "git archive from the exact commit; see install/prepare-core-archive.sh",
            "patches": [{"name": patch_state, "patch_file_sha256": patch_hash}],
            "protocol_core_replaced": False,
        }
        (core / "SSR-UBUNTU-CORE-METADATA.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        if dest.exists():
            raise RuntimeError("目标核心目录已存在；拒绝覆盖或替换现有核心。请先完成独立备份和迁移流程")
        shutil.copytree(core, dest)
    print("固定版本 SSR manyuser 核心已部署到：%s" % dest)
    print("版本元数据：%s" % (dest / "SSR-UBUNTU-CORE-METADATA.json"))


if __name__ == "__main__":
    main()
