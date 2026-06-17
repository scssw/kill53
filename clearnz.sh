#!/usr/bin/env bash
set -euo pipefail

AGENT_DIR="/opt/nezha/agent"
SYSTEMD_DIR="/etc/systemd/system"
DRY_RUN=1

usage() {
  cat <<'USAGE'
Usage:
  bash clean_nezha_rogue_agents.sh          # dry-run, only show actions
  bash clean_nezha_rogue_agents.sh --apply  # stop, disable, and delete rogue random-config services

This script preserves:
  /opt/nezha/agent/config.yml
  /etc/systemd/system/nezha-agent.service

It removes Nezha agent instances that use random config files like:
  /opt/nezha/agent/config-h6nvv.yml
  /opt/nezha/agent/config-ty5rm.yml
USAGE
}

log() {
  printf '%s\n' "$*"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

needs_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: run as root."
    exit 1
  fi
}

parse_args() {
  case "${1:-}" in
    "")
      DRY_RUN=1
      ;;
    "--apply")
      DRY_RUN=0
      ;;
    "-h"|"--help")
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

unit_uses_random_config() {
  unit_file="$1"
  grep -Eq -- "${AGENT_DIR}/config-[A-Za-z0-9_-]+\\.ya?ml" "$unit_file"
}

extract_random_configs_from_unit() {
  unit_file="$1"
  grep -Eo -- "${AGENT_DIR}/config-[A-Za-z0-9_-]+\\.ya?ml" "$unit_file" | sort -u
}

main() {
  parse_args "$@"
  needs_root

  if [ ! -d "$AGENT_DIR" ]; then
    log "ERROR: $AGENT_DIR not found."
    exit 1
  fi

  log "Mode: $([ "$DRY_RUN" -eq 1 ] && echo dry-run || echo apply)"
  log "Preserving normal config: ${AGENT_DIR}/config.yml"
  log "Preserving normal service: ${SYSTEMD_DIR}/nezha-agent.service"
  log ""

  found=0
  config_delete_list="$(mktemp)"
  trap 'rm -f "$config_delete_list"' EXIT

  for unit_file in "${SYSTEMD_DIR}"/nezha-agent*.service; do
    [ -e "$unit_file" ] || continue
    [ "$unit_file" = "${SYSTEMD_DIR}/nezha-agent.service" ] && continue

    if unit_uses_random_config "$unit_file"; then
      found=1
      unit_name="$(basename "$unit_file")"
      log "Rogue service: $unit_name"
      extract_random_configs_from_unit "$unit_file" | tee -a "$config_delete_list" | sed 's/^/  config: /'

      run systemctl stop "$unit_name" || true
      run systemctl disable "$unit_name" || true
      run rm -f "$unit_file"
      log ""
    fi
  done

  for cfg in "${AGENT_DIR}"/config-*.yml "${AGENT_DIR}"/config-*.yaml; do
    [ -e "$cfg" ] || continue
    found=1
    printf '%s\n' "$cfg" >> "$config_delete_list"
  done

  sort -u "$config_delete_list" | while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    [ "$cfg" = "${AGENT_DIR}/config.yml" ] && continue
    case "$cfg" in
      "${AGENT_DIR}"/config-*.yml|"${AGENT_DIR}"/config-*.yaml)
        if [ -f "$cfg" ]; then
          log "Delete rogue config: $cfg"
          run rm -f "$cfg"
        fi
        ;;
      *)
        log "Skip unexpected path: $cfg"
        ;;
    esac
  done

  run systemctl daemon-reload

  log ""
  if [ "$found" -eq 0 ]; then
    log "No rogue random-config Nezha services or config files found."
  else
    log "Done. Verify with:"
    log "  systemctl list-units --type=service --all | grep nezha"
    log "  find /opt/nezha/agent -maxdepth 1 -name 'config*.yml' -ls"
  fi
}

main "$@"
