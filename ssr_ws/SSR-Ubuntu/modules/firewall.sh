#!/usr/bin/env bash
# Only opens ports through a firewall manager that is already active.
# Never enables UFW, flushes rules, or changes a default policy.
set -Eeuo pipefail
STATE_DIR=${SSR_STATE_DIR:-/var/lib/ssr-ubuntu}
LEDGER="$STATE_DIR/firewall-created.tsv"
[[ ! -L "$STATE_DIR" ]] || { echo "防火墙状态目录不能是符号链接：$STATE_DIR" >&2; exit 2; }
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
[[ ! -L "$LEDGER" ]] || { echo "防火墙 ledger 不能是符号链接：$LEDGER" >&2; exit 2; }

fw_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo ufw; return
    fi
    if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables.service 2>/dev/null; then
        echo nft; return
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1 && iptables -S INPUT | grep -q '^-A INPUT'; then
        echo iptables; return
    fi
    echo none
}

_ledger_has() { [[ -f "$LEDGER" ]] && grep -Fxq "$1" "$LEDGER"; }
_ledger_add() { touch "$LEDGER"; chmod 0600 "$LEDGER"; _ledger_has "$1" || printf '%s\n' "$1" >> "$LEDGER"; }

firewall_allow_port() {
    local port=${1:?port required} backend rule
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || { echo "端口无效" >&2; return 2; }
    backend=$(fw_backend)
    case "$backend" in
        ufw)
            if [[ -r /etc/default/ufw ]] && ! grep -Eq '^[[:space:]]*IPV6=yes([[:space:]]|$)' /etc/default/ufw; then
                echo "警告：/etc/default/ufw 未设置 IPV6=yes；UFW 可能只放行 IPv4。工具不会擅自修改 UFW IPv6 设置。" >&2
            fi
            for proto in tcp udp; do
                rule="ufw|$port|$proto"
                if ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${port}/${proto}([[:space:]]|$)"; then
                    echo "UFW 已存在 $port/$proto 规则，不接管、不记录。"
                else
                    ufw allow "$port/$proto" comment 'ssr-ubuntu-managed' >/dev/null
                    _ledger_add "$rule"
                fi
            done
            ;;
        nft)
            echo "检测到原生 nftables。当前版本不会向未知的现有 base chain 插入规则，以免误改变默认拒绝策略；请人工审核并放行 TCP/UDP $port（IPv4/IPv6）。没有修改任何规则。" >&2
            return 3
            ;;
        iptables)
            command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 || { echo "缺少 iptables/ip6tables 命令，未修改规则。" >&2; return 2; }
            for family in ipv4 ipv6; do
                local cmd=iptables
                [[ "$family" == ipv6 ]] && cmd=ip6tables
                if ! "$cmd" -S SSR_UBUNTU_INPUT >/dev/null 2>&1; then
                    "$cmd" -N SSR_UBUNTU_INPUT
                    printf '%s\n' "iptables-chain-owned-$family" > "$STATE_DIR/iptables-chain-owned-$family"
                elif [[ ! -f "$STATE_DIR/iptables-chain-owned-$family" ]]; then
                    echo "发现同名但非本工具创建的 iptables 链（$family），拒绝修改。" >&2; return 2
                fi
                "$cmd" -C INPUT -j SSR_UBUNTU_INPUT 2>/dev/null || "$cmd" -I INPUT 1 -j SSR_UBUNTU_INPUT
                for proto in tcp udp; do
                    rule="iptables|$family|$port|$proto"
                    if ! "$cmd" -C SSR_UBUNTU_INPUT -p "$proto" --dport "$port" -m comment --comment ssr-ubuntu-managed -j ACCEPT 2>/dev/null; then
                        "$cmd" -A SSR_UBUNTU_INPUT -p "$proto" --dport "$port" -m comment --comment ssr-ubuntu-managed -j ACCEPT
                        _ledger_add "$rule"
                    fi
                done
            done
            ;;
        *)
            echo "未发现已启用的 UFW/nftables/iptables 防火墙管理机制。没有开启防火墙，也没有自动放行端口。请检查云平台安全组。"
            return 3
            ;;
    esac
}

firewall_remove_port() {
    local port=${1:?port required} line backend family proto cmd
    [[ -f "$LEDGER" ]] || { echo "没有本工具创建的防火墙规则记录。"; return 0; }
    backend=$(fw_backend)
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r kind a b c <<< "$line"
        case "$kind" in
            ufw)
                [[ "$a" == "$port" ]] || continue
                ufw --force delete allow "$a/$b" >/dev/null || true
                ;;
            nft)
                [[ "$a" == "$port" ]] || continue
                local handles
                handles=$(nft -a list chain inet ssr_ubuntu input 2>/dev/null | awk -v tag="ssr-ubuntu-${a}-${b}" 'index($0, tag) {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
                while IFS= read -r h; do [[ -n "$h" ]] && nft delete rule inet ssr_ubuntu input handle "$h" || true; done <<< "$handles"
                ;;
            iptables)
                [[ "$b" == "$port" ]] || continue
                family=$a; proto=$c; cmd=iptables; [[ "$family" == ipv6 ]] && cmd=ip6tables
                "$cmd" -D SSR_UBUNTU_INPUT -p "$proto" --dport "$port" -m comment --comment ssr-ubuntu-managed -j ACCEPT 2>/dev/null || true
                ;;
        esac
    done < "$LEDGER"
    local tmp="$LEDGER.tmp"
    awk -F'|' -v p="$port" '!(($1=="ufw" && $2==p) || ($1=="nft" && $2==p) || ($1=="iptables" && $3==p))' "$LEDGER" > "$tmp"
    mv "$tmp" "$LEDGER"; chmod 0600 "$LEDGER"
    for family in ipv4 ipv6; do
        local cmd=iptables
        [[ "$family" == ipv6 ]] && cmd=ip6tables
        if [[ -f "$STATE_DIR/iptables-chain-owned-$family" ]] && "$cmd" -S SSR_UBUNTU_INPUT >/dev/null 2>&1; then
            if ! "$cmd" -S SSR_UBUNTU_INPUT | grep -q '^-A '; then
                "$cmd" -D INPUT -j SSR_UBUNTU_INPUT 2>/dev/null || true
                "$cmd" -X SSR_UBUNTU_INPUT 2>/dev/null || true
                rm -f "$STATE_DIR/iptables-chain-owned-$family"
            fi
        fi
    done
    # Keep an empty owned nft table rather than risk deleting rules that an administrator may have added later.
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-}" in
        allow) firewall_allow_port "${2:-}" ;;
        remove) firewall_remove_port "${2:-}" ;;
        remove-all)
            if [[ -f "$LEDGER" ]]; then
                ports=$(awk -F'|' '$1=="iptables" {print $3} $1!="iptables" {print $2}' "$LEDGER" | sort -nu)
                while IFS= read -r p; do [[ -n "$p" ]] && firewall_remove_port "$p"; done <<< "$ports"
            fi
            ;;
        status) printf '当前防火墙后端：%s\n' "$(fw_backend)"; [[ -f "$LEDGER" ]] && cat "$LEDGER" || true ;;
        *) echo "用法：$0 {allow|remove|remove-all|status} [PORT]" >&2; exit 2 ;;
    esac
fi
