#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG_DIR=/etc/shadowsocksr
CONFIG_FILE="$CONFIG_DIR/user-config.json"
CORE_DIR=/usr/local/shadowsocksr
HELPER_DIR=/usr/local/libexec/ssr-ubuntu
PROJECT_COPY="$HELPER_DIR/project"
UNIT_FILE=/etc/systemd/system/ssr.service
CORE_STAGE_BASE=''
CORE_CREATED=0
INSTALL_DONE=0

cleanup_install() {
    local rc=$?
    if [[ -n "$CORE_STAGE_BASE" && -d "$CORE_STAGE_BASE" ]]; then
        rm -r --one-file-system -- "$CORE_STAGE_BASE"
    fi
    if (( rc != 0 && CORE_CREATED == 1 && INSTALL_DONE == 0 )) && [[ -d "$CORE_DIR" && ! -e "$CONFIG_FILE" && ! -e "$UNIT_FILE" ]]; then
        echo '[回滚] 安装尚未创建配置/服务，移除本次新建的核心目录。' >&2
        rm -r --one-file-system -- "$CORE_DIR"
    fi
    return "$rc"
}
trap cleanup_install EXIT

fail() { echo "[错误] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "请使用 sudo 运行。"
[[ -r /etc/os-release ]] || fail "无法识别系统版本。"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail "仅支持 Ubuntu；当前系统：${PRETTY_NAME:-unknown}。"
case "${VERSION_ID:-}" in
    20.04|22.04|24.04|26.04) ;;
    *) fail "暂不支持 Ubuntu ${VERSION_ID:-unknown}。目标版本为 20.04/22.04/24.04/26.04。" ;;
esac
case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) fail "不支持的 CPU 架构：$(uname -m)。" ;;
esac

[[ ! -e "$CORE_DIR" ]] || fail "检测到已有核心目录 $CORE_DIR。为避免覆盖旧核心，请先执行迁移备份流程。"
[[ ! -e "$CONFIG_FILE" ]] || fail "检测到已有配置 $CONFIG_FILE。请使用旧服务器迁移流程，不要覆盖配置。"
[[ ! -e "$UNIT_FILE" ]] || fail "检测到已有 ssr.service，拒绝覆盖。"
[[ ! -e "$HELPER_DIR" ]] || fail "检测到已有管理器目录 $HELPER_DIR，拒绝覆盖。请先确认旧安装状态。"
[[ ! -e /usr/local/bin/ssr.sh ]] || fail "检测到已有 /usr/local/bin/ssr.sh，拒绝覆盖。"

: "${SSR_CORE_ARCHIVE:?必须提供已下载的固定提交核心压缩包路径 SSR_CORE_ARCHIVE}"
: "${SSR_CORE_COMMIT:?必须提供 40 位固定 Git commit SHA SSR_CORE_COMMIT}"
: "${SSR_CORE_SHA256:?必须提供可信来源的 SHA256 SSR_CORE_SHA256}"
[[ -f "$SSR_CORE_ARCHIVE" ]] || fail "核心压缩包不存在：$SSR_CORE_ARCHIVE"
[[ "$SSR_CORE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || fail "SSR_CORE_COMMIT 必须是 40 位 SHA。"
[[ "$SSR_CORE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || fail "SSR_CORE_SHA256 必须是 64 位 SHA256。"
actual_sha=$(sha256sum "$SSR_CORE_ARCHIVE" | awk '{print $1}')
[[ "${actual_sha,,}" == "${SSR_CORE_SHA256,,}" ]] || fail "核心 SHA256 不匹配；停止安装。"

"$ROOT/install/dependencies.sh"
PYTHON_BIN=${SSR_PYTHON_BIN:-python3}

CORE_STAGE_BASE=$(mktemp -d /usr/local/.ssr-core-stage.XXXXXX)
CORE_STAGE="$CORE_STAGE_BASE/core"
"$PYTHON_BIN" "$ROOT/install/core_install.py" \
    --archive "$SSR_CORE_ARCHIVE" \
    --commit "$SSR_CORE_COMMIT" \
    --sha256 "$SSR_CORE_SHA256" \
    --destination "$CORE_STAGE"

# Verify syntax and import against the selected Python before committing the
# new core directory. This is a smoke test, not an end-to-end client test.
PYTHONPATH="$CORE_STAGE" "$PYTHON_BIN" - "$CORE_STAGE" <<'PY'
import pathlib, py_compile, sys
root = pathlib.Path(sys.argv[1])
for path in root.rglob("*.py"):
    py_compile.compile(str(path), doraise=True)
import shadowsocks.server
print("SSR core syntax/import smoke test: PASS")
PY
mv -- "$CORE_STAGE" "$CORE_DIR"
rmdir -- "$CORE_STAGE_BASE"
CORE_STAGE_BASE=''
CORE_CREATED=1

getent group ssr >/dev/null || groupadd --system ssr
id ssr >/dev/null 2>&1 || useradd --system --gid ssr --home-dir /nonexistent --shell /usr/sbin/nologin ssr
"$PYTHON_BIN" -m venv "$CORE_DIR/venv"
install -d -o root -g ssr -m 0750 "$CONFIG_DIR"
install -d -o root -g root -m 0755 "$HELPER_DIR"
install -d -o root -g root -m 0755 "$PROJECT_COPY"
if [[ "$ROOT" != "$PROJECT_COPY" ]]; then cp -a "$ROOT/." "$PROJECT_COPY/"; fi
install -m 0644 "$ROOT/modules/config.py" "$HELPER_DIR/config.py"
install -m 0644 "$ROOT/modules/link.py" "$HELPER_DIR/link.py"
install -m 0755 "$ROOT/modules/connection.py" "$HELPER_DIR/connection.py"
install -m 0755 "$ROOT/modules/firewall.sh" "$HELPER_DIR/firewall.sh"
install -m 0755 "$ROOT/modules/bbr.sh" "$HELPER_DIR/bbr.sh"
install -m 0755 "$ROOT/modules/qr.sh" "$HELPER_DIR/qr.sh"
install -m 0755 "$ROOT/modules/service.sh" "$HELPER_DIR/service.sh"
install -m 0755 "$ROOT/modules/log.sh" "$HELPER_DIR/log.sh"

password=$("$PYTHON_BIN" -c 'import secrets; print(secrets.token_urlsafe(32))')
cat > "$CONFIG_FILE" <<JSON
{
    "server": "0.0.0.0",
    "server_ipv6": "::",
    "server_port": 2333,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "$password",
    "method": "aes-128-ctr",
    "protocol": "auth_sha1_v4_compatible",
    "protocol_param": "",
    "obfs": "plain",
    "obfs_param": "",
    "speed_limit_per_con": 0,
    "speed_limit_per_user": 0,
    "additional_ports": {},
    "timeout": 120,
    "udp_timeout": 60,
    "dns_ipv6": false,
    "connect_verbose_info": 0,
    "redirect": "",
    "fast_open": false
}
JSON
chown root:ssr "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"
"$PYTHON_BIN" "$HELPER_DIR/config.py" validate --file "$CONFIG_FILE"

install -m 0644 "$ROOT/service/ssr.service" "$UNIT_FILE"
install -m 0755 "$ROOT/ssr.sh" /usr/local/bin/ssr.sh
chown -R root:ssr "$CORE_DIR"
# Core source permissions were normalized by core_install.py. The venv keeps
# its standard executable/readable modes; do not chmod through its interpreter symlink.
systemctl daemon-reload
if ! systemctl enable --now ssr.service; then
    systemctl disable --now ssr.service >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    fail "systemd 服务启动失败。核心和配置均保留，未执行防火墙操作。请检查 journalctl -u ssr.service。"
fi

printf '\n[完成] SSR 管理服务已安装。\n'
printf '系统：Ubuntu %s / %s\n' "$VERSION_ID" "$ARCH"
printf '核心提交：%s\nSHA256：%s\n' "$SSR_CORE_COMMIT" "$actual_sha"
printf '账号端口：2333\n初始密码：%s\n' "$password"
printf '日志：journalctl -u ssr.service -f\n'
printf '\n注意：服务以 -q 启动以抑制原核心 INFO 级明文密码日志；详细连接日志暂时关闭。\n'
INSTALL_DONE=1

read -r -p '是否在当前已启用的防火墙中尝试放行 TCP/UDP 2333？不会自动启用防火墙。[y/N] ' answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    "$HELPER_DIR/firewall.sh" allow 2333 || echo "[提示] 未能安全自动放行；请检查 UFW/nftables/云平台安全组。" >&2
else
    echo "未修改防火墙。请确认云平台安全组已放行 TCP/UDP 2333。"
fi
