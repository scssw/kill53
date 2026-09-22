#!/usr/bin/env bash
# ==============================================================================
# 自动备份配置与定时任务脚本 (backup.sh)
# 功能：
# 1. 自动检测并安装 rsync、sshpass、cron 等必要依赖
# 2. 获取本机IP末两位
# 3. 交互式配置远程备份主机并打通SSH免密连接，保存连接记录
# 4. 菜单支持多选 (如 1 2)，支持自定义目录 (选项4)
# 5. 自动配置 crontab 定时备份任务并在远程主机预建目录
# ==============================================================================

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo_info() {
    echo -e "${CYAN}[信息]${PLAIN} $1"
}

echo_success() {
    echo -e "${GREEN}[成功]${PLAIN} $1"
}

echo_warn() {
    echo -e "${YELLOW}[警告]${PLAIN} $1"
}

echo_err() {
    echo -e "${RED}[错误]${PLAIN} $1"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo_err "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
fi

# 1. 自动检测并安装依赖
check_and_install_dependencies() {
    echo_info "正在检查并安装所需依赖 (rsync, sshpass, cron, curl)..."
    
    local pkgs_to_install=()

    if ! command -v rsync &>/dev/null; then
        pkgs_to_install+=("rsync")
    fi

    if ! command -v sshpass &>/dev/null; then
        pkgs_to_install+=("sshpass")
    fi

    if ! command -v crontab &>/dev/null; then
        pkgs_to_install+=("cron")
    fi

    if ! command -v curl &>/dev/null; then
        pkgs_to_install+=("curl")
    fi

    if ! command -v ssh-keygen &>/dev/null || ! command -v ssh-copy-id &>/dev/null; then
        pkgs_to_install+=("openssh-client")
    fi

    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        echo_info "正在安装缺失的依赖: ${pkgs_to_install[*]}..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y
            apt-get install -y "${pkgs_to_install[@]}"
        elif command -v yum &>/dev/null; then
            # CentOS / RHEL / AlmaLinux
            # sshpass 通常在 epel-release 中
            if ! command -v sshpass &>/dev/null; then
                yum install -y epel-release 2>/dev/null
            fi
            # cron 包名处理
            local yum_pkgs=()
            for pkg in "${pkgs_to_install[@]}"; do
                if [ "$pkg" == "cron" ]; then
                    yum_pkgs+=("cronie")
                elif [ "$pkg" == "openssh-client" ]; then
                    yum_pkgs+=("openssh-clients")
                else
                    yum_pkgs+=("$pkg")
                fi
            done
            yum install -y "${yum_pkgs[@]}"
        elif command -v apk &>/dev/null; then
            apk update
            apk add "${pkgs_to_install[@]}"
        else
            echo_warn "未识别的包管理器，请手动确保安装了: ${pkgs_to_install[*]}"
        fi
    else
        echo_success "所需依赖已全部安装，跳过安装步骤。"
    fi

    # 启动并自启 cron 服务
    if command -v systemctl &>/dev/null; then
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null
    elif command -v service &>/dev/null; then
        service cron start 2>/dev/null || service crond start 2>/dev/null
    fi
}

# 2. 获取本机公网 IP 及末两位
get_ip_tail() {
    echo_info "正在获取本机公网 IP 地址..."
    local local_ip=""
    
    # 尝试公网 API
    local_ip=$(curl -s4 -m 5 https://api.ipify.org 2>/dev/null || \
               curl -s4 -m 5 https://ip.sb 2>/dev/null || \
               curl -s4 -m 5 https://ifconfig.me 2>/dev/null || \
               curl -s4 -m 5 https://icanhazip.com 2>/dev/null)

    # 若公网API获取失败，尝试从网卡获取
    if [[ -z "$local_ip" || ! "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d '\n')
    fi
    if [[ -z "$local_ip" || ! "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -z "$local_ip" ]]; then
        echo_warn "无法自动获取本机 IPv4，请输入本机 IP (如 1.2.113.24): "
        read -r local_ip
    fi

    # 提取末两位 (如 1.2.113.24 -> 113.24)
    IP_TAIL=$(echo "$local_ip" | awk -F. '{print $(NF-1)"."$NF}')
    echo_success "本机 IP: ${local_ip}，末两位识别为: ${IP_TAIL}"
}

# 3. 配置远程备份主机与免密认证
setup_remote_host() {
    echo ""
    echo "--------------------------------------------------------"
    echo "              配置远程备份主机与免密认证"
    echo "--------------------------------------------------------"
    local default_host="168.138.219.203"
    read -rp "请输入远程主机 IP [默认: ${default_host}]: " input_host
    REMOTE_HOST="${input_host:-$default_host}"

    read -rp "请输入远程主机 SSH 端口 [默认: 22]: " input_port
    REMOTE_PORT="${input_port:-22}"

    read -rp "请输入远程主机用户 [默认: root]: " input_user
    REMOTE_USER="${input_user:-root}"

    # 生成本地 SSH 密钥对（若不存在）
    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        echo_info "正在生成本机 SSH 密钥对..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa" -q
    fi

    # 输入密码并推送密钥
    echo ""
    read -rsp "请输入远程主机 (${REMOTE_USER}@${REMOTE_HOST}) 的密码: " REMOTE_PASS
    echo ""

    if [ -z "$REMOTE_PASS" ]; then
        echo_warn "密码为空，尝试直接检测免密连接..."
    else
        echo_info "正在配置免密认证并保存远程主机记录..."
        export SSHPASS="$REMOTE_PASS"
        sshpass -e ssh-copy-id -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null
        unset SSHPASS
    fi

    # 验证免密连接
    echo_info "正在测试与远程主机 ${REMOTE_HOST} 的免密连接..."
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo 'auth_ok'" 2>/dev/null | grep -q "auth_ok"; then
        echo_success "免密连接成功！远程主机记录已保存。"
    else
        echo_err "免密连接失败，请检查远程主机 IP、端口或密码是否正确。"
        read -rp "是否重新输入配置？(y/n) [默认: y]: " retry
        retry="${retry:-y}"
        if [[ "$retry" =~ ^[Yy]$ ]]; then
            setup_remote_host
        else
            echo_warn "跳过免密验证，后续定时任务可能因无权限无法执行。"
        fi
    fi
}

# 辅助函数：向远程主机确保创建目录
remote_mkdir() {
    local target_dir="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '$target_dir'" 2>/dev/null
}

# 辅助函数：添加定时任务到 crontab（避免重复）
add_cron_job() {
    local cron_line="$1"
    local desc="$2"
    
    # 提取用于排重的命令主体
    local cmd_body
    cmd_body=$(echo "$cron_line" | awk '{$1=$2=$3=$4=$5=""; print $0}' | sed -e 's/^[ \t]*//')

    # 获取现有 crontab 内容
    local current_cron
    current_cron=$(crontab -l 2>/dev/null || echo "")

    if echo "$current_cron" | grep -Fq "$cmd_body"; then
        echo_warn "定时任务已存在，无需重复添加: [${desc}]"
    else
        (echo "$current_cron"; echo "$cron_line") | sed '/^$/d' | crontab -
        echo_success "成功添加定时任务: [${desc}]"
        echo -e "  └─ ${CYAN}${cron_line}${PLAIN}"
    fi
}

# 4. 任务配置与菜单选择
choose_backup_tasks() {
    echo ""
    echo "========================================================"
    echo "                    选择备份任务"
    echo "========================================================"
    echo " 1、备份ssr        (/root/backup/ -> /root/backup/${IP_TAIL}ssr)"
    echo " 2、备份hui        (/etc/x-ui/ -> /root/backup/x-ui/${IP_TAIL}hui)"
    echo " 3、备份xui        (/usr/local/h-ui/data/ -> /root/backup/hui/${IP_TAIL}hui)"
    echo " 4、备份指定目录   (如 /usr/share/awk -> /root/backup/usr/share/awk/${IP_TAIL}any)"
    echo "========================================================"
    echo "说明: 1~3 选项可组合多选，例如输入 '1 2' 或 '1 3' 即可同时配置多个任务"
    echo ""

    read -rp "请输入选项编号 (如 1 或 1 2 或 4): " user_choice

    if [[ -z "$user_choice" ]]; then
        echo_err "未输入任何选项，退出。"
        exit 1
    fi

    # 构造 rsync 基础参数
    local rsync_ssh_arg=""
    if [ "$REMOTE_PORT" != "22" ]; then
        rsync_ssh_arg="-e 'ssh -p ${REMOTE_PORT}' "
    fi

    # 分词解析用户输入
    local choices=()
    for item in $(echo "$user_choice" | tr ',' ' '); do
        choices+=("$item")
    done

    for c in "${choices[@]}"; do
        case "$c" in
            1)
                local src="/root/backup/"
                local dest_dir="/root/backup/${IP_TAIL}ssr"
                remote_mkdir "$dest_dir"
                local cron_cmd="3 */1 * * * rsync -avz ${rsync_ssh_arg}${src} ${REMOTE_USER}@${REMOTE_HOST}:${dest_dir}"
                add_cron_job "$cron_cmd" "1、备份ssr (每1小时第3分钟)"
                ;;
            2)
                local src="/etc/x-ui/"
                local dest_dir="/root/backup/x-ui/${IP_TAIL}hui"
                remote_mkdir "$dest_dir"
                local cron_cmd="3 */2 * * * rsync -avz ${rsync_ssh_arg}${src} ${REMOTE_USER}@${REMOTE_HOST}:${dest_dir}"
                add_cron_job "$cron_cmd" "2、备份hui (每2小时第3分钟)"
                ;;
            3)
                local src="/usr/local/h-ui/data/"
                local dest_dir="/root/backup/hui/${IP_TAIL}hui"
                remote_mkdir "$dest_dir"
                local cron_cmd="3 */3 * * * rsync -avz ${rsync_ssh_arg}${src} ${REMOTE_USER}@${REMOTE_HOST}:${dest_dir}"
                add_cron_job "$cron_cmd" "3、备份xui (每3小时第3分钟)"
                ;;
            4)
                echo ""
                read -rp "请输入要定时备份的目录绝对路径 (如 /usr/share/awk): " custom_dir
                if [[ -z "$custom_dir" ]]; then
                    echo_warn "未输入目录路径，跳过选项 4。"
                    continue
                fi
                # 去除末尾斜杠以统一样式
                local clean_dir="${custom_dir%/}"
                local src="${clean_dir}/"
                local dest_dir="/root/backup${clean_dir}/${IP_TAIL}any"
                remote_mkdir "$dest_dir"
                local cron_cmd="3 */4 * * * rsync -avz ${rsync_ssh_arg}${src} ${REMOTE_USER}@${REMOTE_HOST}:${dest_dir}"
                add_cron_job "$cron_cmd" "4、备份指定目录 ${custom_dir} (每4小时第3分钟)"
                ;;
            *)
                echo_warn "忽略未知选项: $c"
                ;;
        esac
    done
}

# 主执行流程
main() {
    clear 2>/dev/null || true
    echo "========================================================"
    echo "            VPS 自动备份与定时同步脚本"
    echo "========================================================"
    check_and_install_dependencies
    get_ip_tail
    setup_remote_host
    choose_backup_tasks

    echo ""
    echo "========================================================"
    echo_success "所有选定的备份任务已配置完成！"
    echo "当前 VPS 的 Crontab 任务列表如下："
    echo "--------------------------------------------------------"
    crontab -l | grep rsync || echo "未找到 rsync 任务"
    echo "--------------------------------------------------------"
    echo_info "如需手动测试某条备份命令，可直接复制上述 rsync 命令在终端执行。"
    echo "========================================================"
}

main "$@"
