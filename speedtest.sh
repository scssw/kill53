#!/bin/bash
# ==================================================================================
# \                  SpeedTest 网络与大陆三网测速综合优化版                       /
# \             集成阿里云镜像测速、最近节点带宽测速与国内三网测速                 /
# \                      GitHub: https://github.com/scssw/kill53                   /
# ==================================================================================

export LANG=C.UTF-8 2>/dev/null || true
export LC_ALL=C.UTF-8 2>/dev/null || true

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

LOG_FILE="/tmp/speedtest_result.log"
true > "$LOG_FILE"

# 日志输出并显示
log_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# 格式化 Mbps
fmt() {
    awk -v b="$1" 'BEGIN{printf "%.2f Mbps\n", b*8/1e6}'
}

# 保证 /usr/local/bin 在 PATH 中
if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# 检查基础依赖
check_dependencies() {
    local missing=()
    for cmd in curl awk tar grep sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "$EUID" -eq 0 ]; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y && apt-get install -y "${missing[@]}"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "${missing[@]}"
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache "${missing[@]}"
            fi
        fi
    fi
}

# 打印系统信息
print_system_info() {
    local cpuname cores mem_total mem_used os kernel bbr_status ipv4_addr ip_isp ip_loc
    cpuname=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^[ \t]*//')
    cores=$(grep -c 'processor' /proc/cpuinfo 2>/dev/null || echo "1")
    [ -z "$cpuname" ] && cpuname=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2; exit}' | sed 's/^[ \t]*//')
    [ -z "$cpuname" ] && cpuname="Unknown CPU"

    mem_total=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
    mem_used=$(free -m 2>/dev/null | awk '/Mem:/{print $3}')
    [ -z "$mem_total" ] && mem_total="N/A"
    [ -z "$mem_used" ] && mem_used="N/A"

    if [ -f /etc/os-release ]; then
        os=$(awk -F= '/^PRETTY_NAME/{gsub(/"/, "", $2); print $2}' /etc/os-release)
    else
        os=$(uname -s -r)
    fi
    kernel=$(uname -r)

    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [ -z "$bbr_status" ] && bbr_status="unknown"

    local ip_json
    ip_json=$(curl -fsSL --max-time 3 "https://api.ip.sb/geoip" 2>/dev/null)
    if [ -n "$ip_json" ]; then
        ipv4_addr=$(echo "$ip_json" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
        ip_isp=$(echo "$ip_json" | grep -o '"isp":"[^"]*' | cut -d'"' -f4)
        ip_loc=$(echo "$ip_json" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
    else
        ipv4_addr=$(curl -fsSL --max-time 3 "https://api4.ipify.org" 2>/dev/null || curl -fsSL --max-time 3 "https://ip.sb" 2>/dev/null)
        ip_isp="Unknown"
        ip_loc="Unknown"
    fi

    log_echo " ================================================================================== "
    log_echo " \\                 SpeedTest 网络与大陆三网测速综合优化版                       / "
    log_echo " \\             集成阿里云镜像测速、最近节点带宽测速与国内三网测速                 / "
    log_echo " \\                      GitHub: https://github.com/scssw/kill53                   / "
    log_echo " ================================================================================== "
    log_echo " CPU 型号          : ${CYAN}${cpuname} (${cores} 核心)${PLAIN}"
    log_echo " 内存大小          : ${CYAN}${mem_used} MB / ${mem_total} MB${PLAIN}"
    log_echo " 操作系统          : ${CYAN}${os} (${kernel})${PLAIN}"
    log_echo " TCP 拥塞控制      : ${CYAN}${bbr_status}${PLAIN}"
    log_echo " IP 与位置         : ${CYAN}${ipv4_addr}${PLAIN} (${ip_loc} - ${ip_isp})"
    log_echo " ================================================================================== "
}

# 阿里云镜像测速 (5次 x 20MB)
test_aliyun() {
    local DL_URL="https://mirrors.aliyun.com/debian/ls-lR.gz"
    local RANGE=20971519   # 20MB

    log_echo ""
    log_echo "${BOLD}【下载测速】阿里云镜像 5次 x 20MB${PLAIN}"
    local best=0
    for i in 1 2 3 4 5; do
        local s
        s=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 60 -r 0-$RANGE "$DL_URL")
        log_echo "  第 $i 次: $(fmt "$s")"
        best=$(awk -v a="$best" -v b="$s" 'BEGIN{print (b>a)?b:a}')
    done
    log_echo "  ${GREEN}最佳: $(fmt "$best")${PLAIN}"
}

# 检查与安装 Ookla 官方 Speedtest CLI
SPEEDTEST_BIN=""
ENGINE_TYPE="ookla"

ensure_speedtest_engine() {
    # 1. 检查 PATH 或常见绝对路径中是否已有现成 binary (避免重复下载)
    if command -v speedtest >/dev/null 2>&1; then
        SPEEDTEST_BIN="$(command -v speedtest)"
        return 0
    fi
    if [ -x "/usr/local/bin/speedtest" ]; then
        SPEEDTEST_BIN="/usr/local/bin/speedtest"
        return 0
    fi

    log_echo "--> 正在初始化 Ookla Speedtest CLI (仅首次安装，后续自动持久复用)..."
    local arch=$(uname -m)
    local pkg_arch=""
    case "$arch" in
        x86_64|amd64) pkg_arch="x86_64" ;;
        aarch64|arm64) pkg_arch="aarch64" ;;
        i386|i686) pkg_arch="i386" ;;
        armhf) pkg_arch="armhf" ;;
        *) pkg_arch="x86_64" ;;
    esac

    local tgz="/tmp/ookla-speedtest-${pkg_arch}.tgz"
    local urls=(
        "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${pkg_arch}.tgz"
        "https://down.vpsaff.net/linux/speedtest/ookla-speedtest/1.2.0/ookla-speedtest-1.2.0-linux-${pkg_arch}.tgz"
    )

    local downloaded=0
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 8 -o "$tgz" "$u" 2>/dev/null || wget -q -T 8 -O "$tgz" "$u" 2>/dev/null; then
            downloaded=1
            break
        fi
    done

    if [ "$downloaded" -eq 1 ] && [ -f "$tgz" ]; then
        tar -xzf "$tgz" -C /tmp speedtest 2>/dev/null
        if [ -f "/tmp/speedtest" ]; then
            chmod +x /tmp/speedtest
            if [ "$EUID" -eq 0 ] || [ -w "/usr/local/bin" ]; then
                mv /tmp/speedtest /usr/local/bin/speedtest 2>/dev/null || sudo mv /tmp/speedtest /usr/local/bin/speedtest 2>/dev/null
                SPEEDTEST_BIN="/usr/local/bin/speedtest"
            else
                mkdir -p "$HOME/.local/bin"
                mv /tmp/speedtest "$HOME/.local/bin/speedtest"
                export PATH="$HOME/.local/bin:$PATH"
                SPEEDTEST_BIN="$HOME/.local/bin/speedtest"
            fi
        fi
        rm -f "$tgz"
    fi

    if [ -x "$SPEEDTEST_BIN" ]; then
        log_echo "${GREEN}--> Ookla Speedtest CLI 安装成功${PLAIN}"
        return 0
    else
        log_echo "${YELLOW}--> Ookla 官方 CLI 下载受阻，启用备用测速引擎...${PLAIN}"
        return 1
    fi
}

# 检查与安装备用测速引擎：speedtest-go (无 Ookla Token 频率限制)
SPEEDTEST_GO_BIN=""

ensure_speedtest_go() {
    if command -v speedtest-go >/dev/null 2>&1; then
        SPEEDTEST_GO_BIN="$(command -v speedtest-go)"
        return 0
    fi
    if [ -x "/usr/local/bin/speedtest-go" ]; then
        SPEEDTEST_GO_BIN="/usr/local/bin/speedtest-go"
        return 0
    fi

    log_echo "--> 正在按需加载 speedtest-go 备用测速组件..."
    local arch=$(uname -m)
    local go_arch=""
    case "$arch" in
        x86_64|amd64) go_arch="x86_64" ;;
        aarch64|arm64) go_arch="arm64" ;;
        i386|i686) go_arch="i386" ;;
        *) go_arch="x86_64" ;;
    esac

    local ver="1.8.3"
    local tgz="/tmp/speedtest-go.tar.gz"
    local urls=(
        "https://github.com/showwin/speedtest-go/releases/download/v${ver}/speedtest-go_${ver}_Linux_${go_arch}.tar.gz"
        "https://ghproxy.net/https://github.com/showwin/speedtest-go/releases/download/v${ver}/speedtest-go_${ver}_Linux_${go_arch}.tar.gz"
        "https://mirror.ghproxy.com/https://github.com/showwin/speedtest-go/releases/download/v${ver}/speedtest-go_${ver}_Linux_${go_arch}.tar.gz"
    )

    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 5 --max-time 20 -o "$tgz" "$u" 2>/dev/null || wget -q -T 10 -O "$tgz" "$u" 2>/dev/null; then
            tar -xzf "$tgz" -C /tmp speedtest-go 2>/dev/null
            if [ -f "/tmp/speedtest-go" ]; then
                chmod +x /tmp/speedtest-go
                if [ "$EUID" -eq 0 ] || [ -w "/usr/local/bin" ]; then
                    mv /tmp/speedtest-go /usr/local/bin/speedtest-go 2>/dev/null || sudo mv /tmp/speedtest-go /usr/local/bin/speedtest-go 2>/dev/null
                    SPEEDTEST_GO_BIN="/usr/local/bin/speedtest-go"
                else
                    mkdir -p "$HOME/.local/bin"
                    mv /tmp/speedtest-go "$HOME/.local/bin/speedtest-go"
                    export PATH="$HOME/.local/bin:$PATH"
                    SPEEDTEST_GO_BIN="$HOME/.local/bin/speedtest-go"
                fi
                rm -f "$tgz"
                return 0
            fi
        fi
    done
    rm -f "$tgz"
    return 1
}

# 格式化输出对齐（中英混排视觉对齐补偿）
pad_node_name() {
    local str="$1"
    local target_width="$2"
    local visual_len=0
    local len=${#str}
    for (( i=0; i<len; i++ )); do
        local c="${str:i:1}"
        if [[ "$c" =~ [^[:ascii:]] ]]; then
            visual_len=$(( visual_len + 2 ))
        else
            visual_len=$(( visual_len + 1 ))
        fi
    done
    local pad=$(( target_width - visual_len ))
    if [ "$pad" -lt 0 ]; then pad=0; fi
    printf "%s%*s" "$str" "$pad" ""
}

# 解析测速输出（支持 JSON 与 Human-Readable 两种格式）
parse_speedtest_output() {
    local text="$1"
    local ul="" dl="" lat="" loss="" srv=""

    # 1. 尝试解析 JSON 格式 (提取 type:result 行)
    local json_line
    json_line=$(echo "$text" | grep '"type":"result"' | tail -n1)
    if [ -n "$json_line" ]; then
        if command -v python3 >/dev/null 2>&1; then
            local py_res
            py_res=$(python3 -c "
import json
try:
    d = json.loads('''$json_line''')
    lat = f\"{d['ping']['latency']:.2f} ms\" if 'ping' in d and 'latency' in d['ping'] else '-'
    dl = f\"{d['download']['bandwidth']*8/1e6:.2f} Mbps\" if 'download' in d and 'bandwidth' in d['download'] else '-'
    ul = f\"{d['upload']['bandwidth']*8/1e6:.2f} Mbps\" if 'upload' in d and 'bandwidth' in d['upload'] else '-'
    loss = f\"{d['packetLoss']:.1f}%\" if 'packetLoss' in d and d['packetLoss'] is not None else '0.0%'
    srv_name = d.get('server', {}).get('name', '')
    srv_loc = d.get('server', {}).get('location', '')
    print(f\"{ul}|{dl}|{lat}|{loss}|{srv_name} {srv_loc}\")
except Exception:
    pass
" 2>/dev/null)
            if [ -n "$py_res" ]; then
                echo "$py_res"
                return 0
            fi
        fi

        # 无 python3 时的 grep/awk 提取
        local bw_dl bw_ul
        lat=$(echo "$json_line" | grep -o '"latency":[0-9.]*' | head -n1 | cut -d: -f2)
        bw_dl=$(echo "$json_line" | grep -o '"download":{[^}]*' | grep -o '"bandwidth":[0-9]*' | head -n1 | cut -d: -f2)
        bw_ul=$(echo "$json_line" | grep -o '"upload":{[^}]*' | grep -o '"bandwidth":[0-9]*' | head -n1 | cut -d: -f2)
        loss=$(echo "$json_line" | grep -o '"packetLoss":[0-9.]*' | head -n1 | cut -d: -f2)
        srv=$(echo "$json_line" | grep -o '"name":"[^"]*' | head -n1 | cut -d'"' -f4)

        [ -n "$lat" ] && lat=$(awk -v v="$lat" 'BEGIN{printf "%.2f ms", v}') || lat="-"
        [ -n "$bw_dl" ] && dl=$(awk -v b="$bw_dl" 'BEGIN{printf "%.2f Mbps", b*8/1e6}') || dl="-"
        [ -n "$bw_ul" ] && ul=$(awk -v b="$bw_ul" 'BEGIN{printf "%.2f Mbps", b*8/1e6}') || ul="-"
        [ -n "$loss" ] && loss="${loss}%" || loss="0.0%"
        echo "${ul}|${dl}|${lat}|${loss}|${srv}"
        return 0
    fi

    # 2. 尝试解析 Human-Readable 文本格式
    if echo "$text" | grep -qi "Download:"; then
        dl=$(echo "$text" | grep -i "Download:" | head -n1 | awk '{if($2=="FAILED" || $2=="") print "-"; else if($3 ~ /bps/i) print $2 " " $3; else print $2 " Mbps"}')
        ul=$(echo "$text" | grep -i "Upload:" | head -n1 | awk '{if($2=="FAILED" || $2=="") print "-"; else if($3 ~ /bps/i) print $2 " " $3; else print $2 " Mbps"}')
        lat=$(echo "$text" | grep -i "Latency:" | head -n1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/ && $(i+1) ~ /ms/) {print $i, $(i+1); break}}')
        [ -z "$lat" ] && lat=$(echo "$text" | grep -i "Latency:" | head -n1 | awk '{print $2 " " $3}')
        loss=$(echo "$text" | grep -i "Packet Loss:" | head -n1 | awk '{print $3}')
        srv=$(echo "$text" | awk -F'[(]' '/Server:/{print $1}' | awk -F: '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')

        [ -z "$dl" ] && dl="-"
        [ -z "$ul" ] && ul="-"
        [ -z "$lat" ] && lat="-"
        [ -z "$loss" ] || [ "$loss" = "Not" ] && loss="0.0%"
        echo "${ul}|${dl}|${lat}|${loss}|${srv}"
        return 0
    fi

    return 1
}

# 单个测速节点执行
run_speed_node() {
    local node_id="$1"
    local default_name="$2"
    local raw_output=""
    local res_line=""
    local success=0

    local is_nearest=0
    [ -z "$node_id" ] && is_nearest=1

    # 1. 优先尝试 Ookla Speedtest
    if [ "$ENGINE_TYPE" = "ookla" ] && [ -x "$SPEEDTEST_BIN" ]; then
        if [ "$is_nearest" -eq 1 ]; then
            raw_output=$(timeout 40 "$SPEEDTEST_BIN" --progress=no --accept-license --accept-gdpr -u Mbps 2>&1)
        else
            raw_output=$(timeout 35 "$SPEEDTEST_BIN" --progress=no --accept-license --accept-gdpr -u Mbps -s "$node_id" 2>&1)
        fi

        # 检查是否触发官方 IP 频率限制 (用户常遇到的 Limit reached)
        if echo "$raw_output" | grep -qi -E "Limit reached|Too many requests"; then
            log_echo " ${YELLOW}[!] Ookla 官方限制当前 IP 频率 (Limit reached)，已自动切换到 speedtest-go 备用引擎${PLAIN}"
            ENGINE_TYPE="speedtest_go"
            ensure_speedtest_go
        else
            res_line=$(parse_speedtest_output "$raw_output")
            if [ -n "$res_line" ]; then
                success=1
            fi
        fi
    fi

    # 2. 如果 Ookla 受限或不可用，无缝启用 speedtest-go 备用引擎
    if [ "$success" -eq 0 ]; then
        if [ -z "$SPEEDTEST_GO_BIN" ]; then
            ensure_speedtest_go >/dev/null 2>&1
        fi
        if [ -x "$SPEEDTEST_GO_BIN" ]; then
            if [ "$is_nearest" -eq 1 ]; then
                raw_output=$(timeout 40 "$SPEEDTEST_GO_BIN" --json 2>&1)
            else
                raw_output=$(timeout 35 "$SPEEDTEST_GO_BIN" -s "$node_id" --json 2>&1)
            fi

            res_line=$(parse_speedtest_output "$raw_output")
            if [ -n "$res_line" ]; then
                success=1
            fi
        fi
    fi

    # 3. 打印表格行
    local padded_name
    padded_name=$(pad_node_name "$default_name" 18)

    if [ "$success" -eq 1 ]; then
        local ul dl lat loss srv_info
        ul=$(echo "$res_line" | cut -d'|' -f1)
        dl=$(echo "$res_line" | cut -d'|' -f2)
        lat=$(echo "$res_line" | cut -d'|' -f3)
        loss=$(echo "$res_line" | cut -d'|' -f4)
        srv_info=$(echo "$res_line" | cut -d'|' -f5)

        # 最近节点附加真实服务商简称
        if [ "$is_nearest" -eq 1 ] && [ -n "$srv_info" ] && [ "$srv_info" != " " ]; then
            local clean_srv="${srv_info:0:8}"
            padded_name=$(pad_node_name "${default_name} (${clean_srv})" 18)
        fi

        printf " ${YELLOW}%s${PLAIN}   ${GREEN}%-17s${PLAIN} ${CYAN}%-19s${PLAIN} ${BLUE}%-11s${PLAIN} %-10s\n" \
            "$padded_name" "$ul" "$dl" "$lat" "$loss" | tee -a "$LOG_FILE"
    else
        printf " ${YELLOW}%s${PLAIN}   ${RED}%-17s${PLAIN} ${RED}%-19s${PLAIN} ${RED}%-11s${PLAIN} %-10s\n" \
            "$padded_name" "Fail / Offline" "Fail / Offline" "-" "-" | tee -a "$LOG_FILE"
    fi

    sleep 1.2
}

# 打印测速表格头
print_table_header() {
    log_echo ""
    log_echo "----------------------------------------------------------------------------------"
    printf " %-18s   %-17s %-19s %-11s %-10s\n" "Node Name" "Upload Speed" "Download Speed" "Latency" "Packet Loss" | tee -a "$LOG_FILE"
    log_echo "----------------------------------------------------------------------------------"
}

# 打印测速表格尾
print_table_footer() {
    log_echo "----------------------------------------------------------------------------------"
}

# 主执行入口
main() {
    local mode="${1:-standard}"

    check_dependencies
    print_system_info

    # 1. 阿里云测速模块 (用户特别指定，放在最前)
    if [ "$mode" != "nearest" ] && [ "$mode" != "cn" ]; then
        test_aliyun
    fi

    if [ "$mode" = "ali" ]; then
        log_echo ""
        log_echo "${GREEN}阿里云镜像测速已完成。${PLAIN}"
        exit 0
    fi

    # 2. 准备测速引擎
    ensure_speedtest_engine

    # 3. 测速表格
    print_table_header

    # A. 最近节点（测试物理带宽上限）
    if [ "$mode" != "cn" ]; then
        run_speed_node "" "最近节点 (Nearest)"
    fi

    # B. 中国大陆代表性三网节点
    if [ "$mode" != "nearest" ]; then
        # 电信
        run_speed_node "3633"  "上海电信 5G"
        run_speed_node "27594" "广州电信 5G"
        if [ "$mode" = "full" ]; then
            run_speed_node "26352" "南京电信 5G"
        fi

        # 联通
        run_speed_node "24447" "上海联通 5G"
        run_speed_node "5145"  "北京联通"
        if [ "$mode" = "full" ]; then
            run_speed_node "26678" "广州联通 5G"
        fi

        # 移动
        run_speed_node "25637" "上海移动 5G"
        run_speed_node "54312" "杭州移动 5G"
        if [ "$mode" = "full" ]; then
            run_speed_node "4575"  "成都移动"
        fi

        # 全球节点（仅在 full 模式开启）
        if [ "$mode" = "full" ]; then
            run_speed_node "1536"  "香港 (Hong Kong)"
            run_speed_node "56935" "日本东京 (Tokyo)"
            run_speed_node "40508" "新加坡 (Singapore)"
            run_speed_node "18229" "美国洛杉矶 (LA)"
        fi
    fi

    print_table_footer

    local finish_time
    finish_time=$(date "+%Y-%m-%d %H:%M:%S")
    log_echo " 测试完成时间: ${finish_time}"
    log_echo " 测速日志已保存至: ${LOG_FILE}"
    log_echo "=================================================================================="
}

# 命令行参数解析
case "$1" in
    ali|--ali)
        main "ali"
        ;;
    nearest|--nearest)
        main "nearest"
        ;;
    cn|--cn)
        main "cn"
        ;;
    full|-f|--full|-a|--all)
        main "full"
        ;;
    -h|--help)
        echo "用法: bash speedtest.sh [选项]"
        echo "选项:"
        echo "  (无参数)      默认标准测速 (阿里云镜像5次 + 最近节点带宽 + 大陆三网代表节点)"
        echo "  full, -f     完整测速 (包含全部国内节点及亚太/欧美海外节点)"
        echo "  ali, --ali   仅进行阿里云镜像下载测速 (5次 x 20MB)"
        echo "  nearest      仅测试物理距离最近节点的上下行带宽"
        echo "  cn, --cn     仅测试大陆三网节点"
        echo "  -h, --help   查看帮助信息"
        exit 0
        ;;
    *)
        main "standard"
        ;;
esac
