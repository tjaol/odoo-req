#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${1:-}"
REMOTE_PORT="14321"
REMOTE_USER="adminfpd"
SSH_KEY="$HOME/.ssh/id_ed25519"
LOCAL_FILE="$HOME/.openclaw/workspace/bt-odoo-opt/log_policy.sh"

if [ -z "$REMOTE_HOST" ]; then
  echo "Usage: $0 <remote_host_ip> [sudo_password_optional]"
  echo "Example (NOPASSWD sudo): $0 203.154.130.242"
  echo "Example (sudo needs pass): $0 203.154.130.242 'YourSudoPass'"
  exit 1
fi

SUDO_PASS="${2:-}"
SSH_OPTS=(-p "$REMOTE_PORT" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

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
scp "${SSH_OPTS[@]}" "$LOCAL_FILE" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/log_policy.sh"

# 3) install and schedule cron
if [ -n "$SUDO_PASS" ]; then
  # sudo requires password
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<EOF
set -euo pipefail
echo '$SUDO_PASS' | sudo -S cp /tmp/log_policy.sh /usr/local/sbin/log_policy.sh
echo '$SUDO_PASS' | sudo -S chmod +x /usr/local/sbin/log_policy.sh
echo '0 */6 * * * root /usr/local/sbin/log_policy.sh >> /var/log/log_policy.log 2>&1' | sudo tee /etc/cron.d/log-policy >/dev/null
rm -f /tmp/log_policy.sh
ls -l /usr/local/sbin/log_policy.sh
cat /etc/cron.d/log-policy
EOF
else
  # passwordless sudo (NOPASSWD)
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<'EOF'
set -euo pipefail
sudo cp /tmp/log_policy.sh /usr/local/sbin/log_policy.sh
sudo chmod +x /usr/local/sbin/log_policy.sh
echo '0 */6 * * * root /usr/local/sbin/log_policy.sh >> /var/log/log_policy.log 2>&1' | sudo tee /etc/cron.d/log-policy >/dev/null
rm -f /tmp/log_policy.sh
ls -l /usr/local/sbin/log_policy.sh
cat /etc/cron.d/log-policy
EOF
fi

echo "✅ Done (key-only mode)"
