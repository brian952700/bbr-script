#!/usr/bin/env bash
# brian952700/bbr-script — download and run the interactive BBR manager.
set -eu

if [[ ${EUID} -ne 0 ]]; then
    echo "错误：请使用 root 用户运行（sudo bash install.sh）。" >&2
    exit 1
fi

script_url="https://raw.githubusercontent.com/brian952700/bbr-script/main/newbbr.sh"
script_file=$(mktemp)
trap 'rm -f -- "$script_file"' EXIT

echo "正在从 brian952700/bbr-script 下载 BBR 管理脚本..."
if command -v curl >/dev/null 2>&1; then
    curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 180 "$script_url" -o "$script_file"
elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=30 -O "$script_file" "$script_url"
else
    echo "请先安装 curl 或 wget，然后重新运行。" >&2
    exit 1
fi

if [[ ! -s "$script_file" ]]; then
    echo "下载结果为空，请检查网络后重试。" >&2
    exit 1
fi
bash -n "$script_file"
bash "$script_file" "$@"

