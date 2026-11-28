#!/usr/bin/env bash
# Logging policy for the legacy core. Detailed INFO mode remains disabled
# until every core logging path has been audited for credential disclosure.
set -Eeuo pipefail
CONFIG=${1:-/etc/shadowsocksr/user-config.json}
HELPER=${2:-/usr/local/libexec/ssr-ubuntu/config.py}
PYTHON=${SSR_PYTHON:-python3}

[[ $EUID -eq 0 ]] || { echo '需要 root 权限。' >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "配置文件不存在：$CONFIG" >&2; exit 2; }
[[ -f "$HELPER" ]] || { echo "配置管理模块不存在：$HELPER" >&2; exit 2; }

status() {
    "$PYTHON" - "$CONFIG" <<'PY'
import json,sys
with open(sys.argv[1], encoding='utf-8') as f: cfg=json.load(f)
print('配置字段 connect_verbose_info=%s' % cfg.get('connect_verbose_info', 0))
print('systemd 当前使用 -q；INFO 级日志被抑制。')
print('详细日志状态：BLOCKED（等待完整日志脱敏审计）')
PY
}

case "${3:-menu}" in
    status) status ;;
    simple)
        "$PYTHON" "$HELPER" set connect_verbose_info 0 --file "$CONFIG"
        echo '已设置简单日志模式。服务仍使用 -q，避免输出未审计的 INFO 日志。'
        ;;
    detailed)
        echo '详细日志模式暂不可用（BLOCKED）。原核心含认证密码 INFO 日志，当前未完成所有日志路径审计。配置未修改。' >&2
        exit 3
        ;;
    menu)
        status
        echo '1. 保持/切换简单模式'
        echo '2. 详细模式（暂不可用）'
        read -r -p '选择 [1-2]：' choice
        case "$choice" in
            1) "$PYTHON" "$HELPER" set connect_verbose_info 0 --file "$CONFIG" ;;
            2) echo '详细日志仍为 BLOCKED；没有修改配置。' >&2; exit 3 ;;
            *) echo '已取消。' ;;
        esac
        ;;
    *) echo "用法：$0 CONFIG HELPER {status|simple|detailed|menu}" >&2; exit 2 ;;
esac
