#!/bin/bash

# 重置H UI管理员密码脚本

reset_password() {
    # 检查systemd安装方式
    if systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
        if ! version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
            echo "错误：H UI (systemd) 版本必须大于等于 v0.0.12"
            exit 1
        fi
        echo "正在重置systemd安装的H UI密码..."
        export HUI_DATA="/usr/local/h-ui/"
        reset_output=$("${HUI_DATA}h-ui" reset)
        echo -e "\033[33m${reset_output}\033[0m"
    fi

    # 检查Docker安装方式
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q '^h-ui$'; then
        if ! version_ge "$(docker exec h-ui ./h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
            echo "错误：H UI (Docker) 版本必须大于等于 v0.0.12"
            exit 1
        fi
        echo "正在重置Docker安装的H UI密码..."
        reset_output=$(docker exec h-ui ./h-ui reset)
        echo -e "\033[33m${reset_output}\033[0m"
    fi

    # 如果都没有安装
    if ! { systemctl list-units --type=service --all | grep -q 'h-ui.service' || 
          { command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -q '^h-ui$'; }; }; then
        echo "错误：未找到H UI安装"
        exit 1
    fi
}

# 版本比较函数
version_ge() {
    local v1=${1#v}
    local v2=${2#v}

    [[ "$v1" == "latest" ]] && return 0

    IFS='.' read -r -a v1_parts <<<"$v1"
    IFS='.' read -r -a v2_parts <<<"$v2"

    for i in "${!v1_parts[@]}"; do
        local part1=${v1_parts[i]:-0}
        local part2=${v2_parts[i]:-0}

        if (( 10#${part1} < 10#${part2} )); then
            return 1
        elif (( 10#${part1} > 10#${part2} )); then
            return 0
        fi
    done
    return 0
}

# 主执行
if [[ $(id -u) != "0" ]]; then
    echo "必须使用root权限运行此脚本"
    exit 1
fi

reset_password
