#!/usr/bin/env bash
set -euo pipefail

# Quick incident helper for hosts abused for Telnet/IoT style scanning.
# Usage:
#   bash net-scan-cleanup.sh audit
#   bash net-scan-cleanup.sh clean
#   bash net-scan-cleanup.sh watch
#
# Override ports:
#   SCAN_PORTS="23 2323 2333 5555 7547" bash net-scan-cleanup.sh clean

SCAN_PORTS="${SCAN_PORTS:-23 2323 2333}"
BLOCK_SSH_ABUSE="${BLOCK_SSH_ABUSE:-1}"
SCAN_KILL_PROCS="${SCAN_KILL_PROCS:-1}"
PERSIST="${PERSIST:-1}"
TOP_N="${TOP_N:-30}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

port_regex() {
  local out="" p
  for p in $SCAN_PORTS; do
    if [ -z "$out" ]; then out="$p"; else out="$out|$p"; fi
  done
  printf '%s' "$out"
}

show_header() {
  echo
  echo "==== $* ===="
}

conntrack_scan_lines() {
  local re
  re="$(port_regex)"
  if have conntrack; then
    conntrack -L 2>/dev/null | egrep "dport=($re)( |$)" || true
  else
    echo "conntrack command not found" >&2
  fi
}

audit_scan_ports() {
  show_header "conntrack entries to watched ports: $SCAN_PORTS"
  conntrack_scan_lines | tee /tmp/net-scan-cleanup.conntrack.$$ | head -n 200 || true
  echo
  echo "count: $(wc -l </tmp/net-scan-cleanup.conntrack.$$ 2>/dev/null || echo 0)"
  rm -f /tmp/net-scan-cleanup.conntrack.$$
}

audit_fanout() {
  show_header "top remote destination ports in conntrack"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dport=\([0-9][0-9]*\) .*/\1/p' \
      | sort | uniq -c | sort -nr | head -n "$TOP_N" || true
  fi

  show_header "top remote destination IPs in conntrack"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dst=\([0-9.][0-9.]*\) sport=.* dport=.*/\1/p' \
      | sort | uniq -c | sort -nr | head -n "$TOP_N" || true
  fi

  show_header "many different IPs on same dport: possible scanning"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dst=\([0-9.][0-9.]*\) sport=.* dport=\([0-9][0-9]*\) .*/\2 \1/p' \
      | sort -u \
      | awk '{c[$1]++} END {for (p in c) print c[p], p}' \
      | sort -nr | head -n "$TOP_N" || true
  fi
}

audit_processes() {
  show_header "processes by cpu"
  ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,lstart,cmd --sort=-%cpu | head -n 40 || true

  show_header "listening sockets"
  ss -tunlp 2>/dev/null | head -n 250 || true

  show_header "established sockets by process"
  ss -tanp 2>/dev/null \
    | grep ESTAB \
    | grep -o 'pid=[0-9]*' \
    | sort | uniq -c | sort -nr | head -n "$TOP_N" || true

  show_header "processes connected to watched scan ports: $SCAN_PORTS"
  scan_socket_lines | head -n 200 || true
}

audit_ssh() {
  show_header "current logins"
  who -u || true

  show_header "recent root logins"
  last -ai root | head -n 30 || true

  show_header "sshd effective risk settings"
  sshd -T 2>/dev/null | egrep '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries)' || true

  show_header "recent ssh failures by source"
  if have journalctl; then
    journalctl -u ssh -u sshd --since "24 hours ago" --no-pager 2>/dev/null \
      | awk '/Failed password|Invalid user/ {
          for (i=1;i<=NF;i++) if ($i=="from") print $(i+1)
        }' \
      | sort | uniq -c | sort -nr | head -n "$TOP_N" || true
  fi
}

add_drop_rule() {
  local chain="$1" proto="$2" port="$3"
  iptables -C "$chain" -p "$proto" --dport "$port" -j REJECT 2>/dev/null \
    || iptables -I "$chain" 1 -p "$proto" --dport "$port" -j REJECT
}

block_scan_ports() {
  show_header "block outbound/forwarded scan ports"
  local chain proto port
  for chain in OUTPUT FORWARD; do
    for proto in tcp udp; do
      for port in $SCAN_PORTS; do
        add_drop_rule "$chain" "$proto" "$port"
      done
    done
  done
  iptables -S OUTPUT | egrep "dport ($(port_regex))" || true
  iptables -S FORWARD | egrep "dport ($(port_regex))" || true
}

conntrack_scan_tuples() {
  local re
  re="$(port_regex)"
  conntrack_scan_lines \
    | awk -v re="^($re)$" '
        {
          src = dst = sport = dport = ""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^src=/ && src == "") src = substr($i, 5)
            else if ($i ~ /^dst=/ && dst == "") dst = substr($i, 5)
            else if ($i ~ /^sport=/ && sport == "") sport = substr($i, 7)
            else if ($i ~ /^dport=/ && dport == "") dport = substr($i, 7)
          }
          if (src != "" && dst != "" && sport != "" && dport ~ re) {
            print src, dst, sport, dport
          }
        }'
}

delete_conntrack_scan_ports() {
  show_header "delete existing conntrack state for scan ports"
  local proto port before after src dst sport dport tuple_tmp
  before="$(conntrack_scan_lines | wc -l || true)"
  echo "before: $before"
  if have conntrack; then
    tuple_tmp="/tmp/net-scan-cleanup.conntrack-tuples.$$"
    conntrack_scan_tuples | sort -u >"$tuple_tmp" || true
    while read -r src dst sport dport; do
      [ -n "${src:-}" ] || continue
      conntrack -D -p tcp --orig-src "$src" --orig-dst "$dst" \
        --sport "$sport" --dport "$dport" 2>/dev/null || true
    done <"$tuple_tmp"
    rm -f "$tuple_tmp"

    for proto in tcp udp; do
      for port in $SCAN_PORTS; do
        conntrack -D -p "$proto" --dport "$port" 2>/dev/null || true
        conntrack -D -p "$proto" --sport "$port" 2>/dev/null || true
      done
    done
  fi
  after="$(conntrack_scan_lines | wc -l || true)"
  echo "after: $after"
}

scan_socket_lines() {
  local re
  re="$(port_regex)"
  if have ss; then
    ss -H -tanp 2>/dev/null \
      | awk -v re=":($re)$" '$1 ~ /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|CLOSE-WAIT|LAST-ACK)$/ && $5 ~ re {print}' || true
  fi
}

kill_scan_processes() {
  [ "$SCAN_KILL_PROCS" = "1" ] || return 0
  have ss || return 0

  show_header "terminate processes still connected to scan ports"
  local tmp pid
  tmp="/tmp/net-scan-cleanup.scan-pids.$$"
  scan_socket_lines | tee /tmp/net-scan-cleanup.scan-sockets.$$ \
    | grep -o 'pid=[0-9]*' \
    | cut -d= -f2 \
    | sort -u >"$tmp" || true

  if [ ! -s "$tmp" ]; then
    echo "no process-owned outbound scan sockets found"
    rm -f "$tmp" /tmp/net-scan-cleanup.scan-sockets.$$
    return 0
  fi

  while read -r pid; do
    [ -n "${pid:-}" ] || continue
    case "$pid" in
      1|$$) continue ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
      ps -p "$pid" -o pid,ppid,user,stat,%cpu,%mem,rss,etime,lstart,cmd --no-headers || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done <"$tmp"

  sleep 2
  while read -r pid; do
    [ -n "${pid:-}" ] || continue
    case "$pid" in
      1|$$) continue ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
      echo "force killing pid=$pid"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done <"$tmp"

  rm -f "$tmp" /tmp/net-scan-cleanup.scan-sockets.$$
}

block_recent_ssh_abusers() {
  [ "$BLOCK_SSH_ABUSE" = "1" ] || return 0
  have journalctl || return 0

  show_header "block top recent ssh brute-force sources"
  local tmp ip count
  tmp="/tmp/net-scan-cleanup.ssh-abuse.$$"
  journalctl -u ssh -u sshd --since "24 hours ago" --no-pager 2>/dev/null \
    | awk '/Failed password|Invalid user/ {
        for (i=1;i<=NF;i++) if ($i=="from") print $(i+1)
      }' \
    | sort | uniq -c | sort -nr | awk '$1 >= 5 {print $1, $2}' | head -n 50 >"$tmp" || true

  while read -r count ip; do
    [ -n "${ip:-}" ] || continue
    case "$ip" in
      127.*|10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.2[0-9].*|172.3[0-1].*) continue ;;
    esac
    iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$ip" -j DROP
    echo "blocked $ip failures=$count"
  done <"$tmp"
  rm -f "$tmp"
}

persist_iptables() {
  [ "$PERSIST" = "1" ] || return 0

  show_header "persist iptables"
  local backup
  if [ -f /etc/iptables.up.rules ]; then
    backup="/etc/iptables.up.rules.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/iptables.up.rules "$backup"
    iptables-save -f /etc/iptables.up.rules
    echo "saved /etc/iptables.up.rules backup=$backup"
  elif [ -d /etc/iptables ]; then
    mkdir -p /etc/iptables
    backup="/etc/iptables/rules.v4.bak.$(date +%Y%m%d%H%M%S)"
    [ -f /etc/iptables/rules.v4 ] && cp /etc/iptables/rules.v4 "$backup" || true
    iptables-save -f /etc/iptables/rules.v4
    echo "saved /etc/iptables/rules.v4 backup=${backup:-none}"
  else
    echo "no known iptables persistence file found; runtime rules are active only"
    echo "install iptables-persistent or save iptables-save output using your distro method"
  fi
}

audit_all() {
  audit_scan_ports
  audit_fanout
  audit_processes
  audit_ssh
}

clean_all() {
  audit_scan_ports
  block_scan_ports
  kill_scan_processes
  delete_conntrack_scan_ports
  block_recent_ssh_abusers
  persist_iptables
  audit_scan_ports
}

watch_scan() {
  while true; do
    clear || true
    date
    audit_scan_ports
    audit_fanout
    sleep 10
  done
}

main() {
  need_root
  case "${1:-audit}" in
    audit) audit_all ;;
    clean) clean_all ;;
    watch) watch_scan ;;
    ports) echo "$SCAN_PORTS" ;;
    *)
      echo "Usage: $0 {audit|clean|watch|ports}" >&2
      echo "Example: SCAN_PORTS='23 2323 2333 5555 7547' $0 clean" >&2
      exit 2
      ;;
  esac
}

main "$@"
