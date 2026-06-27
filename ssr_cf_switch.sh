#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

APP_NAME="ssr_cf_switch"
INSTALL_PATH="/usr/local/sbin/${APP_NAME}.sh"
CONFIG_PATH="/etc/${APP_NAME}.conf"
LOG_PATH="/var/log/${APP_NAME}.log"
CRON_MARKER="# ${APP_NAME}_daily_job"
DEFAULT_SSR_FILE="/usr/local/shadowsocksr/mudb.json"
DEFAULT_TIMELIMIT_FILE="/usr/local/SSR-Bash-Python/timelimit.db"
ROOT_SSH_DIR="/root/.ssh"
SELF_DOWNLOAD_URL="https://raw.githubusercontent.com/scssw/kill53/refs/heads/main/ssr_cf_switch.sh"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行：sudo bash $0"
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1，请先安装后再运行。"
    exit 1
  fi
}

require_base_cmds() {
  require_cmd curl
  require_cmd python3
  require_cmd crontab
  require_cmd rsync
  require_cmd ssh
  require_cmd ssh-copy-id
  require_cmd ssh-keygen
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_first_id() {
  python3 -c 'import json, sys
d = json.load(sys.stdin)
r = d.get("result") or []
print(r[0].get("id", "") if d.get("success") and r else "")'
}

json_success() {
  python3 -c 'import json, sys
d = json.load(sys.stdin)
print("1" if d.get("success") else "0")'
}

json_errors() {
  python3 -c 'import json, sys
d = json.load(sys.stdin)
errors = d.get("errors") or []
messages = [e.get("message", str(e)) for e in errors]
print("; ".join(messages) if messages else "未知错误")'
}

cf_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local -a auth_headers

  if [ "${CF_AUTH_TYPE:-token}" = "global_key" ]; then
    auth_headers=(-H "X-Auth-Email: ${CF_EMAIL}" -H "X-Auth-Key: ${CF_TOKEN}")
  else
    auth_headers=(-H "Authorization: Bearer ${CF_TOKEN}")
  fi

  if [ -n "$data" ]; then
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      "${auth_headers[@]}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      "${auth_headers[@]}" \
      -H "Content-Type: application/json"
  fi
}

find_zone_id() {
  local domain="$1"
  local parts_count i j zone encoded resp zone_id
  local -a domain_parts

  IFS='.' read -r -a domain_parts <<< "$domain"
  parts_count="${#domain_parts[@]}"
  if [ "$parts_count" -lt 2 ]; then
    echo "域名格式不正确：$domain" >&2
    return 1
  fi

  for ((i = 0; i <= parts_count - 2; i++)); do
    zone="${domain_parts[$i]}"
    for ((j = i + 1; j < parts_count; j++)); do
      zone="${zone}.${domain_parts[$j]}"
    done

    encoded="$(urlencode "$zone")"
    resp="$(cf_api GET "/zones?name=${encoded}&status=active&page=1&per_page=1")"
    zone_id="$(printf '%s' "$resp" | json_first_id)"
    if [ -n "$zone_id" ]; then
      printf '%s' "$zone_id"
      return 0
    fi
  done

  echo "Cloudflare 中找不到域名对应的 Zone，请确认认证信息有 Zone:Read 权限，且域名已接入 Cloudflare：$domain" >&2
  return 1
}

build_dns_payload() {
  DOMAIN="$1" TARGET_IP="$2" python3 -c 'import json, os
print(json.dumps({
    "type": "A",
    "name": os.environ["DOMAIN"],
    "content": os.environ["TARGET_IP"],
    "ttl": 1,
    "proxied": False
}))'
}

update_cloudflare_record() {
  local domain="$1"
  local target_ip="$2"
  local zone_id encoded_domain record_resp record_id payload update_resp ok err

  zone_id="$(find_zone_id "$domain")"
  encoded_domain="$(urlencode "$domain")"
  record_resp="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${encoded_domain}&page=1&per_page=1")"
  record_id="$(printf '%s' "$record_resp" | json_first_id)"
  payload="$(build_dns_payload "$domain" "$target_ip")"

  if [ -n "$record_id" ]; then
    update_resp="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$payload")"
  else
    update_resp="$(cf_api POST "/zones/${zone_id}/dns_records" "$payload")"
  fi

  ok="$(printf '%s' "$update_resp" | json_success)"
  if [ "$ok" != "1" ]; then
    err="$(printf '%s' "$update_resp" | json_errors)"
    echo "Cloudflare DNS 更新失败：$err" >&2
    return 1
  fi

  echo "Cloudflare DNS 已更新：${domain} -> ${target_ip}"
}

valid_time() {
  local value="$1"
  local hour minute

  [[ "$value" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  hour="${BASH_REMATCH[1]}"
  minute="${BASH_REMATCH[2]}"
  [ "$hour" -ge 0 ] && [ "$hour" -le 23 ] && [ "$minute" -ge 0 ] && [ "$minute" -le 59 ]
}

valid_ipv4() {
  local ip="$1"
  local part
  local -a ip_parts

  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a ip_parts <<< "$ip"
  for part in "${ip_parts[@]}"; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}

resolve_script_path() {
  local source_path="${BASH_SOURCE[0]:-$0}"
  local resolved_path

  if [ -f "$source_path" ]; then
    readlink -f "$source_path"
    return 0
  fi

  if [[ "$source_path" != /* ]] && [ -f "$(pwd -P)/${source_path}" ]; then
    readlink -f "$(pwd -P)/${source_path}"
    return 0
  fi

  resolved_path="$(readlink -f "$source_path" 2>/dev/null || true)"
  if [ -n "$resolved_path" ] && [ -f "$resolved_path" ]; then
    printf '%s\n' "$resolved_path"
    return 0
  fi

  return 1
}

install_self() {
  local current_path

  if current_path="$(resolve_script_path)"; then
    if [ "$current_path" != "$INSTALL_PATH" ]; then
      cp "$current_path" "$INSTALL_PATH"
      chmod 700 "$INSTALL_PATH"
    fi
  else
    require_cmd curl
    echo "当前脚本来自管道或进程替换，正在从 GitHub 下载脚本安装到 ${INSTALL_PATH}..."
    curl -fsSL "$SELF_DOWNLOAD_URL" -o "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
  fi

  if [ ! -s "$INSTALL_PATH" ]; then
    echo "脚本安装失败：${INSTALL_PATH} 为空或不存在。" >&2
    exit 1
  fi

  if ! bash -n "$INSTALL_PATH"; then
    echo "脚本安装失败：下载或复制后的脚本语法检查未通过。" >&2
    exit 1
  fi
}

write_config() {
  local transfer_enabled="$1"

  umask 077
  {
    echo "# Generated by ${APP_NAME}. Keep this file readable only by root."
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'CF_AUTH_TYPE=%q\n' "$CF_AUTH_TYPE"
    printf 'CF_EMAIL=%q\n' "${CF_EMAIL:-}"
    printf 'CF_TOKEN=%q\n' "$CF_TOKEN"
    printf 'TARGET_IP=%q\n' "$TARGET_IP"
    printf 'SSR_FILE=%q\n' "$SSR_FILE"
    printf 'TIMELIMIT_FILE=%q\n' "$TIMELIMIT_FILE"
    printf 'TRANSFER_ENABLED=%q\n' "$transfer_enabled"
  } > "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
}

install_cron() {
  local time_value="$1"
  local hour minute tmp

  hour="${time_value%:*}"
  minute="${time_value#*:}"
  tmp="$(mktemp)"

  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmp" || true
  printf '%s %s * * * %s --run >> %s 2>&1 %s\n' "$minute" "$hour" "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

ensure_ssh_key() {
  if [ -f "$ROOT_SSH_DIR/id_ed25519.pub" ] || [ -f "$ROOT_SSH_DIR/id_rsa.pub" ]; then
    return 0
  fi

  echo "未发现 SSH 公钥，正在为当前 root 用户生成免密登录密钥..."
  mkdir -p "$ROOT_SSH_DIR"
  chmod 700 "$ROOT_SSH_DIR"
  ssh-keygen -t ed25519 -N "" -f "$ROOT_SSH_DIR/id_ed25519"
}

setup_ssh_login() {
  local target="root@${TARGET_IP}"

  echo
  echo "开始配置 SSH 免密登录：${target}"
  echo "下面可能会要求输入一次目标服务器 root 密码，用来写入公钥。"

  ensure_ssh_key

  if ! ssh-copy-id "$target"; then
    echo
    echo "警告：ssh-copy-id 执行失败。定时 DNS 切换已设置，但 SSR 数据同步可能仍需要密码。"
    echo "你可以稍后手动执行：ssh-copy-id ${target}"
    return 1
  fi

  echo "正在验证 SSH 免密登录..."
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "true"; then
    echo "SSH 免密登录验证通过，定时 rsync 可以正常执行。"
  else
    echo "警告：ssh-copy-id 已执行，但免密验证未通过。请手动检查 SSH 登录设置。"
    return 1
  fi
}

remove_cron() {
  local tmp

  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
}

load_config() {
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "未找到配置文件：$CONFIG_PATH" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
  CF_AUTH_TYPE="${CF_AUTH_TYPE:-token}"
  CF_EMAIL="${CF_EMAIL:-}"
  SSR_FILE="${SSR_FILE:-$DEFAULT_SSR_FILE}"
  TIMELIMIT_FILE="${TIMELIMIT_FILE:-$DEFAULT_TIMELIMIT_FILE}"
  TRANSFER_ENABLED="${TRANSFER_ENABLED:-1}"
}

sync_file_to_target() {
  local source_file="$1"
  local label="$2"

  if [ ! -f "$source_file" ]; then
    echo "${label} 文件不存在：$source_file" >&2
    return 1
  fi

  rsync -avz "$source_file" "root@${TARGET_IP}:${source_file}"
  echo "${label} 已同步到：root@${TARGET_IP}:${source_file}"
}

run_job() {
  need_root
  require_cmd curl
  require_cmd python3
  require_cmd rsync
  load_config

  echo "[$(date '+%F %T')] 开始执行定时切换"
  update_cloudflare_record "$DOMAIN" "$TARGET_IP"

  if [ "${TRANSFER_ENABLED}" = "1" ]; then
    sync_file_to_target "$SSR_FILE" "SSR 用户数据"
    sync_file_to_target "$TIMELIMIT_FILE" "SSR 到期时间数据"
  else
    echo "SSR 数据同步已关闭，仅执行 DNS 切换。"
  fi

  echo "[$(date '+%F %T')] 执行完成"
}

setup_switch() {
  local switch_time zone_id auth_choice

  need_root
  require_base_cmds

  read -r -p "请输入每天切换时间，例 23:30：" switch_time
  if ! valid_time "$switch_time"; then
    echo "时间格式不正确，请使用 HH:MM，例如 23:30"
    exit 1
  fi

  read -r -p "请输入要切换的域名，例 hk.ssrr.today：" DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "域名不能为空。"
    exit 1
  fi

  echo "请选择 Cloudflare 认证方式："
  echo "1、API Token（推荐）"
  echo "2、Global API Key"
  read -r -p "请输入选项 [1-2]：" auth_choice
  case "$auth_choice" in
    1)
      CF_AUTH_TYPE="token"
      CF_EMAIL=""
      read -r -s -p "请输入 Cloudflare API Token：" CF_TOKEN
      echo
      ;;
    2)
      CF_AUTH_TYPE="global_key"
      read -r -p "请输入 Cloudflare 账号邮箱：" CF_EMAIL
      if [ -z "$CF_EMAIL" ]; then
        echo "Cloudflare 账号邮箱不能为空。"
        exit 1
      fi
      read -r -s -p "请输入 Cloudflare Global API Key：" CF_TOKEN
      echo
      ;;
    *)
      echo "无效选项。"
      exit 1
      ;;
  esac
  if [ -z "$CF_TOKEN" ]; then
    echo "Cloudflare 认证密钥不能为空。"
    exit 1
  fi

  read -r -p "请输入目标 IP，例 38.76.188.74：" TARGET_IP
  if ! valid_ipv4 "$TARGET_IP"; then
    echo "目标 IP 格式不正确。"
    exit 1
  fi

  SSR_FILE="$DEFAULT_SSR_FILE"
  TIMELIMIT_FILE="$DEFAULT_TIMELIMIT_FILE"

  echo "正在验证 Cloudflare 认证信息和域名..."
  zone_id="$(find_zone_id "$DOMAIN")"
  echo "验证通过，Zone ID：$zone_id"

  install_self
  write_config "1"
  install_cron "$switch_time"

  echo
  echo "设置完成。"
  echo "每天 ${switch_time} 会执行："
  echo "1. 将 ${DOMAIN} 的 A 记录切换到 ${TARGET_IP}"
  echo "2. 执行 rsync -avz ${SSR_FILE} root@${TARGET_IP}:${SSR_FILE}"
  echo "3. 执行 rsync -avz ${TIMELIMIT_FILE} root@${TARGET_IP}:${TIMELIMIT_FILE}"
  echo
  echo "配置文件：$CONFIG_PATH"
  echo "执行脚本：$INSTALL_PATH"
  echo "日志文件：$LOG_PATH"
  echo "手动测试：sudo $INSTALL_PATH --run"
  echo "注意：rsync 定时执行需要提前配置 root SSH 免密登录。"

  setup_ssh_login || true
}

change_time() {
  local switch_time

  need_root
  require_cmd crontab
  load_config

  read -r -p "请输入新的每天切换时间，例 23:30：" switch_time
  if ! valid_time "$switch_time"; then
    echo "时间格式不正确，请使用 HH:MM，例如 23:30"
    exit 1
  fi

  install_self
  install_cron "$switch_time"

  echo "定时时间已修改为每天 ${switch_time}。"
  echo "当前任务：${INSTALL_PATH} --run"
}

change_target_ip() {
  local new_target_ip

  need_root
  load_config
  if [ "${TRANSFER_ENABLED}" = "1" ]; then
    require_cmd ssh
    require_cmd ssh-copy-id
    require_cmd ssh-keygen
  fi

  echo "当前目标 IP：${TARGET_IP}"
  read -r -p "请输入新的目标 IP，例 38.76.188.74：" new_target_ip
  if ! valid_ipv4 "$new_target_ip"; then
    echo "目标 IP 格式不正确。"
    exit 1
  fi

  TARGET_IP="$new_target_ip"
  install_self
  write_config "$TRANSFER_ENABLED"

  echo "目标 IP 已修改为：${TARGET_IP}"
  echo "后续定时任务会将 ${DOMAIN} 的 A 记录切换到 ${TARGET_IP}。"

  if [ "${TRANSFER_ENABLED}" = "1" ]; then
    echo "SSR 数据同步当前已开启，目标 IP 修改后需要确认 root SSH 免密登录。"
    setup_ssh_login || true
  fi
}

upgrade_script_only() {
  need_root
  install_self

  echo "脚本已升级，原有配置和定时时间保持不变。"
  echo "执行脚本：$INSTALL_PATH"
  echo "配置文件：$CONFIG_PATH"
}

disable_transfer() {
  need_root
  load_config
  write_config "0"
  echo "已取消转移数据设置。后续定时任务只切换 Cloudflare DNS，不再同步 SSR 数据。"
}

cancel_all() {
  need_root
  remove_cron
  rm -f "$CONFIG_PATH"
  echo "已取消所有设置：cron 定时任务已删除，配置文件已删除。"
}

show_menu() {
  echo "=============================="
  echo " 定时切换服务器域名和 SSR 数据"
  echo "=============================="
  echo "1、设置定时切换域名和数据"
  echo "2、取消转移数据设置"
  echo "3、取消所有所有设置"
  echo "4、修改定时时间"
  echo "5、修改目标 IP"
  echo "6、升级脚本设置不变"
  echo
  read -r -p "请输入选项 [1-6]：" choice

  case "$choice" in
    1) setup_switch ;;
    2) disable_transfer ;;
    3) cancel_all ;;
    4) change_time ;;
    5) change_target_ip ;;
    6) upgrade_script_only ;;
    *) echo "无效选项。" && exit 1 ;;
  esac
}

case "${1:-}" in
  --run)
    run_job
    ;;
  *)
    show_menu
    ;;
esac
