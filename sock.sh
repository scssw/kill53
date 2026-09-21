#!/bin/sh

# 定义安装函数：逐个安装并包含错误重试机制
install_pkg() {
    PKG_NAME=$1
    MAX_RETRIES=3
    ATTEMPT=1

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
        echo "正在安装 $PKG_NAME (尝试 $ATTEMPT/$MAX_RETRIES)..."
        if apk add "$PKG_NAME"; then
            echo "$PKG_NAME 安装成功！"
            return 0
        else
            echo "$PKG_NAME 安装失败，2秒后重试..."
            sleep 2
            ATTEMPT=$((ATTEMPT + 1))
        fi
    done

    echo "错误：无法安装 $PKG_NAME，请检查网络或系统状态。"
    exit 1
}

# 1. 逐个安装依赖，降低内存峰值
echo ">>> 开始更新软件源并安装依赖..."
apk update
install_pkg git
install_pkg gcc
install_pkg musl-dev
install_pkg make

# 2. 拉取源码并编译
echo ">>> 开始拉取 microsocks 源码并编译..."
cd /root || exit 1
# 如果之前克隆过，先清理目录
rm -rf microsocks 
git clone https://github.com/rofl0r/microsocks.git
cd microsocks || exit 1

make clean 2>/dev/null
make

# 移动二进制文件并清理源码目录
cp microsocks /usr/local/bin/
cd /root || exit 1
rm -rf microsocks

echo ">>> microsocks 编译并安装完成！"
echo "------------------------------------------------"

# 3. 交互式获取用户输入
printf "请输入服务器地址 (IP或域名): "
read SERVER_IP

printf "请输入 SOCKS5 监听端口 (例如 1080): "
read SERVER_PORT

# 设定用户名和密码
SOCKS_USER="scssw"
SOCKS_PASS="0062506scs"

# 4. 后台运行节点
# 先清理可能正在运行的旧进程
killall microsocks 2>/dev/null

# 启动 microsocks (-p 端口 -u 用户名 -P 密码)
nohup microsocks -p "$SERVER_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS" > /tmp/microsocks.log 2>&1 &

# 5. 输出结果与测试命令
echo "------------------------------------------------"
echo "✅ SOCKS5 节点已在后台成功启动！"
echo "👉 测试命令如下（可复制在本地终端运行）："
echo ""
echo "curl --socks5-hostname ${SOCKS_USER}:${SOCKS_PASS}@${SERVER_IP}:${SERVER_PORT} https://ifconfig.me"
echo ""
echo "如需停止服务，请运行命令: killall microsocks"
