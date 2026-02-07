#!/bin/bash

# 配置变量
IPSET_V4="chnroute"
IPSET_V6="chnroute6"
IPTABLES_FILE="/etc/iptables.up.rules"
URL_V4="https://ruleset.skk.moe/Clash/ip/china_ip.txt"
URL_V6="https://ruleset.skk.moe/Clash/ip/china_ipv6.txt"

# 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行 (sudo bash nocn.sh)" 
   exit 1
fi

# 检查依赖
if ! command -v ipset &> /dev/null; then
    echo "正在安装 ipset..."
    apt-get update && apt-get install -y ipset curl
fi

block_cn() {
    echo "1. 正在获取 IPv4 列表 (skk.moe)..."
    ipset create $IPSET_V4 hash:net -exist
    ipset flush $IPSET_V4
    # 获取数据并过滤空行
    curl -f -L -s $URL_V4 | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}' | sed -e "s/^/add $IPSET_V4 /" | ipset restore -!

    echo "2. 正在获取 IPv6 列表..."
    ipset create $IPSET_V6 hash:net family inet6 -exist
    ipset flush $IPSET_V6
    curl -f -L -s $URL_V6 | grep -i ':' | sed -e "s/^/add $IPSET_V6 /" | ipset restore -!

    echo "3. 正在应用防火墙拦截策略..."
    
    # 先清理旧规则防止堆积
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null

    # 关键逻辑：放行“已建立”的连接，拦截“新发起”的国内连接
    # 这样你的 SSR 客户端连 VPS 不会断，但 VPS 去连百度会被挡住
    iptables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT --reject-with icmp-port-unreachable
    
    ip6tables -I OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT

    # 4. 强制拦截国内公共 DNS
    iptables -I OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null

    # 5. 保存到 iptables 配置文件
    iptables-save > $IPTABLES_FILE
    
    echo "========================================"
    echo "✅ 拦截已开启！"
    echo "   VPS 现在无法主动访问中国 IP 段。"
    echo "   请在 Mac 上用无痕模式测试百度。"
    echo "========================================"
}

unblock_cn() {
    echo "正在清理拦截规则..."
    iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while iptables -D OUTPUT -m set --match-set $IPSET_V4 dst -j REJECT 2>/dev/null; do :; done
    iptables -D OUTPUT -d 114.114.114.114,223.5.5.5,119.29.29.29 -j REJECT 2>/dev/null
    
    ip6tables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    while ip6tables -D OUTPUT -m set --match-set $IPSET_V6 dst -j REJECT 2>/dev/null; do :; done
    
    ipset destroy $IPSET_V4 2>/dev/null
    ipset destroy $IPSET_V6 2>/dev/null
    
    iptables-save > $IPTABLES_FILE
    echo "✅ 拦截已解除，VPS 恢复自由访问。"
}

# 菜单选择
clear
echo "#############################################"
echo "#    VPS 拒绝中国流量 (skk.moe 增强版)     #"
echo "#############################################"
echo ""
echo "1. 开启拦截 (拒绝回国流量)"
echo "2. 取消拦截 (恢复默认)"
echo ""
read -p "请输入数字 [1-2]: " choice

case $choice in
    1)
        block_cn
        ;;
    2)
        unblock_cn
        ;;
    *)
        echo "输入错误，脚本退出。"
        ;;
esac
