#!/usr/bin/env bash
# brian952700/bbr-script — download and run the interactive BBR manager.
set -eu

if [[ ${EUID} -ne 0 ]]; then
    echo "错误：请使用 root 用户运行（sudo bash install.sh）。" >&2
    exit 1
fi

# 仅支持 Debian 12 及以上；必须在下载、依赖安装或配置修改之前检查。
check_supported_system() {
    local ID="" VERSION_ID=""
    if [[ ! -r /etc/os-release ]]; then
        echo "错误：无法识别系统，仅支持 Debian 12 及以上。" >&2
        return 1
    fi
    . /etc/os-release
    local major=${VERSION_ID%%.*}
    if [[ "$ID" != "debian" || ! "$major" =~ ^[0-9]+$ ]]; then
        echo "错误：仅支持 Debian 12 及以上，当前系统：${ID:-未知} ${VERSION_ID:-未知}。" >&2
        return 1
    fi
    if ! dpkg --compare-versions "$major" ge 12; then
        echo "错误：仅支持 Debian 12 及以上，当前版本：$VERSION_ID。" >&2
        return 1
    fi
    OS="$ID"
    VER="$VERSION_ID"
}
check_supported_system || exit 1

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


