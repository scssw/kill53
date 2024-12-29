#!/bin/bash

# 写入新的 resolved.conf 配置
cat <<EOL > /etc/systemd/resolved.conf
[Resolve]
DNS=8.8.8.8 1.1.1.1
#FallbackDNS=
#Domains=
#LLMNR=no
#MulticastDNS=no
#DNSSEC=no
#Cache=yes
DNSStubListener=no
EOL

# 更新 /etc/resolv.conf 的符号链接
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# 重启 systemd-resolved 服务
systemctl restart systemd-resolved.service

echo "已成功更新 /etc/systemd/resolved.conf 并重启 systemd-resolved 服务。"
