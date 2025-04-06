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
    
    # 确保DROP规则存在，这样我们可以在它们之前插入白名单规则
    # 先检查是否已有阻止规则，如果没有则添加
    tcp_drop_exists=false
    udp_drop_exists=false
    
    if iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP 2>/dev/null; then
        tcp_drop_exists=true
    fi
    
    if iptables -C INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP 2>/dev/null; then
        udp_drop_exists=true
    fi
    
    # 如果DROP规则不存在，先添加它们
    if ! $tcp_drop_exists; then
        iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP
    fi
    
    if ! $udp_drop_exists; then
        iptables -A INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP
    fi
    
    # 获取DROP规则的位置
    tcp_rule_num=$(iptables -L INPUT --line-numbers | grep "tcp dpt:53" | grep "DROP" | awk '{print $1}' | head -n 1)
    udp_rule_num=$(iptables -L INPUT --line-numbers | grep "udp dpt:53" | grep "DROP" | awk '{print $1}' | head -n 1)
    
    # 在DROP规则之前插入白名单规则
    if [ -n "$tcp_rule_num" ]; then
        iptables -I INPUT $tcp_rule_num -s $ip_address/32 -p tcp -m tcp --dport 53 -j ACCEPT
    else
        # 如果找不到DROP规则位置，使用-I插入到链的开头
        iptables -I INPUT 1 -s $ip_address/32 -p tcp -m tcp --dport 53 -j ACCEPT
    fi
    
    if [ -n "$udp_rule_num" ]; then
        iptables -I INPUT $udp_rule_num -s $ip_address/32 -p udp -m udp --dport 53 -j ACCEPT
    else
        # 如果找不到DROP规则位置，使用-I插入到链的开头
        iptables -I INPUT 1 -s $ip_address/32 -p udp -m udp --dport 53 -j ACCEPT
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
    
    # 删除规则并检查是否成功
    if iptables -C INPUT -s $selected_ip/32 -p tcp -m tcp --dport 53 -j ACCEPT 2>/dev/null; then
        iptables -D INPUT -s $selected_ip/32 -p tcp -m tcp --dport 53 -j ACCEPT
        tcp_success=$?
    else
        echo "警告: TCP规则不存在，无法删除"
        tcp_success=1
    fi
    
    if iptables -C INPUT -s $selected_ip/32 -p udp -m udp --dport 53 -j ACCEPT 2>/dev/null; then
        iptables -D INPUT -s $selected_ip/32 -p udp -m udp --dport 53 -j ACCEPT
        udp_success=$?
    else
        echo "警告: UDP规则不存在，无法删除"
        udp_success=1
    fi
    
    # 只有当至少一个规则成功删除时才保存规则
    if [ $tcp_success -eq 0 ] || [ $udp_success -eq 0 ]; then
        echo "IP地址 $selected_ip 已从白名单中删除"
        save_rules
    else
        echo "错误: 无法删除IP地址 $selected_ip，可能已被其他方式移除"
    fi
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
    # 使用更灵活的方式检测DROP规则，适应不同系统的iptables输出格式
    tcp_drop_exists=$(iptables-save | grep "INPUT" | grep "tcp" | grep "dport 53" | grep "DROP" | wc -l)
    udp_drop_exists=$(iptables-save | grep "INPUT" | grep "udp" | grep "dport 53" | grep "DROP" | wc -l)
    
    # 也可以直接检查iptables规则
    tcp_drop_direct=$(iptables -L INPUT -n | grep "tcp dpt:53" | grep "DROP" | wc -l)
    udp_drop_direct=$(iptables -L INPUT -n | grep "udp dpt:53" | grep "DROP" | wc -l)
    
    if [ "$tcp_drop_exists" -gt 0 ] || [ "$udp_drop_exists" -gt 0 ] || [ "$tcp_drop_direct" -gt 0 ] || [ "$udp_drop_direct" -gt 0 ]; then
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
                    # 先删除可能存在的旧规则
                    iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport 53 -j DROP 2>/dev/null
                    iptables -D INPUT -p udp -m state --state NEW -m udp --dport 53 -j DROP 2>/dev/null
                    
                    # 重新添加DROP规则，确保它们在所有白名单规则之后
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
        echo "==== 流媒体解锁IP白名单管理 ===="
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
