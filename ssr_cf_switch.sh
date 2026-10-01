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
CRON_TZ_MARKER="# ${APP_NAME}_timezone"
DEFAULT_SSR_FILE="/usr/local/shadowsocksr/mudb.json"
DEFAULT_TIMELIMIT_FILE="/usr/local/SSR-Bash-Python/timelimit.db"
ROOT_SSH_DIR="/root/.ssh"
SELF_DOWNLOAD_URL="https://raw.githubusercontent.com/scssw/kill53/refs/heads/main/ssr_cf_switch.sh"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行：bash $0"
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
try:
    d = json.load(sys.stdin)
    r = d.get("result") or []
    print(r[0].get("id", "") if d.get("success") and r else "")
except Exception:
    print("")'
}

json_success() {
  python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    print("1" if d.get("success") else "0")
except Exception:
    print("0")'
}

json_errors() {
  python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    errors = d.get("errors") or []
    messages = [e.get("message", str(e)) for e in errors]
    print("; ".join(messages) if messages else "未知错误")
except Exception:
    print("解析返回结果失败")'
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
    resp="$(cf_api GET "/zones?name=${encoded}&status=active&page=1&per_page=1" 2>/dev/null || true)"
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

normalize_domains() {
  local input="$1" item normalized=""
  local -a values
  read -r -a values <<< "$input"
  for item in "${values[@]}"; do
    item="${item#http://}"
    item="${item#https://}"
    item="${item%%/*}"
    item="${item%,}"
    item="${item,,}"
    [[ "$item" == *.* ]] || item="${item}.ssrr.today"
    [[ "$item" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$item" == *.* ]] || return 1
    if [ -n "$normalized" ]; then normalized+=" "; fi
    normalized+="$item"
  done
  [ -n "$normalized" ] || return 1
  printf '%s\n' "$normalized"
}

update_all_cloudflare_records() {
  local domains="$1" target_ip="$2" domain
  local -a list
  read -r -a list <<< "$domains"
  for domain in "${list[@]}"; do
    update_cloudflare_record "$domain" "$target_ip"
  done
}

parse_and_validate_time() {
  local input="$1"
  local hour minute

  if [[ "$input" =~ ^([0-9]{1,2})$ ]]; then
    hour="$((10#${BASH_REMATCH[1]}))"
    minute=0
  elif [[ "$input" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    hour="$((10#${BASH_REMATCH[1]}))"
    minute="$((10#${BASH_REMATCH[2]}))"
  else
    return 1
  fi

  if [ "$hour" -ge 0 ] && [ "$hour" -le 23 ] && [ "$minute" -ge 0 ] && [ "$minute" -le 59 ]; then
    printf "%02d:%02d\n" "$hour" "$minute"
    return 0
  fi
  return 1
}

valid_time() {
  parse_and_validate_time "$1" >/dev/null 2>&1
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

check_port() {
  local ip="$1"
  local port="$2"
  local timeout="${3:-3}"

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c '
import socket, sys
ip = sys.argv[1]
port = int(sys.argv[2])
timeout = float(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    code = s.connect_ex((ip, port))
    sys.exit(0 if code == 0 else 1)
except Exception:
    sys.exit(1)
finally:
    s.close()
' "$ip" "$port" "$timeout" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 备用方案：/dev/tcp 检测
  if timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/${ip}/${port}" 2>/dev/null; then
    return 0
  fi

  return 1
}

check_cron_status() {
  if crontab -l 2>/dev/null | grep -Fq "$CRON_MARKER"; then
    local cron_line
    cron_line="$(crontab -l 2>/dev/null | grep -F "$CRON_MARKER" | head -n 1)"
    echo "运行中 (${cron_line%% $CRON_MARKER*})"
  else
    echo "未设置"
  fi
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
  local transfer_enabled="${1:-1}"

  umask 077
  {
    echo "# Generated by ${APP_NAME}. Keep this file readable only by root."
    printf 'DOMAIN=%q\n' "${DOMAIN:-${DOMAINS:-}}"
    printf 'DOMAINS=%q\n' "${DOMAINS:-${DOMAIN:-}}"
    printf 'CF_AUTH_TYPE=%q\n' "$CF_AUTH_TYPE"
    printf 'CF_EMAIL=%q\n' "${CF_EMAIL:-}"
    printf 'CF_TOKEN=%q\n' "$CF_TOKEN"
    printf 'TARGET_IP=%q\n' "$TARGET_IP"
    printf 'LOCAL_IP=%q\n' "${LOCAL_IP:-}"
    printf 'LOCAL_SSH_PORT=%q\n' "${LOCAL_SSH_PORT:-22}"
    printf 'TARGET_PORT=%q\n' "${TARGET_PORT:-22}"
    printf 'SWITCH_TIME=%q\n' "${SWITCH_TIME:-}"
    printf 'RETURN_TIME=%q\n' "${RETURN_TIME:-}"
    printf 'SSR_FILE=%q\n' "${SSR_FILE:-$DEFAULT_SSR_FILE}"
    printf 'TIMELIMIT_FILE=%q\n' "${TIMELIMIT_FILE:-$DEFAULT_TIMELIMIT_FILE}"
    printf 'TRANSFER_ENABLED=%q\n' "$transfer_enabled"
    printf 'TRANSFER_MODE=%q\n' "${TRANSFER_MODE:-ssr}"
  } > "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
}

install_cron() {
  local out="$1" back="$2" oh om bh bm tmp
  if ! valid_time "$out" || ! valid_time "$back"; then
    echo "定时时间无效：传送时间和传回时间都必须填写（例：18 2）。" >&2
    return 1
  fi
  oh="${out%:*}"; om="${out#*:}"; bh="${back%:*}"; bm="${back#*:}"
  oh="$((10#$oh))"; om="$((10#$om))"; bh="$((10#$bh))"; bm="$((10#$bm))"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | grep -vF "$CRON_TZ_MARKER" | grep -v '^CRON_TZ=Asia/Shanghai$' > "$tmp" || true
  printf 'CRON_TZ=Asia/Shanghai\n%s\n' "$CRON_TZ_MARKER" >> "$tmp"
  printf '%d %d * * * %s --out >> %s 2>&1 %s\n' "$om" "$oh" "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >> "$tmp"
  printf '%d %d * * * %s --back >> %s 2>&1 %s\n' "$bm" "$bh" "$INSTALL_PATH" "$LOG_PATH" "$CRON_MARKER" >> "$tmp"
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
  local port="${TARGET_PORT:-22}"

  echo
  echo "开始配置 SSH 免密登录：${target} (端口: ${port})"
  echo "下面可能会要求输入一次目标服务器 root 密码，用来写入公钥。"

  ensure_ssh_key

  if ! ssh-copy-id -p "$port" "$target"; then
    echo
    echo "警告：ssh-copy-id 执行失败。定时 DNS 切换已设置，但 SSR 数据同步可能仍需要密码。"
    echo "你可以稍后手动执行：ssh-copy-id -p ${port} ${target}"
    return 1
  fi

  echo "正在验证 SSH 免密登录..."
  if ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "$target" "true"; then
    echo "SSH 免密登录验证通过，定时 rsync 可以正常执行。"
  else
    echo "警告：ssh-copy-id 已执行，但免密验证未通过。请手动检查 SSH 登录设置。"
    return 1
  fi
}

remove_cron() {
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | grep -vF "$CRON_TZ_MARKER" | grep -v '^CRON_TZ=Asia/Shanghai$' > "$tmp" || true
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
  TARGET_PORT="${TARGET_PORT:-22}"
  SSR_FILE="${SSR_FILE:-$DEFAULT_SSR_FILE}"
  TIMELIMIT_FILE="${TIMELIMIT_FILE:-$DEFAULT_TIMELIMIT_FILE}"
  TRANSFER_ENABLED="${TRANSFER_ENABLED:-1}"
  SWITCH_TIME="${SWITCH_TIME:-}"
  RETURN_TIME="${RETURN_TIME:-}"
  LOCAL_IP="${LOCAL_IP:-}"
  LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"
  TRANSFER_MODE="${TRANSFER_MODE:-ssr}"
  DOMAINS="${DOMAINS:-${DOMAIN:-}}"
  if [ -z "${DOMAIN:-}" ]; then DOMAIN="${DOMAINS%% *}"; fi
}

load_config_silent() {
  if [ -f "$CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_PATH" 2>/dev/null || true
    CF_AUTH_TYPE="${CF_AUTH_TYPE:-token}"
    CF_EMAIL="${CF_EMAIL:-}"
    TARGET_PORT="${TARGET_PORT:-22}"
    SSR_FILE="${SSR_FILE:-$DEFAULT_SSR_FILE}"
    TIMELIMIT_FILE="${TIMELIMIT_FILE:-$DEFAULT_TIMELIMIT_FILE}"
    TRANSFER_ENABLED="${TRANSFER_ENABLED:-1}"
    SWITCH_TIME="${SWITCH_TIME:-}"
    RETURN_TIME="${RETURN_TIME:-}"
    LOCAL_IP="${LOCAL_IP:-}"
    LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"
    TRANSFER_MODE="${TRANSFER_MODE:-ssr}"
    DOMAINS="${DOMAINS:-${DOMAIN:-}}"
    if [ -z "${DOMAIN:-}" ]; then DOMAIN="${DOMAINS%% *}"; fi
  fi
}

sync_file_to_target() {
  local source_file="$1"
  local label="$2"
  local port="${TARGET_PORT:-22}"

  if [ ! -f "$source_file" ]; then
    echo "${label} 文件不存在：$source_file" >&2
    return 1
  fi

  rsync -avz -e "ssh -p ${port}" "$source_file" "root@${TARGET_IP}:${source_file}"
  echo "${label} 已同步到：root@${TARGET_IP}:${source_file} (端口: ${port})"
}

sync_data() {
  local direction="$1" port="${TARGET_PORT:-22}" remote="root@${TARGET_IP}"
  local -a paths
  case "${TRANSFER_MODE:-ssr}" in
    ssr) paths=("$SSR_FILE" "$TIMELIMIT_FILE") ;;
    xui) paths=("/etc/x-ui/") ;;
    both) paths=("$SSR_FILE" "$TIMELIMIT_FILE" "/etc/x-ui/") ;;
    *) echo "未知数据转移模式：${TRANSFER_MODE}" >&2; return 1 ;;
  esac
  if [ "$direction" = "out" ]; then
    for path in "${paths[@]}"; do
      [ -e "$path" ] || { echo "待同步路径不存在：$path" >&2; return 1; }
      rsync -aHAX --numeric-ids -e "ssh -p ${port}" "$path" "${remote}:$path"
    done
    if [ "$TRANSFER_MODE" = "ssr" ] || [ "$TRANSFER_MODE" = "both" ]; then
      ssh -p "$port" "$remote" "systemctl restart ssr-bash-python.service"
    fi
    if [ "$TRANSFER_MODE" = "xui" ] || [ "$TRANSFER_MODE" = "both" ]; then
      ssh -p "$port" "$remote" "systemctl restart x-ui.service"
    fi
  else
    for path in "${paths[@]}"; do
      ssh -p "$port" "$remote" "rsync -aHAX --numeric-ids -e 'ssh -p ${LOCAL_SSH_PORT}' '${path}' 'root@${LOCAL_IP}:${path}'"
    done
    if [ "$TRANSFER_MODE" = "ssr" ] || [ "$TRANSFER_MODE" = "both" ]; then
      systemctl restart ssr-bash-python.service
    fi
    if [ "$TRANSFER_MODE" = "xui" ] || [ "$TRANSFER_MODE" = "both" ]; then
      systemctl restart x-ui.service
    fi
  fi
}

run_job() {
  need_root
  require_cmd curl
  require_cmd python3
  require_cmd rsync
  load_config

  local direction="${1:-out}" destination action_label
  if [ "$direction" = "out" ]; then action_label="传送到 B"; else action_label="从 B 传回 A"; fi
  echo "[$(date '+%F %T %Z')] 开始${action_label}"
  if [ "$direction" = "out" ]; then
    destination="$TARGET_IP"
    if [ "${TRANSFER_ENABLED:-1}" = "1" ]; then sync_data out; else echo "数据同步已关闭，仅切换 DNS。"; fi
  else
    destination="$LOCAL_IP"
    if [ "${TRANSFER_ENABLED:-1}" = "1" ]; then sync_data back; else echo "数据同步已关闭，仅切换 DNS。"; fi
  fi
  update_all_cloudflare_records "${DOMAINS:-$DOMAIN}" "$destination"
  echo "[$(date '+%F %T %Z')] 执行完成，域名已指向 ${destination}"
}

prompt_switch_time() {
  local current="${1:-}"
  local input time_res
  local prompt_str="请输入每天切换时间的小时 (0-23，如 16 为 16:00)"
  if [ -n "$current" ]; then
    prompt_str+=" [当前记录: ${current}] (直接回车保持不变)"
  fi
  prompt_str+="："

  while true; do
    read -r -p "$prompt_str" input
    if [ -z "$input" ] && [ -n "$current" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    if time_res="$(parse_and_validate_time "$input")"; then
      printf '%s\n' "$time_res"
      return 0
    fi
    echo "时间输入无效！只需输入小时 (0-23，如 16 表示 16:00) 或 HH:MM。"
  done
}

prompt_domain() {
  local input
  local domain_prompt="请输入要切换的域名前缀或完整域名（多个用空格分隔）"
  if [ -n "${DOMAINS:-${DOMAIN:-}}" ]; then
    domain_prompt+=" [当前记录: ${DOMAINS:-$DOMAIN}] (直接回车保持不变)"
  else
    domain_prompt+=" (例 uscn2 natus，或输入完整域名)"
  fi
  domain_prompt+="："

  while true; do
    read -r -p "$domain_prompt" input
    if [ -z "$input" ] && [ -n "${DOMAINS:-${DOMAIN:-}}" ]; then
      return 0
    fi
    if [ -n "$input" ]; then
      if DOMAINS="$(normalize_domains "$input")"; then
        DOMAIN="${DOMAINS%% *}"
        return 0
      fi
      echo "域名格式不正确，请使用空格分隔多个域名或前缀。"
    fi
    echo "域名不能为空，请重新输入！"
  done
}

prompt_transfer_mode() {
  local choice
  echo
  echo "选择定时转移的数据类型："
  echo "1、默认定时转移 SSR"
  echo "2、定时转移 xui"
  echo "3、定时转移 SSR+xui"
  read -r -p "请输入选项 [1-3]：" choice
  case "$choice" in
    1|"") TRANSFER_MODE=ssr ;;
    2) TRANSFER_MODE=xui ;;
    3) TRANSFER_MODE=both ;;
    *) echo "无效选项，保持当前设置：${TRANSFER_MODE:-ssr}" ;;
  esac
}

prompt_return_time() {
  local current="${RETURN_TIME:-}" input result prompt_str="请输入传回时间（北京时间，小时或 HH:MM）"
  [ -n "$current" ] && prompt_str+=" [当前: ${current}] (回车保持)"
  prompt_str+="："
  while true; do
    read -r -p "$prompt_str" input
    if [ -z "$input" ] && [ -n "$current" ]; then printf '%s\n' "$current"; return 0; fi
    if result="$(parse_and_validate_time "$input")"; then printf '%s\n' "$result"; return 0; fi
    echo "时间无效，请输入 0-23 小时或 HH:MM。"
  done
}

prompt_schedule_times() {
  local input out back parsed_out parsed_back
  while true; do
    read -r -p "请输入传送和传回时间（北京时间，例：18 2；也可写 18:00 02:00）${SWITCH_TIME:+ [当前: $SWITCH_TIME $RETURN_TIME]}：" input
    if [ -z "$input" ] && [ -n "${SWITCH_TIME:-}" ] && [ -n "${RETURN_TIME:-}" ]; then
      printf '%s %s\n' "$SWITCH_TIME" "$RETURN_TIME"
      return 0
    fi
    read -r out back _ <<< "$input"
    if [ -z "$out" ] || [ -z "$back" ]; then
      echo "请同时输入两个时间，例如：18 2。"
      continue
    fi
    if parsed_out="$(parse_and_validate_time "$out")" && parsed_back="$(parse_and_validate_time "$back")"; then
      printf '%s %s\n' "$parsed_out" "$parsed_back"
      return 0
    fi
    echo "时间无效，请输入 0-23 小时或 HH:MM，例如：18 2。"
  done
}

prompt_local_ip() {
  local ip_input port_input
  while true; do
    read -r -p "请输入 A 机公网 IPv4（传回时域名将指向此地址）${LOCAL_IP:+ [当前: $LOCAL_IP]}：" ip_input
    ip_input="${ip_input:-${LOCAL_IP:-}}"
    if valid_ipv4 "$ip_input"; then LOCAL_IP="$ip_input"; break; fi
    echo "A 机 IP 格式不正确。"
  done
  while true; do
    read -r -p "请输入 A 机 SSH 端口（B 机回传数据到此端口） [当前: ${LOCAL_SSH_PORT:-22}]：" port_input
    port_input="${port_input:-${LOCAL_SSH_PORT:-22}}"
    if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
      LOCAL_SSH_PORT="$port_input"
      return 0
    fi
    echo "端口号无效，请输入 1-65535 之间的数字。"
  done
}

prompt_cf_api() {
  local input_key input_email resp ok zone_id
  local has_saved=0
  if [ -n "${CF_TOKEN:-}" ]; then
    has_saved=1
  fi

  while true; do
    local api_prompt="请输入域名 API (Cloudflare API Token 或 Global API Key)"
    if [ "$has_saved" -eq 1 ]; then
      api_prompt+=" [当前已保存] (直接回车保持不变)"
    fi
    api_prompt+="："

    read -r -p "$api_prompt" input_key
    if [ -z "$input_key" ] && [ "$has_saved" -eq 1 ]; then
      echo "使用已保存的 Cloudflare API 认证配置。"
      return 0
    fi

    if [ -z "$input_key" ]; then
      echo "域名 API 密钥不能为空，请重新输入！"
      continue
    fi

    echo "正在自动识别并校验 API..."

    # 1. 尝试作为 API Token 校验 (Bearer Token)
    resp="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
      -H "Authorization: Bearer ${input_key}" \
      -H "Content-Type: application/json" 2>&1 || true)"
    ok="$(printf '%s' "$resp" | json_success)"

    if [ "$ok" = "1" ]; then
      echo "[OK] 自动识别为: Cloudflare API Token (校验通过)"
      CF_AUTH_TYPE="token"
      CF_TOKEN="$input_key"
      CF_EMAIL=""

      if [ -n "${DOMAIN:-}" ]; then
        echo "正在验证该 API 对域名 ${DOMAIN} 的访问权限..."
        if zone_id="$(find_zone_id "$DOMAIN" 2>/dev/null)"; then
          echo "[OK] 域名匹配成功，Zone ID: ${zone_id}"
        else
          echo "警告：API Token 校验通过，但未能找到域名 ${DOMAIN} 的有效 Zone。"
          echo "请确保该 Token 拥有域名所在 Zone 的 DNS 编辑权限。"
          read -r -p "是否仍然保存该 API？(y/n) [y]: " confirm_save
          confirm_save="${confirm_save:-y}"
          if [[ ! "$confirm_save" =~ ^[Yy]$ ]]; then
            echo "请重新输入域名 API！"
            continue
          fi
        fi
      fi
      return 0
    fi

    # 2. 未识别为 API Token，尝试作为 Global API Key，提示输入邮箱完成校验
    echo "未识别为有效 API Token，识别为 Global API Key。"
    while true; do
      local email_prompt="请输入关联的 Cloudflare 账号邮箱"
      if [ -n "${CF_EMAIL:-}" ]; then
        email_prompt+=" [当前记录: ${CF_EMAIL}] (直接回车保持不变)"
      fi
      email_prompt+="："

      read -r -p "$email_prompt" input_email
      if [ -z "$input_email" ] && [ -n "${CF_EMAIL:-}" ]; then
        input_email="$CF_EMAIL"
      fi

      if [ -z "$input_email" ]; then
        echo "账号邮箱不能为空！"
        continue
      fi
      break
    done

    echo "正在使用账号邮箱校验 Global API Key..."
    resp="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/user" \
      -H "X-Auth-Email: ${input_email}" \
      -H "X-Auth-Key: ${input_key}" \
      -H "Content-Type: application/json" 2>&1 || true)"
    ok="$(printf '%s' "$resp" | json_success)"

    if [ "$ok" = "1" ]; then
      echo "[OK] 自动识别为: Cloudflare Global API Key (账号校验通过)"
      CF_AUTH_TYPE="global_key"
      CF_TOKEN="$input_key"
      CF_EMAIL="$input_email"

      if [ -n "${DOMAIN:-}" ]; then
        echo "正在验证对域名 ${DOMAIN} 的访问权限..."
        if zone_id="$(find_zone_id "$DOMAIN" 2>/dev/null)"; then
          echo "[OK] 域名匹配成功，Zone ID: ${zone_id}"
        else
          echo "警告：Global API Key 校验通过，但未找到域名 ${DOMAIN} 的有效 Zone。"
          echo "请确保该域名已接入此 Cloudflare 账号。"
          read -r -p "是否仍然保存该 API？(y/n) [y]: " confirm_save
          confirm_save="${confirm_save:-y}"
          if [[ ! "$confirm_save" =~ ^[Yy]$ ]]; then
            echo "请重新输入域名 API！"
            continue
          fi
        fi
      fi
      return 0
    else
      local err_msg
      err_msg="$(printf '%s' "$resp" | json_errors)"
      echo "校验失败：${err_msg}"
      echo "API 或邮箱验证不通过，请重新输入！"
      echo
    fi
  done
}

prompt_target_ip_and_port() {
  local current_ip="${TARGET_IP:-}"
  local current_port="${TARGET_PORT:-22}"
  local ip_input port_input

  while true; do
    local ip_prompt="请输入目标 IP"
    if [ -n "$current_ip" ]; then
      ip_prompt+=" [当前记录: ${current_ip}] (直接回车保持不变)"
    else
      ip_prompt+=" (例 38.76.188.74)"
    fi
    ip_prompt+="："

    read -r -p "$ip_prompt" ip_input
    if [ -z "$ip_input" ] && [ -n "$current_ip" ]; then
      ip_input="$current_ip"
    fi

    if ! valid_ipv4 "$ip_input"; then
      echo "目标 IP 格式不正确，请输入有效的 IPv4 地址。"
      continue
    fi

    TARGET_IP="$ip_input"
    while true; do
      read -r -p "请输入 B 机 SSH 端口（传送和回传都会使用） [当前: ${current_port}]：" port_input
      port_input="${port_input:-$current_port}"
      if ! [[ "$port_input" =~ ^[0-9]+$ ]] || [ "$port_input" -lt 1 ] || [ "$port_input" -gt 65535 ]; then
        echo "端口号无效，请输入 1-65535 之间的数字。"
        continue
      fi
      echo "正在检测目标 ${TARGET_IP} 的 ${port_input} 端口..."
      if check_port "$TARGET_IP" "$port_input"; then
        echo "[OK] 目标 ${TARGET_IP}:${port_input} 连通正常。"
        TARGET_PORT="$port_input"
        return 0
      fi
      echo "警告：目标 ${TARGET_IP}:${port_input} 无法连通。"
      read -r -p "仍然使用此端口？(y 使用 / n 重输端口 / r 重输 IP) [n]：" retry_choice
      case "${retry_choice:-n}" in
        [Yy]) TARGET_PORT="$port_input"; return 0 ;;
        [Rr]) break ;;
      esac
    done
  done
}

setup_switch() {
  need_root
  require_base_cmds
  load_config_silent

  echo "=========================================="
  echo "        配置定时切换与数据同步"
  echo "=========================================="

  # A 机负责传送与传回两个定时动作。
  read -r SWITCH_TIME RETURN_TIME <<< "$(prompt_schedule_times)"

  # 2. 域名
  prompt_domain

  # 3. 域名 API (自动识别 Token / Global Key 及校验)
  prompt_cf_api

  # 4. 目标 IP 与端口检测匹配
  prompt_target_ip_and_port
  prompt_local_ip
  prompt_transfer_mode

  SSR_FILE="$DEFAULT_SSR_FILE"
  TIMELIMIT_FILE="$DEFAULT_TIMELIMIT_FILE"

  install_self
  write_config "1"
  install_cron "$SWITCH_TIME" "$RETURN_TIME"

  echo
  echo "=========================================="
  echo "设置完成！配置信息已保存至 ${CONFIG_PATH}"
  echo "每天北京时间 ${SWITCH_TIME}：同步 ${TRANSFER_MODE} 到 B (${TARGET_IP})、重启 B 上对应服务，再将域名 ${DOMAINS} 指向 B。"
  echo "每天北京时间 ${RETURN_TIME}：从 B 同步回 A (${LOCAL_IP})、重启 A 上对应服务，再将域名 ${DOMAINS} 指回 A。"
  echo
  echo "配置文件：$CONFIG_PATH"
  echo "执行脚本：$INSTALL_PATH"
  echo "日志文件：$LOG_PATH"
  echo "手动执行传送：$INSTALL_PATH --out；传回：$INSTALL_PATH --back（当前为 root 时直接运行）"
  echo "=========================================="

  setup_ssh_login || true
}

change_time() {
  need_root
  require_cmd crontab
  load_config_silent

  read -r SWITCH_TIME RETURN_TIME <<< "$(prompt_schedule_times)"

  install_self
  write_config "${TRANSFER_ENABLED:-1}"
  install_cron "$SWITCH_TIME" "$RETURN_TIME"

  echo "定时时间已修改：北京时间 ${SWITCH_TIME} 传送、${RETURN_TIME} 传回。"
  echo "当前任务：${INSTALL_PATH} --out 和 ${INSTALL_PATH} --back"
}

change_transfer_mode() {
  need_root
  require_cmd crontab
  load_config_silent
  if [ ! -f "$CONFIG_PATH" ] || [ -z "${SWITCH_TIME:-}" ] || [ -z "${RETURN_TIME:-}" ]; then
    echo "请先使用菜单 1 完成双向定时转移设置。"
    return 1
  fi
  prompt_transfer_mode
  install_self
  write_config "1"
  install_cron "$SWITCH_TIME" "$RETURN_TIME"
  echo "数据转移类型已修改为：${TRANSFER_MODE}。"
  echo "定时任务已按当前传送和传回时间重新部署。"
}

change_target_ip() {
  need_root
  load_config_silent
  if [ "${TRANSFER_ENABLED:-1}" = "1" ]; then
    require_cmd ssh
    require_cmd ssh-copy-id
    require_cmd ssh-keygen
  fi

  prompt_target_ip_and_port

  install_self
  write_config "${TRANSFER_ENABLED:-1}"

  echo "目标信息已修改为：${TARGET_IP} (SSH 端口: ${TARGET_PORT:-22})"
  echo "后续定时任务会将 ${DOMAINS:-$DOMAIN} 的 A 记录切换到 ${TARGET_IP}。"

  if [ "${TRANSFER_ENABLED:-1}" = "1" ]; then
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
  load_config_silent
  if [ -z "${DOMAIN:-}" ]; then
    echo "未找到有效配置，无需取消。"
    return 0
  fi
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
  load_config_silent

  echo "=========================================="
  echo "      定时切换服务器域名和 SSR 数据"
  echo "=========================================="
  if [ -n "${DOMAINS:-${DOMAIN:-}}" ] && [ -n "${TARGET_IP:-}" ]; then
    echo "【当前配置记录】"
    echo "  • 切换域名: ${DOMAINS:-$DOMAIN}"
    echo "  • 目标地址: ${TARGET_IP} (SSH 端口: ${TARGET_PORT:-22})"
    echo "  • 传送时间: 每天 ${SWITCH_TIME:-未设置}（北京时间）"
    echo "  • 传回时间: 每天 ${RETURN_TIME:-未设置}（北京时间）"
    echo "  • A 机地址: ${LOCAL_IP:-未设置}"
    if [ "${CF_AUTH_TYPE:-token}" = "global_key" ]; then
      echo "  • 认证方式: Global API Key (${CF_EMAIL})"
    else
      echo "  • 认证方式: API Token"
    fi
    echo "  • 数据同步: ${TRANSFER_MODE:-ssr}"
    echo "  • 定时任务: $(check_cron_status)"
  else
    echo "【当前配置记录】暂无保存的配置记录"
  fi
  echo "=========================================="
  echo "1、设置定时切换域名和数据"
  echo "2、取消转移数据设置"
  echo "3、取消所有所有设置"
  echo "4、修改定时时间"
  echo "5、修改目标 IP 及端口"
  echo "6、升级脚本设置不变"
  echo "7、修改转移数据"
  echo "0、退出"
  echo
  read -r -p "请输入选项 [0-7]：" choice

  case "$choice" in
    1) setup_switch ;;
    2) disable_transfer ;;
    3) cancel_all ;;
    4) change_time ;;
    5) change_target_ip ;;
    6) upgrade_script_only ;;
    7) change_transfer_mode ;;
    0) exit 0 ;;
    *) echo "无效选项。" && exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --run|--out)
      run_job out
      ;;
    --back)
      run_job back
      ;;
    *)
      show_menu
      ;;
  esac
fi
