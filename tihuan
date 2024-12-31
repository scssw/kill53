#!/bin/bash

# 配置文件路径（请根据实际路径修改）
CONFIG_FILE="/etc/dnsmasq.conf"

# 替换操作
sed -i 's/^server=8.8.8.8$/# 使用 Google DNS 和 Cloudflare DNS 作为备选\nserver=8.8.8.8\nserver=1.1.1.1/' "$CONFIG_FILE"

echo "替换完成！"
