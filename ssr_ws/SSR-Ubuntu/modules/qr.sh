#!/usr/bin/env bash
set -Eeuo pipefail

qr_generate() {
    local link=${1:?缺少链接内容}
    local output=${2:?缺少输出文件}
    if ! command -v qrencode >/dev/null 2>&1; then
        echo "未安装 qrencode。请在 Ubuntu 上执行：sudo apt-get install qrencode" >&2
        return 2
    fi
    install -d -m 0700 "$(dirname "$output")"
    qrencode -t PNG -o "$output" -- "$link"
    chmod 0600 "$output"
    printf '二维码已在本机生成：%s\n' "$output"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    qr_generate "$@"
fi
