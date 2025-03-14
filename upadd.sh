#!/bin/bash

# 目标配置文件路径
CONFIG_FILE="/usr/local/SSR-Bash-Python/easyadd.conf"

# 备份原始配置文件
if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    echo "已备份原始配置文件为 ${CONFIG_FILE}.bak"
fi

# 写入新的配置内容
cat > "$CONFIG_FILE" <<EOF
um1="none"           # 加密方式
ux1="auth_chain_a"   # 协议
uo1="plain"          # 混淆
iflimitspeed='n'     # 是否限速，默认为 n
us='6666'            # 限速值，默认 2048K/s
iflimittime='y'      # 是否限制帐号有效期，默认为 y
limit='12m'          # 帐号有效期，默认一个月，需要上一项打开才能生效
EOF

echo "配置文件已更新为默认不限速。"
