#!/usr/bin/env bash
# ==============================================================================
# x-ui / SSR 端口限速与流量管理面板 3.1 (智能防卡死 + 自动动态追踪版)
# 特性：
# 1. 动态自动识别 x-ui/xray、SSR 现有端口以及后续新建端口，无需手动配置成千上万端口
# 2. 彻底杜绝全端口扫描卡死、100% CPU 和 ksoftirqd 崩溃问题
# 3. 10 秒轻量级超灵敏轮询，跑满即刻限速，零延迟
# 4. 支持查看被限速端口倒计时 (选项 8) 与 设置限速时间段如 10-24 点 (选项 9)
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

# 紧急降温：如果发现有残留卡死的旧进程，先安全终止
pkill -9 -f "xui_rate_limit.py" 2>/dev/null || true

# 安装基础依赖
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
        echo "正在安装基础系统组件: ${missing[*]} ..."
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

# 内置 Python 核心模块
cat > "$PY_HELPER" <<'XUI_RATE_LIMIT_PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
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
POLL_INTERVAL = 10  # 10秒快速轮询，响应灵敏且CPU接近 0%


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
        "AUTO_DISCOVER": "1",    # 默认开启智能自动模式
        "AUTO_ENABLED": "1",
        "BASE_DOWN_MBIT": "100",
        "BASE_UP_MBIT": "100",
        "WINDOW_MIN": "15",
        "THRESHOLD_MB": "1000",
        "LIMIT_DOWN_MBIT": "16",
        "LIMIT_UP_MBIT": "16",
        "LIMIT_MIN": "30",
        "TIME_SCHEDULE": "",     # 例如 "10-24"
        "TIME_MODE": "1",         # 1: 强制限速, 2: 仅时段监控
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
        if item.isdigit() and 1 <= int(item) <= 65535:
            port_list.append(item)
    # 最多允许手动配置 50 个端口，彻底防爆卡死
    values["ports"] = sorted(list(set(port_list)), key=lambda x: int(x))[:50]
    values["auto_discover"] = values.get("AUTO_DISCOVER", "1") == "1"
    values["auto_enabled"] = values.get("AUTO_ENABLED", "1") == "1"

    values["base_down"] = float(values.get("BASE_DOWN_MBIT", 100))
    values["base_up"] = float(values.get("BASE_UP_MBIT", 100))
    values["window_sec"] = int(float(values.get("WINDOW_MIN", 15)) * 60)
    thresh_mb = float(values.get("THRESHOLD_MB", float(values.get("THRESHOLD_GB", 1)) * 1024))
    values["threshold_mb"] = thresh_mb
    values["threshold_bytes"] = int(thresh_mb * 1024 * 1024)
    values["limit_down"] = float(values.get("LIMIT_DOWN_MBIT", 16))
    values["limit_up"] = float(values.get("LIMIT_UP_MBIT", 16))
    values["limit_sec"] = int(float(values.get("LIMIT_MIN", 30)) * 60)
    values["time_schedule"] = values.get("TIME_SCHEDULE", "").strip()
    values["time_mode"] = values.get("TIME_MODE", "1").strip()
    return values


def is_in_time_schedule(sched_str):
    if not sched_str or sched_str in ("0", "none", "disable"):
        return False
    match = re.match(r"^(\d+)-(\d+)$", sched_str)
    if not match:
        return False
    start_h, end_h = int(match.group(1)), int(match.group(2))
    now = datetime.datetime.now()
    cur_min = now.hour * 60 + now.minute
    start_min = start_h * 60
    end_min = end_h * 60

    if start_min < end_min:
        return start_min <= cur_min < end_min
    else:
        return cur_min >= start_min or cur_min < end_min


def discover_ports():
    """
    智能精准自动识别 x-ui/xray、SSR 当前正在监听的端口。
    支持现有节点及后续在面板中新建的节点端口。
    """
    found = set()
    try:
        res = subprocess.run(["ss", "-H", "-lntup"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return []

    # 代理常见关键字
    proxy_kw = ("xray", "x-ui", "3x-ui", "v2ray", "sing-box", "ssserver", "ss-server")

    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        netid, state = fields[0], fields[1]
        if netid == "tcp" and state != "LISTEN":
            continue
        if netid == "udp" and state not in ("UNCONN", "ESTAB"):
            continue

        local_addr = fields[4]
        port_match = re.search(r":(\d+)$", local_addr)
        if not port_match:
            continue
        port = int(port_match.group(1))

        # 排除系统级服务端口
        if port in (22, 25, 53, 67, 68, 80, 123, 631, 3306, 5432):
            continue

        line_lower = line.lower()
        is_proxy = False

        # 1. 匹配 xray / x-ui (如 xray-linux-amd6) / 3x-ui / sing-box 等
        if any(kw in line_lower for kw in proxy_kw):
            is_proxy = True

        # 2. 匹配 python3 运行的 SSR (检查 cmdline)
        if not is_proxy and "python" in line_lower:
            pids = re.findall(r'pid=(\d+)', line)
            for pid in pids:
                try:
                    with open(f"/proc/{pid}/cmdline", "rb") as f:
                        cmd = f.read().replace(b"\0", b" ").decode(errors="ignore").lower()
                    if any(k in cmd for k in ("server.py", "shadowsocks", "ssr", "ssserver")):
                        is_proxy = True
                        break
                except OSError:
                    continue

        # 3. 匹配 Docker 代理的端口映射
        if not is_proxy and "docker-proxy" in line_lower:
            if f"-host-port {port}" in line_lower:
                is_proxy = True

        if is_proxy and 1 <= port <= 65535:
            found.add(str(port))

    # 最多保留 50 个活跃端口，避免极端情况下的性能瓶颈
    return sorted(list(found), key=lambda x: int(x))[:50]


def all_counters(dev):
    totals = {}
    for direction in ("ingress", "egress"):
        try:
            res = subprocess.run(["tc", "-s", "filter", "show", "dev", dev, direction],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except Exception:
            continue
        active_pref = None
        for line in res.stdout.splitlines():
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

    # 如果网络接口和监控端口没有任何变动，直接返回，绝不重复刷新造成系统负担
    if state.get("version") == 5 and old_ports == ports and old_iface == cfg["IFACE"]:
        return

    # 若发现新增或删除了端口，安全同步规则
    remove_prefs(old_iface, range(max(len(old_ports), len(ports))))

    for index, port in enumerate(ports):
        active = state.get("active", {}).get(port)
        if active and (active.get("until", 0) > int(time.time()) or active.get("reason") == "schedule"):
            down = min(cfg["base_down"], cfg["limit_down"])
            up = min(cfg["base_up"], cfg["limit_up"])
        else:
            down = cfg["base_down"]
            up = cfg["base_up"]
        set_rate(cfg["IFACE"], port, index, down, up)

    state["ports"] = ports
    state["iface"] = cfg["IFACE"]
    state["version"] = 5
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

    # 自动追踪或手动列表
    if cfg["auto_discover"]:
        ports = discover_ports()
        if not ports:
            # 若瞬间未检测到，暂保留历史端口避免断流
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
    in_time_sched = is_in_time_schedule(cfg["time_schedule"])

    for index, port in enumerate(ports):
        key = str(port)
        raw_v4 = byte_counters.get(42000 + index, 0)
        raw_v6 = byte_counters.get(52000 + index, 0)
        current_counter = raw_v4 + raw_v6

        previous = state["last"].get(key)
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

        # 模式 1: 时段强制限速
        if cfg["time_schedule"] and cfg["time_mode"] == "1":
            if in_time_sched:
                if not active or active.get("reason") != "schedule":
                    set_rate(cfg["IFACE"], port, index, cfg["limit_down"], cfg["limit_up"])
                    state["active"][key] = {
                        "started": now,
                        "until": 0,
                        "reason": "schedule",
                        "speed": cfg["limit_down"]
                    }
                    log(f"[SCHEDULE-LIMIT] 端口 {key} 命中定时限速时段 ({cfg['time_schedule']})，已强制降速至 {cfg['limit_down']} Mbps")
                continue
            else:
                if active and active.get("reason") == "schedule":
                    set_rate(cfg["IFACE"], port, index, cfg["base_down"], cfg["base_up"])
                    state["active"].pop(key, None)
                    state["samples"][key] = []
                    log(f"[SCHEDULE-RESTORE] 端口 {key} 离开定时限速时段，已恢复基础速率（{cfg['base_down']} Mbps）")

        # 模式 2: 仅在时段内才计算流量超额
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
                thresh_display = f"{cfg.get('threshold_mb', 1000):.0f}" if float(cfg.get('threshold_mb', 1000)).is_integer() else f"{cfg.get('threshold_mb', 1000):.1f}"
                log(f"[LIMIT] 端口 {key} 流量达 {format_bytes(window_total)} (阈值 {thresh_display} MB)，立即执行限速至 {cfg['limit_down']} Mbps！恢复时间: {until_str}")

    save(state)


def daemon_loop():
    log(f"守护进程已启动，检测周期: {POLL_INTERVAL} 秒（智能动态监控模式）")
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
    log("[RESTORE] 已将受限端口恢复至基础速度")


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
        # 彻底清空 clsact 防止遗留大量陈旧规则
        subprocess.run(["tc", "qdisc", "del", "dev", dev, "clsact"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    state["ports"] = []
    state["active"] = {}
    save(state)
    log("[CLEAN] 已彻底清除所有限速与内核队列规则")


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
    AUTO_DISCOVER="1"
    AUTO_ENABLED="1"
    BASE_DOWN_MBIT="100"
    BASE_UP_MBIT="100"
    WINDOW_MIN="15"
    THRESHOLD_MB="1000"
    LIMIT_DOWN_MBIT="16"
    LIMIT_UP_MBIT="16"
    LIMIT_MIN="30"
    TIME_SCHEDULE=""
    TIME_MODE="1"
    if [[ -f "$CONFIG" ]]; then
        source "$CONFIG"
        if [[ -z "${THRESHOLD_MB:-}" && -n "${THRESHOLD_GB:-}" ]]; then
            THRESHOLD_MB="$(awk -v g="$THRESHOLD_GB" 'BEGIN {printf "%.0f", g*1024}')"
        fi
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
THRESHOLD_MB="${THRESHOLD_MB}"
LIMIT_DOWN_MBIT="${LIMIT_DOWN_MBIT}"
LIMIT_UP_MBIT="${LIMIT_UP_MBIT}"
LIMIT_MIN="${LIMIT_MIN}"
TIME_SCHEDULE="${TIME_SCHEDULE}"
TIME_MODE="${TIME_MODE}"
EOF
    chmod 600 "$CONFIG"
}

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
        pkill -f "$PY_HELPER --daemon" 2>/dev/null || true
        nohup python3 "$PY_HELPER" --daemon >> "$LOG_FILE" 2>&1 &
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

# 菜单 1：智能自动模式（推荐！全自动追踪 x-ui 和 SSR 现有及新建的端口，绝对不卡死）
enable_auto_discover_policy() {
    read_config
    local auto_iface
    auto_iface="$(get_default_iface)"
    local current_iface="${IFACE:-$auto_iface}"

    echo "--- [模式1: 智能自动动态追踪模式（推荐）] ---"
    echo "特点：自动精准识别 xray(x-ui) 和 SSR 节点端口，后续新建的入站端口也会自动纳管，CPU 占用 0%"
    echo "----------------------------------------------------------------------------------"
    read -r -p "公网网络接口（默认 $current_iface）: " iface_in
    IFACE="${iface_in:-$current_iface}"
    ip link show dev "$IFACE" >/dev/null 2>&1 || { echo "找不到网络接口: $IFACE"; return 1; }

    echo ""
    echo ">> 步骤 1: 设置基础正常速度（节点平时允许的最大速度）"
    read_positive_float "每个节点平时下载上限" "${BASE_DOWN_MBIT:-100}" " Mbps"; BASE_DOWN_MBIT="$REPLY"
    read_positive_float "每个节点平时上传上限" "${BASE_UP_MBIT:-100}" " Mbps"; BASE_UP_MBIT="$REPLY"

    echo ""
    echo ">> 步骤 2: 设置流量超额限速策略"
    read_positive_float "流量统计时间窗口" "${WINDOW_MIN:-15}" " 分钟"; WINDOW_MIN="$REPLY"
    read_positive_float "触发限速的流量阈值" "${THRESHOLD_MB:-1000}" " MB"; THRESHOLD_MB="$REPLY"
    read_rate_input "超额后限制的速度（Mbps，或输入如 2000k）" "${LIMIT_DOWN_MBIT:-16}"; LIMIT_DOWN_MBIT="$REPLY"; LIMIT_UP_MBIT="$REPLY"
    read_positive_float "限速持续时间（达到后自动恢复基础速度）" "${LIMIT_MIN:-30}" " 分钟"; LIMIT_MIN="$REPLY"

    AUTO_DISCOVER="1"
    AUTO_ENABLED="1"
    PORTS=""
    write_config

    echo ""
    echo "正在清除可能卡死的旧规则并启动守护进程..."
    stop_daemon_service
    python3 "$PY_HELPER" --remove-all 2>/dev/null || true
    start_daemon_service
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 智能自动模式已成功开启！"
    echo " 自动追踪: xray / x-ui / SSR / 现有与后续新建端口"
    echo " 限速策略: ${WINDOW_MIN} 分钟内达 ${THRESHOLD_MB} MB 限速至 ${LIMIT_DOWN_MBIT} Mbps (${LIMIT_MIN} 分钟后恢复)"
    echo " 守护进程每 10 秒灵敏轮询，秒级限速响应，负载低至 0.00%！"
    echo "=================================================="
}

# 菜单 2：手动指定少量固定端口（防卡死拦截）
configure_custom_ports() {
    read_config
    local auto_iface
    auto_iface="$(get_default_iface)"
    local current_iface="${IFACE:-$auto_iface}"

    echo "--- [模式2: 手动指定特定端口限速] ---"
    echo "注意: 仅用于指定特定的少数几个端口（如 100,65500 或 443,8443）。"
    echo "      严禁输入 100-65500 这种超大范围！若要管全部 x-ui/SSR 端口，请直接使用【模式 1】！"
    echo "----------------------------------------------------------------------------------"
    read -r -p "公网网络接口（默认 $current_iface）: " iface_in
    IFACE="${iface_in:-$current_iface}"
    ip link show dev "$IFACE" >/dev/null 2>&1 || { echo "找不到网络接口: $IFACE"; return 1; }

    local ports_in
    while true; do
        read -r -p "请输入要监控的具体端口（多个逗号隔开，如 100,65500，默认 ${PORTS:-100,65500}）: " ports_in
        ports_in="${ports_in:-${PORTS:-100,65500}}"
        if [[ "$ports_in" =~ - ]]; then
            echo "错误拦截：禁止输入端口段（如 100-65500）！这会创建几万条规则导致系统卡死崩溃。"
            echo "提示：如果你想自动管理所有 x-ui 和 SSR 端口，请使用菜单中的【选项 1 智能自动模式】！"
            continue
        fi

        local -a p_arr
        IFS=',' read -r -a p_arr <<< "$ports_in"
        local valid=1 cleaned=""
        for p in "${p_arr[@]}"; do
            p="${p//[[:space:]]/}"
            if [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)); then
                cleaned+="${cleaned:+,}$p"
            else
                valid=0; break
            fi
        done
        if [[ $valid -eq 1 && -n "$cleaned" ]]; then
            PORTS="$cleaned"
            break
        fi
        echo "输入无效，请输入具体的有效端口号（如 100,65500）。"
    done

    echo ""
    read_positive_float "每个端口平时下载上限" "${BASE_DOWN_MBIT:-100}" " Mbps"; BASE_DOWN_MBIT="$REPLY"
    read_positive_float "每个端口平时上传上限" "${BASE_UP_MBIT:-100}" " Mbps"; BASE_UP_MBIT="$REPLY"
    read_positive_float "流量统计时间窗口" "${WINDOW_MIN:-15}" " 分钟"; WINDOW_MIN="$REPLY"
    read_positive_float "触发限速的流量阈值" "${THRESHOLD_MB:-1000}" " MB"; THRESHOLD_MB="$REPLY"
    read_rate_input "超额后限制的速度（Mbps，或输入如 2000k）" "${LIMIT_DOWN_MBIT:-16}"; LIMIT_DOWN_MBIT="$REPLY"; LIMIT_UP_MBIT="$REPLY"
    read_positive_float "限速持续时间" "${LIMIT_MIN:-30}" " 分钟"; LIMIT_MIN="$REPLY"

    AUTO_DISCOVER="0"
    AUTO_ENABLED="1"
    write_config

    echo ""
    echo "正在刷新规则并启动守护进程..."
    stop_daemon_service
    python3 "$PY_HELPER" --remove-all 2>/dev/null || true
    start_daemon_service
    python3 "$PY_HELPER"

    echo "=================================================="
    echo " 手动端口限速配置成功！"
    echo " 监控端口: $PORTS"
    echo " 限速策略: ${WINDOW_MIN} 分钟内达 ${THRESHOLD_MB} MB 限速至 ${LIMIT_DOWN_MBIT} Mbps"
    echo "=================================================="
}

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
            "reason_desc": f"流量超标达 {trig_str} (于 {start_dt} 触发)",
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
    echo "2. 时段流量监控: 仅在该时间段内统计流量超额，超出阈值才限速；非该时段随便跑不限速"
    read -r -p "请选择行为模式 [默认 1]: " mode_in
    TIME_MODE="${mode_in:-1}"
    if [[ "$TIME_MODE" != "2" ]]; then TIME_MODE="1"; fi

    write_config
    python3 "$PY_HELPER"
    echo "=================================================="
    echo " 时间段限速设置成功！(每天 $TIME_SCHEDULE 点)"
    echo "=================================================="
}

show_status() {
    read_config
    echo "==================== 限速运行全貌 ===================="
    echo "网络接口: ${IFACE:-未配置}"
    if [[ "$AUTO_DISCOVER" == "1" ]]; then
        echo "运行模式: 智能自动动态追踪 (xray / x-ui / SSR 现有与新建端口)"
    else
        echo "运行模式: 手动指定端口模式 (端口: ${PORTS:-无})"
    fi
    echo "平时带宽: 下载 ${BASE_DOWN_MBIT} Mbps / 上传 ${BASE_UP_MBIT} Mbps"
    echo "流量限速: ${WINDOW_MIN} 分钟内达 ${THRESHOLD_MB} MB -> 限速至 ${LIMIT_DOWN_MBIT} Mbps (${LIMIT_MIN} 分钟后恢复)"
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
except Exception:
    print("读取状态失败。")
    sys.exit(0)

ports = state.get("ports", [])
print(f"当前监控端口: {','.join(map(str, ports)) if ports else '无'}")

now = int(time.time())
active = state.get("active", {})

if not ports:
    print("提示: 当前没有发现代理监听端口，请检查 xray / SSR 服务是否启动。")
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
    echo "已停止后台守护进程，受限端口已恢复基础速度。"
}

# 彻底清理并紧急降温
emergency_reset() {
    read_config
    echo "正在紧急终止进程并彻底重置网络队列..."
    stop_daemon_service
    pkill -9 -f "xui_rate_limit.py" 2>/dev/null || true
    local dev="${IFACE:-$(get_default_iface)}"
    tc qdisc del dev "$dev" clsact 2>/dev/null || true
    rm -f "$CONFIG" "$BASE_DIR/xui_rate_limit_state.json" "$LOG_FILE"
    echo "已彻底清除全部 tc 规则，系统负载已降回 0%！"
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
    echo "=== 正在执行系统与代理端口诊断 ==="
    read_config
    echo "1. 默认公网网卡: $(get_default_iface)"
    echo "2. 检查后台进程: $(pgrep -f "$PY_HELPER --daemon" || echo "未运行")"
    echo "3. 实时扫描 x-ui(xray) 与 SSR 端口:"
    python3 -c "import sys; sys.path.insert(0, '/root/speex'); from xui_rate_limit import discover_ports; print('   -> 检测到的活跃代理端口:', discover_ports())" 2>/dev/null || true
    echo "4. 执行一次即时检测:"
    python3 "$PY_HELPER"
    echo "=== 诊断完成 ==="
}

if [[ "${1:-}" == "--restore" ]]; then restore_rules; exit 0; fi
if [[ "${1:-}" == "--check" ]]; then python3 "$PY_HELPER"; exit 0; fi

while true; do
    echo
    echo "====== x-ui / SSR 端口限速管理 3.1 (智能防卡死版) ======"
    echo "1. 启用智能自动模式（推荐！自动追踪 x-ui/SSR 现有与新建端口）"
    echo "2. 配置指定端口限速（手动输入指定端口，如 100,65500）"
    echo "3. 查看当前流量统计与全貌状态"
    echo "4. 停止自动限速守护进程（恢复基础速度）"
    echo "5. 彻底移除全部限速规则（紧急降温重置）"
    echo "6. 安装/更新开机自动恢复"
    echo "7. 运行系统诊断 / 检查发现的代理端口"
    echo "8. 查看当前已被限速的端口（独立列表与倒计时）"
    echo "9. 设置限速时间段（如 10-24 点限速）"
    echo "0. 退出"
    echo "======================================================="
    read -r -p "请选择 [0-9]: " choice
    case "$choice" in
        1) enable_auto_discover_policy ;;
        2) configure_custom_ports ;;
        3) show_status ;;
        4) stop_auto_policy ;;
        5) emergency_reset ;;
        6) install_boot_restore ;;
        7) run_diagnose ;;
        8) show_limited_ports ;;
        9) configure_time_schedule ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0 至 9。" ;;
    esac
done
