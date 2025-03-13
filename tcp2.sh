#!/bin/bash

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}TCP 网络优化脚本${RESET}"
echo "1) 100ms 延迟优化配置"
echo "2) 200ms 延迟优化配置"
echo -n "请选择优化配置 (1-2): "
read choice

# 备份当前设置
backup_sysctl() {
    cp /etc/sysctl.conf /etc/sysctl.conf.bak
    echo -e "${YELLOW}已备份原配置到 /etc/sysctl.conf.bak${RESET}"
}

optimize_100ms() {
    cat > /etc/sysctl.conf << EOF
# 基础网络优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 16777216
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192

# TCP 缓冲区
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_mem = 786432 1048576 16777216

# TCP 连接优化
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3

# TCP 拥塞控制
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3

# 连接跟踪
net.netfilter.nf_conntrack_max = 131072
net.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# 系统限制
fs.file-max = 524288
fs.nr_open = 524288
EOF
}

optimize_200ms() {
    cat > /etc/sysctl.conf << EOF
# 基础网络优化
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.optmem_max = 67108864
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# TCP 缓冲区
net.ipv4.tcp_rmem = 4096 2097152 67108864
net.ipv4.tcp_wmem = 4096 2097152 67108864
net.ipv4.tcp_mem = 786432 4194304 67108864

# TCP 连接优化
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# TCP 拥塞控制
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3

# 连接跟踪
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60

# 系统限制
fs.file-max = 1048576
fs.nr_open = 1048576
EOF
}

apply_common_settings() {
    # 设置系统最大打开文件数
    ulimit -n 1048576

    # 设置系统限制
    cat > /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    # 优化网卡设置
    for i in $(find /sys/class/net -type l -not -lname '*virtual*' -printf '%f\n'); do
        ethtool -G $i rx 4096 tx 4096 2>/dev/null
        ethtool -A $i autoneg off rx off tx off 2>/dev/null
        ethtool -K $i gro on gso on tso on 2>/dev/null
    done
}

case $choice in
    1)
        echo -e "${GREEN}应用 100ms 延迟优化配置...${RESET}"
        backup_sysctl
        optimize_100ms
        apply_common_settings
        ;;
    2)
        echo -e "${GREEN}应用 200ms 延迟优化配置...${RESET}"
        backup_sysctl
        optimize_200ms
        apply_common_settings
        ;;
    *)
        echo -e "${RED}无效的选择！${RESET}"
        exit 1
        ;;
esac

# 应用新的参数
sysctl -p

echo -e "${GREEN}TCP优化完成！${RESET}"
echo -e "${YELLOW}请注意：新的配置将在系统重启后生效${RESET}" 
