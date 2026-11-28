#!/usr/bin/env bash
# SSR-Ubuntu manager. The protocol core remains the original SSR manyuser core.
set -Eeuo pipefail

VERSION='0.2.0'
CONFIG_FILE=${SSR_CONFIG_FILE:-/etc/shadowsocksr/user-config.json}
CORE_DIR=${SSR_CORE_DIR:-/usr/local/shadowsocksr}
UNIT='ssr.service'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -d /usr/local/libexec/ssr-ubuntu/project ]]; then
    PROJECT_DIR=/usr/local/libexec/ssr-ubuntu/project
else
    PROJECT_DIR="$SCRIPT_DIR"
fi
if [[ -f /usr/local/libexec/ssr-ubuntu/config.py ]]; then
    HELPER_DIR=/usr/local/libexec/ssr-ubuntu
else
    HELPER_DIR="$PROJECT_DIR/modules"
fi
if [[ -x "$CORE_DIR/venv/bin/python" ]]; then
    PYTHON=${SSR_PYTHON:-$CORE_DIR/venv/bin/python}
else
    PYTHON=${SSR_PYTHON:-python3}
fi
export SSR_PYTHON="$PYTHON"
CONFIG_HELPER="$HELPER_DIR/config.py"
LINK_HELPER="$HELPER_DIR/link.py"
CONNECTION_HELPER="$HELPER_DIR/connection.py"
FIREWALL_HELPER="$HELPER_DIR/firewall.sh"
BBR_HELPER="$HELPER_DIR/bbr.sh"
QR_HELPER="$HELPER_DIR/qr.sh"
SERVICE_HELPER="$HELPER_DIR/service.sh"
LOG_HELPER="$PROJECT_DIR/modules/log.sh"

info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
error() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
need_root() { [[ $EUID -eq 0 ]] || { error '此操作需要 root，请使用 sudo。'; return 1; }; }
need_config() { [[ -f "$CONFIG_FILE" ]] || { error "未发现配置文件：$CONFIG_FILE"; return 1; }; }
need_unit() { systemctl cat "$UNIT" >/dev/null 2>&1 || { error '尚未安装新版 systemd 服务。请先完成核心固定版本验证和安装。'; return 1; }; }

config_ports() {
    "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE" | \
        "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); [print(x["port"]) for x in d["accounts"]]'
}

sync_port_firewall() {
    local before=${1:-} after=${2:-} port
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        if ! grep -Fxq -- "$port" <<< "$after"; then
            "$FIREWALL_HELPER" remove "$port" || warn "端口 $port 的工具创建规则未能清理，请检查防火墙 ledger。"
        fi
    done <<< "$before"
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        if ! grep -Fxq -- "$port" <<< "$before"; then
            read -r -p "是否在当前已启用的防火墙中放行 TCP/UDP $port？不会自动启用防火墙。[y/N] " yn
            if [[ "$yn" =~ ^[Yy]$ ]]; then
                "$FIREWALL_HELPER" allow "$port" || warn "未能安全自动放行 $port；请检查云平台安全组及防火墙。"
            else
                warn "未修改防火墙；请确认云平台安全组和现有防火墙已放行 $port。"
            fi
        fi
    done <<< "$after"
}

system_summary() {
    if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
    printf '系统：%s\n' "${PRETTY_NAME:-未知}"
    printf '架构：%s\n' "$(uname -m)"
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '安装状态：配置已存在\n'
        "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE" 2>/dev/null | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print("端口模式：" + ("多端口" if d["mode"]=="multi" else "单端口")); print("用户数量："+str(len(d["accounts"])))' || true
    else
        printf '安装状态：未发现 SSR 配置\n'
    fi
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        printf '服务状态：运行中\n'
    elif systemctl cat "$UNIT" >/dev/null 2>&1; then
        printf '服务状态：已安装但未运行\n'
    else
        printf '服务状态：systemd 服务未安装\n'
    fi
}

install_ssr() {
    need_root || return
    bash "$PROJECT_DIR/install.sh"
}

update_ssr() {
    need_root || return
    cat <<'EOF'
核心更新暂不可用（BLOCKED）。
原因：尚未在目标 Ubuntu 环境完成固定提交核心的协议回归测试。
本工具不会跟随 manyuser 浮动分支，也不会用其他代理核心替换 SSR。
请先在隔离测试机完成原客户端同链接对照测试，再启用受控更新。
EOF
    return 3
}

uninstall_ssr() {
    need_root || return
    bash "$PROJECT_DIR/uninstall/uninstall.sh"
}

libsodium_menu() {
    need_root || return
    echo 'libsodium 状态：'
    if ldconfig -p 2>/dev/null | grep -q 'libsodium'; then
        ldconfig -p | grep 'libsodium' || true
        return 0
    fi
    warn '未发现已注册的 libsodium 动态库。'
    [[ -r /etc/os-release ]] && . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || { error '自动安装仅针对 Ubuntu 软件源。'; return 2; }
    local pkg=''
    if apt-cache show libsodium23 2>/dev/null | grep -q '^Package: libsodium23$'; then pkg=libsodium23
    elif apt-cache show libsodium-dev 2>/dev/null | grep -q '^Package: libsodium-dev$'; then pkg=libsodium-dev
    else error '当前软件源未找到 libsodium23/libsodium-dev。'; return 2; fi
    read -r -p "安装 Ubuntu 软件源中的 $pkg？[y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
    apt-get update && apt-get install -y "$pkg" && ldconfig
    ldconfig -p | grep 'libsodium' || { error '安装后仍未发现 libsodium 动态库。'; return 2; }
}

view_user() {
    need_config || return
    "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE"
    local server_ip
    read -r -p '请输入服务器公网 IP 或域名（不会自动猜测）：' server_ip
    [[ -n "$server_ip" ]] || { error '服务器地址不能为空。'; return 2; }
    local qr_dir=/var/lib/ssr-ubuntu/qr
    mkdir -p /var/lib/ssr-ubuntu; chmod 0700 /var/lib/ssr-ubuntu
    if command -v qrencode >/dev/null 2>&1; then
        "$PYTHON" "$LINK_HELPER" --file "$CONFIG_FILE" --ip "$server_ip" --qr-dir "$qr_dir"
    else
        "$PYTHON" "$LINK_HELPER" --file "$CONFIG_FILE" --ip "$server_ip"
        warn '未安装 qrencode；未使用任何第三方二维码网站。'
    fi
}

view_connections() {
    need_config || return
    read -r -p '是否通过 HTTPS 将公网客户端 IP 发送给 ipapi.co 查询归属地？[y/N] ' geo
    if [[ "$geo" =~ ^[Yy]$ ]]; then
        "$PYTHON" "$CONNECTION_HELPER" --config "$CONFIG_FILE" --geo
    else
        "$PYTHON" "$CONNECTION_HELPER" --config "$CONFIG_FILE"
    fi
}

json_string() { "$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }
json_number() { [[ "$1" =~ ^[0-9]+$ ]] || { error '请输入非负整数。'; return 2; }; printf '%s' "$1"; }
set_config_field() {
    local key=$1 type=$2 prompt=$3 value encoded
    if [[ "$key" == password ]]; then
        read -r -s -p "$prompt" value; echo
    else
        read -r -p "$prompt" value
    fi
    if [[ -z "$value" ]]; then
        if [[ "$key" == protocol_param ]]; then
            encoded='""'
            "$PYTHON" "$CONFIG_HELPER" set "$key" "$encoded" --file "$CONFIG_FILE"
            return $?
        fi
        echo '未修改。'; return 0
    fi
    if [[ "$key" == password ]]; then
        printf '%s' "$value" | "$PYTHON" -c 'import json,sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False))' | "$PYTHON" "$CONFIG_HELPER" set "$key" --json-stdin --file "$CONFIG_FILE"
        return $?
    fi
    if [[ "$type" == int ]]; then encoded=$(json_number "$value") || return
    elif [[ "$type" == bool ]]; then
        [[ "$value" == true || "$value" == false ]] || { error '请输入 true 或 false。'; return 2; }
        encoded=$value
    else encoded=$(json_string "$value")
    fi
    "$PYTHON" "$CONFIG_HELPER" set "$key" "$encoded" --file "$CONFIG_FILE"
}

select_method_value() {
    local -a values=(none rc4 rc4-md5 rc4-md5-6 aes-128-ctr aes-192-ctr aes-256-ctr aes-128-cfb aes-192-cfb aes-256-cfb aes-128-cfb8 aes-192-cfb8 aes-256-cfb8 salsa20 chacha20 chacha20-ietf)
    local i choice
    for i in "${!values[@]}"; do printf '%2d. %s\n' "$((i+1))" "${values[$i]}"; done
    read -r -p '选择加密方式编号：' choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#values[@]} )) || { error '编号无效。'; return 2; }
    SELECTED_METHOD=${values[$((choice-1))]}
}

choose_method() {
    select_method_value || return
    local encoded; encoded=$(json_string "$SELECTED_METHOD")
    "$PYTHON" "$CONFIG_HELPER" set method "$encoded" --file "$CONFIG_FILE"
}

select_protocol_value() {
    local -a values=(origin auth_sha1_v4 auth_aes128_md5 auth_aes128_sha1 auth_chain_a auth_chain_b)
    local i choice compatible
    for i in "${!values[@]}"; do printf '%2d. %s\n' "$((i+1))" "${values[$i]}"; done
    read -r -p '选择协议插件编号：' choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#values[@]} )) || { error '编号无效。'; return 2; }
    SELECTED_PROTOCOL=${values[$((choice-1))]}
    if [[ "$SELECTED_PROTOCOL" == auth_sha1_v4 ]]; then
        read -r -p '是否启用协议兼容模式（_compatible）？[Y/n] ' compatible
        [[ -z "$compatible" ]] && compatible=y
        [[ "$compatible" =~ ^[Yy]$ ]] && SELECTED_PROTOCOL=auth_sha1_v4_compatible
    fi
}

choose_protocol() {
    select_protocol_value || return
    local encoded; encoded=$(json_string "$SELECTED_PROTOCOL")
    "$PYTHON" "$CONFIG_HELPER" set protocol "$encoded" --file "$CONFIG_FILE"
}

select_obfs_value() {
    local -a values=(plain http_simple http_post random_head tls1.2_ticket_auth)
    local i choice compatible
    for i in "${!values[@]}"; do printf '%2d. %s\n' "$((i+1))" "${values[$i]}"; done
    read -r -p '选择混淆插件编号：' choice
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#values[@]} )) || { error '编号无效。'; return 2; }
    SELECTED_OBFS=${values[$((choice-1))]}
    if [[ "$SELECTED_OBFS" != plain ]]; then
        read -r -p '是否启用混淆兼容模式（_compatible）？[Y/n] ' compatible
        [[ -z "$compatible" ]] && compatible=y
        [[ "$compatible" =~ ^[Yy]$ ]] && SELECTED_OBFS="${SELECTED_OBFS}_compatible"
    fi
}

choose_obfs() {
    select_obfs_value || return
    local encoded; encoded=$(json_string "$SELECTED_OBFS")
    "$PYTHON" "$CONFIG_HELPER" set obfs "$encoded" --file "$CONFIG_FILE"
}

config_all_single() {
    local port password protocol_param per_con per_user payload
    read -r -p '服务器端口：' port
    read -r -s -p '新密码（输入不回显）：' password; echo
    select_method_value || return
    select_protocol_value || return
    select_obfs_value || return
    read -r -p '设备数限制 protocol_param（空表示不限）：' protocol_param
    read -r -p '单线程限速 KB/S（0 表示不限）：' per_con
    read -r -p '端口总限速 KB/S（0 表示不限）：' per_user
    printf '%s\0' "$port" "$password" "$SELECTED_METHOD" "$SELECTED_PROTOCOL" "$SELECTED_OBFS" "$protocol_param" "$per_con" "$per_user" | \
        "$PYTHON" -c 'import json,sys; a=sys.stdin.buffer.read().split(b"\0"); a.pop() if a and a[-1]==b"" else None; a=[x.decode() for x in a]; print(json.dumps({"server_port":int(a[0]),"password":a[1],"method":a[2],"protocol":a[3],"obfs":a[4],"protocol_param":a[5],"speed_limit_per_con":int(a[6]),"speed_limit_per_user":int(a[7])},ensure_ascii=False))' | \
        "$PYTHON" "$CONFIG_HELPER" set-many --json-stdin --file "$CONFIG_FILE"
}

config_all_multi() {
    local protocol_param per_con per_user payload
    select_method_value || return
    select_protocol_value || return
    select_obfs_value || return
    read -r -p '设备数限制 protocol_param（空表示不限）：' protocol_param
    read -r -p '单线程限速 KB/S（0 表示不限）：' per_con
    read -r -p '端口总限速 KB/S（0 表示不限）：' per_user
    payload=$("$PYTHON" -c 'import json,sys; print(json.dumps({"method":sys.argv[1],"protocol":sys.argv[2],"obfs":sys.argv[3],"protocol_param":sys.argv[4],"speed_limit_per_con":int(sys.argv[5]),"speed_limit_per_user":int(sys.argv[6])},ensure_ascii=False))' "$SELECTED_METHOD" "$SELECTED_PROTOCOL" "$SELECTED_OBFS" "$protocol_param" "$per_con" "$per_user")
    "$PYTHON" "$CONFIG_HELPER" set-many "$payload" --file "$CONFIG_FILE"
}

manage_user() {
    need_root || return
    need_config || return
    local mode choice port new_port password accounts_json
    mode=$("$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["mode"])')
    if [[ "$mode" == single ]]; then
        cat <<'EOF'
单端口配置：
1. 修改端口
2. 修改密码
3. 修改加密方式
4. 修改协议插件
5. 修改混淆插件
6. 修改设备数限制
7. 修改单线程限速
8. 修改端口总限速
9. 修改全部配置
EOF
        read -r -p '选择 [1-9]：' choice
        case "$choice" in
            1) set_config_field server_port int '新端口：' ;;
            2) set_config_field password string '新密码（输入不回显）：' ;;
            3) choose_method ;;
            4) choose_protocol ;;
            5) choose_obfs ;;
            6) set_config_field protocol_param string '设备数限制 protocol_param：' ;;
            7) set_config_field speed_limit_per_con int '单线程限速 KB/S：' ;;
            8) set_config_field speed_limit_per_user int '端口总限速 KB/S：' ;;
            9) config_all_single ;;
            *) error '无效选项。'; return 2 ;;
        esac
    else
        cat <<'EOF'
多端口配置：
1. 添加用户
2. 删除用户
3. 修改用户端口/密码
4. 修改全局加密方式
5. 修改全局协议插件
6. 修改全局混淆插件
7. 修改设备数限制
8. 修改单线程限速
9. 修改端口总限速
10. 修改全部全局配置
EOF
        read -r -p '选择 [1-10]：' choice
        case "$choice" in
            1)
                read -r -p '新用户端口：' port
                read -r -s -p '新用户密码（输入不回显）：' password; echo
                printf '%s\n' "$password" | "$PYTHON" "$CONFIG_HELPER" add-user "$port" --password-stdin --file "$CONFIG_FILE"
                ;;
            2)
                "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE"
                read -r -p '要删除的用户端口：' port
                read -r -p "确认删除端口 $port？[y/N] " yn
                [[ "$yn" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }
                "$PYTHON" "$CONFIG_HELPER" delete-user "$port" --file "$CONFIG_FILE"
                ;;
            3)
                "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE"
                read -r -p '原端口：' port
                read -r -p '新端口（不改端口请重复输入原端口）：' new_port
                read -r -p '是否修改密码？[y/N] ' yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    read -r -s -p '新密码（输入不回显）：' password; echo
                    printf '%s\n' "$password" | "$PYTHON" "$CONFIG_HELPER" update-user "$port" "$new_port" --password-stdin --file "$CONFIG_FILE"
                else
                    "$PYTHON" "$CONFIG_HELPER" update-user "$port" "$new_port" --file "$CONFIG_FILE"
                fi
                ;;
            4) choose_method ;;
            5) choose_protocol ;;
            6) choose_obfs ;;
            7) set_config_field protocol_param string '设备数限制 protocol_param：' ;;
            8) set_config_field speed_limit_per_con int '单线程限速 KB/S：' ;;
            9) set_config_field speed_limit_per_user int '端口总限速 KB/S：' ;;
            10) config_all_multi ;;
            *) error '无效选项。'; return 2 ;;
        esac
    fi
}

manual_config() {
    need_root || return
    need_config || return
    local tmp
    local expected_sha
    expected_sha=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
    tmp=$(mktemp)
    cp -- "$CONFIG_FILE" "$tmp"
    chmod 0600 "$tmp"
    "${EDITOR:-vi}" "$tmp"
    local rc=0
    if "$PYTHON" "$CONFIG_HELPER" replace --candidate "$tmp" --file "$CONFIG_FILE" --expected-sha256 "$expected_sha"; then rc=0; else rc=$?; fi
    rm -f -- "$tmp"
    return "$rc"
}

switch_mode() {
    need_root || return
    need_config || return
    local mode target port count
    mode=$("$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["mode"])')
    if [[ "$mode" == single ]]; then
        echo '当前为单端口模式。转换将把当前端口和密码原样迁移到 port_password，不重新生成账号。'
        read -r -p '确认转换为多端口模式？[y/N] ' yn
        [[ "$yn" =~ ^[Yy]$ ]] || return 0
        "$PYTHON" "$CONFIG_HELPER" mode multi --file "$CONFIG_FILE"
    else
        "$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE"
        read -r -p '转换为单端口时要保留哪个端口？' port
        count=$("$PYTHON" "$CONFIG_HELPER" accounts --file "$CONFIG_FILE" | "$PYTHON" -c 'import json,sys; print(len(json.load(sys.stdin)["accounts"]))')
        if (( count > 1 )); then
            warn "当前有 $count 个用户；转换后只保留端口 $port，其余账号会从活动配置中移除，但会保存在自动备份中。"
            read -r -p '输入 KEEP-ONE 确认：' yn
            [[ "$yn" == KEEP-ONE ]] || return 0
            "$PYTHON" "$CONFIG_HELPER" mode single --port "$port" --confirm-drop --file "$CONFIG_FILE"
        else
            "$PYTHON" "$CONFIG_HELPER" mode single --port "$port" --file "$CONFIG_FILE"
        fi
    fi
}

service_action() {
    need_root || return
    need_unit || return
    "$SERVICE_HELPER" "$1"
}

view_log() {
    need_root || return
    need_unit || return
    "$SERVICE_HELPER" logs
}

other_functions() {
    need_root || return
    cat <<'EOF'
其他功能：
1. BBR 状态/启用/关闭
2. BT/PT/SPAM 封禁（BLOCKED）
3. BT/PT/SPAM 解封（BLOCKED）
4. SSR 日志模式
EOF
    read -r -p '选择 [1-4]：' choice
    case "$choice" in
        1)
            "$BBR_HELPER" status
            read -r -p '输入 enable 启用、disable 关闭，其他返回：' action
            case "$action" in enable) "$BBR_HELPER" enable ;; disable) "$BBR_HELPER" disable ;; *) return 0 ;; esac
            ;;
        2|3)
            warn '此功能暂未启用：尚未取得固定版本且经过审计的 BT/PT/SPAM 规则集。没有修改任何防火墙规则。'
            return 3
            ;;
        4)
            "$LOG_HELPER" "$CONFIG_FILE" "$CONFIG_HELPER" menu
            ;;
        *) error '无效选项。'; return 2 ;;
    esac
}

update_script() {
    need_root || return
    warn '脚本自动更新暂不可用：当前没有签名 release manifest 和固定 SHA256。不会从浮动远程分支覆盖本地脚本。'
    return 3
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo '============================================================'
        echo " ShadowsocksR Ubuntu 管理脚本 v$VERSION"
        echo '============================================================'
        system_summary
        cat <<'EOF'

1. 安装 ShadowsocksR（要求固定核心提交和 SHA256）
2. 更新 ShadowsocksR（暂不可用，等待兼容性回归）
3. 卸载管理器（默认保留核心和配置）
4. 安装/检查 libsodium

5. 查看账号信息、SSR/SS 链接及本地二维码
6. 显示连接信息
7. 设置用户配置
8. 手动修改配置
9. 切换端口模式

10. 启动 ShadowsocksR
11. 停止 ShadowsocksR
12. 重启 ShadowsocksR
13. 查看 ShadowsocksR 日志

14. 其他功能（BBR / 日志 / BT-PT-SPAM）
15. 更新管理脚本（暂不可用）

0. 退出
EOF
        read -r -p '请输入数字 [0-15]：' num
        case "$num" in
            1) install_ssr || true ;;
            2) update_ssr || true ;;
            3) uninstall_ssr || true ;;
            4) libsodium_menu || true ;;
            5) view_user || true ;;
            6) view_connections || true ;;
            7)
                before=$(config_ports 2>/dev/null || true)
                manage_user || true
                after=$(config_ports 2>/dev/null || true)
                sync_port_firewall "$before" "$after" || true
                ;;
            8)
                before=$(config_ports 2>/dev/null || true)
                manual_config || true
                after=$(config_ports 2>/dev/null || true)
                sync_port_firewall "$before" "$after" || true
                ;;
            9)
                before=$(config_ports 2>/dev/null || true)
                switch_mode || true
                after=$(config_ports 2>/dev/null || true)
                sync_port_firewall "$before" "$after" || true
                ;;
            10) service_action start || true ;;
            11) service_action stop || true ;;
            12) service_action restart || true ;;
            13) view_log || true ;;
            14) other_functions || true ;;
            15) update_script || true ;;
            0) exit 0 ;;
            *) error '请输入 0-15。' ;;
        esac
        echo
        read -r -p '按 Enter 返回菜单...' _
    done
}

case "${1:-menu}" in
    --version|-v) echo "$VERSION" ;;
    menu) main_menu ;;
    status) system_summary ;;
    install) install_ssr ;;
    start|stop|restart) service_action "$1" ;;
    service-status) service_action status ;;
    *) echo "用法：$0 [menu|status|install|start|stop|restart|service-status|--version]" >&2; exit 2 ;;
esac
