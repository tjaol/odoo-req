#!/usr/bin/env bash
set -uo pipefail  # no -e, use explicit error handling

# ===== config =====
MOUNT="/"
THRESHOLD=85

# Emergency journald policy
JOURNAL_KEEP_DAYS=14
JOURNAL_MAX_SIZE="500M"

# Rotation/archive policy
ARCHIVE_SOURCE_MIN_DAYS=7   # archive rotated logs older than this
ARCHIVE_RETENTION_DAYS=30   # delete archives older than this

ODOO_LOG_DIR="/var/log/odoo19"
ARCHIVE_BASE="/data/log-archive"
ARCHIVE_ODOO="$ARCHIVE_BASE/odoo19"
ARCHIVE_SYS="$ARCHIVE_BASE/system"

mkdir -p "$ARCHIVE_ODOO" "$ARCHIVE_SYS"

ts() { date -Is; }

# ===== helpers =====
disk_used_pct() { df -P "$MOUNT" | awk 'NR==2 {gsub("%","",$5); print $5}'; }

# ===== 1) emergency truncation =====
used="$(disk_used_pct)"
if [ "$used" -ge "$THRESHOLD" ]; then
  echo "$(ts) [EMERG] disk ${MOUNT} used=${used}% -> truncating" >&2

  journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" >/dev/null 2>&1 || true
  journalctl --vacuum-size="$JOURNAL_MAX_SIZE"      >/dev/null 2>&1 || true

  for f in /var/log/syslog /var/log/auth.log /var/log/kern.log; do
    [ -f "$f" ] && truncate -s 0 "$f" || true
  done

  for f in "$ODOO_LOG_DIR"/odoo19-prd.log "$ODOO_LOG_DIR"/odoo19-staging.log; do
    [ -f "$f" ] && truncate -s 0 "$f" || true
  done

  # restart services to release old fd
  systemctl restart rsyslog          >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  systemctl restart odoo19-prd       >/dev/null 2>&1 || true
  systemctl restart odoo19-staging   >/dev/null 2>&1 || true
fi

# ===== 2) archive rotated logs =====
find "$ODOO_LOG_DIR" -maxdepth 1 -type f -name 'odoo19-*.log-*' -mtime +"$ARCHIVE_SOURCE_MIN_DAYS" -print0 2>/dev/null \
| while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if [ ! -f "$ARCHIVE_ODOO/${base}.tar.gz" ]; then
      tar -C "$ODOO_LOG_DIR" -czf "$ARCHIVE_ODOO/${base}.tar.gz" "$base" \
        && rm -f "$f"
    fi
  done || true

find /var/log -maxdepth 1 -type f \( -name 'syslog.*' -o -name 'auth.log.*' -o -name 'kern.log.*' \) -mtime +"$ARCHIVE_SOURCE_MIN_DAYS" -print0 2>/dev/null \
| while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if [ ! -f "$ARCHIVE_SYS/${base}.tar.gz" ]; then
      tar -C /var/log -czf "$ARCHIVE_SYS/${base}.tar.gz" "$base" \
        && rm -f "$f"
    fi
  done || true

# ===== 3) retention =====
find "$ARCHIVE_BASE" -type f -name '*.tar.gz' -mtime +"$ARCHIVE_RETENTION_DAYS" -delete 2>/dev/null || true

echo "$(ts) [OK] log policy done. disk_used=$(disk_used_pct)%"
