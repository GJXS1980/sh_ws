#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo '需要 root 权限。' >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
BASE=${SSR_MIGRATION_BACKUP_DIR:-/root/ssr-migration-backups}
mkdir -p "$BASE"
[[ ! -L "$BASE" ]] || { echo "备份目录不能是符号链接：$BASE" >&2; exit 2; }
chmod 0700 "$BASE"
DEST=$(mktemp -d "$BASE/ssr-$STAMP-XXXXXX")
chmod 0700 "$DEST"
mkdir -p "$DEST/meta"

copy_if_exists() { local src=$1 dst=$2; [[ -e "$src" ]] || return 0; cp -a -- "$src" "$dst"; }
copy_if_exists /usr/local/shadowsocksr "$DEST/core"
copy_if_exists /etc/shadowsocksr "$DEST/etc-shadowsocksr"
if [[ -e /etc/init.d/ssr ]]; then cp -L /etc/init.d/ssr "$DEST/ssr.init"; fi
if [[ -e /etc/systemd/system/ssr.service ]]; then cp -L /etc/systemd/system/ssr.service "$DEST/ssr.service"; fi

{
    printf 'timestamp=%s\n' "$STAMP"
    printf 'os=%s\n' "$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    printf 'arch=%s\n' "$(uname -m)"
    if systemctl is-active --quiet ssr.service 2>/dev/null; then echo 'systemd_active=yes'; else echo 'systemd_active=no'; fi
    if [[ -e /etc/systemd/system/ssr.service ]]; then echo 'systemd_unit_present=yes'; else echo 'systemd_unit_present=no'; fi
    if [[ -x /etc/init.d/ssr ]]; then
        echo 'init_present=yes'
        if /etc/init.d/ssr status >/dev/null 2>&1; then echo 'init_active=yes'; else echo 'init_active=no'; fi
    else
        echo 'init_present=no'; echo 'init_active=no'
    fi
    if [[ -f /etc/shadowsocksr/user-config.json ]]; then echo 'config_present=yes'; else echo 'config_present=no'; fi
} > "$DEST/meta/state.txt"
chmod 0600 "$DEST/meta/state.txt"

iptables-save > "$DEST/meta/iptables.v4.txt" 2>/dev/null || true
ip6tables-save > "$DEST/meta/iptables.v6.txt" 2>/dev/null || true
nft list ruleset > "$DEST/meta/nft.ruleset.txt" 2>/dev/null || true
ufw status verbose > "$DEST/meta/ufw.status.txt" 2>/dev/null || true
ss -lntup > "$DEST/meta/listeners.txt" 2>/dev/null || true
systemctl cat ssr.service > "$DEST/meta/systemd-unit.txt" 2>/dev/null || true
chmod 0600 "$DEST/meta"/* 2>/dev/null || true
printf '%s\n' "$DEST" > "$BASE/latest-path"
chmod 0600 "$BASE/latest-path"
echo "迁移前备份已完成：$DEST"
echo '说明：防火墙快照仅用于审计和人工恢复；本工具不会自动覆盖当前防火墙规则。'
