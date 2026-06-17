cat > /root/fix_cpu_xmrig_qemuga.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] 清理 XMRig 矿工..."
systemctl stop xmrig 2>/dev/null || true
systemctl disable xmrig 2>/dev/null || true
pkill -9 xmrig 2>/dev/null || true

rm -f /etc/systemd/system/xmrig.service
rm -f /etc/systemd/system/multi-user.target.wants/xmrig.service
rm -f /usr/lib/systemd/system/xmrig.service
rm -f /lib/systemd/system/xmrig.service
rm -f /usr/local/bin/xmrig
rm -rf /tmp/xmrig-*
rm -f /tmp/xmrig.tar.gz /tmp/xmrig

echo "[2/7] 清理 cron 里的矿工痕迹..."
for c in /var/spool/cron/crontabs/root /var/spool/cron/root /etc/crontab; do
  [ -f "$c" ] && sed -i.bak '/xmrig\|supportxmr\|monero\|minerd\|kinsing\|kdevtmpfsi/d' "$c"
done

find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -type f 2>/dev/null \
  -exec sed -i.bak '/xmrig\|supportxmr\|monero\|minerd\|kinsing\|kdevtmpfsi/d' {} \; || true

echo "[3/7] 清理 SystemLoger 后门..."
systemctl stop systemlog.service 2>/dev/null || true
systemctl disable systemlog.service 2>/dev/null || true
pkill -9 -f '^/opt/systemlog/SystemLoger$' 2>/dev/null || true

rm -f /etc/systemd/system/systemlog.service
rm -f /etc/systemd/system/multi-user.target.wants/systemlog.service
rm -f /usr/lib/systemd/system/systemlog.service
rm -f /lib/systemd/system/systemlog.service

systemctl daemon-reload
systemctl reset-failed systemlog.service 2>/dev/null || true
systemctl mask systemlog.service 2>/dev/null || true

chattr -i /opt/systemlog/SystemLoger 2>/dev/null || true
rm -rf /opt/systemlog/SystemLoger
mkdir -p /opt/systemlog/SystemLoger
chmod 000 /opt/systemlog/SystemLoger
chattr +i /opt/systemlog/SystemLoger 2>/dev/null || true

echo "  - systemlog.service 状态："
systemctl is-enabled systemlog.service 2>/dev/null || true
systemctl is-active systemlog.service 2>/dev/null || true
if pgrep -f '^/opt/systemlog/SystemLoger$' >/dev/null 2>&1; then
  echo "  - [WARN] SystemLoger 进程仍在运行"
  ps aux | grep -F '/opt/systemlog/SystemLoger' | grep -v grep || true
else
  echo "  - [OK] SystemLoger 进程已清除"
fi
if [ -d /opt/systemlog/SystemLoger ] && [ ! -x /opt/systemlog/SystemLoger ]; then
  echo "  - [OK] /opt/systemlog/SystemLoger 已替换为不可执行占位目录"
else
  echo "  - [WARN] /opt/systemlog/SystemLoger 占位异常"
  ls -ld /opt/systemlog/SystemLoger 2>/dev/null || true
fi
lsattr -d /opt/systemlog/SystemLoger 2>/dev/null || true

echo "[4/7] 停用 qemu-guest-agent..."
systemctl stop qemu-guest-agent 2>/dev/null || true
systemctl disable qemu-guest-agent 2>/dev/null || true
systemctl mask qemu-guest-agent 2>/dev/null || true
pkill -9 qemu-ga 2>/dev/null || true

echo "[5/7] 清理 systemd 状态..."
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[6/7] 当前可疑进程："
ps aux | egrep 'xmrig|supportxmr|monero|minerd|kinsing|kdevtmpfsi|qemu-ga|SystemLoger|systemlog' | grep -v grep || echo "未发现可疑进程"

echo "[7/7] 当前 CPU 前10："
ps -eo pid,ppid,user,stat,pcpu,pmem,comm,args --sort=-pcpu | head -11

echo
echo "完成。建议再执行：top"
EOF

chmod +x /root/fix_cpu_xmrig_qemuga.sh
bash /root/fix_cpu_xmrig_qemuga.sh
