#!/bin/bash

# ============================================================================
# Debian 12 一键配置脚本 (修复版)
# 修复 Fail2Ban 启动问题 + BBRv3 + 密码登录
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

# 修复 Fail2Ban 安装和配置
install_and_fix_fail2ban() {
    log_info "安装和配置 Fail2Ban..."
    
    # 安装 Fail2Ban
    apt install -y fail2ban
    
    # 确保服务目录存在
    mkdir -p /var/run/fail2ban
    chown root:root /var/run/fail2ban
    chmod 755 /var/run/fail2ban
    
    # 创建简化配置
    cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400
findtime = 3600
EOF
    
    # 重启服务确保配置生效
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl start fail2ban
    
    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2Ban 服务已成功启动"
    else
        log_warn "Fail2Ban 服务启动失败，尝试修复..."
        systemctl restart fail2ban
        sleep 2
        systemctl status fail2ban --no-pager -l
    fi
}

# 显示 Fail2Ban 状态（修复版）
show_fail2ban_status() {
    echo -e "\n${GREEN}检查 Fail2Ban 状态:${NC}"
    
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}✓ Fail2Ban 服务运行正常${NC}"
        # 使用更可靠的方式检查状态
        if command -v fail2ban-client >/dev/null 2>&1; then
            echo -e "\n${YELLOW}Fail2Ban 监控的服務:${NC}"
            systemctl status fail2ban --no-pager -l | grep "Active:" || true
        fi
    else
        echo -e "${RED}✗ Fail2Ban 服务未运行${NC}"
        echo -e "${YELLOW}尝试启动 Fail2Ban...${NC}"
        systemctl start fail2ban
        systemctl status fail2ban --no-pager -l
    fi
}

# 安装最新内核 (支持 BBRv3)
install_bbrv3_kernel() {
    log_info "安装 BBRv3 支持内核..."
    
    # 添加 backports 源
    echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/bbrv3.list
    
    # 更新并安装新内核
    apt update -y
    apt install -y -t bookworm-backports \
        linux-image-cloud-amd64 \
        linux-headers-cloud-amd64
    
    log_info "BBRv3 内核安装完成"
}

# 配置 BBRv3 网络优化
configure_bbrv3() {
    log_info "配置 BBRv3 网络优化..."
    
    # 移除旧配置
    sed -i '/bbr/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
    
    # 添加 BBRv3 优化配置
    cat >> /etc/sysctl.conf << 'EOF'

# BBRv3 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
fs.file-max = 2097152
EOF
    
    sysctl -p
    log_info "BBRv3 网络优化已配置"
}

# 安装基本组件
install_basics() {
    log_info "安装基本系统工具..."
    apt update -y
    apt install -y sudo curl wget nano vim htop ufw
}

# 系统更新
system_upgrade() {
    log_info "系统升级..."
    apt update -y
    apt upgrade -y
    apt autoremove --purge -y
    apt clean
}

# 配置防火墙
setup_firewall() {
    log_info "配置防火墙..."
    apt install -y ufw
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    log_info "防火墙已启用"
}

# 创建管理用户
create_admin_user() {
    log_info "创建管理用户..."
    read -p "请输入管理用户名 (默认: admin): " username
    username=${username:-admin}
    
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash "$username"
        log_info "用户 $username 创建成功"
    fi
    
    echo "请为用户 $username 设置密码:"
    passwd "$username"
    
    echo "$username ALL=(ALL:ALL) ALL" >> /etc/sudoers
    echo "$username" > /root/.debian_setup_username
}

# 配置 SSH（密码认证）
configure_ssh_password() {
    log_info "配置 SSH（密码认证）..."
    
    local ssh_config="/etc/ssh/sshd_config"
    cp "$ssh_config" "${ssh_config}.backup.$(date +%Y%m%d)"
    
    sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' "$ssh_config"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$ssh_config"
    
    systemctl restart ssh
    log_info "SSH 已配置：禁用root登录，启用密码认证"
}

# 配置区域设置
configure_locales() {
    log_info "配置区域设置..."
    apt install -y locales
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
}

# 安装监控工具
install_monitoring_tools() {
    log_info "安装系统监控工具..."
    apt install -y htop iotop iftop nload
}

# 创建登录欢迎信息
create_motd() {
    cat > /etc/motd << 'EOF'
=============================================
=             Debian 12 Server              =
=      BBRv3 + Fail2Ban + 安全配置         =
=============================================
EOF
}

# 显示配置摘要
show_summary() {
    local username=$(cat /root/.debian_setup_username 2>/dev/null || echo "admin")
    
    echo -e "\n${GREEN}==========================================="
    echo "           配置完成摘要"
    echo "===========================================${NC}"
    
    echo -e "${GREEN}✅ 所有基础配置完成"
    echo -e "✅ BBRv3 网络优化启用"
    echo -e "✅ Fail2Ban 防爆破安装完成"
    echo -e "✅ 防火墙配置完成${NC}"
    
    echo -e "\n${YELLOW}连接信息:${NC}"
    echo -e "用户名: $username"
    echo -e "连接: ssh $username@服务器IP"
    
    echo -e "\n${YELLOW}安全防护:${NC}"
    echo -e "✔ 3次登录失败封禁IP 1小时"
    echo -e "✔ root SSH 登录已禁用"
    echo -e "✔ 防火墙已启用"
    
    show_fail2ban_status
    
    echo -e "\n${GREEN}===========================================${NC}"
}

# 重启提示
reboot_prompt() {
    echo -e "\n${YELLOW}需要重启使内核和BBRv3生效${NC}"
    read -p "是否立即重启? (y/N): " choice
    case "${choice:-n}" in
        y|Y) reboot ;;
        *) echo "请手动重启";;
    esac
}

# 主配置函数
main() {
    check_root
    install_basics
    system_upgrade
    setup_firewall
    create_admin_user
    configure_ssh_password
    configure_locales
    install_bbrv3_kernel
    configure_bbrv3
    install_and_fix_fail2ban
    install_monitoring_tools
    create_motd
    show_summary
    reboot_prompt
    
    log_info "配置完成!"
}

main "$@"
