#!/usr/bin/env bash
# =========================================================
# 脚本名称: seehui.sh
# 功能描述: 读取 H-UI 的 hysteria2.yaml 配置文件并显示 H-UI 地址及证书路径
# =========================================================

CONFIG_FILE="${1:-/usr/local/h-ui/bin/hysteria2.yaml}"

# 检查配置文件是否存在；如果不存在，提示主机没安装hui
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -z "$1" ] && [ -f "/usr/local/h-ui/hysteria2.yaml" ]; then
        CONFIG_FILE="/usr/local/h-ui/hysteria2.yaml"
    else
        echo "主机没安装hui"
        exit 1
    fi
fi

# 检查字符串是否为 IP 地址 (IPv4 / IPv6)
is_ip() {
    local target="$1"
    # IPv4 检查
    if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    # IPv6 检查
    if [[ "$target" =~ : ]]; then
        return 0
    fi
    return 1
}

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

domain=""
ip=""
candidate=""

# 1. 优先尝试从证书路径提取目录名 (例如 /root/cert/hh.ssrr.today/fullchain.pem)
if [[ "$cert_path" =~ /([^/]+)/[^/]+$ ]]; then
    candidate="${BASH_REMATCH[1]}"
elif [[ "$cert_path" =~ /root/cert/([^/]+) ]]; then
    candidate="${BASH_REMATCH[1]}"
fi

# 2. 如果密钥路径有目录且 candidate 仍为空
if [ -z "$candidate" ] && [[ "$key_path" =~ /([^/]+)/[^/]+$ ]]; then
    candidate="${BASH_REMATCH[1]}"
fi

# 3. 尝试从证书文件名中提取
if [ -z "$candidate" ] && [ -n "$cert_path" ]; then
    fn=$(basename "$cert_path" 2>/dev/null)
    fn_no_ext="${fn%.*}"
    candidate="$fn_no_ext"
fi

# 4. 如果证书文件实际存在，尝试使用 openssl 读取 SAN 或 CN
if [ -f "$cert_path" ] && command -v openssl &>/dev/null; then
    san_domain=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | head -n 1 | cut -d: -f2)
    if [ -n "$san_domain" ]; then
        candidate="$san_domain"
    else
        cn_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -nE 's/.*CN[ =]*([^, /]+).*/\1/p')
        if [ -n "$cn_domain" ]; then
            candidate="$cn_domain"
        fi
    fi
fi

# 5. 分析提取出的 candidate 是域名还是 IP
if [ -n "$candidate" ]; then
    if is_ip "$candidate"; then
        if [[ "$candidate" != "127.0.0.1" && "$candidate" != "0.0.0.0" ]]; then
            ip="$candidate"
        fi
    elif [[ "$candidate" =~ \. ]] && [[ "$candidate" != *"fullchain"* ]] && [[ "$candidate" != *"privkey"* ]]; then
        domain="$candidate"
    fi
fi

# 6. 如果没有域名，但 auth_url 中包含非本机的 IP 地址
if [ -z "$domain" ] && [ -z "$ip" ] && [ -n "$auth_url" ]; then
    url_host=$(echo "$auth_url" | sed -nE 's#^https?://([^:/]+).*#\1#p')
    if [ -n "$url_host" ] && is_ip "$url_host" && [[ "$url_host" != "127.0.0.1" && "$url_host" != "0.0.0.0" ]]; then
        ip="$url_host"
    fi
fi

# 7. 如果没有域名且未获取到有效 IP，自动探测本机公网 IP
if [ -z "$domain" ] && [ -z "$ip" ]; then
    ip=$(curl -s4m 2 https://api.ipify.org 2>/dev/null || \
         curl -s4m 2 https://ip.sb 2>/dev/null || \
         curl -s4m 2 https://ifconfig.me 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}' || \
         echo "127.0.0.1")
fi

# 8. 根据是否有域名输出对应的 hui 地址 (有域名提示 https://，无域名只有ip提示 http://)
if [ -n "$domain" ]; then
    echo "当前hui地址为 https://${domain}:${port}"
else
    echo "当前hui地址为 http://${ip}:${port}"
fi

# 9. 输出证书信息（如果存在配置）
if [ -n "$cert_path" ] || [ -n "$key_path" ]; then
    echo "证书是"
    [ -n "$cert_path" ] && echo "    cert: ${cert_path}"
    [ -n "$key_path" ] && echo "    key: ${key_path}"
fi
