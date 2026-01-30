#!/usr/bin/env bash
set -euo pipefail

PREFIX_HOST="clash.ssrr.today"
PREFIX_PORT="12345"
PREFIX_SCHEME="${PREFIX_SCHEME:-http}"
PREFIX="${PREFIX_SCHEME}://${PREFIX_HOST}:${PREFIX_PORT}"

# Public HTTPS endpoint (usually reverse proxy on 443). Leave PUBLIC_PORT empty to omit port.
PUBLIC_HOST="${PUBLIC_HOST:-${PREFIX_HOST}}"
PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"
PUBLIC_PORT="${PUBLIC_PORT:-}"

IMAGE="${IMAGE:-asdlokj1qpi23/subconverter:latest}"
CONTAINER_NAME="subconverter"
HOST_PORT="${PREFIX_PORT}"
CONTAINER_PORT="25500"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
  fi
}

install_deps() {
  echo "[1/4] Installing dependencies (docker / curl / python3)..."
  apt-get update -y
  apt-get install -y docker.io curl python3 ca-certificates
  systemctl enable --now docker
}

start_container() {
  echo "[2/4] Pulling image and starting container..."

  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${HOST_PORT}$"; then
    echo "Port ${HOST_PORT} is already in use. Skipping container start."
    return 0
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Existing container ${CONTAINER_NAME} found, removing..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  docker pull "${IMAGE}" >/dev/null

  docker run -d --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    "${IMAGE}" >/dev/null

  echo "Container started: ${CONTAINER_NAME}"
}

open_firewall() {
  echo "[3/4] Trying to open firewall port ${HOST_PORT}/tcp (ufw only)..."
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow "${HOST_PORT}/tcp" >/dev/null || true
      echo "ufw allowed ${HOST_PORT}/tcp"
    else
      echo "ufw inactive, skipped."
    fi
  else
    echo "ufw not found, skipped."
  fi
}

health_check() {
  echo "[4/4] Local connectivity check..."
  if curl -fsS "http://127.0.0.1:${HOST_PORT}/sub?target=clash&url=ssr%3A%2F%2Ftest" >/dev/null 2>&1; then
    echo "Local OK: /sub reachable"
  else
    echo "Hint: /sub check failed (test SSR may be invalid). Service may still be OK."
  fi

  echo
  echo "Done. For external use:"
  echo "1) ${PREFIX_HOST} A record -> your public IP"
  echo "2) Allow ${HOST_PORT}/tcp in firewall/security group"
  echo
}

urlencode() {
  local s="${1:-}"
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${s}"
}

make_url() {
  local scheme="$1"
  local host="$2"
  local port="$3"
  local enc="$4"
  if [[ -n "${port}" ]]; then
    echo "${scheme}://${host}:${port}/sub?target=clash&url=${enc}"
  else
    echo "${scheme}://${host}/sub?target=clash&url=${enc}"
  fi
}

install_cli() {
  local target="/usr/local/bin/clash"
  install -D -m 0755 "$0" "${target}"
  echo "Installed CLI: ${target}"
}

interactive() {
  echo "----------------------------"
  echo "Paste SSR or VLESS link (starts with ssr:// or vless://), press Enter to generate; type exit to quit"
  echo "Prefix: ${PREFIX}"
  echo "Public: ${PUBLIC_SCHEME}://${PUBLIC_HOST}${PUBLIC_PORT:+:${PUBLIC_PORT}}"
  echo "----------------------------"

  while true; do
    read -rp "LINK> " link || true
    link="${link:-}"
    case "${link}" in
      exit|quit)
        exit 0
        ;;
    esac
    if [[ -z "${link}" ]]; then
      echo "Empty input, cancelled."
      continue
    fi
    if [[ "${link}" == ssr://* ]]; then
      enc="$(urlencode "${link}")"
      echo
      echo "Generated (subconverter):"
      make_url "${PREFIX_SCHEME}" "${PREFIX_HOST}" "${PREFIX_PORT}" "${enc}"
      echo
      echo "Generated (public https):"
      make_url "${PUBLIC_SCHEME}" "${PUBLIC_HOST}" "${PUBLIC_PORT}" "${enc}"
      echo
      echo "Tip: if external access fails, check DNS resolution and firewall for ${HOST_PORT}/tcp"
      continue
    fi
    if [[ "${link}" == vless://* ]]; then
      enc="$(urlencode "${link}")"
      echo
      echo "Generated (subconverter):"
      make_url "${PREFIX_SCHEME}" "${PREFIX_HOST}" "${PREFIX_PORT}" "${enc}"
      echo
      echo "Generated (public https):"
      make_url "${PUBLIC_SCHEME}" "${PUBLIC_HOST}" "${PUBLIC_PORT}" "${enc}"
      echo
      echo "Generated (Clash proxy YAML):"
      python3 - "$link" <<'PY'
import sys
import urllib.parse

def _first(params, key, default=""):
  vals = params.get(key)
  return vals[0] if vals else default

def _bool(val):
  if val is None:
    return None
  v = str(val).strip().lower()
  if v in ("1", "true", "yes", "y", "on"):
    return True
  if v in ("0", "false", "no", "n", "off"):
    return False
  return None

url = sys.argv[1] if len(sys.argv) > 1 else ""
if not url.startswith("vless://"):
  print("Not a vless:// link, cancelled.")
  sys.exit(0)

u = urllib.parse.urlparse(url)
uuid = urllib.parse.unquote(u.username or "")
host = u.hostname or ""
port = u.port or 0
params = urllib.parse.parse_qs(u.query, keep_blank_values=True)
name = urllib.parse.unquote(u.fragment or "") or f"{host}:{port}"

network = _first(params, "type", "tcp")
security = _first(params, "security", "")
sni = _first(params, "sni", "")
fp = _first(params, "fp", "")
pbk = _first(params, "pbk", "")
sid = _first(params, "sid", "")
spx = urllib.parse.unquote(_first(params, "spx", ""))
flow = _first(params, "flow", "")
udp = _bool(_first(params, "udp", ""))

lines = []
lines.append(f"- name: \"{name}\"")
lines.append("  type: vless")
lines.append(f"  server: {host}")
lines.append(f"  port: {port}")
lines.append(f"  uuid: {uuid}")
if network:
  lines.append(f"  network: {network}")
if udp is not None:
  lines.append(f"  udp: {'true' if udp else 'false'}")

if security.lower() == "reality":
  lines.append("  tls: true")
  if sni:
    lines.append(f"  servername: {sni}")
  if fp:
    lines.append(f"  client-fingerprint: {fp}")
  if flow:
    lines.append(f"  flow: {flow}")
  ropts = []
  if pbk:
    ropts.append(f"    public-key: {pbk}")
  if sid:
    ropts.append(f"    short-id: {sid}")
  if spx:
    ropts.append(f"    spider-x: {spx}")
  if ropts:
    lines.append("  reality-opts:")
    lines.extend(ropts)
else:
  if security:
    lines.append("  tls: true")
    if sni:
      lines.append(f"  servername: {sni}")

print("\n".join(lines))
PY
      echo
      continue
    fi
    echo "Not an ssr:// or vless:// link, cancelled."
  done
}

main() {
  if [[ "${1:-}" == "--install-cli" ]]; then
    install_cli
    return 0
  fi

  if [[ "${1:-}" == "--interactive" ]] || [[ "$(basename "$0")" == "clash" ]]; then
    interactive
    return 0
  fi

  need_root
  install_deps
  start_container
  open_firewall
  health_check
  install_cli
  interactive
}

main "$@"
