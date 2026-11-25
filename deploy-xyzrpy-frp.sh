#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

DOMAIN=xyzrpy.com
PUBLIC_IP=167.179.99.196
CONTROL_PORT=7007
FRP_VERSION=0.72.0
FRPS_UNIT=xyzrpy-frps.service
FRPS_DIR=/etc/xyzrpy-frp
FRPS_BIN="/opt/xyzrpy-frp/$FRP_VERSION/frps"
SITE=/etc/nginx/conf.d/xyzrpy-frp.conf
WEBROOT=/var/www/xyzrpy-frp-acme
CERT_NAME=xyzrpy-frp
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
MARKER='# Managed by deploy-xyzrpy-frp.sh'
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
Usage: sudo bash deploy-xyzrpy-frp.sh --email EMAIL [options]

Ubuntu 22.04+ with systemd, amd64 or arm64.
  --ssh-port PORT         Keep this VPS SSH port open (repeatable).
  --route HOST:PORT[:http|https]
                          Override or add a hostname in xyzrpy.com (repeatable).
                          PORT is the FRP remote_port. Scheme defaults to http.
                          HTTPS upstreams need a trusted cert matching HOST.
  --direct-tcp PORT[,PORT...]
                          Also expose the selected FRP TCP ports on VPS IPv4.
                          Openings persist across runs. Default is no new openings.
  --direct-bind-ip IP     Local VPS interface IPv4 for direct TCP (default 167.179.99.196).
  --help                  Show this help.

Default HTTPS routes (xyzrpy.com): @ and www -> 8091, pan -> 8081,
note -> 1995, book -> 1090, netron -> 1418, img -> 8000, docs -> 2726,
codediff -> 4173. Default UFW openings: VPS SSH, 80, 443, 7007 TCP.
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

write_managed() {
    local source=$1 path=$2 mode=$3 temporary
    assert_managed "$path"
    temporary=$(mktemp "${path%/*}/.xyzrpy-frp.XXXXXX")
    install -m "$mode" "$source" "$temporary"
    mv -fT -- "$temporary" "$path"
}

check_dns() {
    local host a_records aaaa_records failed=0
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
    printf '%s\n' "$MARKER" 'bindAddr = "0.0.0.0"' "bindPort = $CONTROL_PORT" \
        'proxyBindAddr = "127.0.0.1"' 'allowPorts = ['
    for port in "${PORTS[@]}"; do printf '    { single = %s },\n' "$port"; done
    # The supplied legacy frpc.ini has no token and may use older TLS defaults.
    printf '%s\n' ']' 'log.to = "console"' 'auth.method = "token"' \
        'auth.token = ""' 'transport.tls.force = false'
}

install_frps() {
    local digest=$2 folder="frp_${FRP_VERSION}_linux_$1"
    local changed=0
    assert_managed "$FRPS_DIR/frps.toml"
    assert_managed "/etc/systemd/system/$FRPS_UNIT"
    if ! systemctl is-active --quiet "$FRPS_UNIT" &&
        [[ -n "$(ss -H -ltn "sport = :$CONTROL_PORT")" ]]; then
        die "TCP $CONTROL_PORT is already listening. Inspect with ss -ltnp."
    fi

    if [[ ! -x "$FRPS_BIN" ]]; then
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
            --max-time 240 --output "$TMP/frp.tar.gz" \
            "https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/$folder.tar.gz"
        printf '%s  %s\n' "$digest" "$TMP/frp.tar.gz" | sha256sum --check --status \
            || die "FRP archive checksum mismatch."
        tar -xzf "$TMP/frp.tar.gz" -C "$TMP" "$folder/frps"
        install -d -m 0755 "${FRPS_BIN%/*}"
        install -m 0755 "$TMP/$folder/frps" "$FRPS_BIN"
        changed=1
    fi

    install -d -m 0700 "$FRPS_DIR"
    render_frps_config > "$TMP/frps.toml"
    "$FRPS_BIN" verify -c "$TMP/frps.toml"

    cat > "$TMP/frps.service" <<EOF
$MARKER
[Unit]
Description=FRP server for xyzrpy.com
After=network.target

[Service]
DynamicUser=yes
LoadCredential=frps.toml:$FRPS_DIR/frps.toml
ExecStart=$FRPS_BIN -c \${CREDENTIALS_DIRECTORY}/frps.toml
Restart=on-failure
RestartSec=3s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
    if ! cmp -s "$TMP/frps.toml" "$FRPS_DIR/frps.toml"; then
        write_managed "$TMP/frps.toml" "$FRPS_DIR/frps.toml" 0600
        changed=1
    fi
    if ! cmp -s "$TMP/frps.service" "/etc/systemd/system/$FRPS_UNIT"; then
        write_managed "$TMP/frps.service" "/etc/systemd/system/$FRPS_UNIT" 0644
        systemctl daemon-reload
        changed=1
    fi
    systemctl enable "$FRPS_UNIT"
    if (( changed )); then systemctl restart "$FRPS_UNIT"; else systemctl start "$FRPS_UNIT"; fi
    local attempt
    for attempt in {1..10}; do
        if systemctl is-active --quiet "$FRPS_UNIT" &&
            ( : > "/dev/tcp/127.0.0.1/$CONTROL_PORT" ) 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    die "FRP did not open TCP $CONTROL_PORT. Run: journalctl -u $FRPS_UNIT -n 50"
}

configure_direct_tcp() {
    local port base proxyd=/lib/systemd/systemd-socket-proxyd
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
    if [[ -r /proc/net/if_inet6 ]] && read -r _ < /proc/net/if_inet6; then
        ipv6_http='    listen [::]:80;'
        ipv6_tls='    listen [::]:443 ssl;'
    fi

    printf '%s\n' "$MARKER"
    printf 'server {\n    listen 80;\n%s\n    server_name %s;\n' "$ipv6_http" "${HOSTS[*]}"
    challenge_location
    if [[ "$mode" == tls ]]; then
        printf '%s\n' '    location / {'
        for host in "${HOSTS[@]}"; do
            printf '        if ($host = %s) { return 301 https://%s$request_uri; }\n' "$host" "$host"
        done
        printf '%s\n' '        return 404;' '    }'
    else
        printf '%s\n' '    location / { return 404; }'
    fi
    printf '}\n'

    [[ "$mode" == tls ]] || return 0
    cat <<'EOF'

# HTTPS virtual hosts
map $http_upgrade $xyzrpy_frp_connection {
    default upgrade;
    '' close;
}
EOF
    for host in "${HOSTS[@]}"; do
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
    local file=$1 mode=$2 previous="$TMP/previous.conf" had_previous=0 activated=0
    assert_managed "$SITE"
    if [[ -e "$SITE" ]]; then cp -p -- "$SITE" "$previous"; had_previous=1; fi
    write_managed "$file" "$SITE" 0644

    if nginx -T > "$TMP/nginx-config" 2> "$TMP/nginx-diagnostics" &&
        ! grep -Eq 'conflicting server name|duplicate default server' "$TMP/nginx-diagnostics" &&
        grep -Fxq "# configuration file $SITE:" "$TMP/nginx-config" &&
        systemctl enable --now nginx &&
        systemctl reload nginx; then
        activated=1
        if probe_hosts http 80 && { [[ "$mode" == http ]] || probe_hosts https 443; }; then
            return 0
        fi
        printf 'Nginx could not serve the local %s probe for all requested hosts.\n' "$mode" >&2
    fi

    cat "$TMP/nginx-diagnostics" >&2
    if (( had_previous )); then
        write_managed "$previous" "$SITE" 0644
    else
        rm -f -- "$SITE"
    fi
    if (( activated )); then nginx -t && systemctl reload nginx || true; fi
    die "Nginx deployment failed and the site file was restored. Check active vhosts and ports 80/443."
}

configure_https() {
    local host
    local -a cert_args=()
    assert_managed "$SITE"
    install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"
    printf '%s\n' "$PROBE_NAME" > "$TMP/probe"
    install -m 0644 "$TMP/probe" "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"

    if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" || ! -f "$SITE" ]]; then
        render_site http > "$TMP/http.conf"
        apply_site "$TMP/http.conf" http
    fi
    # The existing TLS site may lack newly added names. Stage a complete HTTP
    # vhost while reusing the last HTTPS blocks until the certificate is issued.
    if ! probe_hosts http 80; then
        render_site http > "$TMP/http.conf"
        if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" && -f "$SITE" ]]; then
            sed -n '/^# HTTPS virtual hosts$/,$p' "$SITE" >> "$TMP/http.conf"
        fi
        apply_site "$TMP/http.conf" http
    fi
    for host in "${HOSTS[@]}"; do cert_args+=(-d "$host"); done
    certbot certonly --webroot --webroot-path "$WEBROOT" --cert-name "$CERT_NAME" \
        --non-interactive --agree-tos --email "$EMAIL" --keep-until-expiring "${cert_args[@]}"

    local hook=/etc/letsencrypt/renewal-hooks/deploy/xyzrpy-frp-nginx
    # The managed-file marker follows the interpreter line for an executable hook.
    if [[ -e "$hook" || -L "$hook" ]]; then
        [[ ! -L "$hook" && -f "$hook" && "$(sed -n '2p' "$hook")" == "$MARKER" ]] \
            || die "Existing Certbot hook is not owned by this script: $hook"
    fi
    install -d -m 0755 "${hook%/*}"
    cat > "$TMP/reload-nginx" <<EOF
#!/bin/sh
$MARKER
set -eu
[ "\${RENEWED_LINEAGE:-}" = "$CERT_DIR" ] || exit 0
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
EOF
    install -m 0755 "$TMP/reload-nginx" "$hook"

    render_site tls > "$TMP/tls.conf"
    apply_site "$TMP/tls.conf" tls
    systemctl enable --now certbot.timer
}

cleanup() {
    rm -f -- "$WEBROOT/.well-known/acme-challenge/$PROBE_NAME"
    rm -rf -- "$TMP"
}

main() {
    parse_args "$@"
    [[ $EUID == 0 ]] || die "Run with sudo."
    . /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID%%.*}" -ge 22 && -d /run/systemd/system ]] \
        || die "This script requires Ubuntu 22.04 or later, with systemd running."
    local architecture digest
    case "$(dpkg --print-architecture)" in
        amd64) architecture=amd64; digest=daf719b32ca2778770bb92955e231a07414d754378b9af328aa2642862479804 ;;
        arm64) architecture=arm64; digest=02180b857480302fd934e9ddbd50fe2f73229f99062f88756abc6de9df5e95cf ;;
        *) die "Supported architectures are amd64 and arm64." ;;
    esac

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
    apt-get install -y ca-certificates curl openssl ufw dnsutils iproute2 nginx certbot

    log 'Checking DNS records and enabling firewall rules'
    check_dns
    configure_firewall

    log 'Installing and starting frps'
    install_frps "$architecture" "$digest"

    log 'Configuring Nginx and obtaining the Let'\''s Encrypt certificate'
    configure_https

    configure_direct_tcp
    log "FRP control: $PUBLIC_IP:$CONTROL_PORT"
    log 'Start frpc with your existing frpc.ini.'
    log "VPS checks: systemctl status $FRPS_UNIT nginx certbot.timer; ufw status"
    local host
    for host in "${HOSTS[@]}"; do log "https://$host -> ${SCHEME[$host]:-http}://127.0.0.1:${UPSTREAM[$host]}"; done
}

main "$@"
