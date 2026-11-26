#!/usr/bin/env bash
# 在 Ubuntu 或 Debian VPS 上部署 FRPS，并通过 Nginx 提供 HTTPS 反向代理。
# 任一关键命令失败时停止，临时文件和证书探测文件由退出钩子清理。
set -Eeuo pipefail
export LC_ALL=C
umask 077

DOMAIN=xyzrpy.com
PUBLIC_IP=45.32.181.43
CONTROL_PORT=7007
VHOST_HTTP_PORT=8087
FRP_VERSION=0.72.0
FRPS_UNIT=frps.service
OLD_FRPS_UNIT=xyzrpy-frps.service
SYSTEMD_UNIT_DIR=/etc/systemd/system
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
LE_DIR=/etc/letsencrypt
HALO_CERT_DIR="$LE_DIR/live/$DOMAIN"
WEBROOT=/var/www/xyzrpy-frp-acme
CERT_NAME=xyzrpy-frp
CERT_DIR="$LE_DIR/live/$CERT_NAME"
NGINX_BACKUP_DIR=/var/backups/xyzrpy-frp-nginx
INDIVIDUAL_SITES=(book pan note netron img docs codediff)
# 用管理标记识别本脚本生成的配置，避免覆盖手工维护的站点或服务。
MARKER='# Managed by deploy-xyzrpy-frp.sh'
# PORTS 是现有 frpc.ini 的代理端口。UPSTREAM 指定各域名对应的本地代理端口。
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

Ubuntu 22.04+ or Debian 11 with systemd, amd64 or arm64.
  --ssh-port PORT         Keep this VPS SSH port open (repeatable).
  --route HOST:PORT[:http|https]
                          Override or add a hostname in xyzrpy.com (repeatable).
                          PORT is the FRP remote_port. Scheme defaults to http.
                          HTTPS upstreams need a trusted cert matching HOST.
  --direct-tcp PORT[,PORT...]
                          Use loopback FRP proxies with public listeners for the selected ports.
                          Public listeners persist across runs.
  --direct-bind-ip IP     Local VPS interface IPv4 for direct TCP (default 45.32.181.43).
  --help                  Show this help.

Default HTTPS routes (xyzrpy.com): @ and www -> 8091, pan -> 8081,
note -> 1995, book -> 1090, netron -> 1418, img -> 8000, docs -> 2726,
codediff -> 4173.
Each listed subdomain uses its own Nginx file and Let's Encrypt certificate.
UFW allows TCP for VPS SSH, 80, 443, 8087, 7007, and all FRP remote ports.
FRP v0.72.0 runs as frps.service. The default HTTP vhost port is 8087.
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
    assert_managed "$2"
    write_atomic "$@"
}

write_atomic() {
    local source=$1 path=$2 mode=$3 temporary
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

    for port in "${!SSH_PORTS[@]}" 80 443 "$VHOST_HTTP_PORT" "$CONTROL_PORT" "${PORTS[@]}"; do
        ufw allow "$port/tcp"
    done
    if ! ufw status | grep -Fx 'Status: active' >/dev/null; then
        ufw --force enable
    fi
    ufw reload
}

render_frps_config() {
    if [[ "${1:-}" == loopback ]]; then
        local port
        printf '%s\n' "$MARKER" 'bindAddr = "0.0.0.0"' "bindPort = $CONTROL_PORT" \
            "vhostHTTPPort = $VHOST_HTTP_PORT" 'proxyBindAddr = "127.0.0.1"' 'allowPorts = ['
        for port in "${PORTS[@]}"; do printf '    { single = %s },\n' "$port"; done
        printf '%s\n' ']' 'auth.token = ""' 'transport.tls.force = false'
    else
        # v0.72.0 根据 [common] 识别旧版 INI 配置，文件名仍使用 frps.toml。
        printf '%s\n' '[common]' "bind_port = $CONTROL_PORT" "vhost_http_port = $VHOST_HTTP_PORT"
    fi
}

configure_frps_paths() {
    local architecture=$1
    case "$architecture" in
        amd64) FRP_DIGEST=daf719b32ca2778770bb92955e231a07414d754378b9af328aa2642862479804 ;;
        arm64) FRP_DIGEST=02180b857480302fd934e9ddbd50fe2f73229f99062f88756abc6de9df5e95cf ;;
        *) die "Unsupported FRP architecture: $architecture" ;;
    esac
    FRP_FOLDER="frp_${FRP_VERSION}_linux_${architecture}"
    FRP_DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/$FRP_FOLDER.tar.gz"
    FRPS_DIR="$FRP_BASE_DIR/$FRP_FOLDER"
    FRPS_BIN="$FRPS_DIR/frps"
    FRPS_CONFIG="$FRPS_DIR/frps.toml"
}

matches_frps_file() {
    [[ -f "$1" && "$(<"$1")" == "$(<"$2")" ]]
}

assert_known_frps_file() {
    local path=$1 candidate
    shift
    [[ ! -L "$path" ]] || die "Refusing to replace symbolic link $path"
    [[ -e "$path" ]] || return 0
    if [[ -f "$path" && "$(head -n 1 "$path")" == "$MARKER" ]]; then return 0; fi
    for candidate in "$@"; do
        if matches_frps_file "$path" "$candidate"; then return 0; fi
    done
    die "Existing FRP file differs from the deployment configuration: $path"
}

uses_direct_listeners() {
    local socket
    (( ${#DIRECT_PORTS[@]} == 0 )) || return 0
    for socket in "$SYSTEMD_UNIT_DIR"/xyzrpy-frp-tcp-*.socket; do
        [[ -f "$socket" && "$(head -n 1 "$socket")" == "$MARKER" ]] || continue
        if systemctl is-active --quiet "${socket##*/}" ||
           systemctl is-enabled --quiet "${socket##*/}"; then
            return 0
        fi
    done
    return 1
}

wait_for_frps() {
    local attempt
    for attempt in {1..10}; do
        if systemctl is-active --quiet "$FRPS_UNIT" &&
            ( : > "/dev/tcp/127.0.0.1/$CONTROL_PORT" ) 2>/dev/null &&
            ( : > "/dev/tcp/127.0.0.1/$VHOST_HTTP_PORT" ) 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

install_frps() {
    local changed=0 config_changed=0 migrate=0 old_active=0 listen_port
    local unit="$SYSTEMD_UNIT_DIR/$FRPS_UNIT" old_unit="$SYSTEMD_UNIT_DIR/$OLD_FRPS_UNIT"
    local archive="$TMP/$FRP_FOLDER.tar.gz" cached="${FRP_BASE_DIR%/*}/$FRP_FOLDER.tar.gz"
    local source_bin="$FRPS_BIN" action=start

    render_frps_config > "$TMP/frps-minimal.toml"
    printf '%s\n' 'bindPort = 7000' > "$TMP/frps-sample.toml"
    if uses_direct_listeners; then
        render_frps_config loopback > "$TMP/frps.toml"
    else
        cp -- "$TMP/frps-minimal.toml" "$TMP/frps.toml"
    fi

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
    tail -n +2 "$TMP/frps.service" > "$TMP/frps-manual.service"
    assert_known_frps_file "$FRPS_CONFIG" "$TMP/frps-minimal.toml" "$TMP/frps-sample.toml"
    assert_known_frps_file "$unit" "$TMP/frps-manual.service"

    if [[ -f "$old_unit" && "$(head -n 1 "$old_unit")" == "$MARKER" ]]; then
        if systemctl is-active --quiet "$OLD_FRPS_UNIT"; then old_active=1; migrate=1; fi
        if systemctl is-enabled --quiet "$OLD_FRPS_UNIT"; then migrate=1; fi
    fi
    if (( ! old_active )) && ! systemctl is-active --quiet "$FRPS_UNIT"; then
        for listen_port in "$CONTROL_PORT" "$VHOST_HTTP_PORT"; do
            [[ -z "$(ss -H -ltn "sport = :$listen_port")" ]] ||
                die "TCP $listen_port is already listening. Inspect with ss -ltnp."
        done
    fi

    # 优先复用已安装的同版本程序或 root 目录下已经下载并通过校验的安装包。
    if [[ ! -x "$FRPS_BIN" || "$("$FRPS_BIN" -v)" != "$FRP_VERSION" ]]; then
        if [[ -f "$cached" ]] &&
            printf '%s  %s\n' "$FRP_DIGEST" "$cached" | sha256sum --check --status; then
            archive=$cached
        else
            curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
                --max-time 240 --output "$archive" "$FRP_DOWNLOAD_URL" \
                || die "下载 frp 安装包失败：$FRP_DOWNLOAD_URL"
            printf '%s  %s\n' "$FRP_DIGEST" "$archive" | sha256sum --check --status \
                || die 'frp 安装包的 SHA-256 校验失败。'
        fi
        tar -xzf "$archive" -C "$TMP"
        source_bin="$TMP/$FRP_FOLDER/frps"
    fi
    "$source_bin" verify -c "$TMP/frps.toml"

    if [[ "$source_bin" != "$FRPS_BIN" ]]; then
        if [[ ! -d "$FRPS_DIR" ]]; then
            install -d -m 0700 "$FRPS_DIR"
            install -m 0755 "$TMP/$FRP_FOLDER/frpc" "$FRPS_DIR/frpc"
            install -m 0644 "$TMP/$FRP_FOLDER/LICENSE" "$TMP/$FRP_FOLDER/frpc.toml" "$FRPS_DIR/"
        fi
        write_atomic "$source_bin" "$FRPS_BIN" 0755
        changed=1
    fi
    if ! matches_frps_file "$FRPS_CONFIG" "$TMP/frps.toml"; then
        if [[ -f "$FRPS_CONFIG" ]]; then cp -p -- "$FRPS_CONFIG" "$TMP/previous-frps.toml"; fi
        write_atomic "$TMP/frps.toml" "$FRPS_CONFIG" 0600
        changed=1
        config_changed=1
    fi
    if ! matches_frps_file "$unit" "$TMP/frps.service" &&
       ! matches_frps_file "$unit" "$TMP/frps-manual.service"; then
        write_atomic "$TMP/frps.service" "$unit" 0644
        changed=1
    fi

    systemctl daemon-reload
    if (( old_active )); then systemctl stop "$OLD_FRPS_UNIT"; fi
    if (( changed )) && systemctl is-active --quiet "$FRPS_UNIT"; then action=restart; fi
    if systemctl "$action" "$FRPS_UNIT" && wait_for_frps; then
        systemctl enable "$FRPS_UNIT"
        if (( migrate )); then systemctl disable "$OLD_FRPS_UNIT"; fi
        return 0
    fi

    systemctl stop "$FRPS_UNIT" || true
    if (( config_changed )) && [[ -f "$TMP/previous-frps.toml" ]]; then
        write_atomic "$TMP/previous-frps.toml" "$FRPS_CONFIG" 0600
    fi
    if (( old_active )); then systemctl start "$OLD_FRPS_UNIT" || true; fi
    die "FRPS 未能正常监听 $CONTROL_PORT 和 $VHOST_HTTP_PORT。请执行：journalctl -u $FRPS_UNIT -n 50"
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

extra_hosts() {
    local host label
    for host in "${HOSTS[@]}"; do
        case "$host" in "$DOMAIN"|"www.$DOMAIN") continue ;; esac
        for label in "${INDIVIDUAL_SITES[@]}"; do
            [[ "$host" != "$label.$DOMAIN" ]] || continue 2
        done
        printf '%s\n' "$host"
    done
}

certificate_covers() {
    local directory=$1 host=$2
    [[ -s "$directory/fullchain.pem" && -s "$directory/privkey.pem" ]] &&
        openssl x509 -in "$directory/fullchain.pem" -noout -checkhost "$host" |
        grep -Fx "Hostname $host does match certificate" >/dev/null
}

render_proxy_location() {
    local host=$1 port=${UPSTREAM[$1]} scheme=${SCHEME[$1]:-http}
    cat <<EOF
    location / {
        proxy_pass $scheme://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
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
    printf '    }\n'
}

render_proxy_site() {
    local host=$1 certificate=$2 ipv6_http= ipv6_tls=
    if [[ -r /proc/net/if_inet6 ]] && read -r _ < /proc/net/if_inet6; then
        ipv6_http='    listen [::]:80;'
        ipv6_tls='    listen [::]:443 ssl;'
    fi

    printf 'server {\n    listen 80;\n%s\n    server_name %s;\n' "$ipv6_http" "$host"
    challenge_location
    if [[ -n "$certificate" ]]; then
        printf '    location / { return 301 https://%s$request_uri; }\n' "$host"
    else
        render_proxy_location "$host"
    fi
    printf '}\n'

    [[ -n "$certificate" ]] || return 0
    cat <<EOF

server {
    listen 443 ssl;
$ipv6_tls
    server_name $host;
    ssl_certificate $certificate/fullchain.pem;
    ssl_certificate_key $certificate/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 512m;
    if (\$host != $host) { return 421; }
EOF
    challenge_location
    render_proxy_location "$host"
    printf '}\n'
}

render_site() {
    local mode=$1 host certificate
    printf '%s\n' "$MARKER"
    cat <<'EOF'
map $http_upgrade $xyzrpy_frp_connection {
    default upgrade;
    '' close;
}
EOF
    while IFS= read -r host; do
        certificate=
        if [[ "$mode" == tls ]] || certificate_covers "$CERT_DIR" "$host"; then
            certificate=$CERT_DIR
        fi
        render_proxy_site "$host" "$certificate"
    done < <(extra_hosts)
}

render_site_files() {
    local directory=$1 mode=$2 label host certificate halo_mode=http
    install -d -m 0700 "$directory"
    render_site "$mode" > "$directory/shared.conf"
    if [[ "$mode" == tls ]] ||
        { certificate_covers "$HALO_CERT_DIR" "$DOMAIN" && certificate_covers "$HALO_CERT_DIR" "www.$DOMAIN"; }; then
        halo_mode=tls
    fi
    render_halo "$halo_mode" > "$directory/halo"
    for label in "${INDIVIDUAL_SITES[@]}"; do
        host="$label.$DOMAIN"
        certificate=
        if [[ "$mode" == tls ]] || certificate_covers "$LE_DIR/live/$host" "$host"; then
            certificate="$LE_DIR/live/$host"
        elif certificate_covers "$CERT_DIR" "$host"; then
            # 迁移旧站点时继续用已有证书，直到独立证书签发成功。
            certificate=$CERT_DIR
        fi
        {
            printf '%s\n' "$MARKER"
            render_proxy_site "$host" "$certificate"
        } > "$directory/$label.conf"
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

assert_individual_site() {
    local path=$1 host=$2
    [[ ! -L "$path" ]] || die "Refusing to replace symbolic link $path"
    [[ -e "$path" ]] || return 0
    [[ -f "$path" ]] || die "Nginx site path is not a regular file: $path"
    [[ "$(head -n 1 "$path")" == "$MARKER" ]] && return 0

    # 可接管用户按示例创建的文件，包括 Certbot 加上的 HTTP 跳转块。
    # 如果同一个文件还声明其他域名，就保留原文件并停止部署。
    awk -v host="$host" '
        { sub(/#.*/, "") }
        /^[[:space:]]*server_name[[:space:]]+/ {
            sub(/^[[:space:]]*server_name[[:space:]]+/, "")
            sub(/[[:space:]]*;.*/, "")
            if ($0 != host) foreign = 1
            count++
        }
        END { exit !(count && !foreign) }
    ' "$path" || die "Nginx site $path does not exclusively serve $host."
}

apply_site() {
    local directory=$1 mode=$2 label path index attempt had_link=0 installed=1
    local rollback manual_backup=
    local -a destinations=("$SITE" "$HALO_SITE") candidates=(shared.conf halo)
    for label in "${INDIVIDUAL_SITES[@]}"; do
        path="${SITE%/*}/$label.conf"
        assert_individual_site "$path" "$label.$DOMAIN"
        destinations+=("$path")
        candidates+=("$label.conf")
    done
    assert_managed "$SITE"
    assert_managed "$HALO_SITE"
    if [[ -L "$HALO_ENABLED" ]]; then
        [[ "$(readlink -m -- "$HALO_ENABLED")" == "$HALO_SITE" ]] \
            || die "现有 Halo 启用链接指向其他文件：$HALO_ENABLED"
        had_link=1
    elif [[ -e "$HALO_ENABLED" ]]; then
        die "Halo 启用路径已被占用：$HALO_ENABLED"
    fi

    rollback=$(mktemp -d "$TMP/nginx-rollback.XXXXXX")
    for index in "${!destinations[@]}"; do
        path=${destinations[index]}
        if [[ -f "$path" ]]; then
            cp -p -- "$path" "$rollback/$index"
            if (( index >= 2 )) && [[ "$(head -n 1 "$path")" != "$MARKER" ]]; then
                if [[ -z "$manual_backup" ]]; then
                    install -d -m 0700 "$NGINX_BACKUP_DIR"
                    manual_backup=$(mktemp -d "$NGINX_BACKUP_DIR/sites.XXXXXX")
                    log "原有站点配置已备份至 $manual_backup"
                fi
                cp -p -- "$path" "$manual_backup/${path##*/}"
            fi
        fi
    done

    for index in "${!destinations[@]}"; do
        if ! write_atomic "$directory/${candidates[index]}" "${destinations[index]}" 0644; then
            installed=0
            break
        fi
    done
    local diagnostics="$rollback/nginx-diagnostics" loaded="$rollback/nginx-config"
    if (( installed )) &&
        { (( had_link )) || ln -s -- "$HALO_SITE" "$HALO_ENABLED"; } &&
        nginx -T > "$loaded" 2> "$diagnostics" &&
        ! grep -Eq 'conflicting server name|duplicate default server' "$diagnostics"; then
        for path in "$SITE" "$HALO_ENABLED" "${destinations[@]:2}"; do
            if ! grep -Fxq "# configuration file $path:" "$loaded"; then
                printf 'Nginx did not load %s\n' "$path" >&2
                installed=0
                break
            fi
        done
        if (( installed )) && systemctl enable --now nginx && systemctl reload nginx; then
            for attempt in {1..4}; do
                if probe_hosts http 80 && { [[ "$mode" != tls ]] || probe_hosts https 443; }; then
                    return 0
                fi
                if (( attempt < 4 )); then sleep 1; fi
            done
            printf 'Nginx could not serve the local %s probe for all requested hosts.\n' "$mode" >&2
        fi
    fi

    if [[ -f "$diagnostics" ]]; then cat "$diagnostics" >&2; fi
    if (( ! had_link )) && [[ -L "$HALO_ENABLED" ]]; then rm -f -- "$HALO_ENABLED"; fi
    for index in "${!destinations[@]}"; do
        path=${destinations[index]}
        if [[ -f "$rollback/$index" ]]; then
            mv -fT -- "$rollback/$index" "$path"
        else
            rm -f -- "$path"
        fi
    done
    if systemctl is-active --quiet nginx; then nginx -t && systemctl reload nginx || true; fi
    die 'Nginx deployment failed. The previous site files were restored.'
}

install_halo_tls_options() {
    local options=/etc/letsencrypt/options-ssl-nginx.conf
    local dhparams=/etc/letsencrypt/ssl-dhparams.pem source package_files
    # webroot 签发证书时不会安装 Nginx TLS 模板，缺少时从 Certbot 软件包复制。
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

ensure_named_certificate() {
    local name=$1 host ready=1
    shift
    local -a domains=()
    for host in "$@"; do
        domains+=(-d "$host")
        if ! certificate_covers "$LE_DIR/live/$name" "$host"; then ready=0; fi
    done

    if (( ready )) && [[ -f "$LE_DIR/renewal/$name.conf" ]]; then
        # 沿用此前保存的验证方式，例如人工执行 certbot --nginx 签发的证书。
        certbot renew --cert-name "$name" --non-interactive
    else
        certbot certonly --webroot --webroot-path "$WEBROOT" --cert-name "$name" \
            --non-interactive --agree-tos --email "$EMAIL" --keep-until-expiring "${domains[@]}"
    fi
}

configure_renewal_hook() {
    local hook="$LE_DIR/renewal-hooks/deploy/xyzrpy-frp-nginx" label
    if [[ -e "$hook" || -L "$hook" ]]; then
        [[ ! -L "$hook" && -f "$hook" && "$(sed -n '2p' "$hook")" == "$MARKER" ]] \
            || die "Existing Certbot hook is not owned by this script: $hook"
    fi
    install -d -m 0755 "${hook%/*}"
    {
        printf '%s\n' '#!/bin/sh' "$MARKER" 'set -eu' 'case "${RENEWED_LINEAGE:-}" in'
        printf '    "%s"|"%s"' "$CERT_DIR" "$HALO_CERT_DIR"
        for label in "${INDIVIDUAL_SITES[@]}"; do
            printf '|"%s/live/%s.%s"' "$LE_DIR" "$label" "$DOMAIN"
        done
        printf '%s\n' ') ;;' '    *) exit 0 ;;' 'esac' \
            '/usr/sbin/nginx -t' '/usr/bin/systemctl reload nginx'
    } > "$TMP/reload-nginx"
    write_atomic "$TMP/reload-nginx" "$hook" 0755
}

configure_https() {
    local label host
    install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"
    printf '%s\n' "$PROBE_NAME" > "$TMP/probe"
    install -m 0644 "$TMP/probe" "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"

    if certificate_covers "$HALO_CERT_DIR" "$DOMAIN" && certificate_covers "$HALO_CERT_DIR" "www.$DOMAIN"; then
        install_halo_tls_options
    fi
    render_site_files "$TMP/sites-staging" http
    apply_site "$TMP/sites-staging" http
    configure_renewal_hook

    for label in "${INDIVIDUAL_SITES[@]}"; do
        host="$label.$DOMAIN"
        ensure_named_certificate "$host" "$host"
    done
    ensure_named_certificate "$DOMAIN" "$DOMAIN" "www.$DOMAIN"
    if [[ -n "$(extra_hosts)" ]]; then
        # 额外 --route 站点沿用原有共享证书名称。
        ensure_named_certificate "$CERT_NAME" "${HOSTS[@]}"
    fi
    install_halo_tls_options

    render_site_files "$TMP/sites-tls" tls
    apply_site "$TMP/sites-tls" tls
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
    local os_version=${VERSION_ID:-}
    case "${ID:-}" in
        ubuntu)
            [[ "$os_version" =~ ^[0-9]+\.[0-9]+$ && "${os_version%%.*}" -ge 22 ]] ||
                die "Ubuntu 22.04 or later is required (detected ${os_version:-unknown})."
            ;;
        debian)
            [[ "$os_version" == 11 ]] || die "Debian 11 is required (detected ${os_version:-unknown})."
            ;;
        *) die "Use Ubuntu 22.04 or later, or Debian 11 (detected ${ID:-unknown})." ;;
    esac
    [[ -d /run/systemd/system ]] || die "This script requires systemd running."
    local architecture
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

    log 'Installing system packages'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl openssl ufw dnsutils iproute2 nginx certbot python3-certbot-nginx

    configure_frps_paths "$architecture"

    log 'Enabling firewall rules'
    configure_firewall

    log 'Installing and starting frps'
    install_frps

    log 'Configuring Nginx and obtaining the Let'\''s Encrypt certificate'
    check_dns
    configure_https

    configure_direct_tcp
    log "FRP control: $PUBLIC_IP:$CONTROL_PORT"
    log "FRP HTTP vhost: TCP $VHOST_HTTP_PORT"
    log "FRPS config: $FRPS_CONFIG"
    log 'Start frpc with your existing frpc.ini.'
    log "VPS checks: systemctl status $FRPS_UNIT nginx certbot.timer; ufw status"
    local host
    for host in "${HOSTS[@]}"; do log "https://$host -> ${SCHEME[$host]:-http}://127.0.0.1:${UPSTREAM[$host]}"; done
}

main "$@"
