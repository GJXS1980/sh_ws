#!/usr/bin/env bash
# Install only Ubuntu repository packages required by the manager.
# This script never enables a firewall or changes OpenSSL security policy.
set -Eeuo pipefail

fail() { echo "[错误] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail '请使用 sudo 运行。'
[[ -r /etc/os-release ]] || fail '无法识别系统版本。'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail "仅支持 Ubuntu；当前系统：${PRETTY_NAME:-unknown}。"
case "${VERSION_ID:-}" in 20.04|22.04|24.04|26.04) ;; *) fail "暂不支持 Ubuntu ${VERSION_ID:-unknown}。" ;; esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates python3 python3-venv iproute2 qrencode

if apt-cache show libsodium23 2>/dev/null | grep -q '^Package: libsodium23$'; then
    apt-get install -y libsodium23
elif apt-cache show libsodium-dev 2>/dev/null | grep -q '^Package: libsodium-dev$'; then
    apt-get install -y libsodium-dev
else
    echo '[警告] 软件源未提供 libsodium23/libsodium-dev；Salsa20/ChaCha20 算法尚不可用。' >&2
fi

PYTHON_BIN=${SSR_PYTHON_BIN:-python3}
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "找不到 Python：$PYTHON_BIN"
"$PYTHON_BIN" - <<'PY'
import sys
if sys.version_info < (3, 8):
    raise SystemExit("需要 Python 3.8 或更高版本；当前为 %s" % sys.version.split()[0])
print("Python 管理脚本运行时：", sys.version.split()[0])
if sys.version_info >= (3, 13):
    print("警告：Python 3.13+ 的 SSR manyuser 核心运行兼容性尚未验证。")
PY

if command -v ldconfig >/dev/null 2>&1; then
    ldconfig
    if ldconfig -p 2>/dev/null | grep -q 'libsodium'; then
        echo '[信息] libsodium 动态库已注册。'
    else
        echo '[警告] 尚未发现 libsodium 动态库；相关算法需在部署前单独验证。' >&2
    fi
fi
