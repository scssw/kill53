#!/bin/bash

# 定义变量
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
# 列表源
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"

if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行" 
   exit 1
fi

# 安装依赖
install_dependencies() {
    if ! command -v ipset &> /dev/null; then
        apt-get update && apt-get install -y ipset curl grep
    fi
}

block_cn() {
    install_dependencies
    echo "1. 正在下载并导入 IPv4 列表..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    curl -s $URL_V4 | grep -v "^#" | sed -e "s/^/add $IPSET_V4 /" | ipset restore -!

    echo "2. 正在下载并导入 IPv6 列表 (拦截 B站/百度关键)..."
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    curl -s $URL_V6 | grep -v "^#" | sed -e "s/^/add $IPSET_V6 /" | ipset restore -!

    echo "3. 正在应用防火墙规则..."
    
    # --- IPv4 规则 ---
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    iptables -I OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # --- IPv6 规则 ---
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null
    ip6tables -I OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT
    ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 保存规则
    iptables-save > $IPTABLES_FILE
    if command -v ip6tables-save &> /dev/null; then
        ip6tables-save > ${IPTABLES_FILE}6
    fi
    
    echo "========================================"
    echo "✅ 拦截已强化！(IPv4 + IPv6 已封锁)"
    echo "提示：若仍能打开，请清理浏览器缓存或刷新 DNS。"
    echo "========================================"
}

unblock_cn() {
    echo "正在移除所有拦截规则..."
    # 清理 IPv4
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null; do :; done
    ipset destroy $IPSET_V4 2>/dev/null
    
    # 清理 IPv6
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null; do :; done
    ipset destroy $IPSET_V6 2>/dev/null
    
    echo "✅ 已彻底取消拦截。"
}

clear
echo "1. 开启拦截 (IPv4+IPv6双重封锁)"
echo "2. 取消拦截"
read -p "请输入 [1-2]: " choice
case $choice in
    1) block_cn ;;
    2) unblock_cn ;;
esac
