#!/usr/bin/env bash
# =========================================================
# 脚本名称: seehui.sh
# 功能描述: 读取 H-UI 的 hysteria2.yaml 配置文件并显示 H-UI 地址及证书路径
# =========================================================

CONFIG_FILE="${1:-/usr/local/h-ui/bin/hysteria2.yaml}"

# 检查配置文件是否存在，若不存在尝试其它可能路径
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/usr/local/h-ui/hysteria2.yaml" ]; then
        CONFIG_FILE="/usr/local/h-ui/hysteria2.yaml"
    elif [ -f "./hysteria2.yaml" ]; then
        CONFIG_FILE="./hysteria2.yaml"
    else
        echo -e "\033[31m错误: 未找到配置文件: $CONFIG_FILE\033[0m"
        exit 1
    fi
fi

# 提取证书与密钥路径
cert_path=$(grep -E '^[[:space:]]*cert:' "$CONFIG_FILE" | head -n 1 | sed -E 's/^[[:space:]]*cert:[[:space:]]*//' | tr -d '\r"' | tr -d "'" | sed 's/[[:space:]]*$//')
key_path=$(grep -E '^[[:space:]]*key:' "$CONFIG_FILE" | head -n 1 | sed -E 's/^[[:space:]]*key:[[:space:]]*//' | tr -d '\r"' | tr -d "'" | sed 's/[[:space:]]*$//')

# 提取认证 URL 及端口 (如: https://127.0.0.1:58585/hui/hysteria2/auth)
auth_url=$(grep -E '^[[:space:]]*url:' "$CONFIG_FILE" | head -n 1 | sed -E 's/^[[:space:]]*url:[[:space:]]*//' | tr -d '\r"' | tr -d "'" | sed 's/[[:space:]]*$//')
port=$(echo "$auth_url" | grep -oE ':[0-9]+' | head -n 1 | tr -d ':')

# 缺省兜底端口为 58585
if [ -z "$port" ]; then
    port="58585"
fi

# 提取域名
domain=""

# 1. 优先尝试从证书路径中匹配带有点号的目录名 (例如 /root/cert/hh.ssrr.today/fullchain.pem -> hh.ssrr.today)
if [[ "$cert_path" =~ /([^/]+\.[^/]+)/[^/]+$ ]]; then
    domain="${BASH_REMATCH[1]}"
fi

# 2. 尝试从 /root/cert/ 后的子目录提取
if [ -z "$domain" ] && [[ "$cert_path" =~ /root/cert/([^/]+)/ ]]; then
    candidate="${BASH_REMATCH[1]}"
    if [[ "$candidate" =~ \. ]]; then
        domain="$candidate"
    fi
fi

# 3. 尝试从密钥路径中匹配
if [ -z "$domain" ] && [[ "$key_path" =~ /([^/]+\.[^/]+)/[^/]+$ ]]; then
    domain="${BASH_REMATCH[1]}"
fi

# 4. 如果证书文件名本身包含域名（例如 domain.com.crt）
if [ -z "$domain" ]; then
    filename=$(basename "$cert_path" 2>/dev/null)
    base_no_ext="${filename%.*}"
    if [[ "$base_no_ext" =~ \. ]]; then
        domain="$base_no_ext"
    fi
fi

# 5. 如果系统存在 openssl 且证书文件实际存在，从证书中解析域名
if [ -z "$domain" ] && [ -f "$cert_path" ] && command -v openssl &>/dev/null; then
    san_domain=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | head -n 1 | cut -d: -f2)
    if [ -n "$san_domain" ]; then
        domain="$san_domain"
    else
        cn_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -nE 's/.*CN[ =]*([^, /]+).*/\1/p')
        if [ -n "$cn_domain" ]; then
            domain="$cn_domain"
        fi
    fi
fi

# 6. 如果仍然无法获取域名，尝试获取本机公网 IP 作为备用显示
if [ -z "$domain" ]; then
    server_ip=$(curl -s4m 2 https://api.ipify.org 2>/dev/null || curl -s4m 2 https://ip.sb 2>/dev/null || echo "127.0.0.1")
    domain="$server_ip"
fi

# 输出提示信息
echo "当前hui地址为 https://${domain}:${port}"
echo "证书是"
echo "    cert: ${cert_path}"
echo "    key: ${key_path}"
