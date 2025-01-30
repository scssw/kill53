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
    ${ECHO_TYPE} "\033[31m$2\033[0m" ;;
  "green")
    ${ECHO_TYPE} "\033[32m$2\033[0m" ;;
  "yellow")
    ${ECHO_TYPE} "\033[33m$2\033[0m" ;;
  "skyBlue")
    ${ECHO_TYPE} "\033[36m$2\033[0m" ;;
  esac
}

check_sys() {
  [[ $(id -u) != "0" ]] && { echo_content red "必须使用root权限运行"; exit 1; }
  ! command -v systemctl &>/dev/null && { echo_content red "系统未使用systemd"; exit 1; }
  [[ ! -f "/usr/local/h-ui/h-ui" ]] && { echo_content red "未找到H UI安装"; exit 1; }
}

get_latest_version() {
  latest_version=$(curl -sL https://api.github.com/repos/scssw/h-ui/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
  [[ -z "$latest_version" ]] && { echo_content red "无法获取最新版本号"; exit 1; }
  echo "$latest_version"
}

upgrade_h_ui() {
  check_sys
  current_version=$(/usr/local/h-ui/h-ui -v | awk '{print $3}')
  latest_version=$(get_latest_version)

  [[ "$latest_version" == "$current_version" ]] && { echo_content skyBlue "当前已是最新版本: ${current_version}"; exit 0; }

  echo_content green "正在升级 H UI (${current_version} -> ${latest_version})"
  
  systemctl stop h-ui || { echo_content red "停止服务失败"; exit 1; }

  case $(arch) in
    x86_64)  arch_name="amd64" ;;
    aarch64) arch_name="arm64" ;;
    *)       echo_content red "不支持的架构"; exit 1 ;;
  esac

  download_url="https://github.com/scssw/h-ui/releases/download/${latest_version}/h-ui-linux-${arch_name}"
  if ! curl -fsSL "$download_url" -o "/usr/local/h-ui/h-ui"; then
    echo_content red "下载失败: $download_url"
    exit 1
  fi

  chmod +x /usr/local/h-ui/h-ui
  systemctl restart h-ui || { echo_content red "启动服务失败"; exit 1; }

  echo_content skyBlue "升级完成，当前版本: $(/usr/local/h-ui/h-ui -v | awk '{print $3}')"
}

main() {
  init_var
  upgrade_h_ui
}

main
