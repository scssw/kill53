#!/bin/bash

# 网络接口名称
IFACE="eth0"

# 限速值（以 Mbps 为单位）
LIMIT=80

# 将 Mbps 转换为 Kbps
LIMIT_KBPS=$((LIMIT * 1024))

# 显示菜单
echo "请选择一个选项："
echo "1. 限速 ${LIMIT} Mbps"
echo "2. 取消限速"
echo "3. 查看限速"
read -p "输入选项编号: " OPTION

case $OPTION in
    1)
        echo "正在设置限速为 ${LIMIT} Mbps..."
        # 删除现有的队列规则
        tc qdisc del dev $IFACE root 2>/dev/null
        # 添加根队列规则
        tc qdisc add dev $IFACE root handle 1: htb default 1
        # 添加主类
        tc class add dev $IFACE parent 1: classid 1:1 htb rate ${LIMIT_KBPS}kbit ceil ${LIMIT_KBPS}kbit
        # 应用限速到网络接口
        tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip dst 0.0.0.0/0 flowid 1:1
        echo "限速已设置为 ${LIMIT} Mbps。"
        ;;
    2)
        echo "正在取消限速..."
        # 删除现有的队列规则
        tc qdisc del dev $IFACE root 2>/dev/null
        echo "限速已取消。"
        ;;
    3)
        echo "当前限速情况："
        # 显示当前的队列规则
        tc qdisc show dev $IFACE
        ;;
    *)
        echo "无效的选项。"
        ;;
esac
