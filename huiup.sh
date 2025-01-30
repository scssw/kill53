#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

init_var() {
  ECHO_TYPE="echo -e"
  HUI_DATA_SYSTEMD="/usr/local/h-ui/"
}

echo_content() {
  case $1 in
  "red")
    ${ECHO_TYPE} "\033[31m$2\033[0m"
    ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m"
    ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m"
    ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m"
    ;;
  esac
}

version_ge() {
  local v1=${1#v}
  local v2=${2#v}

  if [[ -z "$v1" || "$v1" == "latest" ]]; then
    return 0
  fi

  IFS='.' read -r -a v1_parts <<<"$v1"
  IFS='.' read -r -a v2_parts <<<"$v2"

  for i in "${!v1_parts[@]}"; do
    local part1=${v1_parts[i]:-0}
    local part2=${v2_parts[i]:-0}

    if [[ "$part1" < "$part2" ]]; then
      return 1
    elif [[ "$part1" > "$part2" ]]; then
      return 0
    fi
  done
  return 0
}

check_sys() {
  if [[ $(id -u) != "0" ]]; then
    echo_content red "必须使用root权限运行"
    exit 1
  fi

  if ! command -v systemctl &> /dev/null; then
    echo_content red "系统未使用systemd"
    exit 1
  fi

  if [[ ! -f "/usr/local/h-ui/h-ui" ]]; then
    echo_content red "未找到H UI安装"
    exit 1
  fi
}

upgrade_h_ui() {
  check_sys

  latest_version=$(curl -Ls "https://api.github.com/repos/scssw/h-ui/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",.*/\1')
  current_version=$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')

  if [[ "${latest_version}" == "${current_version}" ]]; then
    echo_content skyBlue "当前已是最新版本: ${current_version}"
    exit 0
  fi

  echo_content green "正在升级 H UI (${current_version} -> ${latest_version})"
  
  if systemctl is-active --quiet h-ui; then
    systemctl stop h-ui
  fi

  get_arch=$(arch)
  [[ $get_arch =~ "x86_64" ]] && get_arch="amd64"
  [[ $get_arch =~ "aarch64" ]] && get_arch="arm64"

  curl -fsSL "https://github.com/scssw/h-ui/releases/download/${latest_version}/h-ui-linux-${get_arch}" -o /usr/local/h-ui/h-ui &&
    chmod +x /usr/local/h-ui/h-ui &&
    systemctl restart h-ui

  echo_content skyBlue "升级完成，当前版本: ${latest_version}"
}

main() {
  init_var
  upgrade_h_ui
}

main
