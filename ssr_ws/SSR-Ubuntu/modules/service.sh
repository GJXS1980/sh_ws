#!/usr/bin/env bash
# systemd-only SSR service operations.
set -Eeuo pipefail
UNIT=${SSR_UNIT:-ssr.service}

case "${1:-status}" in
    start)   exec systemctl start "$UNIT" ;;
    stop)    exec systemctl stop "$UNIT" ;;
    restart) exec systemctl restart "$UNIT" ;;
    status)  exec systemctl status "$UNIT" --no-pager -l ;;
    logs)    exec journalctl -u "$UNIT" -f ;;
    *) echo "用法：$0 {start|stop|restart|status|logs}" >&2; exit 2 ;;
esac
