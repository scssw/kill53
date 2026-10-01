#!/usr/bin/env bash
# Aggregate ingress/egress bandwidth limits for x-ui/Xray ports.
set -euo pipefail

BASE_DIR="/root/speex"
CONFIG="$BASE_DIR/xui_rate_limit.conf"
TAG="# xui-port-rate-limit"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行此面板。"
    exit 1
fi
for tool in tc ip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "缺少命令：$tool（通常由 iproute2 提供）"
        exit 1
    fi
done
mkdir -p "$BASE_DIR"

get_iface() {
    ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}
read_config() {
    IFACE=""; PORTS=""; DOWN_MBIT=""; UP_MBIT=""
    if [[ -f "$CONFIG" ]]; then source "$CONFIG"; fi
}
remove_pref() {
    tc filter del dev "$1" ingress pref "$2" 2>/dev/null || true
    tc filter del dev "$1" egress pref "$2" 2>/dev/null || true
}
remove_rules() {
    local dev="$1" ports="$2" index=0 port
    [[ -n "$dev" && -n "$ports" ]] || return 0
    local -a port_list
    IFS=',' read -r -a port_list <<< "$ports"
    for port in "${port_list[@]}"; do
        remove_pref "$dev" "$((42000 + index))"
        index=$((index + 1))
    done
}
apply_direction() {
    local dev="$1" direction="$2" port="$3" rate="$4" pref="$5" field
    if [[ "$direction" == ingress ]]; then field=dst_port; else field=src_port; fi
    # Police drops packets above the cap; TCP adapts, while UDP may lose packets.
    tc filter replace dev "$dev" "$direction" protocol ip pref "$pref" handle 1 flower ip_proto tcp "$field" "$port" action police rate "${rate}mbit" burst 128k drop
    tc filter replace dev "$dev" "$direction" protocol ip pref "$pref" handle 2 flower ip_proto udp "$field" "$port" action police rate "${rate}mbit" burst 128k drop
    tc filter replace dev "$dev" "$direction" protocol ipv6 pref "$pref" handle 3 flower ip_proto tcp "$field" "$port" action police rate "${rate}mbit" burst 128k drop
    tc filter replace dev "$dev" "$direction" protocol ipv6 pref "$pref" handle 4 flower ip_proto udp "$field" "$port" action police rate "${rate}mbit" burst 128k drop
}
apply_rules() {
    local dev="$1" ports="$2" down="$3" up="$4" index=0 port
    local -a port_list
    ip link show dev "$dev" >/dev/null 2>&1 || { echo "找不到网络接口：$dev" >&2; return 1; }
    tc qdisc add dev "$dev" clsact 2>/dev/null || true
    IFS=',' read -r -a port_list <<< "$ports"
    for port in "${port_list[@]}"; do
        local pref=$((42000 + index))
        remove_pref "$dev" "$pref"
        apply_direction "$dev" egress "$port" "$down" "$pref"
        apply_direction "$dev" ingress "$port" "$up" "$pref"
        index=$((index + 1))
    done
}
validate_ports() {
    local value="$1" part
    local -A seen=()
    local -a values
    IFS=',' read -r -a values <<< "$value"
    PORTS_CLEAN=""
    for part in "${values[@]}"; do
        part="${part//[[:space:]]/}"
        [[ "$part" =~ ^[0-9]+$ ]] && ((10#$part >= 1 && 10#$part <= 65535)) || return 1
        part=$((10#$part))
        [[ -n "${seen[$part]+x}" ]] && continue
        seen[$part]=1
        PORTS_CLEAN+="${PORTS_CLEAN:+,}$part"
    done
    [[ -n "$PORTS_CLEAN" ]]
}
read_positive() {
    local prompt="$1" default="$2" value
    while true; do
        read -r -p "$prompt（默认 $default）: " value
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$value" 'BEGIN {exit !(n > 0 && n <= 100000)}'; then
            REPLY="$value"; return
        fi
        echo "请输入大于 0 的数字（单位 Mbps）。"
    done
}
enable_limits() {
    read_config
    local default_iface="${IFACE:-$(get_iface)}" iface ports down up
    read -r -p "公网网络接口（默认 ${default_iface:-需手动填写}）: " iface
    iface="${iface:-$default_iface}"
    [[ -n "$iface" ]] || { echo "无法自动识别接口。"; return 1; }
    read -r -p "要限制的 x-ui 入站端口（逗号分隔，如 443,8443）: " ports
    validate_ports "$ports" || { echo "端口格式无效，请输入 1 到 65535 的端口号。"; return 1; }
    ports="$PORTS_CLEAN"
    read_positive "每个端口的下载上限" "${DOWN_MBIT:-100}"; down="$REPLY"
    read_positive "每个端口的上传上限" "${UP_MBIT:-100}"; up="$REPLY"
    remove_rules "${IFACE:-$iface}" "${PORTS:-}"
    apply_rules "$iface" "$ports" "$down" "$up"
    {
        printf 'IFACE=%q\n' "$iface"
        printf 'PORTS=%q\n' "$ports"
        printf 'DOWN_MBIT=%q\n' "$down"
        printf 'UP_MBIT=%q\n' "$up"
    } > "$CONFIG"
    chmod 600 "$CONFIG"
    echo "已应用：端口 $ports；每端口下载 ${down} Mbps、上传 ${up} Mbps。"
    echo "同一端口上的用户共享该端口上限。"
}
show_status() {
    read_config
    if [[ -z "$PORTS" ]]; then echo "尚未配置限速端口。"; return; fi
    echo "配置接口：$IFACE"
    echo "端口：$PORTS"
    echo "每端口下载上限：${DOWN_MBIT} Mbps；上传上限：${UP_MBIT} Mbps"
    echo "tc 规则："
    tc filter show dev "$IFACE" ingress 2>/dev/null | grep -E 'pref 42[0-9][0-9][0-9]' || true
    tc filter show dev "$IFACE" egress 2>/dev/null | grep -E 'pref 42[0-9][0-9][0-9]' || true
}
disable_limits() {
    read_config
    [[ -z "$PORTS" ]] || remove_rules "$IFACE" "$PORTS"
    rm -f "$CONFIG"
    echo "已移除本脚本配置的端口限速规则。"
}
install_boot_restore() {
    local script="$BASE_DIR/xui_rate_limit.sh" old_cron new_cron
    old_cron="$(crontab -l 2>/dev/null || true)"
    new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$TAG" 'index($0, tag) == 0 && $0 != ""')"
    new_cron+="${new_cron:+$'\n'}@reboot $script --restore $TAG"
    printf '%s\n' "$new_cron" | crontab -
    echo "已安装开机恢复任务。"
}
restore_rules() {
    read_config
    [[ -n "$PORTS" ]] || exit 0
    apply_rules "$IFACE" "$PORTS" "$DOWN_MBIT" "$UP_MBIT"
}
if [[ "${1:-}" == "--restore" ]]; then restore_rules; exit 0; fi

while true; do
    echo
    echo "====== x-ui 端口限速管理 ======"
    echo "1. 配置/更新端口限速（上下行，Mbps）"
    echo "2. 查看状态"
    echo "3. 停止限速并移除规则"
    echo "4. 安装开机自动恢复"
    echo "0. 退出"
    read -r -p "请选择: " choice
    case "$choice" in
        1) enable_limits ;;
        2) show_status ;;
        3) disable_limits ;;
        4) install_boot_restore ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 1、2、3、4 或 0。" ;;
    esac
done
