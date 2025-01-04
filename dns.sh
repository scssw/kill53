#!/bin/bash

# 删除 /etc/resolv.conf 符号链接
echo "删除符号链接 /etc/resolv.conf ..."
sudo rm -f /etc/resolv.conf

# 创建新的静态 /etc/resolv.conf 文件
echo "创建新的 /etc/resolv.conf 文件 ..."
echo -e "nameserver 127.0.0.1\nnameserver 127.0.0.1" | sudo tee /etc/resolv.conf > /dev/null

# 设置文件只读权限
echo "设置文件只读权限 ..."
sudo chmod 444 /etc/resolv.conf

# 禁用 systemd-resolved 服务
echo "禁用 systemd-resolved 服务 ..."
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# 完成提示
echo "DNS 配置已更新，systemd-resolved 服务已禁用。"
