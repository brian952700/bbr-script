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
[[ $ARCH == "x86_64" ]] && ARCH_NAME="amd64" || ARCH_NAME=$ARCH

echo -e "${BLUE}检测到系统: $OS $VER ($ARCH)${PLAIN}"

# 检查必要依赖并自动安装
check_dependencies() {
    local dep
    local need_install=()
    for dep in curl wget kmod procps; do
        case "$dep" in
            kmod) command -v modprobe >/dev/null 2>&1 || need_install+=("$dep") ;;
            procps) command -v sysctl >/dev/null 2>&1 || need_install+=("$dep") ;;
            *) command -v "$dep" >/dev/null 2>&1 || need_install+=("$dep") ;;
        esac
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need_install+=(ca-certificates)
    if [[ ${#need_install[@]} -gt 0 ]]; then
        echo -e "${BLUE}安装依赖: ${need_install[*]}${PLAIN}"
        if ! apt-get update || ! apt-get install -y "${need_install[@]}"; then
            echo -e "${RED}依赖安装失败，请检查 apt 软件源后重试。${PLAIN}" >&2
            return 1
        fi
    fi
}

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
            [[ ! "$continue_boot" =~ ^[Yy]$ ]] && exit 1
        else
            echo -e "${GREEN}/boot分区空间充足 (可用: ${boot_available}MB)${PLAIN}"
        fi
    fi
}

# 检查网络连接
check_network() {
    echo -e "${BLUE}检查网络连接...${PLAIN}"
    
    local mirrors=(
        "https://mirrors.aliyun.com"
        "https://mirrors.163.com"
        "https://mirrors.tuna.tsinghua.edu.cn"
        "https://www.baidu.com"
    )
    
    for mirror in "${mirrors[@]}"; do
        if curl -s --connect-timeout 5 "$mirror" > /dev/null 2>&1; then
            echo -e "${GREEN}网络连接正常（${mirror}）${PLAIN}"
            return 0
        fi
    done
    
    if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
        echo -e "${YELLOW}网络连接正常但HTTPS访问受限${PLAIN}"
        return 0
    else
        echo -e "${RED}网络连接失败，请检查网络设置${PLAIN}"
        return 1
    fi
}

# 检测BBR状态
check_bbr_status() {
    local param=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$param" == "bbr" ]]; then
        return 0
    else
        return 1
    fi
}

# 检测内核版本是否支持原生BBR
check_kernel_native_bbr() {
    local kernel_version=$(uname -r | cut -d- -f1)
    local major=$(echo "$kernel_version" | cut -d. -f1)
    local minor=$(echo "$kernel_version" | cut -d. -f2)
    
    # 内核4.9+支持BBR，5.4+为最佳
    if [[ $major -gt 5 ]] || [[ $major -eq 5 && $minor -ge 4 ]]; then
        echo -e "${GREEN}当前内核 $kernel_version 原生支持BBR（最佳）${PLAIN}"
        return 0
    elif [[ $major -eq 4 && $minor -ge 9 ]] || [[ $major -ge 5 ]]; then
        echo -e "${YELLOW}当前内核 $kernel_version 支持BBR（建议升级到5.4+）${PLAIN}"
        return 0
    else
        echo -e "${RED}当前内核 $kernel_version 不支持BBR，需要升级${PLAIN}"
        return 1
    fi
}

# 启用BBR
enable_bbr() {
    if check_bbr_status; then
        echo -e "${GREEN}BBR已经启用${PLAIN}"
        return 0
    fi
    
    if ! check_kernel_native_bbr; then
        echo -e "${YELLOW}需要先升级内核才能启用BBR${PLAIN}"
        return 1
    fi
    
    echo -e "${BLUE}正在配置BBR...${PLAIN}"
    
    # 配置sysctl
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
# BBR配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 基础网络优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
EOF
    
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
    
    if check_bbr_status; then
        echo -e "${GREEN}╔════════════════════════════════════════════╗${PLAIN}"
        echo -e "${GREEN}║  BBR启用成功！                            ║${PLAIN}"
        echo -e "${GREEN}║  您的网络加速已生效                       ║${PLAIN}"
        echo -e "${GREEN}╚════════════════════════════════════════════╝${PLAIN}"
        return 0
    else
        echo -e "${RED}BBR启用失败，请检查内核版本${PLAIN}"
        return 1
    fi
}

# 从当前 Debian 软件源安装本架构的内核元包，不更换软件源。
upgrade_kernel_debian() {
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
    if apt-get update && apt-get install -y "$kernel_package"; then
        echo -e "${GREEN}内核包安装/更新完成；若安装了新内核，重启后生效。${PLAIN}"
        return 0
    fi
    echo -e "${RED}内核安装/更新失败，请检查软件源和包管理器输出。${PLAIN}" >&2
    return 1
}

# 卸载多余旧内核（保留当前和最新）
remove_old_kernels() {
    echo -e "${YELLOW}检测旧内核...${PLAIN}"
    
        current_kernel=$(uname -r)
        installed_kernels=$(dpkg -l | grep 'linux-image-[0-9]' | awk '{print $2}')
        
        echo -e "${YELLOW}当前运行内核: $current_kernel${PLAIN}"
        echo -e "${YELLOW}已安装的内核：${PLAIN}"
        echo "$installed_kernels"
        
        read -p "是否清理非当前内核? [y/N]: " confirm_remove
        if [[ "$confirm_remove" =~ ^[Yy]$ ]]; then
            for kernel in $installed_kernels; do
                if [[ "$kernel" != *"$current_kernel"* ]]; then
                    echo -e "${BLUE}移除旧内核: $kernel${PLAIN}"
                    apt-get purge -y "$kernel" 2>/dev/null
                fi
            done
            apt-get autoremove -y
            echo -e "${GREEN}旧内核清理完成${PLAIN}"
        else
            echo -e "${YELLOW}已取消${PLAIN}"
        fi
}

# 显示当前状态
show_status() {
    echo -e "\n${BLUE}==================== 系统状态 ====================${PLAIN}"
    echo -e "${GREEN}系统:${PLAIN} $OS $VER"
    echo -e "${GREEN}架构:${PLAIN} $ARCH"
    echo -e "${GREEN}内核:${PLAIN} $(uname -r)"
    
    if check_bbr_status; then
        echo -e "${GREEN}BBR状态:${PLAIN} ✅ 已启用"
    else
        echo -e "${GREEN}BBR状态:${PLAIN} ❌ 未启用"
    fi
    
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR模块:${PLAIN} ✅ 已加载"
    else
        echo -e "${GREEN}BBR模块:${PLAIN} ❌ 未加载"
    fi
    
    local qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}队列算法:${PLAIN} ${qdisc:-未设置}"
    
    local congestion=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}拥塞算法:${PLAIN} ${congestion:-未设置}"
    
    echo -e "${BLUE}=================================================${PLAIN}\n"
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

snapshot_tcp_values() {
    local key value
    for key in "${TCP_TUNE_KEYS[@]}"; do
        value=$(sysctl -n "$key") || return 1
        printf '%s = %s\n' "$key" "$value" || return 1
    done
}

show_tcp_tuning() {
    echo "当前 TCP 参数："
    sysctl "${TCP_TUNE_KEYS[@]}"
    if [[ -f "$TCP_TUNE_FILE" ]]; then
        echo "已启用调优配置：$TCP_TUNE_FILE"
        head -n 2 "$TCP_TUNE_FILE"
    else
        echo "尚未启用本脚本的 TCP 调优。"
    fi
}

apply_tcp_tuning() {
    local profile="$1" max_buffer before candidate mem_kb confirm
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
    if [[ -e "$TCP_TUNE_FILE" ]] &&
       ! grep -qxF '# Managed by brian952700/bbr-script TCP tuning' <(head -n 1 "$TCP_TUNE_FILE"); then
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
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo "当前内核没有可用的 BBR，请检查内核和模块。"
        return 1
    fi
    install -d -m 700 "$TCP_TUNE_STATE" || return 1
    before=$(mktemp "$TCP_TUNE_STATE/current.XXXXXX") || return 1
    if ! snapshot_tcp_values > "$before"; then
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
    if [[ ! -e "$TCP_TUNE_BACKUP" ]] && ! cp -- "$before" "$TCP_TUNE_BACKUP"; then
        rm -f -- "$before" "$candidate"
        return 1
    fi
    if ! sysctl -p "$candidate"; then
        echo "应用失败，尝试恢复本次操作前的运行值。"
        sysctl -p "$before" || echo "恢复也失败，请检查：$before"
        rm -f -- "$candidate"
        echo "配置未保存；本次快照保留在：$before"
        return 1
    fi
    if ! chmod 644 "$candidate" || ! mv -f -- "$candidate" "$TCP_TUNE_FILE"; then
        echo "保存配置失败，尝试恢复本次操作前的运行值。"
        sysctl -p "$before" || echo "恢复也失败，请检查：$before"
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
    if [[ -e "$TCP_TUNE_FILE" ]] &&
       ! grep -qxF '# Managed by brian952700/bbr-script TCP tuning' <(head -n 1 "$TCP_TUNE_FILE"); then
        echo "文件不属于本脚本，停止恢复：$TCP_TUNE_FILE"
        return 1
    fi
    echo "恢复首次调优前记录的运行值，并移除本功能的配置文件。"
    echo "如果首次调优前已开启 BBR，恢复后仍保留 BBR。"
    read -r -p "确认恢复? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    before=$(mktemp "$TCP_TUNE_STATE/restore.XXXXXX") || return 1
    if ! snapshot_tcp_values > "$before"; then
        rm -f -- "$before"
        return 1
    fi
    if ! sysctl -p "$TCP_TUNE_BACKUP"; then
        echo "恢复失败，尝试回退本次操作。"
        sysctl -p "$before" || echo "回退也失败，请检查：$before"
        echo "配置和备份保留。"
        return 1
    fi
    if ! rm -f -- "$TCP_TUNE_FILE"; then
        echo "无法移除持久配置，尝试回退运行值；备份保留。"
        sysctl -p "$before"
        return 1
    fi
    rm -f -- "$TCP_TUNE_BACKUP" "$before"
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
        1) apply_tcp_tuning balanced ;;
        2) apply_tcp_tuning throughput ;;
        3) show_tcp_tuning ;;
        4) restore_tcp_tuning ;;
        0) return 0 ;;
        *) echo "无效选择" ;;
    esac
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║       BBR一键加速脚本 v${sh_ver} (Brian版)        ║${PLAIN}"
    echo -e "${BLUE}║       仅支持 Debian 12+，自动检测依赖            ║${PLAIN}"
    echo -e "${BLUE}║                                                 ║${PLAIN}"
    echo -e "${BLUE}║       维护者: brian952700           ║${PLAIN}"
    echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
    echo -e "${BLUE}项目: https://github.com/brian952700/bbr-script${PLAIN}"
    echo -e "${BLUE}反馈: https://github.com/brian952700/bbr-script/issues${PLAIN}"
    echo ""
    show_status
    echo -e "${GREEN}1.${PLAIN} 安装/启用 BBR ${YELLOW}(推荐先选此项)${PLAIN}"
    echo -e "${GREEN}2.${PLAIN} 安装/更新内核（Debian）"
    echo -e "${GREEN}3.${PLAIN} TCP 调优（Xray 场景，可恢复）"
    echo -e "${GREEN}4.${PLAIN} 清理旧内核 ${YELLOW}(释放/boot空间)${PLAIN}"
    echo -e "${GREEN}5.${PLAIN} 查看状态"
    echo " -------------"
    echo -e "${GREEN}0.${PLAIN} 退出"
    echo ""
    read -p "请选择操作 [0-5]: " choice
    
    case $choice in
        1)
            if check_kernel_native_bbr; then
                enable_bbr
            else
                echo -e "${YELLOW}当前内核不支持BBR，请先升级内核${PLAIN}"
                echo -e "${BLUE}提示：选择2安装 Debian 内核${PLAIN}"
            fi
            ;;
        2)
            check_boot_space
            if upgrade_kernel_debian; then
                read -r -p "是否现在重启? [y/N]: " reboot_now
                [[ "$reboot_now" =~ ^[Yy]$ ]] && reboot
            fi
            ;;
        3)
            tcp_tuning_menu
            ;;
        4)
            remove_old_kernels
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
    
    echo ""
    read -p "按回车键继续..." 
    show_menu
}

# 初始化检查
echo -e "${BLUE}╔═════════════════════════════════════════════════╗${PLAIN}"
echo -e "${BLUE}║            执行预检查...                        ║${PLAIN}"
echo -e "${BLUE}╚═════════════════════════════════════════════════╝${PLAIN}"
echo ""

# 执行所有预检查
check_dependencies || exit 1
check_network || exit 1
check_virt

echo ""
echo -e "${GREEN}预检查完成！${PLAIN}"
sleep 1

# 脚本入口
show_menu



