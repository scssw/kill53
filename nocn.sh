#!/bin/bash

# 配置变量
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"
FIX_MARKER="/etc/nocn_fixed_marker"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo "错误: 请使用 root 权限运行" && exit 1

# --- 智能环境检查 ---
ensure_env() {
    # 1. 优先检查 ipset 是否已存在。如果存在，说明环境是好的，直接跳过所有修复。
    if command -v ipset &> /dev/null; then
        echo "✅ 检测到 ipset 已安装，跳过源修复步骤..."
        return
    fi

    # 2. 如果 ipset 不存在，且没有修复过，则执行修复
    if [[ -f "$FIX_MARKER" ]]; then
        echo "检测到已执行过修复，正在重试安装..."
    else
        # 只有在 Debian 11 且未修复过时才执行
        if grep -q "bullseye" /etc/os-release 2>/dev/null; then
            echo "检测到 Debian 11，正在执行源修复..."
            sed -i '/bullseye-backports/d' /etc/apt/sources.list 2>/dev/null
            rm -f /etc/apt/sources.list.d/backports.list 2>/dev/null
            # 创建标记文件，下次不再运行
            touch "$FIX_MARKER"
        fi
    fi

    # 3. 安装依赖
    echo "正在安装依赖..."
    apt-get update --fix-missing -y
    apt-get install -y ipset curl
}

block_cn() {
    ensure_env
    
    echo "1. 正在获取 IPv4 列表..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    
    # 增加超时和重试机制
    data_v4=$(curl --retry 3 --connect-timeout 10 -f -L -s $URL_V4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sed 's/[[:space:]]//g')
    
    if [ -z "$data_v4" ]; then 
        echo "❌ IPv4 数据下载失败，请检查网络连接！"
        exit 1
    fi
    echo "$data_v4" | sed "s|^|add $IPSET_V4 |" | ipset restore -!

    echo "2. 正在获取 IPv6 列表..."
    # 允许 IPv6 失败而不退出脚本
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    
    data_v6=$(curl --retry 3 --connect-timeout 10 -f -L -s $URL_V6 | grep ':' | sed 's/[[:space:]]//g')
    
    if [ -n "$data_v6" ]; then
        echo "$data_v6" | sed "s|^|add $IPSET_V6 |" | ipset restore -!
        ENABLE_V6=true
    else
        echo "⚠️ IPv6 列表下载失败 (或为空)，将仅启用 IPv4 拦截..."
        ENABLE_V6=false
    fi

    echo "3. 部署拦截策略..."
    # 清理旧规则
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null

    # 应用 IPv4 规则
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT --reject-with icmp-port-unreachable
    
    # 应用 IPv6 规则 (如果下载成功)
    if [ "$ENABLE_V6" = true ]; then
        ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        ip6tables -A OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT
    fi

    # 拦截国内公共 DNS
    iptables -I OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null

    # 保存
    iptables-save > $IPTABLES_FILE
    
    echo "========================================"
    echo "✅ 拦截已开启！"
    if [ "$ENABLE_V6" = true ]; then
        echo "   状态: IPv4 + IPv6 双栈封锁"
    else
        echo "   状态: 仅 IPv4 封锁 (IPv6 获取失败)"
    fi
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
