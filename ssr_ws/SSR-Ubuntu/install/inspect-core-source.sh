#!/usr/bin/env bash
# Inspect the user-selected manyuser branch without executing upstream code.
set -Eeuo pipefail
REPO_URL='https://github.com/ssrlive/shadowsocksr.git'
BRANCH='manyuser'
command -v git >/dev/null 2>&1 || { echo '缺少 git' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" remote add origin "$REPO_URL"
git -C "$WORK" fetch --depth=1 origin "refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
COMMIT=$(git -C "$WORK" rev-parse "refs/remotes/origin/${BRANCH}^{commit}")
TREE=$(git -C "$WORK" rev-parse "${COMMIT}^{tree}")
DATE=$(git -C "$WORK" show -s --format=%cI "$COMMIT")
SUBJECT=$(git -C "$WORK" show -s --format=%s "$COMMIT")
for path in shadowsocks/server.py shadowsocks/daemon.py shadowsocks/shell.py shadowsocks/encrypt.py shadowsocks/obfs.py setup.py CHANGES; do
    git -C "$WORK" cat-file -e "$COMMIT:$path" || { echo "缺少关键文件：$path" >&2; exit 3; }
done
SETUP=$(git -C "$WORK" show "$COMMIT:setup.py")
PKG_VERSION=$(printf '%s\n' "$SETUP" | sed -nE 's/.*version=["'"'"']([^"'"'"']+).*/\1/p' | head -n1)
CHANGES_TOP=$(git -C "$WORK" show "$COMMIT:CHANGES" | sed -n '1,8p')
SERVER=$(git -C "$WORK" show "$COMMIT:shadowsocks/server.py")
printf '仓库：%s\n分支：%s\nCommit：%s\nTree：%s\n提交日期：%s\n提交说明：%s\nsetup.py包版本：%s\n' "$REPO_URL" "$BRANCH" "$COMMIT" "$TREE" "$DATE" "$SUBJECT" "${PKG_VERSION:-unknown}"
printf '\nCHANGES 顶部：\n%s\n' "$CHANGES_TOP"
printf '检查 server.py daemon 调用：'
grep -Fq 'daemon.daemon_exec(config)' <<<"$SERVER" && echo PASS || { echo FAIL; exit 4; }
printf '检查 port_password 多端口映射：'
grep -Fq "config['port_password']" <<<"$SERVER" && echo PASS || { echo FAIL; exit 4; }
printf '检查旧版明文密码日志行：'
grep -Fq 'password [%s]' <<<"$SERVER" && echo 'FOUND（安装前必须应用本项目日志脱敏补丁）' || echo '未找到预期日志行（需要重新审查补丁，安装器会 fail-closed）'
printf '\n请人工审核上述提交，再执行：\n  bash install/prepare-core-archive.sh /root/ssr-core-source %s\n' "$COMMIT"
