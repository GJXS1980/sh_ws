#!/usr/bin/env bash
# SSR-Ubuntu managed firewall rules. Never enables a firewall or changes policy.
set -Eeuo pipefail

STATE_DIR=${SSR_STATE_DIR:-/var/lib/ssr-ubuntu}
LEDGER="$STATE_DIR/firewall-created.tsv"
[[ ! -L "$STATE_DIR" ]] || { echo "防火墙状态目录不能是符号链接：$STATE_DIR" >&2; exit 2; }
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
[[ ! -L "$LEDGER" ]] || { echo "防火墙 ledger 不能是符号链接：$LEDGER" >&2; exit 2; }

fw_backend() {
    local ufw_active=0 firewalld_active=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw_active=1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && [[ "$(firewall-cmd --state 2>/dev/null || true)" == "running" ]]; then
        firewalld_active=1
    fi
    if (( ufw_active && firewalld_active )); then
        echo conflict
    elif (( ufw_active )); then
        echo ufw
    elif (( firewalld_active )); then
        echo firewalld
    elif command -v nft >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nftables.service 2>/dev/null; then
        echo nft
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1 && iptables -S INPUT | grep -q '^-A INPUT'; then
        echo iptables
    else
        echo none
    fi
}

_ledger_has() { [[ -f "$LEDGER" ]] && grep -Fxq "$1" "$LEDGER"; }
_ledger_add() {
    touch "$LEDGER"
    chmod 0600 "$LEDGER"
    _ledger_has "$1" || printf '%s\n' "$1" >> "$LEDGER"
}

_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

_firewalld_add_one() {
    local zone=$1 port=$2 proto=$3 spec="$2/$3"
    local runtime=0 permanent=0 rc
    firewall-cmd --get-default-zone >/dev/null 2>&1 || {
        echo "无法读取 Firewalld 默认 zone。" >&2; return 2;
    }

    if firewall-cmd --zone="$zone" --query-port="$spec" >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if (( rc == 1 )); then
        if ! firewall-cmd --zone="$zone" --add-port="$spec" >/dev/null; then
            echo "Firewalld 运行时放行失败：$spec ($zone)" >&2; return 2
        fi
        runtime=1
    elif (( rc != 0 )); then
        echo "Firewalld 无法查询运行时规则：$spec ($zone)" >&2; return 2
    fi

    if firewall-cmd --permanent --zone="$zone" --query-port="$spec" >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if (( rc == 1 )); then
        if ! firewall-cmd --permanent --zone="$zone" --add-port="$spec" >/dev/null; then
            (( runtime == 0 )) || firewall-cmd --zone="$zone" --remove-port="$spec" >/dev/null 2>&1 || true
            echo "Firewalld 永久规则写入失败：$spec ($zone)" >&2; return 2
        fi
        permanent=1
    elif (( rc != 0 )); then
        (( runtime == 0 )) || firewall-cmd --zone="$zone" --remove-port="$spec" >/dev/null 2>&1 || true
        echo "Firewalld 无法查询永久规则：$spec ($zone)" >&2; return 2
    fi

    if (( runtime || permanent )); then
        _ledger_add "firewalld|$zone|$port|$proto|$runtime|$permanent"
        echo "Firewalld：$zone 已放行 $spec（运行时新增=$runtime，永久新增=$permanent）。"
    else
        echo "Firewalld：$zone 已存在 $spec，未接管原有规则。"
    fi
}

firewall_allow_port() {
    local port=${1:?port required} backend proto zone cmd family rule
    _valid_port "$port" || { echo "端口无效：$port" >&2; return 2; }
    port=$((10#$port))
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
                    if ! ufw allow "$port/$proto" comment 'ssr-ubuntu-managed' >/dev/null; then
                        echo "UFW 放行失败：$port/$proto" >&2
                        firewall_remove_port "$port" >/dev/null 2>&1 || true
                        return 2
                    fi
                    _ledger_add "$rule"
                    echo "UFW：已放行 $port/$proto。"
                fi
            done
            ;;
        firewalld)
            zone=$(firewall-cmd --get-default-zone 2>/dev/null) || { echo "无法读取 Firewalld 默认 zone。" >&2; return 2; }
            [[ -n "$zone" ]] || { echo "Firewalld 默认 zone 为空。" >&2; return 2; }
            for proto in tcp udp; do
                if ! _firewalld_add_one "$zone" "$port" "$proto"; then
                    firewall_remove_port "$port" >/dev/null 2>&1 || true
                    return 2
                fi
            done
            ;;
        iptables)
            command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 || { echo "缺少 iptables/ip6tables 命令，未修改规则。" >&2; return 2; }
            for family in ipv4 ipv6; do
                cmd=iptables
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
                        echo "iptables：$family 已放行 $port/$proto。"
                    else
                        echo "iptables：$family 已存在 $port/$proto。"
                    fi
                done
            done
            ;;
        nft)
            echo "检测到原生 nftables。当前版本不会向未知的现有 base chain 插入规则，以免误改变默认策略；请人工审核并放行 TCP/UDP $port。没有修改规则。" >&2
            return 3
            ;;
        conflict)
            echo "同时检测到 UFW 和 Firewalld 处于 active/running 状态；为避免只修改其中一套规则，拒绝自动放行。" >&2
            return 2
            ;;
        *)
            echo "未发现已启用的受支持防火墙。不会自动开启防火墙或修改规则；请检查云平台安全组。"
            return 3
            ;;
    esac
}

firewall_remove_port() {
    local port=${1:?port required} line kind a b c d e proto cmd family failed=0
    _valid_port "$port" || { echo "端口无效：$port" >&2; return 2; }
    port=$((10#$port))
    [[ -f "$LEDGER" ]] || { echo "没有本工具创建的防火墙规则记录。"; return 0; }

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r kind a b c d e <<< "$line"
        case "$kind" in
            ufw)
                [[ "$a" == "$port" ]] || continue
                ufw --force delete allow "$a/$b" >/dev/null || failed=1
                ;;
            firewalld)
                [[ "$b" == "$port" ]] || continue
                proto=$c
                if [[ "$d" == "1" ]]; then
                    firewall-cmd --zone="$a" --remove-port="$b/$proto" >/dev/null || failed=1
                fi
                if [[ "$e" == "1" ]]; then
                    firewall-cmd --permanent --zone="$a" --remove-port="$b/$proto" >/dev/null || failed=1
                fi
                ;;
            iptables)
                [[ "$b" == "$port" ]] || continue
                family=$a; proto=$c; cmd=iptables
                [[ "$family" == ipv6 ]] && cmd=ip6tables
                "$cmd" -D SSR_UBUNTU_INPUT -p "$proto" --dport "$port" -m comment --comment ssr-ubuntu-managed -j ACCEPT 2>/dev/null || failed=1
                ;;
        esac
    done < "$LEDGER"

    if (( failed )); then
        echo "部分防火墙规则删除失败；保留 ledger 以便后续重试。" >&2
        return 2
    fi

    local tmp="$LEDGER.tmp"
    awk -F'|' -v p="$port" '
        !(($1=="ufw" && $2==p) ||
          ($1=="firewalld" && $3==p) ||
          ($1=="iptables" && $3==p))
    ' "$LEDGER" > "$tmp"
    mv "$tmp" "$LEDGER"
    chmod 0600 "$LEDGER"

    for family in ipv4 ipv6; do
        cmd=iptables
        [[ "$family" == ipv6 ]] && cmd=ip6tables
        if [[ -f "$STATE_DIR/iptables-chain-owned-$family" ]] && "$cmd" -S SSR_UBUNTU_INPUT >/dev/null 2>&1; then
            if ! "$cmd" -S SSR_UBUNTU_INPUT | grep -q '^-A '; then
                "$cmd" -D INPUT -j SSR_UBUNTU_INPUT 2>/dev/null || true
                "$cmd" -X SSR_UBUNTU_INPUT 2>/dev/null || true
                rm -f "$STATE_DIR/iptables-chain-owned-$family"
            fi
        fi
    done
    echo "已移除本工具管理的端口 $port 规则。"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-}" in
        allow) firewall_allow_port "${2:-}" ;;
        remove) firewall_remove_port "${2:-}" ;;
        remove-all)
            if [[ -f "$LEDGER" ]]; then
                ports=$(awk -F'|' '$1=="iptables" {print $3} $1=="firewalld" {print $3} $1=="ufw" {print $2}' "$LEDGER" | sort -nu)
                while IFS= read -r p; do [[ -n "$p" ]] && firewall_remove_port "$p"; done <<< "$ports"
            fi
            ;;
        status)
            printf '当前防火墙后端：%s\n' "$(fw_backend)"
            [[ -f "$LEDGER" ]] && cat "$LEDGER" || true
            ;;
        *) echo "用法：$0 {allow|remove|remove-all|status} [PORT]" >&2; exit 2 ;;
    esac
fi
