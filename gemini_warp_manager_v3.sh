#!/usr/bin/env bash
set -euo pipefail

### ====== 基本参数（按你需求固定） ======
MARK_HEX="0x1"
MARK_DEC="1"
IPSET4="warp4"
DNSMASQ_MAIN="/etc/dnsmasq.conf"
DNSMASQ_CONF_DIR="/etc/dnsmasq.d"
DNSMASQ_PANEL_TAG="gemini-warp-manager"
POLICY_SERVICE="/etc/systemd/system/gemini-warp-policy.service"
WG_TABLE_DEFAULT="51820"   # wgcf 常见表号；如果检测不到会退回这个
WG_IF="wgcf"

### ====== 颜色输出 ======
if command -v tput >/dev/null 2>&1; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; BOLD="$(tput bold)"; RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[X]${RESET} $*"; }
info() { echo -e "${BLUE}[*]${RESET} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行：sudo -i 后再执行"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

pause() {
  echo
  read -r -p "按回车继续..." _
}

### ====== 检测 wg 表号 ======
detect_wg_table() {
  # 1) 从 ip route table all 找 default dev wgcf table X
  local t
  t="$(ip route show table all 2>/dev/null | awk '/^default/ && /dev[[:space:]]+wgcf/ {for(i=1;i<=NF;i++) if($i=="table"){print $(i+1); exit}}')"
  if [[ -n "${t:-}" ]]; then
    echo "$t"; return
  fi

  # 2) 常见表号 51820 若存在默认路由
  if ip route show table "${WG_TABLE_DEFAULT}" 2>/dev/null | grep -q '^default'; then
    echo "${WG_TABLE_DEFAULT}"; return
  fi

  # 3) 最后兜底
  echo "${WG_TABLE_DEFAULT}"
}

### ====== ip rule 优先级（关键：必须在最靠前的 lookup main 前面） ======
get_earliest_main_pref() {
  # 取第一条 lookup main 的 pref（最小值）
  ip -d rule show 2>/dev/null | awk '/lookup main/ {gsub(":", "", $1); print $1}' | sort -n | head -n1
}

pick_fwmark_pref() {
  local main_pref
  main_pref="$(get_earliest_main_pref || true)"
  if [[ -z "${main_pref:-}" ]]; then
    echo 10
    return
  fi
  local p=$((main_pref - 1))
  (( p < 1 )) && p=1
  # 经验：给个更“明显”的空间（避免被别的早期规则夹住）
  # 如果 main_pref 很小（比如 10），那就用 5
  if (( p > 10 )); then
    echo 10
  else
    echo "$p"
  fi
}

### ====== dnsmasq 覆盖配置（按你给的内容原样） ======
write_dnsmasq_conf_override() {
  info "覆盖写入 dnsmasq 主配置：${DNSMASQ_MAIN}"
  cp -a "${DNSMASQ_MAIN}" "${DNSMASQ_MAIN}.bak.${DNSMASQ_PANEL_TAG}.$(date +%F_%T)" 2>/dev/null || true

  cat > "${DNSMASQ_MAIN}" <<'EOF'
# Managed by gemini-warp-manager
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

filterwin2k

no-resolv
server=1.0.0.1
server=8.8.8.8
cache-size=2048
local-ttl=60
listen-address=127.0.0.1

ipset=/gemini.google.com/warp4
ipset=/proactivebackend-pa.googleapis.com/warp4
ipset=/aisandbox-pa.googleapis.com/warp4
ipset=/robinfrontend-pa.googleapis.com/warp4
ipset=/aistudio.google.com/warp4
ipset=/alkalimakersuite-pa.clients6.google.com/warp4
ipset=/generativelanguage.googleapis.com/warp4
ipset=/alkalicore-pa.clients6.google.com/warp4
ipset=/waa-pa.clients6.google.com/warp4

# 配置目录
conf-dir=/etc/dnsmasq.d
EOF
}

### ====== resolv.conf 处理（可能被 chattr +i 锁过） ======
unlock_resolv_if_immutable() {
  if has_cmd lsattr && lsattr /etc/resolv.conf 2>/dev/null | grep -q '\-i\-'; then
    # 这种输出格式不一定统一，稳妥用 grep i
    true
  fi
  if has_cmd lsattr && lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
    warn "/etc/resolv.conf 可能被设置了不可变（chattr +i），尝试解锁..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
}

set_resolv_local() {
  unlock_resolv_if_immutable
  cp -a /etc/resolv.conf "/etc/resolv.conf.bak.${DNSMASQ_PANEL_TAG}.$(date +%F_%T)" 2>/dev/null || true
  printf "nameserver 127.0.0.1\nnameserver 127.0.0.1\n" > /etc/resolv.conf
}

set_resolv_public() {
  unlock_resolv_if_immutable
  cp -a /etc/resolv.conf "/etc/resolv.conf.bak.${DNSMASQ_PANEL_TAG}.$(date +%F_%T)" 2>/dev/null || true
  printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf
}

### ====== 安装依赖 ======
install_deps() {
  info "安装依赖：ipset dnsmasq dnsutils iptables iptables-persistent wg(可选)"
  apt-get update -y
  apt-get install -y ipset dnsmasq dnsutils iptables iptables-persistent >/dev/null
  # wg / wg-quick 可能已由 wireguard-tools 提供；尽量装上但不强制失败
  apt-get install -y wireguard-tools >/dev/null 2>&1 || true
}

### ====== 创建 ipset ======
ensure_ipsets() {
  info "确保 ipset 集合存在：${IPSET4}"
  ipset create "${IPSET4}" hash:ip family inet -exist
}

### ====== 清理旧 iptables / ip rule 残留（避免 0x51820 / 重复） ======
cleanup_old_rules() {
  info "清理旧残留规则（iptables/ip rule）"

  # 删除所有 fwmark 0x51820 的 rule
  while ip rule 2>/dev/null | grep -q 'fwmark 0x51820'; do
    local pref
    pref="$(ip rule | awk '/fwmark 0x51820/ {gsub(":", "", $1); print $1; exit}')"
    [[ -n "${pref:-}" ]] && ip rule del pref "${pref}" 2>/dev/null || break
  done

  # 删除所有 fwmark 0x1 lookup <wg_table> 的 rule（稍后按正确 pref 重加）
  local wg_table
  wg_table="$(detect_wg_table)"
  while ip rule 2>/dev/null | grep -qE "fwmark ${MARK_HEX}.*lookup ${wg_table}\b"; do
    local pref
    pref="$(ip rule | awk -v m="${MARK_HEX}" -v t="${wg_table}" '$0 ~ m && $0 ~ ("lookup "t"$") {gsub(":", "", $1); print $1; exit}')"
    [[ -n "${pref:-}" ]] && ip rule del pref "${pref}" 2>/dev/null || break
  done

  # 清理 mangle OUTPUT 中 warp4 的 MARK（删旧的 0x51820/重复）
  iptables -t mangle -D OUTPUT -m set --match-set "${IPSET4}" dst -j MARK --set-xmark 0x51820/0xffffffff 2>/dev/null || true
  iptables -t mangle -D OUTPUT -m set --match-set "${IPSET4}" dst -j MARK --set-xmark 0x1/0xffffffff     2>/dev/null || true
}

ensure_iptables_mark() {
  info "设置 iptables 打标：命中 ipset(${IPSET4}) -> MARK ${MARK_HEX}"
  # 幂等：先删同样的再加
  iptables -t mangle -D OUTPUT -m set --match-set "${IPSET4}" dst -j MARK --set-xmark 0x1/0xffffffff 2>/dev/null || true
  iptables -t mangle -A OUTPUT -m set --match-set "${IPSET4}" dst -j MARK --set-xmark 0x1/0xffffffff
  netfilter-persistent save >/dev/null 2>&1 || true
}

ensure_policy_routing() {
  local wg_table pref
  wg_table="$(detect_wg_table)"
  pref="$(pick_fwmark_pref)"

  info "确保 wgcf 路由表：${wg_table} 存在 default dev ${WG_IF}"
  ip route replace default dev "${WG_IF}" table "${wg_table}" 2>/dev/null || true

  info "添加 ip rule（必须排在 lookup main 之前）：pref ${pref} fwmark ${MARK_HEX} -> table ${wg_table}"
  ip rule add pref "${pref}" fwmark "${MARK_HEX}" lookup "${wg_table}" 2>/dev/null || true

  ip route flush cache || true
}

install_persist_service() {
  local wg_table pref
  wg_table="$(detect_wg_table)"
  pref="$(pick_fwmark_pref)"

  info "安装持久化 systemd 服务：开机/重启后自动补 ip rule（避免丢失/顺序错）"
  cat > "${POLICY_SERVICE}" <<EOF
[Unit]
Description=Persist WARP policy routing (fwmark ${MARK_HEX} -> table ${wg_table})
After=network-online.target wg-quick@wgcf.service dnsmasq.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'ip route replace default dev ${WG_IF} table ${wg_table}; ip rule add pref ${pref} fwmark ${MARK_HEX} lookup ${wg_table} 2>/dev/null || true; ip route flush cache || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now gemini-warp-policy.service >/dev/null 2>&1 || true
}

restart_dnsmasq_safe() {
  info "重启 dnsmasq 并检查 53 端口"
  systemctl restart dnsmasq
  if ! ss -lunp | grep -q ':53 .*dnsmasq'; then
    err "dnsmasq 未监听 53（会导致 resolv.conf=127.0.0.1 时断网）。请检查：journalctl -u dnsmasq -n 100"
    exit 1
  fi
  ok "dnsmasq 正常监听 53"
}

warmup() {
  info "触发一次解析，让 ipset 自动入条目"
  dig +short A gemini.google.com @127.0.0.1 >/dev/null 2>&1 || true
}

### ====== 写入 wgcf.conf PostUp/PostDown（防止 ip rule 被清掉） ======
# 重要：绝不覆盖用户已有的 PostUp/PostDown（例如 prio 18 的 from 公网IP lookup main）
# 我们只“追加/更新带标记的两行”，避免 wg-quick 重启时报错或导致失联。
fix_iprule_postup() {
  # 用法：
  #   fix_iprule_postup            # 写入并尽量立即生效（会尝试重启 wg-quick@wgcf）
  #   fix_iprule_postup quiet      # 静默写入（默认不重启，只补内核 rule）
  local quiet="${1:-}"
  local conf="/etc/wireguard/wgcf.conf"
  local tag="# ${DNSMASQ_PANEL_TAG}"

  [[ -f "$conf" ]] || { [[ "$quiet" == "quiet" ]] || warn "未找到 $conf，跳过写入 PostUp/PostDown（如果你不是用 wg-quick@wgcf 启动，可忽略）"; return 0; }

  # 必须有 [Interface]
  grep -qE '^\[Interface\]' "$conf" || { err "$conf 缺少 [Interface] 段，已中止"; return 1; }

  local wg_table pref main_pref
  wg_table="$(detect_wg_table)"
  pref="$(pick_fwmark_pref)"
  main_pref="$(get_earliest_main_pref || true)"

  [[ "$quiet" == "quiet" ]] || info "写入 wgcf.conf（不覆盖原 PostUp/PostDown）：table=${wg_table}, pref=${pref}, main_pref=${main_pref:-?}"

  # 我们自己的两行（带 tag），仅更新/插入它们，不动其它 PostUp/PostDown
  local postup postdown
  postup="PostUp = ip route replace default dev ${WG_IF} table ${wg_table}; ip rule add pref ${pref} fwmark ${MARK_HEX} lookup ${wg_table} 2>/dev/null || true; ip route flush cache || true ${tag}"
  postdown="PostDown = ip rule del pref ${pref} 2>/dev/null || true ${tag}"

  # 备份
  cp -a "$conf" "${conf}.bak.${DNSMASQ_PANEL_TAG}.$(date +%F_%T)" 2>/dev/null || true

  # 重写文件：
  # - 若已存在带 tag 的两行：替换成最新内容（适配不同 table/pref）
  # - 若不存在：在 [Interface] 段内、遇到第一个 [Peer] 前插入两行
  awk -v up="$postup" -v down="$postdown" -v tag="$tag" '
    BEGIN{in_if=0; inserted=0; seen_tag=0;}
    /^\[Interface\]$/ {in_if=1; print; next}
    /^\[Peer\]$/ {
      if (in_if==1 && inserted==0 && seen_tag==0) { print up; print down; inserted=1 }
      in_if=0
      print
      next
    }
    {
      if (in_if==1) {
        # 仅替换我们自己的带 tag 行
        if ($0 ~ tag "$") {
          seen_tag=1
          if ($0 ~ /^PostUp[[:space:]]*=/)   { print up;   next }
          if ($0 ~ /^PostDown[[:space:]]*=/) { print down; next }
        }
      }
      print
    }
    END{
      if (in_if==1 && inserted==0 && seen_tag==0) { print up; print down }
    }
  ' "$conf" > "${conf}.tmp.${DNSMASQ_PANEL_TAG}" && mv "${conf}.tmp.${DNSMASQ_PANEL_TAG}" "$conf"

  [[ "$quiet" == "quiet" ]] || ok "已写入/更新 ${tag} PostUp/PostDown（不会覆盖原规则）"

  # 静默模式默认不重启，避免 SSH 瞬断；但会先补一次内核 rule，确保立刻可用
  ip route replace default dev "${WG_IF}" table "${wg_table}" 2>/dev/null || true
  ip rule add pref "${pref}" fwmark "${MARK_HEX}" lookup "${wg_table}" 2>/dev/null || true
  ip route flush cache || true

  if [[ "$quiet" != "quiet" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^wg-quick@wgcf\.service'; then
    # 菜单4手动修复时尝试重启让 PostUp 真正接管；失败也不致命
    systemctl restart wg-quick@wgcf >/dev/null 2>&1 || true
  fi
}


### ====== 状态检查（你要的“路由优先情况提示 + 打标是否正常”） ======
check_status() {
  echo
  echo "${BOLD}====== 运行状态检查 ======${RESET}"

  # 安装检查
  echo
  echo "${BOLD}组件安装情况：${RESET}"
  if has_cmd wg; then ok "wg（WireGuard 工具）已安装"; else err "wg 未安装（建议 apt install wireguard-tools）"; fi
  if has_cmd iptables; then ok "iptables 已安装"; else err "iptables 未安装"; fi
  if has_cmd ipset; then ok "ipset 已安装"; else err "ipset 未安装"; fi
  if has_cmd dnsmasq; then ok "dnsmasq 已安装"; else err "dnsmasq 未安装"; fi
  if has_cmd dig; then ok "dnsutils(dig) 已安装"; else err "dnsutils 未安装"; fi

  # 服务检查
  echo
  echo "${BOLD}服务运行情况：${RESET}"
  if svc_active dnsmasq; then ok "dnsmasq 正在运行"; else err "dnsmasq 未运行（systemctl start dnsmasq）"; fi
  if ip link show "${WG_IF}" >/dev/null 2>&1; then ok "接口 ${WG_IF} 存在"; else warn "接口 ${WG_IF} 不存在（wgcf 可能未启动/未安装）"; fi
  if svc_active "wg-quick@wgcf"; then ok "wg-quick@wgcf 正在运行"; else warn "wg-quick@wgcf 未运行（若你用的是别的方式启动 wgcf 可忽略）"; fi

  # DNS 检查
  echo
  echo "${BOLD}DNS 检查：${RESET}"
  if ss -lunp | grep -q ':53 .*dnsmasq'; then ok "dnsmasq 正在监听 53"; else err "dnsmasq 未监听 53（resolv.conf=127.0.0.1 会断网）"; fi
  echo "resolv.conf："
  sed -n '1,5p' /etc/resolv.conf || true
  if grep -qE '^\s*nameserver\s+127\.0\.0\.1' /etc/resolv.conf; then
    ok "当前 DNS 指向 127.0.0.1（dnsmasq）"
  else
    warn "当前 DNS 非 127.0.0.1（若要用 ipset 自动入条目，建议用 dnsmasq 并指向本机）"
  fi

# ===== 策略路由优先级检查（修正版） =====
echo
echo "${BOLD}策略路由优先级检查（关键）：${RESET}"
wg_table="$(detect_wg_table)"
main_pref="$(get_earliest_main_pref || true)"

echo "ip rule（前 30 行）："
ip rule | sed -n '1,30p'

# 统一用 ip -d rule show（信息更完整）
rules_d="$(ip -d rule show 2>/dev/null || true)"

# 1) 判断是否存在：只要同一行同时包含 fwmark + lookup <table> 即认为存在
#    并且 fwmark 的值解析成数字后等于 1
found_fwmark_rule="0"
fw_pref=""

while read -r line; do
  # 例：10: from all fwmark 0x1 lookup 51820
  # 或：1000: from all fwmark 0x00000001/0xffffffff lookup 51820
  # 或：1000: from all fwmark 1 lookup 51820
  if echo "$line" | grep -q "lookup ${wg_table}\b" && echo "$line" | grep -q "fwmark"; then
    pref="$(echo "$line" | awk '{gsub(":", "", $1); print $1}')"
    m="$(echo "$line" | sed -n 's/.*fwmark[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | cut -d/ -f1)"
    # m 可能是 0x1 / 0x00000001 / 1
    if [[ "$m" =~ ^0x ]]; then
      m_dec=$((16#${m#0x}))
    else
      m_dec=$((m))
    fi
    if (( m_dec == 1 )); then
      found_fwmark_rule="1"
      fw_pref="$pref"
      break
    fi
  fi
done <<< "$rules_d"

if [[ "$found_fwmark_rule" == "1" ]]; then
  ok "已找到 fwmark=1 -> lookup ${wg_table}（pref=${fw_pref}）"
else
  err "未找到 fwmark=1 -> lookup ${wg_table} 的规则（分流不会生效）"
fi

# 2) 解析 main 的最小 pref（纯数字）
main_pref="$(echo "$rules_d" | awk '/lookup main/ {gsub(":", "", $1); print $1}' | sort -n | head -n1)"

if [[ -n "${fw_pref:-}" && -n "${main_pref:-}" ]]; then
  if (( fw_pref < main_pref )); then
    ok "优先级正确：fwmark(pref=${fw_pref}) 在 lookup main(pref=${main_pref}) 之前 ✅"
  else
    err "优先级错误：fwmark(pref=${fw_pref}) 在 lookup main(pref=${main_pref}) 之后 ❌（会出现“打标但走原IP”）"
    warn "建议把 fwmark 规则放到 pref $((main_pref-1)) 之前"
  fi
else
  warn "未能解析到 fwmark/main 的 pref 数值（可能输出格式变化或规则缺失）"
fi

  # iptables 打标检查
  echo
  echo "${BOLD}iptables 打标检查：${RESET}"
  echo "iptables -t mangle -S OUTPUT："
  iptables -t mangle -S OUTPUT || true
  echo
  echo "计数器（命中 ipset 会增长）："
  iptables -t mangle -L OUTPUT -n -v --line-numbers || true

  # ipset 条目检查
  echo
  echo "${BOLD}ipset 条目检查：${RESET}"
  if ipset list "${IPSET4}" >/dev/null 2>&1; then
    cnt="$(ipset list "${IPSET4}" 2>/dev/null | awk '/Number of entries/ {print $4; exit}')"
    echo "warp4 条目数：${cnt:-unknown}"
    echo "warp4 Members 前 5 条："
    ipset list "${IPSET4}" 2>/dev/null | awk '
      /^Members:/ {flag=1; next}
      flag && NF {print; c++}
      c==5 {exit}
    '
  else
    err "ipset ${IPSET4} 不存在"
  fi

  # 快速验证：解析 gemini 并提示
  echo
  echo "${BOLD}快速验证提示：${RESET}"
  echo "执行：nslookup gemini.google.com（应走 127.0.0.1 并解析成功）"
  echo "执行：dig +short A gemini.google.com @127.0.0.1（会触发入 ipset）"
  echo "提示：一键安装后节点即可访问 gemini（你的分流模式下，普通 ifconfig.me 仍可能显示原 IP，这属于正常现象）"
}

### ====== 一键安装（你要的“gemini 优先脚本”） ======
install_all() {
  echo
  echo "${BOLD}====== 一键安装：Gemini 优先（dnsmasq + ipset + iptables + policy routing） ======${RESET}"

  install_deps
  ensure_ipsets

  # 覆盖 dnsmasq 配置（按你提供的内容）
  write_dnsmasq_conf_override
  restart_dnsmasq_safe

  # resolv.conf 指向本机 dnsmasq（你已确认用 kill53 方式也可以）
  set_resolv_local

  cleanup_old_rules
  ensure_iptables_mark
  ensure_policy_routing
  install_persist_service

  # 写入 wgcf.conf PostUp/PostDown，避免其它脚本/重启清掉 ip rule
  fix_iprule_postup quiet

    warmup

  ok "安装完成：一键安装后节点即可访问 Gemini 成功 ✅"
  warn "提示：分流模式下，未命中 ipset 的网站仍走原 IP，这是正常的。"
}

### ====== 清除还原 ======
restore_all() {
  echo
  echo "${BOLD}====== 清除还原设置 ======${RESET}"

  info "停止并移除持久化服务"
  systemctl disable --now gemini-warp-policy.service >/dev/null 2>&1 || true
  rm -f "${POLICY_SERVICE}" || true
  systemctl daemon-reload || true

  info "移除 ip rule（fwmark 0x1 -> table 51820）"
  local wg_table
  wg_table="$(detect_wg_table)"
  while ip rule 2>/dev/null | grep -qE "fwmark ${MARK_HEX}.*lookup ${wg_table}\b"; do
    local pref
    pref="$(ip rule | awk -v m="${MARK_HEX}" -v t="${wg_table}" '$0 ~ m && $0 ~ ("lookup "t"$") {gsub(":", "", $1); print $1; exit}')"
    [[ -n "${pref:-}" ]] && ip rule del pref "${pref}" 2>/dev/null || break
  done
  ip route flush cache || true

  info "移除 iptables mangle OUTPUT 打标规则"
  iptables -t mangle -D OUTPUT -m set --match-set "${IPSET4}" dst -j MARK --set-xmark 0x1/0xffffffff 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true

  info "可选：清空/删除 ipset（谨慎：如果你还有别的用途就别删）"
  ipset flush "${IPSET4}" 2>/dev/null || true
  # ipset destroy "${IPSET4}" 2>/dev/null || true

  info "还原 DNS：改为公网 DNS（防止本机 dnsmasq 配置出错导致断网）"
  set_resolv_public

  info "dnsmasq 配置处理：不强制恢复原文件，只保留备份供你手动回滚"
  warn "dnsmasq.conf 已被覆盖过，备份位于：${DNSMASQ_MAIN}.bak.${DNSMASQ_PANEL_TAG}.*"
  warn "如需回滚：把备份复制回 ${DNSMASQ_MAIN} 并 systemctl restart dnsmasq"

  # 仅移除我们写入 wgcf.conf 的带标记 PostUp/PostDown，不影响原有规则
  if [[ -f /etc/wireguard/wgcf.conf ]]; then
    sed -i "/# ${DNSMASQ_PANEL_TAG}\$/d" /etc/wireguard/wgcf.conf 2>/dev/null || true
  fi

  ok "清除还原完成"
}

### ====== 面板头部：显示安装/运行状态（缺失红字） ======
panel_header() {
  clear || true
  echo "${BOLD}================== Gemini WARP 分流管理面板 ==================${RESET}"
  echo "标记：fwmark ${MARK_HEX} -> table $(detect_wg_table) / ipset=${IPSET4} / DNS=dnsmasq(127.0.0.1)"
  echo "----------------------------------------------------------------"
  echo -n "WARP(wgcf/wg)："
  if has_cmd wg && (ip link show "${WG_IF}" >/dev/null 2>&1); then
    echo -e " ${GREEN}已就绪${RESET}"
  else
    echo -e " ${RED}未就绪（wg 或 wgcf接口缺失）${RESET}"
  fi

  echo -n "iptables："
  if has_cmd iptables; then echo -e " ${GREEN}已安装${RESET}"; else echo -e " ${RED}未安装${RESET}"; fi
  echo -n "ipset："
  if has_cmd ipset; then echo -e " ${GREEN}已安装${RESET}"; else echo -e " ${RED}未安装${RESET}"; fi
  echo -n "dnsmasq："
  if has_cmd dnsmasq; then
    if svc_active dnsmasq; then echo -e " ${GREEN}已安装/运行中${RESET}"; else echo -e " ${YELLOW}已安装但未运行${RESET}"; fi
  else
    echo -e " ${RED}未安装${RESET}"
  fi
  echo -n "DNS 监听(53)："
  if ss -lunp 2>/dev/null | grep -q ':53 .*dnsmasq'; then echo -e " ${GREEN}OK${RESET}"; else echo -e " ${RED}异常${RESET}"; fi
  echo "----------------------------------------------------------------"
}

menu() {
  panel_header
  echo
  echo "${BOLD}请选择操作：${RESET}"
  echo "  1) 一键安装 Gemini 优先脚本（dnsmasq 配置覆盖 + ipset + iptables + 路由优先级修复）"
  echo "  2) 清除还原设置"
  echo "  3) 检查运行状态（路由优先级 / ipset 打标 / dnsmasq 等）"
  echo "  4) 修复 iprule：写入 wgcf.conf PostUp/PostDown（自动识别表号/优先级）"
  echo "  0) 退出"
  echo
  read -r -p "输入选项 [0-4]: " choice
  case "${choice:-}" in
    1) install_all; pause ;;
    2) restore_all; pause ;;
    3) check_status; pause ;;
    4) fix_iprule_postup; pause ;;
    0) exit 0 ;;
    *) warn "无效选项"; pause ;;
  esac
}

main() {
  need_root
  while true; do
    menu
  done
}

main "$@"