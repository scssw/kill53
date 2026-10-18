#!/usr/bin/env bash
# Aggregate ingress/egress bandwidth and volume limits for x-ui/Xray and ShadowsocksR ports.
# Optimized & Fixed Version with Custom Thresholds and Reliable Detection.
set -euo pipefail

BASE_DIR="/root/speex"
CONFIG="$BASE_DIR/xui_rate_limit.conf"
TAG="# xui-port-rate-limit"
PY_HELPER="$BASE_DIR/xui_rate_limit.py"
LOG_FILE="$BASE_DIR/xui_rate_limit.log"

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行此面板。"
    exit 1
fi
mkdir -p "$BASE_DIR"

# 确保基础依赖存在
install_dependencies() {
    local missing=()
    for tool in tc ip ss python3; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if ! command -v crontab >/dev/null 2>&1; then
        missing+=("cron")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "正在自动安装缺失依赖: ${missing[*]} ..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y iproute2 python3 cron net-tools
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute iproute-tc python3 cronie net-tools
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y iproute iproute-tc python3 cronie net-tools
        elif command -v apk >/dev/null 2>&1; then
            apk add iproute2 python3 cronie
        fi
    fi
    # 确保 cron 服务启动
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    fi
}
install_dependencies

# 内置 Python 流量监控与限速核心脚本
cat > "$PY_HELPER" <<'XUI_RATE_LIMIT_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Traffic-volume policy helper for x-ui/Xray, ShadowsocksR, Docker and custom ports.
Supports IPv4 + IPv6, accurate delta tracking, auto-restore, and custom rate/time limits.
"""
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

BASE = "/root/speex"
CONFIG = os.path.join(BASE, "xui_rate_limit.conf")
STATE = os.path.join(BASE, "xui_rate_limit_state.json")
LOG_FILE = os.path.join(BASE, "xui_rate_limit.log")


def log(msg):
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{now_str}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def config():
    values = {
        "IFACE": "",
        "PORTS": "",
        "AUTO_DISCOVER": "0",
        "AUTO_ENABLED": "1",
        "BASE_DOWN_MBIT": "100",
        "BASE_UP_MBIT": "100",
        "WINDOW_MIN": "15",
        "THRESHOLD_GB": "3",
        "LIMIT_DOWN_MBIT": "16",
        "LIMIT_UP_MBIT": "16",
        "LIMIT_MIN": "30",
    }
    if os.path.isfile(CONFIG):
        with open(CONFIG, encoding="utf-8") as stream:
            for line in stream:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    values[key.strip()] = value.strip().strip("'\"")

    ports_raw = values.get("PORTS", "")
    port_list = []
    for item in ports_raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "-" in item:
            parts = item.split("-")
            if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                start, end = int(parts[0]), int(parts[1])
                for p in range(min(start, end), max(start, end) + 1):
                    if 1 <= p <= 65535:
                        port_list.append(str(p))
        elif item.isdigit() and 1 <= int(item) <= 65535:
            port_list.append(item)
    # 去重且保持顺序
    values["ports"] = sorted(list(set(port_list)), key=lambda x: int(x))
    values["auto_discover"] = values.get("AUTO_DISCOVER", "0") == "1"
    values["auto_enabled"] = values.get("AUTO_ENABLED", "1") == "1"

    # 数值转换
    values["base_down"] = float(values.get("BASE_DOWN_MBIT", 100))
    values["base_up"] = float(values.get("BASE_UP_MBIT", 100))
    values["window_sec"] = int(float(values.get("WINDOW_MIN", 15)) * 60)
    values["threshold_bytes"] = int(float(values.get("THRESHOLD_GB", 3)) * 1024 * 1024 * 1024)
    values["limit_down"] = float(values.get("LIMIT_DOWN_MBIT", 16))
    values["limit_up"] = float(values.get("LIMIT_UP_MBIT", 16))
    values["limit_sec"] = int(float(values.get("LIMIT_MIN", 30)) * 60)
    return values


def run(args, capture=False):
    return subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
    )


def discover_ports():
    """全面识别 xray, x-ui, 3x-ui, v2ray, sing-box, SSR, docker-proxy 等代理端口"""
    found = set()
    try:
        result = run(["ss", "-H", "-lntup"], True)
    except Exception as e:
        log(f"执行 ss -H -lntup 失败: {e}")
        return []

    # 常见代理特征关键词
    proxy_keywords = [
        "xray", "x-ui", "3x-ui", "v2ray", "sing-box",
        "shadowsocks", "shadowsocksr", "ssserver", "ss-server",
        "server.py", "ssr"
    ]

    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        netid, state = fields[0], fields[1]
        if (netid == "tcp" and state != "LISTEN") and (netid == "udp" and state != "UNCONN"):
            continue

        local_addr = fields[4]
        match_port = re.search(r":(\d+)$", local_addr)
        if not match_port:
            continue
        port = int(match_port.group(1))
        if port <= 0 or port > 65535 or port in (22, 53, 80):  # 避开基础端口
            continue

        owners = re.findall(r'users:\(\("([^\"]+)",(?:pid=)?(\d+),', line)
        is_proxy = False

        for proc_name, pid_str in owners:
            pname = proc_name.lower()
            if any(k in pname for k in proxy_keywords):
                is_proxy = True
                break
            
            # 检查 /proc/<pid>/cmdline 和 cwd（尤其是 python 运行的 SSR）
            try:
                with open(f"/proc/{pid_str}/cmdline", "rb") as stream:
                    cmdline = stream.read().replace(b"\0", b" ").decode(errors="ignore").lower()
                cwd = os.readlink(f"/proc/{pid_str}/cwd").lower()
                if any(k in cmdline for k in proxy_keywords) or any(k in cwd for k in proxy_keywords):
                    is_proxy = True
                    break
                # 如果是 docker-proxy，检查是否映射了此端口
                if "docker-proxy" in pname or "docker-proxy" in cmdline:
                    if f"-host-port {port}" in cmdline:
                        is_proxy = True
                        break
            except OSError:
                continue

        if is_proxy:
            found.add(str(port))

    return sorted(list(found), key=lambda x: int(x))


def all_counters(dev):
    """同时统计 IPv4 (pref 42000+) 与 IPv6 (pref 52000+) 的收发字节数"""
    totals = {}
    for direction in ("ingress", "egress"):
        try:
            result = run(["tc", "-s", "filter", "show", "dev", dev, direction], True)
        except Exception:
            continue
        active_pref = None
        for line in result.stdout.splitlines():
            pref_match = re.search(r"\bpref\s+(\d+)\b", line)
            if pref_match:
                active_pref = int(pref_match.group(1))
            elif "filter" in line and "pref" not in line:
                active_pref = None

            if active_pref is not None:
                sent = re.search(r"\bSent\s+(\d+)\s+bytes\b", line)
                if sent:
                    totals[active_pref] = totals.get(active_pref, 0) + int(sent.group(1))
    return totals


def get_burst(rate_mbit):
    """根据速率自适应计算合理的 burst 大小，防止过小丢包或过大失准"""
    burst_k = max(256, int(rate_mbit * 32))
    return f"{burst_k}k"


def set_rate(dev, port, index, down, up):
    """为指定端口应用 IPv4 与 IPv6 的 tc flower police 限速规则"""
    pref_v4 = 42000 + index
    pref_v6 = 52000 + index
    burst_down = get_burst(down)
    burst_up = get_burst(up)

    # IPv4 规则
    for direction, rate, burst, field in (
        ("egress", down, burst_down, "src_port"),
        ("ingress", up, burst_up, "dst_port"),
    ):
        for protocol, handle in (("tcp", 1), ("udp", 2)):
            args = [
                "tc", "filter", "replace", "dev", dev, direction,
                "protocol", "ip", "pref", str(pref_v4), "handle", str(handle),
                "flower", "ip_proto", protocol, field, str(port),
                "action", "police", "rate", f"{rate}mbit", "burst", burst, "drop"
            ]
            subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # IPv6 规则 (尝试下发，若系统不支持则忽略)
    for direction, rate, burst, field in (
        ("egress", down, burst_down, "src_port"),
        ("ingress", up, burst_up, "dst_port"),
    ):
        for protocol, handle in (("tcp", 1), ("udp", 2)):
            args = [
                "tc", "filter", "replace", "dev", dev, direction,
                "protocol", "ipv6", "pref", str(pref_v6), "handle", str(handle),
                "flower", "ip_proto", protocol, field, str(port),
                "action", "police", "rate", f"{rate}mbit", "burst", burst, "drop"
            ]
            subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def remove_prefs(dev, indexes):
    commands = []
    for index in indexes:
        for direction in ("ingress", "egress"):
            commands.append(f"filter del dev {dev} {direction} pref {42000 + index}")
            commands.append(f"filter del dev {dev} {direction} pref {52000 + index}")
    if commands:
        subprocess.run(
            ["tc", "-force", "-batch", "-"],
            input="\n".join(commands) + "\n",
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def reconcile(cfg, state, ports):
    """确保所有被监控的端口都在 tc clsact 中挂载了 filter"""
    old_ports = state.get("ports", [])
    old_iface = state.get("iface", cfg["IFACE"])
    
    # 确保 clsact qdisc 存在
    subprocess.run(["tc", "qdisc", "add", "dev", cfg["IFACE"], "clsact"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if state.get("version") == 3 and old_ports == ports and old_iface == cfg["IFACE"]:
        return

    # 若端口发生变化，清除旧规则
    remove_prefs(old_iface, range(max(len(old_ports), len(ports))))

    for index, port in enumerate(ports):
        active = state.get("active", {}).get(port)
        if active and int(time.time()) < active["until"]:
            down = min(cfg["base_down"], cfg["limit_down"])
            up = min(cfg["base_up"], cfg["limit_up"])
        else:
            down = cfg["base_down"]
            up = cfg["base_up"]
        set_rate(cfg["IFACE"], port, index, down, up)

    state["ports"] = ports
    state["iface"] = cfg["IFACE"]
    state["version"] = 3
    state["last"] = {port: state.get("last", {}).get(port, 0) for port in ports}
    state["samples"] = {port: state.get("samples", {}).get(port, []) for port in ports}
    state["active"] = {port: act for port, act in state.get("active", {}).items() if port in ports}


def save(state):
    fd, path = tempfile.mkstemp(prefix=".xui-rate-", dir=BASE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.chmod(path, 0o600)
        os.replace(path, STATE)
    finally:
        if os.path.exists(path):
            os.unlink(path)


def format_bytes(num_bytes):
    if num_bytes >= 1024**3:
        return f"{num_bytes / (1024**3):.2f} GB"
    elif num_bytes >= 1024**2:
        return f"{num_bytes / (1024**2):.2f} MB"
    elif num_bytes >= 1024:
        return f"{num_bytes / 1024:.2f} KB"
    return f"{num_bytes} B"


def main():
    cfg = config()
    if not cfg["IFACE"]:
        log("错误：未配置网络接口 IFACE")
        return

    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {"last": {}, "samples": {}, "active": {}, "ports": []}

    now = int(time.time())

    # 1. 确定端口列表
    if cfg["auto_discover"]:
        ports = discover_ports()
        if not ports:
            # 尝试回退到上次记录的端口，避免临时未监听时丢失监控
            ports = state.get("ports", [])
            if not ports:
                log("未检测到运行中的 xray / ShadowsocksR / 代理端口")
                save(state)
                return
    else:
        ports = cfg["ports"]
        if not ports:
            log("未指定要监控的端口列表")
            save(state)
            return

    reconcile(cfg, state, ports)

    # 2. 读取 tc 计数器
    byte_counters = all_counters(cfg["IFACE"])

    for index, port in enumerate(ports):
        key = str(port)
        raw_v4 = byte_counters.get(42000 + index, 0)
        raw_v6 = byte_counters.get(52000 + index, 0)
        current_counter = raw_v4 + raw_v6

        previous = state["last"].get(key)
        # 精确处理内核计数器重置 (Rollover / Reset)
        if previous is None:
            delta = 0
        elif current_counter >= previous:
            delta = current_counter - previous
        else:
            delta = current_counter

        state["last"][key] = current_counter

        samples = state["samples"].setdefault(key, [])
        samples.append([now, delta])
        # 保留最近 WINDOW_SEC 内的采样
        samples[:] = [s for s in samples if s[0] >= (now - cfg["window_sec"])]
        window_total = sum(s[1] for s in samples)

        active = state["active"].get(key)

        # 检查是否在限速中
        if active:
            if now >= active["until"]:
                # 限速到期 -> 恢复基础速度
                set_rate(cfg["IFACE"], port, index, cfg["base_down"], cfg["base_up"])
                state["active"].pop(key, None)
                # 清理过期采样，防止解封瞬间再次超标
                state["samples"][key] = []
                log(f"[RESTORE] 端口 {key} 限速期满，已恢复基础速率（下行 {cfg['base_down']} Mbps, 上行 {cfg['base_up']} Mbps）")
            else:
                remaining = (active["until"] - now) // 60
                # 仍处于限速期
                pass
        else:
            # 检查是否超标 (只有启用了自动策略且采样大于1次)
            if cfg["auto_enabled"] and len(samples) > 1 and window_total >= cfg["threshold_bytes"]:
                # 触发限速
                set_rate(cfg["IFACE"], port, index, cfg["limit_down"], cfg["limit_up"])
                until_time = now + cfg["limit_sec"]
                state["active"][key] = {
                    "started": now,
                    "until": until_time,
                    "trigger_bytes": window_total,
                }
                until_str = datetime.datetime.fromtimestamp(until_time).strftime("%Y-%m-%d %H:%M:%S")
                log(f"[LIMIT] 端口 {key} 在 {cfg['WINDOW_MIN']} 分钟内流量达到 {format_bytes(window_total)} (阈值 {cfg['THRESHOLD_GB']} GB)，已限速至 {cfg['limit_down']} Mbps，预计恢复时间: {until_str}")

    save(state)


def restore_all():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        return
    ports = state.get("ports", [])
    for index, port in enumerate(ports):
        if str(port) in state.get("active", {}):
            set_rate(cfg["IFACE"], port, index, cfg["base_down"], cfg["base_up"])
    state["active"] = {}
    save(state)
    log("[RESTORE] 已手动将所有受限端口恢复至基础速度")


def remove_all():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {}
    dev = state.get("iface", cfg.get("IFACE", ""))
    if dev:
        remove_prefs(dev, range(len(state.get("ports", []))))
    state["ports"] = []
    state["active"] = {}
    save(state)
    log("[CLEAN] 已清除所有端口的限速规则")


def boot_restore():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {"last": {}, "samples": {}, "active": {}, "ports": []}
    ports = discover_ports() if cfg["auto_discover"] else cfg["ports"]
    state["ports"] = []
    reconcile(cfg, state, ports)
    save(state)
    log("[BOOT] 开机规则恢复完毕")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "--restore-all":
        restore_all()
    elif action == "--remove-all":
        remove_all()
    elif action == "--boot":
        boot_restore()
    else:
        main()
XUI_RATE_LIMIT_PYTHON
chmod 700 "$PY_HELPER"

# 自动获取最佳默认网卡（优先公网 IP 路由网卡）
get_default_iface() {
    local iface
    iface="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [[ -z "$iface" ]]; then
        iface="$(ip -o -4 route show to default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi
    echo "${iface:-eth0}"
}

read_config() {
    IFACE=""
    PORTS=""
    AUTO_DISCOVER="0"
    AUTO_ENABLED="1"
    BASE_DOWN_MBIT="100"
    BASE_UP_MBIT="100"
    WINDOW_MIN="15"
    THRESHOLD_GB="3"
    LIMIT_DOWN_MBIT="16"
    LIMIT_UP_MBIT="16"
    LIMIT_MIN="30"
    if [[ -f "$CONFIG" ]]; then
        source "$CONFIG"
    fi
}

write_config() {
    cat > "$CONFIG" <<EOF
IFACE="${IFACE}"
PORTS="${PORTS}"
AUTO_DISCOVER="${AUTO_DISCOVER}"
AUTO_ENABLED="${AUTO_ENABLED}"
BASE_DOWN_MBIT="${BASE_DOWN_MBIT}"
BASE_UP_MBIT="${BASE_UP_MBIT}"
WINDOW_MIN="${WINDOW_MIN}"
THRESHOLD_GB="${THRESHOLD_GB}"
LIMIT_DOWN_MBIT="${LIMIT_DOWN_MBIT}"
LIMIT_UP_MBIT="${LIMIT_UP_MBIT}"
LIMIT_MIN="${LIMIT_MIN}"
EOF
    chmod 600 "$CONFIG"
}

remove_policy_cron() {
    local old_cron new_cron
    old_cron="$(crontab -l 2>/dev/null || true)"
    new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$PY_HELPER" 'index($0, tag) == 0 && $0 != ""')"
    printf '%s\n' "$new_cron" | crontab -
}

install_policy_cron() {
    remove_policy_cron
    local old_cron python
    old_cron="$(crontab -l 2>/dev/null || true)"
    python="$(command -v python3)"
    # 每 1 分钟检测一次，反应灵敏
    printf '%s\n* * * * * %s %s >> %s 2>&1\n' "$old_cron" "$python" "$PY_HELPER" "$LOG_FILE" | crontab -
}

read_positive_float() {
    local prompt="$1" default="$2" unit="${3:-}" value
    while true; do
        read -r -p "$prompt（默认 $default$unit）: " value
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$value" 'BEGIN {exit !(n > 0)}'; then
            REPLY="$value"
            return
        fi
        echo "输入无效，请输入大于 0 的数字。"
    done
}

read_rate_input() {
    local prompt="$1" default="$2" value
    while true; do
        read -r -p "$prompt（默认 $default）: " value
        value="${value:-$default}"
        # 支持用户输入 2000k 或 2000kbps 自动转换为 Mbps
        if [[ "$value" =~ ^([0-9]+)[kK]([bB][pP][sS])?$ ]]; then
            local kb="${BASH_REMATCH[1]}"
            REPLY="$(awk -v k="$kb" 'BEGIN {printf "%.2f", k*8/1000}')"
            echo "已自动换算为: ${REPLY} Mbps"
            return
        elif [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$value" 'BEGIN {exit !(n > 0)}'; then
            REPLY="$value"
            return
        fi
        echo "请输入大于 0 的数值（如 16 表示 16 Mbps，或 2000k 表示 2000 KB/s）。"
    done
}

# 验证端口或端口范围格式 (如 100,443,10000-10050)
validate_ports() {
    local raw="$1" part
    local -a parts
    IFS=',' read -r -a parts <<< "$raw"
    CLEANED_PORTS=""
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            ((part >= 1 && part <= 65535)) || return 1
            CLEANED_PORTS+="${CLEANED_PORTS:+,}$part"
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local p1="${BASH_REMATCH[1]}" p2="${BASH_REMATCH[2]}"
            ((p1 >= 1 && p1 <= 65535 && p2 >= 1 && p2 <= 65535 && p1 <= p2)) || return 1
            CLEANED_PORTS+="${CLEANED_PORTS:+,}$part"
        else
            return 1
        fi
    done
    [[ -n "$CLEANED_PORTS" ]]
}

# 菜单 2：配置/更新指定端口限速（含自定义阈值、限速速度、恢复时间）
configure_custom_ports() {
    read_config
    local auto_iface
    auto_iface="$(get_default_iface)"
    local current_iface="${IFACE:-$auto_iface}"

    echo "--- [模式2: 手动配置指定端口限速] ---"
    read -r -p "公网网络接口（默认 $current_iface）: " iface_in
    IFACE="${iface_in:-$current_iface}"
    ip link show dev "$IFACE" >/dev/null 2>&1 || { echo "找不到网络接口: $IFACE"; return 1; }

    while true; do
        read -r -p "要监控与限速的入站端口（多个用逗号，如 100,65500 或 1000-1010，默认 ${PORTS:-443}）: " ports_in
        ports_in="${ports_in:-${PORTS:-443}}"
        if validate_ports "$ports_in"; then
            PORTS="$CLEANED_PORTS"
            break
        fi
        echo "端口格式无效，请输入 1-65535 的端口，例如 443,8443 或 1000-2000"
    done

    echo ""
    echo ">> 步骤 1: 设置基础正常速度（用户平时允许的最大速度）"
    read_positive_float "每个端口平时下载上限" "${BASE_DOWN_MBIT:-100}" " Mbps"; BASE_DOWN_MBIT="$REPLY"
    read_positive_float "每个端口平时上传上限" "${BASE_UP_MBIT:-100}" " Mbps"; BASE_UP_MBIT="$REPLY"

    echo ""
    echo ">> 步骤 2: 设置流量超额限速策略"
    read_positive_float "流量统计时间窗口" "${WINDOW_MIN:-15}" " 分钟"; WINDOW_MIN="$REPLY"
    read_positive_float "触发限速的流量阈值" "${THRESHOLD_GB:-3}" " GB"; THRESHOLD_GB="$REPLY"
    read_rate_input "超额后限制的速度（Mbps，或输入如 2000k）" "${LIMIT_DOWN_MBIT:-16}"; LIMIT_DOWN_MBIT="$REPLY"; LIMIT_UP_MBIT="$REPLY"
    read_positive_float "限速持续时间（达到后自动恢复基础速度）" "${LIMIT_MIN:-30}" " 分钟"; LIMIT_MIN="$REPLY"

    AUTO_DISCOVER="0"
    AUTO_ENABLED="1"
    write_config

    echo ""
    echo "正在应用底层限速规则并启动后台守护监控..."
    python3 "$PY_HELPER" --restore-all 2>/dev/null || true
    install_policy_cron
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 配置成功！"
    echo " 监控端口: $PORTS"
    echo " 平时速度: 下载 ${BASE_DOWN_MBIT} Mbps / 上传 ${BASE_UP_MBIT} Mbps"
    echo " 限速策略: ${WINDOW_MIN} 分钟内流量达到 ${THRESHOLD_GB} GB 时，限速为 ${LIMIT_DOWN_MBIT} Mbps（持续 ${LIMIT_MIN} 分钟后自动恢复）"
    echo " 后台监控已启动（每分钟自动检测一次流量）"
    echo "=================================================="
}

# 菜单 1：全自动策略（自动发现 xray/SSR 端口）
enable_auto_discover_policy() {
    read_config
    local auto_iface
    auto_iface="$(get_default_iface)"
    local current_iface="${IFACE:-$auto_iface}"

    echo "--- [模式1: 自动扫描 xray / SSR 端口策略] ---"
    read -r -p "公网网络接口（默认 $current_iface）: " iface_in
    IFACE="${iface_in:-$current_iface}"
    ip link show dev "$IFACE" >/dev/null 2>&1 || { echo "找不到网络接口: $IFACE"; return 1; }

    echo ""
    read_positive_float "自动发现端口平时下载上限" "${BASE_DOWN_MBIT:-100}" " Mbps"; BASE_DOWN_MBIT="$REPLY"
    read_positive_float "自动发现端口平时上传上限" "${BASE_UP_MBIT:-100}" " Mbps"; BASE_UP_MBIT="$REPLY"
    read_positive_float "流量统计时间窗口" "${WINDOW_MIN:-15}" " 分钟"; WINDOW_MIN="$REPLY"
    read_positive_float "触发限速的流量阈值" "${THRESHOLD_GB:-3}" " GB"; THRESHOLD_GB="$REPLY"
    read_rate_input "超额后限制的速度（Mbps，或输入如 2000k）" "${LIMIT_DOWN_MBIT:-16}"; LIMIT_DOWN_MBIT="$REPLY"; LIMIT_UP_MBIT="$REPLY"
    read_positive_float "限速持续时间" "${LIMIT_MIN:-30}" " 分钟"; LIMIT_MIN="$REPLY"

    AUTO_DISCOVER="1"
    AUTO_ENABLED="1"
    PORTS=""
    write_config

    echo ""
    echo "正在扫描系统代理端口并启动自动策略..."
    install_policy_cron
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 自动模式已启用！"
    echo " 将自动监控 xray / 3x-ui / SSR / Docker 映射端口"
    echo " 策略: ${WINDOW_MIN} 分钟内达 ${THRESHOLD_GB} GB 限速至 ${LIMIT_DOWN_MBIT} Mbps，${LIMIT_MIN} 分钟后恢复"
    echo "=================================================="
}

show_status() {
    read_config
    echo "==================== 限速运行状态 ===================="
    echo "网络接口: ${IFACE:-未配置}"
    if [[ "$AUTO_DISCOVER" == "1" ]]; then
        echo "运行模式: 自动扫描 xray / ShadowsocksR / 代理端口"
    else
        echo "运行模式: 手动指定端口模式 (端口: ${PORTS:-无})"
    fi
    echo "平时带宽: 下载 ${BASE_DOWN_MBIT} Mbps / 上传 ${BASE_UP_MBIT} Mbps"
    echo "限速规则: ${WINDOW_MIN} 分钟内达到 ${THRESHOLD_GB} GB -> 限速至 ${LIMIT_DOWN_MBIT} Mbps (${LIMIT_MIN} 分钟后恢复)"
    echo "自动限速策略: $(if [[ "$AUTO_ENABLED" == "1" ]]; then echo "已启用"; else echo "已停用"; fi)"
    echo "------------------------------------------------------"

    python3 - "$BASE_DIR/xui_rate_limit_state.json" <<'STATUS_PY'
import json
import os
import sys
import time
import datetime

state_path = sys.argv[1]
if not os.path.isfile(state_path):
    print("暂无状态记录文件。")
    sys.exit(0)

try:
    with open(state_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"读取状态失败: {e}")
    sys.exit(0)

ports = state.get("ports", [])
print(f"当前监控端口: {','.join(map(str, ports)) if ports else '无'}")

now = int(time.time())
active = state.get("active", {})

if not ports:
    print("提示: 当前没有监控到任何端口。如果是自动模式，请检查代理服务是否正在运行。")
else:
    print("\n[各端口流量统计与状态]")
    for p in ports:
        key = str(p)
        samples = state.get("samples", {}).get(key, [])
        window_bytes = sum(s[1] for s in samples)
        if window_bytes >= 1024**3:
            w_str = f"{window_bytes / (1024**3):.2f} GB"
        elif window_bytes >= 1024**2:
            w_str = f"{window_bytes / (1024**2):.2f} MB"
        else:
            w_str = f"{window_bytes / 1024:.2f} KB"

        act = active.get(key)
        if act and act.get("until", 0) > now:
            until_dt = datetime.datetime.fromtimestamp(act["until"]).strftime("%H:%M:%S")
            rem = (act["until"] - now) // 60
            status_text = f"【已限速】剩余约 {rem} 分钟 (至 {until_dt} 恢复)"
        else:
            status_text = "【正常】"

        print(f"  - 端口 {key:5s} | 窗口内累计: {w_str:9s} | 状态: {status_text}")

STATUS_PY

    echo "------------------------------------------------------"
    local tc_count
    tc_count="$({ tc filter show dev "$IFACE" ingress 2>/dev/null || true; tc filter show dev "$IFACE" egress 2>/dev/null || true; } | grep -Ec 'pref (42|52)[0-9]{3}' || true)"
    echo "底层 tc 规则生效条数: $tc_count"
    local cron_check
    cron_check="$(crontab -l 2>/dev/null | grep -c "$PY_HELPER" || true)"
    echo "后台 Cron 监控: $(if [[ "$cron_check" -gt 0 ]]; then echo "运行中 (每分钟检测)"; else echo "未运行"; fi)"
    echo "======================================================"
}

stop_auto_policy() {
    read_config
    remove_policy_cron
    AUTO_ENABLED="0"
    write_config
    python3 "$PY_HELPER" --restore-all 2>/dev/null || true
    echo "已停止自动限速守护策略，所有受限端口已恢复基础速度（基础端口限速仍保留）。"
}

remove_all_rules() {
    read_config
    remove_policy_cron
    python3 "$PY_HELPER" --remove-all 2>/dev/null || true
    rm -f "$CONFIG" "$BASE_DIR/xui_rate_limit_state.json"
    echo "已彻底清除全部端口限速规则和配置文件。"
}

install_boot_restore() {
    local script="$BASE_DIR/xui_rate_limit.sh"
    local old_cron new_cron
    old_cron="$(crontab -l 2>/dev/null || true)"
    new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$TAG" 'index($0, tag) == 0 && $0 != ""')"
    new_cron+="${new_cron:+$'\n'}@reboot $script --restore $TAG"
    printf '%s\n' "$new_cron" | crontab -
    echo "已成功安装开机自动恢复任务。"
}

restore_rules() {
    read_config
    python3 "$PY_HELPER" --boot
    if [[ "$AUTO_ENABLED" == "1" ]]; then
        install_policy_cron
    fi
}

run_diagnose() {
    echo "=== 正在执行系统与限速诊断 ==="
    read_config
    echo "1. 默认公网网卡识别: $(get_default_iface)"
    echo "2. 配置文件配置网卡: ${IFACE:-未配置}"
    echo "3. 检查内核 clsact 支持:"
    if ip link show dev "${IFACE:-$(get_default_iface)}" >/dev/null 2>&1; then
        tc qdisc add dev "${IFACE:-$(get_default_iface)}" clsact 2>/dev/null || true
        echo "   [OK] clsact qdisc 正常"
    else
        echo "   [FAIL] 网卡不可用"
    fi
    echo "4. 检查 ss 监听与代理识别:"
    python3 -c "import sys; sys.path.insert(0, '/root/speex'); from xui_rate_limit import discover_ports; print('   自动扫描到的代理端口:', discover_ports())" 2>/dev/null || echo "   未生成 Python 模块"
    echo "5. 运行一次手动流量检测:"
    python3 "$PY_HELPER"
    echo "=== 诊断完成 ==="
}

# 命令行入参调用
if [[ "${1:-}" == "--restore" ]]; then restore_rules; exit 0; fi
if [[ "${1:-}" == "--check" ]]; then python3 "$PY_HELPER"; exit 0; fi

while true; do
    echo
    echo "====== x-ui / SSR 端口限速管理 2.0 (增强版) ======"
    echo "1. 启用/配置自动扫描模式（自动发现代理端口并设置阈值限速）"
    echo "2. 配置/更新指定端口限速（自定义端口、流量阈值、限速速度、恢复时间）"
    echo "3. 查看当前流量统计与限速状态"
    echo "4. 停止自动限速策略（保留基础限速）"
    echo "5. 彻底移除全部限速规则"
    echo "6. 安装开机自动恢复"
    echo "7. 运行诊断 / 立即执行一次检测"
    echo "0. 退出"
    echo "================================================="
    read -r -p "请选择 [0-7]: " choice
    case "$choice" in
        1) enable_auto_discover_policy ;;
        2) configure_custom_ports ;;
        3) show_status ;;
        4) stop_auto_policy ;;
        5) remove_all_rules ;;
        6) install_boot_restore ;;
        7) run_diagnose ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0 至 7。" ;;
    esac
done
