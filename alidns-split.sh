#!/usr/bin/env bash
# Create/remove cron jobs that enable and disable an Alibaba Cloud DNS record.
# 修复版（2026-09-30）：make_job_script 生成任务时写死 aliyun 绝对路径，
# 不再依赖 cron 的最小 PATH（旧逻辑在 cron 下找不到 /usr/local/bin/aliyun
# 会静默 exit 127）；小时参数兼容前导零（如 06）；任务脚本内固定 LC_ALL=C
# 以消除 cron 日志中的 setlocale 警告。
set -euo pipefail

APP_NAME="alidns-split"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/alidns-split"
CONFIG_FILE="$CONFIG_DIR/config"
DOMAINS_DIR="$CONFIG_DIR/domains"
CRON_TAG="# alidns-split managed"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先安装。"; }

ensure_aliyun() {
  if command -v aliyun >/dev/null 2>&1; then
    return
  fi
  printf '本机未检测到 aliyun CLI，正在通过阿里云官方安装脚本安装……\n'
  need_cmd curl
  case "$(uname -s)" in
    Linux|Darwin) ;;
    *) die '自动安装仅支持 Linux/macOS，请按阿里云 CLI 官方文档手动安装。' ;;
  esac
  curl -fsSL https://aliyuncli.alicdn.com/install.sh | bash || die '阿里云 CLI 安装失败。请检查网络和安装权限后重试。'
  export PATH="$PATH:/usr/local/bin"
  command -v aliyun >/dev/null 2>&1 || die '安装脚本已运行，但 PATH 中仍找不到 aliyun。请确认安装目录并重新运行。'
}

read_input() {
  local prompt="$1" value
  printf '%s' "$prompt" >&2
  IFS= read -r value || true
  printf '%s' "$value"
}

read_json_block() {
  local prompt="$1" line input='' depth=0 started=0
  printf '%s' "$prompt" >&2
  while IFS= read -r line; do
    [[ -n "$input" ]] && input+=$'\n'
    input+="$line"
    if [[ "$line" == *'{'* ]]; then started=1; fi
    if (( started )); then
      local opens closes
      opens="$(grep -o '{' <<<"$line" | wc -l)"
      closes="$(grep -o '}' <<<"$line" | wc -l)"
      depth=$((depth + opens - closes))
      (( depth <= 0 )) && break
    else
      break
    fi
  done
  printf '%s' "$input"
}

check_time() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,2}$ ]] && ((10#$value <= 23))
}

read_hour() {
  local prompt="$1" value
  while true; do
    value="$(read_input "$prompt")"
    if check_time "$value"; then
      # Normalize values such as 02 so Bash arithmetic and cron both receive 2.
      printf '%d' "$((10#$value))"
      return 0
    fi
    printf '请输入 0 到 23 之间的小时数（例如 02 或 2）。\n' >&2
  done
}

extract_json_field() {
  local input="$1" field="$2"
  python3 -c 'import json,sys
def find(x,key):
 if isinstance(x,dict):
  for k,v in x.items():
   if k.lower()==key.lower() and v not in (None, ""): return str(v)
   result=find(v,key)
   if result: return result
 elif isinstance(x,list):
  for v in x:
   result=find(v,key)
   if result: return result
 return ""
try:
 data=json.loads(sys.stdin.read())
 print(find(data,sys.argv[1]))
except Exception:
 import re
 match=re.search(r"[\"\x27]?"+re.escape(sys.argv[1])+r"[\"\x27]?\s*:\s*[\"\x27]?([^,\"\x27}\s]+)",sys.stdin.getvalue() if hasattr(sys.stdin,"getvalue") else "")
 print(match.group(1) if match else "")' "$field" <<<"$input"
}

parse_records() {
  python3 -c 'import json,sys
try:
 d=json.loads(sys.stdin.read())
 def find(x,key):
  if isinstance(x,dict):
   if key in x: return x[key]
   for v in x.values():
    r=find(v,key)
    if r is not None: return r
  elif isinstance(x,list):
   for v in x:
    r=find(v,key)
    if r is not None: return r
  return None
 records=find(d,"Record")
 if records is None:
  one=find(d,"RecordId")
  records=[d] if one is not None else []
 if isinstance(records,dict): records=[records]
 for r in records:
  print("\t".join(str(r.get(k,"" )).replace("\t"," ").replace("\n"," ") for k in ("RecordId","DomainName","RR","Type","Value","Status","Line")))
except Exception:
 import re
 s=sys.stdin.read()
 m=re.search(r"[\"\x27]?RecordId[\"\x27]?\s*:\s*[\"\x27]?([^,\"\x27}\s]+)",s)
 if m: print(m.group(1)+"\t\t\t\t\t\t")' <<<"$1"
}

make_job_script() {
  local action="$1" path aliyun_bin
  # 修复：在生成任务时就解析 aliyun 绝对路径并写死，不再依赖 cron 的最小 PATH。
  # cron 下 PATH 常为 /usr/bin:/bin，而 aliyun 默认装在 /usr/local/bin，
  # 旧逻辑用 command -v 查找失败会静默 exit 127，导致定时任务永远不执行。
  aliyun_bin="$(command -v aliyun)"
  [[ -n "$aliyun_bin" && -x "$aliyun_bin" ]] || die "找不到 aliyun 可执行文件，请先安装阿里云 CLI。"
  path="$CONFIG_DIR/$action.sh"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -eu
export LC_ALL=C LANG=C
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
config_file="\${1:?用法: $action.sh 配置文件}"
target_hour="\${2:?缺少目标小时}"
# 修复：先去掉前导零再校验，兼容 06 / 6 / 006 等写法（旧正则会把 "06" 判为非法而 exit 2）
target_hour="\$((10#\$target_hour))"
[[ "\$target_hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { echo "无效的小时参数: \${2}" >&2; exit 2; }
[[ "\$(TZ=Asia/Shanghai date +%H)" == "\$(printf '%02d' "\$target_hour")" ]] || exit 0
source "\$config_file"
exec "$aliyun_bin" alidns SetDomainRecordStatus --RecordId "\$RECORD_ID" --Status "$action" --access-key-id "\$ACCESS_KEY_ID" --access-key-secret "\$ACCESS_KEY_SECRET" --region "cn-hangzhou" --endpoint "alidns.aliyuncs.com"
EOF
  chmod 700 "$path"
}

remove_managed_cron() {
  local current
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk -v tag="$CRON_TAG" 'index($0,tag)==0 && $0!=""' | crontab -
}

domain_key() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
}

# 列出所有已保存的域名，返回 0 表示有数据；通过全局数组 ALL_CONF_FILES 输出
list_saved_domains() {
  local -a files=()
  local f
  shopt -s nullglob
  files=("$DOMAINS_DIR"/*.conf)
  shopt -u nullglob
  ALL_CONF_FILES=()
  ((${#files[@]})) || return 1
  for f in "${files[@]}"; do
    ALL_CONF_FILES+=("$f")
  done
  return 0
}

# 打印已有域名列表（带序号），供各菜单复用
print_domain_list() {
  local f name i=1
  for f in "${ALL_CONF_FILES[@]}"; do
    name="$(awk -F= '/^DOMAIN_NAME=/{sub(/^[^=]*=/,""); gsub(/^\047|\047$/,"",$0); print; exit}' "$f")"
    printf '%d) %s\n' "$i" "$name"
    i=$((i+1))
  done
}

# 根据序号选择已有域名配置，成功返回 0 并设置 SELECTED_CONFIG
choose_domain_by_index() {
  local choice
  while true; do
    choice="$(read_input '选择序号> ')"
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#ALL_CONF_FILES[@]})) || { printf '序号无效，请输入 1 到 %d。\n' "${#ALL_CONF_FILES[@]}" >&2; continue; }
    SELECTED_CONFIG="${ALL_CONF_FILES[$((choice-1))]}"
    return 0
  done
}

choose_saved_domain() {
  local choice
  list_saved_domains || true
  if ((${#ALL_CONF_FILES[@]})); then
    printf '\n已有域名数据：\n'
    print_domain_list
    printf '%d) 输入新域名数据\n' "$(( ${#ALL_CONF_FILES[@]} + 1 ))"
    while true; do
      choice="$(read_input '选择序号> ')"
      [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#ALL_CONF_FILES[@]}+1)) || { printf '序号无效。\n' >&2; continue; }
      if (( choice <= ${#ALL_CONF_FILES[@]} )); then SELECTED_CONFIG="${ALL_CONF_FILES[$((choice-1))]}"; return 0; fi
      return 1
    done
  else
    return 1
  fi
}

create_task() {
  need_cmd python3
  ensure_aliyun
  need_cmd crontab
  mkdir -p "$DOMAINS_DIR"
  chmod 700 "$CONFIG_DIR" "$DOMAINS_DIR"
  local key_id key_secret pasted req_id record_id domain ip on_hour off_hour tz choice key config
  if choose_saved_domain; then
    config="$SELECTED_CONFIG"
    source "$config"
    record_id="$RECORD_ID"; domain="$DOMAIN_NAME"; ip="$RECORD_VALUE"
    printf '\n已选择 %s（RecordId: %s），直接设置启停时间即可。\n' "$domain" "$record_id"
  else
  printf '\n请输入阿里云 AccessKey（支持直接粘贴两行：\n  accessKeyId LTAI5t...\n  accessKeySecret YHkOX...\n回车即可自动识别）：\n'
  key_id="$(read_input 'AccessKeyId> ')"
  # 支持粘贴 "accessKeyId LTAI5t..." 整行，自动提取 key
  key_id="$(sed -E 's/^[[:space:]]*(accessKeyId|access_key_id|AccessKeyId)[[:space:]]+//i' <<<"$key_id")"
  key_id="${key_id%%$'\n'*}"
  key_id="$(sed -E 's/[[:space:]]+$//' <<<"$key_id")"
  [[ -n "$key_id" ]] || die 'AccessKeyId 不能为空。'
  key_secret="$(read_input 'AccessKeySecret> ')"
  key_secret="$(sed -E 's/^[[:space:]]*(accessKeySecret|access_key_secret|AccessKeySecret)[[:space:]]+//i' <<<"$key_secret")"
  key_secret="${key_secret%%$'\n'*}"
  key_secret="$(sed -E 's/[[:space:]]+$//' <<<"$key_secret")"
  [[ -n "$key_secret" ]] || die 'AccessKeySecret 不能为空。'
  printf '\n请粘贴完整 JSON 响应（支持多行，粘贴完会自动识别结束）：\n'
  pasted="$(read_json_block 'JSON> ')"
  req_id="$(extract_json_field "$pasted" RequestId)"
  [[ -n "$req_id" ]] || req_id="$(extract_json_field "$pasted" x-acs-request-id)"
  [[ -n "$req_id" ]] || req_id="$pasted"
  local -a records
  mapfile -t records < <(parse_records "$pasted")
  ((${#records[@]} > 0)) || die '没有识别到 RecordId。RequestId/x-acs-request-id 只是请求追踪编号，请粘贴包含 DNS 记录信息的完整 JSON。'
  if ((${#records[@]} > 1)); then
    printf '\n找到多条 DNS 记录，请选择要启停的记录：\n'
    local i
    for i in "${!records[@]}"; do
      IFS=$'\t' read -r record_id domain rr type ip status line <<<"${records[$i]}"
      printf '%d) %s  %s.%s  %s  %s  当前状态=%s  线路=%s\n' "$((i+1))" "$record_id" "$rr" "$domain" "$type" "$ip" "$status" "$line"
    done
    choice="$(read_input '选择记录序号> ')"
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#records[@]})) || die '记录序号无效。'
    IFS=$'\t' read -r record_id domain rr type ip status line <<<"${records[$((choice-1))]}"
  else
    IFS=$'\t' read -r record_id domain rr type ip status line <<<"${records[0]}"
  fi
  printf '\n识别到：\n  RequestId: %s\n  RecordId: %s\n  域名: %s\n  主机记录: %s\n  类型: %s\n  记录值/IP: %s\n  当前状态: %s\n\n' "$req_id" "$record_id" "${domain:-（未提供）}" "${rr:-（未提供）}" "${type:-（未提供）}" "${ip:-（未提供）}" "${status:-（未提供）}"

  umask 077
  key="$(domain_key "$domain")"
  config="$DOMAINS_DIR/$key.conf"
  cat >"$config" <<EOF
ACCESS_KEY_ID=$(printf '%q' "$key_id")
ACCESS_KEY_SECRET=$(printf '%q' "$key_secret")
RECORD_ID=$(printf '%q' "$record_id")
DOMAIN_NAME=$(printf '%q' "$domain")
RECORD_VALUE=$(printf '%q' "$ip")
REQUEST_ID=$(printf '%q' "$req_id")
EOF
  chmod 600 "$config"
  fi

  local local_tz beijing_time
  local_tz="$(date '+%Z %z')"
  beijing_time="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z %z')"
  printf '本机时间：%s\n北京时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z %z')" "$beijing_time"
  if [[ "$(date '+%z')" != '+0800' ]]; then
    printf '本机时区与北京时间不一致；脚本会每小时检查一次北京时间，并只在设定小时执行。\n'
  else
    printf '本机时区与北京时间一致。\n'
  fi
  on_hour="$(read_hour '输入开启小时（0-23）> ')"
  while true; do
    off_hour="$(read_hour '输入关闭小时（0-23）> ')"
    [[ "$on_hour" != "$off_hour" ]] && break
    printf '开启和关闭时间不能相同，请重新输入关闭时间。\n'
  done

  make_job_script Enable
  make_job_script Disable

  {
    crontab -l 2>/dev/null | awk -v tag="$CRON_TAG" -v conf="$config" 'index($0,tag)==0 || index($0,conf)==0' || true
    printf '0 * * * * TZ=Asia/Shanghai %s/Enable.sh %s %s >> %s/%s.log 2>&1 %s\n' "$CONFIG_DIR" "$config" "$on_hour" "$CONFIG_DIR" "${config##*/}" "$CRON_TAG"
    printf '0 * * * * TZ=Asia/Shanghai %s/Disable.sh %s %s >> %s/%s.log 2>&1 %s\n' "$CONFIG_DIR" "$config" "$off_hour" "$CONFIG_DIR" "${config##*/}" "$CRON_TAG"
  } | crontab -
  printf '\n任务创建完成：%s 每天北京时间 %02d:00 开启、%02d:00 关闭。配置保存在 %s（权限 600），运行日志在 %s/%s.log。\n' "$domain" "$on_hour" "$off_hour" "$config" "$CONFIG_DIR" "${config##*/}"
}

delete_task() {
  need_cmd crontab
  list_saved_domains || true
  if ((${#ALL_CONF_FILES[@]} == 0)); then
    printf '没有已保存的域名数据。\n'
    return
  fi
  printf '\n已有域名数据：\n'
  print_domain_list
  choose_domain_by_index
  local name
  name="$(awk -F= '/^DOMAIN_NAME=/{sub(/^[^=]*=/,""); gsub(/^\047|\047$/,"",$0); print; exit}' "$SELECTED_CONFIG")"
  printf '确认删除 %s 的启停任务？(y/N) ' "$name" >&2
  local confirm
  IFS= read -r confirm || true
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf '已取消。\n'; return; }
  # 从 crontab 中移除该域名的任务行
  local config_name
  config_name="${SELECTED_CONFIG##*/}"
  local current
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk -v conf="$config_name" 'index($0,conf)==0' | crontab -
  rm -f "$SELECTED_CONFIG"
  # 如果没有任何域名配置了，清理公共脚本
  list_saved_domains || true
  if ((${#ALL_CONF_FILES[@]} == 0)); then
    rm -f "$CONFIG_DIR/Enable.sh" "$CONFIG_DIR/Disable.sh" "$CONFIG_FILE"
    rmdir "$DOMAINS_DIR" 2>/dev/null || true
    rmdir "$CONFIG_DIR" 2>/dev/null || true
  fi
  printf '已删除 %s 的启停任务。\n' "$name"
}

modify_task() {
  need_cmd crontab
  list_saved_domains || true
  if ((${#ALL_CONF_FILES[@]} == 0)); then
    printf '没有已保存的域名数据，请先创建任务。\n'
    return
  fi
  printf '\n已有域名数据：\n'
  print_domain_list
  choose_domain_by_index
  local name
  name="$(awk -F= '/^DOMAIN_NAME=/{sub(/^[^=]*=/,""); gsub(/^\047|\047$/,"",$0); print; exit}' "$SELECTED_CONFIG")"
  printf '\n修改 %s 的启停时间：\n' "$name"
  local on_hour off_hour
  on_hour="$(read_hour '输入开启小时（0-23）> ')"
  while true; do
    off_hour="$(read_hour '输入关闭小时（0-23）> ')"
    [[ "$on_hour" != "$off_hour" ]] && break
    printf '开启和关闭时间不能相同，请重新输入关闭时间。\n'
  done
  local config
  config="$SELECTED_CONFIG"
  local config_name
  config_name="${config##*/}"
  # 移除该域名的旧 cron 行，再按新时间写入
  local current
  current="$(crontab -l 2>/dev/null || true)"
  {
    printf '%s\n' "$current" | awk -v tag="$CRON_TAG" -v conf="$config_name" 'index($0,tag)==0 || index($0,conf)==0'
    printf '0 * * * * TZ=Asia/Shanghai %s/Enable.sh %s %s >> %s/%s.log 2>&1 %s\n' "$CONFIG_DIR" "$config" "$on_hour" "$CONFIG_DIR" "$config_name" "$CRON_TAG"
    printf '0 * * * * TZ=Asia/Shanghai %s/Disable.sh %s %s >> %s/%s.log 2>&1 %s\n' "$CONFIG_DIR" "$config" "$off_hour" "$CONFIG_DIR" "$config_name" "$CRON_TAG"
  } | crontab -
  printf '\n已修改 %s：每天北京时间 %02d:00 开启、%02d:00 关闭。\n' "$name" "$on_hour" "$off_hour"
}

list_tasks() {
  list_saved_domains || true
  if ((${#ALL_CONF_FILES[@]} == 0)); then
    printf '当前没有任何启停任务。\n'
    return
  fi
  local current name on_line off_line on_h off_h f
  current="$(crontab -l 2>/dev/null || true)"
  printf '\n当前已配置的启停任务：\n'
  for f in "${ALL_CONF_FILES[@]}"; do
    name="$(awk -F= '/^DOMAIN_NAME=/{sub(/^[^=]*=/,""); gsub(/^\047|\047$/,"",$0); print; exit}' "$f")"
    on_line="$(printf '%s\n' "$current" | grep -F "$f" | grep -F 'Enable.sh' || true)"
    off_line="$(printf '%s\n' "$current" | grep -F "$f" | grep -F 'Disable.sh' || true)"
    on_h="$(printf '%s' "$on_line" | awk '{print $(NF-2)}')"
    off_h="$(printf '%s' "$off_line" | awk '{print $(NF-2)}')"
    printf '  %s：每天北京时间 %s:00 开启、%s:00 关闭（配置：%s）\n' \
      "$name" "${on_h:-?}" "${off_h:-?}" "$f"
  done
}

main() {
  local choice
  while true; do
    printf '\n========== 阿里 DNS 分流启停管理 ==========\n1、创建启停任务\n2、删除任务\n3、修改任务时间\n4、查看任务\n0、退出\n'
    choice="$(read_input '请选择> ')"
    case "$choice" in
      1) create_task ;;
      2) delete_task ;;
      3) modify_task ;;
      4) list_tasks ;;
      0) printf '再见。\n'; return 0 ;;
      *) printf '无效选项，请输入 0-4。\n' >&2 ;;
    esac
  done
}
main "$@"
