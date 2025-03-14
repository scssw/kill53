#!/bin/bash
# persistent_tc.sh
# 本脚本用于设置/取消限速，并同时设置/关闭开机自动运行。
# 请根据实际情况修改 IFACE 为您使用的网络接口名称
IFACE="eth0"
LIMIT=80  # 限速值，单位 Mbps

# 当传入参数时（用于 systemd 调用），按参数执行操作
if [ "$1" == "start" ]; then
    echo "设置 $IFACE 限速为 ${LIMIT} Mbps..."
    # 删除已有规则（若存在）
    tc qdisc del dev $IFACE root 2>/dev/null
    # 使用 TBF 限速配置
    tc qdisc add dev $IFACE root tbf rate ${LIMIT}mbit burst 32kbit latency 400ms
    exit 0
fi

if [ "$1" == "stop" ]; then
    echo "取消 $IFACE 限速..."
    tc qdisc del dev $IFACE root 2>/dev/null
    exit 0
fi

if [ "$1" == "status" ]; then
    echo "当前 $IFACE 限速配置："
    tc qdisc show dev $IFACE
    exit 0
fi

# 如果没有传入参数，则进入交互式菜单
echo "请选择一个选项："
echo "1. 设置限速并启用开机自动运行 (限速 ${LIMIT} Mbps)"
echo "2. 取消限速并关闭开机自动运行"
echo "3. 查看当前限速配置"
read -p "输入选项编号: " OPTION

# systemd 单元文件存放路径
UNIT_FILE="/etc/systemd/system/limit_tc.service"
SCRIPT_PATH="/usr/local/bin/persistent_tc.sh"

case $OPTION in
    1)
        # 设置限速
        bash "$SCRIPT_PATH" start
        echo "限速设置成功。正在创建 systemd 服务单元以实现开机自动运行..."
        # 创建 systemd 服务单元文件
        cat <<EOF > $UNIT_FILE
[Unit]
Description=TC 限速服务
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH start
ExecStop=$SCRIPT_PATH stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        # 重新加载 systemd 配置，并启用服务
        systemctl daemon-reload
        systemctl enable limit_tc.service
        echo "开机自动运行限速配置已启用。"
        ;;
    2)
        # 取消限速
        bash "$SCRIPT_PATH" stop
        echo "限速已取消。正在禁用开机自动运行..."
        systemctl disable limit_tc.service
        # 可选择删除单元文件
        rm -f $UNIT_FILE
        systemctl daemon-reload
        echo "开机自动运行已关闭。"
        ;;
    3)
        # 查看当前限速配置
        bash "$SCRIPT_PATH" status
        ;;
    *)
        echo "无效的选项。"
        ;;
esac
