#!/usr/bin/env bash
# ==============================================================================
# x-ui / SSR 端口限速与流量管理面板 3.0 (高灵敏毫秒级响应 + 时段限速)
# 支持 IPv4/IPv6 双栈、高频 10 秒轮询（告别分钟级延迟）、时段定时限速、独立限速端口查看
# ==============================================================================
set -euo pipefail

BASE_DIR="/root/speex"
CONFIG="$BASE_DIR/xui_rate_limit.conf"
TAG="# xui-port-rate-limit"
PY_HELPER="$BASE_DIR/xui_rate_limit.py"
LOG_FILE="$BASE_DIR/xui_rate_limit.log"
SERVICE_FILE="/etc/systemd/system/xui-rate-limit.service"

if [[ $EUID -ne 0 ]]; then
    echo "错误：请使用 root 权限运行此面板。"
    exit 1
fi
mkdir -p "$BASE_DIR"

# 自动安装缺失工具
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
        echo "正在自动安装系统依赖: ${missing[*]} ..."
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    fi
}
install_dependencies

# 内置 Python 核心守护进程
cat > "$PY_HELPER" <<'XUI_RATE_LIMIT_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Traffic-volume policy helper for x-ui/Xray, ShadowsocksR, Docker and custom ports.
High-frequency polling (10s) to eliminate trigger delay.
Supports time-schedule rate limiting (e.g. 10-24).
"""
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

BASE = "/root/speex"
CONFIG = os.path.join(BASE, "xui_rate_limit.conf")
STATE = os.path.join(BASE, "xui_rate_limit_state.json")
LOG_FILE = os.path.join(BASE, "xui_rate_limit.log")
POLL_INTERVAL = 10  # 10秒快速轮询，彻底解决2-3分钟延迟问题


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
        "TIME_SCHEDULE": "",     # 例如 "10-24"
        "TIME_MODE": "1",         # 1: 时段内强制限速, 2: 时段内才监控流量
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
    values["ports"] = sorted(list(set(port_list)), key=lambda x: int(x))
    values["auto_discover"] = values.get("AUTO_DISCOVER", "0") == "1"
    values["auto_enabled"] = values.get("AUTO_ENABLED", "1") == "1"

    values["base_down"] = float(values.get("BASE_DOWN_MBIT", 100))
    values["base_up"] = float(values.get("BASE_UP_MBIT", 100))
    values["window_sec"] = int(float(values.get("WINDOW_MIN", 15)) * 60)
    values["threshold_bytes"] = int(float(values.get("THRESHOLD_GB", 3)) * 1024 * 1024 * 1024)
    values["limit_down"] = float(values.get("LIMIT_DOWN_MBIT", 16))
    values["limit_up"] = float(values.get("LIMIT_UP_MBIT", 16))
    values["limit_sec"] = int(float(values.get("LIMIT_MIN", 30)) * 60)
    values["time_schedule"] = values.get("TIME_SCHEDULE", "").strip()
    values["time_mode"] = values.get("TIME_MODE", "1").strip()
    return values


def is_in_time_schedule(sched_str):
    """判断当前时间是否处于指定时间段 (如 10-24, 22-6)"""
    if not sched_str or sched_str in ("0", "none", "disable"):
        return False
    match = re.match(r"^(\d+)-(\d+)$", sched_str)
    if not match:
        return False
    start_h, end_h = int(match.group(1)), int(match.group(2))
    now = datetime.datetime.now()
    cur_min = now.hour * 60 + now.minute
    start_min = start_h * 60
    end_min = end_h * 60  # 24 时即 1440 分钟

    if start_min < end_min:
        return start_min <= cur_min < end_min
    else:
        # 跨天如 22-6
        return cur_min >= start_min or cur_min < end_min


def run(args, capture=False):
    return subprocess.run(
        args,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
    )


def discover_ports():
    found = set()
    try:
        result = run(["ss", "-H", "-lntup"], True)
    except Exception as e:
        log(f"执行 ss 失败: {e}")
        return []

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

        match_port = re.search(r":(\d+)$", fields[4])
        if not match_port:
            continue
        port = int(match_port.group(1))
        if port <= 0 or port > 65535 or port in (22, 53, 80):
            continue

        owners = re.findall(r'users:\(\("([^\"]+)",(?:pid=)?(\d+),', line)
        is_proxy = False

        for proc_name, pid_str in owners:
            pname = proc_name.lower()
            if any(k in pname for k in proxy_keywords):
                is_proxy = True
                break
            try:
                with open(f"/proc/{pid_str}/cmdline", "rb") as stream:
                    cmdline = stream.read().replace(b"\0", b" ").decode(errors="ignore").lower()
                cwd = os.readlink(f"/proc/{pid_str}/cwd").lower()
                if any(k in cmdline for k in proxy_keywords) or any(k in cwd for k in proxy_keywords):
                    is_proxy = True
                    break
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
    burst_k = max(256, int(rate_mbit * 32))
    return f"{burst_k}k"


def set_rate(dev, port, index, down, up):
    pref_v4 = 42000 + index
    pref_v6 = 52000 + index
    burst_down = get_burst(down)
    burst_up = get_burst(up)

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
    old_ports = state.get("ports", [])
    old_iface = state.get("iface", cfg["IFACE"])

    subprocess.run(["tc", "qdisc", "add", "dev", cfg["IFACE"], "clsact"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if state.get("version") == 4 and old_ports == ports and old_iface == cfg["IFACE"]:
        return

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
    state["version"] = 4
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


def check_and_update():
    cfg = config()
    if not cfg["IFACE"]:
        return

    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {"last": {}, "samples": {}, "active": {}, "ports": []}

    now = int(time.time())

    # 获取端口列表
    if cfg["auto_discover"]:
        ports = discover_ports()
        if not ports:
            ports = state.get("ports", [])
            if not ports:
                save(state)
                return
    else:
        ports = cfg["ports"]
        if not ports:
            save(state)
            return

    reconcile(cfg, state, ports)
    byte_counters = all_counters(cfg["IFACE"])

    # 检查时段设置
    in_time_sched = is_in_time_schedule(cfg["time_schedule"])

    for index, port in enumerate(ports):
        key = str(port)
        raw_v4 = byte_counters.get(42000 + index, 0)
        raw_v6 = byte_counters.get(52000 + index, 0)
        current_counter = raw_v4 + raw_v6

        previous = state["last"].get(key)
        # 精确处理计数器差值（初次启动直接将当前增量作为初值，消除冷启动延迟）
        if previous is None:
            delta = 0
        elif current_counter >= previous:
            delta = current_counter - previous
        else:
            delta = current_counter

        state["last"][key] = current_counter

        samples = state["samples"].setdefault(key, [])
        if delta > 0:
            samples.append([now, delta])
        samples[:] = [s for s in samples if s[0] >= (now - cfg["window_sec"])]
        window_total = sum(s[1] for s in samples)

        active = state["active"].get(key)

        # 情况 1: 启用了“时段强制限速” (TIME_MODE == 1 且处于时段内)
        if cfg["time_schedule"] and cfg["time_mode"] == "1":
            if in_time_sched:
                if not active or active.get("reason") != "schedule":
                    set_rate(cfg["IFACE"], port, index, cfg["limit_down"], cfg["limit_up"])
                    state["active"][key] = {
                        "started": now,
                        "until": 0,  # 0 表示随时间段结束而恢复
                        "reason": "schedule",
                        "speed": cfg["limit_down"]
                    }
                    log(f"[SCHEDULE-LIMIT] 端口 {key} 命中定时限速时段 ({cfg['time_schedule']})，已强制降速至 {cfg['limit_down']} Mbps")
                continue  # 时段内强制限速中，跳过后续流量判定
            else:
                # 刚脱离时段
                if active and active.get("reason") == "schedule":
                    set_rate(cfg["IFACE"], port, index, cfg["base_down"], cfg["base_up"])
                    state["active"].pop(key, None)
                    state["samples"][key] = []
                    log(f"[SCHEDULE-RESTORE] 端口 {key} 离开定时限速时段，已恢复基础速率（下行 {cfg['base_down']} Mbps）")

        # 情况 2: 流量阈值限速处理
        # 如果设置了 TIME_MODE == 2 (仅在时段内检测流量)，非时段则跳过
        if cfg["time_schedule"] and cfg["time_mode"] == "2" and not in_time_sched:
            continue

        if active:
            if active.get("reason") != "schedule" and now >= active.get("until", 0):
                set_rate(cfg["IFACE"], port, index, cfg["base_down"], cfg["base_up"])
                state["active"].pop(key, None)
                state["samples"][key] = []
                log(f"[RESTORE] 端口 {key} 流量限速期满，已恢复基础速率（下行 {cfg['base_down']} Mbps, 上行 {cfg['base_up']} Mbps）")
        else:
            if cfg["auto_enabled"] and window_total >= cfg["threshold_bytes"]:
                set_rate(cfg["IFACE"], port, index, cfg["limit_down"], cfg["limit_up"])
                until_time = now + cfg["limit_sec"]
                state["active"][key] = {
                    "started": now,
                    "until": until_time,
                    "trigger_bytes": window_total,
                    "reason": "volume",
                    "speed": cfg["limit_down"]
                }
                until_str = datetime.datetime.fromtimestamp(until_time).strftime("%Y-%m-%d %H:%M:%S")
                log(f"[LIMIT] 端口 {key} 流量达到 {format_bytes(window_total)} (阈值 {cfg['THRESHOLD_GB']} GB)，立即执行限速至 {cfg['limit_down']} Mbps！恢复时间: {until_str}")

    save(state)


def daemon_loop():
    log(f"守护进程已启动，检测周期: {POLL_INTERVAL} 秒（超灵敏模式）")
    def sig_handler(signum, frame):
        log("守护进程收到退出信号，安全退出...")
        sys.exit(0)
    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    while True:
        try:
            check_and_update()
        except Exception as e:
            log(f"轮询异常: {e}")
        time.sleep(POLL_INTERVAL)


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
    log("[RESTORE] 已将所有受限端口恢复至基础速度")


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
    if action == "--daemon":
        daemon_loop()
    elif action == "--restore-all":
        restore_all()
    elif action == "--remove-all":
        remove_all()
    elif action == "--boot":
        boot_restore()
    else:
        check_and_update()
XUI_RATE_LIMIT_PYTHON
chmod 700 "$PY_HELPER"

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
    TIME_SCHEDULE=""
    TIME_MODE="1"
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
TIME_SCHEDULE="${TIME_SCHEDULE}"
TIME_MODE="${TIME_MODE}"
EOF
    chmod 600 "$CONFIG"
}

# 管理后台守护服务 (优先 Systemd 保证 10 秒级超灵敏轮询；无 systemd 则用 nohup + cron 备用)
start_daemon_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=X-UI and SSR High-Frequency Rate Limit Daemon (10s polling)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PY_HELPER --daemon
Restart=always
RestartSec=3
WorkingDirectory=$BASE_DIR

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xui-rate-limit >/dev/null 2>&1 || true
        systemctl restart xui-rate-limit
    else
        # 兼容无 systemd 环境
        pkill -f "$PY_HELPER --daemon" 2>/dev/null || true
        nohup python3 "$PY_HELPER" --daemon >> "$LOG_FILE" 2>&1 &
        # 安装 cron 保护
        local old_cron new_cron
        old_cron="$(crontab -l 2>/dev/null || true)"
        new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$PY_HELPER" 'index($0, tag) == 0 && $0 != ""')"
        new_cron+="${new_cron:+$'\n'}* * * * * pgrep -f '$PY_HELPER --daemon' >/dev/null || nohup python3 $PY_HELPER --daemon >> $LOG_FILE 2>&1 &"
        printf '%s\n' "$new_cron" | crontab -
    fi
}

stop_daemon_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "$SERVICE_FILE" ]]; then
        systemctl stop xui-rate-limit 2>/dev/null || true
        systemctl disable xui-rate-limit 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -f "$PY_HELPER --daemon" 2>/dev/null || true
    local old_cron new_cron
    old_cron="$(crontab -l 2>/dev/null || true)"
    new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$PY_HELPER" 'index($0, tag) == 0 && $0 != ""')"
    printf '%s\n' "$new_cron" | crontab -
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
    echo "正在应用底层规则并启动高频毫秒级守护进程（每 10 秒轮询一次，秒级限速响应）..."
    python3 "$PY_HELPER" --restore-all 2>/dev/null || true
    start_daemon_service
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 配置成功！"
    echo " 监控端口: $PORTS"
    echo " 平时速度: 下载 ${BASE_DOWN_MBIT} Mbps / 上传 ${BASE_UP_MBIT} Mbps"
    echo " 限速策略: ${WINDOW_MIN} 分钟内达 ${THRESHOLD_GB} GB 限速至 ${LIMIT_DOWN_MBIT} Mbps（持续 ${LIMIT_MIN} 分钟后恢复）"
    echo " 后台守护进程已启动（每 10 秒精准检测，达到 3GB 秒级执行限速！）"
    echo "=================================================="
}

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
    echo "正在扫描系统代理端口并启动守护服务..."
    start_daemon_service
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 自动模式已启用！守护进程每 10 秒检测一次。"
    echo "=================================================="
}

# 菜单 8：独立查看当前已被限速的端口
show_limited_ports() {
    read_config
    echo "================== [当前被限速端口列表] =================="
    python3 - "$BASE_DIR/xui_rate_limit_state.json" "$CONFIG" <<'STATUS_LIMITED_PY'
import json
import os
import sys
import time
import datetime

state_path = sys.argv[1]
conf_path = sys.argv[2]

if not os.path.isfile(state_path):
    print("当前没有任何限速记录。")
    sys.exit(0)

try:
    with open(state_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    print("读取状态失败。")
    sys.exit(0)

now = int(time.time())
active = state.get("active", {})
limited_items = []

for port, act in active.items():
    reason = act.get("reason", "volume")
    speed = act.get("speed", "限速")
    if reason == "schedule":
        limited_items.append({
            "port": port,
            "speed": speed,
            "reason_desc": "命中定时限速时段",
            "restore_desc": "等待设定时段结束自动恢复"
        })
    elif act.get("until", 0) > now:
        rem_sec = act["until"] - now
        rem_min = rem_sec // 60
        until_dt = datetime.datetime.fromtimestamp(act["until"]).strftime("%Y-%m-%d %H:%M:%S")
        start_dt = datetime.datetime.fromtimestamp(act.get("started", now)).strftime("%H:%M:%S")
        trig = act.get("trigger_bytes", 0)
        trig_str = f"{trig / (1024**3):.2f} GB" if trig >= 1024**3 else f"{trig / (1024**2):.2f} MB"
        limited_items.append({
            "port": port,
            "speed": speed,
            "reason_desc": f"流量超标达到 {trig_str} (于 {start_dt} 触发)",
            "restore_desc": f"剩余约 {rem_min} 分钟 (预计 {until_dt} 恢复)"
        })

if not limited_items:
    print("\n  [√] 当前没有端口处于限速状态，所有端口运行正常！\n")
else:
    print(f"\n  [!] 检测到共有 {len(limited_items)} 个端口正处于限速中：\n")
    for item in sorted(limited_items, key=lambda x: int(x["port"])):
        print(f"  ● 端口: {item['port']}")
        print(f"    - 限速速率: {item['speed']} Mbps")
        print(f"    - 限制原因: {item['reason_desc']}")
        print(f"    - 恢复状态: {item['restore_desc']}")
        print("  " + "-" * 50)
print("==========================================================")
STATUS_LIMITED_PY
}

# 菜单 9：设置限速时间段 (如 10-24)
configure_time_schedule() {
    read_config
    echo "================== [设置限速时间段] =================="
    echo "当前限速时段: ${TIME_SCHEDULE:-无（全天正常策略）}"
    echo "时段作用模式: $(if [[ "$TIME_MODE" == "1" ]]; then echo "时段内强制限速至限制速度"; else echo "仅在该时段内计算流量超额"; fi)"
    echo "----------------------------------------------------"
    echo "说明: 输入格式为 H1-H2，例如 10-24 表示 10:00 到 24:00。"
    echo "      也支持如 8-22，或者跨天如 22-6 (晚10点到早6点)。"
    echo "      输入 0 可清除时间段设置。"
    echo "----------------------------------------------------"
    
    local sched_in
    while true; do
        read -r -p "请输入限速时间段（例如 10-24，输入 0 清除，直接回车保留当前）: " sched_in
        sched_in="${sched_in:-${TIME_SCHEDULE:-0}}"
        if [[ "$sched_in" == "0" || "$sched_in" == "none" ]]; then
            TIME_SCHEDULE=""
            write_config
            python3 "$PY_HELPER"
            echo "已成功清除限速时间段设置！"
            return
        elif [[ "$sched_in" =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
            local h1="${BASH_REMATCH[1]}" h2="${BASH_REMATCH[2]}"
            if ((h1 >= 0 && h1 <= 24 && h2 >= 0 && h2 <= 24 && h1 != h2)); then
                TIME_SCHEDULE="$sched_in"
                break
            fi
        fi
        echo "格式错误，请输入合法小时范围（0-24），例如 10-24 或 22-6。"
    done

    echo ""
    echo "请选择在时间段 [$TIME_SCHEDULE] 内的限速行为:"
    echo "1. 时段强制限速: 只要处于该时间段，无论流量多少，立刻将端口限制到限速速度 (${LIMIT_DOWN_MBIT} Mbps)，离开该时段恢复"
    echo "2. 时段流量监控: 仅在该时段内统计流量超额，超出阈值才限速；非该时段随便跑不限速"
    read -r -p "请选择行为模式 [默认 1]: " mode_in
    TIME_MODE="${mode_in:-1}"
    if [[ "$TIME_MODE" != "2" ]]; then TIME_MODE="1"; fi

    write_config
    echo ""
    echo "正在刷新守护进程规则..."
    python3 "$PY_HELPER"
    echo "=================================================="
    echo " 设置成功！"
    echo " 限速时间段: 每天 $TIME_SCHEDULE 点"
    echo " 运行模式: $(if [[ "$TIME_MODE" == "1" ]]; then echo "到达该时段自动强制限速至 ${LIMIT_DOWN_MBIT} Mbps"; else echo "仅在该时段内计算流量超额"; fi)"
    echo "=================================================="
}

show_status() {
    read_config
    echo "==================== 限速运行全貌 ===================="
    echo "网络接口: ${IFACE:-未配置}"
    if [[ "$AUTO_DISCOVER" == "1" ]]; then
        echo "运行模式: 自动扫描代理端口"
    else
        echo "运行模式: 手动指定端口模式 (端口: ${PORTS:-无})"
    fi
    echo "平时带宽: 下载 ${BASE_DOWN_MBIT} Mbps / 上传 ${BASE_UP_MBIT} Mbps"
    echo "流量限速: ${WINDOW_MIN} 分钟内达到 ${THRESHOLD_GB} GB -> 限速至 ${LIMIT_DOWN_MBIT} Mbps (${LIMIT_MIN} 分钟后恢复)"
    echo "定时限速: $(if [[ -n "$TIME_SCHEDULE" ]]; then echo "每天 ${TIME_SCHEDULE} 点 (模式 ${TIME_MODE})"; else echo "未设置"; fi)"
    echo "自动策略: $(if [[ "$AUTO_ENABLED" == "1" ]]; then echo "已启用"; else echo "已停用"; fi)"
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
        if act:
            if act.get("reason") == "schedule":
                status_text = "【已限速 (定时时段强制)】"
            elif act.get("until", 0) > now:
                rem = (act["until"] - now) // 60
                status_text = f"【已限速】剩余约 {rem} 分钟"
            else:
                status_text = "【正常】"
        else:
            status_text = "【正常】"

        print(f"  - 端口 {key:5s} | 窗口累计: {w_str:9s} | 状态: {status_text}")
STATUS_PY

    echo "------------------------------------------------------"
    local tc_count
    tc_count="$({ tc filter show dev "$IFACE" ingress 2>/dev/null || true; tc filter show dev "$IFACE" egress 2>/dev/null || true; } | grep -Ec 'pref (42|52)[0-9]{3}' || true)"
    echo "底层 tc 规则生效条数: $tc_count"
    local is_running="未运行"
    if pgrep -f "$PY_HELPER --daemon" >/dev/null 2>&1; then
        is_running="运行中 (10 秒超灵敏轮询)"
    fi
    echo "后台守护进程状态: $is_running"
    echo "======================================================"
}

stop_auto_policy() {
    read_config
    stop_daemon_service
    AUTO_ENABLED="0"
    write_config
    python3 "$PY_HELPER" --restore-all 2>/dev/null || true
    echo "已停止后台自动限速守护进程，所有受限端口已恢复基础速度（基础端口限速仍保留）。"
}

remove_all_rules() {
    read_config
    stop_daemon_service
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
        start_daemon_service
    fi
}

run_diagnose() {
    echo "=== 正在执行系统与限速诊断 ==="
    read_config
    echo "1. 默认公网网卡: $(get_default_iface)"
    echo "2. 当前配置网卡: ${IFACE:-未配置}"
    echo "3. 检查后台进程: $(pgrep -f "$PY_HELPER --daemon" || echo "未运行")"
    echo "4. 检查 ss 监听与代理识别:"
    python3 -c "import sys; sys.path.insert(0, '/root/speex'); from xui_rate_limit import discover_ports; print('   自动扫描代理端口:', discover_ports())" 2>/dev/null || true
    echo "5. 执行一次手动检测:"
    python3 "$PY_HELPER"
    echo "=== 诊断完成 ==="
}

if [[ "${1:-}" == "--restore" ]]; then restore_rules; exit 0; fi
if [[ "${1:-}" == "--check" ]]; then python3 "$PY_HELPER"; exit 0; fi

while true; do
    echo
    echo "====== x-ui / SSR 端口限速管理 3.0 (高灵敏增强版) ======"
    echo "1. 启用/配置自动扫描模式（自动发现代理端口并设置阈值限速）"
    echo "2. 配置/更新指定端口限速（自定义端口、流量阈值、限速速度、恢复时间）"
    echo "3. 查看当前流量统计与全貌状态"
    echo "4. 停止自动限速守护进程（恢复基础速度）"
    echo "5. 彻底移除全部限速规则"
    echo "6. 安装/更新开机自动恢复"
    echo "7. 运行系统诊断 / 立即执行一次检测"
    echo "8. 查看当前已被限速的端口（独立列表与倒计时）"
    echo "9. 设置限速时间段（如 10-24 点限速）"
    echo "0. 退出"
    echo "======================================================"
    read -r -p "请选择 [0-9]: " choice
    case "$choice" in
        1) enable_auto_discover_policy ;;
        2) configure_custom_ports ;;
        3) show_status ;;
        4) stop_auto_policy ;;
        5) remove_all_rules ;;
        6) install_boot_restore ;;
        7) run_diagnose ;;
        8) show_limited_ports ;;
        9) configure_time_schedule ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0 至 9。" ;;
    esac
done
