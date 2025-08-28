#!/bin/bash

# ============================================================================
# Debian 12 安全配置脚本 v3.0 (全面修复版)
# 修复：Fail2ban配置、BBR检测、PATH问题、首次全量更新
# ============================================================================

set -e

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
log_debug() { echo -e "${YELLOW}[DEBUG]${NC} $1"; }

# 全局变量
ADMIN_USER=""
SSH_PORT="22"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
KERNEL_VERSION=""
HAS_BBR_SUPPORT=false
FAIL2BAN_BACKEND="systemd"  # 默认使用systemd
LOG_PATH="/var/log/auth.log"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        log_info "使用命令: sudo bash $0"
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
        
        if [[ "$ID" != "debian" ]]; then
            log_warn "此脚本专为 Debian 系统设计"
            read -p "是否继续？(y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
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
        log_info "内核支持 BBR (需要 4.9+)"
    else
        HAS_BBR_SUPPORT=false
        log_warn "当前内核版本不支持 BBR，需要升级内核"
    fi
    
    # 检查系统日志类型
    if systemctl is-active --quiet systemd-journald; then
        FAIL2BAN_BACKEND="systemd"
        log_info "系统使用 systemd 日志"
    else
        FAIL2BAN_BACKEND="auto"
        if [ -f /var/log/auth.log ]; then
            LOG_PATH="/var/log/auth.log"
        elif [ -f /var/log/secure ]; then
            LOG_PATH="/var/log/secure"
        fi
        log_info "系统使用传统日志文件: $LOG_PATH"
    fi
}

# 创建备份目录
create_backup() {
    mkdir -p "$BACKUP_DIR"
    log_info "备份目录已创建: $BACKUP_DIR"
    
    # 备份重要配置文件
    [[ -f /etc/ssh/sshd_config ]] && cp -p /etc/ssh/sshd_config "$BACKUP_DIR/"
    [[ -f /etc/sudoers ]] && cp -p /etc/sudoers "$BACKUP_DIR/"
    [[ -f /etc/sysctl.conf ]] && cp -p /etc/sysctl.conf "$BACKUP_DIR/"
    [[ -f /etc/fail2ban/jail.local ]] && cp -p /etc/fail2ban/jail.local "$BACKUP_DIR/"
}

# 全量系统更新（新增）
full_system_update() {
    log_step "执行完整系统更新"
    
    log_info "更新软件包列表..."
    apt-get update -y
    
    log_info "升级所有已安装的软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    
    log_info "执行发行版升级..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
    
    log_info "清理不需要的软件包..."
    apt-get autoremove --purge -y
    apt-get autoclean -y
    
    log_info "系统更新完成"
}

# 获取用户输入
get_user_input() {
    log_step "配置信息收集"
    
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
                break
            fi
        else
            break
        fi
    done
    
    # 获取SSH端口
    read -p "请输入SSH端口 (默认22，建议修改如2222): " input_port
    if [[ -n "$input_port" ]] && [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
        SSH_PORT="$input_port"
    fi
    
    log_info "配置信息："
    log_info "  管理员用户: $ADMIN_USER"
    log_info "  SSH端口: $SSH_PORT"
    
    read -p "确认以上信息正确？(Y/n): " -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        get_user_input
    fi
}

# 安装基础软件包（改进版）
install_packages() {
    log_step "安装必要软件包"
    
    # 基础工具列表
    local packages=(
        "sudo"                  # sudo权限管理
        "curl"                  # 下载工具
        "wget"                  # 下载工具
        "nano"                  # 文本编辑器
        "vim"                   # 文本编辑器
        "htop"                  # 系统监控
        "net-tools"            # 网络工具
        "ufw"                  # 防火墙
        "fail2ban"             # 防暴力破解
        "unattended-upgrades"  # 自动安全更新
        "apt-transport-https"  # HTTPS支持
        "ca-certificates"      # 证书
        "gnupg"               # GPG密钥
        "lsb-release"         # 系统信息
        "software-properties-common"  # 软件源管理
        "rsyslog"             # 系统日志（确保auth.log存在）
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "安装 $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
        else
            log_debug "$pkg 已安装"
        fi
    done
    
    # 确保rsyslog运行（生成auth.log）
    if systemctl is-enabled rsyslog &>/dev/null; then
        systemctl restart rsyslog
        log_info "rsyslog 服务已重启"
    fi
}

# 安装新内核（如果需要BBR）
install_new_kernel() {
    if [ "$HAS_BBR_SUPPORT" = false ]; then
        log_step "安装支持BBR的新内核"
        
        log_info "添加 backports 源..."
        echo "deb http://deb.debian.org/debian $(lsb_release -cs)-backports main" > /etc/apt/sources.list.d/backports.list
        
        apt-get update -y
        
        log_info "安装新内核..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -t $(lsb_release -cs)-backports linux-image-amd64 linux-headers-amd64
        
        log_warn "新内核已安装，需要重启后生效"
        HAS_BBR_SUPPORT=true
    fi
}

# 创建管理用户（改进版）
create_admin_user() {
    log_step "配置管理用户: $ADMIN_USER"
    
    # 创建用户（如果不存在）
    if ! id "$ADMIN_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$ADMIN_USER"
        usermod -aG sudo "$ADMIN_USER" 2>/dev/null || true
        log_info "用户 $ADMIN_USER 创建成功"
    else
        log_info "使用现有用户 $ADMIN_USER"
    fi
    
    # 设置密码
    log_info "请设置 $ADMIN_USER 用户的密码："
    while ! passwd "$ADMIN_USER"; do
        log_error "密码设置失败，请重试"
    done
    
    # 配置sudo权限（安全方式）
    local sudoers_file="/etc/sudoers.d/90-$ADMIN_USER"
    cat > "$sudoers_file" << EOF
# Sudo permissions for $ADMIN_USER
# Created by security setup script on $(date)
$ADMIN_USER ALL=(ALL:ALL) ALL

# Optional: Allow specific commands without password
# $ADMIN_USER ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/bin/systemctl
EOF
    
    chmod 440 "$sudoers_file"
    
    # 验证sudoers配置
    if visudo -c -f "$sudoers_file" &>/dev/null; then
        log_info "sudo权限配置成功"
    else
        log_error "sudo配置有误，正在修复..."
        rm -f "$sudoers_file"
        # 使用备用方法
        echo "$ADMIN_USER ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo
    fi
}

# 配置SSH安全（改进版）
configure_ssh() {
    log_step "配置SSH安全设置"
    
    local ssh_config_d="/etc/ssh/sshd_config.d"
    mkdir -p "$ssh_config_d"
    
    # 创建自定义SSH配置
    cat > "$ssh_config_d/99-security.conf" << EOF
# Custom SSH Security Configuration
# Generated on $(date)
# Script Version: 3.0

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
Compression delayed

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
        log_error "SSH配置有误，恢复原配置"
        rm -f "$ssh_config_d/99-security.conf"
        exit 1
    fi
}

# 配置防火墙（改进版）
setup_firewall() {
    log_step "配置防火墙规则"
    
    # 检查ufw是否已安装
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw
    fi
    
    # 重置防火墙规则（可选）
    # ufw --force reset
    
    # 先添加SSH端口规则（防止锁定）
    ufw allow "$SSH_PORT/tcp" comment 'SSH'
    
    # 如果修改了默认SSH端口，临时保留22端口
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow 22/tcp comment 'SSH-Temp'
        log_warn "临时保留22端口，确认新端口 $SSH_PORT 可用后执行: sudo ufw delete allow 22/tcp"
    fi
    
    # 添加常用服务端口
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed
    
    # 防止日志溢出
    ufw logging on
    
    # 启用防火墙
    echo "y" | ufw enable
    
    if ufw status | grep -q "Status: active"; then
        log_info "防火墙已成功启用"
        ufw status numbered
    else
        log_error "防火墙启用失败"
    fi
}

# 配置Fail2Ban（完全重写）
configure_fail2ban() {
    log_step "配置Fail2Ban防护"
    
    # 确保fail2ban已安装
    if ! dpkg -l | grep -q "^ii.*fail2ban"; then
        apt-get install -y fail2ban
    fi
    
    # 停止服务以便配置
    systemctl stop fail2ban 2>/dev/null || true
    
    # 清理可能存在的错误socket文件
    rm -f /var/run/fail2ban/fail2ban.sock
    
    # 创建运行目录
    mkdir -p /var/run/fail2ban
    
    # 检测日志系统并设置backend
    local backend_config=""
    if [ "$FAIL2BAN_BACKEND" = "systemd" ]; then
        backend_config="backend = systemd"
    else
        backend_config="backend = auto"
    fi
    
    # 创建主配置文件
    cat > /etc/fail2ban/jail.local << EOF
# Fail2Ban configuration
# Generated on $(date)

[DEFAULT]
# Ban time (seconds)
bantime = 3600
# Time window for counting failures
findtime = 600
# Max retry attempts
maxretry = 3
# Backend for log monitoring
$backend_config
# Ignored IPs
ignoreip = 127.0.0.1/8 ::1

# SSH protection
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
bantime = 3600
findtime = 600

# Alternative SSH jail for systemd
[ssh-systemd]
enabled = true
port = $SSH_PORT
filter = sshd[mode=aggressive]
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    # 如果不是systemd，添加传统日志路径
    if [ "$FAIL2BAN_BACKEND" != "systemd" ]; then
        cat >> /etc/fail2ban/jail.local << EOF

# SSH with traditional logs
[ssh-auth]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $LOG_PATH
maxretry = 3
bantime = 3600
findtime = 600
EOF
    fi
    
    # 修复权限
    chmod 644 /etc/fail2ban/jail.local
    
    # 创建必要的日志文件（如果不存在）
    touch /var/log/auth.log 2>/dev/null || true
    
    # 启动fail2ban
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl start fail2ban
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban 已成功启动"
        
        # 尝试获取状态
        if fail2ban-client ping &>/dev/null; then
            log_info "Fail2ban 响应正常"
            fail2ban-client status | grep "Jail list" || true
        else
            log_warn "Fail2ban 启动但响应异常，检查日志: journalctl -u fail2ban"
        fi
    else
        log_error "Fail2ban 启动失败，查看日志: journalctl -u fail2ban -n 50"
        log_warn "系统将继续配置，但Fail2ban可能需要手动修复"
    fi
}

# 配置系统优化（修复BBR）
configure_system_optimization() {
    log_step "系统性能优化"
    
    # 备份原配置
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
    
    # 创建优化配置文件
    cat > /etc/sysctl.d/99-optimization.conf << 'EOF'
# System Optimization Configuration
# Generated by security script v3.0

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
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 30

# File descriptors
fs.file-max = 2097152
fs.nr_open = 1048576

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
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
EOF
    
    # BBR配置（仅在支持时添加）
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        log_info "配置BBR拥塞控制..."
        
        # 加载BBR模块
        modprobe tcp_bbr 2>/dev/null || true
        
        # 添加BBR配置
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-optimization.conf
        
        # 确保模块开机加载
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
    else
        log_warn "当前内核不支持BBR，使用默认拥塞控制"
        echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.d/99-optimization.conf
    fi
    
    # 应用配置
    sysctl -p /etc/sysctl.d/99-optimization.conf 2>/dev/null || true
    
    # 验证配置
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            log_info "BBR已成功启用"
        else
            log_warn "BBR配置已添加，重启后生效"
        fi
    fi
    
    # 显示当前拥塞控制算法
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    log_info "当前拥塞控制算法: $current_cc"
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
// Automatically upgrade packages from these origins
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Package blacklist
Unattended-Upgrade::Package-Blacklist {
};

// Auto fix interrupted dpkg
Unattended-Upgrade::AutoFixInterruptedDpkg "true";

// Minimal steps
Unattended-Upgrade::MinimalSteps "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Automatic reboot
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Email notifications (configure if needed)
//Unattended-Upgrade::Mail "admin@example.com";
//Unattended-Upgrade::MailReport "on-change";
EOF
    
    # 启用自动更新
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    # 配置更新时间（通过systemd timer）
    if systemctl list-timers apt-daily.timer &>/dev/null; then
        log_info "自动更新计时器已配置"
        systemctl list-timers apt-daily*
    fi
    
    log_info "自动安全更新已启用"
}

# 创建登录信息
create_motd() {
    log_step "创建登录欢迎信息"
    
    # 获取系统信息
    local kernel_info=$(uname -r)
    local bbr_status="未启用"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        bbr_status="已启用"
    fi
    
    cat > /etc/motd << EOF
╔══════════════════════════════════════════════════════════╗
║          Debian Security Hardened Server v3.0           ║
╠══════════════════════════════════════════════════════════╣
║  系统信息:                                               ║
║  • 内核版本: $kernel_info
║  • 管理用户: $ADMIN_USER
║  • SSH端口: $SSH_PORT
║                                                          ║
║  安全防护:                                               ║
║  • 防火墙: UFW (已启用)                                  ║
║  • Fail2Ban: 3次失败封禁1小时                           ║
║  • BBR状态: $bbr_status
║  • 自动更新: 每日检查安全补丁                           ║
║                                                          ║
║  备份位置: $BACKUP_DIR
╠══════════════════════════════════════════════════════════╣
║  警告: 所有操作都会被记录和监控                          ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# 系统测试函数
test_configuration() {
    log_step "测试配置"
    
    local test_passed=true
    
    # 测试SSH
    if sshd -t &>/dev/null; then
        log_info "✓ SSH配置正常"
    else
        log_error "✗ SSH配置错误"
        test_passed=false
    fi
    
    # 测试防火墙
    if ufw status | grep -q "Status: active"; then
        log_info "✓ 防火墙运行正常"
    else
        log_error "✗ 防火墙未启用"
        test_passed=false
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
        log_error "✗ Sudo权限配置错误"
        test_passed=false
    fi
    
    if [ "$test_passed" = true ]; then
        log_info "所有关键配置测试通过"
    else
        log_warn "部分配置可能需要手动检查"
    fi
}

# 显示完成信息
show_completion_info() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║              配置完成 - 重要信息保存                     ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}✅ 已完成的配置：${NC}"
    echo -e "  • 完整系统更新"
    echo -e "  • 管理用户创建: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "  • SSH安全配置 (端口: ${YELLOW}$SSH_PORT${NC})"
    echo -e "  • 防火墙配置 (UFW)"
    echo -e "  • Fail2Ban防护"
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        echo -e "  • BBR网络优化"
    else
        echo -e "  • 网络优化（BBR需要重启后生效）"
    fi
    echo -e "  • 自动安全更新"
    
    echo -e "\n${YELLOW}📝 重要信息（请保存）：${NC}"
    echo -e "┌────────────────────────────────────────┐"
    echo -e "│ SSH连接信息:                          │"
    echo -e "│ 命令: ${BLUE}ssh -p $SSH_PORT $ADMIN_USER@服务器IP${NC}"
    echo -e "│ 用户: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "│ 端口: ${YELLOW}$SSH_PORT${NC}"
    echo -e "│ 备份: ${YELLOW}$BACKUP_DIR${NC}"
    echo -e "└────────────────────────────────────────┘"
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${RED}⚠️  重要提醒：${NC}"
        echo -e "  SSH端口已改为 ${YELLOW}$SSH_PORT${NC}"
        echo -e "  确认新端口可用后，删除临时22端口："
        echo -e "  ${BLUE}sudo ufw delete allow 22/tcp${NC}"
    fi
    
    echo -e "\n${GREEN}🔧 常用管理命令：${NC}"
    echo -e "  查看防火墙: ${BLUE}sudo ufw status${NC}"
    echo -e "  查看Fail2ban: ${BLUE}sudo fail2ban-client status sshd${NC}"
    echo -e "  查看封禁IP: ${BLUE}sudo fail2ban-client status sshd${NC}"
    echo -e "  解封IP: ${BLUE}sudo fail2ban-client unban <IP>${NC}"
    echo -e "  查看系统日志: ${BLUE}sudo journalctl -xe${NC}"
    echo -e "  测试BBR: ${BLUE}sysctl net.ipv4.tcp_congestion_control${NC}"
    
    echo -e "\n${YELLOW}📊 自动更新时间：${NC}"
    echo -e "  系统将在每天 6:00 和 18:00 自动检查更新"
    echo -e "  查看计时器: ${BLUE}systemctl list-timers apt-daily*${NC}"
    
    # 保存配置信息到文件
    cat > "$BACKUP_DIR/setup_info.txt" << EOF
Debian Security Setup Information
Date: $(date)
Admin User: $ADMIN_USER
SSH Port: $SSH_PORT
Backup Location: $BACKUP_DIR
Kernel: $(uname -r)
BBR Status: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
EOF
    
    log_info "配置信息已保存到: $BACKUP_DIR/setup_info.txt"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║     Debian 12 Security Hardening Script v3.0            ║"
    echo -e "║     完整修复版 - 包含所有补丁和优化                      ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    # 基础检查
    check_root
    check_system
    
    # 用户输入
    get_user_input
    
    # 创建备份
    create_backup
    
    # 执行完整系统更新（新增）
    full_system_update
    
    # 安装软件包
    install_packages
    
    # 安装新内核（如果需要）
    if [ "$HAS_BBR_SUPPORT" = false ]; then
        read -p "是否安装新内核以支持BBR？(Y/n): " -r
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            install_new_kernel
        fi
    fi
    
    # 配置系统
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

# 错误处理
trap 'log_error "脚本执行出错，请检查 $BACKUP_DIR 的备份文件"; exit 1' ERR

# 执行主函数
main "$@"
