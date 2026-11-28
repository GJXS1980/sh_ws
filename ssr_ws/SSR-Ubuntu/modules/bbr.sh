#!/usr/bin/env bash
set -Eeuo pipefail
CONF=/etc/sysctl.d/99-ssr-bbr.conf
STATE_DIR=${SSR_STATE_DIR:-/var/lib/ssr-ubuntu}
STATE="$STATE_DIR/bbr-state"
PREEXISTING="$STATE_DIR/99-ssr-bbr.conf.preexisting"

bbr_status() {
    printf 'available: '; sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
    printf 'qdisc: '; sysctl -n net.core.default_qdisc 2>/dev/null || true
    printf 'congestion: '; sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
}

bbr_enable() {
    [[ $EUID -eq 0 ]] || { echo "需要 root 权限" >&2; return 1; }
    [[ ! -L "$CONF" && ! -L "$STATE_DIR" && ! -L "$STATE" && ! -L "$PREEXISTING" ]] || { echo "检测到 BBR 状态路径为符号链接，拒绝修改。" >&2; return 2; }
    local available old_qdisc old_cc
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    grep -qw bbr <<< "$available" || { echo "当前内核不支持 BBR；未修改任何配置。" >&2; return 2; }
    mkdir -p "$STATE_DIR"; chmod 0700 "$STATE_DIR"
    if [[ ! -e "$STATE" ]]; then
        old_qdisc=$(sysctl -n net.core.default_qdisc)
        old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        printf '%s\n%s\n' "$old_qdisc" "$old_cc" > "$STATE"
        chmod 0600 "$STATE"
        if [[ -e "$CONF" ]]; then cp -a "$CONF" "$PREEXISTING"; printf 'preexisting\n' >> "$STATE"; else printf 'absent\n' >> "$STATE"; fi
    else
        old_qdisc=$(sed -n '1p' "$STATE")
        old_cc=$(sed -n '2p' "$STATE")
    fi
    cat > "$CONF" <<'EOF'
# Managed by SSR-Ubuntu. No kernel replacement is performed.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    chmod 0644 "$CONF"
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null || ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null; then
        if [[ -f "$PREEXISTING" ]]; then
            cp -a "$PREEXISTING" "$CONF"
        else
            rm -f "$CONF"
        fi
        local restore_failed=0
        sysctl -w "net.core.default_qdisc=$old_qdisc" >/dev/null 2>&1 || restore_failed=1
        sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || restore_failed=1
        if (( restore_failed == 0 )); then rm -f "$STATE" "$PREEXISTING"; fi
        echo "BBR 参数应用失败，已尝试恢复原配置。" >&2
        (( restore_failed == 0 )) || echo "警告：内核运行参数未能完全恢复，保留了状态备份 $STATE。" >&2
        return 2
    fi
    bbr_status
}

bbr_disable() {
    [[ $EUID -eq 0 ]] || { echo "需要 root 权限" >&2; return 1; }
    [[ ! -L "$CONF" && ! -L "$STATE_DIR" && ! -L "$STATE" && ! -L "$PREEXISTING" ]] || { echo "检测到 BBR 状态路径为符号链接，拒绝修改。" >&2; return 2; }
    [[ -f "$STATE" ]] || { echo "未发现本工具的 BBR 状态备份。"; return 0; }
    local old_qdisc old_cc existed
    old_qdisc=$(sed -n '1p' "$STATE"); old_cc=$(sed -n '2p' "$STATE"); existed=$(sed -n '3p' "$STATE")
    if [[ "$existed" == preexisting ]]; then
        [[ -f "$PREEXISTING" ]] || { echo "原有 sysctl 配置备份缺失；拒绝删除当前配置。" >&2; return 2; }
        cp -a "$PREEXISTING" "$CONF"
    else
        rm -f "$CONF"
    fi
    local restore_failed=0
    sysctl -w "net.core.default_qdisc=$old_qdisc" >/dev/null 2>&1 || restore_failed=1
    sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || restore_failed=1
    if (( restore_failed != 0 )); then
        echo "原始内核运行参数未能完全恢复；保留状态备份 $STATE，请检查 sysctl。" >&2
        return 2
    fi
    rm -f "$STATE" "$PREEXISTING"
    bbr_status
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-status}" in
        status) bbr_status ;;
        enable) bbr_enable ;;
        disable) bbr_disable ;;
        *) echo "用法：$0 {status|enable|disable}" >&2; exit 2 ;;
    esac
fi
