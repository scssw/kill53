#!/usr/bin/env bash
set -eu

# 本地和远程 SSR 配置文件路径
LOCAL_SSR="/root/backup/ssr-conf.tar.gz"
REMOTE_SSR="/root/backup/ssr-conf.tar.gz"
# 本地和远程 h-ui 数据库路径
LOCAL_HUI="/usr/local/h-ui/data/h_ui.db"
REMOTE_HUI="/usr/local/h-ui/data/h_ui.db"
# 本地和远程 x-ui 数据库路径
LOCAL_XUI="/etc/x-ui/x-ui.db"
REMOTE_XUI="/etc/x-ui/x-ui.db"
# 本地和远程证书目录路径
LOCAL_CERT_DIR="/root/cert"
REMOTE_CERT_DIR="/root/cert"
# 本地和远程额外证书目录路径
LOCAL_EXTRA_CERT_DIR="/usr/local/h-ui/my_acme_dir/certificates/acme.zerossl.com-v2-dv90"
REMOTE_EXTRA_CERT_DIR="/usr/local/h-ui/my_acme_dir/certificates/acme.zerossl.com-v2-dv90"

# 检查命令是否存在
need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# 检测包管理器
detect_pm() {
  if need_cmd apt-get; then
    echo "apt"
  elif need_cmd yum; then
    echo "yum"
  elif need_cmd dnf; then
    echo "dnf"
  elif need_cmd apk; then
    echo "apk"
  else
    echo ""
  fi
}

# 安装软件包
install_pkg() {
  local pkg="$1"
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    echo "未找到支持的包管理器；请手动安装 $pkg。" >&2
    return 1
  fi

  case "$pm" in
    apt)
      sudo apt-get update -y
      sudo apt-get install -y "$pkg"
      ;;
    yum)
      sudo yum install -y "$pkg"
      ;;
    dnf)
      sudo dnf install -y "$pkg"
      ;;
    apk)
      sudo apk add --no-cache "$pkg"
      ;;
  esac
}

# 确保 rsync 已安装
ensure_rsync() {
  if ! need_cmd rsync; then
    echo "未找到 rsync；正在安装..."
    install_pkg rsync
  fi
}

# 确保 SSH 密钥存在
ensure_ssh_key() {
  if [[ ! -f "$HOME/.ssh/id_rsa" || ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
    echo "未找到 SSH 密钥；正在创建..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t rsa -b 2048 -N "" -f "$HOME/.ssh/id_rsa"
  else
    echo "SSH 密钥已存在；跳过。"
  fi
}

# 尝试使用密钥认证
try_key_auth() {
  local user="$1"
  local host="$2"
  local port="$3"
  ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "${user}@${host}" "true" >/dev/null 2>&1
}

# 设置密钥认证
setup_key_auth() {
  local user="$1"
  local host="$2"
  local port="$3"

  if try_key_auth "$user" "$host" "$port"; then
    echo "密钥认证已工作；跳过密码输入。"
    return 0
  fi

  if need_cmd ssh-copy-id; then
    echo "将要求输入密码以安装密钥..."
    ssh-copy-id -p "$port" -o StrictHostKeyChecking=accept-new "${user}@${host}"
  else
    echo "将要求输入密码以安装密钥..."
    ssh -p "$port" -o StrictHostKeyChecking=accept-new "${user}@${host}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    ssh -p "$port" -o StrictHostKeyChecking=accept-new "${user}@${host}" \
      "cat >> ~/.ssh/authorized_keys" < "$HOME/.ssh/id_rsa.pub"
  fi
}

# 检查本地文件是否存在
require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "本地文件未找到: $path" >&2
    exit 1
  fi
}

# 运行备份脚本
run_backup() {
  sudo /bin/bash /usr/local/SSR-Bash-Python/user/backup.sh
}

# 主函数
main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "警告：当前不是以 root 用户运行。您可能需要使用 sudo 来安装软件或访问文件。"
  fi

  ensure_rsync
  ensure_ssh_key

  # 读取远程 IP 地址
  read -r -p "远程 IP 地址: " remote_ip
  if [[ -z "$remote_ip" ]]; then
    echo "远程 IP 地址是必需的。" >&2
    exit 1
  fi

  read -r -p "对方 SSH 端口（默认 22；如果不是 22 请输入实际端口）: " remote_port
  remote_port="${remote_port:-22}"
  if [[ ! "$remote_port" =~ ^[0-9]+$ ]] || (( remote_port < 1 || remote_port > 65535 )); then
    echo "无效端口：请输入 1-65535 之间的数字。" >&2
    exit 1
  fi

  remote_user="root"

  # 设置密钥认证
  setup_key_auth "$remote_user" "$remote_ip" "$remote_port"

  # 选择传输类型（支持多个数字，用空格分隔，如 "1 3 4"）
  echo "选择传输类型:"
  echo "1) ssr 包"
  echo "2) hui 包"
  echo "3) 证书目录"
  echo "4) xui 数据库"
  read -r -p "输入要转移的类型编号（多个用空格分隔，如 1 3 4）: " choices

  # 将输入拆分为数组并去重
  read -r -a choice_array <<< "$choices"
  declare -A seen_choices
  unique_choices=()
  for c in "${choice_array[@]}"; do
    if [[ -n "$c" ]] && [[ -z "${seen_choices[$c]+x}" ]]; then
      seen_choices[$c]=1
      unique_choices+=("$c")
    fi
  done

  # 验证输入是否有效
  for c in "${unique_choices[@]}"; do
    if [[ "$c" != "1" && "$c" != "2" && "$c" != "3" && "$c" != "4" ]]; then
      echo "无效选择: $c。请输入 1-4 之间的数字。" >&2
      exit 1
    fi
  done

  if [[ ${#unique_choices[@]} -eq 0 ]]; then
    echo "未输入任何选择。" >&2
    exit 1
  fi

  # 标记是否需要运行备份脚本（选项1和2需要）
  need_backup=false
  for c in "${unique_choices[@]}"; do
    if [[ "$c" == "1" || "$c" == "2" ]]; then
      need_backup=true
      break
    fi
  done

  # 如果需要，执行一次备份
  if $need_backup; then
    run_backup
  fi

  # 根据选择的编号执行对应传输
  for c in "${unique_choices[@]}"; do
    case "$c" in
      1)
        echo "=== 正在转移 ssr 包 ==="
        require_file "$LOCAL_SSR"
        ssh -p "$remote_port" "${remote_user}@${remote_ip}" "mkdir -p /root/backup"
        rsync -avz -e "ssh -p $remote_port" "$LOCAL_SSR" "${remote_user}@${remote_ip}:$REMOTE_SSR"
        ;;
      2)
        echo "=== 正在转移 hui 包 ==="
        require_file "$LOCAL_HUI"
        ssh -p "$remote_port" "${remote_user}@${remote_ip}" "mkdir -p /usr/local/h-ui/data"
        rsync -avz -e "ssh -p $remote_port" "$LOCAL_HUI" "${remote_user}@${remote_ip}:$REMOTE_HUI"
        ;;
      3)
        echo "=== 正在转移证书目录 ==="
        if [[ ! -d "$LOCAL_CERT_DIR" ]]; then
          echo "本地目录未找到: $LOCAL_CERT_DIR" >&2
          exit 1
        fi
        ssh -p "$remote_port" "${remote_user}@${remote_ip}" "mkdir -p \"$REMOTE_CERT_DIR\""
        rsync -avz -e "ssh -p $remote_port" "${LOCAL_CERT_DIR}/" "${remote_user}@${remote_ip}:${REMOTE_CERT_DIR}/"
        if [[ -d "$LOCAL_EXTRA_CERT_DIR" ]]; then
          ssh -p "$remote_port" "${remote_user}@${remote_ip}" "mkdir -p \"$REMOTE_EXTRA_CERT_DIR\""
          rsync -avz -e "ssh -p $remote_port" "${LOCAL_EXTRA_CERT_DIR}/" "${remote_user}@${remote_ip}:${REMOTE_EXTRA_CERT_DIR}/"
        else
          echo "可选目录未找到，跳过: $LOCAL_EXTRA_CERT_DIR"
        fi
        ;;
      4)
        echo "=== 正在转移 xui 数据库 ==="
        require_file "$LOCAL_XUI"
        ssh -p "$remote_port" "${remote_user}@${remote_ip}" "mkdir -p /etc/x-ui"
        rsync -avz -e "ssh -p $remote_port" "$LOCAL_XUI" "${remote_user}@${remote_ip}:$REMOTE_XUI"
        ;;
    esac
  done

  echo "完成。"
}

main "$@"
