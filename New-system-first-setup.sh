#!/bin/bash

# ============================================================================
# Debian 12 一键配置脚本 (BBRv3 + Fail2Ban防爆破 + 密码登录)
# 使用方法: 
#   apt-get update && apt-get install -y curl && bash <(curl -sSL https://raw.githubusercontent.com/zaochui/debian12/main/New-system-first-setup.sh)
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

# 安装最新内核 (支持 BBRv3)
install_bbrv3_kernel() {
    log_info "安装 BBRv3 支持内核..."
    
    # 检查当前内核版本
    local current_kernel=$(uname -r)
    log_info "当前内核版本: $current_kernel"
    
    # 添加 backports 源
    echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/bbrv3.list
    
    # 更新并安装新内核
    apt update -y
    apt install -y -t bookworm-backports \
        linux-image-cloud-amd64 \
        linux-headers-cloud-amd64
    
    log_info "BBRv3 内核安装完成，需要重启生效"
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

# ============================================================================
# BBRv3 网络性能优化
# ============================================================================
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区优化
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728

# TCP 连接优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300

# 连接队列优化
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_max_syn_backlog = 65536
net.core.somaxconn = 65536

# 内存优化
vm.swappiness = 10
vm.vfs_cache_pressure = 50
fs.file-max = 2097152
EOF
    
    sysctl -p
    log_info "BBRv3 网络优化已配置"
}

# 安装和配置 Fail2Ban (防暴力破解)
install_fail2ban() {
    log_info "安装和配置 Fail2Ban..."
    
    apt install -y fail2ban
    
    # 创建自定义配置
    cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
ignoreip = 127.0.0.1/8

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 5
bantime = 86400
findtime = 3600

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
bantime = 604800
findtime = 86400
maxretry = 3
EOF
    
    # 启动服务
    systemctl enable fail2ban
    systemctl start fail2ban
    
    log_info "Fail2Ban 已安装并配置完成"
}

# 显示 Fail2Ban 状态
show_fail2ban_status() {
    echo -e "\n${GREEN}Fail2Ban 状态:${NC}"
    fail2ban-client status sshd
    echo -e "\n${YELLOW}当前被禁IP:${NC}"
    fail2ban-client status sshd | grep -A 10 "Banned IP list"
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
    
    # 重置防火墙规则
    ufw --force reset
    
    # 允许基本端口
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # 默认拒绝所有入站，允许所有出站
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
    
    if id "$username" &>/dev/null; then
        log_warn "用户 $username 已存在"
    else
        useradd -m -s /bin/bash "$username"
        log_info "用户 $username 创建成功"
    fi
    
    # 设置用户密码
    echo "请为用户 $username 设置密码:"
    passwd "$username"
    
    # 添加 sudo 权限
    if ! grep -q "^$username" /etc/sudoers; then
        echo "$username ALL=(ALL:ALL) ALL" >> /etc/sudoers
        log_info "已为用户 $username 添加 sudo 权限"
    fi
    
    echo "$username" > /root/.debian_setup_username
}

# 配置 SSH（只使用密码认证）
configure_ssh_password() {
    log_info "配置 SSH（密码认证）..."
    
    local ssh_config="/etc/ssh/sshd_config"
    local backup_file="$ssh_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 备份原配置
    cp "$ssh_config" "$backup_file"
    log_info "SSH 配置已备份到: $backup_file"
    
    # 安全配置选项（只禁用root登录，保留密码认证）
    sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' "$ssh_config"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$ssh_config"
    sed -i 's/#ChallengeResponseAuthentication no/ChallengeResponseAuthentication no/' "$ssh_config"
    
    # 添加一些安全设置
    echo "MaxAuthTries 3" >> "$ssh_config"
    echo "ClientAliveInterval 300" >> "$ssh_config"
    echo "ClientAliveCountMax 2" >> "$ssh_config"
    
    systemctl restart ssh
    log_info "SSH 已配置：禁用root登录，启用密码认证"
}

# 配置区域设置
configure_locales() {
    log_info "配置区域设置..."
    apt install -y locales
    
    # 生成 en_US.UTF-8
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    
    # 设置默认语言
    update-locale LANG=en_US.UTF-8
    log_info "区域设置完成"
}

# 安装监控工具
install_monitoring_tools() {
    log_info "安装系统监控工具..."
    apt install -y htop iotop iftop nload
    log_info "监控工具安装完成"
}

# 创建登录欢迎信息
create_motd() {
    log_info "配置登录欢迎信息..."
    cat > /etc/motd << 'EOF'
=============================================
=             Debian 12 Server              =
=      BBRv3 + Fail2Ban + 安全配置         =
=============================================
已启用:
- BBRv3 网络加速
- Fail2Ban 防暴力破解
- 防火墙保护
- SSH 安全配置
=============================================
EOF
}

# 显示配置摘要
show_summary() {
    local username=$(get_username)
    
    echo -e "\n${GREEN}==========================================="
    echo "           配置完成摘要"
    echo "===========================================${NC}"
    
    echo -e "${GREEN}✅ 系统基础工具安装完成"
    echo -e "✅ 系统更新完成"
    echo -e "✅ 防火墙配置完成"
    echo -e "✅ 管理用户创建完成"
    echo -e "✅ SSH 安全配置完成"
    echo -e "✅ 区域设置完成"
    echo -e "✅ BBRv3 网络优化启用"
    echo -e "✅ Fail2Ban 防爆破已安装"
    echo -e "✅ 监控工具安装完成${NC}"
    
    echo -e "\n${YELLOW}SSH 连接信息:${NC}"
    echo -e "用户名: $username"
    echo -e "连接命令: ssh $username@你的服务器IP"
    echo -e "认证方式: 密码认证"
    
    echo -e "\n${YELLOW}安全防护:${NC}"
    echo -e "✔ Fail2Ban 已启用: 3次失败登录禁止1小时"
    echo -e "✔ 防火墙已启用: 开放 22,80,443 端口"
    echo -e "✔ root SSH 登录已禁用"
    echo -e "✔ BBRv3 网络加速已启用"
    
    # 显示 Fail2Ban 状态
    show_fail2ban_status
    
    echo -e "\n${RED}重要提示:${NC}"
    echo -e "1. 请使用创建的用户名和密码登录"
    echo -e "2. 连续3次密码错误将被封禁IP 1小时"
    echo -e "3. 建议定期更改密码"
    echo -e "4. 重启后所有配置生效"

    echo -e "\n${GREEN}===========================================${NC}"
}

# 获取用户名
get_username() {
    if [[ -f "/root/.debian_setup_username" ]]; then
        cat "/root/.debian_setup_username"
    else
        echo "admin"
    fi
}

# 重启提示
reboot_prompt() {
    echo -e "\n${YELLOW}部分配置需要重启才能生效${NC}"
    read -p "是否立即重启服务器? (y/N): " choice
    case "${choice:-n}" in
        y|Y)
            log_info "系统将在 5 秒后重启..."
            sleep 5
            reboot
            ;;
        *)
            log_info "请手动重启服务器以使所有配置生效"
            ;;
    esac
}

# 主配置函数
main() {
    log_info "开始 Debian 12 安全配置 (BBRv3 + Fail2Ban)..."
    
    check_root
    install_basics
    system_upgrade
    setup_firewall
    create_admin_user
    configure_ssh_password
    configure_locales
    install_bbrv3_kernel
    configure_bbrv3
    install_fail2ban
    install_monitoring_tools
    create_motd
    show_summary
    reboot_prompt
    
    log_info "安全配置完成!"
}

# 执行主函数
main "$@"
