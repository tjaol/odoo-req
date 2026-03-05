#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${1:-}"
REMOTE_PORT="1422"
REMOTE_USER="adminfpd"
SSH_KEY="$HOME/.ssh/id_rsa"
LOCAL_FILE="$HOME/.openclaw/workspace/bt-odoo-opt/log_policy.sh"

if [ -z "$REMOTE_HOST" ]; then
  echo "Usage: $0 <remote_host_ip>"
  echo "Example: $0 203.154.130.242"
  exit 1
fi

SSH_OPTS=(-p "$REMOTE_PORT" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-P "$REMOTE_PORT" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# 0) key connectivity check
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "echo '[OK] key login works'"

# 1) setup remote logrotate (key-only, no inject)
./ssh_key_inject.sh \
  --host "$REMOTE_HOST" \
  --port "$REMOTE_PORT" \
  --user "$REMOTE_USER" \
  --auth-mode key \
  --no-inject \
  --key "$SSH_KEY" \
  --action remote-logrotate \
  --rotate-days 30

# 2) upload log policy script
scp "${SCP_OPTS[@]}" "$LOCAL_FILE" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/log_policy.sh"

# 3) install and schedule cron (strict key-only + passwordless sudo)
ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<'EOF'
set -euo pipefail

# hard fail if passwordless sudo is not available
sudo -n true

sudo cp /tmp/log_policy.sh /usr/local/sbin/log_policy.sh
sudo chmod +x /usr/local/sbin/log_policy.sh
echo '0 */6 * * * root /usr/local/sbin/log_policy.sh >> /var/log/log_policy.log 2>&1' | sudo tee /etc/cron.d/log-policy >/dev/null
rm -f /tmp/log_policy.sh
ls -l /usr/local/sbin/log_policy.sh
cat /etc/cron.d/log-policy
EOF

echo "✅ Done (key-only mode)"
