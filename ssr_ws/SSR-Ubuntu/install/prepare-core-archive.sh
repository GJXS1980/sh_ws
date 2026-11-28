#!/usr/bin/env bash
# Produce a deterministic archive from an explicitly selected upstream commit.
# This script fetches source only; it never executes upstream code.
set -Eeuo pipefail

REPO_URL='https://github.com/ssrlive/shadowsocksr.git'
OUT_DIR=${1:-/root/ssr-core-source}
COMMIT=${2:-}

[[ -n "$COMMIT" && "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || {
    echo "用法：$0 OUTPUT_DIR 40位Git_COMMIT_SHA" >&2
    exit 2
}
command -v git >/dev/null 2>&1 || { echo '缺少 git，请先安装。' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo '缺少 sha256sum。' >&2; exit 2; }

mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"
WORK=$(mktemp -d)
trap '[[ ! -d "$WORK" ]] || rm -r --one-file-system -- "$WORK"' EXIT

git -C "$WORK" init -q
git -C "$WORK" remote add origin "$REPO_URL"
# Git uses HTTPS certificate verification by default; do not set sslVerify=false.
# Fetch the named upstream branch history so the requested commit can be
# proven reachable from the repository's manyuser branch.
git -C "$WORK" fetch origin refs/heads/manyuser:refs/remotes/origin/manyuser
git -C "$WORK" cat-file -e "$COMMIT^{commit}"
for path in shadowsocks/server.py shadowsocks/daemon.py shadowsocks/shell.py shadowsocks/encrypt.py shadowsocks/obfs.py setup.py CHANGES; do
    git -C "$WORK" cat-file -e "$COMMIT:$path" || { echo "指定提交缺少核心文件：$path" >&2; exit 4; }
done
git -C "$WORK" merge-base --is-ancestor "$COMMIT" refs/remotes/origin/manyuser || {
    echo '指定 commit 不属于当前 manyuser 分支历史；拒绝归档。' >&2
    exit 3
}
FETCHED=$(git -C "$WORK" rev-parse "$COMMIT^{commit}")
[[ "${FETCHED,,}" == "${COMMIT,,}" ]] || { echo '解析出的 commit 与请求不一致。' >&2; exit 3; }

ARCHIVE="$OUT_DIR/shadowsocksr-${COMMIT}.tar.gz"
git -C "$WORK" archive --format=tar --prefix="shadowsocksr-${COMMIT}/" "$COMMIT" | gzip -n > "$ARCHIVE"
SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
TREE=$(git -C "$WORK" rev-parse "$COMMIT^{tree}")
DATE=$(git -C "$WORK" show -s --format=%cI "$COMMIT")
printf '核心仓库：%s\n固定提交：%s\n源码树：%s\n提交日期：%s\n压缩包：%s\nSHA256：%s\n' "$REPO_URL" "$FETCHED" "$TREE" "$DATE" "$ARCHIVE" "$SHA"
printf '\n归档已生成。运行项目根目录的 sudo bash ./install.sh 即可自动校验此固定归档并继续安装。\n'
