#!/usr/bin/env python3
"""Build and verify a clean SSR-Ubuntu source ZIP package."""
import argparse
import hashlib
import pathlib
import stat
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXCLUDE_DIRS = {".git", "__pycache__", ".pytest_cache", ".mypy_cache", "dist"}
EXCLUDE_NAMES = {"MANIFEST.sha256"}


def files_to_package():
    result = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in EXCLUDE_DIRS for part in rel.parts):
            continue
        if path.name.endswith((".pyc", ".pyo")) or path.name in EXCLUDE_NAMES:
            continue
        result.append(path)
    return sorted(result, key=lambda p: p.relative_to(ROOT).as_posix())


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def build(output):
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    files = files_to_package()
    manifest_lines = ["%s  %s" % (sha256(p), p.relative_to(ROOT).as_posix()) for p in files]
    manifest = ROOT / "MANIFEST.sha256"
    manifest.write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
    files = files_to_package() + [manifest]
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in sorted(files, key=lambda p: p.relative_to(ROOT).as_posix()):
            rel = path.relative_to(ROOT).as_posix()
            info = zipfile.ZipInfo("SSR-Ubuntu/" + rel)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = path.stat().st_mode
            info.external_attr = (stat.S_IFREG | (mode & 0o777)) << 16
            zf.writestr(info, path.read_bytes())
    with zipfile.ZipFile(output) as zf:
        bad = zf.testzip()
        if bad:
            raise RuntimeError("ZIP CRC 校验失败：%s" % bad)
        names = set(zf.namelist())
        required = {
            "SSR-Ubuntu/ssr.sh",
            "SSR-Ubuntu/README.md",
            "SSR-Ubuntu/original/ssr.sh.v2.0.38",
            "SSR-Ubuntu/install/core_install.py",
            "SSR-Ubuntu/core/CORE_PIN_STATUS.md",
            "SSR-Ubuntu/reports/test-report.md",
            "SSR-Ubuntu/MANIFEST.sha256",
        }
        missing = required - names
        if missing:
            raise RuntimeError("ZIP 缺少交付文件：%s" % ", ".join(sorted(missing)))
        if any("__pycache__" in name or name.endswith(".pyc") for name in names):
            raise RuntimeError("ZIP 不应包含 Python 缓存文件")
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="/mnt/data/SSR-Ubuntu-project.zip")
    args = parser.parse_args()
    output = build(pathlib.Path(args.output))
    print("ZIP：%s" % output)
    print("大小：%d bytes" % output.stat().st_size)
    print("SHA256：%s" % sha256(output))
    print("MANIFEST：%s" % (ROOT / "MANIFEST.sha256"))


if __name__ == "__main__":
    main()
