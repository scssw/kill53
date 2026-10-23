#!/usr/bin/env bash
# 强制使用 UTF-8 环境
export LANG=en_US.UTF-8
set -euo pipefail

DEFAULT_PORT="12345"
CLASH_CMD_PATH="${CLASH_INSTALL_PATH:-/usr/local/bin/clash}"
RELAY_SCRIPT_PATH="${RELAY_SCRIPT_PATH:-/usr/local/bin/ssr_clash_relay.py}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/ssr-clash-relay.service}"
ENV_PATH="${ENV_PATH:-/etc/default/ssr-clash-relay}"

print_info() { printf "\e[1;32m[INFO]\e[0m %s\n" "$*"; }
print_err() { printf "\e[1;31m[ERROR]\e[0m %s\n" "$*" >&2; }

start_relay_service() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now ssr-clash-relay.service
    systemctl restart ssr-clash-relay.service
  else
    pkill -f "${RELAY_SCRIPT_PATH}" || true
    nohup python3 "${RELAY_SCRIPT_PATH}" --port "${PORT}" >/tmp/ssr_clash.log 2>&1 &
  fi
}

# 1. 刷新环境：清理旧进程和残留文件
cleanup_old_version() {
  print_info "正在清理旧版本进程及缓存..."
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop ssr-clash-relay.service >/dev/null 2>&1 || true
  fi
  pkill -f ssr_clash_relay.py || true
  pkill -f "${RELAY_SCRIPT_PATH}" || true
  rm -f /tmp/ssr_clash_relay.pid
  rm -f /tmp/ssr_clash.log
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
  cat > "${ENV_PATH}" <<EOF
PORT=${PORT}
RELAY_SCRIPT=${RELAY_SCRIPT_PATH}
EOF

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
    ADDR=$(curl -s --max-time 2 api.ipify.org || hostname -I | awk '{print $1}')
fi

ENCODED=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$SSR_INPUT_FOR_URL")
echo -e "\n\e[1;32m您的 Clash 订阅链接：\e[0m"
echo "http://${ADDR}:${PORT}/sub?target=clash&url=${ENCODED}"
if [[ -n "${BIND_DOMAIN}" ]]; then
  echo "https://${BIND_DOMAIN}/sub?target=clash&url=${ENCODED}"
fi
SCRIPT

  # 替换变量
  sed -i "s|__RELAY_SCRIPT_PATH__|${RELAY_SCRIPT_PATH}|g" "${CLASH_CMD_PATH}"
  sed -i "s|__RELAY_PORT__|${PORT}|g" "${CLASH_CMD_PATH}"
  sed -i "s|__BIND_DOMAIN__|${DOMAIN}|g" "${CLASH_CMD_PATH}"
  chmod +x "${CLASH_CMD_PATH}"
}

# --- 执行流程 ---
cleanup_old_version

# 端口互动
read -r -p "请输入中转端口 (默认 12345): " PORT
PORT=${PORT:-12345}

# 域名互动
read -r -p "请输入绑定域名 (例如 example.com，直接回车则使用IP): " DOMAIN
DOMAIN=${DOMAIN:-""}

install_relay_script
install_systemd_service
install_clash_cmd
start_relay_service

print_info "安装/刷新完成！"
print_info "绑定地址: ${DOMAIN:-'系统自动获取IP'}"
print_info "中转端口: ${PORT}"
print_info "现在只需执行 'clash'，逐行粘贴一个或多个 SSR 链接，空行结束后即可生成新链接。"
