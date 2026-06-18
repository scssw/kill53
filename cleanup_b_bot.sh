#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot cleanup and audit for /tmp/b and /tmp/probe-agent style fallout.
# Safe defaults:
# - keeps /opt/systemlog/SystemLoger placeholder directory if it already exists
# - backs up files before editing cron/systemd
# - does not touch Nezha, x-ui, h-ui, Docker, or SSH authorized_keys

IOC_HASH="30ca33a71b715f77191e4009124e684d76b054151faa4ffa8965fb84f31fee68"
PROBE_AGENT_HASH="21c34c0f4d54d2bfba4bf2501ab30e5329e126b04007e231e57e57dc6d11baa4"
SAMPLE_DIR="/root/malware-samples"
LOG="/root/b-bot-cleanup-$(date +%Y%m%d-%H%M%S).log"

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

exec > >(tee -a "$LOG") 2>&1

section() {
  printf '\n%s========== %s ==========%s\n' "$BLUE" "$1" "$RESET"
}

ok() {
  printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
}

bad() {
  printf '%s[ALERT]%s %s\n' "$RED" "$RESET" "$*"
}

run() {
  printf '  $ %s\n' "$*"
  "$@" || true
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    bad "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bbotbak.$(date +%Y%m%d-%H%M%S)"
  fi
}

save_sample() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$SAMPLE_DIR"
  local base
  base="$(basename "$f")"
  local dst="$SAMPLE_DIR/${base}.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$dst"
  local sum
  sum="$(sha256sum "$dst" | awk '{print $1}')"
  if [ "$sum" = "$IOC_HASH" ]; then
    bad "保存已知 /tmp/b 样本：$dst"
  elif [ "$sum" = "$PROBE_AGENT_HASH" ]; then
    bad "保存可疑 probe-agent 样本：$dst"
  else
    warn "保存可疑样本：$dst sha256=$sum"
  fi
}

clean_processes() {
  section "进程清理"
  local pattern='xmrig|supportxmr|monero|minerd|kinsing|kdevtmpfsi|/tmp/b|/tmp/\.a|/tmp/attack|/tmp/probe-agent|probe-agent'

  if pgrep -af "$pattern" >/tmp/bbot-pids.$$ 2>/dev/null; then
    bad "发现可疑进程："
    cat /tmp/bbot-pids.$$
    pkill -9 -f "$pattern" 2>/dev/null || true
    ok "已尝试结束上述可疑进程"
  else
    ok "未发现 XMR/二阶段/临时 bot 进程"
  fi
  rm -f /tmp/bbot-pids.$$
}

clean_tmp_payloads() {
  section "临时载荷清理"

  for f in \
    /tmp/b \
    /tmp/.a \
    /tmp/attack \
    /tmp/probe-agent \
    /tmp/xmrig \
    /tmp/xmrig.tar.gz \
    /tmp/SystemLog.log \
    /var/tmp/b \
    /var/tmp/.a \
    /dev/shm/b \
    /dev/shm/.a
  do
    if [ -e "$f" ]; then
      save_sample "$f"
      rm -rf -- "$f"
      ok "已删除 $f"
    fi
  done

  find /tmp /var/tmp /dev/shm -maxdepth 2 -type f \
    \( -name 'xmrig-*' -o -name 'kdevtmpfsi' -o -name 'kinsing' -o -name 'minerd' \) \
    -print -exec rm -f {} \; 2>/dev/null || true

  ok "临时目录清理完成"
}

clean_systemd() {
  section "Systemd 清理"

  for svc in xmrig systemlog kinsing kdevtmpfsi; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done

  for f in \
    /etc/systemd/system/xmrig.service \
    /etc/systemd/system/systemlog.service \
    /etc/systemd/system/kinsing.service \
    /etc/systemd/system/kdevtmpfsi.service \
    /usr/lib/systemd/system/xmrig.service \
    /usr/lib/systemd/system/systemlog.service \
    /lib/systemd/system/xmrig.service \
    /lib/systemd/system/systemlog.service
  do
    if [ -f "$f" ]; then
      backup_file "$f"
      rm -f -- "$f"
      ok "已删除 $f"
    fi
  done

  systemctl daemon-reload
  systemctl reset-failed xmrig systemlog kinsing kdevtmpfsi 2>/dev/null || true
  ok "systemd 清理完成"
}

clean_cron_iocs() {
  section "Cron IOC 清理"
  local expr='xmrig|supportxmr|monero|minerd|kinsing|kdevtmpfsi|103\.106\.228\.23|jysiys\.xyz|68\.183\.181\.185|50001|probe-agent|probe3|/tmp/\.a|/tmp/b'
  local files=()

  while IFS= read -r f; do
    files+=("$f")
  done < <(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs -type f 2>/dev/null)

  [ -f /etc/crontab ] && files+=("/etc/crontab")

  local changed=0
  for f in "${files[@]}"; do
    if grep -Eq "$expr" "$f" 2>/dev/null; then
      warn "清理 cron 文件中的 IOC：$f"
      backup_file "$f"
      sed -i -E "/$expr/d" "$f"
      changed=1
    fi
  done

  if [ "$changed" -eq 0 ]; then
    ok "cron 中未发现相关 IOC"
  else
    ok "cron IOC 清理完成，原文件已备份为 *.bbotbak.*"
  fi
}

audit_iocs() {
  section "IOC 复查"

  local expr='103\.106\.228\.23|jysiys\.xyz|68\.183\.181\.185|50001|probe-agent|probe3|main\.execCmd|/tmp/\.a|/tmp/b|xmrig|supportxmr|monero|minerd|kinsing|kdevtmpfsi'
  local exclude='(/root/\.bash_history|/root/fix_cpu_xmrig_qemuga\.sh|/root/b-bot-cleanup-|/root/malware-samples|/usr/local/x-ui/bin/geosite)'

  if command -v rg >/dev/null 2>&1; then
    rg -n --hidden --no-messages "$expr" /etc /root /opt /usr/local /var/spool/cron 2>/dev/null \
      | grep -Ev "$exclude" \
      | head -n 80 \
      || true
  else
    grep -RInE "$expr" /etc /root /opt /usr/local /var/spool/cron 2>/dev/null \
      | grep -Ev "$exclude" \
      | head -n 80 \
      || true
  fi

  ok "IOC 复查完成；上面若无输出，说明未发现未解释命中"
}

audit_tmp_exec() {
  section "临时目录可执行文件"
  local found=0
  while IFS= read -r line; do
    found=1
    printf '%s\n' "$line"
  done < <(find /tmp /var/tmp /dev/shm -maxdepth 2 -type f -perm -111 -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %m %u:%g %p\n' 2>/dev/null | sort)

  if [ "$found" -eq 0 ]; then
    ok "未发现临时目录中的可执行文件"
  else
    warn "请人工确认上面这些临时目录可执行文件。正常服务不应长期从 /tmp 运行。"
  fi
}

audit_services() {
  section "服务状态"
  systemctl list-units --type=service --all 2>/dev/null \
    | grep -Ei 'xmrig|systemlog|kinsing|kdevtmpfsi|nezha|qemu' \
    || ok "未发现匹配服务"

  if [ -d /opt/systemlog/SystemLoger ]; then
    ok "/opt/systemlog/SystemLoger 是目录占位，脚本已保留"
    ls -ld /opt/systemlog/SystemLoger 2>/dev/null || true
  fi
}

hardening_notes() {
  section "加固建议"
  cat <<'NOTES'
建议手动确认以下项目：

1. /tmp 执行限制
   mount | grep -E ' /tmp | /var/tmp | /dev/shm '
   可考虑在 /etc/fstab 中给 /tmp、/var/tmp、/dev/shm 加 noexec,nosuid,nodev。

2. SSH 加固
   /etc/ssh/sshd_config 建议：
   PermitRootLogin prohibit-password
   PasswordAuthentication no
   PubkeyAuthentication yes

3. 入口排查
   last -ai | head -80
   lastb -ai | head -80
   nl -ba /root/.ssh/authorized_keys

4. 如果再次出现高 CPU
   ps -eo pid,ppid,user,stat,%cpu,%mem,etime,lstart,cmd --sort=-%cpu | head -40
   ss -tunap | grep -Ei 'xmrig|stratum|:3333|:4444|:5555|:7777|:14444'
NOTES
}

main() {
  need_root

  printf '%s/b bot 清理与复查脚本%s\n' "$BOLD" "$RESET"
  printf '开始时间: %s\n' "$(date '+%F %T %Z')"
  printf '日志文件: %s\n' "$LOG"

  clean_processes
  clean_tmp_payloads
  clean_systemd
  clean_cron_iocs
  audit_iocs
  audit_tmp_exec
  audit_services
  hardening_notes

  section "完成"
  ok "清理和复查结束。完整日志：$LOG"
}

main "$@"
