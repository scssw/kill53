#!/bin/sh
# ==============================================================================
# 脚本名称: sock5.sh
# 功能描述: MicroSocks SOCKS5 一键安装与多节点管理脚本
# 支持系统: Alpine Linux / Debian / Ubuntu / CentOS 等
# ==============================================================================

set -e

CONFIG_DIR="/etc/microsocks"
NODES_DIR="/etc/microsocks/nodes"
BIN_PATH="/usr/local/bin/microsocks"
SCRIPT_INSTALL_PATH="/usr/local/bin/sock5"

# 颜色输出定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

# 打印带颜色的信息
info() {
    printf "${CYAN}[信息] %s${RESET}\n" "$1"
}

success() {
    printf "${GREEN}[成功] %s${RESET}\n" "$1"
}

warn() {
    printf "${YELLOW}[警告] %s${RESET}\n" "$1"
}

error() {
    printf "${RED}[错误] %s${RESET}\n" "$1"
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 权限运行此脚本！例如: sudo sh $0"
        exit 1
    fi
}

# 识别系统类型
detect_os() {
    if [ -f /etc/alpine-release ] || ( [ -f /etc/os-release ] && grep -qi "alpine" /etc/os-release ); then
        OS_TYPE="alpine"
        OS_NAME="Alpine Linux"
    elif [ -f /etc/debian_version ] || ( [ -f /etc/os-release ] && grep -qiE "debian|ubuntu" /etc/os-release ); then
        OS_TYPE="debian"
        OS_NAME="Debian/Ubuntu"
    elif command -v apk >/dev/null 2>&1; then
        OS_TYPE="alpine"
        OS_NAME="Alpine Linux"
    elif command -v apt-get >/dev/null 2>&1; then
        OS_TYPE="debian"
        OS_NAME="Debian/Ubuntu"
    else
        OS_TYPE="unknown"
        OS_NAME="未知系统"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s4 --max-time 2 ip.sb 2>/dev/null || curl -s4 --max-time 2 icanhazip.com 2>/dev/null || curl -s4 --max-time 2 ifconfig.me 2>/dev/null || curl -s4 --max-time 2 api.ipify.org 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- --timeout=2 ip.sb 2>/dev/null || wget -qO- --timeout=2 icanhazip.com 2>/dev/null || wget -qO- --timeout=2 ifconfig.me 2>/dev/null || true)
    fi

    # 如果无法获取外网 IP，获取本机第一个内网 IP
    if [ -z "$ip" ]; then
        if command -v ip >/dev/null 2>&1; then
            ip=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '127.0.0.1' | head -n 1 || true)
        elif command -v ifconfig >/dev/null 2>&1; then
            ip=$(ifconfig 2>/dev/null | grep -oE 'inet (addr:)?([0-9]+\.){3}[0-9]+' | awk '{print $2}' | tr -d 'addr:' | grep -v '127.0.0.1' | head -n 1 || true)
        fi
    fi

    if [ -z "$ip" ]; then
        ip="服务器IP"
    fi
    echo "$ip" | tr -d ' \n\r'
}

# 显示节点配置与连接地址详情
show_node_connection_info() {
    local port="$1"
    local user="$2"
    local pass="$3"
    local server_ip
    server_ip=$(get_public_ip)

    # 计算 Base64 用户名:密码认证串 (如有 base64 命令)
    local b64_auth=""
    if command -v base64 >/dev/null 2>&1; then
        b64_auth=$(printf "%s:%s" "$user" "$pass" | base64 2>/dev/null | tr -d '\r\n' || true)
    fi

    printf "${GREEN}================================================================${RESET}\n"
    printf "${BOLD}${GREEN}               SOCKS5 节点配置与连接地址详情                    ${RESET}\n"
    printf "${GREEN}================================================================${RESET}\n"
    printf "  ${BOLD}【基础连接信息】${RESET}\n"
    printf "  • 代理协议 (Type)   : SOCKS5\n"
    printf "  • 服务器地址 (Host) : ${CYAN}%s${RESET}\n" "$server_ip"
    printf "  • 服务端口 (Port)   : ${CYAN}%s${RESET}\n" "$port"
    printf "  • 认证用户 (User)   : %s\n" "$user"
    printf "  • 认证密码 (Pass)   : %s\n" "$pass"
    printf -- "----------------------------------------------------------------\n"
    printf "  ${BOLD}【一键导入/连接地址】${RESET}\n"
    printf "  • 标准 SOCKS5 链接  :\n"
    printf "    ${YELLOW}socks5://%s:%s@%s:%s${RESET}\n" "$user" "$pass" "$server_ip" "$port"
    if [ -n "$b64_auth" ]; then
        printf "  • Base64 格式链接 (部分客户端支持):\n"
        printf "    ${YELLOW}socks5://%s@%s:%s${RESET}\n" "$b64_auth" "$server_ip" "$port"
    fi
    printf "  • Telegram 一键代理链接 (App内直接唤起配置):\n"
    printf "    ${CYAN}tg://socks?server=%s&port=%s&user=%s&pass=%s${RESET}\n" "$server_ip" "$port" "$user" "$pass"
    printf "  • Telegram 网页代理链接 (浏览器打开直接导入):\n"
    printf "    ${CYAN}https://t.me/socks?server=%s&port=%s&user=%s&pass=%s${RESET}\n" "$server_ip" "$port" "$user" "$pass"
    printf "${GREEN}================================================================${RESET}\n"
}

# 安装开机自启服务
setup_autostart() {
    # 软链接或者复制脚本本身到 /usr/local/bin/sock5
    if [ -f "$0" ] && [ "$0" != "$SCRIPT_INSTALL_PATH" ]; then
        cp -f "$0" "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
        chmod +x "$SCRIPT_INSTALL_PATH" 2>/dev/null || true
    fi

    # Debian / Ubuntu (Systemd)
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        if [ ! -f /etc/systemd/system/microsocks.service ]; then
            cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=MicroSocks SOCKS5 Multi-Node Service
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_INSTALL_PATH --start-all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable microsocks.service >/dev/null 2>&1 || true
        fi
    # Alpine Linux (OpenRC)
    elif [ -d /etc/local.d ]; then
        if [ ! -f /etc/local.d/microsocks.start ]; then
            cat > /etc/local.d/microsocks.start <<EOF
#!/bin/sh
$SCRIPT_INSTALL_PATH --start-all
EOF
            chmod +x /etc/local.d/microsocks.start
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add local default >/dev/null 2>&1 || true
            fi
        fi
    fi
}

# 检查并安装依赖与 MicroSocks
check_and_install_microsocks() {
    detect_os
    mkdir -p "$CONFIG_DIR" "$NODES_DIR"

    if [ -x "$BIN_PATH" ] || command -v microsocks >/dev/null 2>&1; then
        setup_autostart
        return 0
    fi

    printf "${CYAN}==================================================${RESET}\n"
    printf "${BOLD}  未检测到 MicroSocks，正在为您自动编译安装...   ${RESET}\n"
    printf "${CYAN}==================================================${RESET}\n"
    info "检测到操作系统: $OS_NAME"
    info "正在安装所需编译依赖与工具..."

    if [ "$OS_TYPE" = "alpine" ]; then
        apk update || true
        apk add --no-cache build-base git musl-dev make procps curl ca-certificates bash
    elif [ "$OS_TYPE" = "debian" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || true
        apt-get install -y build-essential git gcc make procps curl ca-certificates
    else
        warn "未精确匹配系统类型，尝试通过常见包管理器安装依赖..."
        if command -v apk >/dev/null 2>&1; then
            apk update && apk add --no-cache build-base git musl-dev make procps curl ca-certificates bash
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y build-essential git gcc make procps curl ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y gcc make git procps-ng curl ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y gcc make git procps-ng curl ca-certificates
        else
            error "无法自动安装依赖，请先手动安装 git、make、gcc 等工具！"
            exit 1
        fi
    fi

    info "正在克隆 MicroSocks 源码..."
    BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'microsocks')

    # 先从官方 GitHub 克隆，若失败尝试镜像源
    if ! git clone --depth 1 https://github.com/rofl0r/microsocks.git "$BUILD_DIR/microsocks" 2>/dev/null; then
        info "官方源连接较慢，正在尝试镜像加速下载..."
        if ! git clone --depth 1 https://ghfast.top/https://github.com/rofl0r/microsocks.git "$BUILD_DIR/microsocks"; then
            error "源码下载失败，请检查网络或 GitHub 连通性！"
            rm -rf "$BUILD_DIR"
            exit 1
        fi
    fi

    info "正在编译 MicroSocks..."
    cd "$BUILD_DIR/microsocks"
    make clean 2>/dev/null || true
    
    CORES=1
    if command -v nproc >/dev/null 2>&1; then
        CORES=$(nproc 2>/dev/null || echo 1)
    fi
    make -j"$CORES" || make -j1

    if [ ! -f "microsocks" ]; then
        error "编译失败，未能生成 microsocks 可执行文件！"
        rm -rf "$BUILD_DIR"
        exit 1
    fi

    mkdir -p /usr/local/bin
    cp -f microsocks "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$BUILD_DIR"

    success "MicroSocks 编译安装完成！二进制文件路径: $BIN_PATH"
    setup_autostart
    sleep 1
}

# 检查端口是否被占用
check_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln 2>/dev/null | grep -E "(:|\])${port}[[:space:]]" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -E "(:|\])${port}[[:space:]]" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":$port" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 获取特定端口节点的运行 PID
get_node_pid() {
    local port="$1"
    local pid_file="$NODES_DIR/${port}.pid"
    local pid=""

    # 1. 尝试从 pid 文件读取
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # 确认进程是 microsocks
            if ps -p "$pid" -o args 2>/dev/null | grep -q "microsocks" || ps -p "$pid" 2>/dev/null | grep -q "microsocks"; then
                echo "$pid"
                return 0
            fi
        fi
    fi

    # 2. 尝试从 pgrep 中匹配端口
    if command -v pgrep >/dev/null 2>&1; then
        pid=$(pgrep -f "microsocks.*-p[[:space:]]+${port}([[:space:]]|$)" 2>/dev/null | head -n 1 || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid" > "$pid_file" 2>/dev/null || true
            echo "$pid"
            return 0
        fi
    fi

    return 1
}

# 启动单个节点
start_single_node() {
    local port="$1"
    local conf="$NODES_DIR/${port}.conf"
    [ -f "$conf" ] || return 1

    local pid
    pid=$(get_node_pid "$port" || true)
    if [ -n "$pid" ]; then
        return 0
    fi

    # 读取节点配置
    PORT="" USER="" PASS=""
    . "$conf"

    if [ -n "$USER" ] && [ -n "$PASS" ]; then
        nohup "$BIN_PATH" -i 0.0.0.0 -p "$PORT" -u "$USER" -P "$PASS" >/dev/null 2>&1 &
    else
        nohup "$BIN_PATH" -i 0.0.0.0 -p "$PORT" >/dev/null 2>&1 &
    fi

    local new_pid=$!
    echo "$new_pid" > "$NODES_DIR/${PORT}.pid"
    sleep 0.5
    if kill -0 "$new_pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 停止单个节点
stop_single_node() {
    local port="$1"
    local pid
    pid=$(get_node_pid "$port" || true)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "microsocks.*-p[[:space:]]+${port}([[:space:]]|$)" 2>/dev/null || true
    fi
    rm -f "$NODES_DIR/${port}.pid" 2>/dev/null || true
}

# 统计配置总数与运行中数量
count_nodes_status() {
    TOTAL_COUNT=0
    RUNNING_COUNT=0
    for f in "$NODES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        TOTAL_COUNT=$((TOTAL_COUNT + 1))
        local p
        p=$(basename "$f" .conf)
        local pid
        pid=$(get_node_pid "$p" || true)
        if [ -n "$pid" ]; then
            RUNNING_COUNT=$((RUNNING_COUNT + 1))
        fi
    done
}

# 启动所有已配置的节点
start_all_nodes() {
    info "正在启动所有已配置的 SOCKS5 节点..."
    local started=0
    for f in "$NODES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        local p
        p=$(basename "$f" .conf)
        if start_single_node "$p"; then
            started=$((started + 1))
        fi
    done
    success "已启动所有节点！(共检查启动 $started 个)"
}

# 停止所有 socks5 进程
stop_all_socks5() {
    printf "\n"
    info "正在停止所有运行中的 SOCKS5 进程 (pkill microsocks)..."
    if command -v pkill >/dev/null 2>&1; then
        pkill microsocks 2>/dev/null || true
    else
        killall microsocks 2>/dev/null || true
    fi
    sleep 0.5

    # 强制杀死残留
    if command -v pgrep >/dev/null 2>&1 && pgrep microsocks >/dev/null 2>&1; then
        pkill -9 microsocks 2>/dev/null || true
    fi

    # 清理所有 pid 记录
    rm -f "$NODES_DIR"/*.pid 2>/dev/null || true

    success "所有 SOCKS5 进程已成功停止！"
    printf "\n"
    printf "${CYAN}当前进程状态检查 (pgrep -a microsocks):${RESET}\n"
    printf -- "--------------------------------------------------\n"
    if command -v pgrep >/dev/null 2>&1 && pgrep -a microsocks 2>/dev/null; then
        :
    elif command -v ps >/dev/null 2>&1; then
        local ps_res
        ps_res=$(ps | grep microsocks | grep -v grep || true)
        if [ -n "$ps_res" ]; then
            echo "$ps_res"
        else
            printf "${GREEN}[正常] 未发现正在运行的 microsocks 进程。${RESET}\n"
        fi
    else
        printf "${GREEN}[正常] 未发现正在运行的 microsocks 进程。${RESET}\n"
    fi
    printf -- "--------------------------------------------------\n\n"
    printf "提示: 输入 1 可重新启动所有节点，按回车键直接返回主菜单: "
    read -r after_stop_act
    if [ "$after_stop_act" = "1" ]; then
        start_all_nodes
        printf "按回车键返回主菜单..."
        read -r _
    fi
}

# 列出所有已建节点
display_nodes_list() {
    printf "${CYAN}------------------ 已建节点列表 ------------------${RESET}\n"
    local count=0
    for f in "$NODES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        printf "  当前暂无已配置的 SOCKS5 节点。\n"
        printf -- "--------------------------------------------------\n"
        return 0
    fi

    printf "${BOLD}%-5s %-8s %-12s %-14s %-12s %-8s${RESET}\n" "序号" "端口" "用户名" "密码" "状态" "PID"
    printf -- "--------------------------------------------------\n"

    local idx=1
    for f in "$NODES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        PORT="" USER="" PASS=""
        . "$f"

        local pid
        pid=$(get_node_pid "$PORT" || true)
        local status_str
        local pid_str

        if [ -n "$pid" ]; then
            status_str="${GREEN}运行中${RESET}"
            pid_str="$pid"
        else
            status_str="${RED}已停止${RESET}"
            pid_str="-"
        fi

        printf "[%2d]  %-8s %-12s %-14s %-20b %-8s\n" "$idx" "$PORT" "$USER" "$PASS" "$status_str" "$pid_str"
        idx=$((idx + 1))
    done
    printf -- "--------------------------------------------------\n"
}

# 新建单个节点交互
add_single_node() {
    while true; do
        printf "\n${CYAN}==================================================${RESET}\n"
        printf "${BOLD}                 新建 SOCKS5 节点                 ${RESET}\n"
        printf "${CYAN}==================================================${RESET}\n"

        # 1. 输入端口
        local input_port=""
        while true; do
            printf "请输入端口 [1-65535] (输入 0 返回): "
            read -r input_port
            if [ "$input_port" = "0" ]; then
                return 0
            fi

            # 校验是否为纯数字
            case "$input_port" in
                ''|*[!0-9]*)
                    error "端口必须为有效纯数字！"
                    continue
                    ;;
            esac

            if [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
                error "端口号范围必须在 1 到 65535 之间！"
                continue
            fi

            # 检查是否已存在此端口配置
            if [ -f "$NODES_DIR/${input_port}.conf" ]; then
                error "端口 $input_port 已存在配置！若需修改请先删除该节点。"
                continue
            fi

            # 检查系统中该端口是否已被占用
            if check_port_in_use "$input_port"; then
                warn "系统端口 $input_port 当前已被占用，请更换其它未占用端口！"
                continue
            fi

            break
        done

        # 2. 输入用户名
        local input_user=""
        while true; do
            printf "请输入用户名 (支持字母、数字及 _ . - @): "
            read -r input_user
            if [ -z "$input_user" ]; then
                error "用户名不能为空！"
                continue
            fi
            # 校验用户名字符安全
            case "$input_user" in
                *[\'\"\ \\\/\|\&\;\$\<\>\`\!]*)
                    error "用户名包含非法字符，仅支持字母、数字和常用标点符号！"
                    continue
                    ;;
            esac
            break
        done

        # 3. 输入密码
        local input_pass=""
        while true; do
            printf "请输入密码: "
            read -r input_pass
            if [ -z "$input_pass" ]; then
                error "密码不能为空！"
                continue
            fi
            # 校验密码字符安全
            case "$input_pass" in
                *[\'\"\\\$]*)
                    error "为避免转义问题，密码请勿使用单双引号、反斜杠或美元符号！"
                    continue
                    ;;
            esac
            break
        done

        # 保存配置
        cat > "$NODES_DIR/${input_port}.conf" <<EOF
PORT="${input_port}"
USER="${input_user}"
PASS="${input_pass}"
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
EOF
        chmod 600 "$NODES_DIR/${input_port}.conf"

        # 启动该节点
        info "正在后台启动 SOCKS5 节点 (端口: $input_port)..."
        if start_single_node "$input_port"; then
            printf "\n"
            success "SOCKS5 节点已创建并后台运行！"
            printf "\n"
            # 建立节点后显示节点配置地址与连接信息
            show_node_connection_info "$input_port" "$input_user" "$input_pass"
        else
            error "节点启动失败，请检查端口 $input_port 是否异常！"
        fi

        printf "\n支持多建节点，继续按 1 可以继续创建，按 0 返回: "
        read -r next_step
        if [ "$next_step" != "1" ]; then
            break
        fi
    done
}

# 查看已建节点的配置与连接地址
menu_view_node_info() {
    while true; do
        printf "\n${CYAN}==================================================${RESET}\n"
        printf "${BOLD}             查看 SOCKS5 节点配置地址             ${RESET}\n"
        printf "${CYAN}==================================================${RESET}\n"

        local total=0
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            total=$((total + 1))
        done

        if [ "$total" -eq 0 ]; then
            info "当前暂无任何已配置的 SOCKS5 节点！"
            printf -- "--------------------------------------------------\n"
            printf "按回车键返回..."
            read -r _
            break
        fi

        printf "${BOLD}%-5s %-8s %-12s %-16s${RESET}\n" "序号" "端口" "用户名" "运行状态"
        printf -- "--------------------------------------------------\n"

        local idx=1
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            PORT="" USER="" PASS=""
            . "$f"

            local pid
            pid=$(get_node_pid "$PORT" || true)
            local status_str
            if [ -n "$pid" ]; then
                status_str="${GREEN}运行中 (PID: $pid)${RESET}"
            else
                status_str="${RED}已停止${RESET}"
            fi

            printf "[%2d]  %-8s %-12s %-24b\n" "$idx" "$PORT" "$USER" "$status_str"
            idx=$((idx + 1))
        done

        printf -- "--------------------------------------------------\n"
        printf " [ A] 显示全部节点的配置地址\n"
        printf " [ 0] 返回上级菜单\n"
        printf -- "--------------------------------------------------\n"
        printf "请输入要查看的节点编号 [0-%d / A]: " "$total"
        read -r view_num

        if [ "$view_num" = "0" ] || [ -z "$view_num" ]; then
            break
        fi

        if [ "$view_num" = "a" ] || [ "$view_num" = "A" ]; then
            printf "\n"
            for f in "$NODES_DIR"/*.conf; do
                [ -f "$f" ] || continue
                PORT="" USER="" PASS=""
                . "$f"
                show_node_connection_info "$PORT" "$USER" "$PASS"
                printf "\n"
            done
            printf "按回车键继续..."
            read -r _
            continue
        fi

        case "$view_num" in
            ''|*[!0-9]*)
                error "输入无效，请输入数字编号或 A ！"
                sleep 1
                continue
                ;;
        esac

        if [ "$view_num" -lt 1 ] || [ "$view_num" -gt "$total" ]; then
            error "数字编号超出范围！"
            sleep 1
            continue
        fi

        local curr_idx=0
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            curr_idx=$((curr_idx + 1))
            if [ "$curr_idx" -eq "$view_num" ]; then
                PORT="" USER="" PASS=""
                . "$f"
                printf "\n"
                show_node_connection_info "$PORT" "$USER" "$PASS"
                printf "\n"
                break
            fi
        done

        printf "按回车键继续..."
        read -r _
    done
}

# 菜单 1: 配置 sock5 节点
menu_config_node() {
    while true; do
        printf "\n"
        display_nodes_list
        printf "  1. 新建节点\n"
        printf "  2. 查看节点配置地址 (SOCKS5链接/TG链接/参数)\n"
        printf "  3. 启动所有已停止的节点\n"
        printf "  0. 返回主菜单\n"
        printf -- "--------------------------------------------------\n"
        printf "请输入选项 [0-3]: "
        read -r sub_choice

        case "$sub_choice" in
            1)
                add_single_node
                ;;
            2)
                menu_view_node_info
                ;;
            3)
                start_all_nodes
                printf "按回车键继续..."
                read -r _
                ;;
            0)
                break
                ;;
            *)
                warn "输入无效，请重新输入！"
                sleep 0.5
                ;;
        esac
    done
}

# 菜单 2: 删除 sock5 节点
menu_delete_node() {
    while true; do
        printf "\n${CYAN}==================================================${RESET}\n"
        printf "${BOLD}                 删除 SOCKS5 节点                 ${RESET}\n"
        printf "${CYAN}==================================================${RESET}\n"

        local total=0
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            total=$((total + 1))
        done

        if [ "$total" -eq 0 ]; then
            info "当前暂无任何已配置的 SOCKS5 节点！"
            printf -- "--------------------------------------------------\n"
            printf "按回车键返回主菜单..."
            read -r _
            break
        fi

        printf "${BOLD}%-5s %-8s %-12s %-16s${RESET}\n" "序号" "端口" "用户名" "运行状态"
        printf -- "--------------------------------------------------\n"

        local idx=1
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            PORT="" USER="" PASS=""
            . "$f"

            local pid
            pid=$(get_node_pid "$PORT" || true)
            local status_str
            if [ -n "$pid" ]; then
                status_str="${GREEN}运行中 (PID: $pid)${RESET}"
            else
                status_str="${RED}已停止${RESET}"
            fi

            printf "[%2d]  %-8s %-12s %-24b\n" "$idx" "$PORT" "$USER" "$status_str"
            idx=$((idx + 1))
        done

        printf -- "--------------------------------------------------\n"
        printf " [ 0] 返回主菜单\n"
        printf -- "--------------------------------------------------\n"
        printf "请输入要删除的节点数字编号 [0-%d]: " "$total"
        read -r del_num

        if [ "$del_num" = "0" ] || [ -z "$del_num" ]; then
            break
        fi

        case "$del_num" in
            ''|*[!0-9]*)
                error "输入无效，请输入列表中对应的数字序号！"
                sleep 1
                continue
                ;;
        esac

        if [ "$del_num" -lt 1 ] || [ "$del_num" -gt "$total" ]; then
            error "数字序号超出有效范围！"
            sleep 1
            continue
        fi

        # 找到对应编号的配置文件
        local curr_idx=0
        local target_conf=""
        local target_port=""
        for f in "$NODES_DIR"/*.conf; do
            [ -f "$f" ] || continue
            curr_idx=$((curr_idx + 1))
            if [ "$curr_idx" -eq "$del_num" ]; then
                target_conf="$f"
                target_port=$(basename "$f" .conf)
                break
            fi
        done

        if [ -n "$target_conf" ] && [ -f "$target_conf" ]; then
            info "正在停止端口 $target_port 的节点进程..."
            stop_single_node "$target_port"
            rm -f "$target_conf" "$NODES_DIR/${target_port}.pid" 2>/dev/null || true
            success "SOCKS5 节点 (端口: $target_port) 已成功删除并停止！"
            printf "\n按回车键继续..."
            read -r _
        fi
    done
}

# 菜单 4: 卸载
menu_uninstall() {
    printf "\n${RED}==================================================${RESET}\n"
    printf "${BOLD}${RED}              卸载 MicroSocks SOCKS5              ${RESET}\n"
    printf "${RED}==================================================${RESET}\n"
    warn "注意: 卸载将停止所有正在运行的 SOCKS5 节点，并删除所有节点配置和程序！"
    printf "确定要彻底卸载吗？(y/N): "
    read -r confirm_del

    if [ "$confirm_del" != "y" ] && [ "$confirm_del" != "Y" ]; then
        info "已取消卸载操作。"
        sleep 1
        return 0
    fi

    info "1. 停止所有 SOCKS5 进程..."
    if command -v pkill >/dev/null 2>&1; then
        pkill microsocks 2>/dev/null || true
    fi

    info "2. 清理开机自启服务..."
    if [ -f /etc/systemd/system/microsocks.service ]; then
        systemctl disable microsocks.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/microsocks.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ -f /etc/local.d/microsocks.start ]; then
        rm -f /etc/local.d/microsocks.start
    fi

    info "3. 删除程序文件及快捷命令..."
    rm -f "$BIN_PATH"
    rm -f "$SCRIPT_INSTALL_PATH"

    info "4. 删除节点配置文件目录..."
    rm -rf "$CONFIG_DIR"

    success "MicroSocks 及所有配置已彻底卸载完成！"
    exit 0
}

# 命令行非交互参数处理
handle_cli_args() {
    case "$1" in
        --start-all)
            detect_os
            start_all_nodes
            exit 0
            ;;
        --stop-all)
            stop_all_socks5
            exit 0
            ;;
        --status)
            if command -v pgrep >/dev/null 2>&1; then
                pgrep -a microsocks || echo "没有运行中的 microsocks 进程。"
            else
                ps | grep microsocks | grep -v grep || echo "没有运行中的 microsocks 进程。"
            fi
            exit 0
            ;;
    esac
}

# 主菜单入口
main_menu() {
    check_root
    check_and_install_microsocks

    while true; do
        count_nodes_status
        printf "\n"
        printf "${CYAN}==================================================${RESET}\n"
        printf "${BOLD}            MicroSocks SOCKS5 管理脚本            ${RESET}\n"
        printf "${CYAN}==================================================${RESET}\n"
        printf "系统环境: %s | 核心程序: %b\n" "$OS_NAME" "${GREEN}已安装${RESET}"
        printf "运行状态: 当前 %b 个节点运行中 (共 %d 个已配置)\n" "${GREEN}${RUNNING_COUNT}${RESET}" "$TOTAL_COUNT"
        printf -- "--------------------------------------------------\n"
        printf "  ${BOLD}1.${RESET} 配置 sock5 节点 (查看/新建/启动)\n"
        printf "  ${BOLD}2.${RESET} 删除 sock5 节点\n"
        printf "  ${BOLD}3.${RESET} 停止 socks5\n"
        printf "  ${BOLD}4.${RESET} 卸载\n"
        printf "  ${BOLD}0.${RESET} 退出\n"
        printf "${CYAN}==================================================${RESET}\n"
        printf "请输入选项 [0-4]: "
        read -r main_choice

        case "$main_choice" in
            1)
                menu_config_node
                ;;
            2)
                menu_delete_node
                ;;
            3)
                stop_all_socks5
                ;;
            4)
                menu_uninstall
                ;;
            0)
                printf "\n感谢使用，已退出脚本。\n\n"
                exit 0
                ;;
            *)
                warn "无效输入，请选择 0-4 之间的数字！"
                sleep 0.5
                ;;
        esac
    done
}

# 处理传入参数或启动主菜单
if [ -n "$1" ]; then
    handle_cli_args "$1"
fi

main_menu
