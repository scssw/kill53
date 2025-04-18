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
  latest_version=$(curl -sL https://api.github.com/repos/scssw/uiup/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
  [[ -z "$latest_version" ]] && { echo_content red "无法获取最新版本号"; exit 1; }
  echo "$latest_version"
}

check_version_exists() {
  local version=$1
  local exists=$(curl -sL https://api.github.com/repos/scssw/uiup/releases/tags/${version} | grep '"message":' | grep -q "Not Found" && echo "false" || echo "true")
  [[ "$exists" == "false" ]] && { echo_content red "版本 ${version} 不存在"; exit 1; }
}

upgrade_h_ui() {
  check_sys
  current_version=$(/usr/local/h-ui/h-ui -v | awk '{print $3}')
  
  # 检查是否通过环境变量指定了版本
  if [[ -n "$HUI_VERSION" ]]; then
    target_version="$HUI_VERSION"
    check_version_exists "$target_version"
  else
    target_version=$(get_latest_version)
  fi

  [[ "$target_version" == "$current_version" ]] && { echo_content skyBlue "当前已是最新版本: ${current_version}"; exit 0; }

  echo_content green "正在升级 H UI (${current_version} -> ${target_version})"
  
  systemctl stop h-ui || { echo_content red "停止服务失败"; exit 1; }

  case $(arch) in
    x86_64)  arch_name="amd64" ;;
    aarch64) arch_name="arm64" ;;
    *)       echo_content red "不支持的架构"; exit 1 ;;
  esac

  download_url="https://github.com/scssw/uiup/releases/download/${target_version}/h-ui-linux-${arch_name}"
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
#!/usr/bin/env bash

# 目标任务：每月1号凌晨3点重启 h-ui
CRON_JOB="0 3 1 * * /bin/systemctl restart h-ui"

# 从 crontab 中查找是否已有任何重启 h-ui 的任务
crontab -l 2>/dev/null | grep -F "/bin/systemctl restart h-ui" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  # 存在则先删除旧任务，再追加新任务
  ( crontab -l | grep -v -F "/bin/systemctl restart h-ui" ; echo "$CRON_JOB" ) | crontab -
  echo -e "\e[36m已修改定时任务为：$CRON_JOB\e[0m"
else
  # 不存在则直接追加
  ( crontab -l 2>/dev/null; echo "$CRON_JOB" ) | crontab -
  echo -e "\e[36m已添加定时任务：$CRON_JOB\e[0m"
fi

