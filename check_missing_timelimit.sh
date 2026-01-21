#!/bin/bash
set -euo pipefail

# Find ports that exist in mudb.json but are missing from timelimit.db.
# Optional: delete those ports from mudb.json via mujson_mgr.py.

mudb_path="${1:-/usr/local/shadowsocksr/mudb.json}"
timedb_path="${2:-/usr/local/SSR-Bash-Python/timelimit.db}"

if [[ ! -f "$mudb_path" ]]; then
  echo "Missing mudb.json: $mudb_path" >&2
  exit 1
fi

if [[ ! -f "$timedb_path" ]]; then
  echo "Missing timelimit.db: $timedb_path" >&2
  exit 1
fi

mapfile -t missing_ports < <(comm -23 \
  <(python3 - "$mudb_path" <<'PY' | sort -u
import json
import sys

path = sys.argv[1]
with open(path, "r") as f:
    data = json.load(f)

for item in data:
    port = item.get("port")
    if port is not None:
        print(str(port))
PY
  ) \
  <(awk -F: 'NF { print $1 }' "$timedb_path" | sort -u))

printf "%s\n" "${missing_ports[@]}"

delete_missing_ports() {
  if [[ "${#missing_ports[@]}" -eq 0 ]]; then
    return 0
  fi
  mujson_dir="/usr/local/shadowsocksr"
  mujson_mgr="${mujson_dir}/mujson_mgr.py"
  if [[ ! -f "$mujson_mgr" ]]; then
    echo "Missing mujson_mgr.py: $mujson_mgr" >&2
    exit 1
  fi
  cd "$mujson_dir"
  for port in "${missing_ports[@]}"; do
    python mujson_mgr.py -d -p "$port" >/dev/null 2>&1
  done
}

show_menu() {
  echo "1) 查找遗漏端口"
  echo "2) 删除遗漏端口"
  echo "0) 退出"
  read -r -p "请选择: " choice
  case "$choice" in
    1)
      ;;
    2)
      delete_missing_ports
      ;;
    0)
      exit 0
      ;;
    *)
      echo "无效选项"
      exit 1
      ;;
  esac
}

if [[ "${1:-}" == "--menu" || "${1:-}" == "-m" || "${#}" -eq 0 ]]; then
  show_menu
fi
