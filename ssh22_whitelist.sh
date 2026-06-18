#!/usr/bin/env bash
set -euo pipefail

CHAIN="SSH22_WHITELIST"
PORT="22"
WHITELIST_FILE="/etc/ssh22_whitelist.list"
APPLY_SCRIPT="/usr/local/sbin/ssh22-whitelist-apply"
RESTORE_HOOK="/etc/network/if-pre-up.d/ssh22-whitelist"

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
    if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
        iptables -N "$CHAIN"
    fi

    if ! iptables -C "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then
        iptables -I "$CHAIN" 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    fi

    if ! iptables -C "$CHAIN" -j DROP >/dev/null 2>&1; then
        iptables -A "$CHAIN" -j DROP
    fi

    if ! iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
    fi
}

install_restore_files() {
    mkdir -p "$(dirname "$RESTORE_HOOK")"
    mkdir -p "$(dirname "$APPLY_SCRIPT")"

    cat > "$APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CHAIN="SSH22_WHITELIST"
PORT="22"
WHITELIST_FILE="/etc/ssh22_whitelist.list"

if [[ ! -f "$WHITELIST_FILE" ]]; then
    exit 0
fi

if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
    iptables -N "$CHAIN"
fi

iptables -F "$CHAIN"
iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

while IFS= read -r item; do
    [[ -z "$item" || "$item" == \#* ]] && continue
    iptables -A "$CHAIN" -s "$item" -j ACCEPT
done < "$WHITELIST_FILE"

iptables -A "$CHAIN" -j DROP

while iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; do
    iptables -D INPUT -p tcp --dport "$PORT" -j "$CHAIN"
done
iptables -I INPUT 1 -p tcp --dport "$PORT" -j "$CHAIN"
EOF
    chmod +x "$APPLY_SCRIPT"

    cat > "$RESTORE_HOOK" <<EOF
#!/bin/sh
[ -x "$APPLY_SCRIPT" ] && "$APPLY_SCRIPT"
exit 0
EOF
    chmod +x "$RESTORE_HOOK"
}

print_whitelist_sources() {
    iptables-save | awk -v chain="$CHAIN" '
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

    if iptables -nL "$CHAIN" >/dev/null 2>&1; then
        print_whitelist_sources > "$WHITELIST_FILE"
    else
        : > "$WHITELIST_FILE"
    fi

    echo "已持久化白名单到：$WHITELIST_FILE"
    echo "已安装独立开机恢复钩子：$RESTORE_HOOK"
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

    if iptables -C "$CHAIN" -s "$item" -j ACCEPT >/dev/null 2>&1; then
        echo "已存在：$item"
        return
    fi

    local drop_line
    drop_line="$(iptables -nL "$CHAIN" --line-numbers | awk '$2 == "DROP" {print $1; exit}')"
    if [[ -n "$drop_line" ]]; then
        iptables -I "$CHAIN" "$drop_line" -s "$item" -j ACCEPT
    else
        iptables -A "$CHAIN" -s "$item" -j ACCEPT
        iptables -A "$CHAIN" -j DROP
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
    if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
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

    while iptables -C "$CHAIN" -s "$item" -j ACCEPT >/dev/null 2>&1; do
        iptables -D "$CHAIN" -s "$item" -j ACCEPT
        deleted=1
    done

    if [[ "$deleted" -eq 1 ]]; then
        echo "已删除：$item"
    else
        echo "未找到：$item"
    fi
}

delete_whitelist() {
    if ! iptables -nL "$CHAIN" >/dev/null 2>&1; then
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
    while iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" >/dev/null 2>&1; do
        iptables -D INPUT -p tcp --dport "$PORT" -j "$CHAIN"
    done

    if iptables -nL "$CHAIN" >/dev/null 2>&1; then
        iptables -F "$CHAIN"
        iptables -X "$CHAIN"
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
    need_cmd iptables
    need_cmd iptables-save

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
