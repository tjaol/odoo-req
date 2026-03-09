#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LOG_DIR="$HOME/.openclaw/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/lmstudio-cliproxy-check.log"
exec >>"$LOG_FILE" 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S %Z') ====="

# Ensure LM Studio app is running
if ! pgrep -f '/Applications/LM Studio.app/Contents/MacOS/LM Studio' >/dev/null 2>&1; then
  echo '[fix] launching LM Studio app'
  open -a 'LM Studio' || true
  sleep 8
fi

# Ensure LM Studio local server is up
if ! lsof -nP -iTCP:1234 -sTCP:LISTEN >/dev/null 2>&1; then
  echo '[fix] 1234 not listening; restarting LM Studio app'
  osascript -e 'tell application "LM Studio" to quit' || true
  sleep 3
  pkill -f '/Applications/LM Studio.app/Contents/MacOS/LM Studio' || true
  sleep 2
  open -a 'LM Studio' || true
  sleep 10
fi

# Ensure qwen model is loaded/visible
if [ -x "$HOME/.lmstudio/bin/lms" ]; then
  if ! "$HOME/.lmstudio/bin/lms" ps 2>/dev/null | grep -q 'qwen3.5-27b'; then
    echo '[fix] loading qwen3.5-27b'
    "$HOME/.lmstudio/bin/lms" load qwen3.5-27b || true
  fi
fi

# Ensure cliproxy is running
if ! lsof -nP -iTCP:8317 -sTCP:LISTEN >/dev/null 2>&1; then
  echo '[fix] restarting cliproxy launch agent'
  launchctl kickstart -k "gui/$(id -u)/me.henri.cliproxy" || true
  sleep 3
fi

# Health snapshot
{
  echo '-- 1234 --'
  lsof -nP -iTCP:1234 -sTCP:LISTEN || true
  curl -sS --max-time 5 http://127.0.0.1:1234/v1/models || true
  echo
  echo '-- lms ps --'
  "$HOME/.lmstudio/bin/lms" ps || true
  echo
  echo '-- 8317 --'
  lsof -nP -iTCP:8317 -sTCP:LISTEN || true
} | sed 's/^/  /'

echo
