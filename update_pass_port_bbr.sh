#!/bin/bash

# ============================================================================
# Debian 12 CyberPanel 预配置脚本
# 功能：系统更新、密码修改、SSH配置、主机名设置、安装CyberPanel必需工具
# ============================================================================

# 确保使用完整PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
SERVER_IP=""
SSH_PORT="22"
INSTALL_LOG="/var/log/debian_setup.log"

# 等待用户按回车
wait_enter() {
    echo -e "${YELLOW}按回车键继续...${NC}"
    read
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
    log_success "Root权限检查通过"
}

# 获取服务器IP
get_server_ip() {
    SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || wget -qO- -4 ifconfig.me 2>/dev/null || echo "未知")
    fi
    log_info "服务器IP: $SERVER_IP"
}

# 修复APT系统
fix_apt() {
    log_step "修复APT系统"
    
    # 停止占用的apt进程
    log_info "停止占用的APT进程..."
    killall apt apt-get 2>/dev/null || true
    
    # 清理锁文件
    log_info "清理APT锁文件..."
    rm -f /var/lib/apt/lists/lock
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/dpkg/lock*
    dpkg --configure -a 2>/dev/null || true
    
    # 清理缓存
    log_info "清理APT缓存..."
    apt-get clean
    apt-get autoclean
    rm -rf /var/lib/apt/lists/*
    mkdir -p /var/lib/apt/lists/partial
    
    # 备份sources.list
    if [ ! -f /etc/apt/sources.list.original ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.original 2>/dev/null || true
    fi
    
    # 使用默认源
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
    
    # 更新
    log_info "更新软件包列表..."
    apt-get update
    
    log_success "APT系统修复完成"
    wait_enter
}

# 系统更新
system_update() {
    log_step "执行系统更新"
    
    log_info "升级已安装的软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    
    log_info "清理不需要的软件包..."
    apt-get autoremove --purge -y
    apt-get autoclean
    
    log_success "系统更新完成"
    wait_enter
}

# 配置主机名
configure_hostname() {
    log_step "配置主机名"
    
    local CURRENT_HOSTNAME=$(hostname)
    log_info "当前主机名: $CURRENT_HOSTNAME"
    
    while true; do
        read -p "请输入新的主机名 (如: server.domain.com): " NEW_HOSTNAME
        
        if [ -z "$NEW_HOSTNAME" ]; then
            log_error "主机名不能为空"
            continue
        fi
        
        break
    done
    
    # 获取短主机名
    local SHORT_HOSTNAME=$(echo "$NEW_HOSTNAME" | cut -d. -f1)
    
    # 设置主机名
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME"
    echo "$SHORT_HOSTNAME" > /etc/hostname
    
    # 更新hosts文件
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
    } > /etc/hosts
    
    log_success "主机名已设置为: $NEW_HOSTNAME"
    wait_enter
}

# 修改root密码
change_root_password() {
    log_step "修改root密码"
    
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
        
        echo "root:$PASSWORD1" | chpasswd
        if [ $? -eq 0 ]; then
            log_success "密码修改成功"
            password_set=true
        else
            log_error "密码修改失败"
        fi
    done
    
    wait_enter
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
    
    while true; do
        read -p "请输入新的SSH端口 (1-65535，直接回车保持默认22): " NEW_PORT
        
        # 如果直接回车，保持默认
        if [ -z "$NEW_PORT" ]; then
            SSH_PORT=22
            log_info "保持默认端口 22"
            break
        fi
        
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
        log_success "SSH端口已设置为: $SSH_PORT"
    else
        log_error "SSH配置错误，恢复原配置"
        cp "${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)" "$SSHD_CONFIG"
        SSH_PORT=$CURRENT_PORT
    fi
    
    wait_enter
}

# 安装CyberPanel必需工具
install_cyberpanel_tools() {
    log_step "安装CyberPanel必需工具"
    
    # CyberPanel必需的工具
    local REQUIRED_TOOLS="wget curl tar gzip unzip ca-certificates gnupg lsb-release software-properties-common"
    
    log_info "安装必需工具..."
    for tool in $REQUIRED_TOOLS; do
        if ! dpkg -l | grep -q "^ii.*$tool"; then
            log_info "安装 $tool..."
            apt-get install -y "$tool" 2>/dev/null || log_warn "$tool 安装失败"
        fi
    done
    
    log_success "CyberPanel必需工具安装完成"
    wait_enter
}

# 配置BBR加速
configure_bbr() {
    log_step "配置BBR网络加速"
    
    # 检查内核版本
    KERNEL_VERSION=$(uname -r)
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    
    if [ "$KERNEL_MAJOR" -lt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]); then
        log_warn "当前内核 $KERNEL_VERSION 不支持BBR (需要 4.9+)"
        wait_enter
        return
    fi
    
    # 检查是否已启用
    if lsmod | grep -q bbr; then
        log_info "BBR已经启用"
        wait_enter
        return
    fi
    
    log_info "启用BBR..."
    
    # 加载BBR模块
    modprobe tcp_bbr 2>/dev/null || true
    
    # 添加BBR配置
    if ! grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'EOF'

# BBR Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi
    
    # 应用配置
    sysctl -p 2>/dev/null
    
    # 验证BBR
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        log_success "BBR已成功启用"
    else
        log_warn "BBR启用失败"
    fi
    
    wait_enter
}

# 显示最终信息
show_final_info() {
    log_step "配置完成信息"
    
    echo -e "${GREEN}系统配置已完成！${NC}"
    echo
    echo "服务器信息："
    echo "  主机名: $(hostname -f 2>/dev/null || hostname)"
    echo "  IP地址: $SERVER_IP"
    echo "  SSH端口: $SSH_PORT"
    echo
    echo "SSH连接命令："
    echo -e "${CYAN}ssh -p $SSH_PORT root@$SERVER_IP${NC}"
    echo
    
    # 保存配置信息
    cat > /root/server_info.txt << EOF
========================================
Debian 12 CyberPanel 预配置信息
========================================
配置时间: $(date)
服务器IP: $SERVER_IP
SSH端口: $SSH_PORT
主机名: $(hostname -f 2>/dev/null || hostname)

SSH连接:
ssh -p $SSH_PORT root@$SERVER_IP

现在可以安装CyberPanel了！
========================================
EOF
    
    log_success "配置信息已保存到: /root/server_info.txt"
    echo
    log_warn "建议重启系统以应用所有配置: reboot"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║     Debian 12 CyberPanel 预配置脚本                       ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    log_info "开始执行系统配置..."
    echo
    
    # 初始化
    echo "=== Debian Setup Script - $(date) ===" > "$INSTALL_LOG"
    check_root
    get_server_ip
    
    # 执行所有步骤
    fix_apt
    system_update
    configure_hostname
    change_root_password
    change_ssh_port
    install_cyberpanel_tools
    configure_bbr
    show_final_info
}

# 运行主程序
main "$@"
