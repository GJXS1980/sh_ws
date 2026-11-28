#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '需要 root 权限。' >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$ROOT/detect.sh"
BACKUP=$($ROOT/backup.sh | sed -n 's/^迁移前备份已完成：//p' | tail -1)
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { echo '备份失败；迁移已停止。' >&2; exit 2; }
cat <<EOF

迁移准备阶段已完成。
备份目录：$BACKUP
当前版本不会自动切换服务，原因是固定 manyuser 核心提交、源码 SHA256、旧/新环境客户端同链接回归测试尚未完成。
旧服务不会被停止，旧核心和配置没有被覆盖。

请在完成核心固定、日志脱敏、Python/OpenSSL/libsodium 兼容测试后，再执行受控切换。
EOF
exit 3
