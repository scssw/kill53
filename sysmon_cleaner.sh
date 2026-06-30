#!/usr/bin/env bash
set -Eeuo pipefail

NAME="sysmon清理工具"
MODE="${1:-menu}"
TS="$(date +%Y%m%d-%H%M%S)"
QUARANTINE="/root/sysmon-quarantine-${TS}"

SERVICES=(
  "sysmon.service"
  "sysmon-guard.service"
)

TIMERS=(
  "sysmon-guard.timer"
)

PATHS=(
  "/usr/local/sysmon"
  "/usr/local/.sysmon-guard"
  "/usr/local/lib/libsysmon.so"
  "/etc/systemd/system/sysmon.service"
  "/etc/systemd/system/sysmon-guard.service"
  "/etc/systemd/system/sysmon-guard.timer"
)

log() {
  printf '[%s] %s\n' "$NAME" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "请使用 root 权限运行"
    exit 1
  fi
}

section() {
  printf '\n==== %s ====\n' "$*"
}

show_status() {
  section "systemd 服务"
  if have systemctl; then
    systemctl status "${SERVICES[@]}" "${TIMERS[@]}" --no-pager 2>&1 || true
    printf '\n'
    systemctl list-timers --all --no-pager 2>/dev/null | grep -E 'sysmon|NEXT|^$' || true
  else
    log "未找到 systemctl"
  fi

  section "相关进程"
  ps auxww | grep -E '[s]ysmon|/usr/local/.sysmon-guard|libsysmon' || true

  section "网络连接"
  if have ss; then
    ss -tpn state established 2>/dev/null | grep -E 'sysmon|51\.254\.44\.35|:8008' || true
    ss -tulpn 2>/dev/null | grep -E 'sysmon|51\.254\.44\.35|:8008' || true
  else
    log "未找到 ss"
  fi

  section "相关文件"
  for p in "${PATHS[@]}" "/etc/ld.so.preload"; do
    if [ -e "$p" ]; then
      ls -ld "$p"
    fi
  done

  section "配置文件"
  if [ -f /usr/local/sysmon/config.yml ]; then
    sed -n '1,160p' /usr/local/sysmon/config.yml
  fi

  section "ld.so.preload 注入"
  if [ -f /etc/ld.so.preload ]; then
    nl -ba /etc/ld.so.preload
  else
    log "未找到 /etc/ld.so.preload"
  fi

  section "cron 引用"
  crontab -l 2>/dev/null | grep -E 'sysmon|libsysmon|\.sysmon-guard' || true
  grep -RInE 'sysmon|libsysmon|\.sysmon-guard' /etc/cron* 2>/dev/null || true

  section "最近 guard 日志"
  if [ -f /usr/local/.sysmon-guard/guard.log ]; then
    tail -80 /usr/local/.sysmon-guard/guard.log
  fi
}

quarantine_files() {
  mkdir -p "$QUARANTINE"
  log "隔离备份目录: $QUARANTINE"

  for p in "${PATHS[@]}" "/etc/ld.so.preload"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      mkdir -p "$QUARANTINE$(dirname "$p")"
      cp -a "$p" "$QUARANTINE$p" 2>/dev/null || true
    fi
  done

  if crontab -l >/dev/null 2>&1; then
    crontab -l > "$QUARANTINE/root.crontab.before"
  fi

  if have systemctl; then
    systemctl cat "${SERVICES[@]}" "${TIMERS[@]}" > "$QUARANTINE/systemd-units.before" 2>&1 || true
  fi
}

stop_systemd() {
  if ! have systemctl; then
    return
  fi

  log "正在停止并禁用 timer 和服务"
  systemctl stop "${TIMERS[@]}" 2>/dev/null || true
  systemctl disable "${TIMERS[@]}" 2>/dev/null || true
  systemctl stop "${SERVICES[@]}" 2>/dev/null || true
  systemctl disable "${SERVICES[@]}" 2>/dev/null || true
}

kill_leftovers() {
  log "正在结束残留 sysmon 进程"
  pkill -f '/usr/local/sysmon/sysmon' 2>/dev/null || true
  pkill -f '/usr/local/.sysmon-guard/sysmon' 2>/dev/null || true
  pkill -f 'sysmon guard' 2>/dev/null || true
}

clean_ld_preload() {
  if [ ! -f /etc/ld.so.preload ]; then
    return
  fi

  if grep -qE '/usr/local/lib/libsysmon\.so|libsysmon\.so' /etc/ld.so.preload; then
    log "正在从 /etc/ld.so.preload 移除 libsysmon.so 注入"
    cp -a /etc/ld.so.preload "$QUARANTINE/etc/ld.so.preload.before-edit" 2>/dev/null || true
    sed -i '/\/usr\/local\/lib\/libsysmon\.so/d;/libsysmon\.so/d' /etc/ld.so.preload
  fi

  if [ ! -s /etc/ld.so.preload ]; then
    log "正在删除空的 /etc/ld.so.preload"
    rm -f /etc/ld.so.preload
  fi
}

clean_cron() {
  if ! crontab -l >/dev/null 2>&1; then
    return
  fi

  if crontab -l | grep -qE 'sysmon|libsysmon|\.sysmon-guard'; then
    log "正在移除 root crontab 中的 sysmon 引用"
    crontab -l | grep -Ev 'sysmon|libsysmon|\.sysmon-guard' > "$QUARANTINE/root.crontab.after"
    crontab "$QUARANTINE/root.crontab.after"
  fi
}

remove_files() {
  log "正在删除 sysmon 相关文件"
  rm -rf /usr/local/sysmon
  rm -rf /usr/local/.sysmon-guard
  rm -f /usr/local/lib/libsysmon.so
  rm -f /etc/systemd/system/sysmon.service
  rm -f /etc/systemd/system/sysmon-guard.service
  rm -f /etc/systemd/system/sysmon-guard.timer

  if have systemctl; then
    systemctl daemon-reload
    systemctl reset-failed sysmon.service sysmon-guard.service sysmon-guard.timer 2>/dev/null || true
  fi
}

verify_clean() {
  section "清理验证"
  local bad=0

  if have systemctl; then
    systemctl is-active --quiet sysmon.service && bad=1 && log "仍在运行: sysmon.service"
    systemctl is-active --quiet sysmon-guard.timer && bad=1 && log "仍在运行: sysmon-guard.timer"
  fi

  if ps auxww | grep -Eq '[s]ysmon|/usr/local/.sysmon-guard|libsysmon'; then
    bad=1
    log "仍发现 sysmon 相关进程:"
    ps auxww | grep -E '[s]ysmon|/usr/local/.sysmon-guard|libsysmon' || true
  fi

  for p in /usr/local/sysmon /usr/local/.sysmon-guard /usr/local/lib/libsysmon.so; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      bad=1
      log "仍存在: $p"
    fi
  done

  if [ -f /etc/ld.so.preload ] && grep -qE 'libsysmon|sysmon' /etc/ld.so.preload; then
    bad=1
    log "/etc/ld.so.preload 中仍有 sysmon 引用"
  fi

  if [ "$bad" -eq 0 ]; then
    log "清理验证通过"
  else
    log "清理验证发现残留"
    return 1
  fi
}

clean_all() {
  need_root
  quarantine_files
  stop_systemd
  kill_leftovers
  clean_ld_preload
  clean_cron
  remove_files
  kill_leftovers
  verify_clean || true
  log "隔离备份保留在: $QUARANTINE"
}

usage() {
  cat <<'EOF'
用法:
  bash sysmon_cleaner.sh          # 显示交互菜单
  bash sysmon_cleaner.sh status   # 只查询
  bash sysmon_cleaner.sh clean    # 隔离并清理 sysmon 病毒持久化

清理目标:
  /usr/local/sysmon
  /usr/local/.sysmon-guard
  /usr/local/lib/libsysmon.so
  /etc/ld.so.preload 中的 libsysmon.so 引用
  sysmon.service / sysmon-guard.service / sysmon-guard.timer
  root crontab 中包含 sysmon/libsysmon/.sysmon-guard 的行
EOF
}

menu() {
  clear 2>/dev/null || true
  cat <<'EOF'
========================================
       sysmon 病毒查询清理工具
========================================
1. 查询
2. 清理
0. 退出
========================================
EOF

  printf '请选择操作 [1/2/0]: '
  read -r choice

  case "$choice" in
    1)
      show_status
      ;;
    2)
      printf '确认清理 sysmon 病毒残留？会先备份隔离再删除。[y/N]: '
      read -r confirm
      case "$confirm" in
        y|Y|yes|YES)
          clean_all
          ;;
        *)
          log "已取消清理"
          ;;
      esac
      ;;
    0)
      log "已退出"
      ;;
    *)
      log "无效选择"
      exit 2
      ;;
  esac
}

case "$MODE" in
  menu|"")
    menu
    ;;
  status|check)
    show_status
    ;;
  clean|remove)
    clean_all
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
