#!/usr/bin/env bash
# Create/remove cron jobs that enable and disable an Alibaba Cloud DNS record.
set -euo pipefail

APP_NAME="alidns-split"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/alidns-split"
CONFIG_FILE="$CONFIG_DIR/config"
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
  local action="$1" path
  path="$CONFIG_DIR/$action.sh"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -eu
source "$CONFIG_FILE"
exec aliyun alidns SetDomainRecordStatus --RecordId "\$RECORD_ID" --Status "$action" --access-key-id "\$ACCESS_KEY_ID" --access-key-secret "\$ACCESS_KEY_SECRET" --region "cn-hangzhou" --endpoint "https://alidns.aliyuncs.com"
EOF
  chmod 700 "$path"
}

remove_managed_cron() {
  local current
  current="$(crontab -l 2>/dev/null || true)"
  printf '%s\n' "$current" | awk -v tag="$CRON_TAG" 'index($0,tag)==0 && $0!=""' | crontab -
}

create_task() {
  need_cmd python3
  ensure_aliyun
  need_cmd crontab
  printf '\n请输入阿里云 AccessKeyId：\n'
  local key_id key_secret pasted req_id record_id domain ip on_hour off_hour tz choice
  key_id="$(read_input 'AccessKeyId> ')"
  [[ "$key_id" == *' '* ]] && key_id="${key_id##* }"
  [[ -n "$key_id" ]] || die 'AccessKeyId 不能为空。'
  key_secret="$(read_input 'AccessKeySecret> ')"
  [[ "$key_secret" == *' '* ]] && key_secret="${key_secret##* }"
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

  local local_tz beijing_time
  local_tz="$(date '+%Z %z')"
  beijing_time="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %Z %z')"
  printf '本机时间：%s\n北京时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z %z')" "$beijing_time"
  if [[ "$(date '+%z')" != '+0800' ]]; then
    printf '本机时区与北京时间不一致，任务将按北京时间写入 cron（无需修改系统时区）。\n'
  else
    printf '本机时区与北京时间一致。\n'
  fi
  on_hour="$(read_hour '输入开启小时（0-23）> ')"
  while true; do
    off_hour="$(read_hour '输入关闭小时（0-23）> ')"
    [[ "$on_hour" != "$off_hour" ]] && break
    printf '开启和关闭时间不能相同，请重新输入关闭时间。\n'
  done

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  umask 077
  cat >"$CONFIG_FILE" <<EOF
ACCESS_KEY_ID=$(printf '%q' "$key_id")
ACCESS_KEY_SECRET=$(printf '%q' "$key_secret")
RECORD_ID=$(printf '%q' "$record_id")
DOMAIN_NAME=$(printf '%q' "$domain")
RECORD_VALUE=$(printf '%q' "$ip")
REQUEST_ID=$(printf '%q' "$req_id")
EOF
  chmod 600 "$CONFIG_FILE"
  make_job_script Enable
  make_job_script Disable

  remove_managed_cron
  {
    crontab -l 2>/dev/null || true
    printf '0 %s * * * TZ=Asia/Shanghai %s/Enable.sh %s\n' "$on_hour" "$CONFIG_DIR" "$CRON_TAG"
    printf '0 %s * * * TZ=Asia/Shanghai %s/Disable.sh %s\n' "$off_hour" "$CONFIG_DIR" "$CRON_TAG"
  } | crontab -
  printf '\n任务创建完成：每天北京时间 %02d:00 开启、%02d:00 关闭。配置保存在 %s（权限 600）。\n' "$on_hour" "$off_hour" "$CONFIG_FILE"
}

delete_task() {
  need_cmd crontab
  remove_managed_cron
  rm -f "$CONFIG_DIR/Enable.sh" "$CONFIG_DIR/Disable.sh" "$CONFIG_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  printf '已删除阿里 DNS 分流定时任务及本地配置。\n'
}

main() {
  printf '\n阿里 DNS 分流启停\n1、创建启停任务\n2、删除任务\n'
  local choice
  choice="$(read_input '请选择> ')"
  case "$choice" in
    1) create_task ;;
    2) delete_task ;;
    *) die '请选择 1 或 2。' ;;
  esac
}
main "$@"
