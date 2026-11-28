#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '需要 root 权限。' >&2; exit 1; }
BACKUP=${1:-}
[[ -n "$BACKUP" && -d "$BACKUP" ]] || { echo "用法：$0 /root/ssr-migration-backups/ssr-YYYYMMDD-HHMMSS" >&2; exit 2; }
[[ -f "$BACKUP/meta/state.txt" ]] || { echo '备份目录缺少 meta/state.txt。' >&2; exit 2; }
STAMP=$(date +%Y%m%d-%H%M%S)
systemctl stop ssr.service 2>/dev/null || true

if [[ -d "$BACKUP/core" ]]; then
    [[ ! -e /usr/local/shadowsocksr ]] || mv /usr/local/shadowsocksr "/usr/local/shadowsocksr.failed-$STAMP"
    cp -a "$BACKUP/core" /usr/local/shadowsocksr
fi
if [[ -d "$BACKUP/etc-shadowsocksr" ]]; then
    [[ ! -e /etc/shadowsocksr ]] || cp -a /etc/shadowsocksr "/etc/shadowsocksr.pre-rollback-$STAMP"
    mv /etc/shadowsocksr "/etc/shadowsocksr.failed-$STAMP"
    cp -a "$BACKUP/etc-shadowsocksr" /etc/shadowsocksr
fi
if [[ -f "$BACKUP/ssr.init" ]]; then
    install -D -m 0755 "$BACKUP/ssr.init" /etc/init.d/ssr
fi
if [[ -f "$BACKUP/ssr.service" ]]; then
    install -D -m 0644 "$BACKUP/ssr.service" /etc/systemd/system/ssr.service
elif [[ -f /etc/systemd/system/ssr.service ]] && grep -q 'SSR-Ubuntu manager' /etc/systemd/system/ssr.service; then
    mv /etc/systemd/system/ssr.service "/etc/systemd/system/ssr.service.failed-$STAMP"
fi
systemctl daemon-reload

if grep -qx 'systemd_active=yes' "$BACKUP/meta/state.txt"; then
    systemctl restart ssr.service 2>/dev/null || true
elif grep -qx 'init_active=yes' "$BACKUP/meta/state.txt" && [[ -x /etc/init.d/ssr ]]; then
    /etc/init.d/ssr start || true
fi
cat <<EOF
回滚文件恢复已执行。
备份来源：$BACKUP
注意：本工具没有自动恢复 iptables/nftables/UFW 快照，避免覆盖当前系统其他应用的防火墙规则。
请人工比对 $BACKUP/meta/ 中的防火墙快照，并验证原客户端连接。
EOF
