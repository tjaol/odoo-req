#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${1:-}"
REMOTE_PORT="14321"
REMOTE_USER="adminfpd"
LOCAL_FILE="$HOME/.openclaw/workspace/bt-odoo-opt/log_policy.sh"

if [ -z "$REMOTE_HOST" ]; then
  echo "Usage: $0 <remote_host_ip>"
  echo "Example: $0 203.154.130.242"
  exit 1
fi

# 依赖检查
command -v sshpass >/dev/null 2>&1 || {
  echo "ERROR: sshpass not found. Install with: brew install hudochenkov/sshpass/sshpass"
  exit 1
}

# 只输入一次密码（不回显）
read -rsp "Remote sudo password: " REMOTE_PASS
echo

# 1) 先执行 remote-logrotate（强制 password 模式，避免中途再次弹 SSH 密码）
./ssh_key_inject.sh \
  --host "$REMOTE_HOST" \
  --port "$REMOTE_PORT" \
  --user "$REMOTE_USER" \
  --auth-mode password \
  --password "$REMOTE_PASS" \
  --action remote-logrotate \
  --rotate-days 30

# 2) 上传 log_policy.sh（同一密码，非交互）
export SSHPASS="$REMOTE_PASS"
sshpass -e scp -P "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new \
  "$LOCAL_FILE" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/log_policy.sh"

# 3) 远端安装 + cron（同一密码，非交互）
sshpass -e ssh -p "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new \
  "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<EOF
set -euo pipefail
echo '$REMOTE_PASS' | sudo -S cp /tmp/log_policy.sh /usr/local/sbin/log_policy.sh
echo '$REMOTE_PASS' | sudo -S chmod +x /usr/local/sbin/log_policy.sh
echo '0 */6 * * * root /usr/local/sbin/log_policy.sh >> /var/log/log_policy.log 2>&1' | sudo tee /etc/cron.d/log-policy >/dev/null
rm -f /tmp/log_policy.sh
ls -l /usr/local/sbin/log_policy.sh
cat /etc/cron.d/log-policy
EOF

unset REMOTE_PASS
unset SSHPASS
echo "✅ Done"
