#!/usr/bin/env bash
set -Eeuo pipefail
CORE=/usr/local/shadowsocksr
CONFIG=/etc/shadowsocksr/user-config.json
INIT=/etc/init.d/ssr
UNIT=/etc/systemd/system/ssr.service

[[ -r /etc/os-release ]] && . /etc/os-release
printf '系统：%s\n' "${PRETTY_NAME:-unknown}"
printf '架构：%s\n' "$(uname -m)"
for item in "$CORE" "$CORE/shadowsocks/server.py" "$CONFIG" "$INIT" "$UNIT"; do
    [[ -e "$item" ]] && printf '[FOUND] %s\n' "$item" || printf '[MISS ] %s\n' "$item"
done
if [[ -f "$CONFIG" ]]; then
    python3 - "$CONFIG" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1],encoding='utf-8'))
 mode='multi' if isinstance(d.get('port_password'),dict) else 'single'
 ports=sorted(d['port_password'],key=lambda x:int(x)) if mode=='multi' else [str(d.get('server_port','?'))]
 print('配置模式：%s；端口：%s' % (mode, ','.join(ports)))
 print('method=%s protocol=%s obfs=%s' % (d.get('method'),d.get('protocol'),d.get('obfs')))
except Exception as e:
 print('配置解析失败：%s' % e)
PY
fi
if systemctl is-active --quiet ssr.service 2>/dev/null; then echo 'systemd ssr.service：active'; else echo 'systemd ssr.service：inactive/not-installed'; fi
if [[ -x "$INIT" ]]; then "$INIT" status 2>&1 || true; fi
printf '\n当前监听端口（TCP/UDP）：\n'
ss -lntup 2>/dev/null || true
printf '\n进程线索：\n'
pgrep -af '[s]erver.py' || true
