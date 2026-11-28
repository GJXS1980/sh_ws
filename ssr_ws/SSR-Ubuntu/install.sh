#!/usr/bin/env bash
# One-command bootstrap for the pinned SSR-Ubuntu release.
# The upstream core is fetched only from the exact locked commit and verified
# against the SHA256 recorded in core/CORE.lock before installation.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCK="$ROOT/core/CORE.lock"
fail() { echo "[错误] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail '请使用 sudo 或 root 运行：sudo bash ./install.sh'
[[ -r /etc/os-release ]] || fail '无法识别操作系统。'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail "仅支持 Ubuntu；当前系统：${PRETTY_NAME:-unknown}。"
[[ -f "$LOCK" ]] || fail "缺少核心锁定文件：$LOCK"

lock_value() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' "$LOCK"
}

COMMIT=$(lock_value CORE_COMMIT)
EXPECTED_SHA=$(lock_value CORE_SHA256)
ARCHIVE_REL=$(lock_value CORE_ARCHIVE)
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'CORE.lock 中 CORE_COMMIT 格式错误。'
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || fail 'CORE.lock 中 CORE_SHA256 格式错误。'
[[ "$ARCHIVE_REL" == core/archives/* ]] || fail 'CORE.lock 中 CORE_ARCHIVE 路径不受支持。'

if [[ -n "${SSR_CORE_ARCHIVE:-}" ]]; then
    ARCHIVE=$SSR_CORE_ARCHIVE
else
    ARCHIVE="$ROOT/$ARCHIVE_REL"
fi

if [[ ! -s "$ARCHIVE" ]]; then
    [[ -z "${SSR_CORE_ARCHIVE:-}" ]] || fail "指定的 SSR_CORE_ARCHIVE 不存在：$ARCHIVE"
    CACHE_DIR=/var/cache/ssr-ubuntu/core
    CACHE_ARCHIVE="$CACHE_DIR/shadowsocksr-${COMMIT}.tar.gz"
    install -d -m 0700 "$CACHE_DIR"
    if [[ -s "$CACHE_ARCHIVE" ]]; then
        ARCHIVE=$CACHE_ARCHIVE
    else
        command -v git >/dev/null 2>&1 || {
            echo '[信息] 正在安装 Git，以便从固定 Commit 生成核心归档。'
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y git ca-certificates gzip
        }
        echo '[信息] 正在获取固定 manyuser Commit；不会使用浮动分支 ZIP 或上游一键安装脚本。'
        bash "$ROOT/install/prepare-core-archive.sh" "$CACHE_DIR" "$COMMIT"
        ARCHIVE=$CACHE_ARCHIVE
    fi
fi

[[ -s "$ARCHIVE" ]] || fail "SSR 核心归档不存在：$ARCHIVE"
ACTUAL_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[[ "${ACTUAL_SHA,,}" == "${EXPECTED_SHA,,}" ]] || fail "核心 SHA256 不匹配。预期：$EXPECTED_SHA；实际：$ACTUAL_SHA。停止安装。"

echo '[PASS] 固定 Commit 与 SHA256 校验通过。'
export SSR_CORE_ARCHIVE="$ARCHIVE"
export SSR_CORE_COMMIT="$COMMIT"
export SSR_CORE_SHA256="$EXPECTED_SHA"
bash "$ROOT/install/install.sh"
