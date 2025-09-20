#!/bin/bash

# ============================================================================
# Debian 12 系统初始化配置脚本 - 精简版
# 功能：主机名修改 + 系统更新 + SSH安全 + 防火墙 + 性能优化
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
DEFAULT_HOSTNAME="zaochui-org"
NEW_HOSTNAME=""
SSH_PORT="22"
KERNEL_VERSION=""
HAS_BBR_SUPPORT=false
SERVER_IP=""
ROOT_PASS=""
OLD_HOSTNAME=""

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
    log_info "当前内核: $KERNEL_VERSION"
    
    # 提取主版本号
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
    
    # BBR 需要 4.9+ 内核
    if [ "$KERNEL_MAJOR" -gt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 9 ]); then
        HAS_BBR_SUPPORT=true
        log_info "内核支持 BBR"
    else
        HAS_BBR_SUPPORT=false
        log_warn "当前内核版本不支持 BBR，系统更新后将支持"
    fi
    
    # 获取服务器公网IP
    SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -z "$SERVER_IP" ]; then
        # 备用方法获取IP
        SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || wget -qO- -4 ifconfig.me 2>/dev/null)
    fi
    log_info "服务器IP: $SERVER_IP"
    
    # 获取当前主机名
    OLD_HOSTNAME=$(hostname)
    log_info "当前主机名: $OLD_HOSTNAME"
}

# 获取用户输入
get_user_input() {
    log_step "配置信息收集"
    
    # 主机名设置
    echo -e "${YELLOW}主机名设置${NC}"
    echo -e "  当前主机名: ${GREEN}$OLD_HOSTNAME${NC}"
    echo -e "  默认新主机名: ${GREEN}$DEFAULT_HOSTNAME${NC}"
    read -p "请输入新主机名（直接回车使用默认值，输入 'skip' 跳过修改）: " input_hostname
    
    if [[ "$input_hostname" == "skip" ]]; then
        NEW_HOSTNAME=""
        log_info "跳过主机名修改"
    elif [[ -z "$input_hostname" ]]; then
        NEW_HOSTNAME="$DEFAULT_HOSTNAME"
        log_info "将使用默认主机名: $DEFAULT_HOSTNAME"
    else
        # 验证主机名格式
        if [[ "$input_hostname" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,62}$ ]]; then
            NEW_HOSTNAME="$input_hostname"
            log_info "将设置主机名为: $NEW_HOSTNAME"
        else
            log_error "主机名格式无效！使用默认值: $DEFAULT_HOSTNAME"
            NEW_HOSTNAME="$DEFAULT_HOSTNAME"
        fi
    fi
    
    # 获取root新密码
    echo -e "\n${YELLOW}安全设置${NC}"
    while true; do
        echo -e "设置root用户的新密码（直接回车跳过）:"
        read -s -p "输入密码: " ROOT_PASS
        echo
        
        if [[ -z "$ROOT_PASS" ]]; then
            log_info "跳过密码修改"
            break
        fi
        
        read -s -p "确认密码: " ROOT_PASS_CONFIRM
        echo
        
        if [[ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]]; then
            log_error "两次输入的密码不一致，请重新输入"
        elif [[ ${#ROOT_PASS} -lt 8 ]]; then
            log_error "密码长度至少需要8个字符"
        else
            log_info "密码设置成功"
            break
        fi
    done
    
    # 获取SSH端口
    read -p "请输入SSH端口 (当前: 22，建议修改如 10022): " input_port
    if [[ -n "$input_port" ]] && [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
        SSH_PORT="$input_port"
    fi
    
    # 显示配置摘要
    echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}配置信息确认：${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "  服务器IP: ${YELLOW}$SERVER_IP${NC}"
    if [[ -n "$NEW_HOSTNAME" ]]; then
        echo -e "  主机名: ${YELLOW}$OLD_HOSTNAME${NC} → ${YELLOW}$NEW_HOSTNAME${NC}"
    else
        echo -e "  主机名: ${YELLOW}$OLD_HOSTNAME${NC} (不修改)"
    fi
    echo -e "  SSH端口: ${YELLOW}$SSH_PORT${NC}"
    echo -e "  root密码: ${YELLOW}$([ -n "$ROOT_PASS" ] && echo "将更新" || echo "保持不变")${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    
    read -p "确认以上信息正确？(Y/n): " -r
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        get_user_input
    fi
}

# 修改主机名
change_hostname() {
    if [[ -z "$NEW_HOSTNAME" ]]; then
        return
    fi
    
    log_step "修改主机名"
    
    # 修改主机名
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME"
    
    # 更新 /etc/hostname
    echo "$NEW_HOSTNAME" > /etc/hostname
    
    # 更新 /etc/hosts
    if grep -q "$OLD_HOSTNAME" /etc/hosts; then
        sed -i "s/$OLD_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
    fi
    
    # 确保localhost解析正确
    if ! grep -q "127.0.0.1.*localhost" /etc/hosts; then
        echo "127.0.0.1   localhost" >> /etc/hosts
    fi
    if ! grep -q "127.0.1.1.*$NEW_HOSTNAME" /etc/hosts; then
        echo "127.0.1.1   $NEW_HOSTNAME" >> /etc/hosts
    fi
    
    # 验证修改
    log_info "主机名修改完成"
    log_info "新主机名: $(hostname)"
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

# 系统更新到最新版本和内核
full_system_update() {
    log_step "系统更新（包括最新内核）"
    
    # 配置APT不需要交互
    export DEBIAN_FRONTEND=noninteractive
    
    log_info "更新软件包列表..."
    apt-get update -y
    
    log_info "升级所有已安装的软件包..."
    apt-get upgrade -y
    
    log_info "执行完整系统升级（包括内核）..."
    apt-get dist-upgrade -y
    
    log_info "安装最新内核（如果有）..."
    apt-get install -y linux-image-amd64 linux-headers-amd64
    
    log_info "清理不需要的软件包..."
    apt-get autoremove --purge -y
    apt-get autoclean -y
    
    # 检查是否有新内核
    CURRENT_KERNEL=$(uname -r)
    LATEST_KERNEL=$(dpkg -l | grep linux-image | grep -E '^ii' | awk '{print $2}' | sed 's/linux-image-//' | grep -v generic | sort -V | tail -1)
    
    if [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ] && [ -n "$LATEST_KERNEL" ]; then
        log_warn "新内核已安装: $LATEST_KERNEL"
        log_warn "当前运行内核: $CURRENT_KERNEL"
        log_warn "需要重启系统以使用新内核"
    else
        log_info "已运行最新内核"
    fi
    
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
        "htop"
        "net-tools"
        "ufw"
        "rsyslog"
        "vim"
        "git"
        "build-essential"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "安装 $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>/dev/null || log_warn "$pkg 安装失败，继续..."
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
    
    # 创建自定义SSH配置（简化版，不要太严格）
    cat > "$ssh_config_d/99-custom.conf" << EOF
# Custom SSH Configuration
# Generated on $(date)

# 基础设置
Port $SSH_PORT
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin yes

# 基本安全
MaxAuthTries 6
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 3

# 性能优化
UseDNS no
TCPKeepAlive yes
EOF
    
    # 测试SSH配置
    if sshd -t &>/dev/null; then
        log_info "SSH配置测试通过"
        systemctl restart sshd || systemctl restart ssh
        log_info "SSH服务已重启"
    else
        log_error "SSH配置有误，恢复原配置"
        rm -f "$ssh_config_d/99-custom.conf"
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
    
    # 添加SSH端口（防止锁定）
    ufw allow "$SSH_PORT/tcp" comment 'SSH' 2>/dev/null || log_warn "SSH端口规则添加失败"
    
    # 如果修改了默认SSH端口，临时保留22端口
    if [[ "$SSH_PORT" != "22" ]]; then
        ufw allow 22/tcp comment 'SSH-Temp' 2>/dev/null || true
        log_warn "临时保留22端口，请测试新端口${SSH_PORT}可用后手动删除: ufw delete allow 22/tcp"
    fi
    
    # 添加常用服务端口（为后续服务预留）
    ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
    ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
    
    # 设置默认策略
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    
    # 启用防火墙（静默模式）
    echo "y" | ufw enable 2>/dev/null || log_warn "防火墙启用失败"
    
    if ufw status | grep -q "Status: active"; then
        log_info "防火墙已启用"
        echo -e "\n当前防火墙规则："
        ufw status numbered
    else
        log_warn "防火墙未能启用，请手动检查"
    fi
}

# 配置系统优化
configure_system_optimization() {
    log_step "系统性能优化"
    
    # 创建优化配置文件
    cat > /etc/sysctl.d/99-optimization.conf << 'EOF'
# 系统优化配置
# 生成时间: $(date)

# 网络优化
net.core.default_qdisc = fq
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# TCP优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30

# 文件描述符
fs.file-max = 2097152
fs.nr_open = 1048576

# 内存优化
vm.swappiness = 10
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5

# 基础安全
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF
    
    # 检查内核是否支持BBR
    modprobe tcp_bbr 2>/dev/null
    if lsmod | grep -q tcp_bbr; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-optimization.conf
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        log_info "BBR拥塞控制已配置"
    fi
    
    # 应用配置
    sysctl -p /etc/sysctl.d/99-optimization.conf 2>/dev/null || log_warn "部分系统参数应用失败"
    
    # 配置系统限制
    cat > /etc/security/limits.d/99-nofile.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    
    log_info "系统优化完成"
}

# 创建维护脚本
create_maintenance_scripts() {
    log_step "创建维护脚本"
    
    # 创建系统信息脚本
    cat > /root/server_info.sh << 'EOF'
#!/bin/bash
echo "========================================="
echo "         服务器信息概览"
echo "========================================="
echo "主机名: $(hostname)"
echo "内核版本: $(uname -r)"
echo "系统版本: $(cat /etc/debian_version)"
echo "IP地址: $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)"
echo "内存使用: $(free -h | grep Mem | awk '{print $3"/"$2}')"
echo "磁盘使用: $(df -h / | awk 'NR==2 {print $3"/"$2}')"
echo "负载状态: $(uptime | awk -F'load average:' '{print $2}')"
echo "========================================="
echo "防火墙状态:"
ufw status
echo "========================================="
echo "监听端口:"
netstat -tlnp 2>/dev/null | grep LISTEN
echo "========================================="
EOF
    chmod +x /root/server_info.sh
    
    # 创建快速开放端口脚本
    cat > /root/open_port.sh << 'EOF'
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "用法: ./open_port.sh <端口号> [注释]"
    echo "示例: ./open_port.sh 3000 NodeJS"
    exit 1
fi
PORT=$1
COMMENT=${2:-"Custom"}
ufw allow $PORT/tcp comment "$COMMENT"
echo "端口 $PORT 已开放"
ufw status numbered
EOF
    chmod +x /root/open_port.sh
    
    log_info "维护脚本已创建:"
    log_info "  /root/server_info.sh - 查看系统信息"
    log_info "  /root/open_port.sh - 快速开放端口"
}

# 保存配置信息
save_config_info() {
    cat > /root/server_config.txt << EOF
=========================================
服务器配置信息
=========================================
配置时间: $(date)
服务器IP: $SERVER_IP
主机名: $(hostname)
SSH端口: $SSH_PORT
内核版本: $(uname -r)

SSH连接命令:
ssh -p $SSH_PORT root@$SERVER_IP

常用命令:
- 查看系统信息: /root/server_info.sh
- 开放端口: /root/open_port.sh <端口>
- 查看防火墙: ufw status
- 系统更新: apt update && apt upgrade -y

后续安装建议:
1. Docker: curl -fsSL https://get.docker.com | bash
2. Docker Compose: apt install docker-compose -y
3. Caddy: 参考 https://caddyserver.com/docs/install
=========================================
EOF
}

# 显示完成信息
show_completion_info() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║              系统初始化配置完成                          ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${GREEN}✅ 已完成的配置：${NC}"
    if [[ -n "$NEW_HOSTNAME" ]]; then
        echo -e "  • 主机名修改: $OLD_HOSTNAME → $NEW_HOSTNAME"
    fi
    echo -e "  • 系统更新到最新版本"
    echo -e "  • SSH安全配置 (端口: ${YELLOW}$SSH_PORT${NC})"
    echo -e "  • UFW防火墙配置"
    echo -e "  • 系统性能优化"
    echo -e "  • 基础软件包安装"
    
    echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}📝 重要信息（请保存）：${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "服务器IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "主机名: ${GREEN}$(hostname)${NC}"
    echo -e "SSH端口: ${GREEN}$SSH_PORT${NC}"
    echo -e "SSH连接: ${GREEN}ssh -p $SSH_PORT root@$SERVER_IP${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    
    # 检查是否需要重启
    CURRENT_KERNEL=$(uname -r)
    LATEST_KERNEL=$(dpkg -l | grep linux-image | grep -E '^ii' | awk '{print $2}' | sed 's/linux-image-//' | grep -v generic | sort -V | tail -1)
    
    if [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ] && [ -n "$LATEST_KERNEL" ]; then
        echo -e "\n${RED}⚠️  重要提醒：${NC}"
        echo -e "  检测到新内核已安装: ${YELLOW}$LATEST_KERNEL${NC}"
        echo -e "  当前运行内核: ${YELLOW}$CURRENT_KERNEL${NC}"
        echo -e "  ${RED}建议立即重启以使用新内核和BBR优化${NC}"
        echo -e "  重启命令: ${YELLOW}reboot${NC}"
    fi
    
    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "\n${YELLOW}⚠️  SSH端口已修改：${NC}"
        echo -e "  新端口: ${GREEN}$SSH_PORT${NC}"
        echo -e "  临时保留了22端口，测试新端口后请手动关闭："
        echo -e "  ${YELLOW}ufw delete allow 22/tcp${NC}"
    fi
    
    echo -e "\n${GREEN}🔧 快速命令：${NC}"
    echo -e "  查看系统信息: ${BLUE}/root/server_info.sh${NC}"
    echo -e "  开放新端口: ${BLUE}/root/open_port.sh <端口>${NC}"
    echo -e "  查看防火墙: ${BLUE}ufw status${NC}"
    
    echo -e "\n${GREEN}📦 后续安装建议：${NC}"
    echo -e "  Docker: ${BLUE}curl -fsSL https://get.docker.com | bash${NC}"
    echo -e "  PostgreSQL/Redis/MinIO: 建议使用Docker部署"
    echo -e "  Caddy: 访问 https://caddyserver.com/docs/install"
    
    log_info "配置信息已保存到: /root/server_config.txt"
}

# 主函数
main() {
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗"
    echo -e "║        Debian 12 系统初始化配置脚本                     ║"
    echo -e "║            精简版 - 专注核心功能                        ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    # 执行流程
    check_root
    check_system
    get_user_input
    
    # 开始配置
    change_hostname
    update_root_password
    full_system_update
    install_packages
    configure_ssh
    setup_firewall
    configure_system_optimization
    create_maintenance_scripts
    save_config_info
    
    # 显示完成信息
    show_completion_info
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🎉 所有配置已完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # 询问是否立即重启
    echo -e "\n${YELLOW}是否立即重启系统？(推荐重启以应用新内核)${NC}"
    read -p "立即重启？(y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}系统将在3秒后重启...${NC}"
        sleep 3
        reboot
    else
        echo -e "${YELLOW}请记得稍后手动重启: ${NC}${GREEN}reboot${NC}"
    fi
}

# 执行主函数
main "$@"
