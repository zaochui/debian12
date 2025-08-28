#!/bin/bash

# ============================================================================
# Debian 12 安全配置脚本 (简化改进版)
# 功能：自定义用户、密码认证、Fail2Ban、BBR、安全SSH配置
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[步骤]${NC} $1\n"; }

# 全局变量
ADMIN_USER=""
SSH_PORT="22"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        log_info "使用命令: sudo bash $0"
        exit 1
    fi
}

# 检查系统版本
check_system() {
    if ! grep -q "debian" /etc/os-release; then
        log_warn "此脚本专为 Debian 系统设计"
        read -p "是否继续？(y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 创建备份目录
create_backup() {
    mkdir -p "$BACKUP_DIR"
    log_info "备份目录已创建: $BACKUP_DIR"
    
    # 备份重要配置文件
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$BACKUP_DIR/"
    [[ -f /etc/sudoers ]] && cp /etc/sudoers "$BACKUP_DIR/"
    [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "$BACKUP_DIR/"
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
    read -p "请输入SSH端口 (默认22，建议修改): " input_port
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

# 安装基础软件包
install_packages() {
    log_step "安装必要软件包"
    
    # 更新软件源
    apt update -y
    
    # 安装基础工具
    local packages=(
        "sudo"          # sudo权限管理
        "curl"          # 下载工具
        "wget"          # 下载工具
        "nano"          # 文本编辑器
        "vim"           # 文本编辑器
        "htop"          # 系统监控
        "net-tools"     # 网络工具
        "ufw"           # 防火墙
        "fail2ban"      # 防暴力破解
        "unattended-upgrades"  # 自动安全更新
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "安装 $pkg..."
            apt install -y "$pkg"
        else
            log_info "$pkg 已安装"
        fi
    done
}

# 创建管理用户
create_admin_user() {
    log_step "配置管理用户: $ADMIN_USER"
    
    # 创建用户（如果不存在）
    if ! id "$ADMIN_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$ADMIN_USER"
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
$ADMIN_USER ALL=(ALL:ALL) ALL

# Optional: 免密码sudo（取消注释启用）
# $ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    
    chmod 440 "$sudoers_file"
    
    # 验证sudoers配置
    if visudo -c -f "$sudoers_file" &>/dev/null; then
        log_info "sudo权限配置成功"
    else
        log_error "sudo配置有误，请检查"
        rm "$sudoers_file"
        exit 1
    fi
}

# 配置SSH安全
configure_ssh() {
    log_step "配置SSH安全设置"
    
    local ssh_config="/etc/ssh/sshd_config"
    local ssh_config_d="/etc/ssh/sshd_config.d"
    
    # 创建配置目录
    mkdir -p "$ssh_config_d"
    
    # 创建自定义SSH配置
    cat > "$ssh_config_d/99-security.conf" << EOF
# 自定义SSH安全配置
# 生成时间: $(date)

# 端口配置
Port $SSH_PORT

# 认证设置
PasswordAuthentication yes         # 允许密码登录
PubkeyAuthentication yes          # 允许密钥登录
PermitRootLogin no                 # 禁止root直接登录
ChallengeResponseAuthentication no # 禁用挑战响应

# 用户限制 - 只允许指定用户登录
AllowUsers $ADMIN_USER

# 安全限制
MaxAuthTries 3                     # 最大尝试次数
MaxSessions 5                      # 最大会话数
ClientAliveInterval 300            # 5分钟发送心跳
ClientAliveCountMax 2              # 2次心跳无响应断开
LoginGraceTime 60                  # 登录超时时间

# 其他安全设置
X11Forwarding no                   # 禁用X11转发
PrintMotd yes                      # 显示欢迎信息
PrintLastLog yes                  # 显示最后登录信息
TCPKeepAlive yes                  # TCP保活
UseDNS no                         # 禁用DNS反查（提高连接速度）

# 日志
LogLevel VERBOSE                   # 详细日志级别
EOF
    
    # 测试SSH配置
    if sshd -t -f "$ssh_config" &>/dev/null; then
        log_info "SSH配置测试通过"
        systemctl restart ssh
        log_info "SSH服务已重启"
    else
        log_error "SSH配置有误，保持原配置"
        rm "$ssh_config_d/99-security.conf"
        exit 1
    fi
    
    # 提醒当前SSH连接信息
    log_warn "SSH端口已改为: $SSH_PORT"
    log_warn "请确保防火墙已开放此端口"
}

# 配置防火墙
setup_firewall() {
    log_step "配置防火墙规则"
    
    # 先添加SSH端口规则（防止锁定）
    ufw allow "$SSH_PORT/tcp" comment 'SSH'
    
    # 如果修改了默认SSH端口，也临时保留22端口
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow 22/tcp comment 'SSH-Temp'
        log_warn "临时保留22端口，确认新端口可用后请执行: ufw delete allow 22/tcp"
    fi
    
    # 添加常用服务端口
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 启用防火墙
    if ufw --force enable; then
        log_info "防火墙已启用"
        ufw status numbered
    else
        log_error "防火墙启用失败"
    fi
}

# 配置Fail2Ban
configure_fail2ban() {
    log_step "配置Fail2Ban防护"
    
    # 创建本地配置
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# 默认禁止时间（秒）
bantime = 3600
# 查找时间窗口
findtime = 600
# 最大重试次数
maxretry = 3
# 忽略的IP（添加你信任的IP）
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

# SSH慢速攻击防护
[sshd-slow]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400
findtime = 3600

# 防止SSH DDoS
[sshd-ddos]
enabled = true
port = $SSH_PORT
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 10
bantime = 86400
findtime = 60
EOF
    
    # 创建DDoS过滤器
    cat > /etc/fail2ban/filter.d/sshd-ddos.conf << 'EOF'
[Definition]
failregex = ^.*sshd\[.*\]: (Connection closed by|Received disconnect from) <HOST>.*$
            ^.*sshd\[.*\]: (Did not receive identification string from) <HOST>.*$
ignoreregex =
EOF
    
    # 重启Fail2ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban 已启用并运行"
        fail2ban-client status
    else
        log_error "Fail2ban 启动失败"
    fi
}

# 配置系统优化
configure_system_optimization() {
    log_step "系统性能优化"
    
    # 备份原配置
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
    
    # 清理旧配置
    sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    
    # 添加优化配置
    cat >> /locals.conf << 'EOF'

# ===== 系统优化配置 =====
# 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# 连接数优化
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# 缓冲区优化
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728

# 文件描述符
fs.file-max = 2097152

# 内存优化
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5

# 安全相关
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
EOF
    
    # 应用配置
    sysctl -p
    
    # 检查BBR是否启用
    if lsmod | grep -q tcp_bbr; then
        log_info "BBR 已成功启用"
    else
        log_warn "BBR 模块未加载，可能需要更新内核或重启"
    fi
}

# 配置自动安全更新
configure_auto_updates() {
    log_step "配置自动安全更新"
    
    # 配置自动更新
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
    
    # 启用自动更新
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    log_info "自动安全更新已配置"
}

# 创建登录信息
create_motd() {
    log_step "创建登录欢迎信息"
    
    cat > /etc/motd << EOF
╔══════════════════════════════════════════════════════════╗
║              Debian 安全服务器 - 已加固                   ║
╠══════════════════════════════════════════════════════════╣
║  系统信息:                                               ║
║  - 管理员用户: $ADMIN_USER                              ║
║  - SSH 端口: $SSH_PORT                                  ║
║  - 防火墙: 已启用 (UFW)                                 ║
║  - Fail2Ban: 已启用 (3次失败封禁1小时)                  ║
║  - BBR: 已启用 (网络加速)                               ║
║  - 自动更新: 已启用 (安全补丁)                          ║
╠══════════════════════════════════════════════════════════╣
║  安全提醒:                                               ║
║  • 所有操作都会被记录                                   ║
║  • 请遵守安全规范                                       ║
║  • 定期检查系统日志                                     ║
║  • 备份目录: $BACKUP_DIR                                ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# 显示完成信息
show_completion_info() {
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║                    配置完成                              ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}✅ 已完成的配置：${NC}"
    echo -e "  • 管理用户创建: ${YELLOW}$ADMIN_USER${NC}"
    echo -e "  • SSH安全配置 (端口: ${YELLOW}$SSH_PORT${NC})"
    echo -e "  • 防火墙配置 (UFW)"
    echo -e "  • Fail2Ban防护"
    echo -e "  • BBR网络优化"
    echo -e "  • 自动安全更新"
    
    echo -e "\n${YELLOW}⚠️  重要信息：${NC}"
    echo -e "  1. SSH连接命令: ${BLUE}ssh -p $SSH_PORT $ADMIN_USER@服务器IP${NC}"
    echo -e "  2. Root登录已禁用，请使用 ${YELLOW}$ADMIN_USER${NC} 登录"
    echo -e "  3. 需要root权限时使用: ${BLUE}sudo 命令${NC}"
    echo -e "  4. 配置备份位置: ${YELLOW}$BACKUP_DIR${NC}"
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${RED}⚠️  端口变更提醒：${NC}"
        echo -e "  SSH端口已改为 ${YELLOW}$SSH_PORT${NC}"
        echo -e "  确认新端口可用后，执行: ${BLUE}sudo ufw delete allow 22/tcp${NC}"
    fi
    
    echo -e "\n${GREEN}📋 常用命令：${NC}"
    echo -e "  查看防火墙状态: ${BLUE}sudo ufw status${NC}"
    echo -e "  查看Fail2ban状态: ${BLUE}sudo fail2ban-client status${NC}"
    echo -e "  查看被封禁的IP: ${BLUE}sudo fail2ban-client status sshd${NC}"
    echo -e "  解封IP: ${BLUE}sudo fail2ban-client unban IP地址${NC}"
    echo -e "  查看系统日志: ${BLUE}sudo journalctl -xe${NC}"
    
    echo -e "\n${YELLOW}建议重启系统使所有配置生效${NC}"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║        Debian 12 服务器安全配置脚本 v2.0                ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    # 执行检查
    check_root
    check_system
    
    # 获取用户输入
    get_user_input
    
    # 创建备份
    create_backup
    
    # 执行配置
    install_packages
    create_admin_user
    configure_ssh
    setup_firewall
    configure_fail2ban
    configure_system_optimization
    configure_auto_updates
    create_motd
    
    # 显示完成信息
    show_completion_info
    
    # 询问是否重启
    echo -e "\n${YELLOW}是否现在重启系统？(推荐)${NC}"
    read -p "(Y/n): " -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "系统将在10秒后重启..."
        log_warn "请记住: SSH端口 $SSH_PORT, 用户名 $ADMIN_USER"
        sleep 10
        reboot
    else
        log_info "请稍后手动重启: ${BLUE}sudo reboot${NC}"
    fi
}

# 执行主函数
main "$@"
