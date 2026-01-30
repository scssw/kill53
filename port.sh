#!/bin/bash

# 获取用户输入的端口号
read -p "请输入要检测的端口号: " PORT

# 检查端口号是否为空
if [ -z "$PORT" ]; then
    echo "错误: 端口号不能为空。请重新运行脚本并输入端口号。"
    exit 1
fi

echo "\n正在检测端口 $PORT ..."

# 使用 netstat -tlunp 检测端口
# -t: TCP, -l: Listening sockets, -u: UDP, -n: Numeric addresses, -p: Show PID/Program name
# 注意 grep " $PORT " 确保匹配的是端口号，避免匹配到PID等其他数字
NETSTAT_RESULT=$(netstat -tlunp | grep -E ":$PORT " | grep LISTEN)

# 检查 netstat 结果
if [ -z "$NETSTAT_RESULT" ]; then
    echo "端口 $PORT 未被占用。"
else
    echo "\n端口 $PORT 已被占用，详细信息如下："
    echo "-------------------------------------"
    echo "$NETSTAT_RESULT"
    echo "-------------------------------------"
fi
