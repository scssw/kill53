#!/bin/bash

# 配置变量
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"

# 权限检查
[[ $EUID -ne 0 ]] && echo "错误: 请使用 root 权限运行" && exit 1

# 依赖检查
ensure_env() {
    if ! command -v ipset &> /dev/null; then
        apt-get update && apt-get install -y ipset curl
    fi
}

block_cn() {
    ensure_env
    echo "1. 正在获取 IPv4 列表并清理格式..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    
    # 强化过滤：只保留包含数字和点的行，并剔除所有空格
    data_v4=$(curl -f -L -s $URL_V4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sed 's/[[:space:]]//g')
    if [ -z "$data_v4" ]; then echo "❌ IPv4 数据下载失败"; exit 1; fi
    echo "$data_v4" | sed "s|^|add $IPSET_V4 |" | ipset restore -!

    echo "2. 正在获取 IPv6 列表..."
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    data_v6=$(curl -f -L -s $URL_V6 | grep ':' | sed 's/[[:space:]]//g')
    if [ -z "$data_v6" ]; then echo "❌ IPv6 数据下载失败"; exit 1; fi
    echo "$data_v6" | sed "s|^|add $IPSET_V6 |" | ipset restore -!

    echo "3. 正在部署防火墙规则..."
    # 清理
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null

    # 应用
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT --reject-with icmp-port-unreachable
    
    ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT

    # 拦截国内公共 DNS (可选)
    iptables -I OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null

    # 保存
    iptables-save > $IPTABLES_FILE
    
    echo "========================================"
    echo "✅ 拦截已真正开启！"
    echo "请执行 'ping baidu.com' 验证拦截效果。"
    echo "========================================"
}

unblock_cn() {
    echo "正在还原设置..."
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null; do :; done
    iptables -D OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null; do :; done
    ipset destroy $IPSET_V4 2>/dev/null
    ipset destroy $IPSET_V6 2>/dev/null
    iptables-save > $IPTABLES_FILE
    echo "✅ 拦截已解除。"
}

clear
echo "1. 开启拦截"
echo "2. 取消拦截"
read -p "选择 [1-2]: " choice
case $choice in
    1) block_cn ;;
    2) unblock_cn ;;
esac
