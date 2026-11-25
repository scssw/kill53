#!/usr/bin/env bash
set -euo pipefail

ACME="$HOME/.acme.sh/acme.sh"

PAUSED_KEYS=()
PAUSED_LABELS=()
PAUSED_START_CMDS=()
RESUMED=0

is_key_paused() {
  local needle="$1"
  local k
  if [ "${#PAUSED_KEYS[@]}" -gt 0 ]; then
    for k in "${PAUSED_KEYS[@]}"; do
      if [ "$k" = "$needle" ]; then
        return 0
      fi
    done
  fi
  return 1
}

record_paused_item() {
  local key="$1"
  local label="$2"
  local start_cmd="$3"
  if is_key_paused "$key"; then
    return 1
  fi
  PAUSED_KEYS+=("$key")
  PAUSED_LABELS+=("$label")
  PAUSED_START_CMDS+=("$start_cmd")
  return 0
}

print_paused_start_commands() {
  local i
  if [ "${#PAUSED_START_CMDS[@]}" -eq 0 ]; then
    return 0
  fi
  for i in "${!PAUSED_START_CMDS[@]}"; do
    echo "  - [${PAUSED_LABELS[$i]}] ${PAUSED_START_CMDS[$i]}"
  done
}

resume_paused_services() {
  local i label cmd
  if [ "${#PAUSED_START_CMDS[@]}" -eq 0 ] || [ "$RESUMED" -eq 1 ]; then
    return 0
  fi

  echo ""
  echo "Restarting previously paused service(s)..."
  for i in "${!PAUSED_START_CMDS[@]}"; do
    label="${PAUSED_LABELS[$i]}"
    cmd="${PAUSED_START_CMDS[$i]}"
    echo "Starting $label: $cmd"
    if eval "$cmd"; then
      echo "Started $label successfully."
    else
      echo "[WARN] Failed to start $label. Start manually with: $cmd"
    fi
  done
  RESUMED=1
}

cleanup_on_signal() {
  if [ "${#PAUSED_START_CMDS[@]}" -gt 0 ] && [ "$RESUMED" -eq 0 ]; then
    echo ""
    echo "[WARN] Script interrupted. The following paused service(s) were NOT automatically started:"
    print_paused_start_commands
  fi
  exit 130
}

trap cleanup_on_signal INT TERM

is_port80_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '!/^State/ && $4 ~ /:80$/ { found=1 } END { exit !found }'
    return $?
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1
    return $?
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '/^tcp/ && $4 ~ /:80$/ { found=1 } END { exit !found }'
    return $?
  else
    awk '$2 ~ /:0050$/ && $4 == "0A" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
    return $?
  fi
}

show_port80_listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /:80$/' || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk '/^(Proto|tcp)/ && ($4 ~ /:80$/ || NR <= 2)' || true
  fi
}

get_port80_pids() {
  local pids=""
  if command -v ss >/dev/null 2>&1; then
    pids="$(ss -ltnp 2>/dev/null | awk '!/^State/ && $4 ~ /:80$/ { print }' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  fi
  if [ -z "$pids" ] && command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -t -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  fi
  if [ -z "$pids" ] && command -v netstat >/dev/null 2>&1; then
    pids="$(netstat -ltnp 2>/dev/null | awk '/^tcp/ && $4 ~ /:80$/ { print $7 }' | grep -oE '^[0-9]+' | sort -u || true)"
  fi
  printf '%s\n' "$pids"
}

stop_docker_container() {
  local cname="$1"
  local q_cname start_cmd
  if is_key_paused "docker:$cname"; then
    return 0
  fi
  printf -v q_cname '%q' "$cname"
  start_cmd="docker start $q_cname"
  echo "Pausing Docker container: $cname"
  if docker stop "$cname" >/dev/null; then
    record_paused_item "docker:$cname" "docker:$cname" "$start_cmd" || true
    return 0
  fi
  echo "[WARN] Failed to stop Docker container: $cname"
  return 1
}

stop_systemd_unit() {
  local unit="$1"
  local q_unit start_cmd
  if is_key_paused "systemd:$unit"; then
    return 0
  fi
  printf -v q_unit '%q' "$unit"
  start_cmd="systemctl start $q_unit"
  echo "Pausing systemd service: $unit"
  if systemctl stop "$unit"; then
    record_paused_item "systemd:$unit" "systemd:$unit" "$start_cmd" || true
    return 0
  fi
  echo "[WARN] Failed to stop systemd service: $unit"
  return 1
}

stop_init_service() {
  local svc="$1"
  local q_svc start_cmd
  if command -v rc-service >/dev/null 2>&1 && rc-service "$svc" status >/dev/null 2>&1; then
    if is_key_paused "rc:$svc"; then
      return 0
    fi
    printf -v q_svc '%q' "$svc"
    start_cmd="rc-service $q_svc start"
    echo "Pausing OpenRC service: $svc"
    if rc-service "$svc" stop; then
      record_paused_item "rc:$svc" "openrc:$svc" "$start_cmd" || true
      return 0
    fi
  elif command -v service >/dev/null 2>&1 && service "$svc" status >/dev/null 2>&1; then
    if is_key_paused "sysv:$svc"; then
      return 0
    fi
    printf -v q_svc '%q' "$svc"
    start_cmd="service $q_svc start"
    echo "Pausing service: $svc"
    if service "$svc" stop; then
      record_paused_item "sysv:$svc" "service:$svc" "$start_cmd" || true
      return 0
    fi
  fi
  return 1
}

get_systemd_unit_for_pid() {
  local pid="$1"
  local unit=""
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  unit="$(ps -p "$pid" -o unit= 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$unit" ] || [ "$unit" = "-" ] || [[ "$unit" != *.service ]] || [[ "$unit" == user@* ]]; then
    if [ -r "/proc/$pid/cgroup" ]; then
      unit="$(grep -oE '[^/]+\.service' "/proc/$pid/cgroup" 2>/dev/null | grep -v '^user@' | head -n1 || true)"
    else
      unit=""
    fi
  fi

  if [ -n "$unit" ] && [[ "$unit" == *.service ]] && [[ "$unit" != user@* ]]; then
    if systemctl is-active --quiet "$unit"; then
      printf '%s\n' "$unit"
      return 0
    fi
  fi
  return 1
}

find_root_pid() {
  local cur="$1"
  local target_comm="$2"
  local ppid="" pcomm=""
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    ppid="$(ps -p "$cur" -o ppid= 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$ppid" ] || [ "$ppid" -le 1 ] 2>/dev/null; then
      break
    fi
    pcomm="$(ps -p "$ppid" -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "$pcomm" = "$target_comm" ]; then
      cur="$ppid"
    else
      break
    fi
  done
  printf '%s\n' "$cur"
}

build_standalone_start_cmd() {
  local pid="$1"
  local comm="$2"
  local exe="" cwd="" arg="" skip_next=0
  local -a raw_args=()
  local -a cmd_args=()
  local quoted_cmd="" q_cwd="" stripped=""

  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  if [[ "$exe" == *" (deleted)" ]]; then
    exe=""
  fi
  cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"

  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' arg; do
      raw_args+=("$arg")
    done < "/proc/$pid/cmdline"
  fi

  if [ "${#raw_args[@]}" -eq 0 ]; then
    if [ -n "$exe" ] && [ -x "$exe" ]; then
      cmd_args=("$exe")
    elif [ -n "$comm" ]; then
      cmd_args=("$comm")
    else
      return 1
    fi
  elif [[ "${raw_args[0]}" == "nginx: master process "* ]]; then
    stripped="${raw_args[0]#nginx: master process }"
    read -r -a cmd_args <<< "$stripped"
    if [ -n "$exe" ] && [ -x "$exe" ] && [ "${#cmd_args[@]}" -gt 0 ]; then
      cmd_args[0]="$exe"
    fi
  else
    for arg in "${raw_args[@]}"; do
      if [ "$skip_next" -eq 1 ]; then
        skip_next=0
        continue
      fi
      if [ "$comm" = "caddy" ] && [ "$arg" = "--pingback" ]; then
        skip_next=1
        continue
      fi
      cmd_args+=("$arg")
    done
    if [ -n "$exe" ] && [ -x "$exe" ] && [ "${#cmd_args[@]}" -gt 0 ]; then
      cmd_args[0]="$exe"
    fi
  fi

  printf -v quoted_cmd '%q ' "${cmd_args[@]}"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    printf -v q_cwd '%q' "$cwd"
    printf '( cd %s && nohup %s>/dev/null 2>&1 & )\n' "$q_cwd" "$quoted_cmd"
  else
    printf 'nohup %s>/dev/null 2>&1 &\n' "$quoted_cmd"
  fi
}

stop_standalone_process() {
  local pid="$1"
  local comm="$2"
  local root_pid exe start_cmd stopped=0

  root_pid="$(find_root_pid "$pid" "$comm")"
  if is_key_paused "proc:$root_pid"; then
    return 0
  fi

  exe="$(readlink -f "/proc/$root_pid/exe" 2>/dev/null || true)"
  if [[ "$exe" == *" (deleted)" ]]; then
    exe=""
  fi
  start_cmd="$(build_standalone_start_cmd "$root_pid" "$comm" || true)"
  if [ -z "$start_cmd" ]; then
    return 1
  fi

  echo "Pausing standalone process: $comm (PID: $root_pid)"
  if [ "$comm" = "nginx" ] && [ -n "$exe" ] && [ -x "$exe" ]; then
    if "$exe" -s stop >/dev/null 2>&1; then
      stopped=1
    fi
  elif [ "$comm" = "caddy" ] && [ -n "$exe" ] && [ -x "$exe" ]; then
    if "$exe" stop >/dev/null 2>&1; then
      stopped=1
    fi
  fi

  if [ "$stopped" -eq 0 ]; then
    if kill -TERM "$root_pid" 2>/dev/null; then
      stopped=1
    fi
  fi

  if [ "$stopped" -eq 1 ]; then
    record_paused_item "proc:$root_pid" "process:$comm($root_pid)" "$start_cmd" || true
    return 0
  fi
  return 1
}

pause_docker_for_pid_or_proxy() {
  local pid="$1"
  local comm="$2"
  local cid="" cname="" found=0

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  if [ -r "/proc/$pid/cgroup" ]; then
    cid="$(grep -oE '[0-9a-f]{64}' "/proc/$pid/cgroup" 2>/dev/null | head -n1 || true)"
    if [ -n "$cid" ]; then
      cname="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
      if [ -n "$cname" ]; then
        stop_docker_container "$cname" && return 0
      fi
    fi
  fi

  if [[ "$comm" == docker-proxy* ]] || [[ "$comm" == rootlesskit* ]] || [[ "$comm" == vpnkit* ]]; then
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      if docker port "$cid" 2>/dev/null | grep -qE 'tcp -> .*:80$'; then
        cname="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
        if [ -n "$cname" ]; then
          if stop_docker_container "$cname"; then
            found=1
          fi
        fi
      fi
    done < <(docker ps -q 2>/dev/null || true)
    if [ "$found" -eq 1 ]; then
      return 0
    fi
  fi

  return 1
}

pause_known_services_fallback() {
  local svc cid cname
  local -a candidates=("sniproxy" "nginx" "caddy" "openresty")

  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      if docker port "$cid" 2>/dev/null | grep -qE 'tcp -> .*:80$'; then
        cname="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
        if [ -n "$cname" ]; then
          stop_docker_container "$cname" || true
          is_port80_in_use || return 0
        fi
      fi
    done < <(docker ps -q 2>/dev/null || true)
  fi

  if command -v systemctl >/dev/null 2>&1; then
    for svc in "${candidates[@]}"; do
      if systemctl is-active --quiet "${svc}.service"; then
        stop_systemd_unit "${svc}.service" || true
        sleep 0.5
        is_port80_in_use || return 0
      fi
    done
  fi

  for svc in "${candidates[@]}"; do
    if stop_init_service "$svc"; then
      sleep 0.5
      is_port80_in_use || return 0
    fi
  done
}

ensure_port80_free() {
  local pids pid comm unit svc_base waited=0

  echo "Checking port 80 usage..."
  if ! is_port80_in_use; then
    echo "Port 80 is free. Continuing..."
    return 0
  fi

  echo "Port 80 is currently in use:"
  show_port80_listeners

  pids="$(get_port80_pids)"
  if [ -n "$pids" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      if ! kill -0 "$pid" 2>/dev/null; then
        continue
      fi

      comm="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]' || true)"

      if pause_docker_for_pid_or_proxy "$pid" "$comm"; then
        continue
      fi

      if unit="$(get_systemd_unit_for_pid "$pid")"; then
        stop_systemd_unit "$unit" || true
        continue
      fi

      svc_base="${comm%%:*}"
      if [ -n "$svc_base" ] && stop_init_service "$svc_base"; then
        continue
      fi

      if [ -n "$comm" ]; then
        stop_standalone_process "$pid" "$comm" || true
      fi
    done <<< "$pids"
  fi

  if is_port80_in_use; then
    pause_known_services_fallback
  fi

  while is_port80_in_use && [ "$waited" -lt 10 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done

  if is_port80_in_use; then
    echo ""
    echo "[ERROR] Port 80 is still occupied and could not be freed automatically:"
    show_port80_listeners
    if [ "${#PAUSED_START_CMDS[@]}" -gt 0 ]; then
      echo "Paused service(s) can be started manually with:"
      print_paused_start_commands
    fi
    exit 1
  fi

  echo "Port 80 is now free."
}

if [ ! -x "$ACME" ]; then
  echo "Installing acme.sh..."
  curl https://get.acme.sh | sh
fi

read -r -p "Enter domain: " domain
if [ -z "${domain}" ]; then
  echo "Domain is required."
  exit 1
fi

if [ ! -f "$HOME/.acme.sh/account.conf" ]; then
  email_prefix=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
  email="${email_prefix}@gmail.com"
  "$ACME" --register-account -m "$email"
  echo "Registered account with email: $email"
else
  echo "Account already exists. Skipping account registration."
fi

ensure_port80_free

echo "Issuing certificate for $domain..."
if "$ACME" --issue -d "$domain" --standalone; then
  echo "Certificate issued successfully."
  resume_paused_services
else
  echo ""
  echo "[ERROR] Certificate issuance failed for domain: $domain"
  if [ "${#PAUSED_START_CMDS[@]}" -gt 0 ]; then
    echo "The following paused service(s) were NOT automatically restarted."
    echo "Start them manually with:"
    print_paused_start_commands
  fi
  exit 1
fi

cert_dir="/root/cert/$domain"
mkdir -p "$cert_dir"

reload_cmd=""
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -w "nginx" >/dev/null 2>&1; then
    reload_cmd="docker exec nginx nginx -s reload"
  fi
fi

if [ -z "$reload_cmd" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      reload_cmd="systemctl reload nginx"
    fi
  fi
fi

if [ -n "$reload_cmd" ]; then
  "$ACME" --installcert -d "$domain" \
    --key-file "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem" \
    --reloadcmd "$reload_cmd"
  echo "Installed certs to: $cert_dir (with reloadcmd: $reload_cmd)"
else
  "$ACME" --installcert -d "$domain" \
    --key-file "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem"
  echo "Installed certs to: $cert_dir (no reloadcmd configured)"
  echo "Set reload command manually if needed."
fi

"$ACME" --renew-all --force >/dev/null 2>&1 || true

echo "Done."
