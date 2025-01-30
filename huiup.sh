#!/usr/bin/env bash

# 设置要升级到的 H UI 版本（默认：latest）
HUI_VERSION=${1:-latest}

# 升级 H UI
if systemctl list-units --type=service --all | grep -q 'h-ui.service'; then
  # 升级 H UI (systemd)
  if ! version_ge "$(/usr/local/h-ui/h-ui -v | sed -n 's/.*version \([^\ ]*\).*/\1/p')" "v0.0.12"; then
    echo "H UI (systemd) 版本必须大于或等于 v0.0.12"
    exit 0
  fi
  curl -fsSL https://github.com/scssw/h-ui/releases/latest/download/h-ui-linux-amd64 -o /usr/local/h-ui/h-ui
  chmod +x /usr/local/h-ui/h-ui
  systemctl restart h-ui
  echo "H UI (systemd) 升级成功！"
else
  # 升级 H UI (二进制文件)
  curl -fsSL https://github.com/scssw/h-ui/releases/latest/download/h-ui-linux-amd64 -o /usr/local/bin/h-ui
  chmod +x /usr/local/bin/h-ui
  echo "H UI (二进制文件) 升级成功！"
fi
