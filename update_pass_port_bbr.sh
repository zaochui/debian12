#!/bin/bash

# Debian 12 一键优化配置脚本
# 功能：修改用户密码、修改SSH端口、系统更新、安装BBR
# 作者：System Admin Tools
# 版本：1.0

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查是否为root用户或使用sudo
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以root权限运行"
        print_info "请使用: sudo bash $0"
        exit 1
    fi
}

# 检查系统是否为Debian 12
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" ]] || [[ "$VERSION_ID" != "12" ]]; then
            print_warning "此脚本专为 Debian 12 设计，当前系统：$ID $VERSION_ID"
            read -p "是否继续？(y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        print_error "无法确定操作系统版本"
        exit 1
    fi
}

# 1. 修改当前用户密码
change_user_password() {
    print_info "========== 修改用户密码 =========="
    
    # 获取当前实际用户（处理sudo情况）
    if [ -n "$SUDO_USER" ]; then
        CURRENT_USER=$SUDO_USER
    else
        CURRENT_USER=$(whoami)
    fi
    
    print_info "当前用户: $CURRENT_USER"
    
    # 循环直到密码设置成功
    while true; do
        print_info "请输入新密码（密码输入时不会显示）："
        read -s PASSWORD1
        echo
        
        # 检查密码是否为空
        if [ -z "$PASSWORD1" ]; then
            print_error "密码不能为空，请重新输入"
            continue
        fi
        
        print_info "请再次输入新密码："
        read -s PASSWORD2
        echo
        
        # 检查两次密码是否一致
        if [ "$PASSWORD1" != "$PASSWORD2" ]; then
            print_error "两次输入的密码不一致，请重新输入"
            continue
        fi
        
        # 修改密码
        echo "$CURRENT_USER:$PASSWORD1" | chpasswd
        if [ $? -eq 0 ]; then
            print_success "用户 $CURRENT_USER 的密码修改成功"
            break
        else
            print_error "密码修改失败，请重试"
        fi
    done
}

# 2. 修改SSH端口
change_ssh_port() {
    print_info "========== 修改SSH端口 =========="
    
    SSHD_CONFIG="/etc/ssh/sshd_config"
    
    # 备份原配置文件
    if [ ! -f "${SSHD_CONFIG}.bak" ]; then
        cp $SSHD_CONFIG ${SSHD_CONFIG}.bak
        print_info "已备份SSH配置文件到 ${SSHD_CONFIG}.bak"
    fi
    
    # 获取当前SSH端口
    CURRENT_PORT=$(grep "^Port\|^#Port" $SSHD_CONFIG | awk '{print $2}' | head -1)
    if [ -z "$CURRENT_PORT" ]; then
        CURRENT_PORT=22
    fi
    
    print_info "当前SSH端口: $CURRENT_PORT"
    
    # 输入新端口
    while true; do
        read -p "请输入新的SSH端口 (1-65535): " NEW_PORT
        
        # 验证端口号
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
            print_error "端口必须是数字"
            continue
        fi
        
        if [ $NEW_PORT -lt 1 ] || [ $NEW_PORT -gt 65535 ]; then
            print_error "端口必须在1-65535之间"
            continue
        fi
        
        # 对于低端口给出提醒
        if [ $NEW_PORT -lt 1024 ]; then
            print_warning "端口 $NEW_PORT 是系统保留端口（<1024），通常用于系统服务"
            read -p "确定要使用此端口吗？(y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        
        # 检查端口是否被占用
        if ss -tuln | grep -q ":$NEW_PORT "; then
            print_error "端口 $NEW_PORT 已被占用，请选择其他端口"
            continue
        fi
        
        # 对一些常用端口给出警告
        case $NEW_PORT in
            80|443|21|25|110|143|3306|5432|6379|27017)
                print_warning "端口 $NEW_PORT 通常用于其他服务（HTTP/HTTPS/FTP/Mail/Database等）"
                read -p "确定要使用此端口吗？(y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    continue
                fi
                ;;
        esac
        
        break
    done
    
    # 修改SSH配置
    sed -i "s/^#\?Port .*/Port $NEW_PORT/" $SSHD_CONFIG
    
    # 配置防火墙（如果安装了ufw）
    if command -v ufw &> /dev/null; then
        print_info "配置防火墙规则..."
        ufw allow $NEW_PORT/tcp
        if [ "$CURRENT_PORT" != "$NEW_PORT" ]; then
            print_warning "记得稍后删除旧端口的防火墙规则: ufw delete allow $CURRENT_PORT/tcp"
        fi
    fi
    
    # 重启SSH服务
    print_info "重启SSH服务..."
    systemctl restart sshd || systemctl restart ssh
    
    if [ $? -eq 0 ]; then
        print_success "SSH端口已成功修改为: $NEW_PORT"
        print_warning "请记住新端口号！下次连接请使用: ssh -p $NEW_PORT user@host"
    else
        print_error "SSH服务重启失败，请检查配置"
    fi
}

# 3. 系统更新和清理
system_update_cleanup() {
    print_info "========== 系统更新和清理 =========="
    
    print_info "更新软件包列表..."
    apt update
    
    print_info "升级所有软件包..."
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
    
    print_info "执行完整系统升级..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
    
    print_info "清理不需要的软件包..."
    apt autoremove -y
    
    print_info "清理软件包缓存..."
    apt autoclean
    apt clean
    
    # 清理系统日志（保留最近7天）
    print_info "清理系统日志..."
    journalctl --vacuum-time=7d
    
    # 清理临时文件
    print_info "清理临时文件..."
    find /tmp -type f -atime +7 -delete 2>/dev/null || true
    find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
    
    print_success "系统更新和清理完成"
}

# 4. 安装和启用BBR
install_bbr() {
    print_info "========== 安装BBR =========="
    
    # 检查内核版本（BBR需要4.9+）
    KERNEL_VERSION=$(uname -r | cut -d. -f1,2)
    KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)
    
    if [ "$KERNEL_MAJOR" -lt 4 ] || ([ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]); then
        print_error "BBR需要Linux内核4.9或更高版本，当前版本: $(uname -r)"
        print_info "请先升级内核"
        return 1
    fi
    
    # 检查BBR是否已启用
    if lsmod | grep -q bbr; then
        print_info "BBR已经启用"
        sysctl net.ipv4.tcp_congestion_control
        return 0
    fi
    
    # 启用BBR
    print_info "配置BBR..."
    
    # 添加BBR配置到sysctl.conf
    cat >> /etc/sysctl.conf << EOF

# BBR Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    
    # 应用配置
    sysctl -p
    
    # 验证BBR是否启用
    if lsmod | grep -q bbr; then
        print_success "BBR已成功启用"
        sysctl net.ipv4.tcp_congestion_control
        sysctl net.core.default_qdisc
    else
        print_error "BBR启用失败"
        return 1
    fi
}

# 显示系统信息
show_system_info() {
    print_info "========== 系统信息 =========="
    echo "主机名: $(hostname)"
    echo "系统版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "内核版本: $(uname -r)"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
    echo "内存: $(free -h | grep Mem | awk '{print $2}')"
    echo "磁盘: $(df -h / | tail -1 | awk '{print $2}')"
    echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

# 主菜单
main_menu() {
    clear
    echo "╔══════════════════════════════════════════════╗"
    echo "║       Debian 12 系统优化配置脚本 v1.0        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "请选择要执行的操作："
    echo "1) 执行所有优化（推荐）"
    echo "2) 仅修改用户密码"
    echo "3) 仅修改SSH端口"
    echo "4) 仅更新系统和清理"
    echo "5) 仅安装BBR"
    echo "6) 显示系统信息"
    echo "0) 退出"
    echo ""
    read -p "请输入选项 [0-6]: " choice
    
    case $choice in
        1)
            change_user_password
            echo ""
            change_ssh_port
            echo ""
            system_update_cleanup
            echo ""
            install_bbr
            echo ""
            print_success "所有优化配置已完成！"
            ;;
        2)
            change_user_password
            ;;
        3)
            change_ssh_port
            ;;
        4)
            system_update_cleanup
            ;;
        5)
            install_bbr
            ;;
        6)
            show_system_info
            ;;
        0)
            print_info "退出脚本"
            exit 0
            ;;
        *)
            print_error "无效的选项"
            sleep 2
            main_menu
            ;;
    esac
    
    echo ""
    read -p "按Enter键返回主菜单，按Ctrl+C退出..."
    main_menu
}

# 主程序入口
main() {
    clear
    
    # 检查权限
    check_root
    
    # 检查系统
    check_system
    
    # 显示主菜单
    main_menu
}

# 捕获Ctrl+C
trap 'echo ""; print_warning "脚本被用户中断"; exit 1' INT

# 运行主程序
main
