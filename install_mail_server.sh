#!/bin/bash

# Debian 12 Postfix + Dovecot + Let's Encrypt 一键安装脚本
set -e # 遇到任何错误立即退出脚本

echo "========================================"
echo "  Debian 12 邮件服务器一键安装脚本"
echo "========================================"
echo ""

# 1. 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo "错误：此脚本必须以 root 权限运行。请使用 'sudo bash $0'" 
   exit 1
fi

# 2. 获取并显示当前主机名
CURRENT_HOSTNAME=$(hostname -f)
echo "当前服务器的主机名 (FQDN) 是: $CURRENT_HOSTNAME"
echo ""
echo "⚠️  请注意：此主机名必须已是您域名的 DNS 'A' 记录，并指向本服务器IP。"
echo "   这是成功申请 Let's Encrypt SSL 证书的必要条件。"
echo ""
read -p "请确认您的主机名和DNS解析已正确设置 (y/N)? " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "请先使用 'hostnamectl set-hostname mail.yourdomain.com' 命令设置正确的主机名，并配置好DNS解析后再运行此脚本。"
    exit 1
fi

# 3. 安装必要的软件包
echo "➡️  第 1 步：更新软件包列表并安装必要的软件..."
apt update
apt install -y wget

# 安装 Certbot
apt install -y certbot

# 使用 debconf 预先设置 Postfix 的配置，实现完全无人值守安装
echo "postfix postfix/mailname string $CURRENT_HOSTNAME" | debconf-set-selections
echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections

# 安装邮件服务核心软件
apt install -y postfix dovecot-imapd dovecot-pop3d dovecot-sieve dovecot-managesieved

echo "✅ 软件安装完成。"

# 4. 防火墙 (UFW) 配置
echo ""
echo "➡️  第 2 步：配置防火墙..."

# 检查是否安装了 UFW
if ! command -v ufw &> /dev/null; then
    echo "UFW 未安装，现在为您安装并启用..."
    apt install -y ufw
    ufw enable
fi

# 检查 UFW 状态
UFW_STATUS=$(ufw status | grep Status | cut -d ' ' -f 2)
if [[ "$UFW_STATUS" == "active" ]]; then
    echo "检测到 UFW 已启用，正在开放邮件服务所需端口 (25, 587, 993, 995) 和证书申请端口 (80, 443)..."
    ufw allow 25/tcp    # SMTP
    ufw allow 587/tcp   # SMTP Submission (MSA)
    ufw allow 993/tcp   # IMAPS
    ufw allow 995/tcp   # POP3S
    ufw allow 80/tcp    # HTTP (用于 Certbot 证书申请)
    ufw allow 443/tcp   # HTTPS (也可用于 Certbot)
    echo "✅ 防火墙规则已添加。"
else
    echo "⚠️  UFW 处于禁用状态。脚本不会配置防火墙规则。"
    echo "    如果您需要启用防火墙，请手动运行 'ufw enable' 并开放以下端口："
    echo "    25/tcp (SMTP), 587/tcp (Submission), 993/tcp (IMAPS), 995/tcp (POP3S), 80/tcp (HTTP), 443/tcp (HTTPS)"
fi

# 5. 申请 Let's Encrypt SSL 证书
echo ""
echo "➡️  第 3 步：申请 Let's Encrypt SSL 证书..."

# 临时停止可能占用80端口的服务（如 nginx, apache），如果存在的话
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

# 申请证书
if certbot certonly --standalone -d "$CURRENT_HOSTNAME" --agree-tos --non-interactive --preferred-challenges http; then
    echo "✅ SSL 证书申请成功！"
    SSL_CERT="/etc/letsencrypt/live/$CURRENT_HOSTNAME/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$CURRENT_HOSTNAME/privkey.pem"
else
    echo "❌ 证书申请失败！这通常是因为DNS解析未设置或未生效。"
    echo "   脚本将继续使用自签名证书作为备选方案。"
    echo "   您以后可以手动运行 'certbot certonly --standalone -d $CURRENT_HOSTNAME' 来申请证书。"
    # 生成自签名证书作为备选
    mkdir -p /etc/ssl/private
    mkdir -p /etc/ssl/certs
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/private/$CURRENT_HOSTNAME.key \
        -out /etc/ssl/certs/$CURRENT_HOSTNAME.crt \
        -subj "/CN=$CURRENT_HOSTNAME"
    SSL_CERT="/etc/ssl/certs/$CURRENT_HOSTNAME.crt"
    SSL_KEY="/etc/ssl/private/$CURRENT_HOSTNAME.key"
fi

# 6. 配置 Postfix
echo ""
echo "➡️  第 4 步：配置 Postfix..."

# 备份原始配置
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup

# 生成主配置
cat > /etc/postfix/main.cf << EOF
# 基础设置
smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no
append_dot_mydomain = no
readme_directory = no

# 服务器识别
myhostname = $CURRENT_HOSTNAME
mydomain = $(echo $CURRENT_HOSTNAME | cut -d. -f2-)
myorigin = /etc/mailname
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
relayhost = 

# 网络限制（根据你的需求调整，这里限制为本地和私有网络）
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

# TLS 加密设置
smtpd_use_tls = yes
smtpd_tls_cert_file = $SSL_CERT
smtpd_tls_key_file = $SSL_KEY
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtpd_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3
smtpd_tls_ciphers = medium

# SMTP 认证 (通过 Dovecot)
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname
broken_sasl_auth_clients = yes

# 邮件策略和限制
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_helo_hostname, reject_non_fqdn_helo_hostname, reject_unknown_helo_hostname
smtpd_sender_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_sender, reject_unknown_sender_domain

# 邮件投递和格式
mailbox_size_limit = 0
recipient_delimiter = +
local_transport = error:local delivery is disabled
virtual_transport = dovecot
dovecot_destination_recipient_limit = 1

# 启用 Dovecot LMTP 进行本地投递
virtual_transport = lmtp:unix:private/dovecot-lmtp

# 启用 Maildir 格式
home_mailbox = Maildir/
EOF

# 启用 Submission 端口 (587) 用于认证发信
sed -i '/^#submission.*inet.*n.*smtpd/ s/^#//' /etc/postfix/master.cf
sed -i '/^#.*smtpd.*-o.*smtpd_sasl_auth_enable=yes/ s/^#//' /etc/postfix/master.cf

echo "✅ Postfix 配置完成。"

# 7. 配置 Dovecot
echo ""
echo "➡️  第 5 步：配置 Dovecot..."

# 配置认证
cat > /etc/dovecot/conf.d/10-auth.conf << EOF
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-system.conf.ext
EOF

# 配置邮件存储格式 (Maildir)
cat > /etc/dovecot/conf.d/10-mail.conf << EOF
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
}
EOF

# 配置 SSL
cat > /etc/dovecot/conf.d/10-ssl.conf << EOF
ssl = required
ssl_cert = <$SSL_CERT
ssl_key = <$SSL_KEY
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
EOF

echo "✅ Dovecot 配置完成。"

# 8. 重启服务
echo ""
echo "➡️  第 6 步：重启服务并使配置生效..."
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

# 9. 最终检查和服务状态验证
echo ""
echo "➡️  服务状态检查..."
echo "Postfix 状态:"
systemctl status postfix --no-pager -l
echo ""
echo "Dovecot 状态:"
systemctl status dovecot --no-pager -l

echo ""
echo "📨 端口监听检查 (您应该看到以下端口处于 LISTEN 状态):"
ss -tulpn | grep -E ':25|:587|:993|:995'

# 10. 输出最终用户指南
echo ""
echo "========================================"
echo "🎉 邮件服务器安装完成！"
echo "========================================"
echo ""
echo "📋 接下来您需要做的是："
echo ""
echo "1.  📝 创建邮件用户："
echo "    您的邮件账户就是系统用户。请使用以下命令创建用户："
echo "    # adduser username"
echo "    按提示为 'username' 设置一个强密码。"
echo ""
echo "2.  📱 配置邮件客户端 (如 Outlook, Thunderbird, 手机邮件APP)："
echo "    - 服务器地址: $CURRENT_HOSTNAME"
echo "    - 用户名: 您创建的系统用户名 (完整地址，如 user@$CURRENT_HOSTNAME)"
echo "    - 密码: 该用户的系统密码"
echo "    - 端口和加密类型:"
echo "        * IMAP: 端口 993, SSL/TLS 加密"
echo "        * SMTP: 端口 587, STARTTLS 加密"
echo ""
echo "3.  🔐 SSL 证书:"
echo "    您的证书已由 Let's Encrypt 自动管理，将于 90 天后自动续期，无需手动干预。"
echo ""
echo "4.  📊 日志文件:"
echo "    - 邮件日志: /var/log/mail.log"
echo "    - Dovecot 日志: /var/log/dovecot.log"
echo ""
echo "5.  🧪 测试:"
echo "    建议使用命令 'apt install mailutils' 安装邮件工具，然后运行"
echo "    # echo \"这是一封测试邮件\" | mail -s \"测试主题\" your@email.com"
echo "    来发送一封测试邮件。"
echo ""
echo "祝您使用愉快！"
