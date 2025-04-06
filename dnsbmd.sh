#!/bin/bash


# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请以root权限运行此脚本"
    exit 1
fi

# 检查iptables是否安装
if ! command -v iptables &> /dev/null; then
    echo "iptables未安装，请先安装iptables"
    exit 1
fi

# 保存iptables规则的函数
save_rules() {
    iptables-save > /etc/iptables.up.rules
    echo "iptables规则已保存"
}

# 添加IP白名单
add_whitelist() {
    echo "请输入要添加到白名单的IP地址："
    read ip_address
    
    # 验证IP地址格式
    if [[ ! $ip_address =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "无效的IP地址格式"
        return
    fi
    
    # 检查IP是否已在白名单中
    if iptables -C INPUT -s $ip_address/32 -p tcp -m tcp --dport 53 -j ACCEPT 2>/dev/null; then
        echo "IP地址 $ip_address 已在白名单中"
        return
    fi
    
    # 添加允许规则
    iptables -A INPUT -s $ip_address/32 -p tcp -m tcp --dport 53 -j ACCEPT
    iptables -A INPUT -s $ip_address/32 -p udp -m udp --dport 53 -j ACCEPT
    
    # 检查是否已有阻止规则，如果没有则添加
    if ! iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP 2>/dev/null; then
        iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP
        iptables -A INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP
    fi
    
    echo "IP地址 $ip_address 已添加到白名单"
    save_rules
}

# 删除IP白名单
remove_whitelist() {
    echo "当前白名单IP列表："
    # 获取并显示白名单IP列表（带编号）
    ip_list=($(get_whitelist_ips))
    if [ ${#ip_list[@]} -eq 0 ]; then
        echo "当前没有IP在白名单中"
        return
    fi
    
    for i in "${!ip_list[@]}"; do
        echo "[$((i+1))] ${ip_list[$i]}"
    done
    
    echo "请输入要删除的IP编号（输入0返回）："
    read ip_number
    
    # 验证输入是否为数字
    if ! [[ "$ip_number" =~ ^[0-9]+$ ]]; then
        echo "无效的输入，请输入数字"
        return
    fi
    
    # 检查是否选择返回
    if [ "$ip_number" -eq 0 ]; then
        return
    fi
    
    # 检查编号是否有效
    if [ "$ip_number" -lt 1 ] || [ "$ip_number" -gt "${#ip_list[@]}" ]; then
        echo "无效的编号，请输入1-${#ip_list[@]}之间的数字"
        return
    fi
    
    # 获取选择的IP地址
    selected_ip=${ip_list[$((ip_number-1))]}
    
    # 删除规则
    iptables -D INPUT -s $selected_ip/32 -p tcp -m tcp --dport 53 -j ACCEPT
    iptables -D INPUT -s $selected_ip/32 -p udp -m udp --dport 53 -j ACCEPT
    
    echo "IP地址 $selected_ip 已从白名单中删除"
    save_rules
}

# 获取白名单IP列表的函数
get_whitelist_ips() {
    if [ -f "/etc/iptables.up.rules" ]; then
        # 直接从规则文件中读取并提取IP地址
        cat /etc/iptables.up.rules | grep "INPUT" | grep "dport 53" | grep "ACCEPT" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' | sed 's|/32||g' | sort | uniq
    else
        # 如果规则文件不存在，使用iptables-save
        iptables-save | grep "INPUT" | grep "dport 53" | grep "ACCEPT" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' | sed 's|/32||g' | sort | uniq
    fi
}

# 查看白名单
view_whitelist() {
    echo "当前53端口白名单IP列表："
    # 获取并显示白名单IP列表（带编号）
    ip_list=($(get_whitelist_ips))
    if [ ${#ip_list[@]} -eq 0 ]; then
        echo "当前没有IP在白名单中"
    else
        for i in "${!ip_list[@]}"; do
            echo "[$((i+1))] ${ip_list[$i]}"
        done
    fi
    
    # 检查是否有阻止规则（同时检查TCP和UDP规则）
    tcp_drop_exists=$(iptables-save | grep -E "^-A INPUT.*-p tcp.*--dport 53.*-j DROP" | wc -l)
    udp_drop_exists=$(iptables-save | grep -E "^-A INPUT.*-p udp.*--dport 53.*-j DROP" | wc -l)
    
    if [ "$tcp_drop_exists" -gt 0 ] || [ "$udp_drop_exists" -gt 0 ]; then
        echo "53端口当前状态: 仅允许白名单IP访问"
    else
        echo "53端口当前状态: 允许所有IP访问"
    fi
}

# 管理53端口访问
manage_port() {
    while true; do
        echo "==== 53端口管理 ===="
        echo "1. 放开53端口 (允许所有IP访问)"
        echo "2. 禁用53端口 (仅允许白名单IP访问)"
        echo "0. 返回主菜单"
        echo "===================="
        read -p "请选择操作: " port_choice
        
        case $port_choice in
            1)
                # 删除阻止规则
                iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP 2>/dev/null
                iptables -D INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP 2>/dev/null
                echo "53端口已放开，允许所有IP访问"
                save_rules
                ;;
            2)
                # 添加阻止规则（如果不存在）
                if ! iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP 2>/dev/null; then
                    iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP
                    iptables -A INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP
                    echo "53端口已禁用，仅允许白名单IP访问"
                    save_rules
                else
                    echo "53端口已经处于禁用状态"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择，请重试"
                ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        echo "==== 流媒体解锁IP管理 ===="
        echo "1. 添加IP白名单"
        echo "2. 删除IP白名单"
        echo "3. 查看IP白名单"
        echo "4. 开启/禁用53端口"
        echo "0. 退出"
        echo "================================"
        read -p "请选择操作: " choice
        
        case $choice in
            1)
                add_whitelist
                ;;
            2)
                remove_whitelist
                ;;
            3)
                view_whitelist
                ;;
            4)
                manage_port
                ;;
            0)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo "无效选择，请重试"
                ;;
        esac
        
        echo ""
    done
}

# 启动主菜单
main_menu
