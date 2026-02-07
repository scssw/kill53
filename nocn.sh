#!/bin/bash

# 定义变量 (使用 skk.moe 优化源)
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"

# 检查 root
[[ $EUID -ne 0 ]] && echo "错误: 必须使用 root 权限运行！" && exit 1

# 环境检查
ensure_env() {
    if ! command -v ipset &> /dev/null || ! command -v curl &> /dev/null; then
        echo "正在安装必要组件 (ipset/curl)..."
        # 尝试修复 Debian 11 常见的 backports 报错
        sed -i '/backports/d' /etc/apt/sources.list 2>/dev/null
        apt-get update -y && apt-get install -y ipset curl
    fi
}

block_cn() {
    ensure_env
    
    echo "1. 正在获取 IPv4 列表 (skk.moe)..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    # 使用 curl 下载并直接导入
    data_v4=$(curl -f -L -s $URL_V4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}')
    if [ -z "$data_v4" ]; then echo "❌ 无法下载 IPv4 列表，请检查网络"; exit 1; fi
    echo "$data_v4" | sed -e "s/^/add $IPSET_V4 /" | ipset restore -!

    echo "2. 正在获取 IPv6 列表 (skk.moe)..."
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    data_v6=$(curl -f -L -s $URL_V6 | grep -i ':')
    if [ -z "$data_v6" ]; then echo "❌ 无法下载 IPv6 列表，请检查网络"; exit 1; fi
    echo "$data_v6" | sed -e "s/^/add $IPSET_V6 /" | ipset restore -!

    echo "3. 正在部署防火墙策略..."
    
    # 清理旧规则（避免重复）
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null

    # 核心拦截逻辑：
    # 1. 允许回复已建立的连接 (保证 SSR 客户端能收到数据)
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # 2. 拒绝发往中国 IP 段的新连接
    iptables -A OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT --reject-with icmp-port-unreachable
    
    # IPv6 同理
    ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT

    # 4. 强制拦截国内公共 DNS (防止通过国内 DNS 绕过拦截)
    iptables -I OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null

    # 5. 保存规则 (写入你指定的路径)
    iptables-save > $IPTABLES_FILE
    
    echo "========================================"
    echo "✅ 拦截已开启！"
    echo "   数据源: SukkaW Ruleset (skk.moe)"
    echo "   状态: IPv4+IPv6 双重封锁"
    echo "========================================"
}

unblock_cn() {
    echo "正在移除拦截规则..."
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null; do :; done
    iptables -D OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null
    
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null; do :; done
    
    ipset destroy $IPSET_V4 2>/dev/null
