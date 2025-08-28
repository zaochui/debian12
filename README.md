# Debian 12 Mail Server Auto Install Script

[中文](#中文说明) | [English](#english-description)

## 中文说明

一个强大的 Bash 脚本，用于在全新的 Debian 12 系统上自动安装和配置完整的邮件服务器 (Postfix + Dovecot)，并自动申请 Let's Encrypt SSL 证书。

### 🚀 功能特性

-   **全自动安装**: 无需手动干预，自动安装和配置 Postfix 和 Dovecot。
-   **Let's Encrypt SSL**: 自动获取并配置受信任的 SSL 证书。
-   **安全默认配置**: 强制使用 TLS 加密，采用现代安全实践。
-   **UFW 防火墙设置**: 如果防火墙已启用，会自动配置所需规则。
-   **详细使用指南**: 提供清晰易懂的安装后操作说明。

### 📋 先决条件

运行脚本前，您**必须**确保：
1.  拥有一个域名 (例如 `example.com`)。
2.  已将您服务器的主机名 (例如 `mail.example.com`) 的 DNS `A` 记录指向您服务器的**公网 IP 地址**。这是申请 SSL 证书的**必要条件**。
3.  一台全新的 Debian 12 VPS 或服务器。

### 🛠️ 使用方法

1.  **设置主机名**:
