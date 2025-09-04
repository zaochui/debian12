#!/bin/bash

# ============================================================================
# Debian 12 系统优化配置脚本 v4.0
# 功能：系统更新、密码修改、SSH配置、主机名设置、工具安装、BBR优化
# 特性：强大的APT修复机制、智能错误处理、分步安装
# ============================================================================

# 确保使用完整PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 严格错误处理
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${MAGENTA}[步骤]${NC} $1\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
log_success() { echo -e "${CYAN}✅${NC} $1"; }

# 全局变量
SCRIPT_VERSION="4.0"
SYSTEM_INFO=""
KERNEL_VERSION=""
HAS_BBR_SUPPORT=false
SERVER_IP=""
SSH_PORT="22"
NEW_HOSTNAME=""
APT_FIXED=false
INSTALL_LOG="/var/log/debian_setup.log"

# 错误处理函数
error_handler() {
    local exit_code=$1
    local line_no=$2
    if [ $exit_code -ne 0 ]; then
        log_error "脚本在第 $line_no 行发生错误 (错误码: $exit_code)"
        log_info "如遇问题，查看日志: $INSTALL_LOG"
    fi
}

# 初始化日志
init_log() {
    echo "=== Debian Setup Script v$SCRIPT_VERSION - $(date) ===" >> "$INSTALL_LOG"
    log_info "脚本开始执行，日志文件: $INSTALL_LOG"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        log_info "使用: sudo bash $0"
        exit 1
    fi
    log_success "Root权限检查通过"
}

# 检查系统版本
check_system() {
    log_step "系统环境检查"
    
    # 获取系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYSTEM_INFO="$PRETTY_NAME"
        log_info "系统版本: $SYSTEM_INFO"
        
        # 检查是否为Debian
        if [[ "$ID" != "debian" ]]; then
            log_warn "此脚本专为 Debian 设计，当前系统: $ID"
            read -p "是否继续？(y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
    
    # 检查内核版本
    KERNEL_VERSION=$(uname -r)
    log_info "内核版本: $KERNEL_VERSION"
    
    # 提取主版本号检查BBR支持
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    
    if [ "$KERNEL_MAJOR" -gt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]); then
        HAS_BBR_SUPPORT=true
        log_info "内核支持 BBR 加速"
    else
        HAS_BBR_SUPPORT=false
        log_warn "当前内核不支持 BBR (需要 4.9+)"
    fi
    
    # 获取服务器IP
    SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || wget -qO- -4 ifconfig.me 2>/dev/null || echo "未知")
    fi
    log_info "服务器IP: $SERVER_IP"
}

# 深度修复APT系统（参考附件的方法）
deep_fix_apt() {
    log_step "深度修复APT系统"
    
    # 1. 停止占用的apt进程
    log_info "停止占用的APT进程..."
    killall apt apt-get 2>/dev/null || true
    
    # 2. 清理锁文件
    log_info "清理APT锁文件..."
    rm -f /var/lib/apt/lists/lock
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/dpkg/lock*
    dpkg --configure -a 2>/dev/null || true
    
    # 3. 彻底清理缓存
    log_info "彻底清理APT缓存..."
    apt-get clean
    apt-get autoclean
    rm -rf /var/lib/apt/lists/*
    rm -rf /var/cache/apt/*.bin
    mkdir -p /var/lib/apt/lists/partial
    
    # 4. 备份并重建sources.list
    if [ ! -f /etc/apt/sources.list.original ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.original 2>/dev/null || true
    fi
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # 5. 尝试多个镜像源
    local mirrors=(
        "deb.debian.org"
        "cdn-fastly.deb.debian.org"
        "ftp.debian.org"
        "mirror.xtom.com/debian"
    )
    
    local success=false
    for mirror in "${mirrors[@]}"; do
        log_info "尝试使用镜像: $mirror"
        
        # 生成sources.list
        cat > /etc/apt/sources.list << EOF
deb http://${mirror}/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://${mirror}/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://${mirror}/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://${mirror}/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
        
        # 测试更新
        if apt-get update 2>&1 | tee -a "$INSTALL_LOG"; then
            success=true
            log_success "成功使用镜像: $mirror"
            break
        else
            log_warn "镜像 $mirror 失败，尝试下一个..."
        fi
    done
    
    if [ "$success" = false ]; then
        log_error "所有镜像源都失败了"
        log_info "尝试使用最小化配置..."
        cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main
deb http://security.debian.org/debian-security bookworm-security main
EOF
        apt-get update || {
            log_error "APT修复失败，请检查网络连接"
            return 1
        }
    fi
    
    # 6. 修复损坏的包
    log_info "修复可能损坏的包..."
    apt-get --fix-broken install -y 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    
    # 7. 清理并更新
    apt-get autoremove --purge -y 2>/dev/null || true
    
    APT_FIXED=true
    log_success "APT系统修复完成！"
}

# 系统全量更新
full_system_update() {
    log_step "执行系统更新"
    
    # 确保APT正常
    if [ "$APT_FIXED" = false ]; then
        deep_fix_apt
    fi
    
    log_info "更新软件包列表..."
    apt-get update || {
        log_warn "更新失败，尝试修复..."
        deep_fix_apt
        apt-get update
    }
    
    log_info "升级已安装的软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --allow-downgrades || {
        log_warn "升级失败，尝试修复..."
        apt-get --fix-broken install -y
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    }
    
    log_info "执行深度升级..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || log_warn "深度升级部分失败"
    
    log_info "清理不需要的软件包..."
    apt-get autoremove --purge -y
    apt-get autoclean
    apt-get clean
    
    # 清理系统日志（保留7天）
    log_info "清理系统日志..."
    journalctl --vacuum-time=7d 2>/dev/null || true
    
    # 清理临时文件
    find /tmp -type f -atime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    
    log_success "系统更新完成"
}

# 修改用户密码
change_user_password() {
    log_step "修改用户密码"
    
    # 获取当前用户
    local CURRENT_USER
    if [ -n "${SUDO_USER:-}" ]; then
        CURRENT_USER=$SUDO_USER
    else
        CURRENT_USER=$(whoami)
    fi
    
    log_info "当前用户: $CURRENT_USER"
    
    read -p "是否修改密码？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "跳过密码修改"
        return
    fi
    
    local password_set=false
    while [ "$password_set" = false ]; do
        echo -e "${YELLOW}请输入新密码（不显示）:${NC}"
        read -s PASSWORD1
        echo
        
        if [ -z "$PASSWORD1" ]; then
            log_error "密码不能为空"
            continue
        fi
        
        if [ ${#PASSWORD1} -lt 8 ]; then
            log_error "密码长度至少8个字符"
            continue
        fi
        
        echo -e "${YELLOW}请再次输入新密码:${NC}"
        read -s PASSWORD2
        echo
        
        if [ "$PASSWORD1" != "$PASSWORD2" ]; then
            log_error "两次密码不一致"
            continue
        fi
        
        echo "$CURRENT_USER:$PASSWORD1" | chpasswd
        if [ $? -eq 0 ]; then
            log_success "密码修改成功"
            password_set=true
        else
            log_error "密码修改失败"
        fi
    done
}

# 修改SSH端口
change_ssh_port() {
    log_step "配置SSH端口"
    
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    
    # 备份SSH配置
    if [ ! -f "${SSHD_CONFIG}.original" ]; then
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.original"
    fi
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # 获取当前端口
    local CURRENT_PORT=$(grep "^Port\|^#Port" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)
    CURRENT_PORT=${CURRENT_PORT:-22}
    
    log_info "当前SSH端口: $CURRENT_PORT"
    
    read -p "是否修改SSH端口？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        SSH_PORT=$CURRENT_PORT
        return
    fi
    
    while true; do
        read -p "请输入新的SSH端口 (1-65535): " NEW_PORT
        
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
            log_error "端口必须是数字"
            continue
        fi
        
        if [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
            log_error "端口范围: 1-65535"
            continue
        fi
        
        # 检查端口占用
        if ss -tuln | grep -q ":$NEW_PORT "; then
            log_error "端口 $NEW_PORT 已被占用"
            continue
        fi
        
        SSH_PORT=$NEW_PORT
        break
    done
    
    # 修改SSH配置
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
    
    # 测试配置
    if sshd -t 2>/dev/null; then
        systemctl restart sshd || systemctl restart ssh
        log_success "SSH端口已修改为: $SSH_PORT"
    else
        log_error "SSH配置错误，恢复原配置"
        cp "${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)" "$SSHD_CONFIG"
        SSH_PORT=$CURRENT_PORT
    fi
}

# 配置主机名
configure_hostname() {
    log_step "配置主机名"
    
    local CURRENT_HOSTNAME=$(hostname)
    local CURRENT_FQDN=$(hostname -f 2>/dev/null || hostname)
    
    log_info "当前主机名: $CURRENT_HOSTNAME"
    log_info "当前FQDN: $CURRENT_FQDN"
    
    read -p "是否修改主机名？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi
    
    read -p "请输入新的主机名 (如: server.domain.com): " NEW_HOSTNAME
    
    if [ -z "$NEW_HOSTNAME" ]; then
        log_error "主机名不能为空"
        return
    fi
    
    # 获取短主机名
    local SHORT_HOSTNAME=$(echo "$NEW_HOSTNAME" | cut -d. -f1)
    
    # 设置主机名
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME"
    echo "$SHORT_HOSTNAME" > /etc/hostname
    
    # 备份并更新hosts文件
    cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
    
    # 重建hosts文件
    {
        echo "127.0.0.1   localhost"
        echo "127.0.1.1   $SHORT_HOSTNAME"
        echo "$SERVER_IP   $NEW_HOSTNAME $SHORT_HOSTNAME"
        echo ""
        echo "# IPv6"
        echo "::1     localhost ip6-localhost ip6-loopback"
        echo "ff02::1 ip6-allnodes"
        echo "ff02::2 ip6-allrouters"
    } > /etc/hosts.new
    
    # 保留其他自定义条目
    if [ -f /etc/hosts.bak.$(date +%Y%m%d_%H%M%S) ]; then
        grep -v -E "^[^#].*(localhost|$CURRENT_HOSTNAME|$CURRENT_FQDN|127\.0\.|::1|ff02::)" /etc/hosts.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null >> /etc/hosts.new || true
    fi
    
    mv /etc/hosts.new /etc/hosts
    
    log_success "主机名已设置为: $NEW_HOSTNAME"
    log_info "验证: $(hostname -f 2>/dev/null || hostname)"
}

# 安装必要工具（智能分批安装）
install_essential_tools() {
    log_step "安装必要工具和常用命令"
    
    # 确保APT正常
    if [ "$APT_FIXED" = false ]; then
        deep_fix_apt
    fi
    
    # 定义工具包组
    declare -A tool_groups=(
        ["核心工具"]="wget curl nano tar gzip bzip2 xz-utils ca-certificates gnupg"
        ["系统工具"]="sudo net-tools dnsutils htop iotop iftop ncdu tree jq"
        ["开发工具"]="git vim build-essential make gcc g++ python3 python3-pip"
        ["网络工具"]="iputils-ping traceroute mtr nmap tcpdump netcat-openbsd whois"
        ["其他工具"]="rsync tmux screen neofetch bash-completion"
    )
    
    # 分组安装
    for group in "${!tool_groups[@]}"; do
        log_info "安装${group}..."
        for tool in ${tool_groups[$group]}; do
            if ! dpkg -l | grep -q "^ii.*$tool"; then
                apt-get install -y "$tool" 2>/dev/null || {
                    log_warn "⚠ $tool 安装失败，跳过"
                    echo "$tool install failed" >> "$INSTALL_LOG"
                }
            fi
        done
    done
    
    # 配置vim
    if command -v vim &>/dev/null; then
        cat > /etc/vim/vimrc.local << 'EOF'
set number
set autoindent
set tabstop=4
set shiftwidth=4
set expandtab
set paste
syntax on
EOF
        log_success "Vim配置完成"
    fi
    
    # 配置bash别名
    if ! grep -q "# Custom aliases" /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc << 'EOF'

# Custom aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ports='netstat -tulanp'
EOF
        
        # 如果安装了htop，添加别名
        if command -v htop &>/dev/null; then
            echo "alias top='htop'" >> /etc/bash.bashrc
        fi
        
        log_success "Bash别名配置完成"
    fi
    
    log_success "工具安装完成"
}

# 配置BBR加速
install_bbr() {
    log_step "配置BBR网络加速"
    
    if [ "$HAS_BBR_SUPPORT" = false ]; then
        log_warn "当前内核不支持BBR，需要内核4.9+"
        return
    fi
    
    # 检查是否已启用
    if lsmod | grep -q bbr; then
        log_info "BBR已经启用"
        return
    fi
    
    log_info "启用BBR..."
    
    # 加载BBR模块
    modprobe tcp_bbr 2>/dev/null || true
    
    # 添加BBR配置
    cat >> /etc/sysctl.conf << 'EOF'

# BBR Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Network Optimization
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200

# Memory Optimization
vm.swappiness=10
vm.dirty_ratio=30
vm.dirty_background_ratio=5
EOF
    
    # 应用配置
    sysctl -p 2>/dev/null || log_warn "部分系统参数应用失败"
    
    # 验证BBR
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        log_success "BBR已成功启用"
    else
        log_warn "BBR启用失败"
    fi
}

# 显示系统信息
show_system_info() {
    log_step "系统信息汇总"
    
    echo -e "${GREEN}系统信息:${NC}"
    echo "  主机名: $(hostname -f 2>/dev/null || hostname)"
    echo "  系统: $SYSTEM_INFO"
    echo "  内核: $KERNEL_VERSION"
    echo "  CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    echo "  内存: $(free -h | grep Mem | awk '{print $2}')"
    echo "  磁盘: $(df -h / | tail -1 | awk '{print $2" 使用 "$3" ("$5")"}')"
    echo "  IP地址: $SERVER_IP"
    echo "  SSH端口: $SSH_PORT"
    
    if [ "$HAS_BBR_SUPPORT" = true ] && lsmod | grep -q bbr; then
        echo "  BBR状态: 已启用"
    else
        echo "  BBR状态: 未启用"
    fi
    
    # 保存配置信息
    cat > /root/server_config.txt << EOF
========================================
Debian 12 系统配置信息
========================================
配置时间: $(date)
脚本版本: v$SCRIPT_VERSION
服务器IP: $SERVER_IP
SSH端口: $SSH_PORT
主机名: $(hostname -f 2>/dev/null || hostname)
内核版本: $KERNEL_VERSION
BBR状态: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未启用")

SSH连接:
ssh -p $SSH_PORT root@$SERVER_IP

配置日志: $INSTALL_LOG
========================================
EOF
    
    log_success "配置信息已保存到: /root/server_config.txt"
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║     Debian 12 系统优化配置脚本 v${SCRIPT_VERSION}          ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "请选择操作:"
    echo "  1) 执行完整优化（推荐）"
    echo "  2) 修复APT并更新系统"
    echo "  3) 修改用户密码"
    echo "  4) 修改SSH端口"
    echo "  5) 配置主机名"
    echo "  6) 安装必要工具"
    echo "  7) 安装BBR加速"
    echo "  8) 显示系统信息"
    echo "  0) 退出"
    echo
    read -p "请选择 [0-8]: " choice
    
    case $choice in
        1)
            log_info "开始执行完整系统优化..."
            deep_fix_apt
            full_system_update
            configure_hostname
            change_user_password
            change_ssh_port
            install_essential_tools
            install_bbr
            show_system_info
            log_success "所有优化已完成！"
            log_warn "建议重启系统: reboot"
            ;;
        2)
            deep_fix_apt
            full_system_update
            ;;
        3)
            change_user_password
            ;;
        4)
            change_ssh_port
            ;;
        5)
            configure_hostname
            ;;
        6)
            install_essential_tools
            ;;
        7)
            install_bbr
            ;;
        8)
            show_system_info
            ;;
        0)
            log_info "退出脚本"
            exit 0
            ;;
        *)
            log_error "无效选项"
            sleep 2
            main_menu
            ;;
    esac
    
    echo
    read -p "按Enter键返回主菜单，Ctrl+C退出..."
    main_menu
}

# 主函数
main() {
    clear
    
    # 初始化
    init_log
    check_root
    check_system
    
    # 显示主菜单
    main_menu
}

# 运行主程序
main "$@"
