#!/usr/bin/env bash
# 在 Ubuntu VPS 上部署 FRPS，并通过 Nginx 提供 HTTPS 反向代理。
# 任一关键命令失败时停止，临时文件和证书探测文件由退出钩子清理。
set -Eeuo pipefail
export LC_ALL=C
umask 077

DOMAIN=xyzrpy.com
PUBLIC_IP=45.32.181.43
CONTROL_PORT=7007
VHOST_HTTP_PORT=8087
FRPS_UNIT=xyzrpy-frps.service
# GitHub 的 latest 接口返回正式发行版及其附件的下载地址和摘要。
FRP_RELEASE_API=https://api.github.com/repos/fatedier/frp/releases/latest
# 安装目录按版本和架构区分。查询发布信息后再确定具体路径。
FRP_BASE_DIR=/root/frp_ws
FRP_FOLDER=
FRP_DOWNLOAD_URL=
FRP_DIGEST=
FRPS_DIR=
FRPS_BIN=
FRPS_CONFIG=
SITE=/etc/nginx/conf.d/xyzrpy-frp.conf
HALO_SITE=/etc/nginx/sites-available/halo
HALO_ENABLED=/etc/nginx/sites-enabled/halo
HALO_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
WEBROOT=/var/www/xyzrpy-frp-acme
CERT_NAME=xyzrpy-frp
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
# 用管理标记识别本脚本生成的配置，避免覆盖手工维护的站点或服务。
MARKER='# Managed by deploy-xyzrpy-frp.sh'
# PORTS 是客户端可申请的代理端口。UPSTREAM 指定各域名对应的本地代理端口。
PORTS=(2222 1090 1726 1095 1625 1995 8081 30 881 811 812 8091 1418 18789 8000 2726 4173)
HOSTS=(xyzrpy.com www.xyzrpy.com pan.xyzrpy.com note.xyzrpy.com book.xyzrpy.com
       netron.xyzrpy.com img.xyzrpy.com docs.xyzrpy.com codediff.xyzrpy.com)
declare -A UPSTREAM=(
    [xyzrpy.com]=8091 [www.xyzrpy.com]=8091 [pan.xyzrpy.com]=8081
    [note.xyzrpy.com]=1995 [book.xyzrpy.com]=1090 [netron.xyzrpy.com]=1418
    [img.xyzrpy.com]=8000 [docs.xyzrpy.com]=2726 [codediff.xyzrpy.com]=4173
)
declare -A SCHEME=() SSH_PORTS=() DIRECT_PORTS=()
EMAIL=
DIRECT_BIND_IP=$PUBLIC_IP

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }
usage() {
    cat <<'EOF'
Usage: sudo bash <脚本文件名> --email EMAIL [options]

Ubuntu 22.04+ with systemd, amd64 or arm64.
  --ssh-port PORT         Keep this VPS SSH port open (repeatable).
  --route HOST:PORT[:http|https]
                          Override or add a hostname in xyzrpy.com (repeatable).
                          PORT is the FRP remote_port. Scheme defaults to http.
                          HTTPS upstreams need a trusted cert matching HOST.
  --direct-tcp PORT[,PORT...]
                          Also expose the selected FRP TCP ports on VPS IPv4.
                          Openings persist across runs. Default is no new openings.
  --direct-bind-ip IP     Local VPS interface IPv4 for direct TCP (default 45.32.181.43).
  --help                  Show this help.

Default HTTPS routes (xyzrpy.com): @ and www -> 8091, pan -> 8081,
note -> 1995, book -> 1090, netron -> 1418, img -> 8000, docs -> 2726,
codediff -> 4173. Default UFW openings: VPS SSH, 80, 443, 7007 TCP.
FRP HTTP vhost listens on 127.0.0.1:8087; it is not opened to the public network.
The original frpc.ini connects to TCP 7007 with its existing settings.
EOF
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ && "$1" -le 65535 ]]
}

frp_port() {
    local port
    for port in "${PORTS[@]}"; do
        [[ "$1" == "$port" ]] && return 0
    done
    return 1
}

parse_args() {
    local host port scheme
    local -a selected
    while (( $# )); do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --email|--ssh-port|--route|--direct-tcp|--direct-bind-ip)
                (( $# >= 2 )) && [[ "$2" != --* ]] || die "Missing value for $1"
                ;;
            *) die "Unknown argument $1 (see --help)" ;;
        esac
        case "$1" in
            --email) EMAIL=$2 ;;
            --ssh-port)
                valid_port "$2" || die "Invalid VPS SSH port $2"
                SSH_PORTS[$2]=1
                ;;
            --route)
                [[ "$2" =~ ^((([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)\.)*xyzrpy\.com):([0-9]+)(:(http|https))?$ ]] \
                    || die "Invalid route $2"
                host=${BASH_REMATCH[1]}
                port=${BASH_REMATCH[5]}
                scheme=${BASH_REMATCH[7]:-http}
                [[ "$port" != 2222 ]] && frp_port "$port" || die "Invalid web upstream $port"
                [[ -v UPSTREAM[$host] ]] || HOSTS+=("$host")
                UPSTREAM[$host]=$port
                SCHEME[$host]=$scheme
                ;;
            --direct-tcp)
                [[ "$2" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Invalid TCP port list $2"
                IFS=, read -r -a selected <<< "$2"
                for port in "${selected[@]}"; do
                    frp_port "$port" || die "Port $port is absent from the FRP port list"
                    DIRECT_PORTS[$port]=1
                done
                ;;
            --direct-bind-ip) DIRECT_BIND_IP=$2 ;;
        esac
        shift 2
    done
    [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || die "Provide a valid Let's Encrypt contact with --email"
}

assert_managed() {
    local path=$1
    [[ ! -L "$path" ]] || die "Refusing to replace symbolic link $path"
    if [[ -e "$path" ]]; then
        [[ -f "$path" && "$(head -n 1 "$path")" == "$MARKER" ]] \
            || die "Existing file is not owned by this script: $path"
    fi
}

# 在目标文件所在目录写入临时文件，再原子替换脚本管理的配置。
write_managed() {
    local source=$1 path=$2 mode=$3 temporary
    assert_managed "$path"
    temporary=$(mktemp "${path%/*}/.xyzrpy-frp.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$temporary" || ! mv -fT -- "$temporary" "$path"; then
        rm -f -- "$temporary"
        return 1
    fi
}

check_dns() {
    local host a_records aaaa_records failed=0
    # 在申请证书前逐个检查域名的 A 记录。存在 AAAA 记录时提示检查 IPv6 连通性。
    for host in "${HOSTS[@]}"; do
        a_records=$(dig +time=4 +tries=2 +short A "$host." |
            awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' | sort -u) \
            || die "DNS lookup failed for $host"
        if [[ "$a_records" != "$PUBLIC_IP" ]]; then
            printf 'DNS A for %s must resolve to %s (got %s)\n' \
                "$host" "$PUBLIC_IP" "${a_records:-no IPv4 address}" >&2
            failed=1
        fi
        aaaa_records=$(dig +time=4 +tries=2 +short AAAA "$host." | awk '/:/') \
            || die "IPv6 DNS lookup failed for $host"
        if [[ -n "$aaaa_records" ]]; then
            printf 'DNS AAAA for %s: %s. It must also reach this Nginx on port 80.\n' \
                "$host" "$aaaa_records" >&2
        fi
    done
    (( failed == 0 )) || die "Correct the DNS records and rerun."
}

configure_firewall() {
    local port connection_port
    # 合并显式指定的 SSH 端口、当前会话端口和本机 SSH 监听端口。
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ _ connection_port <<< "$SSH_CONNECTION"
        if valid_port "${connection_port:-}"; then SSH_PORTS[$connection_port]=1; fi
    fi
    while read -r port; do
        if valid_port "$port"; then SSH_PORTS[$port]=1; fi
    done < <({
        ss -H -ltnp | awk '/"sshd(-session)?"/ {print $4}'
        if systemctl is-active --quiet ssh.socket; then
            systemctl show --property=Listen --value ssh.socket | awk '{print $1}'
        fi
    } | awk -F: 'NF > 1 {print $NF}')
    if (( ${#SSH_PORTS[@]} == 0 )); then SSH_PORTS[22]=1; fi

    for port in "${!SSH_PORTS[@]}" 80 443 "$CONTROL_PORT"; do
        ufw allow "$port/tcp"
    done
    if ! ufw status | grep -Fx 'Status: active' >/dev/null; then
        ufw --force enable
    fi
}

render_frps_config() {
    local port
    # 服务端配置使用 TOML。allowPorts 列出客户端可申请的 TCP 代理端口。
    printf '%s\n' \
        "$MARKER" \
        '# FRPC 连接 FRPS 使用的服务端监听地址和端口' \
        'bindAddr = "0.0.0.0"' \
        "bindPort = $CONTROL_PORT" \
        '# FRP 原生 HTTP 虚拟主机监听端口' \
        "vhostHTTPPort = $VHOST_HTTP_PORT" \
        '# TCP/HTTP 代理监听在本机回环地址，由 Nginx 反向代理访问' \
        'proxyBindAddr = "127.0.0.1"' \
        'allowPorts = ['
    for port in "${PORTS[@]}"; do printf '    { single = %s },\n' "$port"; done
    # 当前 frpc.ini 未设置 token，因此这里保持空 token 以兼容现有客户端。
    printf '%s\n' \
        ']' \
        'log.to = "console"' \
        'auth.method = "token"' \
        'auth.token = ""' \
        'transport.tls.force = false'
}

# 根据 Ubuntu 的包架构和 GitHub 的正式发行版信息确定安装包。
resolve_frp_release() {
    local architecture=$1
    local release_json="$TMP/frp-release.json" tag asset_name asset_info

    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --max-time 60 --header 'Accept: application/vnd.github+json' \
        --output "$release_json" "$FRP_RELEASE_API" \
        || die '无法查询 GitHub 上的 frp 最新正式版。'

    # 限制版本标签的格式，确保由它生成的文件名和安装路径合法。
    tag=$(jq -er '.tag_name | strings | select(test("^v[0-9]+[.][0-9]+[.][0-9]+$"))' "$release_json") \
        || die 'GitHub 返回的 frp 版本标签无效。'
    FRP_FOLDER="frp_${tag#v}_linux_${architecture}"
    asset_name="$FRP_FOLDER.tar.gz"

    # 精确匹配官方附件，读取实际下载地址与 SHA-256 摘要。
    asset_info=$(jq -er --arg name "$asset_name" '
        .assets[]
        | select(.name == $name and .state == "uploaded")
        | [.browser_download_url, .digest] | @tsv
    ' "$release_json") || die "最新正式版 $tag 未提供 $asset_name。"
    IFS=$'\t' read -r FRP_DOWNLOAD_URL FRP_DIGEST <<< "$asset_info"
    [[ "$FRP_DOWNLOAD_URL" == "https://github.com/fatedier/frp/releases/download/$tag/$asset_name" ]] \
        || die "附件 $asset_name 的下载地址无效。"
    [[ "$FRP_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || die "附件 $asset_name 缺少有效的 SHA-256 摘要。"
    FRP_DIGEST=${FRP_DIGEST#sha256:}

    FRPS_DIR="$FRP_BASE_DIR/$FRP_FOLDER"
    FRPS_BIN="$FRPS_DIR/frps"
    FRPS_CONFIG="$FRPS_DIR/frps.toml"
    log "已选定 frp $tag（Linux $architecture），安装目录为 $FRPS_DIR"
}

install_frps() {
    local changed=0
    assert_managed "$FRPS_CONFIG"
    assert_managed "/etc/systemd/system/$FRPS_UNIT"
    local listen_port
    for listen_port in "$CONTROL_PORT" "$VHOST_HTTP_PORT"; do
        if ! systemctl is-active --quiet "$FRPS_UNIT" &&
            [[ -n "$(ss -H -ltn "sport = :$listen_port")" ]]; then
            die "TCP $listen_port is already listening. Inspect with ss -ltnp."
        fi
    done

    # 同一版本已经安装时复用 frps。发现新版本时下载到临时目录，
    # 核对摘要后只提取服务端程序 frps，然后由 systemd 切换到新版本目录。
    install -d -m 0755 "$FRP_BASE_DIR"
    install -d -m 0700 "$FRPS_DIR"
    if [[ ! -x "$FRPS_BIN" ]]; then
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
            --max-time 240 --output "$TMP/frp.tar.gz" "$FRP_DOWNLOAD_URL" \
            || die "下载 frp 安装包失败：$FRP_DOWNLOAD_URL"
        printf '%s  %s\n' "$FRP_DIGEST" "$TMP/frp.tar.gz" | sha256sum --check --status \
            || die 'frp 安装包的 SHA-256 校验失败。'
        tar -xOzf "$TMP/frp.tar.gz" -- "$FRP_FOLDER/frps" > "$TMP/frps"
        install -m 0755 "$TMP/frps" "$FRPS_BIN"
        changed=1
    fi

    # 先校验生成的配置，再写入正式路径。配置文件仅允许 root 读取和修改。
    render_frps_config > "$TMP/frps.toml"
    "$FRPS_BIN" verify -c "$TMP/frps.toml"

    # 按用户提供的 systemd 参数运行 FRPS，并设置开机自启动和异常自动重启。
    cat > "$TMP/frps.service" <<EOF
$MARKER
[Unit]
Description=FRP Server Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$FRPS_DIR
ExecStart=$FRPS_BIN -c $FRPS_CONFIG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$TMP/frps.toml" "$FRPS_CONFIG"; then
        write_managed "$TMP/frps.toml" "$FRPS_CONFIG" 0600
        changed=1
    fi
    if ! cmp -s "$TMP/frps.service" "/etc/systemd/system/$FRPS_UNIT"; then
        write_managed "$TMP/frps.service" "/etc/systemd/system/$FRPS_UNIT" 0644
        systemctl daemon-reload
        changed=1
    fi
    systemctl enable "$FRPS_UNIT"
    if (( changed )); then systemctl restart "$FRPS_UNIT"; else systemctl start "$FRPS_UNIT"; fi
    # 等待服务进入运行状态，并确认两个本地 TCP 端口都能接受连接。
    local attempt
    for attempt in {1..10}; do
        if systemctl is-active --quiet "$FRPS_UNIT" &&
            ( : > "/dev/tcp/127.0.0.1/$CONTROL_PORT" ) 2>/dev/null &&
            ( : > "/dev/tcp/127.0.0.1/$VHOST_HTTP_PORT" ) 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    die "FRPS 未能正常监听控制端口 $CONTROL_PORT 或 HTTP 虚拟主机端口 $VHOST_HTTP_PORT。请执行：journalctl -u $FRPS_UNIT -n 50"
}

configure_direct_tcp() {
    local port base proxyd=/lib/systemd/systemd-socket-proxyd
    # 仅为显式选定的端口创建公网监听，将连接转发到本机 FRP 代理。
    (( ${#DIRECT_PORTS[@]} )) || return 0
    [[ -x "$proxyd" ]] || proxyd=/usr/lib/systemd/systemd-socket-proxyd
    [[ -x "$proxyd" ]] || die 'systemd-socket-proxyd was not found.'
    [[ "$DIRECT_BIND_IP" != 127.* ]] && ip -4 -o addr show |
        awk '{sub(/\/.*/, "", $4); print $4}' | grep -Fx "$DIRECT_BIND_IP" >/dev/null \
        || die "--direct-bind-ip must be an IPv4 address assigned to this VPS."

    for port in "${!DIRECT_PORTS[@]}"; do
        base="xyzrpy-frp-tcp-$port"
        assert_managed "/etc/systemd/system/$base.socket"
        assert_managed "/etc/systemd/system/$base.service"
        cat > "$TMP/direct.socket" <<EOF
$MARKER
[Unit]
Description=Public FRP TCP listener for $port
Wants=network-online.target
After=network-online.target

[Socket]
ListenStream=$DIRECT_BIND_IP:$port
FreeBind=yes

[Install]
WantedBy=sockets.target
EOF
        cat > "$TMP/direct.service" <<EOF
$MARKER
[Unit]
Description=Forward public TCP $port to FRP loopback
After=$FRPS_UNIT
Requires=$base.socket

[Service]
DynamicUser=yes
ExecStart=$proxyd 127.0.0.1:$port
NoNewPrivileges=yes
EOF
        if ! cmp -s "$TMP/direct.socket" "/etc/systemd/system/$base.socket" ||
           ! cmp -s "$TMP/direct.service" "/etc/systemd/system/$base.service"; then
            systemctl stop "$base.service" "$base.socket" 2>/dev/null || true
            write_managed "$TMP/direct.socket" "/etc/systemd/system/$base.socket" 0644
            write_managed "$TMP/direct.service" "/etc/systemd/system/$base.service" 0644
            systemctl daemon-reload
        fi
        ufw allow "$port/tcp"
        if ! systemctl enable --now "$base.socket"; then
            die "Cannot listen on $DIRECT_BIND_IP:$port. Inspect with ss -ltnp and journalctl -u $base.socket."
        fi
    done
}

challenge_location() {
    cat <<EOF
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
EOF
}

render_site() {
    local mode=$1 host port scheme ipv6_http= ipv6_tls=
    local -a hosts=()
    for host in "${HOSTS[@]}"; do
        [[ "$host" == "$DOMAIN" || "$host" == "www.$DOMAIN" ]] || hosts+=("$host")
    done
    # 始终保留 HTTP 证书验证路径。证书就绪后再启用 HTTPS 和跳转。
    if [[ -r /proc/net/if_inet6 ]] && read -r _ < /proc/net/if_inet6; then
        ipv6_http='    listen [::]:80;'
        ipv6_tls='    listen [::]:443 ssl;'
    fi

    printf '%s\n' "$MARKER"
    printf 'server {\n    listen 80;\n%s\n    server_name %s;\n' "$ipv6_http" "${hosts[*]}"
    challenge_location
    if [[ "$mode" == tls ]]; then
        printf '%s\n' '    location / {'
        for host in "${hosts[@]}"; do
            printf '        if ($host = %s) { return 301 https://%s$request_uri; }\n' "$host" "$host"
        done
        printf '%s\n' '        return 404;' '    }'
    else
        printf '%s\n' '    location / { return 404; }'
    fi
    printf '}\n'

    [[ "$mode" == tls ]] || return 0
    cat <<'EOF'

# HTTPS 虚拟主机配置
map $http_upgrade $xyzrpy_frp_connection {
    default upgrade;
    '' close;
}
EOF
    for host in "${hosts[@]}"; do
        port=${UPSTREAM[$host]}
        scheme=${SCHEME[$host]:-http}
        cat <<EOF

server {
    listen 443 ssl;
$ipv6_tls
    server_name $host;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 512m;
    if (\$host != $host) { return 421; }
EOF
        challenge_location
        cat <<EOF
    location / {
        proxy_pass $scheme://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$xyzrpy_frp_connection;
        proxy_connect_timeout 5s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
EOF
        if [[ "$scheme" == https ]]; then
            cat <<EOF
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
EOF
        fi
        printf '    }\n}\n'
    done
}

# 生成 Halo 的 TLS 站点。默认两个域名共用一个代理块；
# 如果显式传入不同的 --route，则分别使用各自的上游。
render_halo_tls() {
    local host=$1 names=$2 ipv6_tls=$3
    local port=${UPSTREAM[$host]} scheme=${SCHEME[$host]:-http}
    cat <<EOF
server {
    listen 443 ssl;
$ipv6_tls
    server_name $names;
    ssl_certificate $HALO_CERT_DIR/fullchain.pem;
    ssl_certificate_key $HALO_CERT_DIR/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    client_max_body_size 512m;
EOF
    challenge_location
    cat <<EOF
    location / {
        proxy_pass $scheme://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
EOF
    if [[ "$scheme" == https ]]; then
        cat <<EOF
        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
EOF
    fi
    printf '    }\n}\n'
}

render_halo() {
    local mode=$1 www="www.$DOMAIN" ipv6_http= ipv6_tls=
    if [[ -r /proc/net/if_inet6 ]] && read -r _ < /proc/net/if_inet6; then
        ipv6_http='    listen [::]:80;'
        ipv6_tls='    listen [::]:443 ssl;'
    fi
    printf '%s\n' "$MARKER"
    printf 'server {\n    listen 80;\n%s\n    server_name %s %s;\n' "$ipv6_http" "$DOMAIN" "$www"
    # ACME 验证请求直接读取文件，其余请求在证书就绪后跳转到 HTTPS。
    challenge_location
    if [[ "$mode" == tls ]]; then
        printf '%s\n' '    location / { return 301 https://$host$request_uri; }'
    else
        printf '%s\n' '    location / { return 404; }'
    fi
    printf '}\n'
    [[ "$mode" == tls ]] || return 0
    printf '\n%s\n' '# HTTPS 虚拟主机配置'
    if [[ "${UPSTREAM[$DOMAIN]}:${SCHEME[$DOMAIN]:-http}" == "${UPSTREAM[$www]}:${SCHEME[$www]:-http}" ]]; then
        render_halo_tls "$DOMAIN" "$DOMAIN $www" "$ipv6_tls"
    else
        render_halo_tls "$DOMAIN" "$DOMAIN" "$ipv6_tls"
        render_halo_tls "$www" "$www" "$ipv6_tls"
    fi
}

probe_hosts() {
    local scheme=$1 port=$2 host response
    for host in "${HOSTS[@]}"; do
        response=$(curl --fail --silent --show-error --noproxy '*' --max-time 10 \
            --resolve "$host:$port:127.0.0.1" \
            "$scheme://$host/.well-known/acme-challenge/$PROBE_NAME") || return 1
        [[ "$response" == "$PROBE_NAME" ]] || return 1
    done
}

apply_site() {
    local file=$1 halo_file=$2 mode=$3 previous="$TMP/previous.conf"
    local had_previous=0 had_halo=0 had_link=0
    # 两份配置一起验证和重载，迁移时避免同一个域名被声明两次。
    assert_managed "$SITE"
    assert_managed "$HALO_SITE"
    if [[ -L "$HALO_ENABLED" ]]; then
        [[ "$(readlink -m -- "$HALO_ENABLED")" == "$HALO_SITE" ]] \
            || die "现有 Halo 启用链接指向其他文件：$HALO_ENABLED"
        had_link=1
    elif [[ -e "$HALO_ENABLED" ]]; then
        die "Halo 启用路径已被占用：$HALO_ENABLED"
    fi
    if [[ -e "$SITE" ]]; then cp -p -- "$SITE" "$previous"; had_previous=1; fi
    if [[ -e "$HALO_SITE" ]]; then cp -p -- "$HALO_SITE" "$TMP/previous-halo"; had_halo=1; fi

    if write_managed "$file" "$SITE" 0644 &&
        write_managed "$halo_file" "$HALO_SITE" 0644 &&
        { (( had_link )) || ln -s -- "$HALO_SITE" "$HALO_ENABLED"; } &&
        nginx -T > "$TMP/nginx-config" 2> "$TMP/nginx-diagnostics" &&
        ! grep -Eq 'conflicting server name|duplicate default server' "$TMP/nginx-diagnostics" &&
        grep -Fxq "# configuration file $SITE:" "$TMP/nginx-config" &&
        grep -Fxq "# configuration file $HALO_ENABLED:" "$TMP/nginx-config" &&
        systemctl enable --now nginx &&
        systemctl reload nginx; then
        if probe_hosts http 80 && { [[ "$mode" == http ]] || probe_hosts https 443; }; then
            return 0
        fi
        printf 'Nginx could not serve the local %s probe for all requested hosts.\n' "$mode" >&2
    fi

    if [[ -f "$TMP/nginx-diagnostics" ]]; then cat "$TMP/nginx-diagnostics" >&2; fi
    if (( had_previous )); then
        write_managed "$previous" "$SITE" 0644
    else
        rm -f -- "$SITE"
    fi
    if (( had_halo )); then
        write_managed "$TMP/previous-halo" "$HALO_SITE" 0644
    else
        rm -f -- "$HALO_SITE"
    fi
    if (( ! had_link )); then rm -f -- "$HALO_ENABLED"; fi
    if systemctl is-active --quiet nginx; then nginx -t && systemctl reload nginx || true; fi
    die "Nginx deployment failed and the site file was restored. Check active vhosts and ports 80/443."
}

install_halo_tls_options() {
    local options=/etc/letsencrypt/options-ssl-nginx.conf
    local dhparams=/etc/letsencrypt/ssl-dhparams.pem source package_files
    # webroot 签发证书时不会安装 Nginx TLS 模板，缺少时从 Ubuntu 的 Certbot 软件包复制。
    if [[ ! -s "$options" ]]; then
        package_files=$(dpkg-query -L python3-certbot-nginx python3-certbot)
        source=$(awk '/\/tls_configs\/options-ssl-nginx(-tls13)?\.conf$/ {print; exit}' <<< "$package_files")
        if [[ -z "$source" ]]; then
            source=$(awk '/\/tls_configs\/options-ssl-nginx-tls13-session-tix-on\.conf$/ {print; exit}' <<< "$package_files")
        fi
        [[ -r "$source" ]] || die '未找到 Certbot 提供的 Nginx TLS 模板。'
        install -m 0644 "$source" "$options"
    fi
    if [[ ! -s "$dhparams" ]]; then
        package_files=$(dpkg-query -L python3-certbot)
        source=$(awk '/\/ssl-dhparams\.pem$/ {print; exit}' <<< "$package_files")
        [[ -r "$source" ]] || die '未找到 Certbot 提供的 DH 参数文件。'
        install -m 0644 "$source" "$dhparams"
    fi
}

configure_https() {
    local host
    local -a cert_args=()
    assert_managed "$SITE"
    assert_managed "$HALO_SITE"
    install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"
    printf '%s\n' "$PROBE_NAME" > "$TMP/probe"
    install -m 0644 "$TMP/probe" "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"

    # 已能提供全部 HTTP 验证路径时，先签发证书，再一起切换两份站点文件。
    if ! probe_hosts http 80; then
        render_site http > "$TMP/http.conf"
        render_halo http > "$TMP/halo-http.conf"
        # 保留可继续使用的 TLS 配置。首次迁移时旧 TLS 块仍由原站点配置提供。
        if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" && -f "$SITE" ]]; then
            sed -n '/^# HTTPS 虚拟主机配置$/,$p' "$SITE" >> "$TMP/http.conf"
        fi
        if [[ -s "$HALO_CERT_DIR/fullchain.pem" && -s "$HALO_CERT_DIR/privkey.pem" && -L "$HALO_ENABLED" && -f "$HALO_SITE" ]]; then
            sed -n '/^# HTTPS 虚拟主机配置$/,$p' "$HALO_SITE" >> "$TMP/halo-http.conf"
        fi
        apply_site "$TMP/http.conf" "$TMP/halo-http.conf" http
    fi
    for host in "${HOSTS[@]}"; do cert_args+=(-d "$host"); done
    certbot certonly --webroot --webroot-path "$WEBROOT" --cert-name "$CERT_NAME" \
        --non-interactive --agree-tos --email "$EMAIL" --keep-until-expiring "${cert_args[@]}"
    # Halo 使用指定名称的证书，其他站点继续沿用原来的证书目录。
    certbot certonly --webroot --webroot-path "$WEBROOT" --cert-name "$DOMAIN" \
        --non-interactive --agree-tos --email "$EMAIL" --keep-until-expiring -d "$DOMAIN" -d "www.$DOMAIN"
    install_halo_tls_options

    local hook=/etc/letsencrypt/renewal-hooks/deploy/xyzrpy-frp-nginx
    # 可执行 Hook 的管理标记必须放在解释器声明之后，便于安全识别和更新。
    if [[ -e "$hook" || -L "$hook" ]]; then
        [[ ! -L "$hook" && -f "$hook" && "$(sed -n '2p' "$hook")" == "$MARKER" ]] \
            || die "Existing Certbot hook is not owned by this script: $hook"
    fi
    install -d -m 0755 "${hook%/*}"
    cat > "$TMP/reload-nginx" <<EOF
#!/bin/sh
$MARKER
set -eu
case "\${RENEWED_LINEAGE:-}" in
    "$CERT_DIR"|"$HALO_CERT_DIR") ;;
    *) exit 0 ;;
esac
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
EOF
    install -m 0755 "$TMP/reload-nginx" "$hook"

    render_site tls > "$TMP/tls.conf"
    render_halo tls > "$TMP/halo-tls.conf"
    apply_site "$TMP/tls.conf" "$TMP/halo-tls.conf" tls
    systemctl enable --now certbot.timer
}

cleanup() {
    # 探测文件位于证书验证目录，其他临时文件统一放在本次部署的工作目录。
    rm -f -- "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"
    rm -rf -- "$TMP"
}

main() {
    parse_args "$@"
    [[ $EUID == 0 ]] || die "Run with sudo."
    . /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID%%.*}" -ge 22 && -d /run/systemd/system ]] \
        || die "This script requires Ubuntu 22.04 or later, with systemd running."
    local architecture
    # 脚本依赖 Ubuntu 的 apt、UFW 和 systemd，这里保留原有的平台范围。
    case "$(dpkg --print-architecture)" in
        amd64) architecture=amd64 ;;
        arm64) architecture=arm64 ;;
        *) die "Supported architectures are amd64 and arm64." ;;
    esac

    # 防止两个部署进程同时修改服务、站点配置和防火墙。
    exec 9>/run/lock/xyzrpy-frp-deploy.lock
    flock -n 9 || die "Another deployment is running."
    TMP=$(mktemp -d /tmp/xyzrpy-frp.XXXXXX)
    PROBE_NAME="deploy-${TMP##*.}"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'printf "Deployment stopped at line %s\n" "$LINENO" >&2' ERR

    log 'Installing Ubuntu packages'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq openssl ufw dnsutils iproute2 nginx certbot python3-certbot-nginx

    resolve_frp_release "$architecture"

    log 'Checking DNS records and enabling firewall rules'
    check_dns
    configure_firewall

    log 'Installing and starting frps'
    install_frps

    log 'Configuring Nginx and obtaining the Let'\''s Encrypt certificate'
    configure_https

    configure_direct_tcp
    log "FRP control: $PUBLIC_IP:$CONTROL_PORT"
    log "FRP HTTP vhost (loopback): 127.0.0.1:$VHOST_HTTP_PORT"
    log "FRPS config: $FRPS_CONFIG"
    log 'Start frpc with your existing frpc.ini.'
    log "VPS checks: systemctl status $FRPS_UNIT nginx certbot.timer; ufw status"
    local host
    for host in "${HOSTS[@]}"; do log "https://$host -> ${SCHEME[$host]:-http}://127.0.0.1:${UPSTREAM[$host]}"; done
}

main "$@"
