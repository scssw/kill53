#!/usr/bin/env bash
# Aggregate ingress/egress bandwidth limits for x-ui/Xray ports.
set -euo pipefail

BASE_DIR="/root/speex"
CONFIG="$BASE_DIR/xui_rate_limit.conf"
TAG="# xui-port-rate-limit"
PY_HELPER="$BASE_DIR/xui_rate_limit.py"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行此面板。"
    exit 1
fi
mkdir -p "$BASE_DIR"

# Keep the helper bundled so this file is the only file needed for deployment.
cat > "$PY_HELPER" <<'XUI_RATE_LIMIT_PYTHON'
#!/usr/bin/env python3
"""Traffic-volume policy helper for x-ui/XRay and ShadowsocksR ports."""
import json
import os
import re
import subprocess
import sys
import shlex
import tempfile
import time

BASE = "/root/speex"
CONFIG = os.path.join(BASE, "xui_rate_limit.conf")
STATE = os.path.join(BASE, "xui_rate_limit_state.json")
THRESHOLD = 3 * 1024**3
WINDOW = 15 * 60
LIMIT_MBIT = 16  # 2000 KB/s
LIMIT_SECONDS = 30 * 60


def config():
    values = {}
    with open(CONFIG, encoding="utf-8") as stream:
        for line in stream:
            if "=" in line:
                key, value = line.rstrip().split("=", 1)
                values[key] = value.strip("'\"")
    values["ports"] = values.get("PORTS", "").split(",")
    values["auto_discover"] = values.get("AUTO_DISCOVER", "0") == "1"
    values["down"] = float(values["DOWN_MBIT"])
    values["up"] = float(values["UP_MBIT"])
    return values


def run(args, capture=False):
    return subprocess.run(args, check=True, text=True,
                          stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                          stderr=subprocess.PIPE if capture else subprocess.DEVNULL)


def discover_ports():
    result = run(["ss", "-H", "-lntup"], True)
    found = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        netid, state = fields[0], fields[1]
        if (netid == "tcp" and state != "LISTEN") or (netid == "udp" and state != "UNCONN"):
            continue
        owners = re.findall(r'users:\(\("([^\"]+)",pid=(\d+),', line)
        is_proxy = False
        for process_name, pid in owners:
            name = process_name.lower()
            if "xray" in name:
                is_proxy = True
                break
            try:
                with open("/proc/{}/cmdline".format(pid), "rb") as stream:
                    command = stream.read().replace(b"\0", b" ").decode(errors="ignore").lower()
                cwd = os.readlink("/proc/{}/cwd".format(pid)).lower()
            except OSError:
                continue
            if ("shadowsocksr" in command or "ssserver" in command or
                    "shadowsocksr" in cwd or name.startswith("ssserver")):
                is_proxy = True
                break
        if is_proxy:
            match = re.search(r":(\d+)$", fields[4])
            if match and int(match.group(1)) > 0:
                found.add(int(match.group(1)))
    return [str(port) for port in sorted(found)]


def all_counters(dev):
    totals = {}
    for direction in ("ingress", "egress"):
        result = run(["tc", "-s", "filter", "show", "dev", dev, direction], True)
        active_pref = None
        for line in result.stdout.splitlines():
            match = re.search(r"\bpref\s+(\d+)\b", line)
            if match:
                active_pref = int(match.group(1))
            if active_pref is not None:
                sent = re.search(r"\bSent\s+(\d+)\s+bytes\b", line)
                if sent:
                    totals[active_pref] = totals.get(active_pref, 0) + int(sent.group(1))
    return totals


def set_rate(dev, port, index, down, up):
    pref = 42000 + index
    for direction, rate, field in (("egress", down, "src_port"),
                                   ("ingress", up, "dst_port")):
        for protocol, handle in (("tcp", 1), ("udp", 2)):
            args = ["tc", "filter", "replace", "dev", dev, direction,
                    "protocol", "ip", "pref", str(pref), "handle", str(handle),
                    "flower", "ip_proto", protocol, field, str(port), "action",
                    "police", "rate", "{}mbit".format(rate), "burst", "128k", "drop"]
            result = subprocess.run(args, text=True, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError("tc 规则添加失败（端口 {}）：{}".format(
                    port, result.stderr.strip()))


def set_rates_bulk(dev, rules):
    commands = []
    for port, index, down, up in rules:
        pref = 42000 + index
        for direction, rate, field in (("egress", down, "src_port"),
                                       ("ingress", up, "dst_port")):
            for protocol, handle in (("tcp", 1), ("udp", 2)):
                args = ["filter", "replace", "dev", dev, direction,
                        "protocol", "ip", "pref", str(pref), "handle", str(handle),
                        "flower", "ip_proto", protocol, field, str(port), "action",
                        "police", "rate", "{}mbit".format(rate), "burst", "128k", "drop"]
                commands.append(shlex.join(args))
    if not commands:
        return
    result = subprocess.run(["tc", "-batch", "-"], input="\n".join(commands) + "\n",
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("tc 批量添加规则失败：{}{}".format(
            result.stderr.strip(), result.stdout.strip()))


def remove_pref(dev, pref):
    for direction in ("ingress", "egress"):
        subprocess.run(["tc", "filter", "del", "dev", dev, direction,
                        "pref", str(pref)], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


def remove_prefs(dev, indexes):
    commands = ["filter del dev {} {} pref {}".format(dev, direction, 42000 + index)
                for index in indexes for direction in ("ingress", "egress")]
    if commands:
        subprocess.run(["tc", "-force", "-batch", "-"],
                       input="\n".join(commands) + "\n", text=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def reconcile(cfg, state, ports):
    old_ports = state.get("ports", [])
    old_iface = state.get("iface", cfg["IFACE"])
    if state.get("version") == 2 and old_ports == ports and old_iface == cfg["IFACE"]:
        return
    remove_prefs(old_iface, range(max(len(old_ports), len(ports))))
    subprocess.run(["tc", "qdisc", "add", "dev", cfg["IFACE"], "clsact"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rules = []
    for index, port in enumerate(ports):
        active = state.get("active", {}).get(port)
        if active and int(time.time()) < active["until"]:
            down, up = min(cfg["down"], LIMIT_MBIT), min(cfg["up"], LIMIT_MBIT)
        else:
            down, up = cfg["down"], cfg["up"]
        rules.append((port, index, down, up))
    try:
        set_rates_bulk(cfg["IFACE"], rules)
    except BaseException:
        remove_prefs(cfg["IFACE"], range(max(len(old_ports), len(ports))))
        raise
    state["ports"] = ports
    state["iface"] = cfg["IFACE"]
    state["version"] = 2
    state["last"] = {port: 0 for port in ports}
    state["samples"] = {port: state.get("samples", {}).get(port, []) for port in ports}
    state["active"] = {port: active for port, active in state.get("active", {}).items() if port in ports}
    state["blocked"] = [port for port in state.get("blocked", []) if port in ports]


def save(state):
    fd, path = tempfile.mkstemp(prefix=".xui-rate-", dir=BASE)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2)
            stream.write("\n")
        os.chmod(path, 0o600)
        os.replace(path, STATE)
    finally:
        if os.path.exists(path):
            os.unlink(path)


def main():
    os.makedirs(BASE, mode=0o700, exist_ok=True)
    cfg = config()
    if cfg.get("AUTO_ENABLED") != "1":
        raise SystemExit("Automatic policy is disabled")
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {"last": {}, "samples": {}, "active": {}, "blocked": []}
    now = int(time.time())
    ports = discover_ports() if cfg["auto_discover"] else [p for p in cfg["ports"] if p]
    reconcile(cfg, state, ports)
    if not ports:
        print("未发现 xray 或 ShadowsocksR 监听端口")
        save(state)
        return
    byte_counters = all_counters(cfg["IFACE"])
    for index, port in enumerate(ports):
        key = str(port)
        value = byte_counters.get(42000 + index, 0)
        previous = state["last"].get(key)
        delta = max(0, value - previous) if previous is not None else 0
        state["last"][key] = value
        samples = state["samples"].setdefault(key, [])
        samples.append([now, delta])
        samples[:] = [sample for sample in samples if sample[0] >= now - WINDOW]
        amount = sum(sample[1] for sample in samples)
        blocked = set(state.get("blocked", []))
        active = state["active"].get(key)
        if active and now >= active["until"]:
            set_rate(cfg["IFACE"], port, index, cfg["down"], cfg["up"])
            state["last"][key] = 0
            state["active"].pop(key, None)
            blocked.add(key)
            print("RESTORE port={}".format(key))
        elif active:
            pass
        elif key in blocked:
            if amount < THRESHOLD:
                blocked.remove(key)
        elif len(samples) > 1 and amount >= THRESHOLD:
            set_rate(cfg["IFACE"], port, index,
                     min(cfg["down"], LIMIT_MBIT), min(cfg["up"], LIMIT_MBIT))
            state["last"][key] = 0
            state["active"][key] = {"started": now, "until": now + LIMIT_SECONDS}
            print("LIMIT port={} window_bytes={} speed={}mbit".format(key, amount, LIMIT_MBIT))
        state["blocked"] = sorted(blocked)
    save(state)


def restore_all():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        return
    ports = state.get("ports", []) if cfg["auto_discover"] else [p for p in cfg["ports"] if p]
    for index, port in enumerate(ports):
        if str(port) in state.get("active", {}):
            set_rate(cfg["IFACE"], port, index, cfg["down"], cfg["up"])
    state["active"] = {}
    state["blocked"] = []
    save(state)


def restore_boot():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {"last": {}, "samples": {}, "active": {}, "blocked": []}
    now = int(time.time())
    ports = discover_ports() if cfg["auto_discover"] else [p for p in cfg["ports"] if p]
    state["ports"] = []
    reconcile(cfg, state, ports)
    for index, port in enumerate(ports):
        active = state.get("active", {}).get(str(port))
        if active and now < active["until"]:
            set_rate(cfg["IFACE"], port, index,
                     min(cfg["down"], LIMIT_MBIT), min(cfg["up"], LIMIT_MBIT))
        elif active:
            set_rate(cfg["IFACE"], port, index, cfg["down"], cfg["up"])
            state["active"].pop(str(port), None)
    save(state)


def remove_all():
    cfg = config()
    try:
        with open(STATE, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        return
    dev = state.get("iface", cfg["IFACE"])
    remove_prefs(dev, range(len(state.get("ports", []))))
    state["ports"] = []
    state["active"] = {}
    save(state)


if __name__ == "__main__":
    if sys.argv[1:] == ["--restore-all"]:
        restore_all()
    elif sys.argv[1:] == ["--boot"]:
        restore_boot()
    elif sys.argv[1:] == ["--remove-all"]:
        remove_all()
    else:
        main()
XUI_RATE_LIMIT_PYTHON
chmod 700 "$PY_HELPER"

for tool in tc ip ss python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "缺少命令：$tool（通常由 iproute2 提供）"
        exit 1
    fi
done

get_iface() {
    ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}
read_config() {
    IFACE=""; PORTS=""; DOWN_MBIT=""; UP_MBIT=""; AUTO_ENABLED="0"; AUTO_DISCOVER="0"
    if [[ -f "$CONFIG" ]]; then source "$CONFIG"; fi
}
write_config() {
    {
        printf 'IFACE=%q\nPORTS=%q\nDOWN_MBIT=%q\nUP_MBIT=%q\nAUTO_ENABLED=%q\nAUTO_DISCOVER=%q\n' \
            "$IFACE" "$PORTS" "$DOWN_MBIT" "$UP_MBIT" "$AUTO_ENABLED" "$AUTO_DISCOVER"
    } > "$CONFIG"
    chmod 600 "$CONFIG"
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
    if [[ "${AUTO_ENABLED:-0}" == "1" ]]; then
        python3 "$PY_HELPER" --restore-all
        remove_policy_cron
        AUTO_ENABLED=0
    fi
    if [[ "${AUTO_DISCOVER:-0}" == "1" ]]; then python3 "$PY_HELPER" --remove-all; fi
    remove_rules "${IFACE:-$iface}" "${PORTS:-}"
    apply_rules "$iface" "$ports" "$down" "$up"
    IFACE="$iface"; PORTS="$ports"; DOWN_MBIT="$down"; UP_MBIT="$up"; AUTO_DISCOVER=0
    write_config
    echo "已应用 IPv4 规则：端口 $ports；每端口下载 ${down} Mbps、上传 ${up} Mbps。"
    echo "同一端口上的用户共享该端口上限。"
}
show_status() {
    read_config
    if [[ -z "$PORTS" && "$AUTO_DISCOVER" != "1" ]]; then echo "尚未配置限速端口。"; return; fi
    echo "配置接口：$IFACE"
    if [[ "$AUTO_DISCOVER" == "1" ]]; then
        echo "端口：自动发现 xray / ShadowsocksR 监听端口"
        python3 - "$BASE_DIR/xui_rate_limit_state.json" <<'STATUS_PY'
import datetime
import json
import os
import sys
import time

state_path = sys.argv[1]
if os.path.isfile(state_path):
    try:
        with open(state_path, encoding="utf-8") as stream:
            state = json.load(stream)
    except (OSError, ValueError):
        state = {}
    ports = state.get("ports", [])
    print("当前发现端口：" + (",".join(map(str, ports)) if ports else "无"))
    now = int(time.time())
    active = [(str(port), item) for port, item in state.get("active", {}).items()
              if int(item.get("until", 0)) > now]
    if not active:
        print("当前限速端口：无")
    else:
        print("当前限速端口：")
        for port, item in sorted(active, key=lambda pair: int(pair[0])):
            fmt = lambda stamp: datetime.datetime.fromtimestamp(int(stamp)).strftime("%Y-%m-%d %H:%M:%S")
            print("  端口 {}：限速开始 {}，预计解除 {}".format(
                port, fmt(item.get("started", 0)), fmt(item["until"])))
else:
    print("当前发现端口：暂无检测数据")
    print("当前限速端口：暂无检测数据")
STATUS_PY
    else
        echo "端口：$PORTS"
    fi
    echo "每端口下载上限：${DOWN_MBIT} Mbps；上传上限：${UP_MBIT} Mbps"
    if [[ "$AUTO_ENABLED" == "1" ]]; then echo "自动策略：已启用（15 分钟 / 3 GB / 2000 KB/s / 30 分钟恢复）"; else echo "自动策略：未启用"; fi
    if [[ "$AUTO_DISCOVER" != "1" ]]; then
        echo "当前限速端口：$PORTS（基础限速，无自动解除时间）"
    fi
    local tc_count
    tc_count="$({ tc filter show dev "$IFACE" ingress 2>/dev/null || true; tc filter show dev "$IFACE" egress 2>/dev/null || true; } | grep -Ec 'pref 42[0-9][0-9][0-9]' || true)"
    echo "tc 过滤器条目：$tc_count"
}
disable_limits() {
    read_config
    if [[ "$AUTO_DISCOVER" == "1" ]]; then python3 "$PY_HELPER" --remove-all; fi
    [[ -z "$PORTS" ]] || remove_rules "$IFACE" "$PORTS"
    rm -f "$CONFIG"
    echo "已移除本脚本配置的端口限速规则。"
}
remove_policy_cron() {
    local old_cron new_cron
    old_cron="$(crontab -l 2>/dev/null || true)"
    new_cron="$(printf '%s\n' "$old_cron" | awk -v tag="$PY_HELPER" 'index($0, tag) == 0 && $0 != ""')"
    printf '%s\n' "$new_cron" | crontab -
}
enable_default_policy() {
    read_config
    local default_iface="${IFACE:-$(get_iface)}" iface_input down up
    read -r -p "公网网络接口（默认 ${default_iface:-需手动填写}）: " iface_input
    IFACE="${iface_input:-$default_iface}"
    [[ -n "$IFACE" ]] || { echo "无法自动识别接口。"; return 1; }
    read_positive "发现端口的基础下载上限" "${DOWN_MBIT:-100}"; down="$REPLY"
    read_positive "发现端口的基础上传上限" "${UP_MBIT:-100}"; up="$REPLY"
    if [[ "$AUTO_ENABLED" == "1" ]]; then python3 "$PY_HELPER" --restore-all; fi
    if [[ "$AUTO_DISCOVER" != "1" && -n "$PORTS" ]]; then remove_rules "$IFACE" "$PORTS"; fi
    PORTS=""; DOWN_MBIT="$down"; UP_MBIT="$up"; AUTO_DISCOVER=1
    AUTO_ENABLED=1
    write_config
    remove_policy_cron
    local old_cron python
    old_cron="$(crontab -l 2>/dev/null || true)"
    python="$(command -v python3)"
    printf '%s\n' "$old_cron" "*/2 * * * * $python $PY_HELPER --check >> $BASE_DIR/xui_rate_limit.log 2>&1" | crontab -
    python3 "$PY_HELPER" --check
    echo "默认策略已启用：自动扫描 xray / ShadowsocksR 监听端口；仅限 IPv4；15 分钟内达到 3 GB 后限速 2000 KB/s（约 16 Mbps），30 分钟后恢复基础限速。"
}
disable_default_policy() {
    read_config
    remove_policy_cron
    if [[ "$AUTO_ENABLED" == "1" ]]; then
        python3 "$PY_HELPER" --restore-all
        AUTO_ENABLED=0
        write_config
    fi
    echo "自动策略已停止，基础端口限速配置仍保留。"
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
    if [[ "$AUTO_DISCOVER" == "1" ]]; then python3 "$PY_HELPER" --boot; return; fi
    [[ -n "$PORTS" ]] || exit 0
    apply_rules "$IFACE" "$PORTS" "$DOWN_MBIT" "$UP_MBIT"
    if [[ "$AUTO_ENABLED" == "1" ]]; then python3 "$PY_HELPER" --boot; fi
}
if [[ "${1:-}" == "--restore" ]]; then restore_rules; exit 0; fi
if [[ "${1:-}" == "--check" ]]; then python3 "$PY_HELPER" --check; exit 0; fi

while true; do
    echo
    echo "====== x-ui 端口限速管理 ======"
    echo "1. 启用默认自动策略（IPv4，15 分钟 / 3 GB / 2000 KB/s / 30 分钟恢复）"
    echo "2. 配置/更新基础端口限速（IPv4，上下行 Mbps）"
    echo "3. 查看状态"
    echo "4. 停止自动策略（保留基础限速）"
    echo "5. 移除全部端口限速规则"
    echo "6. 安装开机自动恢复"
    echo "0. 退出"
    read -r -p "请选择: " choice
    case "$choice" in
        1) enable_default_policy ;;
        2) enable_limits ;;
        3) show_status ;;
        4) disable_default_policy ;;
        5) disable_default_policy; disable_limits ;;
        6) install_boot_restore ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 1 至 6 或 0。" ;;
    esac
done
