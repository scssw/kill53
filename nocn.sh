#!/bin/bash

# 配置变量 (使用 skk.moe 优化源)
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo "错误: 请使用 root 权限运行" && exit 1

# --- 修复软件源函数 ---
fix_debian_sources() {
    echo "检测到 Debian 11 或软件源异常，正在尝试修复..."
    # 移除报错的 backports 源
    sed -i '/bullseye-backports/d' /etc/apt/sources.list 2>/dev/null
    rm -f /etc/apt/sources.list.d/backports.list 2>/dev/null
    # 更新索引
    apt-get update --fix-missing
}

# --- 依赖检查与安装 ---
ensure_env() {
    # 如果是 Debian 11，主动预防
    if grep -q "bullseye" /etc/os-release 2>/dev/null; then
        echo "系统确认: Debian 11 (Bullseye)，执行源优化..."
        fix_debian_sources
    fi

    if ! command -v ipset &> /dev/null || ! command -v curl &> /dev/null; then
        echo "正在安装必要组件 (ipset/curl)..."
        if ! apt-get install -y ipset curl; then
            echo "安装失败，尝试修复源后重试..."
            fix_debian_sources
            apt-get install -y ipset curl
        fi
    fi

    # 最终确认
    if ! command -v ipset &> /dev/null; then
        echo "❌ 无法安装 ipset，请手动检查 VPS 联网状态或软件源。"
        exit 1
    fi
}

block_cn() {
    ensure_env
    echo "1. 正在获取 IPv4 列表 (skk.moe)..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    
    # 抓取数据：过滤空行、剔除空格、只保留合规 IP 格式
    data_v4=$(curl -f -L -s $URL_V4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sed 's/[[:space:]]//g')
    if [ -z "$data_v4" ]; then echo "❌ IPv4 数据获取失败"; exit 1; fi
    echo "$data_v4" | sed "s|^|add $IPSET_V4 |" | ipset restore -!

    echo "2. 正在获取 IPv6 列表..."
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    data_v6=$(curl -f -L -s $URL_V6 | grep ':' | sed 's/[[:space:]]//g')
    if [ -z "$data_v6" ]; then echo "❌ IPv6 数据获取失败"; exit 1; fi
    echo "$data_v6" | sed "s|^|add $IPSET_V6 |" | ipset restore -!

    echo "3. 部署拦截策略..."
    # 清理旧规则
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null

    # 关键：允许 ESTABLISHED 保证 SSR 连接不断开
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT --reject-with icmp-port-unreachable
    
    ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT

    # 4. 强制拦截国内公共 DNS
    iptables -I OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null

    # 5. 保存规则
    iptables-save > $IPTABLES_FILE
    echo "========================================"
    echo "✅ 拦截已开启！"
    echo "VPS 已拒绝连接中国 IP 段，百度等国内站已封锁。"
    echo "========================================"
}

unblock_cn() {
    echo "正在恢复系统访问..."
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

# --- 菜单 ---
clear
echo "#############################################"
echo "#    VPS 拒绝中国流量 (Debian 11 适配版)     #"
echo "#############################################"
echo ""
echo "1. 开启拦截 (拒绝回国流量)"
echo "2. 取消拦截"
echo ""
read -p "请输入数字 [1-2]: " choice

case $choice in
    1) block_cn ;;
    2) unblock_cn ;;
    *) echo "退出" ;;
esac
