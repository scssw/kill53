#!/bin/sh
# ssr2vps standalone installer/launcher
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo '请使用 root 运行：bash ssr2vps.sh' >&2
    exit 1
fi

dest=/usr/local/bin/ssr2vps
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp" <<'__SSR2VPS_PYTHON__'
#!/usr/bin/env python3
"""Bind a ShadowsocksR mudbjson master to a traffic-only replica."""
import base64
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CONFIG = Path('/etc/ssr2vps.conf')
STATE = Path('/var/lib/ssr2vps')
BIN = '/usr/local/bin/ssr2vps'
MUD = Path('/usr/local/shadowsocksr/mudb.json')
TIME = Path('/usr/local/SSR-Bash-Python/timelimit.db')
PATH_UNIT = '/etc/systemd/system/ssr2vps-watch.path'
SERVICE_UNIT = '/etc/systemd/system/ssr2vps-watch.service'
TIMER_UNIT = '/etc/systemd/system/ssr2vps-traffic.timer'
NIGHT_UNIT = '/etc/systemd/system/ssr2vps-traffic.service'


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.ssr2vps-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def config():
    try:
        return json.loads(CONFIG.read_text())
    except FileNotFoundError:
        return {}


def save_config(data):
    atomic_write(CONFIG, (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode())


def user_key(row):
    return str(row.get('user', row.get('port', '')))


def rows(raw):
    obj = json.loads(raw)
    if not isinstance(obj, list) or any(not isinstance(x, dict) for x in obj):
        raise ValueError('mudb.json 格式不是用户对象数组')
    return obj


def write_json(path, value):
    atomic_write(path, (json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode(), 0o600)


def ssh(target, command, stdin=None):
    # target is constrained during setup; command is always a fixed literal.
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', target, command],
                          input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def push():
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')
    if not MUD.is_file() or not TIME.is_file():
        raise RuntimeError('找不到 mudb.json 或 timelimit.db，请检查安装路径')
    # Validate the database before sending it.
    rows(MUD.read_text())
    payload = {'mudb': MUD.read_text(), 'timelimit_b64': base64.b64encode(TIME.read_bytes()).decode()}
    ssh(c['peer'], BIN + ' apply-config', json.dumps(payload).encode())
    print('主机用户配置和到期数据已同步到副机。')


def apply_config():
    payload = json.load(sys.stdin)
    incoming = rows(payload['mudb'])
    existing = rows(MUD.read_text()) if MUD.exists() else []
    old = {user_key(x): x for x in existing}
    # The replica's local traffic counters must not be replaced by master's values.
    for item in incoming:
        previous = old.get(user_key(item), {})
        item['u'] = previous.get('u', 0)
        item['d'] = previous.get('d', 0)
    write_json(MUD, incoming)
    atomic_write(TIME, base64.b64decode(payload['timelimit_b64'], validate=True), 0o600)
    print('配置已应用。')


def snapshot():
    if not MUD.is_file():
        raise RuntimeError('找不到副机 mudb.json')
    raw = MUD.read_bytes()
    rows(raw.decode())
    print(json.dumps({'mudb_b64': base64.b64encode(raw).decode()}))


def merge_traffic():
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')
    remote = json.loads(ssh(c['peer'], BIN + ' snapshot'))
    replica = rows(base64.b64decode(remote['mudb_b64'], validate=True).decode())
    master = rows(MUD.read_text())
    ledger_path = STATE / 'ledger.json'
    try:
        ledger = json.loads(ledger_path.read_text())
    except FileNotFoundError:
        ledger = {}
    local = {user_key(x): x for x in master}
    for peer_row in replica:
        key = user_key(peer_row)
        if key not in local:
            continue
        last = ledger.get(key, {})
        for field in ('u', 'd'):
            current = max(0, int(peer_row.get(field, 0) or 0))
            previous = max(0, int(last.get(field, 0) or 0))
            local[key][field] = int(local[key].get(field, 0) or 0) + max(0, current - previous)
            last[field] = current
        ledger[key] = last
    write_json(MUD, master)
    write_json(ledger_path, ledger)
    print('副机流量增量已合并到主机。')


def install_units():
    systemd = '''[Unit]\nDescription=Push SSR2VPS master configuration after local data changes\n\n[Path]\nPathChanged=/usr/local/shadowsocksr/mudb.json\nPathChanged=/usr/local/SSR-Bash-Python/timelimit.db\nUnit=ssr2vps-watch.service\n\n[Install]\nWantedBy=multi-user.target\n'''
    service = '''[Unit]\nDescription=Synchronize SSR2VPS configuration\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/ssr2vps push\n'''
    timer = '''[Unit]\nDescription=Merge replica SSR traffic at 03:00\n\n[Timer]\nOnCalendar=*-*-* 03:00:00\nPersistent=true\nUnit=ssr2vps-traffic.service\n\n[Install]\nWantedBy=timers.target\n'''
    night = '''[Unit]\nDescription=Merge SSR2VPS replica traffic\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/ssr2vps merge-traffic\n'''
    for path, content in ((PATH_UNIT, systemd), (SERVICE_UNIT, service), (TIMER_UNIT, timer), (NIGHT_UNIT, night)):
        Path(path).write_text(content)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', 'ssr2vps-watch.path', 'ssr2vps-traffic.timer'], check=True)


def disable_units():
    subprocess.run(['systemctl', 'disable', '--now', 'ssr2vps-watch.path', 'ssr2vps-traffic.timer'], check=False)
    for p in (PATH_UNIT, SERVICE_UNIT, TIMER_UNIT, NIGHT_UNIT):
        Path(p).unlink(missing_ok=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=False)


def setup(role):
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    data = {'role': role}
    if role == 'master':
        peer = input('副机 SSH 地址（例 root@1.2.3.4）: ').strip()
        if not re.fullmatch(r'[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+', peer):
            raise RuntimeError('SSH 地址格式无效；请使用 user@IPv4/域名')
        data['peer'] = peer
        # Check noninteractive SSH before enabling background jobs.
        ssh(peer, 'true')
        save_config(data)
        install_units()
        push()
    else:
        disable_units()
        save_config(data)
        print('副机已设置。请在主机选择“设为主机”并填写本机 SSH 地址。')


def unbind():
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    disable_units()
    CONFIG.unlink(missing_ok=True)
    print('绑定已取消；SSR 用户和流量数据未删除。')


def menu():
    print('\nSSR2VPS 多 VPS 绑定系统')
    print('1、设为主机')
    print('2、设为副机')
    print('3、取消绑定系统')
    print('0、退出')
    choice = input('请选择: ').strip()
    if choice == '1': setup('master')
    elif choice == '2': setup('replica')
    elif choice == '3': unbind()
    elif choice == '0': return
    else: print('无效选项')


def main():
    try:
        cmd = sys.argv[1] if len(sys.argv) > 1 else 'menu'
        if cmd == 'menu': menu()
        elif cmd == 'push': push()
        elif cmd == 'apply-config': apply_config()
        elif cmd == 'snapshot': snapshot()
        elif cmd == 'merge-traffic': merge_traffic()
        else: raise RuntimeError('用法: ssr2vps [menu|push|apply-config|snapshot|merge-traffic]')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, RuntimeError) as e:
        print('错误: ' + str(e), file=sys.stderr)
        if isinstance(e, subprocess.CalledProcessError) and e.stderr:
            print(e.stderr.decode(errors='replace').strip(), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
__SSR2VPS_PYTHON__
install -m 0755 "$tmp" "$dest"
rm -f "$tmp"
trap - EXIT HUP INT TERM
exec "$dest" menu
