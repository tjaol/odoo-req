#!/usr/bin/env bash
set -euo pipefail

HOST="110.78.229.105"
PORT="14321"
USER="adminfpd"
KEY="$HOME/.ssh/id_ed25519"
SCRIPT_PATH="$(dirname "$0")/log_policy.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: log_policy.sh not found next to this script."
  exit 1
fi

echo "=== 1/2: Uploading script to /tmp ==="
scp -P "$PORT" -i "$KEY" "$SCRIPT_PATH" "${USER}@${HOST}:/tmp/log_policy.sh"

echo "=== 2/2: Installing script and setting up cron ==="
ssh -p "$PORT" -i "$KEY" -t "${USER}@${HOST}" '
  echo "Installing script to /usr/local/sbin..."
  sudo cp /tmp/log_policy.sh /usr/local/sbin/log_policy.sh
  sudo chmod +x /usr/local/sbin/log_policy.sh
  
  echo "Setting up cron job..."
  echo "0 */6 * * * root /usr/local/sbin/log_policy.sh >> /var/log/log_policy.log 2>&1" | sudo tee /etc/cron.d/log-policy > /dev/null
  sudo chmod 644 /etc/cron.d/log-policy
  
  echo "Cleaning up..."
  rm -f /tmp/log_policy.sh
  
  echo ""
  echo "✅ Done! Cron installed at /etc/cron.d/log-policy:"
  cat /etc/cron.d/log-policy
'
