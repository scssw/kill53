#!/bin/bash

# 一键申请Cloudflare SSL证书脚本

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：必须使用root权限运行此脚本！${plain}" && exit 1

# 安装依赖
install_dependencies() {
    echo -e "${yellow}正在安装必要依赖...${plain}"
    if command -v apt &>/dev/null; then
        apt update && apt install -y socat curl
    elif command -v yum &>/dev/null; then
        yum update -y && yum install -y socat curl
    elif command -v dnf &>/dev/null; then
        dnf update -y && dnf install -y socat curl
    else
        echo -e "${red}不支持的包管理器，请手动安装socat和curl${plain}"
        exit 1
    fi
}

# 安装acme.sh
install_acme() {
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo -e "${yellow}正在安装acme.sh...${plain}"
        curl https://get.acme.sh | sh
        [ $? -ne 0 ] && echo -e "${red}acme.sh安装失败${plain}" && exit 1
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
}

# 获取用户输入
get_user_input() {
    echo -e "${green}请输入Cloudflare注册邮箱：${plain}"
    read CF_AccountEmail
    echo -e "${green}请输入Cloudflare Global API Key：${plain}"
    read CF_GlobalKey
    echo -e "${green}请输入要申请证书的域名（例如example.com）：${plain}"
    read CF_Domain
}

# 申请证书
issue_certificate() {
    echo -e "${yellow}正在申请证书...${plain}"
    export CF_Key="${CF_GlobalKey}"
    export CF_Email="${CF_AccountEmail}"
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${CF_Domain}" -d "*.${CF_Domain}" --log
    
    if [ $? -ne 0 ]; then
        echo -e "${red}证书申请失败，请检查输入信息${plain}"
        exit 1
    fi
}

# 安装证书
install_certificate() {
    cert_path="/root/cert/${CF_Domain}"
    mkdir -p "${cert_path}"
    
    ~/.acme.sh/acme.sh --installcert -d "${CF_Domain}" -d "*.${CF_Domain}" \
        --fullchain-file "${cert_path}/fullchain.pem" \
        --key-file "${cert_path}/privkey.pem"
    
    chmod 755 "${cert_path}"/*
    echo -e "${green}证书已保存到：${cert_path}${plain}"
}

# 主流程
main() {
    install_dependencies
    install_acme
    get_user_input
    issue_certificate
    install_certificate
    
    echo -e "${green}SSL证书申请成功！证书文件路径：${plain}"
    ls -lah "/root/cert/${CF_Domain}/"
}

# 执行主函数
main
