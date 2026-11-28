#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
find "$ROOT" -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do
    bash -n "$file"
done
python3 -m py_compile "$ROOT/modules/config.py" "$ROOT/modules/link.py" "$ROOT/modules/connection.py" "$ROOT/install/core_install.py"
echo 'PASS: bash -n and Python byte-compilation'
