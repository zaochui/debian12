#!/bin/bash

# ============================================================================
# Debian 12 安全配置脚本 - 精简版（无备份）
# 适用于新服务器的快速安全配置
# ============================================================================

# 确保使用完整PATH
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${MAGENTA}[步骤]${NC} $1\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 全局变量
HOSTNAME=""
HOSTNAME_SHORT=""
ADMIN_USER=""
ADMIN_PASS=""
SSH_PORT="22"
KERNEL_VERSION=""
HAS_BBR_SUPPORT=false
SERVER_IP=""

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

# 检查系统版本和内核
check_system() {
    log_step "系统环境检查"
    
    # 检查系统版本
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "系统版本: $PRETTY_NAME"
    fi
    
    # 检查内核版本
    KERNEL_VERSION=$(uname -r)
    log_info "内核版本: $KERNEL_VERSION"
    
    # 提取主版本号
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    
    # BBR 需要 4.9+ 内核
    if [ "$KERNEL_MAJOR" -gt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]); then
        HAS_BBR_SUPPORT=true
        log_info "内核支持 BBR"
    else
        HAS_BBR_SUPPORT=false
        log_warn "当前内核版本不支持 BBR"
    fi
    
    # 获取服务器公网IP
    SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -z "$SERVER_IP" ]; then
        # 备用方法获取IP
        SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || wget -qO- -4 ifconfig.me 2>/dev/null)
    fi
    log_info "服务器IP: $SERVER_IP"
}

# 获取用户输入
get_user_input() {
    log_step "配置信息收集"
    
    # 获取服务器名称
    current_hostname=$(hostname)
    log_info "当前服务器名称: $current_hostname"
    
    # 询问完整域名
    read -p "请输入服务器完整域名 (如: mail.zaochui.org): " HOSTNAME
    if [[ -z "$HOSTNAME" ]]; then
        HOSTNAME="$current_hostname"
        log_info "保持当前服务器名称: $HOSTNAME"
    fi
    
    # 提取短名称（第一个点之前的部分）
    HOSTNAME_SHORT=$(echo "$HOSTNAME" | cut -d. -f1)
    log_info "短名称: $HOSTNAME_SHORT"
    log_info "完整域名: $HOSTNAME"
    
    # 获取管理员用户名
    while true; do
        read -p "请输入管理员用户名 (不要使用root): " ADMIN_USER
        if [[ -z "$ADMIN_USER" ]]; then
            log_error "用户名不能为空"
        elif [[ "$ADMIN_USER" == "root" ]]; then
            log_error "不能使用root作为用户名"
        elif id "$ADMIN_USER" &>/dev/null; then
            log_warn "用户 $ADMIN_USER 已存在"
            read -p "是否使用现有用户？(y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "使用现有用户，需要设置新密码"
                break
            fi
        else
            break
        fi
    done
    
    # 获取管理员密码
    while true; do
        echo -e "${YELLOW}请设置 $ADMIN_USER 用户的密码:${NC}"
        read -s -p "输入密码: " ADMIN_PASS
        echo
        read -s -p "确认密码: " ADMIN_PASS_CONFIRM
        echo
        
        if [[ -z "$ADMIN_PASS" ]]; then
            log_error "密码不能为空"
        elif [[ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]]; then
            log_error "两次输入的密码不一致，请重新输入"
        elif [[ ${#ADMIN_PASS} -lt 6 ]]; then
            log_error "密码长度至少需要6个字符"
        else
            log_info "密码设置成功"
            break
        fi
    done
    
    # 获取SSH端口
    read -p "请输入SSH端口 (默认22，建议修改如2222): " input_port
    if [[ -n "$input_port" ]] && [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
        SSH_PORT="$input_port"
    fi
    
    echo -e "\n${GREEN}配置信息确认：${NC}"
    echo -e "  服务器域名: ${YELLOW}$HOSTNAME${NC}"
    echo -e "  服务器短名: ${YELLOW}$HOSTNAME_SHORT${NC}"
    echo -e "  服务器IP: ${YELLOW}$SERVER_IP${NC}"
    echo -e "  管理员用户: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "  SSH端口: ${YELLOW}$SSH_PORT${NC}"
    
    read -p "确认以上信息正确？(Y/n): " -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        get_user_input
    fi
}

# 设置服务器名称（改进版）
set_hostname() {
    log_step "设置服务器名称"
    
    # 设置hostname
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME"
    
    # 更新 /etc/hostname
    echo "$HOSTNAME_SHORT" > /etc/hostname
    
    # 完整更新 /etc/hosts 文件
    log_info "更新 /etc/hosts 文件..."
    
    # 创建新的 hosts 文件内容
    cat > /etc/hosts << EOF
# System hosts file
# Updated by Debian Security Setup Script on $(date)

# Localhost entries
127.0.0.1       localhost localhost.localdomain
::1             localhost localhost.localdomain

# Hostname entries
127.0.1.1       $HOSTNAME $HOSTNAME_SHORT

# Server IP mapping
$SERVER_IP      $HOSTNAME $HOSTNAME_SHORT
EOF
    
    log_info "hosts 文件已更新："
    cat /etc/hosts
    
    # 验证设置
    log_info "验证主机名设置："
    log_info "  hostname: $(hostname)"
    log_info "  hostname -f: $(hostname -f 2>/dev/null || echo '无法解析')"
}

# 全量系统更新
full_system_update() {
    log_step "执行完整系统更新"
    
    log_info "更新软件包列表..."
    apt-get update -y || log_warn "更新软件源时出现警告"
    
    log_info "升级所有已安装的软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || log_warn "升级软件包时出现警告"
    
    log_info "执行发行版升级..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || log_warn "发行版升级时出现警告"
    
    log_info "清理不需要的软件包..."
    apt-get autoremove --purge -y
    apt-get autoclean -y
    
    log_info "系统更新完成"
}

# 安装基础软件包
install_packages() {
    log_step "安装必要软件包"
    
    # 基础工具列表
    local packages=(
        "sudo"
        "curl"
        "wget"
        "nano"
        "vim"
        "htop"
        "net-tools"
        "ufw"
        "fail2ban"
        "unattended-upgrades"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "software-properties-common"
        "rsyslog"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "安装 $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || log_warn "$pkg 安装失败，继续..."
        fi
    done
    
    # 确保rsyslog运行
    if command -v rsyslog &>/dev/null; then
        systemctl restart rsyslog 2>/dev/null || true
        log_info "rsyslog 服务已启动"
    fi
}

# 创建管理用户
create_admin_user() {
    log_step "配置管理用户: $ADMIN_USER"
    
    # 创建用户（如果不存在）
    if ! id "$ADMIN_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$ADMIN_USER"
        usermod -aG sudo "$ADMIN_USER" 2>/dev/null || true
        log_info "用户 $ADMIN_USER 创建成功"
    else
        log_info "用户 $ADMIN_USER 已存在，更新密码"
    fi
    
    # 设置密码（使用前面收集的密码）
    echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    if [ $? -eq 0 ]; then
        log_info "用户密码设置成功"
    else
        log_error "密码设置失败，尝试手动设置"
        passwd "$ADMIN_USER"
    fi
    
    # 配置sudo权限
    local sudoers_file="/etc/sudoers.d/90-$ADMIN_USER"
    cat > "$sudoers_file" << EOF
# Sudo permissions for $ADMIN_USER
$ADMIN_USER ALL=(ALL:ALL) ALL
EOF
    
    chmod 440 "$sudoers_file"
    
    # 验证sudoers配置
    if visudo -c -f "$sudoers_file" &>/dev/null; then
        log_info "sudo权限配置成功"
    else
        log_error "sudo配置有误，尝试修复..."
        rm -f "$sudoers_file"
        echo "$ADMIN_USER ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo
    fi
}

# 配置SSH安全
configure_ssh() {
    log_step "配置SSH安全设置"
    
    local ssh_config_d="/etc/ssh/sshd_config.d"
    mkdir -p "$ssh_config_d"
    
    # 创建自定义SSH配置
    cat > "$ssh_config_d/99-security.conf" << EOF
# Custom SSH Security Configuration
# Generated on $(date)

# Port configuration
Port $SSH_PORT

# Authentication settings
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
ChallengeResponseAuthentication no
UsePAM yes

# User restrictions
AllowUsers $ADMIN_USER

# Security limits
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60

# Other security settings
X11Forwarding no
PrintMotd yes
PrintLastLog yes
TCPKeepAlive yes
UseDNS no

# Logging
SyslogFacility AUTH
LogLevel VERBOSE
EOF
    
    # 测试SSH配置
    if sshd -t &>/dev/null; then
        log_info "SSH配置测试通过"
        systemctl restart sshd || systemctl restart ssh
        log_info "SSH服务已重启"
    else
        log_error "SSH配置有误，保持原配置"
        rm -f "$ssh_config_d/99-security.conf"
    fi
}

# 配置防火墙
setup_firewall() {
    log_step "配置防火墙规则"
    
    # 检查ufw是否已安装
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw
    fi
    
    # 先添加SSH端口规则（防止锁定）
    ufw allow "$SSH_PORT/tcp" comment 'SSH' 2>/dev/null || log_warn "SSH端口规则添加失败"
    
    # 如果修改了默认SSH端口，临时保留22端口
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow 22/tcp comment 'SSH-Temp' 2>/dev/null || true
        log_warn "临时保留22端口，确认新端口可用后执行: sudo ufw delete allow 22/tcp"
    fi
    
    # 添加常用服务端口
    ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
    ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
    
    # 设置默认策略
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    
    # 启用防火墙
    echo "y" | ufw enable 2>/dev/null || log_warn "防火墙启用失败"
    
    if ufw status | grep -q "Status: active"; then
        log_info "防火墙已成功启用"
        ufw status numbered
    else
        log_warn "防火墙未能启用，请手动检查"
    fi
}

# 配置Fail2Ban
configure_fail2ban() {
    log_step "配置Fail2Ban防护"
    
    # 确保fail2ban已安装
    if ! dpkg -l | grep -q "^ii.*fail2ban"; then
        apt-get install -y fail2ban
    fi
    
    # 停止服务以便配置
    systemctl stop fail2ban 2>/dev/null || true
    
    # 清理可能存在的错误socket文件
    rm -f /var/run/fail2ban/fail2ban.sock 2>/dev/null || true
    
    # 创建运行目录
    mkdir -p /var/run/fail2ban
    
    # 创建简化的配置文件
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    # 修复权限
    chmod 644 /etc/fail2ban/jail.local
    
    # 启动fail2ban
    systemctl daemon-reload
    systemctl enable fail2ban 2>/dev/null || true
    systemctl start fail2ban 2>/dev/null || true
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban 已成功启动"
    else
        log_warn "Fail2ban 启动失败，请手动检查: journalctl -u fail2ban"
    fi
}

# 配置系统优化
configure_system_optimization() {
    log_step "系统性能优化"
    
    # 创建优化配置文件
    cat > /etc/sysctl.d/99-optimization.conf << 'EOF'
# System Optimization Configuration

# Network optimization
net.core.default_qdisc = fq
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# Buffer optimization
net.core.rmem_default = 31457280
net.core.rmem_max = 134217728
net.core.wmem_default = 31457280
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# TCP optimization
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200

# File descriptors
fs.file-max = 2097152

# Memory optimization
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5

# Security settings
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
    
    # BBR配置（仅在支持时添加）
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        log_info "配置BBR拥塞控制..."
        
        # 加载BBR模块
        modprobe tcp_bbr 2>/dev/null || true
        
        # 添加BBR配置
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-optimization.conf
        
        # 确保模块开机加载
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    else
        log_warn "当前内核不支持BBR，使用默认拥塞控制"
        echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.d/99-optimization.conf
    fi
    
    # 应用配置
    sysctl -p /etc/sysctl.d/99-optimization.conf 2>/dev/null || log_warn "部分系统参数应用失败"
    
    # 验证BBR
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            log_info "BBR已成功启用"
        else
            log_warn "BBR可能需要重启后才能生效"
        fi
    fi
}

# 配置自动安全更新
configure_auto_updates() {
    log_step "配置自动安全更新"
    
    # 确保unattended-upgrades已安装
    if ! dpkg -l | grep -q "^ii.*unattended-upgrades"; then
        apt-get install -y unattended-upgrades apt-listchanges
    fi
    
    # 配置自动更新
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    # 启用自动更新
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    log_info "自动安全更新已启用"
}

# 创建登录信息
create_motd() {
    log_step "创建登录欢迎信息"
    
    local kernel_info=$(uname -r)
    local bbr_status="未启用"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        bbr_status="已启用"
    fi
    
    cat > /etc/motd << EOF
╔══════════════════════════════════════════════════════════╗
║          Debian Security Hardened Server                ║
╠══════════════════════════════════════════════════════════╣
║  系统信息:                                               ║
║  • 主机名称: $HOSTNAME
║  • 服务器IP: $SERVER_IP
║  • 内核版本: $kernel_info
║  • 管理用户: $ADMIN_USER
║  • SSH端口: $SSH_PORT
║  • BBR状态: $bbr_status
╠══════════════════════════════════════════════════════════╣
║  警告: 所有操作都会被记录和监控                          ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# 系统测试函数
test_configuration() {
    log_step "测试配置"
    
    # 测试主机名
    if hostname -f &>/dev/null; then
        log_info "✓ 主机名配置正常: $(hostname -f)"
    else
        log_warn "⚠ 主机名可能未正确配置"
    fi
    
    # 测试SSH
    if sshd -t &>/dev/null; then
        log_info "✓ SSH配置正常"
    else
        log_warn "⚠ SSH配置可能有问题"
    fi
    
    # 测试防火墙
    if ufw status | grep -q "Status: active"; then
        log_info "✓ 防火墙运行正常"
    else
        log_warn "⚠ 防火墙未启用"
    fi
    
    # 测试Fail2ban
    if systemctl is-active --quiet fail2ban; then
        log_info "✓ Fail2ban运行正常"
    else
        log_warn "⚠ Fail2ban未运行"
    fi
    
    # 测试sudo权限
    if sudo -l -U "$ADMIN_USER" &>/dev/null; then
        log_info "✓ Sudo权限配置正常"
    else
        log_warn "⚠ Sudo权限可能有问题"
    fi
}

# 显示完成信息
show_completion_info() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║              配置完成 - 重要信息保存                     ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}✅ 已完成的配置：${NC}"
    echo -e "  • 服务器名称: ${YELLOW}$HOSTNAME${NC}"
    echo -e "  • hosts文件已正确配置"
    echo -e "  • 完整系统更新"
    echo -e "  • 管理用户创建: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "  • SSH安全配置 (端口: ${YELLOW}$SSH_PORT${NC})"
    echo -e "  • 防火墙配置 (UFW)"
    echo -e "  • Fail2Ban防护"
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        echo -e "  • BBR网络优化"
    else
        echo -e "  • 网络优化（BBR需要新内核）"
    fi
    echo -e "  • 自动安全更新"
    
    echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}📝 重要信息（请保存）：${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "服务器域名: ${GREEN}$HOSTNAME${NC}"
    echo -e "服务器IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "SSH连接命令: ${GREEN}ssh -p $SSH_PORT $ADMIN_USER@$SERVER_IP${NC}"
    echo -e "管理员用户: ${GREEN}$ADMIN_USER${NC}"
    echo -e "SSH端口: ${GREEN}$SSH_PORT${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${RED}⚠️  重要提醒：${NC}"
        echo -e "  SSH端口已改为 ${YELLOW}$SSH_PORT${NC}"
        echo -e "  确认新端口可用后，删除临时22端口："
        echo -e "  ${BLUE}sudo ufw delete allow 22/tcp${NC}"
    fi
    
    echo -e "\n${GREEN}🔧 常用管理命令：${NC}"
    echo -e "  查看防火墙: ${BLUE}sudo ufw status${NC}"
    echo -e "  查看Fail2ban: ${BLUE}sudo fail2ban-client status${NC}"
    echo -e "  查看系统日志: ${BLUE}sudo journalctl -xe${NC}"
    echo -e "  测试BBR: ${BLUE}sudo sysctl net.ipv4.tcp_congestion_control${NC}"
    echo -e "  查看hosts: ${BLUE}cat /etc/hosts${NC}"
    
    echo -e "\n${YELLOW}📊 自动更新时间：${NC}"
    echo -e "  系统将在每天 6:00 和 18:00 自动检查更新"
    
    # 保存配置信息到文件
    cat > /root/server_info.txt << EOF
========================================
Debian Server Configuration Information
========================================
Date: $(date)
Hostname: $HOSTNAME
Short Name: $HOSTNAME_SHORT
Server IP: $SERVER_IP
Admin User: $ADMIN_USER
SSH Port: $SSH_PORT
Kernel: $(uname -r)
BBR Status: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")

SSH Connection:
ssh -p $SSH_PORT $ADMIN_USER@$SERVER_IP

Important: Root login is disabled!

/etc/hosts content:
$(cat /etc/hosts)
========================================
EOF
    
    log_info "配置信息已保存到: /root/server_info.txt"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║     Debian 12 Security Setup Script (Clean Version)     ║"
    echo -e "║            精简版 - 适用于新服务器快速配置               ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    # 基础检查
    check_root
    check_system
    
    # 用户输入
    get_user_input
    
    # 设置服务器名称（包括hosts文件）
    set_hostname
    
    # 执行配置
    full_system_update
    install_packages
    create_admin_user
    configure_ssh
    setup_firewall
    configure_fail2ban
    configure_system_optimization
    configure_auto_updates
    create_motd
    
    # 测试配置
    test_configuration
    
    # 显示完成信息
    show_completion_info
    
    # 重启提示
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}建议重启系统以使所有配置完全生效${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "是否现在重启？(Y/n): " -r
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "系统将在10秒后重启..."
        log_warn "请记住: SSH端口=$SSH_PORT, 用户=$ADMIN_USER"
        for i in {10..1}; do
            echo -n "$i... "
            sleep 1
        done
        echo ""
        reboot
    else
        log_info "请稍后手动重启: ${BLUE}sudo reboot${NC}"
        log_warn "重启前请确保记住SSH端口和用户信息！"
    fi
}

# 执行主函数
main "$@"
