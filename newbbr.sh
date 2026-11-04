#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#	System: Debian 12+
#	Description: 一键全自动优化加速你的服务器
#	Version: 1.1.0
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

sh_ver="1.1.0"

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
    echo -e "${GREEN}4.${PLAIN} 清理旧内核 ${YELLOW}(释放/boot空间)${PLAIN}"
    echo -e "${GREEN}5.${PLAIN} 查看状态"
    echo " -------------"
    echo -e "${GREEN}0.${PLAIN} 退出"
    echo ""
    read -p "请选择操作 [0/1/2/4/5]: " choice
    
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
            echo -e "${RED}无效选择，请输入0、1、2、4或5${PLAIN}"
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

# 智能判断：如果BBR已启用且内核版本足够，无需进入菜单
if check_bbr_status && check_kernel_native_bbr >/dev/null 2>&1; then
    echo ""
    show_status
    echo -e "${GREEN}╔════════════════════════════════════════════╗${PLAIN}"
    echo -e "${GREEN}║  系统状态良好，BBR已启用，无需操作        ║${PLAIN}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${PLAIN}"
    echo ""
    read -n1 -rp "按任意键退出..." key
    echo ""
    exit 0
fi

# 脚本入口
show_menu


