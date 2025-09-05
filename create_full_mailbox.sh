#!/bin/bash

# 检查参数
if [ $# -ne 2 ]; then
    echo "用法: $0 <邮箱地址> <密码>"
    echo "示例: $0 user@example.com password123"
    exit 1
fi

EMAIL=$1
PASSWORD=$2
DOMAIN=$(echo $EMAIL | cut -d@ -f2)
USER=$(echo $EMAIL | cut -d@ -f1)

echo "创建邮箱: $EMAIL"

# 1. 创建邮箱目录
echo "创建邮箱目录..."
sudo mkdir -p /var/mail/vhosts/$DOMAIN/$USER/{cur,new,tmp}
sudo chown -R vmail:vmail /var/mail/vhosts/$DOMAIN

# 2. 添加到Postfix虚拟邮箱映射（收信配置）
echo "配置Postfix虚拟邮箱..."
if ! grep -q "^$EMAIL" /etc/postfix/vmailbox; then
    echo "$EMAIL    $DOMAIN/$USER/" | sudo tee -a /etc/postfix/vmailbox
    sudo postmap /etc/postfix/vmailbox
fi

# 3. 添加虚拟域名（如果不存在）
if ! grep -q "^$DOMAIN" /etc/postfix/virtual_domains; then
    echo "$DOMAIN OK" | sudo tee -a /etc/postfix/virtual_domains
    sudo postmap /etc/postfix/virtual_domains
fi

# 4. 生成加密密码并添加到Dovecot（认证配置）
echo "配置Dovecot认证..."
ENCRYPTED_PASS=$(doveadm pw -s SHA512-CRYPT -p $PASSWORD)
if ! grep -q "^$EMAIL:" /etc/dovecot/users; then
    echo "$EMAIL:$ENCRYPTED_PASS:vmail:vmail::/var/mail/vhosts/$DOMAIN/$USER" | sudo tee -a /etc/dovecot/users
else
    # 更新现有密码
    sudo sed -i "/^$EMAIL:/d" /etc/dovecot/users
    echo "$EMAIL:$ENCRYPTED_PASS:vmail:vmail::/var/mail/vhosts/$DOMAIN/$USER" | sudo tee -a /etc/dovecot/users
fi

# 5. 设置发信权限（sender_access）
echo "设置发信权限..."
if [ ! -f /etc/postfix/sender_access ]; then
    sudo touch /etc/postfix/sender_access
fi
if ! grep -q "^$EMAIL" /etc/postfix/sender_access; then
    echo "$EMAIL OK" | sudo tee -a /etc/postfix/sender_access
    sudo postmap /etc/postfix/sender_access
fi

# 6. 重载服务
echo "重载服务..."
sudo systemctl reload postfix
sudo systemctl reload dovecot

echo ""
echo "邮箱创建成功！"
echo "=================="
echo "邮箱地址: $EMAIL"
echo "IMAP服务器: mail.example.com"
echo "IMAP端口: 143 (STARTTLS) / 993 (SSL/TLS)"
echo "SMTP服务器: mail.example.com"
echo "SMTP端口: 587 (STARTTLS) / 465 (SSL/TLS)"
echo "用户名: $EMAIL"
echo "密码: [您设置的密码]"
echo ""
echo "测试命令："
echo "  收信测试: doveadm auth test $EMAIL"
echo "  发信测试: swaks --to someone@gmail.com --from $EMAIL --auth --auth-user=$EMAIL --server localhost:587"
