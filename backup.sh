#!/usr/bin/env bash
# ==============================================================================
# 自动备份配置与定时任务脚本 (backup.sh)
# 功能：
# 1. 兼容 curl ... | bash 管道运行与终端直接运行
# 2. 自动检测并安装 rsync、cron、curl 等必要依赖
# 3. 自动识别本机公网 IP 并提取末两位
# 4. 使用标准的 ssh-keygen 与 ssh-copy-id 原生交互免密方式记住密码
# 5. 菜单支持 1~3 多选 (如 "1 2") 以及 4 自定义目录
# 6. 自动写入 crontab 定时备份任务并在远程主机预建目录
# ==============================================================================

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 统一终端输入读取函数，彻底解决 curl ... | bash 管道导致的 stdin 无法交互问题
read_input() {
    if [ -e /dev/tty ]; then
        read "$@" < /dev/tty
    else
        read "$@"
    fi
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo_err "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
fi

# 1. 自动检测并安装依赖
check_and_install_dependencies() {
    echo_info "正在检查并安装所需依赖 (rsync, cron, curl, openssh)..."
    
    local pkgs_to_install=()

    if ! command -v rsync &>/dev/null; then
        pkgs_to_install+=("rsync")
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
    
    # 优先通过公网 API 获取公网 IPv4
    local_ip=$(curl -s4 -m 5 https://api.ipify.org 2>/dev/null || \
               curl -s4 -m 5 https://ip.sb 2>/dev/null || \
               curl -s4 -m 5 https://ifconfig.me 2>/dev/null || \
               curl -s4 -m 5 https://icanhazip.com 2>/dev/null)

    # 若公网 API 失败，尝试本地网卡
    if [[ -z "$local_ip" || ! "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d '\n')
    fi
    if [[ -z "$local_ip" || ! "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -z "$local_ip" ]]; then
        echo_warn "无法自动获取本机 IPv4，请输入本机 IP (如 1.2.113.24): "
        read_input -r local_ip
    fi

    # 提取末两位 (如 107.173.39.53 -> 39.53)
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
    read_input -rp "请输入远程主机 IP [默认: ${default_host}]: " input_host
    REMOTE_HOST="${input_host:-$default_host}"

    read_input -rp "请输入远程主机 SSH 端口 [默认: 22]: " input_port
    REMOTE_PORT="${input_port:-22}"

    read_input -rp "请输入远程主机用户 [默认: root]: " input_user
    REMOTE_USER="${input_user:-root}"

    # 1) 如果本机没有密钥，自动生成 ssh-keygen
    if [ ! -f "$HOME/.ssh/id_rsa" ] && [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        echo_info "未检测到本地 SSH 密钥，正在自动生成 (ssh-keygen -t rsa -b 2048)..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa" -q
        echo_success "SSH 密钥已生成。"
    fi

    # 2) 检查是否已经免密连接
    echo_info "正在测试是否已存在免密连接..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo 'auth_ok'" 2>/dev/null | grep -q "auth_ok"; then
        echo_success "已检测到对远程主机 ${REMOTE_HOST} 的免密连接有效，无需重新分发密钥！"
        return 0
    fi

    # 3) 执行标准的 ssh-copy-id 将公钥分发至远程主机
    echo_info "正在使用 ssh-copy-id 推送公钥，请在下方提示时输入远程主机密码："
    echo "--------------------------------------------------------"
    
    # 将标准输入定向到 /dev/tty，确保在 curl ... | bash 下也能正常交互输入密码
    if [ -e /dev/tty ]; then
        ssh-copy-id -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" < /dev/tty
    else
        ssh-copy-id -o StrictHostKeyChecking=no -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}"
    fi
    echo "--------------------------------------------------------"

    # 4) 验证免密连接
    echo_info "正在复核与远程主机 ${REMOTE_HOST} 的免密连接..."
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "echo 'auth_ok'" 2>/dev/null | grep -q "auth_ok"; then
        echo_success "免密连接配置成功！远程主机记录已成功保存。"
    else
        echo_err "免密连接未能建立，可能密码输入有误或连接被拒绝。"
        read_input -rp "是否重新尝试输入密码与配置？(y/n) [默认: y]: " retry
        retry="${retry:-y}"
        if [[ "$retry" =~ ^[Yy]$ ]]; then
            setup_remote_host
        else
            echo_warn "已跳过免密验证，请注意后续定时任务可能因权限不足而失败。"
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

    read_input -rp "请输入选项编号 (如 1 或 1 2 或 4): " user_choice

    if [[ -z "$user_choice" ]]; then
        echo_err "未输入任何选项，退出。"
        exit 1
    fi

    # 构造 rsync 基础参数
    local rsync_ssh_arg=""
    if [ "$REMOTE_PORT" != "22" ]; then
        rsync_ssh_arg="-e 'ssh -p ${REMOTE_PORT}' "
    fi

    # 分词解析用户输入（兼容空格或逗号分隔）
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
                read_input -rp "请输入要定时备份的目录绝对路径 (如 /usr/share/awk): " custom_dir
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
