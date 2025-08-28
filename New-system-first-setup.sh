#!/bin/bash

# ============================================================================
# Debian 12 VPS 全自动配置脚本
# 包含系统初始化、安全加固、性能优化、自动重启继续
# 使用方法: wget -O - https://raw.githubusercontent.com/yourname/debian-setup/master/setup.sh | bash
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# 脚本状态和密钥文件
STATUS_FILE="/root/.debian_setup_status"
SSH_KEY_FILE="/root/ssh_key_backup.txt"
SCRIPT_PATH="/root/debian-setup.sh"
SERVICE_NAME="debian-setup.service"

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

# 检测网络连接
check_network() {
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        log_error "网络连接检查失败，请检查网络配置"
        exit 1
    fi
    log_info "网络连接正常"
}

# 创建 systemd 服务用于重启后继续
create_resume_service() {
    log_info "创建重启后自动继续的服务..."
    
    # 将当前脚本保存到固定位置
    cat "$0" > "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # 创建 systemd 服务文件
    cat > "/etc/systemd/system/$SERVICE_NAME" << EOF
[Unit]
Description=Debian VPS Setup Service
After=network.target ssh.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --resume
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
TimeoutSec=3600

[Install]
WantedBy=multi-user.target
EOF

    # 重载并启用服务
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    log_info "重启后自动继续服务已创建"
}

# 移除 systemd 服务
remove_resume_service() {
    log_info "清理自动继续服务..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload
    rm -f "$SCRIPT_PATH"
}

# 保存执行状态
save_status() {
    echo "$1" > "$STATUS_FILE"
}

# 读取执行状态
get_status() {
    if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        echo "init"
    fi
}

# 安装基本组件
install_basics() {
    log_info "安装基本系统工具..."
    apt update -y
    apt install -y sudo curl wget nano vim htop git unzip zip \
                   net-tools dnsutils telnet gnupg2 apt-transport-https \
                   ca-certificates software-properties-common lsb-release
    
    log_info "设置 root 密码..."
    passwd root
}

# 系统更新
system_upgrade() {
    log_info "系统升级..."
    apt update -y
    apt upgrade -y
    apt dist-upgrade -y
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

# 保存 SSH 公钥到文件
save_ssh_key_to_file() {
    local username=$1
    local key_file="/home/$username/.ssh/id_rsa.pub"
    
    # 创建密钥备份文件
    cat > "$SSH_KEY_FILE" << EOF
===========================================
=            SSH 密钥备份文件             =
=   请妥善保存此文件内容！丢失将无法登录   =
===========================================
生成时间: $(date)
用户名: $username

SSH 公钥:
$(cat "$key_file")

私钥位置: /home/$username/.ssh/id_rsa
公钥位置: /home/$username/.ssh/id_rsa.pub

使用说明:
1. 将公钥内容添加到本地 SSH 客户端的 ~/.ssh/known_hosts
2. 或者使用 ssh-copy-id 命令上传公钥到其他服务器

连接命令:
ssh -i /path/to/private/key $username@服务器IP

===========================================
EOF
    
    log_info "SSH 密钥已保存到: $SSH_KEY_FILE"
}

# 显示 SSH 密钥信息（带暂停功能）
show_ssh_key_info() {
    local username=$1
    
    echo -e "\n${CYAN}===========================================${NC}"
    echo -e "${CYAN}            SSH 密钥信息                 ${NC}"
    echo -e "${CYAN}===========================================${NC}"
    
    # 显示公钥内容
    echo -e "${YELLOW}SSH 公钥内容:${NC}"
    echo -e "${GREEN}$(cat "/home/$username/.ssh/id_rsa.pub")${NC}"
    
    echo -e "\n${YELLOW}私钥文件位置:${NC} /home/$username/.ssh/id_rsa"
    echo -e "${YELLOW}公钥文件位置:${NC} /home/$username/.ssh/id_rsa.pub"
    echo -e "${YELLOW}备份文件位置:${NC} $SSH_KEY_FILE"
    
    echo -e "\n${RED}重要提示:${NC}"
    echo -e "1. 上述公钥内容已保存到 ${SSH_KEY_FILE}"
    echo -e "2. 请立即复制保存公钥内容！"
    echo -e "3. 丢失密钥将无法 SSH 登录服务器！"
    echo -e "4. 建议下载备份文件: $SSH_KEY_FILE"
    
    echo -e "\n${CYAN}===========================================${NC}"
    
    # 暂停让用户查看和复制
    echo -e "\n${YELLOW}请仔细复制上面的 SSH 公钥内容...${NC}"
    read -p "按 Enter 继续 (等待60秒自动继续): " -t 60 || true
    echo
}

# 提供密钥下载帮助
provide_key_download_help() {
    log_info "如何下载 SSH 密钥备份文件:"
    echo -e "${GREEN}方法1: 使用 SCP 下载:${NC}"
    echo "scp root@你的服务器IP:$SSH_KEY_FILE ./"
    echo
    echo -e "${GREEN}方法2: 使用 SFTP:${NC}"
    echo "sftp root@你的服务器IP"
    echo "get $SSH_KEY_FILE"
    echo
    echo -e "${GREEN}方法3: 直接查看内容:${NC}"
    echo "cat $SSH_KEY_FILE"
    echo
}

# 创建新用户并设置 SSH 密钥
create_user_with_ssh() {
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
    passwd "$username"
    
    # 添加 sudo 权限
    if ! grep -q "^$username" /etc/sudoers; then
        echo "$username ALL=(ALL:ALL) ALL" >> /etc/sudoers
        log_info "已为用户 $username 添加 sudo 权限"
    fi
    
    # 生成 SSH 密钥对
    log_info "为 $username 生成 SSH 密钥对..."
    mkdir -p "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    
    if [[ ! -f "/home/$username/.ssh/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "/home/$username/.ssh/id_rsa" -N "" -q
    fi
    
    # 设置公钥认证
    cat "/home/$username/.ssh/id_rsa.pub" > "/home/$username/.ssh/authorized_keys"
    chmod 600 "/home/$username/.ssh/authorized_keys"
    chown -R "$username:$username" "/home/$username/.ssh"
    
    # 保存 SSH 公钥到文件（重要！）
    save_ssh_key_to_file "$username"
    
    # 显示 SSH 密钥信息（暂停让用户查看）
    show_ssh_key_info "$username"
    
    echo "$username" > /root/.debian_setup_username
}

# 获取用户名
get_username() {
    if [[ -f "/root/.debian_setup_username" ]]; then
        cat "/root/.debian_setup_username"
    else
        echo "admin"
    fi
}

# 安全配置 SSH
configure_ssh() {
    log_info "安全配置 SSH..."
    
    local ssh_config="/etc/ssh/sshd_config"
    local backup_file="$ssh_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 备份原配置
    cp "$ssh_config" "$backup_file"
    log_info "SSH 配置已备份到: $backup_file"
    
    # 安全配置选项
    local ssh_changes=(
        "PermitRootLogin no"
        "PasswordAuthentication no"
        "PubkeyAuthentication yes"
        "ChallengeResponseAuthentication no"
        "MaxAuthTries 3"
        "ClientAliveInterval 300"
        "ClientAliveCountMax 2"
    )
    
    for setting in "${ssh_changes[@]}"; do
        local key=${setting%% *}
        local value=${setting#* }
        
        if grep -q "^#$key" "$ssh_config" || grep -q "^$key" "$ssh_config"; then
            sed -i "s/^#*$key.*/$key $value/" "$ssh_config"
        else
            echo "$key $value" >> "$ssh_config"
        fi
    done
    
    # 创建新用户并设置 SSH 密钥
    create_user_with_ssh
    
    # 提供下载帮助
    provide_key_download_help
    
    # 再次提醒用户保存密钥
    read -p "请确认已保存 SSH 公钥！按 Enter 继续配置 SSH..." 
    
    systemctl restart ssh
    log_info "SSH 安全配置已完成"
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

# 启用 BBRv3 优化
enable_bbr_optimization() {
    log_info "启用 BBRv3 和网络优化..."
    
    # 安装最新内核（可选）
    read -p "是否安装最新内核以支持 BBRv3? (Y/n): " choice
    case "${choice:-y}" in
        y|Y)
            log_info "安装最新内核..."
            echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
            apt update -y
            apt install -y -t bookworm-backports linux-image-cloud-amd64
            ;;
    esac
    
    # 配置 BBRv3
    cat >> /etc/sysctl.conf << 'EOF'

# BBRv3 网络优化
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
vm.swappiness = 10
vm.vfs_cache_pressure = 50
fs.file-max = 2097152
EOF
    
    sysctl -p
    log_info "BBRv3 和网络优化已启用"
}

# 安装监控工具
install_monitoring_tools() {
    log_info "安装系统监控工具..."
    apt install -y htop iotop iftop nload sysstat
    log_info "监控工具安装完成"
}

# 创建登录欢迎信息
create_motd() {
    log_info "配置登录欢迎信息..."
    cat > /etc/motd << 'EOF'
=============================================
=             Debian 12 Server              =
=             Secure & Optimized            =
=============================================
系统已通过安全加固和性能优化
=============================================
EOF
}

# 显示配置摘要
show_summary() {
    local username=$(get_username)
    
    log_success "=== 配置完成摘要 ==="
    log_info "✅ 系统基础工具安装完成"
    log_info "✅ 系统更新完成"
    log_info "✅ 防火墙配置完成"
    log_info "✅ SSH 安全加固完成"
    log_info "✅ 区域设置完成"
    log_info "✅ BBRv3 网络优化启用"
    log_info "✅ 监控工具安装完成"
    
    echo -e "\n${YELLOW}SSH 连接信息:${NC}"
    echo "用户名: $username"
    echo "连接命令: ssh -i /path/to/private/key ${username}@服务器IP"
    echo "密钥备份: $SSH_KEY_FILE"
    
    log_warn "重要提示:"
    log_warn "1. SSH 已禁用密码登录，请使用密钥登录"
    log_warn "2. 请确保已保存 SSH 密钥备份文件！"
    log_warn "3. 建议立即测试 SSH 连接"
}

# 测试 SSH 连接
test_ssh_connection() {
    local username=$(get_username)
    
    log_info "建议测试 SSH 连接..."
    echo -e "${YELLOW}请在新终端中测试连接:${NC}"
    echo "ssh -i /path/to/private/key ${username}@服务器IP"
    echo
    read -p "按 Enter 继续（确认已测试或稍后测试）..."
}

# 重启系统
reboot_system() {
    log_warn "系统需要重启以应用所有配置"
    log_info "重启后脚本会自动继续执行剩余步骤..."
    read -p "按 Enter 立即重启或 Ctrl+C 取消: "
    
    # 保存状态并创建重启服务
    save_status "rebooting"
    create_resume_service
    
    log_info "系统将在 10 秒后重启..."
    for i in {10..1}; do
        echo -ne "倒计时: $i 秒\r"
        sleep 1
    done
    echo
    
    reboot
}

# 第二阶段配置（重启后执行）
stage2_configuration() {
    log_info "=== 第二阶段配置 (重启后) ==="
    
    # 验证 BBRv3 状态
    log_info "验证 BBRv3 状态..."
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        log_success "BBRv3 已成功启用"
    else
        log_warn "BBRv3 未启用，使用传统 BBR"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
    
    # 最终系统检查
    log_info "进行最终系统检查..."
    systemctl is-active ssh >/dev/null && log_info "SSH 服务运行正常"
    systemctl is-active ufw >/dev/null && log_info "防火墙服务运行正常"
    
    # 显示最终配置摘要
    final_configuration_summary
    
    # 清理工作
    remove_resume_service
    rm -f "$STATUS_FILE"
    
    log_success "=== 所有配置已完成 ==="
}

# 最终配置完成提示
final_configuration_summary() {
    local username=$(get_username)
    
    echo -e "\n${CYAN}===========================================${NC}"
    echo -e "${CYAN}           配置完成摘要                   ${NC}"
    echo -e "${CYAN}===========================================${NC}"
    
    echo -e "${GREEN}✅ SSH 安全配置:${NC}"
    echo "  - 已禁用 root 登录"
    echo "  - 已禁用密码认证"
    echo "  - 已启用密钥认证"
    echo "  - 管理用户: $username"
    
    echo -e "\n${GREEN}✅ SSH 密钥信息:${NC}"
    echo "  - 公钥文件: /home/$username/.ssh/id_rsa.pub"
    echo "  - 私钥文件: /home/$username/.ssh/id_rsa"
    echo "  - 备份文件: $SSH_KEY_FILE"
    
    echo -e "\n${GREEN}✅ 网络优化:${NC}"
    echo "  - BBRv3 拥塞控制已启用"
    echo "  - 防火墙已配置"
    echo "  - 网络参数已优化"
    
    echo -e "\n${GREEN}✅ 连接服务器:${NC}"
    echo "  ssh -i /path/to/private/key ${username}@服务器IP"
    
    echo -e "\n${RED}⚠️  重要提醒:${NC}"
    echo "  - 请确保已保存 SSH 密钥备份！"
    echo "  - 密钥丢失将无法登录服务器！"
    echo "  - 建议立即测试 SSH 连接"
    
    echo -e "\n${CYAN}===========================================${NC}"
}

# 主配置函数
main_configuration() {
    local current_status=$(get_status)
    
    case "$current_status" in
        "init")
            log_info "开始第一阶段配置..."
            check_root
            check_network
            install_basics
            system_upgrade
            setup_firewall
            configure_ssh
            configure_locales
            enable_bbr_optimization
            install_monitoring_tools
            create_motd
            show_summary
            test_ssh_connection
            reboot_system
            ;;
        "rebooting")
            log_info "检测到重启后状态，继续第二阶段配置..."
            stage2_configuration
            ;;
        *)
            log_info "开始全新配置..."
            save_status "init"
            main_configuration
            ;;
    esac
}

# 处理命令行参数
case "${1:-}" in
    "--resume")
        log_info "从 systemd 服务启动，继续执行..."
        main_configuration
        ;;
    "--help")
        echo "使用方法: $0 [--resume|--help]"
        echo "  --resume: 从重启后继续执行"
        echo "  --help:   显示帮助信息"
        ;;
    *)
        # 正常执行
        main_configuration
        ;;
esac
