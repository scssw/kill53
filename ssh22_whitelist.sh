#!/usr/bin/env bash
set -euo pipefail

CHAIN="SSH22_WHITELIST"
PORT="22"
WHITELIST_FILE="/etc/ssh22_whitelist.list"
APPLY_SCRIPT="/usr/local/sbin/ssh22-whitelist-apply"
RESTORE_HOOK="/etc/network/if-pre-up.d/ssh22-whitelist"
SSR_SERVER_SCRIPT="/usr/local/SSR-Bash-Python/server.sh"
IPTABLES_BIN=""
IPTABLES_SAVE_BIN=""

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "请用 root 运行：sudo bash $0"
        exit 1
    fi
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "缺少命令：$1"
        exit 1
    fi
}

cmd_path() {
    command -v "$1" 2>/dev/null || true
}

chain_exists_with() {
    local bin="$1"
    [[ -n "$bin" ]] && "$bin" -nL "$CHAIN" >/dev/null 2>&1
}

has_append_rules_with_save() {
    local bin="$1"
    [[ -n "$bin" ]] || return 1
    "$bin" 2>/dev/null | awk '$1 == "-A" { found = 1; exit } END { exit !found }'
}

select_iptables_backend() {
    local default_iptables default_save legacy_iptables legacy_save nft_iptables nft_save

    default_iptables="$(cmd_path iptables)"
    default_save="$(cmd_path iptables-save)"
    legacy_iptables="$(cmd_path iptables-legacy)"
    legacy_save="$(cmd_path iptables-legacy-save)"
    nft_iptables="$(cmd_path iptables-nft)"
    nft_save="$(cmd_path iptables-nft-save)"

    if chain_exists_with "$legacy_iptables"; then
        IPTABLES_BIN="$legacy_iptables"
        IPTABLES_SAVE_BIN="${legacy_save:-$default_save}"
    elif chain_exists_with "$nft_iptables"; then
        IPTABLES_BIN="$nft_iptables"
        IPTABLES_SAVE_BIN="${nft_save:-$default_save}"
    elif has_append_rules_with_save "$legacy_save"; then
        IPTABLES_BIN="${legacy_iptables:-$default_iptables}"
        IPTABLES_SAVE_BIN="${legacy_save:-$default_save}"
    else
        IPTABLES_BIN="$default_iptables"
        IPTABLES_SAVE_BIN="$default_save"
    fi

    if [[ -z "$IPTABLES_BIN" || -z "$IPTABLES_SAVE_BIN" ]]; then
        echo "缺少命令：iptables 或 iptables-save"
        exit 1
    fi
}

iptables_cmd() {
    "$IPTABLES_BIN" "$@"
}

iptables_save_cmd() {
    "$IPTABLES_SAVE_BIN" "$@"
}

validate_ip_or_cidr() {
    local item="$1"
    local ip="${item%/*}"
    local cidr=""

    if [[ "$item" == */* ]]; then
        cidr="${item#*/}"
        [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
        (( cidr >= 0 && cidr <= 32 )) || return 1
    fi

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    local -a octets
    read -r -a octets <<< "$ip"
    local octet
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

ensure_chain() {
    if ! iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        iptables_cmd -N "$CHAIN"
    fi

    while iptables_cmd -C "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; do
        iptables_cmd -D "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    iptables_cmd -I "$CHAIN" 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    while iptables_cmd -C "$CHAIN" -j DROP >/dev/null 2>&1; do
        iptables_cmd -D "$CHAIN" -j DROP
    done
    iptables_cmd -A "$CHAIN" -j DROP

    while iptables_cmd -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; do
        iptables_cmd -D INPUT -p tcp --dport "$PORT" -j "$CHAIN"
    done
    iptables_cmd -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
}

whitelist_file_has_entries() {
    [[ -f "$WHITELIST_FILE" ]] || return 1
    awk '
        /^[[:space:]]*($|#)/ { next }
        { found = 1; exit }
        END { exit !found }
    ' "$WHITELIST_FILE"
}

restore_chain_from_whitelist_file() {
    local item

    if ! iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        iptables_cmd -N "$CHAIN"
    fi

    iptables_cmd -F "$CHAIN"
    iptables_cmd -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    while IFS= read -r item; do
        item="${item%%#*}"
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        if validate_ip_or_cidr "$item"; then
            iptables_cmd -A "$CHAIN" -s "$item" -j ACCEPT
        else
            echo "跳过白名单文件中的无效项：$item"
        fi
    done < "$WHITELIST_FILE"

    iptables_cmd -A "$CHAIN" -j DROP
    while iptables_cmd -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; do
        iptables_cmd -D INPUT -p tcp --dport "$PORT" -j "$CHAIN"
    done
    iptables_cmd -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
}

repair_existing_whitelist() {
    if iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        ensure_chain
        install_restore_files
        echo "已修复现有白名单规则：22 端口跳转已放到 INPUT 链最前。"
    elif whitelist_file_has_entries; then
        restore_chain_from_whitelist_file
        install_restore_files
        echo "已根据 $WHITELIST_FILE 恢复 22 端口白名单规则。"
    fi
}

install_restore_files() {
    mkdir -p "$(dirname "$RESTORE_HOOK")"
    mkdir -p "$(dirname "$APPLY_SCRIPT")"

    cat > "$APPLY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

CHAIN="SSH22_WHITELIST"
PORT="22"
WHITELIST_FILE="/etc/ssh22_whitelist.list"
IPTABLES_BIN="$IPTABLES_BIN"

if [[ ! -x "\$IPTABLES_BIN" || ! -f "\$WHITELIST_FILE" ]]; then
    exit 0
fi

if ! "\$IPTABLES_BIN" -nL "\$CHAIN" >/dev/null 2>&1; then
    "\$IPTABLES_BIN" -N "\$CHAIN"
fi

"\$IPTABLES_BIN" -F "\$CHAIN"
"\$IPTABLES_BIN" -A "\$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

while IFS= read -r item; do
    [[ -z "\$item" || "\$item" == \#* ]] && continue
    "\$IPTABLES_BIN" -A "\$CHAIN" -s "\$item" -j ACCEPT
done < "\$WHITELIST_FILE"

"\$IPTABLES_BIN" -A "\$CHAIN" -j DROP

while "\$IPTABLES_BIN" -C INPUT -p tcp --dport "\$PORT" -j "\$CHAIN" >/dev/null 2>&1; do
    "\$IPTABLES_BIN" -D INPUT -p tcp --dport "\$PORT" -j "\$CHAIN"
done
"\$IPTABLES_BIN" -I INPUT 1 -p tcp --dport "\$PORT" -j "\$CHAIN"
EOF
    chmod +x "$APPLY_SCRIPT"

    cat > "$RESTORE_HOOK" <<EOF
#!/bin/sh
[ -x "$APPLY_SCRIPT" ] && "$APPLY_SCRIPT"
exit 0
EOF
    chmod +x "$RESTORE_HOOK"

    install_ssr_restore_hook
}

install_ssr_restore_hook() {
    [[ -f "$SSR_SERVER_SCRIPT" && -w "$SSR_SERVER_SCRIPT" ]] || return 0
    grep -q "$APPLY_SCRIPT" "$SSR_SERVER_SCRIPT" && return 0

    cp -a "$SSR_SERVER_SCRIPT" "${SSR_SERVER_SCRIPT}.bak.$(date +%Y%m%d%H%M%S)"
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v hook="[ -x \"$APPLY_SCRIPT\" ] && \"$APPLY_SCRIPT\"" '
        /^\[\[ \$serverc == 1 \]\]/ || /if \[\[ \$serverc == 1 \]\];then/ { direct = 1 }
        /^\[\[ \$serverc == 3 \]\]/ || /if \[\[ \$serverc == 3 \]\];then/ { direct = 1 }
        /if \[\[ \$serverc == 9 \]\];then/ { startup = 1; direct = 0 }
        /if \[\[ \$serverc == 10 \]\];then/ { startup = 0; direct = 0 }
        /if \[\[ \$serverc == [0-9]+ \]\];then/ && $0 !~ /serverc == (1|3|9|10)/ { direct = 0 }
        {
            print
            if ($0 ~ /^[[:space:]]*iptables-restore < \/etc\/iptables\.up\.rules[[:space:]]*$/ && (direct || startup)) {
                print hook
            }
        }
    ' "$SSR_SERVER_SCRIPT" > "$tmp_file"
    cp "$tmp_file" "$SSR_SERVER_SCRIPT"
    rm -f "$tmp_file"
}

print_whitelist_sources() {
    iptables_save_cmd | awk -v chain="$CHAIN" '
        $1 == "-A" && $2 == chain && $0 ~ /(^| )-j ACCEPT( |$)/ {
            source = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-s" && (i + 1) <= NF) {
                    source = $(i + 1)
                    break
                }
            }
            if (source != "") {
                print source
            }
        }
    '
}

persist_whitelist() {
    install_restore_files

    if iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        print_whitelist_sources > "$WHITELIST_FILE"
    else
        : > "$WHITELIST_FILE"
    fi

    echo "已持久化白名单到：$WHITELIST_FILE"
    echo "已安装独立开机恢复钩子：$RESTORE_HOOK"
    echo "当前使用 iptables 后端：$IPTABLES_BIN"
    echo "不会修改或覆盖 /etc/iptables.up.rules"
}

read_batch_items() {
    local line item
    BATCH_ITEMS=()

    echo "请输入 IP 或 CIDR，例如：1.2.3.4 或 1.2.3.0/24"
    echo "支持一行多个，空格/逗号分隔；输入空行后生效。"

    while true; do
        read -r line || true
        [[ -z "${line//[[:space:]]/}" ]] && break

        line="${line//,/ }"
        for item in $line; do
            BATCH_ITEMS+=("$item")
        done
    done
}

insert_allow_rule() {
    local item="$1"

    if iptables_cmd -C "$CHAIN" -s "$item" -j ACCEPT >/dev/null 2>&1; then
        echo "已存在：$item"
        return
    fi

    local drop_line
    drop_line="$(iptables_cmd -nL "$CHAIN" --line-numbers | awk '$2 == "DROP" {print $1; exit}')"
    if [[ -n "$drop_line" ]]; then
        iptables_cmd -I "$CHAIN" "$drop_line" -s "$item" -j ACCEPT
    else
        iptables_cmd -A "$CHAIN" -s "$item" -j ACCEPT
        iptables_cmd -A "$CHAIN" -j DROP
    fi

    echo "已添加：$item"
}

add_whitelist() {
    local ssh_ip="${SSH_CLIENT:-}"
    ssh_ip="${ssh_ip%% *}"
    if [[ -n "${ssh_ip:-}" ]]; then
        echo "当前 SSH 来源 IP 可能是：$ssh_ip"
        echo "如果你想保留当前连接来源，请把它也加入白名单。"
    fi

    read_batch_items
    if [[ "${#BATCH_ITEMS[@]}" -eq 0 ]]; then
        echo "未输入任何 IP。"
        return
    fi

    local -a valid_items=()
    local item
    for item in "${BATCH_ITEMS[@]}"; do
        if validate_ip_or_cidr "$item"; then
            valid_items+=("$item")
        else
            echo "跳过无效输入：$item"
        fi
    done

    if [[ "${#valid_items[@]}" -eq 0 ]]; then
        echo "没有有效 IP，未修改规则。"
        return
    fi

    ensure_chain
    for item in "${valid_items[@]}"; do
        insert_allow_rule "$item"
    done

    persist_whitelist
}

list_whitelist() {
    if ! iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        echo "当前没有启用 22 端口白名单。"
        return
    fi

    echo "当前 22 端口白名单："
    print_whitelist_sources | awk '
        NF > 0 {
            printf "%s. %s\n", ++n, $1
        }
        END {
            if (n == 0) print "无白名单 IP。启用状态下，新 SSH 连接会被拒绝。"
        }
    '
}

delete_one_source() {
    local item="$1"
    local deleted=0

    while iptables_cmd -C "$CHAIN" -s "$item" -j ACCEPT >/dev/null 2>&1; do
        iptables_cmd -D "$CHAIN" -s "$item" -j ACCEPT
        deleted=1
    done

    if [[ "$deleted" -eq 1 ]]; then
        echo "已删除：$item"
    else
        echo "未找到：$item"
    fi
}

delete_whitelist() {
    if ! iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        echo "当前没有启用 22 端口白名单。"
        return
    fi

    read_batch_items
    if [[ "${#BATCH_ITEMS[@]}" -eq 0 ]]; then
        echo "未输入任何 IP。"
        return
    fi

    local item
    for item in "${BATCH_ITEMS[@]}"; do
        if validate_ip_or_cidr "$item"; then
            delete_one_source "$item"
        else
            echo "跳过无效输入：$item"
        fi
    done

    persist_whitelist
}

restore_open() {
    while iptables_cmd -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; do
        iptables_cmd -D INPUT -p tcp --dport "$PORT" -j "$CHAIN"
    done

    if iptables_cmd -nL "$CHAIN" >/dev/null 2>&1; then
        iptables_cmd -F "$CHAIN"
        iptables_cmd -X "$CHAIN"
    fi

    rm -f "$WHITELIST_FILE" "$RESTORE_HOOK" "$APPLY_SCRIPT"
    echo "已恢复：22 端口不再使用白名单限制。"
    echo "已删除本脚本的持久化文件，未修改 /etc/iptables.up.rules。"
}

show_menu() {
    clear || true
    echo "SSH 22 端口白名单管理"
    echo "======================"
    echo "1. 添加 22 端口白名单 IP"
    echo "2. 查看白名单 IP"
    echo "3. 删除白名单 IP"
    echo "4. 恢复 22 端口开放"
    echo "0. 退出"
    echo
    printf "请选择："
}

main() {
    need_root
    select_iptables_backend
    repair_existing_whitelist

    local choice
    while true; do
        show_menu
        read -r choice || exit 0
        case "$choice" in
            1) add_whitelist ;;
            2) list_whitelist ;;
            3) delete_whitelist ;;
            4) restore_open ;;
            0) exit 0 ;;
            *) echo "无效选项。" ;;
        esac
        echo
        read -r -p "按回车返回菜单..." _
    done
}

main "$@"
