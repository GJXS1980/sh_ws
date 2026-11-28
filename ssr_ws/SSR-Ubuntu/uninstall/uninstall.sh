#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "请使用 sudo 运行。" >&2; exit 1; }
UNIT=/etc/systemd/system/ssr.service
HELPER=/usr/local/libexec/ssr-ubuntu
CONFIG=/etc/shadowsocksr/user-config.json
FIREWALL="$HELPER/firewall.sh"
SCRIPT=/usr/local/bin/ssr.sh
CORE=/usr/local/shadowsocksr

cat <<'EOF'
安全卸载将：
- 停止并禁用本工具的 ssr.service（如果存在）
- 删除本工具安装的 service unit、管理辅助程序和菜单入口
- 保留 SSR 核心、/etc/shadowsocksr 配置和备份
- 仅清理 ledger 明确记录的本工具防火墙规则；不动其他规则
- 不删除其他防火墙规则，不清空防火墙
EOF
read -r -p '输入 REMOVE-MANAGER 确认卸载管理器（不会删除核心和配置）：' confirm
[[ "$confirm" == REMOVE-MANAGER ]] || { echo "已取消。"; exit 0; }
systemctl disable --now ssr.service 2>/dev/null || true
if [[ -x "$FIREWALL" ]]; then
    "$FIREWALL" remove-all || echo "[提示] 本工具防火墙规则清理未全部完成，请人工检查 ledger。" >&2
fi
if [[ -x "$HELPER/bbr.sh" ]]; then
    "$HELPER/bbr.sh" disable || echo "[提示] BBR 配置未能完全恢复，请检查 /etc/sysctl.d/99-ssr-bbr.conf。" >&2
fi
rm -f -- "$UNIT" "$SCRIPT"
if [[ -L "$HELPER" ]]; then
    echo "拒绝删除符号链接路径：$HELPER" >&2
    exit 2
fi
if [[ -d "$HELPER" && "$HELPER" == /usr/local/libexec/ssr-ubuntu ]]; then
    rm -r --one-file-system -- "$HELPER"
fi
systemctl daemon-reload

echo "管理器已卸载；核心、配置和备份保留。只清理了 ledger 记录的本工具防火墙规则。"
read -r -p '如需彻底删除核心和配置，请再次输入 REMOVE-CORE-CONFIG：' confirm2
if [[ "$confirm2" == REMOVE-CORE-CONFIG ]]; then
    echo "再次确认：将删除 $CORE 和 $CONFIG（含配置备份）。"
    read -r -p '再次输入 DELETE-SSR-DATA：' confirm3
    if [[ "$confirm3" == DELETE-SSR-DATA ]]; then
        if [[ -L "$CORE" || -L /etc/shadowsocksr ]]; then
            echo '检测到核心或配置目录为符号链接，拒绝递归删除。' >&2
            exit 2
        fi
        [[ "$CORE" == /usr/local/shadowsocksr ]] && rm -r --one-file-system -- "$CORE"
        [[ -d /etc/shadowsocksr ]] && rm -r --one-file-system -- /etc/shadowsocksr
        echo "核心和配置目录（含备份）已删除。"
    else
        echo "未删除核心和配置。"
    fi
fi
