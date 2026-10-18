#!/bin/sh
# Unified SSR / 3xs x-ui VPS synchronization launcher.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo '请使用 root 运行：bash sx2vps.sh' >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp" <<'__SX_SSR2VPS_PYTHON__'
#!/usr/bin/env python3
"""Bind a ShadowsocksR mudbjson master to a traffic-only replica."""
import base64
import getpass
import hashlib
import ipaddress
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
SYNC_TIMER_UNIT = '/etc/systemd/system/ssr2vps-sync.timer'
WATCH_TIMER_UNIT = '/etc/systemd/system/ssr2vps-watch.timer'
WATCH_STATE = STATE / 'watch-signature'


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


def disable_units():
    subprocess.run(['systemctl', 'disable', '--now', 'ssr2vps-watch.path',
                    'ssr2vps-watch.timer', 'ssr2vps-traffic.timer', 'ssr2vps-sync.timer'], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for p in (PATH_UNIT, SERVICE_UNIT, WATCH_TIMER_UNIT, TIMER_UNIT, NIGHT_UNIT, SYNC_TIMER_UNIT,
              '/etc/systemd/system/ssr2vps-sync.service'):
        Path(p).unlink(missing_ok=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=False)


def peer_status():
    c = config()
    if c.get('role') == 'master':
        try:
            result = ssh(c['peer'], BIN + ' status').decode().strip()
        except (OSError, subprocess.CalledProcessError):
            return
        if result != 'replica':
            disable_units()
            CONFIG.unlink(missing_ok=True)
            print('检测到副机已取消绑定，主机同步也已取消。')


def apply_peer_unbind():
    disable_units()
    CONFIG.unlink(missing_ok=True)


def enforce_limits(data):
    changed = False
    for item in data:
        try:
            limit = int(item.get('transfer_enable', 0) or 0)
            used = max(0, int(item.get('u', 0) or 0)) + max(0, int(item.get('d', 0) or 0))
        except (TypeError, ValueError):
            continue
        field = 'passwd' if 'passwd' in item or 'password' not in item else 'password'
        if limit > 0 and used >= limit and item.get(field) != '1':
            item[field] = '1'
            changed = True
    if changed:
        write_json(MUD, data)


def ssh(target, command, stdin=None):
    # target is constrained during setup; command is always a fixed literal.
    c = config()
    args = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
    if target == c.get('peer') and c.get('peer_port'):
        args += ['-p', str(c['peer_port'])]
    return subprocess.run(args + [target, command],
                          input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def connect_peer(peer):
    c = config()
    try:
        ssh(peer, 'true')
        return int(c['peer_port']) if peer == c.get('peer') and c.get('peer_port') else None
    except (OSError, subprocess.CalledProcessError):
        print('未检测到可用的 SSH 密钥连接，请输入副机 SSH 端口并安装公钥。')
    port = input('对方 SSH 端口（默认 22；如果不是 22 请输入实际端口）: ').strip() or '22'
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise RuntimeError('SSH 端口无效')
    key = Path.home() / '.ssh/id_rsa'
    key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not key.exists():
        subprocess.run(['ssh-keygen', '-q', '-t', 'rsa', '-b', '4096', '-N', '', '-f', str(key)], check=True)
    elif not Path(str(key) + '.pub').exists():
        pub = subprocess.run(['ssh-keygen', '-y', '-f', str(key)], check=True,
                             stdout=subprocess.PIPE).stdout
        Path(str(key) + '.pub').write_bytes(pub)
    print('将要求输入副机登录密码以安装密钥...')
    subprocess.run(['ssh-copy-id', '-o', 'StrictHostKeyChecking=accept-new', '-p', port, peer], check=True)
    subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o',
                    'StrictHostKeyChecking=accept-new', '-p', port, peer, 'true'], check=True)
    return int(port)


def push():
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')
    if not MUD.is_file() or not TIME.is_file():
        raise RuntimeError('找不到 mudb.json 或 timelimit.db，请检查安装路径')
    # Validate the database before sending it.
    master_rows = rows(MUD.read_text())
    enforce_limits(master_rows)
    mud_raw = MUD.read_text()
    payload = {'mudb': mud_raw, 'timelimit_b64': base64.b64encode(TIME.read_bytes()).decode()}
    ssh(c['peer'], BIN + ' apply-config', json.dumps(payload).encode())
    print('主机用户配置和到期数据已同步到副机。')


def watch_check():
    if config().get('role') != 'master':
        return
    digest = hashlib.sha256(MUD.read_bytes() + b'\0' + TIME.read_bytes()).hexdigest()
    try:
        previous = WATCH_STATE.read_text().strip()
    except FileNotFoundError:
        previous = ''
    if digest != previous:
        push()
        atomic_write(WATCH_STATE, (digest + '\n').encode())


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
    added = {'u': 0, 'd': 0}
    matched = 0
    for peer_row in replica:
        key = user_key(peer_row)
        if key not in local:
            continue
        matched += 1
        last = ledger.get(key, {})
        for field in ('u', 'd'):
            current = max(0, int(peer_row.get(field, 0) or 0))
            previous = max(0, int(last.get(field, 0) or 0))
            delta = max(0, current - previous)
            local[key][field] = int(local[key].get(field, 0) or 0) + delta
            added[field] += delta
            last[field] = current
        ledger[key] = last
    write_json(MUD, master)
    write_json(ledger_path, ledger)
    print('副机流量已合并：匹配用户 %d 个，上传 +%d 字节，下载 +%d 字节。' %
          (matched, added['u'], added['d']))


def install_units():
    systemd = '''[Unit]\nDescription=Push SSR2VPS master configuration after local data changes\n\n[Path]\nPathChanged=/usr/local/shadowsocksr/mudb.json\nPathChanged=/usr/local/SSR-Bash-Python/timelimit.db\nUnit=ssr2vps-watch.service\n\n[Install]\nWantedBy=multi-user.target\n'''
    service = '''[Unit]\nDescription=Synchronize SSR2VPS configuration\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/ssr2vps watch-check\n'''
    timer = '''[Unit]\nDescription=Merge replica SSR traffic every 66 minutes\n\n[Timer]\nOnBootSec=66min\nOnUnitActiveSec=66min\nAccuracySec=1s\nUnit=ssr2vps-traffic.service\n\n[Install]\nWantedBy=timers.target\n'''
    night = '''[Unit]\nDescription=Merge SSR2VPS replica traffic\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/ssr2vps merge-traffic\n'''
    sync_timer = '''[Unit]\nDescription=Check whether SSR2VPS peer remains bound\n\n[Timer]\nOnBootSec=15s\nOnUnitActiveSec=30s\nUnit=ssr2vps-sync.service\n\n[Install]\nWantedBy=timers.target\n'''
    sync_service = '''[Unit]\nDescription=Check SSR2VPS peer binding\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/ssr2vps peer-status\n'''
    watch_timer = '''[Unit]\nDescription=Check SSR2VPS master data for missed file events\n\n[Timer]\nOnBootSec=10s\nOnUnitActiveSec=10s\nAccuracySec=1s\nUnit=ssr2vps-watch.service\n\n[Install]\nWantedBy=timers.target\n'''
    for path, content in ((PATH_UNIT, systemd), (SERVICE_UNIT, service), (WATCH_TIMER_UNIT, watch_timer), (TIMER_UNIT, timer), (NIGHT_UNIT, night), (SYNC_TIMER_UNIT, sync_timer), ('/etc/systemd/system/ssr2vps-sync.service', sync_service)):
        Path(path).write_text(content)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', 'ssr2vps-watch.path', 'ssr2vps-watch.timer', 'ssr2vps-traffic.timer', 'ssr2vps-sync.timer'], check=True)


def setup(role):
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    data = {'role': role}
    if role == 'master':
        host = input('副机 IP: ').strip()
        if not re.fullmatch(r'[A-Za-z0-9.-]+', host) or host.startswith('-') or '..' in host:
            raise RuntimeError('IP/主机名格式无效')
        peer = 'root@' + host
        data['peer'] = peer
        # Install a key interactively when noninteractive SSH is not ready.
        port = connect_peer(peer)
        if port:
            data['peer_port'] = port
        save_config(data)
        install_units()
        push()
        try:
            ssh(peer, BIN + ' register-master-ip')
        except (OSError, subprocess.CalledProcessError):
            print('无法获取副机看到的主机 IP。', file=sys.stderr)
    else:
        disable_units()
        save_config(data)
        print('副机已设置。请在主机选择“设为主机”并填写本机 SSH 地址。')


def unbind():
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    c = config()
    if c.get('role') == 'master' and c.get('peer'):
        try:
            ssh(c['peer'], BIN + ' unbind-peer')
        except (OSError, subprocess.CalledProcessError):
            print('无法联系副机；主机本地绑定仍会取消。', file=sys.stderr)
    apply_peer_unbind()
    print('绑定已取消；SSR 用户和流量数据未删除。')


def status_report():
    c = config()
    if not c.get('role'):
        return
    print('SSR：' + ('主机' if c['role'] == 'master' else '副机'))
    if c['role'] == 'master' and c.get('peer'):
        try:
            host_ip = ssh(c['peer'], BIN + ' register-master-ip').decode().strip()
        except (OSError, subprocess.CalledProcessError):
            host_ip = ''
        if host_ip:
            print('  主机 IP：' + host_ip)
    elif c.get('master_ip'):
        print('  主机 IP：' + c['master_ip'])
    peer = c.get('peer', '')
    if peer.startswith('root@'):
        peer = peer[5:]
    if peer:
        print('  同步 IP：' + peer)
    try:
        raw = Path(TIMER_UNIT).read_text()
        match = re.search(r'^OnUnitActiveSec=(.+)$', raw, re.M)
        if match:
            value = match.group(1)
            duration = re.fullmatch(r'(\d+)(s|min|h)', value)
            if duration:
                seconds = int(duration.group(1)) * {'s': 1, 'min': 60, 'h': 3600}[duration.group(2)]
                print('  流量同步间隔：%s（约 %.2f 小时）' % (value, seconds / 3600))
    except OSError:
        pass


def register_master_ip():
    c = config()
    if c.get('role') != 'replica':
        return
    fields = os.environ.get('SSH_CONNECTION', '').split()
    if len(fields) >= 4:
        try:
            c['master_ip'] = str(ipaddress.ip_address(fields[0]))
        except ValueError:
            return
        save_config(c)
        print(c['master_ip'])


def set_interval():
    path = Path(TIMER_UNIT)
    if not path.is_file():
        print('SSR 尚未配置主机流量同步定时器。')
        return
    value = input('请输入 SSR 流量同步间隔（小时，支持小数）: ').strip()
    try:
        hours = float(value)
        if not 0.01 <= hours <= 8760:
            raise ValueError
    except ValueError:
        print('请输入 0.01 到 8760 之间的小时数。')
        return
    seconds = int(hours * 3600)
    interval = (str(seconds // 3600) + 'h' if seconds % 3600 == 0 else
                str(seconds // 60) + 'min' if seconds % 60 == 0 else str(seconds) + 's')
    raw = path.read_text()
    raw, count = re.subn(r'(?m)^OnBootSec=.*$', 'OnBootSec=' + interval, raw, count=1)
    if not count:
        raise RuntimeError('SSR 定时器缺少 OnBootSec')
    raw, count = re.subn(r'(?m)^OnUnitActiveSec=.*$', 'OnUnitActiveSec=' + interval, raw, count=1)
    if not count:
        raise RuntimeError('SSR 定时器缺少 OnUnitActiveSec')
    path.write_text(raw)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'restart', 'ssr2vps-traffic.timer'], check=True)
    print('SSR 流量同步间隔已改为 ' + interval)


def menu():
    print('\nSSR2VPS 多 VPS 绑定系统')
    print('1、设为主机')
    print('2、设为副机')
    print('3、取消绑定系统')
    print('4、一键同步副机流量到主机')
    print('0、退出')
    choice = input('请选择: ').strip()
    if choice == '1': setup('master')
    elif choice == '2': setup('replica')
    elif choice == '3': unbind()
    elif choice == '4': merge_traffic()
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
        elif cmd == 'status': print(config().get('role', 'unbound'))
        elif cmd == 'status-report': status_report()
        elif cmd == 'set-interval': set_interval()
        elif cmd == 'register-master-ip': register_master_ip()
        elif cmd == 'peer-status': peer_status()
        elif cmd == 'watch-check': watch_check()
        elif cmd == 'unbind-peer': apply_peer_unbind()
        else: raise RuntimeError('用法: ssr2vps [menu|push|apply-config|snapshot|merge-traffic]')
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, RuntimeError) as e:
        print('错误: ' + str(e), file=sys.stderr)
        if isinstance(e, subprocess.CalledProcessError) and e.stderr:
            print(e.stderr.decode(errors='replace').strip(), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
__SX_SSR2VPS_PYTHON__
install -m 0755 "$tmp" /usr/local/bin/ssr2vps
rm -f "$tmp"
trap - EXIT HUP INT TERM

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat > "$tmp" <<'__SX_XUI2VPS_PYTHON__'
#!/usr/bin/env python3
"""Sync 3xs x-ui inbound/client config and merge replica traffic deltas."""
import hashlib
import ipaddress
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CONFIG = Path('/etc/xui2vps.conf')
STATE = Path('/var/lib/xui2vps')
BIN = '/usr/local/bin/xui2vps'
DB = Path('/etc/x-ui/x-ui.db')
PATH_UNIT = '/etc/systemd/system/xui2vps-watch.path'
SERVICE_UNIT = '/etc/systemd/system/xui2vps-watch.service'
TIMER_UNIT = '/etc/systemd/system/xui2vps-traffic.timer'
NIGHT_UNIT = '/etc/systemd/system/xui2vps-traffic.service'
SYNC_TIMER_UNIT = '/etc/systemd/system/xui2vps-sync.timer'
TABLES = ('inbounds', 'client_traffics')
INBOUND_COUNTERS = ('up', 'down', 'all_time')
CLIENT_COUNTERS = ('up', 'down', 'all_time', 'last_online')


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.xui2vps-', dir=str(path.parent))
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


def disable_units():
    subprocess.run(['systemctl', 'disable', '--now', 'xui2vps-watch.path',
                    'xui2vps-traffic.timer', 'xui2vps-sync.timer'], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for p in (PATH_UNIT, SERVICE_UNIT, TIMER_UNIT, NIGHT_UNIT, SYNC_TIMER_UNIT):
        Path(p).unlink(missing_ok=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=False)


def peer_status():
    c = config()
    if c.get('role') != 'master' or not c.get('peer'):
        return
    try:
        result = ssh(c['peer'], BIN + ' status').decode().strip()
    except (OSError, subprocess.CalledProcessError):
        return
    if result != 'replica':
        disable_units()
        CONFIG.unlink(missing_ok=True)
        print('检测到副机已取消绑定，主机同步也已取消。')


def apply_peer_unbind():
    disable_units()
    CONFIG.unlink(missing_ok=True)
    for p in (STATE / 'last_sync.json', STATE / 'config.sha256', STATE / 'ledger.json'):
        p.unlink(missing_ok=True)


def ssh(target, command, stdin=None):
    c = config()
    args = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10']
    if target == c.get('peer') and c.get('peer_port'):
        args += ['-p', str(c['peer_port'])]
    return subprocess.run(args + [target, command],
                          input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def connect_peer(peer):
    c = config()
    try:
        ssh(peer, 'true')
        return int(c['peer_port']) if peer == c.get('peer') and c.get('peer_port') else None
    except (OSError, subprocess.CalledProcessError):
        print('未检测到可用的 SSH 密钥连接，请输入副机 SSH 端口并安装公钥。')
    port = input('对方 SSH 端口（默认 22；如果不是 22 请输入实际端口）: ').strip() or '22'
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise RuntimeError('SSH 端口无效')
    key = Path.home() / '.ssh/id_rsa'
    key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not key.exists():
        subprocess.run(['ssh-keygen', '-q', '-t', 'rsa', '-b', '4096', '-N', '', '-f', str(key)], check=True)
    elif not Path(str(key) + '.pub').exists():
        pub = subprocess.run(['ssh-keygen', '-y', '-f', str(key)], check=True,
                             stdout=subprocess.PIPE).stdout
        Path(str(key) + '.pub').write_bytes(pub)
    print('将要求输入副机登录密码以安装密钥...')
    subprocess.run(['ssh-copy-id', '-o', 'StrictHostKeyChecking=accept-new', '-p', port, peer], check=True)
    subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o',
                    'StrictHostKeyChecking=accept-new', '-p', port, peer, 'true'], check=True)
    return int(port)


def open_db(path=DB):
    if not path.is_file():
        raise RuntimeError('找不到 ' + str(path) + '，请确认 3xs x-ui 已安装且使用 SQLite')
    db = sqlite3.connect(str(path), timeout=30)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA busy_timeout=30000')
    return db


def table_columns(db, table):
    return [r['name'] for r in db.execute('PRAGMA table_info("%s")' % table)]


def rows(db, table):
    if not table_columns(db, table):
        raise RuntimeError('数据库缺少表 ' + table + '，请确认是 3xs/3x-ui SQLite 数据库')
    return [dict(r) for r in db.execute('SELECT * FROM "%s"' % table)]


def database_snapshot():
    """Use SQLite's online backup API so WAL-mode databases are consistent."""
    fd, name = tempfile.mkstemp(prefix='xui2vps-snapshot-', suffix='.db')
    os.close(fd)
    try:
        src = open_db()
        dst = sqlite3.connect(name)
        try:
            src.backup(dst)
        finally:
            src.close()
            dst.close()
        snap = sqlite3.connect(name)
        try:
            snap.row_factory = sqlite3.Row
            result = {t: rows(snap, t) for t in TABLES}
            columns = {t: table_columns(snap, t) for t in TABLES}
            return {'tables': result, 'columns': columns}
        finally:
            snap.close()
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def parse_settings(settings_raw):
    if not settings_raw:
        return {}
    if isinstance(settings_raw, dict):
        return settings_raw
    try:
        return json.loads(settings_raw)
    except (ValueError, TypeError):
        return {}


def client_key(c):
    for k in ('email', 'id', 'password'):
        val = str(c.get(k) or '').strip()
        if val:
            return val
    return ''


def extract_sync_state(tables):
    inbounds = tables.get('inbounds', [])
    clients = tables.get('client_traffics', [])
    inbounds_by_id = {r['id']: r for r in inbounds if 'id' in r}

    state = {'inbounds': {}, 'client_traffics': {}}

    for ib in inbounds:
        port = ib.get('port')
        if not port:
            continue
        port_str = str(port)
        settings = parse_settings(ib.get('settings'))
        raw_clients = settings.get('clients', [])
        clients_dict = {}
        for c in raw_clients:
            ck = client_key(c)
            if ck:
                clients_dict[ck] = dict(c)

        state['inbounds'][port_str] = {
            'port': port,
            'protocol': str(ib.get('protocol') or ''),
            'remark': str(ib.get('remark') or ''),
            'enable': int(ib.get('enable', 1) if ib.get('enable') is not None else 1),
            'listen': str(ib.get('listen') or ''),
            'tag': str(ib.get('tag') or ''),
            'stream_settings': str(ib.get('stream_settings') or ''),
            'sniffing': str(ib.get('sniffing') or ''),
            'clients': clients_dict
        }

    for ct in clients:
        inbound_id = ct.get('inbound_id')
        port = inbounds_by_id.get(inbound_id, {}).get('port')
        email = str(ct.get('email') or '').strip()
        if port and email:
            key = f"{port}_{email}"
            state['client_traffics'][key] = {
                'email': email,
                'port': port,
                'total': int(ct.get('total') or 0),
                'expiry_time': int(ct.get('expiry_time') or 0),
                'enable': int(ct.get('enable', 1) if ct.get('enable') is not None else 1),
                'reset': int(ct.get('reset') or 0)
            }

    return state


def two_way_sync(master_db, remote_tables, last_sync_state):
    m_tables = {
        'inbounds': rows(master_db, 'inbounds'),
        'client_traffics': rows(master_db, 'client_traffics')
    }
    r_tables = {
        'inbounds': remote_tables.get('inbounds', []),
        'client_traffics': remote_tables.get('client_traffics', [])
    }

    m_state = extract_sync_state(m_tables)
    r_state = extract_sync_state(r_tables)
    s_state = last_sync_state if last_sync_state else {'inbounds': {}, 'client_traffics': {}}

    m_inbounds = m_state['inbounds']
    r_inbounds = r_state['inbounds']
    s_inbounds = s_state.get('inbounds', {})

    master_changed = False
    replica_needs_push = False

    inbound_cols = table_columns(master_db, 'inbounds')
    client_cols = table_columns(master_db, 'client_traffics')

    all_ports = set(m_inbounds.keys()) | set(r_inbounds.keys()) | set(s_inbounds.keys())

    for port_str in all_ports:
        in_m = port_str in m_inbounds
        in_r = port_str in r_inbounds
        in_s = port_str in s_inbounds

        # 1. Inbound deleted on Master
        if in_s and in_r and not in_m:
            replica_needs_push = True
            print('检测到主机已删除端口 %s 线路，将同步删除副机对应线路' % port_str)
            continue

        # 2. Inbound deleted on Replica
        if in_s and in_m and not in_r:
            m_ib_row = next((r for r in m_tables['inbounds'] if str(r.get('port')) == port_str), None)
            if m_ib_row:
                master_db.execute('DELETE FROM client_traffics WHERE inbound_id = ?', [m_ib_row['id']])
                master_db.execute('DELETE FROM inbounds WHERE id = ?', [m_ib_row['id']])
                master_changed = True
                print('检测到副机已删除端口 %s 线路，已同步删除主机对应线路' % port_str)
            continue

        # 3. Inbound added on Master
        if not in_s and in_m and not in_r:
            replica_needs_push = True
            print('检测到主机新建端口 %s 线路，将同步推送到副机' % port_str)
            continue

        # 4. Inbound added on Replica
        if not in_s and in_r and not in_m:
            r_ib_row = next((r for r in r_tables['inbounds'] if str(r.get('port')) == port_str), None)
            if r_ib_row:
                new_ib = dict(r_ib_row)
                for c in INBOUND_COUNTERS:
                    if c in new_ib:
                        new_ib[c] = 0
                insert_cols = [c for c in inbound_cols if c != 'id' and c in new_ib]
                marks = ','.join('?' for _ in insert_cols)
                names = ','.join('"%s"' % c for c in insert_cols)
                cur = master_db.execute('INSERT INTO inbounds (%s) VALUES (%s)' % (names, marks),
                                        [new_ib.get(c) for c in insert_cols])
                new_inbound_id = cur.lastrowid
                for r_ct in r_tables['client_traffics']:
                    if r_ct.get('inbound_id') == r_ib_row.get('id'):
                        new_ct = dict(r_ct)
                        new_ct['inbound_id'] = new_inbound_id
                        for c in CLIENT_COUNTERS:
                            if c in new_ct:
                                new_ct[c] = 0
                        ct_insert_cols = [c for c in client_cols if c != 'id' and c in new_ct]
                        ct_marks = ','.join('?' for _ in ct_insert_cols)
                        ct_names = ','.join('"%s"' % c for c in ct_insert_cols)
                        master_db.execute('INSERT INTO client_traffics (%s) VALUES (%s)' % (ct_names, ct_marks),
                                          [new_ct.get(c) for c in ct_insert_cols])
                master_changed = True
                print('已从副机采纳新建线路：端口 %s' % port_str)
            continue

        # 5. Inbound exists on both Master and Replica
        if in_m and in_r:
            m_curr_ib = next((r for r in rows(master_db, 'inbounds') if str(r.get('port')) == port_str), None)
            r_curr_ib = next((r for r in r_tables['inbounds'] if str(r.get('port')) == port_str), None)
            if not m_curr_ib or not r_curr_ib:
                continue

            m_settings = parse_settings(m_curr_ib.get('settings'))
            r_settings = parse_settings(r_curr_ib.get('settings'))

            m_clist = m_settings.get('clients', [])
            r_clist = r_settings.get('clients', [])

            m_cmap = {client_key(c): dict(c) for c in m_clist if client_key(c)}
            r_cmap = {client_key(c): dict(c) for c in r_clist if client_key(c)}
            s_cmap = s_inbounds.get(port_str, {}).get('clients', {})

            all_ckeys = set(m_cmap.keys()) | set(r_cmap.keys()) | set(s_cmap.keys())
            m_settings_changed = False

            r_ct_by_email = {str(ct.get('email') or '').strip(): ct for ct in r_tables['client_traffics'] if ct.get('inbound_id') == r_curr_ib['id']}

            for ckey in all_ckeys:
                cin_m = ckey in m_cmap
                cin_r = ckey in r_cmap
                cin_s = ckey in s_cmap

                # Case 5.1: Deleted on Master
                if cin_s and cin_r and not cin_m:
                    replica_needs_push = True
                    print('端口 %s 线路：检测到主机已删除客户端 %s，将同步删除副机对应客户端' % (port_str, ckey))
                    continue

                # Case 5.2: Deleted on Replica
                if cin_s and cin_m and not cin_r:
                    if ckey in m_cmap:
                        del m_cmap[ckey]
                        m_settings_changed = True
                    master_db.execute('DELETE FROM client_traffics WHERE inbound_id = ? AND email = ?',
                                      [m_curr_ib['id'], ckey])
                    master_changed = True
                    print('端口 %s 线路：检测到副机已删除客户端 %s，已同步删除主机对应客户端' % (port_str, ckey))
                    continue

                # Case 5.3: Added on Master
                if not cin_s and cin_m and not cin_r:
                    replica_needs_push = True
                    print('端口 %s 线路：检测到主机新增客户端 %s，将同步推送到副机' % (port_str, ckey))
                    continue

                # Case 5.4: Added on Replica
                if not cin_s and cin_r and not cin_m:
                    m_cmap[ckey] = r_cmap[ckey]
                    m_settings_changed = True
                    r_ct = r_ct_by_email.get(ckey)
                    if r_ct:
                        new_ct = dict(r_ct)
                        new_ct['inbound_id'] = m_curr_ib['id']
                        for c in CLIENT_COUNTERS:
                            if c in new_ct:
                                new_ct[c] = 0
                        ct_insert_cols = [c for c in client_cols if c != 'id' and c in new_ct]
                        ct_marks = ','.join('?' for _ in ct_insert_cols)
                        ct_names = ','.join('"%s"' % c for c in ct_insert_cols)
                        master_db.execute('INSERT INTO client_traffics (%s) VALUES (%s)' % (ct_names, ct_marks),
                                          [new_ct.get(c) for c in ct_insert_cols])
                    else:
                        c_item = r_cmap[ckey]
                        new_ct = {
                            'inbound_id': m_curr_ib['id'],
                            'enable': int(c_item.get('enable', 1) if c_item.get('enable') is not None else 1),
                            'email': c_item.get('email', ckey),
                            'up': 0, 'down': 0,
                            'expiry_time': int(c_item.get('expiryTime', 0) or 0),
                            'total': int(c_item.get('totalGB', 0) or 0) * 1024**3,
                            'reset': int(c_item.get('reset', 0) or 0)
                        }
                        ct_insert_cols = [c for c in client_cols if c != 'id' and c in new_ct]
                        ct_marks = ','.join('?' for _ in ct_insert_cols)
                        ct_names = ','.join('"%s"' % c for c in ct_insert_cols)
                        master_db.execute('INSERT INTO client_traffics (%s) VALUES (%s)' % (ct_names, ct_marks),
                                          [new_ct.get(c) for c in ct_insert_cols])
                    master_changed = True
                    print('端口 %s 线路：已从副机采纳新增客户端 %s' % (port_str, ckey))
                    continue

                # Case 5.5: Modified
                if cin_m and cin_r:
                    m_client = m_cmap[ckey]
                    r_client = r_cmap[ckey]
                    s_client = s_cmap.get(ckey, {})

                    if r_client != s_client and m_client == s_client:
                        m_cmap[ckey] = r_client
                        m_settings_changed = True
                        r_ct = r_ct_by_email.get(ckey, {})
                        if r_ct:
                            master_db.execute(
                                'UPDATE client_traffics SET enable=?, expiry_time=?, total=?, reset=? WHERE inbound_id=? AND email=?',
                                [r_ct.get('enable', 1), r_ct.get('expiry_time', 0), r_ct.get('total', 0),
                                 r_ct.get('reset', 0), m_curr_ib['id'], ckey]
                            )
                        master_changed = True
                        print('端口 %s 线路：检测到副机修改了客户端 %s 设置，已同步更新主机' % (port_str, ckey))
                    elif m_client != s_client and r_client == s_client:
                        replica_needs_push = True
                        print('端口 %s 线路：检测到主机修改了客户端 %s 设置，将同步更新副机' % (port_str, ckey))
                    elif m_client != s_client and r_client != s_client and m_client != r_client:
                        replica_needs_push = True

            if m_settings_changed:
                m_settings['clients'] = list(m_cmap.values())
                new_settings_str = json.dumps(m_settings, ensure_ascii=False)
                master_db.execute('UPDATE inbounds SET settings = ? WHERE id = ?',
                                  [new_settings_str, m_curr_ib['id']])
                master_changed = True

            m_ib_state = m_inbounds.get(port_str, {})
            r_ib_state = r_inbounds.get(port_str, {})
            s_ib_state = s_inbounds.get(port_str, {})

            m_ib_conf = {k: v for k, v in m_ib_state.items() if k != 'clients'}
            r_ib_conf = {k: v for k, v in r_ib_state.items() if k != 'clients'}
            s_ib_conf = {k: v for k, v in s_ib_state.items() if k != 'clients'}

            if r_ib_conf != s_ib_conf and m_ib_conf == s_ib_conf:
                upd_cols = [c for c in ('remark', 'enable', 'listen', 'tag', 'stream_settings', 'sniffing')
                            if c in inbound_cols and c in r_curr_ib]
                assignments = ','.join('"%s"=?' % c for c in upd_cols)
                master_db.execute('UPDATE inbounds SET %s WHERE id = ?' % assignments,
                                  [r_curr_ib.get(c) for c in upd_cols] + [m_curr_ib['id']])
                master_changed = True
                print('端口 %s 线路：检测到副机修改了入站配置，已同步更新主机' % port_str)
            elif m_ib_conf != s_ib_conf and r_ib_conf == s_ib_conf:
                replica_needs_push = True

    return master_changed, replica_needs_push


def sync_and_push(force=False, remote_tables=None):
    peer_status()
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')

    if remote_tables is None:
        try:
            remote_raw = ssh(c['peer'], BIN + ' snapshot')
            remote_tables = json.loads(remote_raw).get('tables', {})
        except Exception as e:
            if force:
                raise
            return False, {}

    last_sync_path = STATE / 'last_sync.json'
    try:
        last_sync_state = json.loads(last_sync_path.read_text())
    except (FileNotFoundError, ValueError):
        last_sync_state = None

    master_changed = False
    replica_needs_push = False

    with open_db() as db:
        db.execute('BEGIN IMMEDIATE')
        try:
            master_changed, replica_needs_push = two_way_sync(db, remote_tables, last_sync_state)
            if master_changed:
                db.commit()
                subprocess.run(['systemctl', 'restart', 'x-ui'], check=False)
            else:
                db.rollback()
        except Exception:
            db.rollback()
            raise

    payload = database_snapshot()
    signature = config_signature(payload)
    signature_path = STATE / 'config.sha256'

    sig_changed = True
    if signature_path.exists():
        try:
            if signature_path.read_text().strip() == signature:
                sig_changed = False
        except OSError:
            pass

    if force or master_changed or replica_needs_push or sig_changed:
        raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
        ssh(c['peer'], BIN + ' apply-config', raw)
        atomic_write(signature_path, (signature + '\n').encode())
        print('x-ui 入站/用户配置已同步到副机；副机本地流量计数已保留。')

    new_sync_state = extract_sync_state(payload['tables'])
    atomic_write(last_sync_path, (json.dumps(new_sync_state, ensure_ascii=False, indent=2) + '\n').encode())
    return True, remote_tables


def push(force=False):
    peer_status()
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')
    sync_and_push(force=force)


def config_signature(payload):
    """Hash only settings that define inbounds/clients, ignoring volatile counters and timestamps."""
    stable = {'tables': {}, 'columns': payload['columns']}
    volatile_fields = {
        'inbounds': set(INBOUND_COUNTERS) | {'last_traffic_reset_time'},
        'client_traffics': set(CLIENT_COUNTERS) | {'last_sub_fetch', 'updated_at', 'created_at'},
    }
    for table in TABLES:
        stable['tables'][table] = [
            {k: v for k, v in row.items() if k not in volatile_fields[table]}
            for row in payload['tables'][table]
        ]
    encoded = json.dumps(stable, ensure_ascii=False, sort_keys=True,
                         separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest()


def apply_config():
    payload = json.load(sys.stdin)
    incoming = payload.get('tables', {})
    columns = payload.get('columns', {})
    if any(not isinstance(incoming.get(t), list) or not isinstance(columns.get(t), list)
           for t in TABLES):
        raise RuntimeError('收到的配置数据格式无效')
    with open_db() as db:
        for table in TABLES:
            if set(table_columns(db, table)) != set(columns[table]):
                raise RuntimeError('主副机 %s 表结构不一致，请先统一 3xs/x-ui 版本' % table)
        db.execute('BEGIN IMMEDIATE')
        try:
            local = {t: rows(db, t) for t in TABLES}

            local_inbounds_by_id = {r['id']: r for r in local['inbounds'] if 'id' in r}
            old_inbounds = {r.get('port') or r.get('id'): r for r in local['inbounds']}

            old_clients = {}
            for r in local['client_traffics']:
                email = str(r.get('email') or '').strip()
                inbound_id = r.get('inbound_id')
                port = ''
                if inbound_id in local_inbounds_by_id:
                    port = str(local_inbounds_by_id[inbound_id].get('port') or '')
                if email and port:
                    old_clients[f"{port}_{email}"] = r
                if email:
                    old_clients[email] = r
                if 'id' in r:
                    old_clients[f"id_{r['id']}"] = r

            for table in ('client_traffics', 'inbounds'):
                db.execute('DELETE FROM "%s"' % table)

            incoming_inbounds_by_id = {r['id']: r for r in incoming.get('inbounds', []) if 'id' in r}

            for table in ('inbounds', 'client_traffics'):
                cols = table_columns(db, table)
                if not incoming[table]:
                    continue
                marks = ','.join('?' for _ in cols)
                names = ','.join('"%s"' % x for x in cols)
                for row in incoming[table]:
                    item = dict(row)
                    if table == 'inbounds':
                        previous = old_inbounds.get(item.get('port') or item.get('id'), {})
                    else:
                        email = str(item.get('email') or '').strip()
                        inbound_id = item.get('inbound_id')
                        port = ''
                        if inbound_id in incoming_inbounds_by_id:
                            port = str(incoming_inbounds_by_id[inbound_id].get('port') or '')
                        previous = (old_clients.get(f"{port}_{email}") or
                                    old_clients.get(email) or
                                    old_clients.get(f"id_{item.get('id')}") or {})

                    counters = INBOUND_COUNTERS if table == 'inbounds' else CLIENT_COUNTERS
                    for key in counters:
                        if key in item:
                            val = previous.get(key)
                            item[key] = int(val) if val is not None else 0

                    db.execute('INSERT INTO "%s" (%s) VALUES (%s)' % (table, names, marks),
                               [item.get(k) for k in cols])
            db.commit()
        except Exception:
            db.rollback()
            raise
    print('副机已应用入站/用户配置，副机已有流量累计值保留。')
    subprocess.run(['systemctl', 'restart', 'x-ui'], check=True)
    print('副机 x-ui 已重启，新线路配置已生效。')


def snapshot():
    payload = database_snapshot()
    print(json.dumps(payload, ensure_ascii=False, separators=(',', ':')))


def make_row_key(table, row, inbounds_by_id=None):
    if table == 'inbounds':
        port = row.get('port')
        if port:
            return f"port_{port}"
        tag = str(row.get('tag') or '').strip()
        if tag:
            return f"tag_{tag}"
        return f"id_{row.get('id')}"
    elif table == 'client_traffics':
        email = str(row.get('email') or '').strip()
        inbound_id = row.get('inbound_id')
        port = ''
        if inbounds_by_id and inbound_id in inbounds_by_id:
            port = str(inbounds_by_id[inbound_id].get('port') or '')
        if email:
            return f"email_{port}_{email}" if port else f"email_{email}"
        return f"id_{inbound_id}_{row.get('id')}"
    return str(row.get('id'))


def merge_traffic_counters(db, remote):
    ledger_path = STATE / 'ledger.json'
    try:
        ledger = json.loads(ledger_path.read_text())
    except FileNotFoundError:
        ledger = {}

    totals = {'up': 0, 'down': 0, 'all_time': 0}
    matched = 0
    table_info = {t: table_columns(db, t) for t in TABLES}

    master = {t: rows(db, t) for t in TABLES}
    inbounds_by_id = {r['id']: r for r in master['inbounds'] if 'id' in r}
    local_map = {t: {make_row_key(t, r, inbounds_by_id): r for r in master[t]} for t in TABLES}
    peer_inbounds_by_id = {r['id']: r for r in remote.get('inbounds', []) if 'id' in r}

    for table in TABLES:
        counters = INBOUND_COUNTERS if table == 'inbounds' else CLIENT_COUNTERS
        valid_keys = set()
        for peer_row in remote.get(table, []):
            key = make_row_key(table, peer_row, peer_inbounds_by_id)
            if not key or key not in local_map[table]:
                continue
            valid_keys.add(key)
            matched += 1

            table_ledger = ledger.setdefault(table, {})
            is_new_in_ledger = (key not in table_ledger)
            old = table_ledger.setdefault(key, {})

            local_row = local_map[table][key]
            changed = {}
            for field in counters:
                if field not in table_info[table] or field not in peer_row:
                    continue
                if field == 'last_online':
                    peer_lo = int(peer_row.get('last_online') or 0)
                    local_lo = int(local_row.get('last_online') or 0)
                    if peer_lo > local_lo:
                        changed['last_online'] = peer_lo
                        local_row['last_online'] = peer_lo
                    continue

                current = max(0, int(peer_row.get(field) or 0))

                # IF FIRST TIME ENCOUNTERED:
                # Set baseline to current replica traffic. Delta is ZERO!
                # Prevents replica's historical traffic from doubling/summing into master!
                if is_new_in_ledger or field not in old:
                    old[field] = current
                    continue

                previous = max(0, int(old.get(field, 0) or 0))

                # If traffic was reset in panel on replica
                if current < previous:
                    old[field] = current
                    continue

                delta = max(0, current - previous)
                if delta:
                    current_local = max(0, int(local_row.get(field) or 0))
                    new_value = current_local + delta
                    changed[field] = new_value
                    local_row[field] = new_value
                    if table == 'client_traffics' and field in totals:
                        totals[field] += delta
                old[field] = current

            if changed:
                assignments = ','.join('"%s"=?' % x for x in changed)
                db.execute('UPDATE "%s" SET %s WHERE "id"=?' % (table, assignments),
                           list(changed.values()) + [local_row['id']])

        if table in ledger:
            stale_keys = [k for k in ledger[table] if k not in valid_keys]
            for k in stale_keys:
                del ledger[table][k]

    # 自动校准入站线路流量（防止端口流量虚高膨胀）并解除被误禁用的客户端
    repair_database(db)

    atomic_write(ledger_path, (json.dumps(ledger, ensure_ascii=False, separators=(',', ':')) + '\n').encode())
    print('副机流量已合并：匹配记录 %d 条，上传 +%d 字节，下载 +%d 字节。' %
          (matched, totals['up'], totals['down']))


def repair_database(db):
    """
    1. 校准入站端口流量为其实际客户端流量之和（彻底解决端口流量膨胀至几TB的Bug）。
    2. 解除被误禁用的客户端状态（针对流量未超配额且未到期、但因先前流量翻倍被锁死的情况）。
    """
    now_ms = int(time.time() * 1000)
    inbounds = [dict(r) for r in db.execute('SELECT * FROM inbounds')]
    clients = [dict(r) for r in db.execute('SELECT * FROM client_traffics')]

    inbound_traffic_map = {}
    for c in clients:
        ib_id = c.get('inbound_id')
        if ib_id not in inbound_traffic_map:
            inbound_traffic_map[ib_id] = {'up': 0, 'down': 0, 'all_time': 0, 'count': 0}
        inbound_traffic_map[ib_id]['up'] += max(0, int(c.get('up') or 0))
        inbound_traffic_map[ib_id]['down'] += max(0, int(c.get('down') or 0))
        inbound_traffic_map[ib_id]['all_time'] += max(0, int(c.get('all_time') or 0))
        inbound_traffic_map[ib_id]['count'] += 1

    healed_inbounds = 0
    healed_clients = 0
    inbound_cols = table_columns(db, 'inbounds')

    # 1. 校准 inbounds 端口流量
    for ib in inbounds:
        ib_id = ib['id']
        port = ib.get('port')
        if ib_id in inbound_traffic_map and inbound_traffic_map[ib_id]['count'] > 0:
            calc_up = inbound_traffic_map[ib_id]['up']
            calc_down = inbound_traffic_map[ib_id]['down']
            calc_all = inbound_traffic_map[ib_id]['all_time']
            curr_up = max(0, int(ib.get('up') or 0))
            curr_down = max(0, int(ib.get('down') or 0))

            # 当入站端口统计流量大于客户端总和时，自动将其校准为客户端实际总和
            if (curr_up + curr_down) > (calc_up + calc_down):
                upd_fields = ['"up"=?', '"down"=?']
                upd_vals = [calc_up, calc_down]
                if 'all_time' in inbound_cols:
                    upd_fields.append('"all_time"=?')
                    upd_vals.append(calc_all or (calc_up + calc_down))
                db.execute('UPDATE inbounds SET %s WHERE id = ?' % ','.join(upd_fields),
                           upd_vals + [ib_id])
                healed_inbounds += 1
                print('[修复] 端口 %s 线路流量从 %.2f GB 校准为客户端实际总和 %.2f GB' %
                      (port, (curr_up + curr_down) / (1024**3), (calc_up + calc_down) / (1024**3)))

        # 检查入站线路是否因先前虚高超标而被误禁用
        total_limit = max(0, int(ib.get('total') or 0))
        exp_time = max(0, int(ib.get('expiry_time') or 0))
        calc_tot = inbound_traffic_map.get(ib_id, {}).get('up', 0) + inbound_traffic_map.get(ib_id, {}).get('down', 0)
        is_valid = (total_limit == 0 or calc_tot < total_limit) and (exp_time == 0 or exp_time > now_ms)
        if is_valid and not ib.get('enable'):
            db.execute('UPDATE inbounds SET enable = 1 WHERE id = ?', [ib_id])
            healed_inbounds += 1
            print('[修复] 端口 %s 线路已解除误禁用并重新启用' % port)

    # 2. 修复客户端误禁用状态
    for ib in inbounds:
        ib_id = ib['id']
        port = ib.get('port')
        settings = parse_settings(ib.get('settings'))
        c_list = settings.get('clients', [])
        settings_changed = False

        ib_clients = [c for c in clients if c.get('inbound_id') == ib_id]
        ib_clients_by_email = {str(c.get('email') or '').strip(): c for c in ib_clients}

        for c_dict in c_list:
            email = str(c_dict.get('email') or '').strip()
            if not email or email not in ib_clients_by_email:
                continue
            ct = ib_clients_by_email[email]
            c_up = max(0, int(ct.get('up') or 0))
            c_down = max(0, int(ct.get('down') or 0))
            c_tot_used = c_up + c_down
            c_limit = max(0, int(ct.get('total') or 0))
            c_exp = max(0, int(ct.get('expiry_time') or 0))

            is_under_quota = (c_limit == 0 or c_tot_used < c_limit)
            is_not_expired = (c_exp == 0 or c_exp > now_ms)

            # 仅当流量未超标、未过期，但 client_traffics.enable 却被置为 0 时进行自愈恢复
            if is_under_quota and is_not_expired:
                if not ct.get('enable'):
                    db.execute('UPDATE client_traffics SET enable = 1 WHERE id = ?', [ct['id']])
                    healed_clients += 1
                    print('[修复] 客户端 %s 流量未超标(%.2fG / %.2fG)且未到期，已解除误禁用(enable=1)' %
                          (email, c_tot_used / (1024**3), c_limit / (1024**3)))

                if not c_dict.get('enable', True):
                    c_dict['enable'] = True
                    settings_changed = True

        if settings_changed:
            db.execute('UPDATE inbounds SET settings = ? WHERE id = ?',
                       [json.dumps(settings, ensure_ascii=False), ib_id])

    return healed_inbounds, healed_clients


def repair_cmd():
    print('正在检查并修复 x-ui 数据库异常数据...')
    repaired_local = False
    with open_db() as db:
        db.execute('BEGIN IMMEDIATE')
        try:
            h_ib, h_ct = repair_database(db)
            if h_ib > 0 or h_ct > 0:
                db.commit()
                repaired_local = True
                print('已修复 %d 条端口线路流量及 %d 个被误禁用的客户端。' % (h_ib, h_ct))
            else:
                db.rollback()
                print('未发现异常数据，本地数据库状态正常。')
        except Exception:
            db.rollback()
            raise

    if repaired_local:
        subprocess.run(['systemctl', 'restart', 'x-ui'], check=False)
        print('本地 x-ui 已重启，修复已生效。')

    c = config()
    if c.get('role') == 'master' and c.get('peer'):
        print('正在将修复后的状态推送到副机并重启副机 x-ui...')
        try:
            push(force=True)
            print('副机已同步更新并修复完毕。')
        except Exception as e:
            print('副机同步失败：%s' % e, file=sys.stderr)


def merge_traffic():
    peer_status()
    c = config()
    if c.get('role') != 'master':
        raise RuntimeError('当前未设为主机')

    try:
        remote_raw = ssh(c['peer'], BIN + ' snapshot')
        remote = json.loads(remote_raw).get('tables', {})
    except Exception as e:
        raise RuntimeError('无法获取副机快照：%s' % e)

    # 1. Sync any config/client changes bidirectionally
    sync_and_push(force=False, remote_tables=remote)

    # 2. Merge traffic deltas with baseline protection
    with open_db() as db:
        db.execute('BEGIN IMMEDIATE')
        try:
            merge_traffic_counters(db, remote)
            db.commit()
        except Exception:
            db.rollback()
            raise


def install_units():
    path_content = '''[Unit]\nDescription=Watch x-ui SQLite database for xui2vps changes\n\n[Path]\nPathChanged=/etc/x-ui/x-ui.db\nPathModified=/etc/x-ui/x-ui.db\nPathChanged=/etc/x-ui/x-ui.db-wal\nPathModified=/etc/x-ui/x-ui.db-wal\nUnit=xui2vps-watch.service\n\n[Install]\nWantedBy=multi-user.target\n'''
    service = '''[Unit]\nDescription=Synchronize x-ui configuration to xui2vps replica\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/xui2vps push-if-changed\n'''
    timer = '''[Unit]\nDescription=Merge xui2vps replica traffic every 64 minutes\n\n[Timer]\nOnBootSec=64min\nOnUnitActiveSec=64min\nAccuracySec=1s\nUnit=xui2vps-traffic.service\n\n[Install]\nWantedBy=timers.target\n'''
    sync_timer = '''[Unit]\nDescription=Retry xui2vps configuration sync\n\n[Timer]\nOnBootSec=10s\nOnUnitActiveSec=15s\nUnit=xui2vps-watch.service\n\n[Install]\nWantedBy=timers.target\n'''
    night = '''[Unit]\nDescription=Merge xui2vps replica traffic\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/xui2vps merge-traffic\n'''
    for path, content in ((PATH_UNIT, path_content), (SERVICE_UNIT, service),
                          (TIMER_UNIT, timer), (NIGHT_UNIT, night),
                          (SYNC_TIMER_UNIT, sync_timer)):
        Path(path).write_text(content)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', 'xui2vps-watch.path',
                    'xui2vps-traffic.timer', 'xui2vps-sync.timer'], check=True)


def setup(role):
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    if role == 'replica':
        # Validate database and both required tables before recording the role.
        database_snapshot()
        disable_units()
        save_config({'role': role})
        print('副机已设置。请在主机选择“设为主机”并填写本机 SSH 地址。')
        return
    database_snapshot()
    host = input('副机 IP: ').strip()
    if not re.fullmatch(r'[A-Za-z0-9.-]+', host) or host.startswith('-') or '..' in host:
        raise RuntimeError('IP/主机名格式无效')
    peer = 'root@' + host
    port = connect_peer(peer)
    data = {'role': 'master', 'peer': peer}
    if port:
        data['peer_port'] = port
    save_config(data)
    install_units()
    for p in (STATE / 'last_sync.json', STATE / 'config.sha256', STATE / 'ledger.json'):
        p.unlink(missing_ok=True)
    push(force=True)
    try:
        ssh(peer, BIN + ' register-master-ip')
    except (OSError, subprocess.CalledProcessError):
        print('无法获取副机看到的主机 IP。', file=sys.stderr)


def unbind():
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行')
    c = config()
    if c.get('role') == 'master' and c.get('peer'):
        try:
            ssh(c['peer'], BIN + ' unbind-peer')
        except (OSError, subprocess.CalledProcessError):
            print('无法联系副机；主机本地绑定仍会取消。', file=sys.stderr)
    apply_peer_unbind()
    print('绑定已取消；x-ui 数据库未删除。')


def status_report():
    c = config()
    if not c.get('role'):
        return
    print('XUI：' + ('主机' if c['role'] == 'master' else '副机'))
    if c['role'] == 'master' and c.get('peer'):
        try:
            host_ip = ssh(c['peer'], BIN + ' register-master-ip').decode().strip()
        except (OSError, subprocess.CalledProcessError):
            host_ip = ''
        if host_ip:
            print('  主机 IP：' + host_ip)
    elif c.get('master_ip'):
        print('  主机 IP：' + c['master_ip'])
    peer = c.get('peer', '')
    if peer.startswith('root@'):
        peer = peer[5:]
    if peer:
        print('  同步 IP：' + peer)
    try:
        raw = Path(TIMER_UNIT).read_text()
        match = re.search(r'^OnUnitActiveSec=(.+)$', raw, re.M)
        if match:
            value = match.group(1)
            duration = re.fullmatch(r'(\d+)(s|min|h)', value)
            if duration:
                seconds = int(duration.group(1)) * {'s': 1, 'min': 60, 'h': 3600}[duration.group(2)]
                print('  流量同步间隔：%s（约 %.2f 小时）' % (value, seconds / 3600))
    except OSError:
        pass


def register_master_ip():
    c = config()
    if c.get('role') != 'replica':
        return
    fields = os.environ.get('SSH_CONNECTION', '').split()
    if len(fields) >= 4:
        try:
            c['master_ip'] = str(ipaddress.ip_address(fields[0]))
        except ValueError:
            return
        save_config(c)
        print(c['master_ip'])


def set_interval():
    path = Path(TIMER_UNIT)
    if not path.is_file():
        print('XUI 尚未配置主机流量同步定时器。')
        return
    value = input('请输入 XUI 流量同步间隔（小时，支持小数）: ').strip()
    try:
        hours = float(value)
        if not 0.01 <= hours <= 8760:
            raise ValueError
    except ValueError:
        print('请输入 0.01 到 8760 之间的小时数。')
        return
    seconds = int(hours * 3600)
    interval = (str(seconds // 3600) + 'h' if seconds % 3600 == 0 else
                str(seconds // 60) + 'min' if seconds % 60 == 0 else str(seconds) + 's')
    raw = path.read_text()
    raw, count = re.subn(r'(?m)^OnBootSec=.*$', 'OnBootSec=' + interval, raw, count=1)
    if not count:
        raise RuntimeError('XUI 定时器缺少 OnBootSec')
    raw, count = re.subn(r'(?m)^OnUnitActiveSec=.*$', 'OnUnitActiveSec=' + interval, raw, count=1)
    if not count:
        raise RuntimeError('XUI 定时器缺少 OnUnitActiveSec')
    path.write_text(raw)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'restart', 'xui2vps-traffic.timer'], check=True)
    print('XUI 流量同步间隔已改为 ' + interval)


def menu():
    print('\nXUI2VPS 多 VPS 绑定系统')
    print('1、设为主机')
    print('2、设为副机')
    print('3、取消绑定系统')
    print('4、一键同步副机流量到主机')
    print('5、一键修复异常数据（校准端口流量、解除误禁用客户端）')
    print('0、退出')
    choice = input('请选择: ').strip()
    if choice == '1': setup('master')
    elif choice == '2': setup('replica')
    elif choice == '3': unbind()
    elif choice == '4': merge_traffic()
    elif choice == '5': repair_cmd()
    elif choice == '0': return
    else: print('无效选项')


def main():
    try:
        cmd = sys.argv[1] if len(sys.argv) > 1 else 'menu'
        if cmd == 'menu': menu()
        elif cmd == 'push': push(force=True)
        elif cmd == 'push-if-changed': push()
        elif cmd == 'apply-config': apply_config()
        elif cmd == 'snapshot': snapshot()
        elif cmd == 'merge-traffic': merge_traffic()
        elif cmd == 'repair': repair_cmd()
        elif cmd == 'status': print(config().get('role', 'unbound'))
        elif cmd == 'status-report': status_report()
        elif cmd == 'set-interval': set_interval()
        elif cmd == 'register-master-ip': register_master_ip()
        elif cmd == 'unbind-peer': apply_peer_unbind()
        else: raise RuntimeError('用法: xui2vps [menu|push|apply-config|snapshot|merge-traffic|repair]')
    except (OSError, ValueError, KeyError, sqlite3.Error,
            subprocess.CalledProcessError, RuntimeError) as e:
        print('错误: ' + str(e), file=sys.stderr)
        if isinstance(e, subprocess.CalledProcessError) and e.stderr:
            print(e.stderr.decode(errors='replace').strip(), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
__SX_XUI2VPS_PYTHON__
install -m 0755 "$tmp" /usr/local/bin/xui2vps
rm -f "$tmp"
trap - EXIT HUP INT TERM

printf '\n当前同步状态：\n'
/usr/local/bin/ssr2vps status-report
/usr/local/bin/xui2vps status-report
printf '\n主菜单 v1.0.5：\n1、SSR 同步\n2、XUI 同步\n3、同步时间修改\n0、退出\n请选择: '
IFS= read -r choice || choice=
case "$choice" in
    1) exec /usr/local/bin/ssr2vps menu ;;
    2) exec /usr/local/bin/xui2vps menu ;;
    3)
        printf '\n同步时间修改：\n1、修改 SSR\n2、修改 XUI\n0、返回\n请选择: '
        IFS= read -r timer_choice || timer_choice=
        case "$timer_choice" in
            1) exec /usr/local/bin/ssr2vps set-interval ;;
            2) exec /usr/local/bin/xui2vps set-interval ;;
            0) exit 0 ;;
            *) echo '无效选项'; exit 1 ;;
        esac ;;
    0) exit 0 ;;
    *) echo '无效选项'; exit 1 ;;
esac
