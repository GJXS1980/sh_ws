#!/usr/bin/env bash
# Reproducible local checks for the manager source package.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

printf '[1/4] Bash syntax checks...\n'
find "$ROOT" -type f -name '*.sh' -exec bash -n {} +

printf '[2/4] Python byte-compilation...\n'
python3 -m compileall -q -f "$ROOT/modules" "$ROOT/install" "$ROOT/tests"

printf '[3/4] Python unit tests...\n'
python3 -m unittest discover -s "$ROOT/tests" -v

printf '[4/4] systemd unit syntax...\n'
bash "$ROOT/tests/test_service_unit.sh"

if command -v shellcheck >/dev/null 2>&1; then
    printf '[ShellCheck] running...\n'
    find "$ROOT" -type f -name '*.sh' -exec shellcheck {} +
else
    printf '[ShellCheck] NOT TESTED: shellcheck is not installed.\n'
fi

printf 'All available checks completed.\n'
exit 0
