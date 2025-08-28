#!/bin/bash

# ============================================================================
# Debian 12 安全配置脚本 - 精简版（仅使用root账号）
# 适用于需要保持root访问的服务器安全配置
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
SSH_PORT="22"
KERNEL_VERSION=""
HAS_BBR_SUPPORT=false
SERVER_IP=""
ROOT_PASS=""

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
    
    # 获取root新密码
    while true; do
        echo -e "${YELLOW}请设置root用户的新密码（增强安全性）:${NC}"
        read -s -p "输入密码: " ROOT_PASS
        echo
        read -s -p "确认密码: " ROOT_PASS_CONFIRM
        echo
        
        if [[ -z "$ROOT_PASS" ]]; then
            log_warn "密码为空，跳过密码修改"
            break
        elif [[ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]]; then
            log_error "两次输入的密码不一致，请重新输入"
        elif [[ ${#ROOT_PASS} -lt 8 ]]; then
            log_error "密码长度至少需要8个字符"
        else
            log_info "密码设置成功"
            break
        fi
    done
    
    # 获取SSH端口
    read -p "请输入SSH端口 (当前: 22，建议修改如 2222): " input_port
    if [[ -n "$input_port" ]] && [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
        SSH_PORT="$input_port"
    fi
    
    echo -e "\n${GREEN}配置信息确认：${NC}"
    echo -e "  服务器IP: ${YELLOW}$SERVER_IP${NC}"
    echo -e "  SSH端口: ${YELLOW}$SSH_PORT${NC}"
    echo -e "  root密码: ${YELLOW}$([ -n "$ROOT_PASS" ] && echo "将更新" || echo "保持不变")${NC}"
    
    read -p "确认以上信息正确？(Y/n): " -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        get_user_input
    fi
}

# 更新root密码
update_root_password() {
    if [ -n "$ROOT_PASS" ]; then
        log_step "更新root密码"
        echo "root:$ROOT_PASS" | chpasswd
        if [ $? -eq 0 ]; then
            log_info "root密码更新成功"
        else
            log_error "密码更新失败"
        fi
    fi
}

# 全量系统更新
full_system_update() {
    log_step "执行系统更新"
    
    log_info "更新软件包列表..."
    apt-get update -y || log_warn "更新软件源时出现警告"
    
    log_info "升级已安装的软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || log_warn "升级软件包时出现警告"
    
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
        "curl"
        "wget"
        "htop"
        "net-tools"
        "ufw"
        "fail2ban"
        "unattended-upgrades"
        "rsyslog"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "安装 $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || log_warn "$pkg 安装失败，继续..."
        fi
    done
    
    log_info "软件包安装完成"
}

# 配置SSH安全
configure_ssh() {
    log_step "配置SSH安全设置"
    
    # 备份原始配置
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)
    
    local ssh_config_d="/etc/ssh/sshd_config.d"
    mkdir -p "$ssh_config_d"
    
    # 创建自定义SSH配置（允许root但增强安全性）
    cat > "$ssh_config_d/99-security.conf" << EOF
# Custom SSH Security Configuration
# Generated on $(date)

# Port configuration
Port $SSH_PORT

# Authentication settings
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes
ChallengeResponseAuthentication no
UsePAM yes

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
        log_error "SSH配置有误，恢复原配置"
        rm -f "$ssh_config_d/99-security.conf"
        cp /etc/ssh/sshd_config.backup.$(date +%Y%m%d) /etc/ssh/sshd_config
    fi
}

# 配置防火墙
setup_firewall() {
    log_step "配置防火墙规则"
    
    # 检查ufw是否已安装
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw
    fi
    
    # 重置防火墙规则
    ufw --force reset
    
    # 先添加SSH端口规则（防止锁定）
    ufw allow "$SSH_PORT/tcp" comment 'SSH' 2>/dev/null || log_warn "SSH端口规则添加失败"
    
    # 如果修改了默认SSH端口，临时保留22端口
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow 22/tcp comment 'SSH-Temp' 2>/dev/null || true
        log_warn "临时保留22端口10分钟，确认新端口可用后自动删除"
        # 创建定时任务10分钟后删除22端口
        echo "ufw delete allow 22/tcp 2>/dev/null" | at now + 10 minutes 2>/dev/null || true
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
    
    # 停止服务
    systemctl stop fail2ban 2>/dev/null || true
    
    # 创建配置文件
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
maxretry = 5
bantime = 3600
findtime = 600
EOF
    
    # 启动fail2ban
    systemctl daemon-reload
    systemctl enable fail2ban 2>/dev/null || true
    systemctl start fail2ban 2>/dev/null || true
    
    sleep 2
    
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban 已成功启动"
    else
        log_warn "Fail2ban 启动失败，请手动检查"
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

# TCP optimization
net.ipv4.tcp_fastopen = 3
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
        modprobe tcp_bbr 2>/dev/null || true
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-optimization.conf
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    else
        log_warn "当前内核不支持BBR，使用默认拥塞控制"
    fi
    
    # 应用配置
    sysctl -p /etc/sysctl.d/99-optimization.conf 2>/dev/null || log_warn "部分系统参数应用失败"
    
    # 验证BBR
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            log_info "BBR已成功启用"
        fi
    fi
}

# 配置自动安全更新
configure_auto_updates() {
    log_step "配置自动安全更新"
    
    # 确保unattended-upgrades已安装
    if ! dpkg -l | grep -q "^ii.*unattended-upgrades"; then
        apt-get install -y unattended-upgrades
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

# 创建恢复脚本
create_recovery_script() {
    log_step "创建紧急恢复脚本"
    
    cat > /root/emergency_recovery.sh << 'EOF'
#!/bin/bash
# 紧急恢复脚本 - 恢复SSH访问

echo "开始紧急恢复..."

# 停止防火墙
ufw disable
systemctl stop fail2ban

# 恢复SSH默认配置
rm -f /etc/ssh/sshd_config.d/99-security.conf
cat > /etc/ssh/sshd_config.d/01-recovery.conf << EOL
Port 22
Port 597
Port 2222
PermitRootLogin yes
PasswordAuthentication yes
EOL

# 重启SSH
systemctl restart ssh
systemctl restart sshd

echo "恢复完成！现在可以通过端口 22, 597, 2222 连接"
EOF
    
    chmod +x /root/emergency_recovery.sh
    log_info "紧急恢复脚本已创建: /root/emergency_recovery.sh"
}

# 系统测试函数
test_configuration() {
    log_step "测试配置"
    
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
    
    # 测试BBR
    if [ "$HAS_BBR_SUPPORT" = true ]; then
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            log_info "✓ BBR已启用"
        fi
    fi
}

# 显示完成信息
show_completion_info() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║              配置完成 - 重要信息保存                     ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}✅ 已完成的配置：${NC}"
    echo -e "  • 系统更新"
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
    echo -e "服务器IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "SSH连接命令: ${GREEN}ssh -p $SSH_PORT root@$SERVER_IP${NC}"
    echo -e "SSH端口: ${GREEN}$SSH_PORT${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${RED}⚠️  重要提醒：${NC}"
        echo -e "  SSH端口已改为 ${YELLOW}$SSH_PORT${NC}"
        echo -e "  临时保留22端口10分钟，请立即测试新端口连接"
        echo -e "  10分钟后22端口将自动关闭"
    fi
    
    echo -e "\n${GREEN}🔧 常用管理命令：${NC}"
    echo -e "  查看防火墙: ${BLUE}ufw status${NC}"
    echo -e "  查看Fail2ban: ${BLUE}fail2ban-client status${NC}"
    echo -e "  查看系统日志: ${BLUE}journalctl -xe${NC}"
    echo -e "  紧急恢复: ${BLUE}/root/emergency_recovery.sh${NC}"
    
    # 保存配置信息到文件
    cat > /root/server_info.txt << EOF
========================================
服务器安全配置信息
========================================
配置时间: $(date)
服务器IP: $SERVER_IP
SSH端口: $SSH_PORT
内核版本: $(uname -r)
BBR状态: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")

SSH连接命令:
ssh -p $SSH_PORT root@$SERVER_IP

紧急恢复脚本:
/root/emergency_recovery.sh
========================================
EOF
    
    log_info "配置信息已保存到: /root/server_info.txt"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║        Debian 12 安全配置脚本 - Root版本                ║"
    echo -e "║            保持root访问 + 安全加固                       ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    # 基础检查
    check_root
    check_system
    
    # 用户输入
    get_user_input
    
    # 更新root密码
    update_root_password
    
    # 执行配置
    full_system_update
    install_packages
    configure_ssh
    setup_firewall
    configure_fail2ban
    configure_system_optimization
    configure_auto_updates
    create_recovery_script
    
    # 测试配置
    test_configuration
    
    # 显示完成信息
    show_completion_info
    
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}配置已完成！${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${RED}⚠️  重要：请立即开启新的SSH连接测试端口 $SSH_PORT${NC}"
        echo -e "${RED}    测试成功后再关闭当前连接${NC}"
    fi
    
    echo -e "\n${BLUE}提示：如遇连接问题，可通过VPS控制台执行恢复脚本：${NC}"
    echo -e "${YELLOW}/root/emergency_recovery.sh${NC}"
}

# 执行主函数
main "$@"
