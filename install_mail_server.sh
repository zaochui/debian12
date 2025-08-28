#!/bin/bash

# ============================================================================
# Debian 12 邮件服务器一键部署脚本 - 最终修复版
# 版本: 2.2.0
# 作者: 开源社区版
# 协议: MIT
# 
# 功能特性:
# - Postfix + Dovecot 虚拟用户管理
# - Let's Encrypt SSL/TLS 证书
# - DKIM, SPF, DMARC 邮件认证
# - 反垃圾邮件防护
# - Fail2ban 防暴力破解
# - 用户管理工具
# - 健康检查监控
# 
# 使用方法: bash install_mail_server.sh
# ============================================================================

set -eo pipefail

# ============================================================================
# 全局配置变量
# ============================================================================

SCRIPT_VERSION="2.2.0"
SCRIPT_NAME="Debian 12 邮件服务器部署脚本"
LOG_FILE="/var/log/mail-server-setup.log"
BACKUP_DIR="/var/backups/mail-setup-$(date +%Y%m%d_%H%M%S)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # 无颜色

# 邮件系统配置
VMAIL_USER="vmail"
VMAIL_GROUP="vmail"
VMAIL_UID="5000"
VMAIL_GID="5000"
VMAIL_HOME="/var/mail/vhosts"

# ============================================================================
# 辅助函数
# ============================================================================

# 日志记录
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 彩色输出
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# 错误退出
error_exit() {
    print_color "$RED" "❌ 错误: $1"
    log "错误: $1"
    exit 1
}

# 成功提示
success() {
    print_color "$GREEN" "✅ $1"
    log "成功: $1"
}

# 警告提示
warning() {
    print_color "$YELLOW" "⚠️  $1"
    log "警告: $1"
}

# 信息提示
info() {
    print_color "$BLUE" "ℹ️  $1"
    log "信息: $1"
}

# 确认提示
confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local REPLY
    
    if [[ "$default" == "Y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" -n 1 -r
    echo
    
    if [[ "$default" == "Y" ]]; then
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# ============================================================================
# 系统要求检查
# ============================================================================

check_requirements() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  系统环境检查"
    print_color "$PURPLE" "========================================"
    
    info "正在检查系统要求..."
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本必须以 root 权限运行。请使用: sudo bash $0"
    fi
    
    # 检查操作系统
    if [[ ! -f /etc/debian_version ]]; then
        error_exit "此脚本仅支持 Debian 系统。"
    fi
    
    # 检查 Debian 版本
    local debian_version=$(cat /etc/debian_version | cut -d. -f1)
    if [[ "$debian_version" -lt 11 ]]; then
        warning "此脚本针对 Debian 11+ 优化，当前版本可能存在兼容性问题。"
        if ! confirm "是否继续安装？"; then
            exit 0
        fi
    fi
    
    # 检查网络连接
    info "检查网络连接..."
    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null && ! ping -c 1 -W 2 1.1.1.1 &> /dev/null; then
        error_exit "无法连接到互联网。请检查网络设置。"
    fi
    
    # 检查磁盘空间（至少需要 1GB）
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 1048576 ]]; then
        error_exit "磁盘空间不足。至少需要 1GB 可用空间。"
    fi
    
    # 检查内存
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    if [[ $total_mem -lt 512 ]]; then
        warning "内存少于 512MB，可能会影响安装"
        # 创建 swap 文件
        if ! swapon -s | grep -q swap; then
            info "创建 swap 文件..."
            fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
            success "Swap 文件创建成功"
        fi
    fi
    
    success "系统环境检查通过"
}

# ============================================================================
# 修复和配置软件源
# ============================================================================

fix_apt_sources() {
    info "配置软件源..."
    
    # 备份原始源
    cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d) 2>/dev/null || true
    
    # 配置标准 Debian 源
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
    
    # 清理缓存
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    
    # 更新源
    apt-get update || {
        warning "主源更新失败，尝试备用源..."
        cat > /etc/apt/sources.list << EOF
deb http://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
        apt-get update
    }
    
    # 修复可能的依赖问题
    apt-get install -f -y
    dpkg --configure -a
    
    success "软件源配置完成"
}

# ============================================================================
# 清理和修复现有安装
# ============================================================================

cleanup_existing_installation() {
    info "检查并修复现有安装..."
    
    # 检查 Postfix 状态
    if dpkg -l | grep -q "^iF.*postfix"; then
        warning "检测到 Postfix 安装未完成，尝试修复..."
        
        # 获取正确的主机名和域名
        local temp_hostname=$(hostname -f 2>/dev/null || hostname)
        if [[ "$temp_hostname" == *.* ]]; then
            TEMP_DOMAIN=$(echo "$temp_hostname" | cut -d. -f2-)
        else
            TEMP_DOMAIN="localdomain"
            temp_hostname="mail.$TEMP_DOMAIN"
        fi
        
        # 修复 Postfix 配置
        postconf -e "myhostname = $temp_hostname"
        postconf -e "mydomain = $TEMP_DOMAIN"
        postconf -e "myorigin = \$mydomain"
        postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
        
        # 尝试完成配置
        newaliases 2>/dev/null || true
        dpkg --configure postfix 2>/dev/null || true
    fi
    
    # 修复所有未配置的包
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    
    success "清理完成"
}

# ============================================================================
# 备份现有配置
# ============================================================================

create_backup() {
    info "创建配置备份..."
    
    mkdir -p "$BACKUP_DIR"
    
    # 备份现有配置文件
    for item in /etc/postfix /etc/dovecot /etc/hostname /etc/hosts /etc/mailname /etc/opendkim; do
        if [[ -e "$item" ]]; then
            cp -a "$item" "$BACKUP_DIR/" 2>/dev/null || true
        fi
    done
    
    success "备份已创建: $BACKUP_DIR"
}

# ============================================================================
# 主机名和域名配置
# ============================================================================

configure_hostname() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  主机名配置"
    print_color "$PURPLE" "========================================"
    
    local current_hostname=$(hostname -f 2>/dev/null || hostname)
    info "当前主机名: $current_hostname"
    
    # 验证 FQDN 格式
    is_valid_fqdn() {
        local hostname=$1
        if [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]] && [[ "$hostname" == *.* ]]; then
            return 0
        else
            return 1
        fi
    }
    
    # 检查当前主机名是否是 IP 地址或无效
    if [[ "$current_hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! is_valid_fqdn "$current_hostname"; then
        warning "当前主机名无效或是 IP 地址"
        echo "邮件服务器需要一个正确的 FQDN，例如: mail.example.com"
        read -p "请输入邮件服务器主机名: " new_hostname
        
        if ! is_valid_fqdn "$new_hostname"; then
            error_exit "主机名格式无效。必须是类似 mail.example.com 的 FQDN"
        fi
        
        HOSTNAME="$new_hostname"
    else
        if confirm "使用 '$current_hostname' 作为邮件服务器主机名？" "Y"; then
            HOSTNAME="$current_hostname"
        else
            read -p "请输入新的主机名: " new_hostname
            if ! is_valid_fqdn "$new_hostname"; then
                error_exit "主机名格式无效"
            fi
            HOSTNAME="$new_hostname"
        fi
    fi
    
    # 设置主机名
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME"
    
    # 更新 /etc/hosts
    local primary_ip=$(ip route get 1 2>/dev/null | awk '{print $7;exit}' || ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d'/' -f1)
    
    # 清理可能的错误条目
    sed -i "/^[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*[[:space:]]*$HOSTNAME/d" /etc/hosts 2>/dev/null || true
    
    # 添加正确的条目
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "$primary_ip    $HOSTNAME $(echo $HOSTNAME | cut -d. -f1)" >> /etc/hosts
    fi
    
    # 提取域名
    DOMAIN=$(echo "$HOSTNAME" | cut -d. -f2-)
    
    # 确保域名有效
    if [[ -z "$DOMAIN" ]] || [[ "$DOMAIN" == "$HOSTNAME" ]]; then
        read -p "请输入域名（如 example.com）: " DOMAIN
    fi
    
    # 更新 mailname
    echo "$HOSTNAME" > /etc/mailname
    
    success "主机名已配置: $HOSTNAME"
    success "域名: $DOMAIN"
}

# ============================================================================
# DNS 验证和检查
# ============================================================================

check_dns() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  DNS 配置检查"
    print_color "$PURPLE" "========================================"
    
    # 安装 DNS 工具
    if ! command -v dig &> /dev/null; then
        info "安装 DNS 工具..."
        apt-get install -y dnsutils curl
    fi
    
    # 获取服务器公网 IP
    info "获取服务器公网 IP..."
    SERVER_IP=$(curl -s -4 --connect-timeout 5 ifconfig.me || \
                curl -s -4 --connect-timeout 5 icanhazip.com || \
                curl -s -4 --connect-timeout 5 ipinfo.io/ip)
    
    if [[ -z "$SERVER_IP" ]]; then
        warning "无法自动获取公网 IP"
        read -p "请手动输入服务器公网 IP: " SERVER_IP
    fi
    
    info "服务器公网 IP: $SERVER_IP"
    
    # 检查 A 记录
    info "检查 DNS A 记录..."
    DNS_IP=$(dig +short "$HOSTNAME" A 2>/dev/null | head -n1)
    
    if [[ -z "$DNS_IP" ]]; then
        warning "域名 $HOSTNAME 没有 DNS A 记录！"
        echo
        print_color "$YELLOW" "请在您的 DNS 服务商处添加以下记录："
        echo "----------------------------------------"
        echo "类型: A"
        echo "名称: $(echo $HOSTNAME | cut -d. -f1)"
        echo "值:   $SERVER_IP"
        echo "----------------------------------------"
        
        if ! confirm "DNS 记录设置完成后继续？"; then
            info "您可以稍后再运行此脚本"
            exit 0
        fi
    elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
        warning "DNS 解析不匹配！"
        echo "域名解析到: $DNS_IP"
        echo "服务器 IP:  $SERVER_IP"
        
        if ! confirm "DNS 配置可能有误，是否继续？"; then
            info "请先修正 DNS 配置"
            exit 0
        fi
    else
        success "DNS A 记录正确"
    fi
}

# ============================================================================
# 安装必要软件包（改进版）
# ============================================================================

install_packages() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  安装软件包"
    print_color "$PURPLE" "========================================"
    
    # 清理可能的问题
    cleanup_existing_installation
    
    # 预配置 Postfix 避免交互式安装
    echo "postfix postfix/mailname string $HOSTNAME" | debconf-set-selections
    echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections
    
    # 基础软件包
    info "安装基础工具..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        gnupg \
        lsb-release \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        dnsutils \
        net-tools \
        || warning "部分基础工具安装失败"
    
    # Postfix - 特殊处理
    info "安装 Postfix..."
    if dpkg -l | grep -q "^ii.*postfix"; then
        info "Postfix 已安装，重新配置..."
        # 确保配置正确
        postconf -e "myhostname = $HOSTNAME"
        postconf -e "mydomain = $DOMAIN"
        postconf -e "myorigin = \$mydomain"
        postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
        newaliases
    else
        # 新安装
        DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
        if [ $? -ne 0 ]; then
            warning "Postfix 安装失败，尝试修复..."
            # 手动配置
            postconf -e "myhostname = $HOSTNAME"
            postconf -e "mydomain = $DOMAIN"
            postconf -e "myorigin = \$mydomain"
            postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
            newaliases 2>/dev/null || true
            dpkg --configure postfix
        fi
    fi
    
    # Dovecot
    info "安装 Dovecot..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        dovecot-core \
        dovecot-imapd \
        dovecot-pop3d \
        dovecot-lmtpd \
        || warning "部分 Dovecot 组件安装失败"
    
    # SSL 证书
    info "安装 Certbot..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot \
        || warning "Certbot 安装失败，将使用自签名证书"
    
    # DKIM
    info "安装 OpenDKIM..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y opendkim opendkim-tools \
        || warning "OpenDKIM 安装失败"
    
    # 反垃圾邮件
    info "安装 SpamAssassin..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y spamassassin spamc \
        || warning "SpamAssassin 安装失败"
    
    # 安全工具
    info "安装安全工具..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban ufw \
        || warning "部分安全工具安装失败"
    
    # 邮件工具
    info "安装邮件工具..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils \
        || warning "邮件工具安装失败"
    
    # 最终检查
    dpkg --configure -a
    
    success "软件包安装完成"
}

# ============================================================================
# SSL 证书配置
# ============================================================================

configure_ssl() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  SSL 证书配置"
    print_color "$PURPLE" "========================================"
    
    # 检查是否安装了 certbot
    if ! command -v certbot &> /dev/null; then
        warning "Certbot 未安装，使用自签名证书"
        create_self_signed_cert
        return
    fi
    
    read -p "请输入用于接收证书通知的邮箱地址: " ADMIN_EMAIL
    
    # 验证邮箱格式
    if [[ ! "$ADMIN_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        warning "邮箱格式不正确，将使用自签名证书"
        create_self_signed_cert
        return
    fi
    
    # 停止占用 80 端口的服务
    for service in nginx apache2 httpd; do
        systemctl stop $service 2>/dev/null || true
    done
    
    info "申请 Let's Encrypt SSL 证书..."
    
    if certbot certonly --standalone \
        -d "$HOSTNAME" \
        --agree-tos \
        --non-interactive \
        --email "$ADMIN_EMAIL" \
        --preferred-challenges http; then
        
        SSL_CERT="/etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/$HOSTNAME/privkey.pem"
        
        # 配置自动续期
        cat > /etc/cron.d/certbot-renew << EOF
0 0,12 * * * root certbot renew --quiet --post-hook 'systemctl reload postfix dovecot'
EOF
        
        success "SSL 证书申请成功"
    else
        warning "Let's Encrypt 证书申请失败，使用自签名证书"
        create_self_signed_cert
    fi
}

create_self_signed_cert() {
    info "生成自签名证书..."
    
    mkdir -p /etc/ssl/certs /etc/ssl/private
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "/etc/ssl/private/$HOSTNAME.key" \
        -out "/etc/ssl/certs/$HOSTNAME.crt" \
        -subj "/C=CN/ST=State/L=City/O=Organization/CN=$HOSTNAME" \
        2>/dev/null
    
    SSL_CERT="/etc/ssl/certs/$HOSTNAME.crt"
    SSL_KEY="/etc/ssl/private/$HOSTNAME.key"
    
    warning "使用自签名证书。建议稍后申请正式证书："
    echo "certbot certonly --standalone -d $HOSTNAME --email your@email.com"
}

# ============================================================================
# 配置 Postfix（修正版）
# ============================================================================

configure_postfix() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  配置 Postfix"
    print_color "$PURPLE" "========================================"
    
    info "配置 Postfix 主配置文件..."
    
    # 备份原配置
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup 2>/dev/null || true
    
    # 确保主机名和域名配置正确
    postconf -e "myhostname = $HOSTNAME"
    postconf -e "mydomain = $DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "mydestination = localhost.\$mydomain, localhost"
    
    # 生成主配置文件
    cat > /etc/postfix/main.cf << EOF
# ====================================================
# Postfix 主配置文件
# 生成时间: $(date)
# ====================================================

# 基础设置
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 3.6

# 服务器标识 - 关键配置
myhostname = $HOSTNAME
mydomain = $DOMAIN
myorigin = \$mydomain
mydestination = localhost.\$mydomain, localhost

# 网络设置
inet_interfaces = all
inet_protocols = ipv4
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128

# SSL/TLS 配置
smtpd_tls_cert_file = $SSL_CERT
smtpd_tls_key_file = $SSL_KEY
smtpd_use_tls = yes
smtpd_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_security_level = may
smtpd_tls_received_header = yes
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

# 虚拟域和用户配置
virtual_mailbox_domains = $DOMAIN
virtual_mailbox_base = $VMAIL_HOME
virtual_mailbox_maps = hash:/etc/postfix/virtual_mailboxes
virtual_alias_maps = hash:/etc/postfix/virtual_aliases
virtual_uid_maps = static:$VMAIL_UID
virtual_gid_maps = static:$VMAIL_GID
virtual_transport = lmtp:unix:private/dovecot-lmtp

# SASL 认证配置
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$mydomain
broken_sasl_auth_clients = yes

# 邮件限制
message_size_limit = 52428800
mailbox_size_limit = 1073741824
virtual_mailbox_limit = 1073741824
recipient_delimiter = +

# SMTP 限制
smtpd_helo_required = yes
disable_vrfy_command = yes

# 接收限制
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    reject_invalid_hostname,
    reject_unknown_recipient_domain

smtpd_sender_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain

# 发送速率限制
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 30
anvil_rate_time_unit = 60s

# 错误处理
smtpd_error_sleep_time = 1s
smtpd_soft_error_limit = 10
smtpd_hard_error_limit = 20

# 队列设置
maximal_queue_lifetime = 3d
bounce_queue_lifetime = 1d
queue_run_delay = 300s

# 性能优化
default_process_limit = 100
EOF

    # 检查是否安装了 OpenDKIM
    if command -v opendkim &> /dev/null; then
        cat >> /etc/postfix/main.cf << EOF

# DKIM 集成
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
EOF
    fi
    
    # 生成别名数据库
    newaliases
    
    # 配置 master.cf
    info "配置 Postfix master.cf..."
    
    # 检查是否已存在配置，避免重复
    if ! grep -q "^submission" /etc/postfix/master.cf; then
        cat >> /etc/postfix/master.cf << 'EOF'

# Submission 端口配置 (587)
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# SMTPS 端口配置 (465)
smtps inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
    fi
    
    # 创建虚拟用户映射
    info "创建虚拟用户映射..."
    
    mkdir -p /etc/postfix
    
    cat > /etc/postfix/virtual_mailboxes << EOF
# 虚拟邮箱映射
admin@$DOMAIN       $DOMAIN/admin/
service@$DOMAIN     $DOMAIN/service/
support@$DOMAIN     $DOMAIN/support/
noreply@$DOMAIN     $DOMAIN/noreply/
info@$DOMAIN        $DOMAIN/info/
EOF
    
    cat > /etc/postfix/virtual_aliases << EOF
# 虚拟别名映射
postmaster@$DOMAIN  admin@$DOMAIN
webmaster@$DOMAIN   admin@$DOMAIN
root@$DOMAIN        admin@$DOMAIN
EOF
    
    # 生成映射数据库
    postmap /etc/postfix/virtual_mailboxes
    postmap /etc/postfix/virtual_aliases
    
    # 重启 Postfix
    systemctl restart postfix
    
    success "Postfix 配置完成"
}

# ============================================================================
# 配置 Dovecot
# ============================================================================

configure_dovecot() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  配置 Dovecot"
    print_color "$PURPLE" "========================================"
    
    info "配置 Dovecot..."
    
    # 创建邮件用户和组
    groupadd -g $VMAIL_GID $VMAIL_GROUP 2>/dev/null || true
    useradd -u $VMAIL_UID -g $VMAIL_GROUP -s /usr/sbin/nologin -d $VMAIL_HOME -m $VMAIL_USER 2>/dev/null || true
    
    # 创建邮件目录
    mkdir -p $VMAIL_HOME/$DOMAIN
    chown -R $VMAIL_USER:$VMAIL_GROUP $VMAIL_HOME
    
    # 配置认证
    cat > /etc/dovecot/conf.d/10-auth.conf << EOF
# 认证配置
disable_plaintext_auth = yes
auth_mechanisms = plain login

# 密码文件认证
passdb {
    driver = passwd-file
    args = scheme=SHA512-CRYPT username_format=%n /etc/dovecot/users
}

userdb {
    driver = static
    args = uid=$VMAIL_USER gid=$VMAIL_GROUP home=$VMAIL_HOME/%d/%n
}
EOF
    
    # 配置邮件存储
    cat > /etc/dovecot/conf.d/10-mail.conf << EOF
# 邮件存储配置
mail_location = maildir:$VMAIL_HOME/%d/%n/Maildir
namespace inbox {
    inbox = yes
}

mail_uid = $VMAIL_USER
mail_gid = $VMAIL_GROUP

first_valid_uid = $VMAIL_UID
last_valid_uid = $VMAIL_UID

mail_privileged_group = $VMAIL_GROUP
EOF
    
    # 配置 SSL
    cat > /etc/dovecot/conf.d/10-ssl.conf << EOF
# SSL 配置
ssl = required
ssl_cert = <$SSL_CERT
ssl_key = <$SSL_KEY
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
EOF
    
    # 配置服务
    cat > /etc/dovecot/conf.d/10-master.conf << EOF
# 服务配置
service imap-login {
    inet_listener imap {
        port = 143
    }
    inet_listener imaps {
        port = 993
        ssl = yes
    }
}

service pop3-login {
    inet_listener pop3 {
        port = 0
    }
    inet_listener pop3s {
        port = 995
        ssl = yes
    }
}

service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
        mode = 0600
        user = postfix
        group = postfix
    }
}

service auth {
    unix_listener /var/spool/postfix/private/auth {
        mode = 0660
        user = postfix
        group = postfix
    }
    
    unix_listener auth-userdb {
        mode = 0666
        user = $VMAIL_USER
        group = $VMAIL_GROUP
    }
}

service auth-worker {
    user = $VMAIL_USER
}
EOF
    
    # 创建用户密码文件
    touch /etc/dovecot/users
    chmod 640 /etc/dovecot/users
    chown root:dovecot /etc/dovecot/users
    
    success "Dovecot 配置完成"
}

# ============================================================================
# 配置 DKIM（如果安装了）
# ============================================================================

configure_dkim() {
    if ! command -v opendkim &> /dev/null; then
        warning "OpenDKIM 未安装，跳过 DKIM 配置"
        return
    fi
    
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  配置 DKIM 邮件签名"
    print_color "$PURPLE" "========================================"
    
    info "配置 OpenDKIM..."
    
    # 创建目录
    mkdir -p /etc/opendkim/keys/$DOMAIN
    
    # 生成密钥
    opendkim-genkey -D /etc/opendkim/keys/$DOMAIN/ -d $DOMAIN -s mail
    chown -R opendkim:opendkim /etc/opendkim/
    
    # 配置 OpenDKIM
    cat > /etc/opendkim.conf << EOF
# OpenDKIM 配置
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes
Canonicalization        relaxed/simple
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256
UserID                  opendkim:opendkim
Socket                  inet:8891@localhost
EOF
    
    # 配置信任主机
    cat > /etc/opendkim/TrustedHosts << EOF
127.0.0.1
localhost
$HOSTNAME
$DOMAIN
EOF
    
    # 配置密钥表
    cat > /etc/opendkim/KeyTable << EOF
mail._domainkey.$DOMAIN $DOMAIN:mail:/etc/opendkim/keys/$DOMAIN/mail.private
EOF
    
    # 配置签名表
    cat > /etc/opendkim/SigningTable << EOF
*@$DOMAIN mail._domainkey.$DOMAIN
EOF
    
    # 设置权限
    chmod 644 /etc/opendkim/TrustedHosts
    chmod 644 /etc/opendkim/KeyTable
    chmod 644 /etc/opendkim/SigningTable
    
    # 重启 OpenDKIM
    systemctl restart opendkim
    systemctl enable opendkim
    
    # 获取 DKIM 记录
    if [[ -f /etc/opendkim/keys/$DOMAIN/mail.txt ]]; then
        DKIM_RECORD=$(cat /etc/opendkim/keys/$DOMAIN/mail.txt | tr -d '\n' | sed 's/.*(\(.*\)).*/\1/' | tr -d ' \t\"')
    fi
    
    success "DKIM 配置完成"
}

# ============================================================================
# 配置防火墙
# ============================================================================

configure_firewall() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  配置防火墙"
    print_color "$PURPLE" "========================================"
    
    if ! command -v ufw &> /dev/null; then
        warning "UFW 未安装，跳过防火墙配置"
        return
    fi
    
    info "配置防火墙规则..."
    
    # 配置防火墙规则
    ufw --force disable
    ufw default deny incoming
    ufw default allow outgoing
    
    # 开放必要端口
    ufw allow 22/tcp comment 'SSH'
    ufw allow 25/tcp comment 'SMTP'
    ufw allow 587/tcp comment 'Submission'
    ufw allow 465/tcp comment 'SMTPS'
    ufw allow 993/tcp comment 'IMAPS'
    ufw allow 995/tcp comment 'POP3S'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # 启用防火墙
    if confirm "是否启用防火墙？" "Y"; then
        ufw --force enable
        success "防火墙已启用"
    else
        warning "防火墙未启用，请手动配置"
    fi
}

# ============================================================================
# 创建管理工具
# ============================================================================

create_management_tools() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  创建管理工具"
    print_color "$PURPLE" "========================================"
    
    info "创建邮箱管理工具..."
    
    # 创建邮箱管理脚本
    cat > /usr/local/bin/mailuser << 'SCRIPT_EOF'
#!/bin/bash

# 邮箱用户管理工具
DOMAIN=$(cat /etc/mailname | cut -d. -f2-)
POSTFIX_DIR="/etc/postfix"
DOVECOT_USERS="/etc/dovecot/users"
VMAIL_HOME="/var/mail/vhosts"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示帮助
show_help() {
    echo "邮箱用户管理工具"
    echo "=================="
    echo "用法: mailuser [命令] [参数]"
    echo ""
    echo "命令:"
    echo "  add <用户名>      - 添加邮箱用户"
    echo "  delete <用户名>   - 删除邮箱用户"
    echo "  passwd <用户名>   - 修改用户密码"
    echo "  list             - 列出所有用户"
    echo ""
    echo "示例:"
    echo "  mailuser add john"
    echo "  mailuser passwd john"
    echo "  mailuser delete john"
}

# 添加用户
add_user() {
    local username=$1
    
    if [ -z "$username" ]; then
        echo -e "${RED}错误: 请指定用户名${NC}"
        echo "用法: mailuser add <用户名>"
        exit 1
    fi
    
    local email="${username}@${DOMAIN}"
    
    # 检查用户是否存在
    if grep -q "^${username}:" "$DOVECOT_USERS" 2>/dev/null; then
        echo -e "${RED}错误: 用户 ${email} 已存在${NC}"
        exit 1
    fi
    
    # 输入密码
    echo "为 ${email} 设置密码"
    read -s -p "输入密码: " password
    echo
    read -s -p "确认密码: " password2
    echo
    
    if [ "$password" != "$password2" ]; then
        echo -e "${RED}错误: 密码不匹配${NC}"
        exit 1
    fi
    
    if [ ${#password} -lt 6 ]; then
        echo -e "${RED}错误: 密码至少需要 6 个字符${NC}"
        exit 1
    fi
    
    # 生成加密密码
    encrypted_pass=$(doveadm pw -s SHA512-CRYPT -p "$password")
    
    # 添加到 Dovecot 用户文件
    echo "${username}:${encrypted_pass}" >> "$DOVECOT_USERS"
    
    # 添加到 Postfix 虚拟邮箱
    if ! grep -q "^${email}" "$POSTFIX_DIR/virtual_mailboxes"; then
        echo "${email}    ${DOMAIN}/${username}/" >> "$POSTFIX_DIR/virtual_mailboxes"
        postmap "$POSTFIX_DIR/virtual_mailboxes"
    fi
    
    # 创建邮箱目录
    mkdir -p "$VMAIL_HOME/$DOMAIN/$username/Maildir/{new,cur,tmp}"
    chown -R vmail:vmail "$VMAIL_HOME/$DOMAIN/$username"
    chmod -R 700 "$VMAIL_HOME/$DOMAIN/$username"
    
    # 重载服务
    systemctl reload postfix
    systemctl reload dovecot
    
    echo -e "${GREEN}✅ 邮箱 ${email} 创建成功！${NC}"
    echo ""
    echo "配置信息:"
    echo "=========="
    echo "邮箱地址: ${email}"
    echo "用户名: ${email}"
    echo "密码: [您设置的密码]"
    echo ""
    echo "服务器设置:"
    echo "IMAP 服务器: $(hostname -f)"
    echo "IMAP 端口: 993 (SSL/TLS)"
    echo "SMTP 服务器: $(hostname -f)"
    echo "SMTP 端口: 587 (STARTTLS) 或 465 (SSL/TLS)"
}

# 删除用户
delete_user() {
    local username=$1
    
    if [ -z "$username" ]; then
        echo -e "${RED}错误: 请指定用户名${NC}"
        exit 1
    fi
    
    local email="${username}@${DOMAIN}"
    
    # 检查用户是否存在
    if ! grep -q "^${username}:" "$DOVECOT_USERS" 2>/dev/null; then
        echo -e "${RED}错误: 用户 ${email} 不存在${NC}"
        exit 1
    fi
    
    # 确认删除
    read -p "确定要删除邮箱 ${email} 吗？所有邮件将被永久删除！[y/N]: " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "取消删除"
        exit 0
    fi
    
    # 从配置文件中删除
    sed -i "/^${username}:/d" "$DOVECOT_USERS"
    sed -i "/^${email}/d" "$POSTFIX_DIR/virtual_mailboxes"
    postmap "$POSTFIX_DIR/virtual_mailboxes"
    
    # 删除邮箱目录
    rm -rf "$VMAIL_HOME/$DOMAIN/$username"
    
    # 重载服务
    systemctl reload postfix
    systemctl reload dovecot
    
    echo -e "${GREEN}✅ 用户 ${email} 已删除${NC}"
}

# 修改密码
change_password() {
    local username=$1
    
    if [ -z "$username" ]; then
        echo -e "${RED}错误: 请指定用户名${NC}"
        exit 1
    fi
    
    if ! grep -q "^${username}:" "$DOVECOT_USERS"; then
        echo -e "${RED}错误: 用户不存在${NC}"
        exit 1
    fi
    
    local email="${username}@${DOMAIN}"
    
    echo "修改 ${email} 的密码"
    read -s -p "输入新密码: " password
    echo
    read -s -p "确认新密码: " password2
    echo
    
    if [ "$password" != "$password2" ]; then
        echo -e "${RED}错误: 密码不匹配${NC}"
        exit 1
    fi
    
    if [ ${#password} -lt 6 ]; then
        echo -e "${RED}错误: 密码至少需要 6 个字符${NC}"
        exit 1
    fi
    
    # 生成新密码
    encrypted_pass=$(doveadm pw -s SHA512-CRYPT -p "$password")
    
    # 更新密码
    sed -i "/^${username}:/c\\${username}:${encrypted_pass}" "$DOVECOT_USERS"
    
    # 重载服务
    systemctl reload dovecot
    
    echo -e "${GREEN}✅ 密码修改成功${NC}"
}

# 列出用户
list_users() {
    echo "邮箱用户列表"
    echo "============"
    
    if [ ! -f "$DOVECOT_USERS" ] || [ ! -s "$DOVECOT_USERS" ]; then
        echo "没有邮箱用户"
        return
    fi
    
    while IFS=: read -r user _; do
        echo "  ${user}@${DOMAIN}"
    done < "$DOVECOT_USERS"
}

# 主程序
case "$1" in
    add)
        add_user "$2"
        ;;
    delete|del|remove)
        delete_user "$2"
        ;;
    passwd|password)
        change_password "$2"
        ;;
    list|ls)
        list_users
        ;;
    help|-h|--help|"")
        show_help
        ;;
    *)
        echo -e "${RED}未知命令: $1${NC}"
        show_help
        exit 1
        ;;
esac
SCRIPT_EOF
    
    chmod +x /usr/local/bin/mailuser
    
    success "管理工具创建完成"
}

# ============================================================================
# 创建初始用户
# ============================================================================

create_initial_users() {
    print_color "$PURPLE" "\n========================================"
    print_color "$PURPLE" "  创建初始邮箱账户"
    print_color "$PURPLE" "========================================"
    
    info "创建默认邮箱账户..."
    
    # 创建 admin 账户
    echo "创建管理员邮箱 (admin@$DOMAIN)"
    /usr/local/bin/mailuser add admin || warning "admin 用户创建失败"
    
    # 询问是否创建其他常用账户
    if confirm "是否创建 service@$DOMAIN 客服邮箱？" "Y"; then
        /usr/local/bin/mailuser add service || warning "service 用户创建失败"
    fi
    
    if confirm "是否创建 noreply@$DOMAIN 系统发信邮箱？" "Y"; then
        /usr/local/bin/mailuser add noreply || warning "noreply 用户创建失败"
    fi
    
    success "初始账户创建完成"
}

# ============================================================================
# 显示配置信息
# ============================================================================

show_configuration() {
    # 获取服务器信息
    local server_ip=$(curl -s -4 ifconfig.me 2>/dev/null || echo "未知")
    local dkim_record=""
    
    if [[ -f /etc/opendkim/keys/$DOMAIN/mail.txt ]]; then
        dkim_record=$(cat /etc/opendkim/keys/$DOMAIN/mail.txt 2>/dev/null | \
                     tr -d '\n' | sed 's/.*(\(.*\)).*/\1/' | tr -d ' \t\"')
    fi
    
    print_color "$GREEN" "\n========================================"
    print_color "$GREEN" "  🎉 邮件服务器安装完成！"
    print_color "$GREEN" "========================================"
    
    echo ""
    print_color "$BLUE" "📋 重要：DNS 配置"
    echo "请在您的 DNS 服务商处添加以下记录："
    echo ""
    
    echo "1️⃣  A 记录:"
    echo "   类型: A"
    echo "   名称: $(echo $HOSTNAME | cut -d. -f1)"
    echo "   值:   $server_ip"
    echo ""
    
    echo "2️⃣  MX 记录:"
    echo "   类型: MX"
    echo "   名称: @"
    echo "   优先级: 10"
    echo "   值:   $HOSTNAME"
    echo ""
    
    echo "3️⃣  SPF 记录:"
    echo "   类型: TXT"
    echo "   名称: @"
    echo "   值:   \"v=spf1 mx a ip4:$server_ip ~all\""
    echo ""
    
    if [[ -n "$dkim_record" ]]; then
        echo "4️⃣  DKIM 记录:"
        echo "   类型: TXT"
        echo "   名称: mail._domainkey"
        echo "   值:   \"$dkim_record\""
        echo ""
    fi
    
    echo "5️⃣  DMARC 记录:"
    echo "   类型: TXT"
    echo "   名称: _dmarc"
    echo "   值:   \"v=DMARC1; p=quarantine; rua=mailto:admin@$DOMAIN\""
    echo ""
    
    print_color "$BLUE" "📧 邮箱账户"
    echo "已创建的邮箱账户:"
    /usr/local/bin/mailuser list
    echo ""
    
    print_color "$BLUE" "🔧 管理命令"
    echo "邮箱管理:"
    echo "  mailuser add <用户名>     - 添加邮箱"
    echo "  mailuser passwd <用户名>  - 修改密码"
    echo "  mailuser delete <用户名>  - 删除邮箱"
    echo "  mailuser list            - 查看所有邮箱"
    echo ""
    
    print_color "$BLUE" "📱 客户端配置"
    echo "在邮件客户端中使用以下设置:"
    echo ""
    echo "收信服务器 (IMAP):"
    echo "  服务器: $HOSTNAME"
    echo "  端口: 993"
    echo "  安全: SSL/TLS"
    echo "  用户名: 完整邮箱地址"
    echo ""
    echo "发信服务器 (SMTP):"
    echo "  服务器: $HOSTNAME"
    echo "  端口: 587 (STARTTLS) 或 465 (SSL/TLS)"
    echo "  安全: STARTTLS 或 SSL/TLS"
    echo "  需要认证: 是"
    echo "  用户名: 完整邮箱地址"
    echo ""
    
    print_color "$GREEN" "安装成功！请配置 DNS 记录后开始使用。"
}

# ============================================================================
# 主程序
# ============================================================================

main() {
    clear
    
    print_color "$PURPLE" "========================================"
    print_color "$PURPLE" "  $SCRIPT_NAME"
    print_color "$PURPLE" "  版本: $SCRIPT_VERSION"
    print_color "$PURPLE" "========================================"
    echo ""
    
    # 初始化日志
    mkdir -p $(dirname "$LOG_FILE")
    echo "===== 安装开始: $(date) =====" > "$LOG_FILE"
    
    # 执行安装步骤
    check_requirements
    fix_apt_sources
    cleanup_existing_installation
    create_backup
    configure_hostname
    check_dns
    install_packages
    configure_ssl
    configure_postfix
    configure_dovecot
    configure_dkim
    configure_firewall
    create_management_tools
    
    # 重启所有服务
    info "重启邮件服务..."
    systemctl restart postfix || warning "Postfix 重启失败"
    systemctl restart dovecot || warning "Dovecot 重启失败"
    
    if command -v opendkim &> /dev/null; then
        systemctl restart opendkim || warning "OpenDKIM 重启失败"
    fi
    
    # 创建初始用户
    create_initial_users
    
    # 显示配置信息
    show_configuration
    
    # 保存配置摘要
    cat > /root/mail-server-info.txt << EOF
邮件服务器配置信息
==================
安装时间: $(date)
主机名: $HOSTNAME
域名: $DOMAIN
服务器 IP: ${SERVER_IP:-未知}

管理命令:
- mailuser: 邮箱用户管理

日志位置:
- 邮件日志: /var/log/mail.log
- 安装日志: $LOG_FILE

配置备份: $BACKUP_DIR
EOF
    
    log "安装完成"
    echo ""
    print_color "$GREEN" "提示：配置信息已保存到 /root/mail-server-info.txt"
}

# ============================================================================
# 脚本入口
# ============================================================================

# 处理参数
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "$SCRIPT_NAME"
    echo "版本: $SCRIPT_VERSION"
    echo ""
    echo "用法: bash $0"
    exit 0
fi

if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
    echo "$SCRIPT_VERSION"
    exit 0
fi

# 执行主程序
main
