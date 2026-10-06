#!/bin/bash

# 一键申请Cloudflare SSL证书脚本

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 凭据文件仅保存邮箱和密钥，各占一行，仅root可读
CREDENTIALS_FILE="/root/.dnsssl_credentials"
SCRIPT_PATH="$(readlink -f "$0")"

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

# 保存凭据
save_credentials() {
    umask 077
    printf '%s\n%s\n' "${CF_AccountEmail}" "${CF_GlobalKey}" > "${CREDENTIALS_FILE}"
    chmod 600 "${CREDENTIALS_FILE}"
}

# 读取已保存的凭据
load_credentials() {
    local saved_email='' saved_key=''

    [[ -f "${CREDENTIALS_FILE}" ]] || return 1
    IFS= read -r saved_email < "${CREDENTIALS_FILE}"
    IFS= read -r saved_key < <(sed -n '2p' "${CREDENTIALS_FILE}")

    [[ -n "${saved_email}" && -n "${saved_key}" ]] || return 1
    CF_AccountEmail="${saved_email}"
    CF_GlobalKey="${saved_key}"
}

# 获取用户输入
get_user_input() {
    local email_input=''

    if load_credentials; then
        echo -e "${green}检测到已保存的Cloudflare账号：${CF_AccountEmail}${plain}"
        read -r -p "回车使用该邮箱，输入新邮箱后回车继续新的申请：" email_input

        if [[ -z "${email_input}" ]]; then
            : # 保持已读取的邮箱和密钥
        else
            CF_AccountEmail="${email_input}"
            echo -e "${green}请输入Cloudflare Global API Key：${plain}"
            read -r -s CF_GlobalKey
            echo
        fi
    else
        echo -e "${green}请输入Cloudflare注册邮箱：${plain}"
        read -r CF_AccountEmail
        echo -e "${green}请输入Cloudflare Global API Key：${plain}"
        read -r -s CF_GlobalKey
        echo
    fi

    echo -e "${green}请输入要申请证书的域名（例如example.com）：${plain}"
    read -r CF_Domain
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

    save_credentials
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

# 添加每日续订检查任务。acme.sh会在证书接近到期时才实际续订。
setup_renewal_task() {
    local task_file="/etc/cron.d/dnsssl-renew-${CF_Domain//[^A-Za-z0-9_-]/_}"
    local domain_arg
    local setup_choice

    echo -e "${yellow}证书通常约90天有效，建议每天检查一次续订状态。${plain}"
    read -r -p "是否添加自动续订任务？每天03:17检查，回1确认，其他跳过：[1/0] " setup_choice
    [[ "${setup_choice}" == "1" ]] || return 0

    domain_arg=$(printf '%q' "${CF_Domain}")
    umask 022
    printf '# dnsssl automatic renewal for %s\n17 3 * * * root %s --renew %s >>/var/log/dnsssl-renew.log 2>&1\n' \
        "${CF_Domain}" "${SCRIPT_PATH}" "${domain_arg}" > "${task_file}"
    chmod 644 "${task_file}"
    echo -e "${green}已添加自动续订任务：${task_file}${plain}"
}

# 定时任务使用的无交互续订入口
renew_certificate() {
    local renew_domain="${1:-}"

    if [[ -z "${renew_domain}" ]]; then
        echo -e "${red}续订失败：缺少域名参数${plain}"
        exit 1
    fi
    if ! load_credentials; then
        echo -e "${red}续订失败：未找到有效的Cloudflare凭据${plain}"
        exit 1
    fi

    CF_Domain="${renew_domain}"
    export CF_Key="${CF_GlobalKey}"
    export CF_Email="${CF_AccountEmail}"

    echo -e "${yellow}正在检查 ${CF_Domain} 的证书续订状态...${plain}"
    ~/.acme.sh/acme.sh --renew --dns dns_cf -d "${CF_Domain}" -d "*.${CF_Domain}" --log
    if [[ $? -ne 0 ]]; then
        echo -e "${red}证书续订失败，请查看 /var/log/dnsssl-renew.log${plain}"
        exit 1
    fi

    install_certificate
    echo -e "${green}证书续订检查完成：${CF_Domain}${plain}"
}

# 主流程
main() {
    install_dependencies
    install_acme
    get_user_input
    issue_certificate
    install_certificate
    setup_renewal_task
    
    echo -e "${green}SSL证书申请成功！证书文件路径：${plain}"
    ls -lah "/root/cert/${CF_Domain}/"
}

# 执行主函数或定时续订入口
if [[ "${1:-}" == "--renew" ]]; then
    renew_certificate "${2:-}"
else
    main
fi
