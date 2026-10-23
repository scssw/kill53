#!/usr/bin/env bash
# 强制使用 UTF-8 环境
export LANG=en_US.UTF-8

DEFAULT_PORT="12345"
CLASH_CMD_PATH="${CLASH_INSTALL_PATH:-/usr/local/bin/clash}"
RELAY_SCRIPT_PATH="${RELAY_SCRIPT_PATH:-/usr/local/bin/ssr_clash_relay.py}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/ssr-clash-relay.service}"
ENV_PATH="${ENV_PATH:-/etc/default/ssr-clash-relay}"
CADDY_SERVICE_PATH="/etc/systemd/system/caddy.service"
CADDY_CONFIG_DIR="/etc/caddy"
CADDYFILE="/etc/caddy/Caddyfile"
CRON_RENEW_FILE="/etc/cron.d/caddy-renew"

PORT="${DEFAULT_PORT}"
DOMAIN=""
SSL_ENABLED="false"

# 载入已有配置 (如果存在)
if [[ -f "${ENV_PATH}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_PATH}" 2>/dev/null || true
fi

print_info() { printf "\e[1;32m[INFO]\e[0m %s\n" "$*"; }
print_err() { printf "\e[1;31m[ERROR]\e[0m %s\n" "$*" >&2; }

get_host_ip() {
  local ip
  ip=$(curl -s --max-time 2 api.ipify.org 2>/dev/null || curl -s --max-time 2 https://ip.sb 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-127.0.0.1}"
}

start_relay_service() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable ssr-clash-relay.service >/dev/null 2>&1 || true
    systemctl restart ssr-clash-relay.service
  else
    pkill -f "${RELAY_SCRIPT_PATH}" || true
    nohup python3 "${RELAY_SCRIPT_PATH}" --port "${PORT}" >/tmp/ssr_clash.log 2>&1 &
  fi
}

cleanup_old_version() {
  print_info "正在清理旧版本进程及缓存..."
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop ssr-clash-relay.service >/dev/null 2>&1 || true
  fi
  pkill -f ssr_clash_relay.py >/dev/null 2>&1 || true
  pkill -f "${RELAY_SCRIPT_PATH}" >/dev/null 2>&1 || true
  rm -f /tmp/ssr_clash_relay.pid /tmp/ssr_clash.log
}

save_env_config() {
  mkdir -p "$(dirname "${ENV_PATH}")"
  cat > "${ENV_PATH}" <<EOF
PORT=${PORT}
DOMAIN=${DOMAIN}
RELAY_SCRIPT=${RELAY_SCRIPT_PATH}
SSL_ENABLED=${SSL_ENABLED:-false}
EOF
}

install_relay_script() {
  mkdir -p "$(dirname "${RELAY_SCRIPT_PATH}")"
  cat > "${RELAY_SCRIPT_PATH}" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import base64
import binascii
import argparse
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

def b64_decode(s: str, allow_plain: bool = False):
    raw = unquote(str(s).strip())
    normalized = raw.replace("-", "+").replace("_", "/")
    try:
        return base64.b64decode(
            normalized.encode("ascii") + b"=" * (-len(normalized) % 4)
        ).decode("utf-8", "ignore")
    except (UnicodeEncodeError, binascii.Error, ValueError):
        if allow_plain:
            return raw
        raise

def yaml_quote(value: str):
    return value.replace("'", "''")

def parse_ssr(ssr_url):
    try:
        if not ssr_url.startswith("ssr://"):
            raise ValueError("不是有效的 SSR 链接")
        raw = b64_decode(ssr_url[6:])
        main, query = raw.split("/?", 1) if "/?" in raw else (raw, "")
        p = main.split(":")
        if len(p) < 6:
            raise ValueError("SSR 节点字段不完整")
        q = parse_qs(query)
        remarks = b64_decode(q['remarks'][0], allow_plain=True) if 'remarks' in q else f"SSR-{p[0]}"
        return {
            "name": remarks.strip(), "server": p[0], "port": int(p[1]),
            "protocol": p[2], "cipher": p[3], "obfs": p[4], "password": b64_decode(p[5]),
            "obfsparam": b64_decode(q['obfsparam'][0], allow_plain=True) if 'obfsparam' in q else "",
            "protoparam": b64_decode(q['protoparam'][0], allow_plain=True) if 'protoparam' in q else ""
        }
    except Exception as exc:
        raise ValueError(f"SSR 链接解析失败: {exc}")

def split_ssr_entries(raw_value: str):
    normalized = raw_value.replace("|", "\n").replace(",", "\n")
    entries = [line.strip() for line in normalized.splitlines() if line.strip()]
    if not entries:
        raise ValueError("未提供 SSR 链接")
    return entries

def make_unique_names(nodes):
    seen = {}
    for node in nodes:
        base = node["name"] or f"SSR-{node['server']}"
        count = seen.get(base, 0) + 1
        seen[base] = count
        node["name"] = base if count == 1 else f"{base}-{count}"
    return nodes

def proxy_line(node):
    return (
        f"  - {{name: '{yaml_quote(node['name'])}', type: ssr, server: {node['server']}, "
        f"port: {node['port']}, cipher: {node['cipher']}, password: '{yaml_quote(node['password'])}', "
        f"protocol: {node['protocol']}, obfs: {node['obfs']}, "
        f"protocol-param: '{yaml_quote(node['protoparam'])}', obfs-param: '{yaml_quote(node['obfsparam'])}'}}"
    )

def to_yaml(nodes):
    proxy_names = [node["name"] for node in nodes]
    group_names = ", ".join(f"'{yaml_quote(name)}'" for name in proxy_names)
    lines = [
        "port: 7890", "socks-port: 7891", "allow-lan: true", "mode: Rule", "log-level: info",
        "proxies:",
        *[proxy_line(node) for node in nodes],
        "proxy-groups:",
        f"  - {{name: '🔰 节点选择', type: select, proxies: [{group_names}]}}",
        "",
        "rules:",
        "  # === 💼 领英 (强行走代理，防止解析到国内 CDN 误判为直连) ===",
        "  - DOMAIN-SUFFIX,linkedin.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,licdn.com,🔰 节点选择",
        "",
        "  # === 📲 社交应用专用规则 (TG / X / WhatsApp 确保前台通信走代理) ===",
        "  # Telegram",
        "  - DOMAIN-SUFFIX,t.me,🔰 节点选择",
        "  - DOMAIN-SUFFIX,tdesktop.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telegra.ph,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telegram.dog,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telegram.me,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telegram.org,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telegram-cdn.org,🔰 节点选择",
        "  - DOMAIN-SUFFIX,telesco.pe,🔰 节点选择",
        "  - IP-CIDR,91.108.0.0/16,🔰 节点选择,no-resolve",
        "  - IP-CIDR,149.154.160.0/20,🔰 节点选择,no-resolve",
        "  - IP-CIDR,109.239.140.0/24,🔰 节点选择,no-resolve",
        "  - IP-CIDR,5.28.192.0/18,🔰 节点选择,no-resolve",
        "  - IP-CIDR6,2001:b28:f23c::/47,🔰 节点选择,no-resolve",
        "  - IP-CIDR6,2001:67c:4e8::/48,🔰 节点选择,no-resolve",
        "",
        "  # Twitter / X",
        "  - DOMAIN-SUFFIX,x.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,twitter.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,twimg.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,t.co,🔰 节点选择",
        "",
        "  # WhatsApp",
        "  - DOMAIN-SUFFIX,whatsapp.com,🔰 节点选择",
        "  - DOMAIN-SUFFIX,whatsapp.net,🔰 节点选择",
        "  - DOMAIN-KEYWORD,whatsapp,🔰 节点选择",
        "",
        "  # === 🎯 基础分流 (局域网直连、.cn域名秒直连、国内IP直连、国外代理) ===",
        "  - GEOIP,LAN,DIRECT,no-resolve",
        "  - DOMAIN-SUFFIX,cn,DIRECT",
        "  - GEOIP,CN,DIRECT",
        "  - MATCH,🔰 节点选择"
    ]
    return "\n".join(lines)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logging.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        if "/sub" in self.path and "url" in q:
            try:
                entries = split_ssr_entries(q['url'][0])
                nodes = make_unique_names([parse_ssr(entry) for entry in entries])
                content = to_yaml(nodes)
                self.send_response(200); self.send_header("Content-Type", "text/yaml; charset=utf-8"); self.end_headers()
                self.wfile.write(content.encode("utf-8"))
            except Exception as e:
                self.send_response(400); self.end_headers(); self.wfile.write(str(e).encode())
        else:
            self.send_response(200); self.end_headers(); self.wfile.write(b"Relay Service is Online")

class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SSR to Clash subscription relay")
    parser.add_argument("--port", type=int, default=12345)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    server = ReusableThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    logging.info("ssr-clash-relay listening on 0.0.0.0:%s", args.port)
    server.serve_forever()
PY
  chmod +x "${RELAY_SCRIPT_PATH}"
}

install_systemd_service() {
  mkdir -p "$(dirname "${ENV_PATH}")" "$(dirname "${SERVICE_PATH}")"
  save_env_config

  cat > "${SERVICE_PATH}" <<'SERVICE'
[Unit]
Description=SSR to Clash subscription relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ssr-clash-relay
ExecStart=/usr/bin/env python3 ${RELAY_SCRIPT} --port ${PORT}
Restart=always
RestartSec=3
StandardOutput=append:/var/log/ssr-clash-relay.log
StandardError=append:/var/log/ssr-clash-relay.log

[Install]
WantedBy=multi-user.target
SERVICE
}

install_clash_cmd() {
  cat > "${CLASH_CMD_PATH}" <<'SCRIPT'
#!/usr/bin/env bash
export LANG=en_US.UTF-8
PORT="__RELAY_PORT__"
RELAY_SCRIPT="__RELAY_SCRIPT_PATH__"
BIND_DOMAIN="__BIND_DOMAIN__"
SSL_ENABLED="__SSL_ENABLED__"

print_input_help() {
  echo "请逐行输入 SSR 地址，支持多条。" >&2
  echo "直接回车空行结束输入。" >&2
}

read_ssr_links() {
  local line
  local first=1
  local result=""
  print_input_help
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    if [[ $first -eq 1 ]]; then
      result="$line"
      first=0
    else
      result+=$'\n'"$line"
    fi
  done
  printf '%s' "$result"
}

SSR_INPUT="$(read_ssr_links)"
[[ -z "$SSR_INPUT" ]] && exit 1
SSR_INPUT_FOR_URL=$(printf '%s' "$SSR_INPUT" | python3 -c "import sys; print('|'.join(line.strip() for line in sys.stdin.read().splitlines() if line.strip()))")

# 确保 relay 在线。优先使用安装时创建的 systemd 服务，避免订阅刷新时服务已退出。
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && systemctl list-unit-files ssr-clash-relay.service >/dev/null 2>&1; then
  systemctl restart ssr-clash-relay.service >/dev/null 2>&1 || true
else
  pkill -f "${RELAY_SCRIPT}" >/dev/null 2>&1 || true
  nohup python3 "${RELAY_SCRIPT}" --port "${PORT}" >/tmp/ssr_clash.log 2>&1 &
  sleep 1
fi

# 地址判断逻辑：如果有绑定域名则用域名，否则自动获取IP
if [[ -n "${BIND_DOMAIN}" ]]; then
    ADDR="${BIND_DOMAIN}"
else
    ADDR=$(curl -s --max-time 2 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
fi

ENCODED=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$SSR_INPUT_FOR_URL")
echo -e "\n\e[1;32m您的 Clash 订阅链接：\e[0m"
if [[ "${SSL_ENABLED}" == "true" && -n "${BIND_DOMAIN}" ]]; then
  echo "https://${BIND_DOMAIN}/sub?target=clash&url=${ENCODED}"
else
  echo "http://${ADDR}:${PORT}/sub?target=clash&url=${ENCODED}"
  if [[ -n "${BIND_DOMAIN}" ]]; then
    echo "https://${BIND_DOMAIN}/sub?target=clash&url=${ENCODED}"
  fi
fi
SCRIPT

  # 替换变量
  sed -i "s|__RELAY_SCRIPT_PATH__|${RELAY_SCRIPT_PATH}|g" "${CLASH_CMD_PATH}"
  sed -i "s|__RELAY_PORT__|${PORT}|g" "${CLASH_CMD_PATH}"
  sed -i "s|__BIND_DOMAIN__|${DOMAIN}|g" "${CLASH_CMD_PATH}"
  sed -i "s|__SSL_ENABLED__|${SSL_ENABLED:-false}|g" "${CLASH_CMD_PATH}"
  chmod +x "${CLASH_CMD_PATH}"
}

update_caddyfile() {
  mkdir -p "${CADDY_CONFIG_DIR}"
  cat > "${CADDYFILE}" <<EOF
${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
}

install_caddy_if_needed() {
  if command -v caddy >/dev/null 2>&1; then
    print_info "检测到已安装 Caddy: $(caddy version 2>/dev/null | head -n 1 || echo 'Caddy')"
    return 0
  fi
  print_info "正在自动安装 Caddy..."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gpg || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' 2>/dev/null | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null 2>&1 || true
    apt-get update -qq || true
    if apt-get install -y -qq caddy; then
      print_info "Caddy APT 安装成功！"
      return 0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y 'dnf-command(copr)' || true
    dnf copr enable -y @caddy/caddy || true
    if dnf install -y caddy; then
      print_info "Caddy DNF 安装成功！"
      return 0
    fi
  elif command -v yum >/dev/null 2>&1; then
    yum install -y yum-plugin-copr || true
    yum copr enable -y @caddy/caddy || true
    if yum install -y caddy; then
      print_info "Caddy YUM 安装成功！"
      return 0
    fi
  fi

  print_info "尝试官方预编译二进制安装 Caddy..."
  local arch
  arch="$(uname -m)"
  local caddy_arch="amd64"
  case "$arch" in
    x86_64) caddy_arch="amd64" ;;
    aarch64|arm64) caddy_arch="arm64" ;;
    armv7l) caddy_arch="armv7" ;;
    *) caddy_arch="amd64" ;;
  esac
  local tar_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${caddy_arch}.tar.gz"
  mkdir -p /tmp/caddy_dl
  if curl -sL --max-time 30 "$tar_url" -o /tmp/caddy_dl/caddy.tar.gz; then
    tar -xzf /tmp/caddy_dl/caddy.tar.gz -C /tmp/caddy_dl
    mv /tmp/caddy_dl/caddy /usr/local/bin/caddy
    chmod +x /usr/local/bin/caddy
    rm -rf /tmp/caddy_dl
    print_info "Caddy 二进制安装成功！"
    return 0
  else
    rm -rf /tmp/caddy_dl
    print_err "Caddy 下载失败，请检查机器网络！"
    return 1
  fi
}

ensure_caddy_service() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if ! systemctl list-unit-files caddy.service >/dev/null 2>&1 && [[ ! -f "${CADDY_SERVICE_PATH}" ]]; then
      local caddy_bin
      caddy_bin="$(command -v caddy)"
      cat > "${CADDY_SERVICE_PATH}" <<SERVICE
[Unit]
Description=Caddy Web Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${caddy_bin} run --config ${CADDYFILE}
ExecReload=${caddy_bin} reload --config ${CADDYFILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

configure_service() {
  echo ""
  print_info "=== 重新配置 SSR 转 Clash 服务 ==="

  read -r -p "请输入中转端口 (当前/默认: ${PORT:-12345}): " NEW_PORT
  PORT="${NEW_PORT:-${PORT:-12345}}"

  read -r -p "请输入绑定域名 (当前: ${DOMAIN:-无}，直接回车保留当前值或使用IP): " NEW_DOMAIN
  DOMAIN="${NEW_DOMAIN:-${DOMAIN:-""}}"

  cleanup_old_version
  install_relay_script
  install_systemd_service
  install_clash_cmd
  start_relay_service

  if [[ "${SSL_ENABLED:-false}" == "true" && -n "${DOMAIN}" && -f "${CADDYFILE}" ]]; then
    update_caddyfile
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || true
    fi
  fi

  local host_ip
  host_ip="$(get_host_ip)"
  print_info "配置安装完成！"
  print_info "当前 HTTP 转换: http://${DOMAIN:-$host_ip}:${PORT}"
  if [[ "${SSL_ENABLED:-false}" == "true" && -n "${DOMAIN}" ]]; then
    print_info "当前 HTTPS 转换: https://${DOMAIN}"
  fi
  print_info "现在只需在终端执行 'clash'，粘贴 SSR 链接即可生成订阅。"
}

uninstall_all() {
  echo ""
  read -r -p "确定要彻底移除所有配置、服务和脚本吗？(y/N): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_info "已取消卸载操作。"
    return 0
  fi

  print_info "正在停止并清理服务..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop ssr-clash-relay.service >/dev/null 2>&1 || true
    systemctl disable ssr-clash-relay.service >/dev/null 2>&1 || true
    if [[ -f "${CADDYFILE}" ]]; then
      systemctl stop caddy >/dev/null 2>&1 || true
      systemctl disable caddy >/dev/null 2>&1 || true
    fi
  fi
  pkill -f ssr_clash_relay.py >/dev/null 2>&1 || true
  pkill -f "${RELAY_SCRIPT_PATH}" >/dev/null 2>&1 || true

  rm -f "${SERVICE_PATH}"
  rm -f "${ENV_PATH}"
  rm -f "${RELAY_SCRIPT_PATH}"
  rm -f "${CLASH_CMD_PATH}"
  rm -f "${CADDYFILE}"
  rm -f "${CRON_RENEW_FILE}"
  rm -f /tmp/ssr_clash* /var/log/ssr-clash-relay.log

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  PORT="${DEFAULT_PORT}"
  DOMAIN=""
  SSL_ENABLED="false"

  print_info "所有配置、脚本与服务已彻底移除！"
}

setup_caddy_ssl() {
  echo ""
  print_info "=== 给域名申请 HTTPS 证书 (Caddy 自动申请与定时续订) ==="

  local current_dom="${DOMAIN:-}"
  local target_domain=""
  if [[ -n "${current_dom}" ]]; then
    read -r -p "请输入要申请证书的域名 (直接回车默认使用 [${current_dom}]): " INPUT_DOMAIN
    target_domain="${INPUT_DOMAIN:-$current_dom}"
  else
    read -r -p "请输入要申请证书的域名 (例如 sub.example.com): " INPUT_DOMAIN
    target_domain="${INPUT_DOMAIN:-}"
  fi

  if [[ -z "${target_domain}" ]]; then
    print_err "未输入有效域名，已取消证书申请。"
    return 1
  fi
  DOMAIN="${target_domain}"

  local host_ip
  host_ip="$(get_host_ip)"
  print_info "当前本机 IP: ${host_ip}"
  print_info "请务必确认域名 [${DOMAIN}] 已通过 A 记录解析至本机 IP [${host_ip}]，且本机 80/443 端口已在安全组/防火墙放行。"

  # 安装 Caddy
  install_caddy_if_needed || return 1

  # 写入 Caddyfile
  update_caddyfile

  # 确保 service 存在
  ensure_caddy_service

  # 启动并申请证书
  print_info "正在启动 Caddy 并向 Let's Encrypt / ZeroSSL 申请证书..."
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy
  else
    pkill -f "caddy run" || true
    nohup "$(command -v caddy)" run --config "${CADDYFILE}" >/var/log/caddy.log 2>&1 &
  fi

  # 设置定时自动续订任务
  print_info "设置定时自动续订任务..."
  mkdir -p /etc/cron.d
  cat > "${CRON_RENEW_FILE}" <<'CRON'
# 每天凌晨 03:30 自动检查并重载 Caddy 证书
30 3 * * * root systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
CRON
  chmod 644 "${CRON_RENEW_FILE}"

  SSL_ENABLED="true"
  save_env_config
  install_clash_cmd

  print_info "================================================="
  print_info "HTTPS 证书申请与反向代理配置成功！"
  print_info "已开启自动定时续订 (双重保障: Caddy内置守护 + 每日定时任务)"
  print_info "HTTPS 转换地址: https://${DOMAIN}"
  print_info "现在只需执行 'clash'，生成的订阅链接即为 HTTPS 地址！"
  print_info "================================================="
}

show_panel() {
  if [[ -f "${ENV_PATH}" ]]; then
    source "${ENV_PATH}" 2>/dev/null || true
  fi

  local host_ip
  host_ip="$(get_host_ip)"

  local svc_status
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active ssr-clash-relay.service >/dev/null 2>&1; then
    svc_status="\e[1;32m运行中 (Active)\e[0m"
  elif pgrep -f "ssr_clash_relay.py" >/dev/null 2>&1; then
    svc_status="\e[1;32m运行中 (PID)\e[0m"
  elif [[ -f "${SERVICE_PATH}" ]] || [[ -f "${RELAY_SCRIPT_PATH}" ]]; then
    svc_status="\e[1;31m未运行 (Stopped)\e[0m"
  else
    svc_status="\e[1;33m未安装 / 未配置\e[0m"
  fi

  local http_url
  if [[ -n "${DOMAIN:-}" ]]; then
    http_url="http://${DOMAIN}:${PORT:-12345}"
  else
    http_url="http://${host_ip}:${PORT:-12345}"
  fi

  local https_url="未开启 (可通过选项 3 一键开启)"
  if [[ "${SSL_ENABLED:-false}" == "true" && -n "${DOMAIN:-}" ]]; then
    https_url="\e[1;32mhttps://${DOMAIN}\e[0m"
  fi

  echo -e "\e[1;36m======================================================\e[0m"
  echo -e "\e[1;37m             SSR 转 Clash 服务管理面板               \e[0m"
  echo -e "\e[1;36m======================================================\e[0m"
  echo -e " 服务状态 : ${svc_status}"
  echo -e " 当前转换 : \e[1;33m${http_url}\e[0m"
  if [[ -n "${DOMAIN:-}" ]]; then
    echo -e " 绑定域名 : ${DOMAIN}"
    echo -e " HTTPS转换: ${https_url}"
  fi
  echo -e " 本机 IP  : ${host_ip}"
  echo -e "\e[1;36m------------------------------------------------------\e[0m"
  echo -e "  \e[1;32m1、\e[0m重新配置 (默认，直接回车即可)"
  echo -e "  \e[1;31m2、\e[0m移除所有配置"
  echo -e "  \e[1;34m3、\e[0m给域名申请证书 (默认用 Caddy，回车按当前域名申请与自动续订)"
  echo -e "  \e[1;30m0、\e[0m退出面板"
  echo -e "\e[1;36m======================================================\e[0m"
}

main() {
  while true; do
    show_panel
    read -r -p "请输入选项 [1-3, 默认 1]: " CHOICE
    CHOICE="${CHOICE:-1}"
    case "$CHOICE" in
      1)
        configure_service
        ;;
      2)
        uninstall_all
        ;;
      3)
        setup_caddy_ssl
        ;;
      0|q|Q|exit)
        print_info "已退出管理面板。"
        exit 0
        ;;
      *)
        print_err "无效选项 [${CHOICE}]，请重新输入。"
        ;;
    esac
    echo ""
    read -r -p "按回车键返回主菜单..." _ || true
  done
}

main "$@"
