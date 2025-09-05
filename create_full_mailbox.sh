#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then 
    print_error "请使用root权限运行此脚本"
    exit 1
fi

# 交互式输入
echo "========================================="
echo "   Postfix + Dovecot 邮箱创建工具"
echo "========================================="
echo ""

# 如果提供了命令行参数，使用参数；否则交互式输入
if [ $# -eq 2 ]; then
    EMAIL=$1
    PASSWORD=$2
    print_info "使用命令行参数创建邮箱: $EMAIL"
else
    # 输入邮箱地址
    while true; do
        read -p "请输入邮箱地址 (例如: user@example.com): " EMAIL
        if [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            print_error "邮箱地址格式不正确，请重新输入"
        fi
    done

    # 输入密码
    while true; do
        read -s -p "请输入密码 (至少6位): " PASSWORD
        echo ""
        if [ ${#PASSWORD} -ge 6 ]; then
            read -s -p "请确认密码: " PASSWORD_CONFIRM
            echo ""
            if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
                break
            else
                print_error "两次输入的密码不一致，请重新输入"
            fi
        else
            print_error "密码长度至少需要6位"
        fi
    done
fi

# 解析域名和用户名
DOMAIN=$(echo $EMAIL | cut -d@ -f2)
USER=$(echo $EMAIL | cut -d@ -f1)

echo ""
print_info "开始创建邮箱: $EMAIL"
echo "----------------------------------------"

# 1. 检查并创建vmail用户和组
if ! id -u vmail >/dev/null 2>&1; then
    print_info "创建vmail用户和组..."
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 vmail -d /var/mail/vhosts -s /sbin/nologin
fi

# 2. 创建邮箱目录
print_info "创建邮箱目录..."
mkdir -p /var/mail/vhosts/$DOMAIN/$USER/{cur,new,tmp}
chown -R vmail:vmail /var/mail/vhosts/$DOMAIN
chmod -R 770 /var/mail/vhosts/$DOMAIN/$USER

# 3. 创建必要的Postfix配置文件（如果不存在）
if [ ! -f /etc/postfix/vmailbox ]; then
    print_info "创建Postfix虚拟邮箱文件..."
    touch /etc/postfix/vmailbox
    postmap /etc/postfix/vmailbox
fi

if [ ! -f /etc/postfix/virtual_domains ]; then
    print_info "创建虚拟域名文件..."
    touch /etc/postfix/virtual_domains
    postmap /etc/postfix/virtual_domains
fi

# 4. 添加域名到虚拟域名列表
if ! grep -q "^$DOMAIN" /etc/postfix/virtual_domains 2>/dev/null; then
    print_info "添加域名 $DOMAIN 到虚拟域名列表..."
    echo "$DOMAIN OK" >> /etc/postfix/virtual_domains
    postmap /etc/postfix/virtual_domains
fi

# 5. 添加邮箱到虚拟邮箱映射
print_info "配置Postfix虚拟邮箱..."
if grep -q "^$EMAIL" /etc/postfix/vmailbox 2>/dev/null; then
    print_warning "邮箱 $EMAIL 已存在于Postfix配置中，更新配置..."
    sed -i "/^$EMAIL/d" /etc/postfix/vmailbox
fi
echo "$EMAIL    $DOMAIN/$USER/" >> /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox

# 6. 创建Dovecot用户文件（如果不存在）
if [ ! -f /etc/dovecot/users ]; then
    print_info "创建Dovecot用户文件..."
    touch /etc/dovecot/users
    chmod 600 /etc/dovecot/users
fi

# 7. 生成加密密码并添加到Dovecot
print_info "配置Dovecot认证..."

# 检查doveadm是否存在
if command -v doveadm &> /dev/null; then
    ENCRYPTED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")
else
    print_warning "doveadm未找到，使用openssl生成密码..."
    SALT=$(openssl rand -base64 16)
    ENCRYPTED_PASS=$(openssl passwd -6 -salt "$SALT" "$PASSWORD")
    ENCRYPTED_PASS="{SHA512-CRYPT}$ENCRYPTED_PASS"
fi

# 更新或添加用户到Dovecot
if grep -q "^$EMAIL:" /etc/dovecot/users 2>/dev/null; then
    print_warning "用户 $EMAIL 已存在于Dovecot中，更新密码..."
    sed -i "/^$EMAIL:/d" /etc/dovecot/users
fi
echo "$EMAIL:$ENCRYPTED_PASS:vmail:vmail::/var/mail/vhosts/$DOMAIN/$USER" >> /etc/dovecot/users

# 8. 创建发信权限文件（如果需要）
if [ ! -f /etc/postfix/sender_access ]; then
    print_info "创建发信权限文件..."
    touch /etc/postfix/sender_access
    postmap /etc/postfix/sender_access
fi

if ! grep -q "^$EMAIL" /etc/postfix/sender_access 2>/dev/null; then
    print_info "设置发信权限..."
    echo "$EMAIL OK" >> /etc/postfix/sender_access
    postmap /etc/postfix/sender_access
fi

# 9. 检查Postfix配置
print_info "检查Postfix配置..."
if ! postconf | grep -q "virtual_mailbox_domains"; then
    print_warning "检测到Postfix可能未配置虚拟邮箱，添加基础配置..."
    postconf -e "virtual_mailbox_domains = hash:/etc/postfix/virtual_domains"
    postconf -e "virtual_mailbox_base = /var/mail/vhosts"
    postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
    postconf -e "virtual_minimum_uid = 100"
    postconf -e "virtual_uid_maps = static:5000"
    postconf -e "virtual_gid_maps = static:5000"
fi

# 10. 检查Dovecot认证socket
if [ ! -S /var/spool/postfix/private/auth ]; then
    print_warning "Dovecot认证socket不存在，可能需要配置Dovecot..."
fi

# 11. 重载服务
print_info "重载邮件服务..."
systemctl reload postfix 2>/dev/null || service postfix reload 2>/dev/null
systemctl reload dovecot 2>/dev/null || service dovecot reload 2>/dev/null

# 12. 测试账号
echo ""
echo "========================================="
print_info "${GREEN}邮箱创建成功！${NC}"
echo "========================================="
echo ""
echo "邮箱信息："
echo "  邮箱地址: $EMAIL"
echo "  邮箱目录: /var/mail/vhosts/$DOMAIN/$USER"
echo ""
echo "客户端配置信息："
echo "  IMAP服务器: $(hostname -f)"
echo "  IMAP端口: 143 (STARTTLS) / 993 (SSL/TLS)"
echo "  SMTP服务器: $(hostname -f)"
echo "  SMTP端口: 587 (STARTTLS) / 465 (SSL/TLS)"
echo "  用户名: $EMAIL"
echo "  密码: [您设置的密码]"
echo ""

# 测试认证
if command -v doveadm &> /dev/null; then
    echo "正在测试账号认证..."
    if doveadm auth test "$EMAIL" "$PASSWORD" 2>/dev/null; then
        print_info "✓ Dovecot认证测试成功"
    else
        print_warning "✗ Dovecot认证测试失败，请检查配置"
    fi
fi

echo ""
echo "提示："
echo "  1. 如果这是第一次创建邮箱，请确保Postfix和Dovecot已正确配置"
echo "  2. 使用 'tail -f /var/log/mail.log' 查看邮件日志"
echo "  3. 使用 'postfix check' 检查Postfix配置"
echo "  4. 使用 'dovecot -n' 查看Dovecot配置"
echo ""

# 询问是否创建另一个邮箱
if [ $# -eq 0 ]; then
    read -p "是否创建另一个邮箱？(y/n): " CREATE_ANOTHER
    if [[ "$CREATE_ANOTHER" =~ ^[Yy]$ ]]; then
        exec "$0"
    fi
fi

exit 0
