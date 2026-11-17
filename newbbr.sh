#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	System: Debian 12+
#	Description: 一键全自动优化加速你的服务器
#	Version: 1.2.0
#	Maintainer: brian952700
#	Repository: https://github.com/brian952700/bbr-script
#	Upstream: adsorgcn/bbr-script (静水流深); ylx2016/Linux-NetSpeed
#	License: MIT (see LICENSE)
#=================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

sh_ver="1.2.0"

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用root用户运行此脚本${PLAIN}" && exit 1

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

# 架构检测
ARCH=$(uname -m)

echo -e "${BLUE}检测到系统: $OS $VER ($ARCH)${PLAIN}"

# 检查虚拟化类型
check_virt() {
    echo -e "${BLUE}检查虚拟化类型...${PLAIN}"
    
    # 尝试使用systemd-detect-virt
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt)
    elif command -v virt-what &>/dev/null; then
        virt_type=$(virt-what | head -1)
    else
        # 简单检测
        if grep -q "openvz" /proc/vz/version 2>/dev/null || grep -q "openvz" /proc/cpuinfo 2>/dev/null; then
            virt_type="openvz"
        else
            virt_type="unknown"
        fi
    fi
    
    echo -e "${GREEN}虚拟化类型: ${virt_type}${PLAIN}"
    
    # OpenVZ检测
    if [[ "$virt_type" == "openvz" ]]; then
        echo -e "${RED}╔════════════════════════════════════════════╗${PLAIN}"
        echo -e "${RED}║  警告：检测到OpenVZ虚拟化                 ║${PLAIN}"
        echo -e "${RED}║  OpenVZ容器无法更换内核，无法启用BBR      ║${PLAIN}"
        echo -e "${RED}║  建议：更换为KVM/Xen虚拟化的VPS           ║${PLAIN}"
        echo -e "${RED}╚════════════════════════════════════════════╝${PLAIN}"
        read -p "是否继续（可能失败）? [y/N]: " continue_openvz
        [[ ! "$continue_openvz" =~ ^[Yy]$ ]] && exit 1
    fi
}

# 检查/boot分区空间
check_boot_space() {
    echo -e "${BLUE}检查/boot分区空间...${PLAIN}"
    
    # 获取/boot分区可用空间（MB）
    boot_available=$(df -m /boot 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [[ -n "$boot_available" ]]; then
        if [[ $boot_available -lt 100 ]]; then
            echo -e "${RED}警告：/boot分区空间不足 (可用: ${boot_available}MB)${PLAIN}"
            echo -e "${YELLOW}建议：先清理旧内核释放空间，或确保有至少100MB可用空间${PLAIN}"
            read -p "是否继续? [y/N]: " continue_boot
            [[ "$continue_boot" =~ ^[Yy]$ ]] || return 1
        else
            echo -e "${GREEN}/boot分区空间充足 (可用: ${boot_available}MB)${PLAIN}"
        fi
    fi
}

# 写操作共用同一把锁，避免多个管理会话交叉修改状态。
with_admin_lock() (
    if ! command -v flock >/dev/null; then
        echo "缺少 flock（util-linux），无法安全执行此操作。" >&2
        return 1
    fi
    exec 9>/run/lock/brian-bbr.lock || return 1
    if ! flock -n 9; then
        echo "另一个会话正在修改配置，请稍后重试。" >&2
        return 1
    fi
    "$@"
)

check_kernel_management() {
    if [[ "$virt_type" == openvz ]] || systemd-detect-virt --container --quiet 2>/dev/null; then
        echo "容器使用宿主机内核，当前环境不执行内核安装或清理。" >&2
        return 1
    fi
}

check_bbr_available() {
    if ! command -v sysctl >/dev/null; then
        echo "缺少 sysctl，请安装 procps 后重试。" >&2
        return 1
    fi
    if command -v modprobe >/dev/null; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo "当前内核或运行环境未提供 BBR，请检查内核、模块和容器权限。" >&2
        return 1
    fi
}

apply_sysctl_file() {
    local file="$1" key expected actual
    sysctl -p "$file" || return 1
    while IFS='=' read -r key expected; do
        [[ "$key" == \#* || -z "$key" ]] && continue
        key=${key//[[:space:]]/}
        actual=$(sysctl -n "$key") || return 1
        if [[ "${actual//[[:space:]]/}" != "${expected//[[:space:]]/}" ]]; then
            printf '参数回读不一致：%s（当前 %s，预期 %s）\n' "$key" "$actual" "$expected" >&2
            return 1
        fi
    done < "$file"
}

enable_bbr() {
    local target=/etc/sysctl.d/99-brian-bbr.conf marker='# Managed by brian952700/bbr-script BBR'
    local before candidate
    if [[ -e "$TCP_TUNE_FILE" || -L "$TCP_TUNE_FILE" || -e "$TCP_TUNE_BACKUP" ]]; then
        echo "已有 TCP 调优配置或恢复备份。请在菜单 3 管理它，恢复后再设置基础配置。"
        return 1
    fi
    if [[ -L "$target" ]] || { [[ -e "$target" ]] && ! grep -qxF "$marker" <(head -n 1 "$target"); }; then
        echo "基础配置文件已存在且不属于脚本：$target" >&2
        return 1
    fi
    check_bbr_available || return 1
    before=$(mktemp) || return 1
    if ! snapshot_sysctl_values net.core.default_qdisc net.ipv4.tcp_congestion_control > "$before"; then
        rm -f -- "$before"
        return 1
    fi
    candidate=$(mktemp /etc/sysctl.d/.brian-bbr.XXXXXX) || {
        rm -f -- "$before"
        return 1
    }
    if ! printf '%s\n' "$marker" 'net.core.default_qdisc = fq' \
        'net.ipv4.tcp_congestion_control = bbr' > "$candidate"; then
        rm -f -- "$before" "$candidate"
        return 1
    fi
    if ! apply_sysctl_file "$candidate" || ! chmod 644 "$candidate" || ! mv -fT -- "$candidate" "$target"; then
        echo "BBR + fq 设置失败，正在恢复原运行值。" >&2
        if apply_sysctl_file "$before"; then
            rm -f -- "$before"
        else
            echo "回退未完全成功，运行值备份：$before" >&2
        fi
        rm -f -- "$candidate"
        return 1
    fi
    rm -f -- "$before"
    echo "已验证 BBR + fq 默认值并保存：$target"
    if [[ -e /etc/sysctl.d/99-bbr.conf ]]; then
        echo "旧版 99-bbr.conf 已保留，其中额外的 TCP 参数仍可能生效。"
    fi
    echo "可用 tc qdisc show 查看现有网卡的实际队列。"
}

# 从当前 Debian 软件源安装本架构的内核元包，不更换软件源。
upgrade_kernel_debian() {
    check_kernel_management || return 1
    check_boot_space || return 1
    local kernel_arch kernel_package
    kernel_arch=$(dpkg --print-architecture) || return 1
    case "$kernel_arch" in
        amd64) kernel_package="linux-image-amd64" ;;
        arm64) kernel_package="linux-image-arm64" ;;
        armhf) kernel_package="linux-image-armmp" ;;
        *)
            echo -e "${RED}当前架构 $kernel_arch 暂不支持自动安装内核，请手动选择合适的 Debian 内核包。${PLAIN}"
            return 1
            ;;
    esac
    echo -e "${BLUE}正在从当前 Debian 软件源安装/更新 $kernel_package...${PLAIN}"
    if apt-get update --error-on=any && apt-get install -y "$kernel_package"; then
        echo -e "${GREEN}内核包安装/更新完成；若安装了新内核，重启后生效。${PLAIN}"
        return 0
    fi
    echo -e "${RED}内核安装/更新失败，请检查软件源和包管理器输出。${PLAIN}" >&2
    return 1
}

# 只清理预览中的旧内核包，保留运行中的内核及最新备用内核。
remove_old_kernels() {
    check_kernel_management || return 1
    local running installed pkg version status release running_pkg="" fallback="" fallback_version="" fallback_release=""
    local preview action planned_pkg rest confirm
    local -a candidates=()
    local -A allowed=()
    running=$(uname -r) || return 1
    installed=$(dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Status}\n' 'linux-image-[0-9]*') || return 1
    while IFS=$'\t' read -r pkg version status; do
        [[ "$status" == installed ]] || continue
        release=${pkg#linux-image-}
        release=${release%-unsigned}
        if [[ "$release" == "$running" ]]; then
            running_pkg="$pkg"
            continue
        else
            if [[ -z "$fallback" ]] || dpkg --compare-versions "$version" gt "$fallback_version"; then
                fallback="$pkg"
                fallback_version="$version"
                fallback_release="$release"
            fi
        fi
    done <<< "$installed"
    if [[ -z "$running_pkg" ]]; then
        echo "无法确认当前内核所属的 Debian 软件包，跳过清理。"
        return 1
    fi
    if [[ -z "$fallback" ]]; then
        echo "只有当前内核，没有需要清理的旧内核。"
        return 0
    fi
    if [[ ! -f "/boot/vmlinuz-$fallback_release" ]]; then
        echo "无法确认最新备用内核文件，跳过清理。"
        return 1
    fi
    while IFS=$'\t' read -r pkg version status; do
        [[ "$status" == installed ]] || continue
        release=${pkg#linux-image-}
        release=${release%-unsigned}
        [[ "$release" != "$running" && "$release" != "$fallback_release" ]] || continue
        candidates+=("$pkg")
        allowed["$pkg"]=1
    done <<< "$installed"
    echo "保留 $running_pkg 和 $fallback。"
    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "没有需要清理的旧内核。"
        return 0
    fi
    local -a apt_options=(-o APT::Get::AutomaticRemove=false -o APT::Get::Assume-Yes=false)
    preview=$(LC_ALL=C apt-get "${apt_options[@]}" -s purge -- "${candidates[@]}") || return 1
    printf '%s\n' "$preview"
    while read -r action planned_pkg rest; do
        case "$action" in
            Remv|Purg)
                planned_pkg=${planned_pkg%%:*}
                if [[ -z "${allowed[$planned_pkg]:-}" ]]; then
                    echo "APT 计划移除清理范围外的包：$planned_pkg。已停止。" >&2
                    return 1
                fi
                ;;
            Inst|Conf)
                echo "APT 计划修改其他包，已停止清理。" >&2
                return 1
                ;;
        esac
    done <<< "$preview"
    read -r -p "继续清理预览中的旧内核？[y/N] " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    if ! apt-get "${apt_options[@]}" purge -- "${candidates[@]}"; then
        echo "内核清理失败，请检查 APT 输出。" >&2
        return 1
    fi
    echo "旧内核清理完成。"
}

# 显示当前状态
show_status() {
    local congestion qdisc bbr_status module_status
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    case "$congestion" in
        bbr) bbr_status="✅ 已启用" ;;
        "") bbr_status="未知" ;;
        *) bbr_status="❌ 未启用" ;;
    esac
    if [[ -d /sys/module/tcp_bbr ]]; then
        module_status="✅ 可见"
    else
        module_status="未检测到"
    fi
    printf '%b\n' \
        "${BLUE}==================== 系统状态 ====================${PLAIN}" \
        "${GREEN}系统:${PLAIN} $OS $VER" \
        "${GREEN}架构:${PLAIN} $ARCH" \
        "${GREEN}内核:${PLAIN} $MENU_KERNEL_RELEASE" \
        "${GREEN}BBR状态:${PLAIN} $bbr_status" \
        "${GREEN}BBR模块:${PLAIN} $module_status" \
        "${GREEN}队列算法:${PLAIN} ${qdisc:-未设置}" \
        "${GREEN}拥塞算法:${PLAIN} ${congestion:-未设置}" \
        "${BLUE}=================================================${PLAIN}"
}

# TCP 调优：独立持久配置与首次运行值备份
TCP_TUNE_FILE=/etc/sysctl.d/99-z-brian-bbr-tcp.conf
TCP_TUNE_STATE=/var/lib/brian-bbr
TCP_TUNE_BACKUP="$TCP_TUNE_STATE/tcp-before.conf"
TCP_TUNE_KEYS=(
    net.core.default_qdisc net.ipv4.tcp_congestion_control
    net.core.rmem_max net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling
    net.ipv4.tcp_sack net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_slow_start_after_idle
)

snapshot_sysctl_values() {
    local key value
    for key in "$@"; do
        value=$(sysctl -n "$key") || return 1
        printf '%s = %s\n' "$key" "$value" || return 1
    done
}

show_tcp_tuning() {
    echo "当前 TCP 参数："
    sysctl "${TCP_TUNE_KEYS[@]}"
    if [[ -f "$TCP_TUNE_FILE" ]]; then
        echo "已保存的调优配置：$TCP_TUNE_FILE"
        head -n 2 "$TCP_TUNE_FILE"
    else
        echo "尚未启用本脚本的 TCP 调优。"
    fi
}

apply_tcp_tuning() {
    local profile="$1" max_buffer before candidate mem_kb confirm first_backup=0
    case "$profile" in
        balanced) max_buffer=33554432 ;;
        throughput)
            mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
            if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || (( mem_kb < 2097152 )); then
                echo "高吞吐档要求系统报告至少 2 GiB 内存，请使用均衡档。"
                return 1
            fi
            max_buffer=67108864
            ;;
        *) return 1 ;;
    esac
    if [[ -L "$TCP_TUNE_FILE" ]] || { [[ -e "$TCP_TUNE_FILE" ]] &&
       ! grep -qxF '# Managed by brian952700/bbr-script TCP tuning' <(head -n 1 "$TCP_TUNE_FILE"); }; then
        echo "调优文件不属于本脚本，请先手动检查：$TCP_TUNE_FILE"
        return 1
    fi
    if [[ -e "$TCP_TUNE_FILE" && ! -s "$TCP_TUNE_BACKUP" ]]; then
        echo "缺少原始参数备份，停止覆盖现有调优配置。"
        return 1
    fi
    echo "启用 BBR + fq、TCP 自动缓冲调节、窗口扩展、SACK 和按需 MTU 黑洞探测。"
    echo "收发缓冲上限：$((max_buffer / 1048576)) MiB；不会立即为每条连接分配全部内存。"
    echo "影响全机 TCP，高并发可能增加内存占用；不保证提速，容器还需检查内存配额。"
    echo "不更换内核、不修改 Xray 配置。"
    read -r -p "确认应用? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    check_bbr_available || return 1
    install -d -m 700 "$TCP_TUNE_STATE" || return 1
    before=$(mktemp "$TCP_TUNE_STATE/current.XXXXXX") || return 1
    if ! snapshot_sysctl_values "${TCP_TUNE_KEYS[@]}" > "$before"; then
        rm -f -- "$before"
        echo "无法读取全部参数，未应用调优。"
        return 1
    fi
    candidate=$(mktemp /etc/sysctl.d/.brian-bbr-tcp.XXXXXX) || {
        rm -f -- "$before"
        return 1
    }
    if ! cat > "$candidate" <<EOF
# Managed by brian952700/bbr-script TCP tuning
# profile=$profile; max_buffer=$max_buffer
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $max_buffer
net.core.wmem_max = $max_buffer
net.ipv4.tcp_rmem = 4096 131072 $max_buffer
net.ipv4.tcp_wmem = 4096 65536 $max_buffer
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    then
        rm -f -- "$before" "$candidate"
        return 1
    fi
    if [[ ! -e "$TCP_TUNE_BACKUP" ]]; then
        if ! ln -- "$before" "$TCP_TUNE_BACKUP"; then
            rm -f -- "$before" "$candidate"
            return 1
        fi
        first_backup=1
    fi
    if ! apply_sysctl_file "$candidate" || ! chmod 644 "$candidate" || ! mv -fT -- "$candidate" "$TCP_TUNE_FILE"; then
        echo "应用或保存失败，尝试恢复本次操作前的运行值。" >&2
        if apply_sysctl_file "$before"; then
            rm -f -- "$before"
            if (( first_backup )); then
                rm -f -- "$TCP_TUNE_BACKUP"
            fi
        else
            echo "回退未完全成功，运行值备份：$before" >&2
        fi
        rm -f -- "$candidate"
        return 1
    fi
    rm -f -- "$before"
    echo "TCP 调优已应用并保存，请用新建连接比较速度、延迟和内存占用。"
    echo "默认拥塞算法主要影响新连接；default_qdisc 不强制替换现有网卡队列。"
    echo "其他 sysctl 配置可能覆盖启动值，请重启后用子菜单3检查。"
}

restore_tcp_tuning() {
    local confirm before
    if [[ ! -s "$TCP_TUNE_BACKUP" ]]; then
        echo "没有首次调优前的备份。"
        return 1
    fi
    if [[ -L "$TCP_TUNE_FILE" ]] || { [[ -e "$TCP_TUNE_FILE" ]] &&
       ! grep -qxF '# Managed by brian952700/bbr-script TCP tuning' <(head -n 1 "$TCP_TUNE_FILE"); }; then
        echo "文件不属于本脚本，停止恢复：$TCP_TUNE_FILE"
        return 1
    fi
    echo "恢复首次调优前记录的运行值，并移除本功能的配置文件。"
    echo "如果首次调优前已开启 BBR，恢复后仍保留 BBR。"
    read -r -p "确认恢复? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    before=$(mktemp "$TCP_TUNE_STATE/restore.XXXXXX") || return 1
    if ! snapshot_sysctl_values "${TCP_TUNE_KEYS[@]}" > "$before"; then
        rm -f -- "$before"
        return 1
    fi
    if ! apply_sysctl_file "$TCP_TUNE_BACKUP"; then
        echo "恢复失败，尝试回退本次操作。"
        apply_sysctl_file "$before" || echo "回退也失败，请检查：$before"
        echo "配置和备份保留。"
        return 1
    fi
    if ! rm -f -- "$TCP_TUNE_FILE"; then
        echo "无法移除持久配置，尝试回退运行值；备份保留。"
        apply_sysctl_file "$before"
        return 1
    fi
    rm -f -- "$TCP_TUNE_BACKUP" "$before" || return 1
    echo "已恢复首次调优前参数，并移除调优文件。"
}

tcp_tuning_menu() {
    local option
    echo "========== TCP 调优（Xray / TCP 场景） =========="
    echo "1. 均衡档：32 MiB 缓冲上限（建议先测试）"
    echo "2. 高吞吐档：64 MiB 缓冲上限（至少 2 GiB 内存）"
    echo "3. 查看当前参数"
    echo "4. 恢复首次调优前的参数"
    echo "0. 返回"
    echo "不是 BBR 算法升级，不保证提速；不作用于 QUIC/UDP 的拥塞控制。"
    read -r -p "请选择 [0-4]: " option
    case "$option" in
        1) with_admin_lock apply_tcp_tuning balanced ;;
        2) with_admin_lock apply_tcp_tuning throughput ;;
        3) show_tcp_tuning ;;
        4) with_admin_lock restore_tcp_tuning ;;
        0) return 0 ;;
        *) echo "无效选择" ;;
    esac
}

# 主菜单
show_menu() {
    local choice status reboot_now
    while true; do
        status=$(show_status)
        if [[ -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]]; then
            printf '\033[H\033[2J'
        fi
        printf '%b\n' \
            "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}" \
            "${BLUE}║       BBR一键加速脚本 v${sh_ver} (Brian版)        ║${PLAIN}" \
            "${BLUE}║       适用于 Debian 12 及以上            ║${PLAIN}" \
            "${BLUE}║                                                 ║${PLAIN}" \
            "${BLUE}║       维护者: brian952700           ║${PLAIN}" \
            "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}" \
            "${BLUE}项目: https://github.com/brian952700/bbr-script${PLAIN}" \
            "${BLUE}反馈: https://github.com/brian952700/bbr-script/issues${PLAIN}" \
            "" \
            "$status" \
            "" \
            "${GREEN}1.${PLAIN} 安装/启用 BBR ${YELLOW}(推荐先选此项)${PLAIN}" \
            "${GREEN}2.${PLAIN} 安装/更新内核（Debian）" \
            "${GREEN}3.${PLAIN} TCP 调优（Xray 场景，可恢复）" \
            "${GREEN}4.${PLAIN} 清理旧内核 ${YELLOW}(释放/boot空间)${PLAIN}" \
            "${GREEN}5.${PLAIN} 查看状态" \
            " -------------" \
            "${GREEN}0.${PLAIN} 退出" \
            ""
        read -r -p "请选择操作 [0-5]: " choice || return 0

        case $choice in
            1)
                with_admin_lock enable_bbr
                ;;
            2)
                if with_admin_lock upgrade_kernel_debian; then
                    read -r -p "是否现在重启? [y/N]: " reboot_now || return 0
                    [[ "$reboot_now" =~ ^[Yy]$ ]] && reboot
                fi
                ;;
            3)
                tcp_tuning_menu
                ;;
            4)
                with_admin_lock remove_old_kernels
                ;;
            5)
                show_status
                ;;
            0)
                echo -e "${GREEN}感谢使用！${PLAIN}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入0-5${PLAIN}"
                ;;
        esac

        printf '\n'
        read -r -p "按回车键继续..." || return 0
    done
}

# 初始化检查
echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
echo -e "${BLUE}║            执行预检查...                        ║${PLAIN}"
echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
echo ""

# 执行所有预检查
check_virt

echo ""
echo -e "${GREEN}预检查完成！${PLAIN}"

# 脚本入口
MENU_KERNEL_RELEASE=$(uname -r)
show_menu
