#!/bin/bash
# speed.sh
# 本脚本用于设置/取消限速，并自动配置/取消开机自启动，无需手动保存到指定位置。
# 请根据实际情况修改 IFACE 为您使用的网络接口名称。

# 默认保存路径（用于 process substitution 运行时自动保存）
DEFAULT_SCRIPT_PATH="/usr/local/bin/speed.sh"

# 判断脚本是否以文件形式运行
if [ ! -f "$0" ]; then
    # $0 不存在表示是以管道方式运行
    SCRIPT_PATH="$DEFAULT_SCRIPT_PATH"
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "当前脚本以临时方式运行，正在自动保存到 $SCRIPT_PATH ..."
        curl -sSL "https://raw.githubusercontent.com/scssw/kill53/refs/heads/main/speed.sh" -o "$SCRIPT_PATH"
        if [ $? -ne 0 ]; then
            echo "保存脚本到 $SCRIPT_PATH 失败，请检查网络连接及权限。"
            exit 1
        fi
        chmod +x "$SCRIPT_PATH"
        echo "脚本已保存到 $SCRIPT_PATH"
    fi
else
    SCRIPT_PATH=$(readlink -f "$0")
fi

# 网络接口名称（请根据实际情况修改）
IFACE="eth0"
# 限速值，单位 Mbps
LIMIT=80

# systemd 单元文件路径
UNIT_FILE="/etc/systemd/system/limit_tc.service"

# 以下部分为 systemd 调用接口（支持 start|stop|status 参数）
if [ "$1" == "start" ]; then
    echo "设置 $IFACE 限速为 ${LIMIT} Mbps..."
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc add dev "$IFACE" root tbf rate ${LIMIT}mbit burst 32kbit latency 400ms
    exit 0
fi

if [ "$1" == "stop" ]; then
    echo "取消 $IFACE 限速..."
    tc qdisc del dev "$IFACE" root 2>/dev/null
    exit 0
fi

if [ "$1" == "status" ]; then
    echo "当前 $IFACE 限速配置："
    tc qdisc show dev "$IFACE"
    exit 0
fi

# 交互式菜单
echo "请选择一个选项："
echo "1. 设置限速并启用开机自启动 (限速 ${LIMIT} Mbps)"
echo "2. 取消限速并关闭开机自启动"
echo "3. 查看当前限速配置"
read -p "输入选项编号: " OPTION

case $OPTION in
    1)
        # 设置限速
        bash "$SCRIPT_PATH" start
        echo "限速设置成功。正在创建 systemd 服务单元以实现开机自启动..."
        cat <<EOF > "$UNIT_FILE"
[Unit]
Description=TC 限速服务
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} start
ExecStop=${SCRIPT_PATH} stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable limit_tc.service
        echo "开机自启动限速配置已启用。"
        ;;
    2)
        # 取消限速
        bash "$SCRIPT_PATH" stop
        echo "限速已取消。正在禁用开机自启动..."
        systemctl disable limit_tc.service
        rm -f "$UNIT_FILE"
        systemctl daemon-reload
        echo "开机自启动已关闭。"
        ;;
    3)
        bash "$SCRIPT_PATH" status
        ;;
    *)
        echo "无效的选项。"
        ;;
esac
