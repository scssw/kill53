#!/bin/bash

# 更新系统
sudo apt update

# 安装Certbot和Nginx插件
sudo apt install -y certbot python3-certbot-nginx

# 输入域名
read -p "请输入你的域名: " domain

# 申请SSL证书
sudo certbot --nginx -d $domain -d www.$domain

# 测试自动续期
sudo certbot renew --dry-run

echo "SSL证书申请完成！"
