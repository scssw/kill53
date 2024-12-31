#!/bin/bash

# 定义目标文件路径
SYSCTL_CONF="/etc/sysctl.conf"

# 提示备份原文件
echo "备份原始的 $SYSCTL_CONF 文件..."
cp $SYSCTL_CONF "${SYSCTL_CONF}.backup.$(date +%F-%T)"

# 写入新配置
echo "覆盖写入优化参数到 $SYSCTL_CONF..."
cat > $SYSCTL_CONF << EOF
# 提高 TCP 缓存性能
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# 调整 TCP 窗口大小
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 启用 TCP 快速打开（TFO）
net.ipv4.tcp_fastopen = 3

# 减少 SYN 重传
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# 禁用 TCP 时间戳（减少带宽占用）
net.ipv4.tcp_timestamps = 0

# 启用 BBR 拥塞控制算法
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# 增大 UDP 缓存区大小
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400

# 增大 UDP 的默认缓冲区
net.core.optmem_max = 25165824
EOF

# 使新配置生效
echo "使配置生效..."
sysctl -p

echo "完成！新配置已成功应用。"
