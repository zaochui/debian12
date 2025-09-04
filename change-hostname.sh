#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 sudo 或以 root 用户运行此脚本。"
    exit 1
fi

# 输入新主机名
read -p "请输入新的主机名（仅允许字母/数字/连字符）: " NEW_NAME

# 验证主机名格式
if ! [[ "$NEW_NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,63}$ ]]; then
    echo "错误：主机名格式无效！"
    echo "规则：以字母开头，仅包含字母/数字/连字符，长度1-64字符。"
    exit 1
fi

# 获取旧主机名
OLD_NAME=$(hostname)

# 修改主机名
hostnamectl set-hostname "$NEW_NAME"

# 更新 /etc/hosts
sed -i "s/$OLD_NAME/$NEW_NAME/g" /etc/hosts

# 验证修改
echo -e "\n✅ 修改完成！"
echo -e "当前主机名: $(hostname)"
echo -e "静态主机名: $(hostnamectl --static)"
echo -e "/etc/hosts 内容:\n$(grep "$NEW_NAME" /etc/hosts)"

# 提示重启
echo -e "\n建议重启系统以使所有服务生效："
echo "sudo reboot"
