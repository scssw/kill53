#!/usr/bin/env bash
set -euo pipefail

LOCAL_SSR="/root/backup/ssr-conf.tar.gz"
REMOTE_SSR="/root/backup/ssr-conf.tar.gz"
LOCAL_HUI="/usr/local/h-ui/data/h_ui.db"
REMOTE_HUI="/usr/local/h-ui/data/h_ui.db"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_pm() {
  if need_cmd apt-get; then
    echo "apt"
  elif need_cmd yum; then
    echo "yum"
  elif need_cmd dnf; then
    echo "dnf"
  elif need_cmd apk; then
    echo "apk"
  else
    echo ""
  fi
}

install_pkg() {
  local pkg="$1"
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    echo "No supported package manager found; please install $pkg manually." >&2
    return 1
  fi

  case "$pm" in
    apt)
      sudo apt-get update -y
      sudo apt-get install -y "$pkg"
      ;;
    yum)
      sudo yum install -y "$pkg"
      ;;
    dnf)
      sudo dnf install -y "$pkg"
      ;;
    apk)
      sudo apk add --no-cache "$pkg"
      ;;
  esac
}

ensure_rsync() {
  if ! need_cmd rsync; then
    echo "rsync not found; installing..."
    install_pkg rsync
  fi
}

ensure_ssh_key() {
  if [[ ! -f "$HOME/.ssh/id_rsa" || ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
    echo "SSH key not found; creating one..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa"
  else
    echo "SSH key exists; skipping."
  fi
}

try_key_auth() {
  local user="$1"
  local host="$2"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "${user}@${host}" "true" >/dev/null 2>&1
}

setup_key_auth() {
  local user="$1"
  local host="$2"

  if try_key_auth "$user" "$host"; then
    echo "Key auth already works; skipping password."
    return 0
  fi

  if need_cmd ssh-copy-id; then
    echo "Password will be requested to install key..."
    ssh-copy-id -o StrictHostKeyChecking=accept-new "${user}@${host}"
  else
    echo "Password will be requested to install key..."
    ssh -o StrictHostKeyChecking=accept-new "${user}@${host}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    ssh -o StrictHostKeyChecking=accept-new "${user}@${host}" \
      "cat >> ~/.ssh/authorized_keys" < "$HOME/.ssh/id_rsa.pub"
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Local file not found: $path" >&2
    exit 1
  fi
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Warning: not running as root. You may need sudo for installs or file access."
  fi

  ensure_rsync
  ensure_ssh_key

  read -r -p "Remote IP: " remote_ip
  if [[ -z "$remote_ip" ]]; then
    echo "Remote IP is required." >&2
    exit 1
  fi

  remote_user="root"

  setup_key_auth "$remote_user" "$remote_ip"

  echo "Select transfer:"
  echo "1) ssr package"
  echo "2) hui package"
  read -r -p "Enter 1 or 2: " choice

  case "$choice" in
    1)
      require_file "$LOCAL_SSR"
      ssh "${remote_user}@${remote_ip}" "mkdir -p /root/backup"
      rsync -avz -e ssh "$LOCAL_SSR" "${remote_user}@${remote_ip}:$REMOTE_SSR"
      ;;
    2)
      require_file "$LOCAL_HUI"
      ssh "${remote_user}@${remote_ip}" "mkdir -p /usr/local/h-ui/data"
      rsync -avz -e ssh "$LOCAL_HUI" "${remote_user}@${remote_ip}:$REMOTE_HUI"
      ;;
    *)
      echo "Invalid choice." >&2
      exit 1
      ;;
  esac

  echo "Done."
}

main "$@"
