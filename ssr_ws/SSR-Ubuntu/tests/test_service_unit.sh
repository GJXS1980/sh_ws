#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! command -v systemd-analyze >/dev/null 2>&1; then
    echo 'NOT TESTED: systemd-analyze 不存在。'
    exit 0
fi
TMP=$(mktemp -d)
trap '[[ ! -d "$TMP" ]] || rm -r --one-file-system -- "$TMP"' EXIT
# Verify unit syntax while replacing only deployment-specific executables that
# are intentionally absent on the build host. This is not a runtime test.
sed \
  -e 's#^ExecStartPre=.*#ExecStartPre=/usr/bin/true#' \
  -e 's#^ExecStart=.*#ExecStart=/usr/bin/true#' \
  "$ROOT/service/ssr.service" > "$TMP/ssr.service"
systemd-analyze verify "$TMP/ssr.service"
echo 'PASS: systemd unit syntax (deployment executables stubbed)'
