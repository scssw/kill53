#!/usr/bin/env bash
set -euo pipefail

# 用于处理主机被滥用进行 Telnet/IoT 扫描的应急脚本。
# 用法：
#   bash net-scan-cleanup.sh audit
#   bash net-scan-cleanup.sh clean
#   bash net-scan-cleanup.sh watch
#   bash net-scan-cleanup.sh restore-ssh
#
# 覆盖默认监控端口：
#   SCAN_PORTS="445 3389 3306 8080 23 223 5900 1433 2323 2333" bash net-scan-cleanup.sh clean

SCAN_PORTS="${SCAN_PORTS:-445 3389 3306 8080 23 223 5900 1433 2323 2333}"
SSH_PORT="${SSH_PORT:-22}"
BLOCK_SSH_ABUSE="${BLOCK_SSH_ABUSE:-0}"
SCAN_KILL_PROCS="${SCAN_KILL_PROCS:-1}"
PERSIST="${PERSIST:-1}"
TOP_N="${TOP_N:-30}"
SCAN_CHAIN="${SCAN_CHAIN:-NET_SCAN_CLEANUP}"
SSH_WHITELIST_CHAIN="${SSH_WHITELIST_CHAIN:-SSH22_WHITELIST}"
SSH_WHITELIST_APPLY="${SSH_WHITELIST_APPLY:-/usr/local/sbin/ssh22-whitelist-apply}"
APPLY_SCRIPT="${APPLY_SCRIPT:-/usr/local/sbin/net-scan-cleanup-apply}"
RESTORE_HOOK="${RESTORE_HOOK:-/etc/network/if-pre-up.d/net-scan-cleanup}"
SSR_SERVER_SCRIPT="${SSR_SERVER_SCRIPT:-/usr/local/SSR-Bash-Python/server.sh}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行" >&2
    exit 1
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

iptables_bins() {
  local name path seen=""
  for name in iptables iptables-legacy iptables-nft; do
    path="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$path" ] || continue
    case " $seen " in
      *" $path "*) continue ;;
    esac
    seen="$seen $path"
    printf '%s\n' "$path"
  done
}

ensure_conntrack() {
  if have conntrack; then
    return 0
  fi

  echo "未找到 conntrack，开始自动安装：apt install conntrack -y"
  if have apt-get; then
    apt-get update || echo "警告：apt-get update 失败，将继续尝试直接安装 conntrack"
    apt-get install -y conntrack
  elif have apt; then
    apt update || echo "警告：apt update 失败，将继续尝试直接安装 conntrack"
    apt install -y conntrack
  else
    echo "错误：未找到 conntrack，也未找到 apt/apt-get，无法自动安装" >&2
    exit 1
  fi

  if ! have conntrack; then
    echo "错误：conntrack 安装后仍不可用，请手动检查软件源或系统包管理器" >&2
    exit 1
  fi
}

port_regex() {
  local out="" p
  for p in $(effective_scan_ports); do
    if [ -z "$out" ]; then out="$p"; else out="$out|$p"; fi
  done
  printf '%s' "$out"
}

effective_scan_ports() {
  local p
  for p in $SCAN_PORTS; do
    [ "$p" = "$SSH_PORT" ] && continue
    printf '%s\n' "$p"
  done
}

show_header() {
  echo
  echo "==== $* ===="
}

conntrack_scan_lines() {
  local re
  re="$(port_regex)"
  [ -n "$re" ] || return 0
  if have conntrack; then
    conntrack -L 2>/dev/null | egrep "dport=($re)( |$)" || true
  else
    echo "未找到 conntrack 命令" >&2
  fi
}

audit_scan_ports() {
  show_header "conntrack 中连接到监控端口的记录：$SCAN_PORTS"
  conntrack_scan_lines | tee /tmp/net-scan-cleanup.conntrack.$$ | head -n 200 || true
  echo
  echo "数量：$(wc -l </tmp/net-scan-cleanup.conntrack.$$ 2>/dev/null || echo 0)"
  rm -f /tmp/net-scan-cleanup.conntrack.$$
}

audit_fanout() {
  show_header "conntrack 中最多的远程目标端口"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dport=\([0-9][0-9]*\) .*/\1/p' \
      | sort | uniq -c | sort -nr | head -n "$TOP_N" || true
  fi

  show_header "conntrack 中最多的远程目标 IP"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dst=\([0-9.][0-9.]*\) sport=.* dport=.*/\1/p' \
      | sort | uniq -c | sort -nr | head -n "$TOP_N" || true
  fi

  show_header "同一目标端口连接大量不同 IP：疑似扫描"
  if have conntrack; then
    conntrack -L 2>/dev/null \
      | sed -n 's/.* dst=\([0-9.][0-9.]*\) sport=.* dport=\([0-9][0-9]*\) .*/\2 \1/p' \
      | sort -u \
      | awk '{c[$1]++} END {for (p in c) print c[p], p}' \
      | sort -nr | head -n "$TOP_N" || true
  fi
}

audit_processes() {
  show_header "按 CPU 排序的进程"
  ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,lstart,cmd --sort=-%cpu | head -n 40 || true

  show_header "监听中的端口"
  ss -tunlp 2>/dev/null | head -n 250 || true

  show_header "已建立连接按进程统计"
  ss -tanp 2>/dev/null \
    | grep ESTAB \
    | grep -o 'pid=[0-9]*' \
    | sort | uniq -c | sort -nr | head -n "$TOP_N" || true

  show_header "正在连接监控扫描端口的进程：$SCAN_PORTS"
  scan_socket_lines | head -n 200 || true
}

audit_ssh() {
  show_header "当前登录会话"
  who -u || true

  show_header "最近 root 登录记录"
  last -ai root | head -n 30 || true

  show_header "sshd 当前生效的风险配置"
  sshd -T 2>/dev/null | egrep '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries)' || true

  show_header "最近 SSH 登录失败来源"
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
  iptables -C "$SCAN_CHAIN" -p "$proto" --dport "$port" -j DROP 2>/dev/null \
    || iptables -A "$SCAN_CHAIN" -p "$proto" --dport "$port" -j DROP
  iptables -C "$chain" -j "$SCAN_CHAIN" 2>/dev/null \
    || iptables -I "$chain" 1 -j "$SCAN_CHAIN"
}

delete_direct_port_rules() {
  local bin="$1" chain="$2" proto="$3" port="$4" target="$5"
  while "$bin" -C "$chain" -p "$proto" --dport "$port" -j "$target" 2>/dev/null; do
    "$bin" -D "$chain" -p "$proto" --dport "$port" -j "$target"
  done
}

cleanup_old_direct_scan_port_rules() {
  local bin chain proto port target
  for bin in $(iptables_bins); do
    for chain in OUTPUT FORWARD; do
      for proto in tcp udp; do
        for port in $(effective_scan_ports); do
          for target in REJECT DROP; do
            delete_direct_port_rules "$bin" "$chain" "$proto" "$port" "$target"
          done
        done
      done
    done
  done
}

ensure_scan_chain() {
  if ! iptables -nL "$SCAN_CHAIN" >/dev/null 2>&1; then
    iptables -N "$SCAN_CHAIN"
  fi

  iptables -F "$SCAN_CHAIN"
}

block_scan_ports() {
  show_header "阻断出站/转发扫描端口"
  local chain proto port
  cleanup_old_direct_scan_port_rules
  ensure_scan_chain
  for chain in OUTPUT FORWARD; do
    for proto in tcp udp; do
      for port in $(effective_scan_ports); do
        add_drop_rule "$chain" "$proto" "$port"
      done
    done
  done
  if [ -n "$(port_regex)" ]; then
    iptables -S "$SCAN_CHAIN" | egrep "dport ($(port_regex))" || true
    iptables -S OUTPUT | grep -- "-j $SCAN_CHAIN" || true
    iptables -S FORWARD | grep -- "-j $SCAN_CHAIN" || true
  fi
}

delete_rule_if_exists() {
  local bin="$1" chain="$2" proto="$3" direction="$4" port="$5" target="$6"
  while "$bin" -C "$chain" -p "$proto" "$direction" "$port" -j "$target" 2>/dev/null; do
    "$bin" -D "$chain" -p "$proto" "$direction" "$port" -j "$target"
  done
}

ensure_ssh_whitelist_jump() {
  local bin
  if [ -x "$SSH_WHITELIST_APPLY" ]; then
    "$SSH_WHITELIST_APPLY" || true
    return 0
  fi

  for bin in $(iptables_bins); do
    "$bin" -nL "$SSH_WHITELIST_CHAIN" >/dev/null 2>&1 || continue
    while "$bin" -C INPUT -p tcp --dport "$SSH_PORT" -j "$SSH_WHITELIST_CHAIN" >/dev/null 2>&1; do
      "$bin" -D INPUT -p tcp --dport "$SSH_PORT" -j "$SSH_WHITELIST_CHAIN"
    done
    "$bin" -I INPUT 1 -p tcp --dport "$SSH_PORT" -j "$SSH_WHITELIST_CHAIN"
    echo "已恢复 INPUT tcp/$SSH_PORT -> $SSH_WHITELIST_CHAIN 白名单跳转。"
    return 0
  done
}

restore_ssh_22_access() {
  show_header "检查并恢复 SSH 22 端口访问"
  local bin chain proto direction target changed=0

  for bin in $(iptables_bins); do
    for chain in INPUT OUTPUT FORWARD; do
      for proto in tcp udp; do
        for direction in --dport --sport; do
          for target in REJECT DROP; do
            if "$bin" -C "$chain" -p "$proto" "$direction" "$SSH_PORT" -j "$target" 2>/dev/null; then
              changed=1
              delete_rule_if_exists "$bin" "$chain" "$proto" "$direction" "$SSH_PORT" "$target"
            fi
          done
        done
      done
    done

  done

  for bin in $(iptables_bins); do
    for chain in INPUT OUTPUT FORWARD; do
      while read -r rule; do
        case "$rule" in
          *"--dport $SSH_PORT"*"-j DROP"*|*"--dport $SSH_PORT"*"-j REJECT"*)
            echo "警告：$bin $chain 仍有 22 限制规则，请手动检查：$rule"
            ;;
        esac
      done <<EOF
$("$bin" -S "$chain" 2>/dev/null || true)
EOF
    done
  done

  ensure_ssh_whitelist_jump

  if [ "$changed" = "1" ]; then
    echo "已移除 22 端口相关 DROP/REJECT 规则，并恢复 SSH22_WHITELIST 白名单跳转。"
  else
    echo "未发现 22 端口被本机 iptables 直接 DROP/REJECT。"
  fi
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
  show_header "删除扫描端口已有 conntrack 状态"
  local proto port before after src dst sport dport tuple_tmp
  before="$(conntrack_scan_lines | wc -l || true)"
  echo "清理前：$before"
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
      for port in $(effective_scan_ports); do
        conntrack -D -p "$proto" --dport "$port" 2>/dev/null || true
        conntrack -D -p "$proto" --sport "$port" 2>/dev/null || true
      done
    done
  fi
  after="$(conntrack_scan_lines | wc -l || true)"
  echo "清理后：$after"
}

scan_socket_lines() {
  local re
  re="$(port_regex)"
  [ -n "$re" ] || return 0
  if have ss; then
    ss -H -tanp 2>/dev/null \
      | awk -v re=":($re)$" '$1 ~ /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|CLOSE-WAIT|LAST-ACK)$/ && $5 ~ re {print}' || true
  fi
}

kill_scan_processes() {
  [ "$SCAN_KILL_PROCS" = "1" ] || return 0
  have ss || return 0

  show_header "终止仍在连接扫描端口的进程"
  local tmp pid
  tmp="/tmp/net-scan-cleanup.scan-pids.$$"
  scan_socket_lines | tee /tmp/net-scan-cleanup.scan-sockets.$$ \
    | grep -o 'pid=[0-9]*' \
    | cut -d= -f2 \
    | sort -u >"$tmp" || true

  if [ ! -s "$tmp" ]; then
    echo "未发现由进程持有的出站扫描连接"
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
      echo "强制终止 pid=$pid"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done <"$tmp"

  rm -f "$tmp" /tmp/net-scan-cleanup.scan-sockets.$$
}

block_recent_ssh_abusers() {
  [ "$BLOCK_SSH_ABUSE" = "1" ] || return 0
  have journalctl || return 0

  show_header "跳过 SSH 来源 IP 自动阻断"
  echo "BLOCK_SSH_ABUSE 默认关闭，避免添加 INPUT -s x.x.x.x -j DROP 这类单 IP 阻断规则。"
  return 0
}

clear_old_input_ip_blocks() {
  show_header "清理历史 INPUT 单 IP 阻断规则"
  local bin source changed=0
  for bin in $(iptables_bins); do
    while read -r source; do
      [ -n "${source:-}" ] || continue
      while "$bin" -C INPUT -s "$source" -j DROP 2>/dev/null; do
        "$bin" -D INPUT -s "$source" -j DROP
        changed=1
        echo "已删除：$bin -D INPUT -s $source -j DROP"
      done
    done <<EOF
$("$bin" -S INPUT 2>/dev/null | awk '
  $1 == "-A" && $2 == "INPUT" {
    source = ""
    target = ""
    other = 0
    for (i = 3; i <= NF; i++) {
      if ($i == "-s" && (i + 1) <= NF) {
        source = $(i + 1)
        i++
      } else if ($i == "-j" && (i + 1) <= NF) {
        target = $(i + 1)
        i++
      } else {
        other = 1
      }
    }
    if (source != "" && target == "DROP" && other == 0) {
      print source
    }
  }
')
EOF
  done

  if [ "$changed" = "0" ]; then
    echo "未发现历史 INPUT 单 IP DROP 规则。"
  fi
}

install_scan_restore_files() {
  [ "$PERSIST" = "1" ] || return 0

  show_header "安装扫描端口常驻恢复钩子"
  mkdir -p "$(dirname "$APPLY_SCRIPT")" "$(dirname "$RESTORE_HOOK")"

  cat >"$APPLY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCAN_PORTS="$SCAN_PORTS"
SSH_PORT="$SSH_PORT"
SCAN_CHAIN="$SCAN_CHAIN"
SSH_WHITELIST_APPLY="$SSH_WHITELIST_APPLY"
IPTABLES_BIN="\${IPTABLES_BIN:-$(command -v iptables 2>/dev/null || echo iptables)}"

effective_scan_ports() {
  local p
  for p in \$SCAN_PORTS; do
    [ "\$p" = "\$SSH_PORT" ] && continue
    printf '%s\n' "\$p"
  done
}

delete_direct_port_rules() {
  local chain="\$1" proto="\$2" port="\$3" target="\$4"
  while "\$IPTABLES_BIN" -C "\$chain" -p "\$proto" --dport "\$port" -j "\$target" 2>/dev/null; do
    "\$IPTABLES_BIN" -D "\$chain" -p "\$proto" --dport "\$port" -j "\$target"
  done
}

if ! "\$IPTABLES_BIN" -nL "\$SCAN_CHAIN" >/dev/null 2>&1; then
  "\$IPTABLES_BIN" -N "\$SCAN_CHAIN"
fi

"\$IPTABLES_BIN" -F "\$SCAN_CHAIN"

for proto in tcp udp; do
  for port in \$(effective_scan_ports); do
    "\$IPTABLES_BIN" -A "\$SCAN_CHAIN" -p "\$proto" --dport "\$port" -j DROP
  done
done

for chain in OUTPUT FORWARD; do
  for proto in tcp udp; do
    for port in \$(effective_scan_ports); do
      delete_direct_port_rules "\$chain" "\$proto" "\$port" REJECT
      delete_direct_port_rules "\$chain" "\$proto" "\$port" DROP
    done
  done

  while "\$IPTABLES_BIN" -C "\$chain" -j "\$SCAN_CHAIN" >/dev/null 2>&1; do
    "\$IPTABLES_BIN" -D "\$chain" -j "\$SCAN_CHAIN"
  done
  "\$IPTABLES_BIN" -I "\$chain" 1 -j "\$SCAN_CHAIN"
done

[ -x "\$SSH_WHITELIST_APPLY" ] && "\$SSH_WHITELIST_APPLY" || true
EOF
  chmod +x "$APPLY_SCRIPT"

  cat >"$RESTORE_HOOK" <<EOF
#!/bin/sh
[ -x "$APPLY_SCRIPT" ] && "$APPLY_SCRIPT"
exit 0
EOF
  chmod +x "$RESTORE_HOOK"

  install_ssr_restore_hook
  echo "已安装：$APPLY_SCRIPT"
  echo "已安装：$RESTORE_HOOK"
}

install_ssr_restore_hook() {
  [ -f "$SSR_SERVER_SCRIPT" ] || return 0
  [ -w "$SSR_SERVER_SCRIPT" ] || return 0

  cp -a "$SSR_SERVER_SCRIPT" "${SSR_SERVER_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
  local tmp_file scan_hook ssh_hook
  tmp_file="$(mktemp)"
  scan_hook="[ -x \"$APPLY_SCRIPT\" ] && \"$APPLY_SCRIPT\""
  ssh_hook="[ -x \"$SSH_WHITELIST_APPLY\" ] && \"$SSH_WHITELIST_APPLY\""
  awk -v scan_hook="$scan_hook" -v ssh_hook="$ssh_hook" '
    {
      if ($0 == scan_hook || $0 == ssh_hook ||
          $0 ~ /\[ -x ""\$(APPLY_SCRIPT|SSH_WHITELIST_APPLY)"" \]/ ||
          $0 ~ /\[ -x "'\''\/usr\/local\/sbin\/(net-scan-cleanup-apply|ssh22-whitelist-apply)'\''" \]/) {
        next
      }
      print
      if ($0 ~ /^[[:space:]]*iptables-restore[[:space:]]*<[[:space:]]*\/etc\/iptables\.up\.rules[[:space:]]*$/) {
        print scan_hook
        print ssh_hook
      }
    }
  ' "$SSR_SERVER_SCRIPT" >"$tmp_file"
  cp "$tmp_file" "$SSR_SERVER_SCRIPT"
  rm -f "$tmp_file"
  echo "已给 SSR server.sh 添加 iptables-restore 后恢复钩子：$SSR_SERVER_SCRIPT"
}

persist_iptables() {
  [ "$PERSIST" = "1" ] || return 0

  show_header "持久化 iptables 规则"
  local backup
  if [ -f /etc/iptables.up.rules ]; then
    backup="/etc/iptables.up.rules.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/iptables.up.rules "$backup"
    iptables-save -f /etc/iptables.up.rules
    echo "已保存 /etc/iptables.up.rules 备份=$backup"
  elif [ -d /etc/iptables ]; then
    mkdir -p /etc/iptables
    backup="/etc/iptables/rules.v4.bak.$(date +%Y%m%d%H%M%S)"
    [ -f /etc/iptables/rules.v4 ] && cp /etc/iptables/rules.v4 "$backup" || true
    iptables-save -f /etc/iptables/rules.v4
    echo "已保存 /etc/iptables/rules.v4 备份=${backup:-无}"
  else
    echo "未找到已知的 iptables 持久化文件；当前规则仅运行时生效"
    echo "请安装 iptables-persistent，或按当前发行版方式保存 iptables-save 输出"
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
  restore_ssh_22_access
  clear_old_input_ip_blocks
  block_scan_ports
  install_scan_restore_files
  kill_scan_processes
  delete_conntrack_scan_ports
  block_recent_ssh_abusers
  restore_ssh_22_access
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
    audit) ensure_conntrack; audit_all ;;
    clean) ensure_conntrack; clean_all ;;
    watch) ensure_conntrack; watch_scan ;;
    restore-ssh|restore22) restore_ssh_22_access; persist_iptables ;;
    ports) effective_scan_ports | xargs echo ;;
    *)
      echo "用法：$0 {audit|clean|watch|restore-ssh|ports}" >&2
      echo "示例：SCAN_PORTS='23 2323 2333 5555 7547' $0 clean" >&2
      exit 2
      ;;
  esac
}

main "$@"
