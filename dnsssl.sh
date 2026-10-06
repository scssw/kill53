#!/bin/bash

# 一键申请 Cloudflare SSL 证书（Global API Key 或 API Token）

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CREDENTIALS_FILE="/root/.dnsssl_credentials"
SCRIPT_PATH="$(readlink -f "$0")"
ACME="$HOME/.acme.sh/acme.sh"

[[ $EUID -ne 0 ]] && echo -e "${red}错误：必须使用 root 权限运行此脚本！${plain}" && exit 1

install_dependencies() {
    echo -e "${yellow}正在安装必要依赖...${plain}"
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y socat curl
    elif command -v dnf &>/dev/null; then
        dnf install -y socat curl
    elif command -v yum &>/dev/null; then
        yum install -y socat curl
    else
        echo -e "${red}不支持的包管理器，请手动安装 socat 和 curl${plain}"
        exit 1
    fi
}

install_acme() {
    if [[ ! -x "$ACME" ]]; then
        echo -e "${yellow}正在安装 acme.sh...${plain}"
        curl -fsSL https://get.acme.sh | sh
        [[ $? -ne 0 || ! -x "$ACME" ]] && echo -e "${red}acme.sh 安装失败${plain}" && exit 1
    fi
    "$ACME" --upgrade --auto-upgrade
}

save_credentials() {
    umask 077
    printf '%s\n%s\n%s\n' "$CF_AuthMode" "$CF_AccountEmail" "$CF_Credential" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
}

load_credentials() {
    local first='' second='' third=''
    [[ -f "$CREDENTIALS_FILE" ]] || return 1
    mapfile -t _saved < "$CREDENTIALS_FILE"
    first="${_saved[0]:-}"; second="${_saved[1]:-}"; third="${_saved[2]:-}"
    if [[ "$first" == "key" || "$first" == "token" ]]; then
        CF_AuthMode="$first"; CF_AccountEmail="$second"; CF_Credential="$third"
    else
        # 兼容旧版仅保存邮箱、Global API Key 的两行文件
        CF_AuthMode="key"; CF_AccountEmail="$first"; CF_Credential="$second"
    fi
    [[ -n "$CF_Credential" ]] || return 1
    [[ "$CF_AuthMode" == "token" || -n "$CF_AccountEmail" ]]
}

read_api_key() {
    local pasted_line='' pasted_email='' pasted_key=''
    echo -e "${green}请一次性粘贴邮箱和 Cloudflare Global API Key，中间用空格或 Tab 分隔：${plain}"
    echo "示例：name@example.com abcdef0123456789"
    IFS= read -r -p "> " pasted_line
    read -r pasted_email pasted_key <<< "$pasted_line"
    if [[ -z "$pasted_email" || -z "$pasted_key" ]]; then
        echo -e "${red}格式错误，请按“邮箱 空格 API Key”重新运行。${plain}"
        exit 1
    fi
    CF_AuthMode=key; CF_AccountEmail="$pasted_email"; CF_Credential="$pasted_key"
}

get_user_input() {
    local choice='' pasted=''
    if load_credentials; then
        echo -e "${green}检测到已保存的 Cloudflare 凭据（认证方式：$([[ $CF_AuthMode == token ]] && echo API Token || echo Global API Key)）。${plain}"
        read -r -p "回车沿用，或输入 1 重新粘贴邮箱和 Key，输入 2 使用 API Token：[回车/1/2] " choice
        if [[ "$choice" == "1" ]]; then
            read_api_key
        elif [[ "$choice" == "2" ]]; then
            CF_AuthMode=token; CF_AccountEmail=''
            read -r -s -p "请输入 Cloudflare API Token：" CF_Credential; echo
        fi
    else
        echo "选择 Cloudflare DNS API 认证方式："
        echo "  1) 邮箱 + Global API Key（可一次粘贴）"
        echo "  2) API Token（推荐使用仅限 DNS 编辑权限的 Token）"
        read -r -p "请选择 [1/2]：" choice
        if [[ "$choice" == "1" ]]; then
            read_api_key
        elif [[ "$choice" == "2" ]]; then
            CF_AuthMode=token; CF_AccountEmail=''
            read -r -s -p "请输入 Cloudflare API Token：" CF_Credential; echo
        else
            echo -e "${red}无效选项。${plain}"; exit 1
        fi
    fi
    [[ -n "$CF_Credential" ]] || { echo -e "${red}凭据不能为空。${plain}"; exit 1; }
    read -r -p "请输入要申请证书的根域名（例如 example.com）：" CF_Domain
    [[ -n "$CF_Domain" ]] || { echo -e "${red}域名不能为空。${plain}"; exit 1; }
}

set_cloudflare_env() {
    unset CF_Key CF_Email CF_Token CF_Account_ID CF_Zone_ID
    if [[ "$CF_AuthMode" == token ]]; then
        export CF_Token="$CF_Credential"
    else
        export CF_Key="$CF_Credential" CF_Email="$CF_AccountEmail"
    fi
}

issue_certificate() {
    echo -e "${yellow}正在申请证书...${plain}"
    set_cloudflare_env
    "$ACME" --set-default-ca --server letsencrypt || return 1
    "$ACME" --issue --dns dns_cf -d "$CF_Domain" -d "*.$CF_Domain" --log || {
        echo -e "${red}证书申请失败，请检查域名和 Cloudflare API 权限。${plain}"; return 1;
    }
    save_credentials
}

install_certificate() {
    local cert_path="/root/cert/${CF_Domain}"
    mkdir -p "$cert_path" || return 1
    "$ACME" --install-cert -d "$CF_Domain" -d "*.$CF_Domain" \
        --fullchain-file "$cert_path/fullchain.pem" \
        --key-file "$cert_path/privkey.pem" || return 1
    chmod 644 "$cert_path/fullchain.pem"
    chmod 600 "$cert_path/privkey.pem"
    echo -e "${green}证书已保存到：${cert_path}${plain}"
}

setup_renewal_task() {
    local task_file="/etc/cron.d/dnsssl-renew-${CF_Domain//[^A-Za-z0-9_-]/_}" domain_arg setup_choice
    echo -e "${yellow}证书通常约 90 天有效，建议每天检查一次续订状态。${plain}"
    read -r -p "是否添加自动续订任务？每天 03:17 检查，输入 1 确认：[1/0] " setup_choice
    [[ "$setup_choice" == 1 ]] || return 0
    domain_arg=$(printf '%q' "$CF_Domain")
    umask 022
    printf '# dnsssl automatic renewal for %s\n17 3 * * * root %s --renew %s >>/var/log/dnsssl-renew.log 2>&1\n' \
        "$CF_Domain" "$SCRIPT_PATH" "$domain_arg" > "$task_file"
    chmod 644 "$task_file"
    echo -e "${green}已添加自动续订任务：${task_file}${plain}"
}

renew_certificate() {
    local renew_domain="${1:-}"
    [[ -n "$renew_domain" ]] || { echo -e "${red}续订失败：缺少域名参数${plain}"; exit 1; }
    load_credentials || { echo -e "${red}续订失败：未找到有效的 Cloudflare 凭据${plain}"; exit 1; }
    CF_Domain="$renew_domain"
    set_cloudflare_env
    echo -e "${yellow}正在检查 ${CF_Domain} 的证书续订状态...${plain}"
    "$ACME" --renew --dns dns_cf -d "$CF_Domain" -d "*.$CF_Domain" --log || {
        echo -e "${red}证书续订失败，请查看 /var/log/dnsssl-renew.log${plain}"; exit 1;
    }
    install_certificate || exit 1
    echo -e "${green}证书续订检查完成：${CF_Domain}${plain}"
}

main() {
    install_dependencies
    install_acme
    get_user_input
    issue_certificate || exit 1
    install_certificate || exit 1
    setup_renewal_task
    echo -e "${green}SSL 证书申请成功！证书文件路径：${plain}"
    ls -lah "/root/cert/${CF_Domain}/"
}

if [[ "${1:-}" == --renew ]]; then
    renew_certificate "${2:-}"
else
    main
fi
