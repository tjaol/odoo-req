#!/usr/bin/env bash
# ssh_key_inject.sh - SSH public key injection/revocation + remote task execution framework
# Usage:
#   inject:      ./ssh_key_inject.sh --host <ip> --password <pass> --action inject
#   revoke:      ./ssh_key_inject.sh --host <ip> --password <pass> --action revoke
#   status:      ./ssh_key_inject.sh --host <ip> --password <pass> --action status
#   auto:        ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action auto --run-cmd "bash /tmp/xxx.sh"
#   odoo-check:  ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action odoo-check
#   odoo-setup:  ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action odoo-setup [--rotate-days 30] [--rotate-size 100M] [--rotate-count <n>]
#   logrotate:        ./ssh_key_inject.sh --action logrotate
#   remote-logrotate: ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action remote-logrotate [--rotate-days 30] [--rotate-size 100M] [--rotate-count <n>]
set -euo pipefail

# ── Parameters ────────────────────────────────────────────────────────────────
HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""          # inject | revoke | status | auto | odoo-check | odoo-setup | logrotate | remote-logrotate
RUN_CMD=""         # used by auto action only
SSH_TIMEOUT="10"
PUBKEY_FILE=""
PUBKEY=""
ROTATE_DAYS="30"   # remote-logrotate: days to keep
ROTATE_SIZE=""     # remote-logrotate: max size before rotate (e.g. 100M), empty = no size limit
ROTATE_COUNT=""    # remote-logrotate: optional file-count cap; empty = unlimited
AUTH_MODE="auto"   # auto | password | key
NO_INJECT="0"      # 1 = skip inject/revoke lifecycle (for pre-installed keys)

usage() {
  cat <<'EOF'
Usage: ssh_key_inject.sh --host <ip> --password <pass> --action <action> [options]

Actions:
  inject      Append public key to remote authorized_keys (idempotent)
  revoke      Remove public key from remote authorized_keys
  status      Check if public key exists on remote host
  auto        inject -> run --run-cmd -> revoke
  odoo-check  inject -> detect & install missing Odoo 19 Python deps -> revoke
  logrotate   Rotate local OpenClaw gateway logs (keeps 5 .gz backups)

  odoo-setup        inject -> odoo-check (deps) -> remote-logrotate (setup log rotation) -> revoke
  remote-logrotate  inject -> detect Odoo log path -> setup logrotate on remote -> revoke

Options:
  --host <ip>           required (except for logrotate)
  --port <port>         default 22
  --user <user>         default root
  --password <pass>     SSH password (used for inject/revoke/status phases)
  --key <privkey>       Private key path (used for execution phase in auto/odoo-check/remote-logrotate)
  --pubkey-file <path>  Public key file (auto-detected from ~/.ssh/id_*.pub if not set)
  --run-cmd <cmd>       Remote command to run (auto mode only)
  --ssh-timeout <sec>   default 10
  --rotate-days <n>     Days to retain logs (default 30)  [remote-logrotate]
  --rotate-size <s>     Rotate when log exceeds size, e.g. 100M 500M (default: no limit) [remote-logrotate]
  --rotate-count <n>    Optional max backup files; omit for unlimited [remote-logrotate]
  --auth-mode <m>       auto|password|key (default: auto)
  --no-inject           Skip inject/revoke lifecycle (use existing server-side public key)
  -h|--help

Examples:
  # Inject public key
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action inject

  # Revoke public key
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action revoke

  # Check key status
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action status

  # Run a custom remote command
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --key ~/.ssh/id_ed25519 \
    --action auto --run-cmd "bash /tmp/my_script.sh"

  # Check and install missing Odoo 19 dependencies
  # Note: requires root/sudo password (or key) if system packages are missing
  ./ssh_key_inject.sh --host 10.0.0.1 --port 14321 --user adminfpd \
    --password 'pass' --key ~/.ssh/id_ed25519 --action odoo-check

  # Rotate remote Odoo logs
  ./ssh_key_inject.sh --host 10.0.0.1 --port 14321 --user adminfpd \
    --password 'pass' --key ~/.ssh/id_ed25519 --action remote-logrotate \
    --rotate-days 30 --rotate-size 100M --rotate-count 14

  # Rotate local OpenClaw logs
  ./ssh_key_inject.sh --action logrotate
EOF
}

# ── Argument parsing ───────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)        HOST="${2:-}";        shift 2 ;;
    --port)        PORT="${2:-}";        shift 2 ;;
    --user)        USER="${2:-}";        shift 2 ;;
    --password)    PASSWORD="${2:-}";    shift 2 ;;
    --key)         KEY="${2:-}";         shift 2 ;;
    --pubkey-file) PUBKEY_FILE="${2:-}"; shift 2 ;;
    --action)        ACTION="${2:-}";       shift 2 ;;
    --run-cmd)       RUN_CMD="${2:-}";      shift 2 ;;
    --ssh-timeout)   SSH_TIMEOUT="${2:-}";  shift 2 ;;
    --rotate-days)   ROTATE_DAYS="${2:-}";  shift 2 ;;
    --rotate-size)   ROTATE_SIZE="${2:-}";  shift 2 ;;
    --rotate-count)  ROTATE_COUNT="${2:-}"; shift 2 ;;
    --auth-mode)     AUTH_MODE="${2:-}";    shift 2 ;;
    --no-inject)     NO_INJECT="1";         shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[ -n "$ACTION" ] || { echo "--action is required"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto|odoo-check|odoo-setup|logrotate|remote-logrotate)$ ]] || {
  echo "--action must be inject|revoke|status|auto|odoo-check|odoo-setup|logrotate|remote-logrotate"; exit 1
}
if [ "$ACTION" != "logrotate" ]; then
  [ -n "$HOST" ] || { echo "--host is required"; exit 1; }
fi
[[ "$AUTH_MODE" =~ ^(auto|password|key)$ ]] || { echo "--auth-mode must be auto|password|key"; exit 1; }
if [ "$ACTION" != "logrotate" ] && [ "$AUTH_MODE" = "password" ]; then
  [ -n "$PASSWORD" ] || { echo "--password is required when --auth-mode password"; exit 1; }
fi
if [ "$ACTION" != "logrotate" ] && [ "$AUTH_MODE" = "key" ]; then
  [ -n "$KEY" ] || { echo "--key is required when --auth-mode key"; exit 1; }
fi

# ── Load public key ───────────────────────────────────────────────────────────
load_pubkey() {
  [ "$ACTION" = "logrotate" ] && return 0
  [ "$NO_INJECT" = "1" ] && return 0
  # 1. Explicit --pubkey-file
  if [ -n "$PUBKEY_FILE" ]; then
    # Expand tilde if present
    PUBKEY_FILE="${PUBKEY_FILE/#\~/$HOME}"
    [ -f "$PUBKEY_FILE" ] || { echo "ERROR: pubkey file not found: $PUBKEY_FILE"; exit 1; }
    PUBKEY="$(cat "$PUBKEY_FILE")"
    echo "[key] using pubkey from: $PUBKEY_FILE"
    return
  fi

  # 2. Derive .pub from --key path
  if [ -n "$KEY" ]; then
    # Expand tilde if present
    KEY="${KEY/#\~/$HOME}"
    local pub="${KEY}.pub"
    if [ -f "$pub" ]; then
      PUBKEY="$(cat "$pub")"
      echo "[key] using pubkey from: $pub"
      return
    fi
  fi

  # 3. Auto-detect common locations
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    if [ -f "$f" ]; then
      PUBKEY="$(cat "$f")"
      echo "[key] auto-detected pubkey: $f"
      return
    fi
  done

  echo "ERROR: no public key found. Use --pubkey-file <path> or --key <private_key_path>"
  exit 1
}

load_pubkey

REMOTE="${USER}@${HOST}"

# ── SSH helpers ───────────────────────────────────────────────────────────────
SSH_BASE_OPTS=(
  -p "$PORT"
  -o ConnectTimeout="$SSH_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=no
)

run_ssh_pass() {
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass not found. Install: brew install hudochenkov/sshpass/sshpass  OR  apt install sshpass"
    exit 1
  fi
  sshpass -p "$PASSWORD" ssh "${SSH_BASE_OPTS[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o PasswordAuthentication=yes "$REMOTE" "$@"
}

run_ssh_key() {
  [ -n "$KEY" ] || { echo "ERROR: --key required"; exit 1; }
  local RESOLVED_KEY="${KEY/#\~/$HOME}"
  ssh "${SSH_BASE_OPTS[@]}" -i "$RESOLVED_KEY" -o BatchMode=yes "$REMOTE" "$@"
}

run_ssh_auto() {
  if [ "$AUTH_MODE" = "password" ]; then
    run_ssh_pass "$@"
  elif [ "$AUTH_MODE" = "key" ]; then
    run_ssh_key "$@"
  else
    if [ -n "$KEY" ]; then
      run_ssh_key "$@" || run_ssh_pass "$@"
    else
      run_ssh_pass "$@"
    fi
  fi
}

# ── Actions ───────────────────────────────────────────────────────────────────

do_inject() {
  if [ "$NO_INJECT" = "1" ]; then
    echo "[inject] skipped (--no-inject)."
    return 0
  fi
  echo "[inject] -> ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
  local pubkey_escaped
  pubkey_escaped="$(printf '%s' "$PUBKEY" | sed "s/'/'\\\\''/g")"
  # inject MUST use password auth — the key isn't on the remote yet
  run_ssh_pass bash -s <<REMOTE_INJECT
set -e
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
if grep -qF '${key_id}' ~/.ssh/authorized_keys 2>/dev/null; then
  echo "[inject] key already present (${key_id}), skipping."
else
  printf '%s\n' '${pubkey_escaped}' >> ~/.ssh/authorized_keys
  echo "[inject] key added (${key_id})."
fi
REMOTE_INJECT
  echo "[inject] done."
}

do_revoke() {
  if [ "$NO_INJECT" = "1" ]; then
    echo "[revoke] skipped (--no-inject)."
    return 0
  fi
  echo "[revoke] -> ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
  # revoke MUST use password auth — we're removing the key, can't rely on it
  run_ssh_pass bash -s <<REMOTE_REVOKE
set -e
if [ ! -f ~/.ssh/authorized_keys ]; then
  echo "[revoke] authorized_keys not found, nothing to do."
  exit 0
fi
if grep -qF '${key_id}' ~/.ssh/authorized_keys 2>/dev/null; then
  tmp=\$(mktemp)
  grep -vF '${key_id}' ~/.ssh/authorized_keys > "\$tmp" || true
  mv "\$tmp" ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  echo "[revoke] key removed (${key_id})."
else
  echo "[revoke] key not found (${key_id}), nothing to do."
fi
REMOTE_REVOKE
  echo "[revoke] done."
}

do_status() {
  if [ "$NO_INJECT" = "1" ]; then
    echo "[status] --no-inject enabled: testing connectivity only"
    run_ssh_auto "echo CONNECTED"
    return 0
  fi
  echo "[status] checking ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
  local found
  found="$(run_ssh_auto bash -s <<REMOTE_STATUS
if [ -f ~/.ssh/authorized_keys ] && grep -qF '${key_id}' ~/.ssh/authorized_keys 2>/dev/null; then
  echo "PRESENT"
else
  echo "ABSENT"
fi
REMOTE_STATUS
)"
  echo "[status] ${key_id}: ${found}"
  [ "$found" = "PRESENT" ] && return 0 || return 1
}

do_auto() {
  [ -n "$RUN_CMD" ] || { echo "ERROR: --run-cmd required for auto action"; exit 1; }
  if [ "$AUTH_MODE" != "password" ]; then
    [ -n "$KEY" ] || { echo "ERROR: --key required for auto action in auth-mode $AUTH_MODE"; exit 1; }
  fi

  trap 'echo ""; echo "[auto] cleanup: revoking key..."; do_revoke' EXIT

  echo "[auto] step 1/3: inject key"
  do_inject

  echo ""
  echo "[auto] step 2/3: execute via key auth"
  echo "[auto] cmd: ${RUN_CMD}"
  run_ssh_auto bash -c "$RUN_CMD"

  echo ""
  echo "[auto] step 3/3: revoke key (via trap)"
}

do_odoo_check() {
  if [ "$AUTH_MODE" != "password" ]; then
    [ -n "$KEY" ] || { echo "ERROR: --key required for odoo-check action in auth-mode $AUTH_MODE"; exit 1; }
  fi

  trap 'echo ""; echo "[odoo-check] cleanup: revoking key..."; do_revoke' EXIT

  echo "[odoo-check] step 1/3: inject key"
  do_inject

  echo ""
  echo "[odoo-check] step 2/3: run Odoo 19 dependency check & install"
  # Note: passing PASSWORD to the remote script as an environment variable
  # Save script locally and pipe it through ssh to guarantee perfect execution
  local TMP_SCRIPT="/tmp/odoo_check_payload_$$.sh"
  cat <<'ODOO_CHECK_SCRIPT' > "$TMP_SCRIPT"
set -euo pipefail

REQUIREMENTS_URL="https://raw.githubusercontent.com/odoo/odoo/refs/heads/19.0/requirements.txt"
TMP_REQ="/tmp/odoo19_requirements_$(id -u).txt"
LOG_FILE="/tmp/odoo19_check_$(date +%Y%m%d_%H%M%S).log"
VENV_PATH="$HOME/.odoo-venv"

echo "============================================"
echo " Odoo 19 Dependency Check & Install"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

echo ""
echo "--- 1. System Dependencies Check (wkhtmltopdf, C libs) ---"
SYS_MISSING=()

# 1. Check wkhtmltopdf
if command -v wkhtmltopdf &>/dev/null; then
  echo "  [OK] wkhtmltopdf ($(wkhtmltopdf --version | head -n1 | grep -o '[0-9.]*' | head -n1 || echo 'unknown'))"
else
  echo "  [MISSING] wkhtmltopdf"
  SYS_MISSING+=("wkhtmltopdf")
fi

# 2. Check system C libs required by Python packages (psycopg2, lxml, reportlab, vector graphics, etc.)
if command -v dpkg-query &>/dev/null; then
  for sys_pkg in build-essential libpq-dev libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libffi-dev libjpeg-dev zlib1g-dev libfreetype6-dev liblcms2-dev libtiff-dev libopenjp2-7-dev libwebp-dev; do
    if dpkg-query -W -f='${Status}' "$sys_pkg" 2>/dev/null | grep -q "install ok installed"; then
      echo "  [OK] $sys_pkg"
    else
      echo "  [MISSING] $sys_pkg"
      SYS_MISSING+=("$sys_pkg")
    fi
  done
else
  echo "  [SKIP] dpkg not found, skipping apt package checks"
fi

echo ""
if [ ${#SYS_MISSING[@]} -gt 0 ]; then
  echo "[WARN] Missing system packages. Attempting to install automatically via sudo..."
  
  APT_MISSING=()
  for p in "${SYS_MISSING[@]}"; do [ "$p" != "wkhtmltopdf" ] && APT_MISSING+=("$p"); done
  
  if [ ${#APT_MISSING[@]} -gt 0 ]; then
    echo "  Running: echo '<password>' | sudo -S apt-get update && sudo -S apt-get install -y ${APT_MISSING[*]}"
    # Disable exit on error temporarily
    set +e
    if echo "$PASSWORD" | sudo -S -n true 2>/dev/null || echo "$PASSWORD" | sudo -S true 2>/dev/null; then
      echo "$PASSWORD" | sudo -S apt-get update >/dev/null 2>&1
      echo "$PASSWORD" | sudo -S DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_MISSING[@]}" || echo "  [!] Failed to install some apt packages."
    else
      echo "  [!] Sudo requires a valid password or user lacks sudo privileges. Please run manually."
    fi
    set -e
  fi
  
  if [[ " ${SYS_MISSING[*]} " =~ " wkhtmltopdf " ]]; then
    echo ""
    echo "  [WARN] wkhtmltopdf is missing. Installing patched version from GitHub..."
    set +e
    if echo "$PASSWORD" | sudo -S true 2>/dev/null; then
      cd /tmp
      wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
      echo "$PASSWORD" | sudo -S DEBIAN_FRONTEND=noninteractive apt-get install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb || echo "  [!] Failed to install wkhtmltopdf."
    else
      echo "  [!] Cannot install wkhtmltopdf automatically without sudo privileges."
    fi
    set -e
  fi
  echo "--------------------------------------------"
  echo "Proceeding with Python dependency check..."
  echo ""
else
  echo "[OK] All system C dependencies and wkhtmltopdf are installed."
  echo "--------------------------------------------"
  echo ""
fi

echo "--- 2. Python Environment Check ---"

# Step 0: Ensure a venv exists (no root needed if dir is writable)
# Priority: existing Odoo venv > create new venv at VENV_PATH
PYTHON=""
for candidate in \
  /opt/odoo/venv/bin/python3 \
  /opt/odoo/.venv/bin/python3 \
  /home/odoo/venv/bin/python3 \
  /home/odoo/.venv/bin/python3; do
  if [ -f "$candidate" ]; then
    PYTHON="$candidate"
    echo "[env] Found existing venv: $(dirname $(dirname $candidate))"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "[env] No existing Odoo venv found."
  SYS_PYTHON="$(which python3)"
  echo "[env] Creating venv at $VENV_PATH using $SYS_PYTHON ..."
  mkdir -p "$(dirname $VENV_PATH)"
  $SYS_PYTHON -m venv "$VENV_PATH"
  PYTHON="$VENV_PATH/bin/python3"
  echo "[env] Venv created."
fi

PIP_CMD="$(dirname $PYTHON)/pip3"
[ -f "$PIP_CMD" ] || PIP_CMD="$PYTHON -m pip"
PIP_EXTRA_ARGS=""  # venv pip never needs --break-system-packages

PY_VERSION=$($PYTHON -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "[env] Python:   $PYTHON ($PY_VERSION)"
echo "[env] Pip:      $PIP_CMD"
echo "[env] Log file: $LOG_FILE (on this remote host)"
echo ""

# Download requirements.txt
echo "[1/3] Downloading Odoo 19 requirements.txt..."
if command -v curl &>/dev/null; then
  curl -fsSL "$REQUIREMENTS_URL" -o "$TMP_REQ"
elif command -v wget &>/dev/null; then
  wget -q "$REQUIREMENTS_URL" -O "$TMP_REQ"
else
  echo "ERROR: neither curl nor wget available"; exit 1
fi
echo "[1/3] Download complete ($(wc -l < "$TMP_REQ") lines)"
echo ""

# Parse package names from requirements.txt
PACKAGES=$($PYTHON -c "
import re
pkgs, seen = [], set()
for line in open('$TMP_REQ'):
    line = line.strip()
    if not line or line.startswith('#'): continue
    line = line.split('#')[0].strip()
    name = re.split(r'[>=<!~\[;]', line)[0].strip().lower()
    if name and name not in seen:
        seen.add(name)
        pkgs.append(name)
print('\n'.join(pkgs))
")

# Detect installed packages
echo "[2/3] Checking installation status..."
MISSING=()
TOTAL=0
while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  # Skip Windows-only packages
  [[ "$pkg" == "pypiwin32" ]] && continue
  TOTAL=$((TOTAL + 1))
  if $PIP_CMD show "$pkg" &>/dev/null 2>&1; then
    echo "  [OK] $pkg"
  else
    echo "  [MISSING] $pkg"
    MISSING+=("$pkg")
  fi
done <<< "$PACKAGES"

INSTALLED=$((TOTAL - ${#MISSING[@]}))
echo ""
echo "Result: $INSTALLED installed, ${#MISSING[@]} missing (total $TOTAL)"

if [ ${#MISSING[@]} -eq 0 ]; then
  echo ""
  echo "[OK] All Odoo 19 dependencies are installed. Nothing to do."
  exit 0
fi

# Install missing packages
echo ""
echo "[3/3] Installing missing packages..."
FAILED=()
for pkg in "${MISSING[@]}"; do
  echo -n "  Installing $pkg ... "
  if $PIP_CMD install $PIP_EXTRA_ARGS "$pkg" >> "$LOG_FILE" 2>&1; then
    echo "OK"
  else
    echo "FAILED (check log: $LOG_FILE)"
    FAILED+=("$pkg")
  fi
done

echo ""
echo "============================================"
if [ ${#FAILED[@]} -gt 0 ]; then
  echo " Install complete with errors"
  echo "============================================"
  echo ""
  echo "[WARN] The following packages failed to install:"
  for pkg in "${FAILED[@]}"; do echo "  - $pkg"; done
  echo ""
  echo "Log file on remote host: $LOG_FILE"
  echo "Retrieve with: scp ${USER}@${HOST}:$LOG_FILE /tmp/"
  exit 1
else
  echo " Install complete - all packages installed successfully"
  echo "============================================"
  echo ""
  echo "[OK] All missing packages have been installed."
  echo "Log file on remote host: $LOG_FILE"
fi
ODOO_CHECK_SCRIPT

  # Run it by passing the file content through SSH stdin
  run_ssh_auto "PASSWORD='$PASSWORD' bash -s" < "$TMP_SCRIPT"
  rm -f "$TMP_SCRIPT"

  echo ""
  echo "[odoo-check] step 3/3: revoke key (via trap)"
}

do_odoo_setup() {
  if [ "$AUTH_MODE" != "password" ]; then
    [ -n "$KEY" ] || { echo "ERROR: --key required for odoo-setup action in auth-mode $AUTH_MODE"; exit 1; }
  fi

  echo "╔══════════════════════════════════════════════════╗"
  echo "║           Odoo Full Setup (odoo-setup)           ║"
  echo "║  1) remote-logrotate — log rotation config      ║"
  echo "║  2) odoo-check  — deps install                  ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""

  # ── Phase 1: remote-logrotate ───────────────────────────────
  echo "━━━ Phase 1/2: Remote log rotation setup ━━━"
  do_remote_logrotate
  # do_remote_logrotate sets its own trap for revoke on EXIT
  # We need to reset the trap before phase 2
  trap - EXIT

  echo ""
  echo "━━━ Phase 2/2: Odoo dependency check & install ━━━"
  do_odoo_check
  # do_odoo_check has its own trap
  trap - EXIT

  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  odoo-setup complete!                            ║"
  echo "╚══════════════════════════════════════════════════╝"
}

do_remote_logrotate() {
  if [ "$AUTH_MODE" != "password" ]; then
    [ -n "$KEY" ] || { echo "ERROR: --key required for remote-logrotate action in auth-mode $AUTH_MODE"; exit 1; }
  fi

  trap 'echo ""; echo "[remote-logrotate] cleanup: revoking key..."; do_revoke' EXIT

  # ── Emergency disk check & cleanup (before inject) ─────────────────────────
  echo "[remote-logrotate] step 0: checking remote disk space..."
  local DISK_CHECK_SCRIPT
  read -r -d '' DISK_CHECK_SCRIPT <<'DISK_CHECK_EOF' || true
#!/usr/bin/env bash
set -uo pipefail

# Check disk usage on key partitions
echo "=== [disk-check] Pre-flight disk space ==="
df -h / /var /tmp /home 2>/dev/null | sort -u

# Find the partition where authorized_keys lives
AUTH_DIR="$HOME/.ssh"
AUTH_PART=$(df "$AUTH_DIR" 2>/dev/null | tail -1 | awk '{print $5}' || echo "?")
AUTH_AVAIL=$(df "$AUTH_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "?")
echo ""
echo "  authorized_keys partition: $AUTH_PART (available: $AUTH_AVAIL)"

# Check if any partition is >= 95% full
CRITICAL=0
while IFS= read -r line; do
  usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $6}')
  [ -z "$usage" ] && continue
  [[ "$usage" =~ ^[0-9]+$ ]] || continue
  if [ "$usage" -ge 95 ]; then
    CRITICAL=1
    echo ""
    echo "  [CRITICAL] $mount is ${usage}% full!"
  fi
done < <(df -h 2>/dev/null | tail -n +2)

if [ "$CRITICAL" = "1" ]; then
  echo ""
  echo "=== [disk-check] Emergency cleanup ==="

  # 1. Clean apt cache
  if command -v apt-get &>/dev/null; then
    echo "  [cleanup] apt cache..."
    echo "$PASSWORD" | sudo -S apt-get clean 2>/dev/null || true
  fi

  # 2. Clean old journal logs (keep last 2 days)
  if command -v journalctl &>/dev/null; then
    echo "  [cleanup] journal logs (keeping 2 days)..."
    echo "$PASSWORD" | sudo -S journalctl --vacuum-time=2d 2>/dev/null || true
  fi

  # 3. Truncate Odoo logs that are > 100MB (emergency, not rotate — just cut)
  echo "  [cleanup] Truncating large Odoo logs (>100MB)..."
  for log_candidate in \
    /var/log/odoo/*.log \
    /var/log/odoo-server.log \
    /opt/odoo/logs/*.log \
    /home/odoo/*.log; do
    [ -f "$log_candidate" ] || continue
    size_kb=$(du -k "$log_candidate" 2>/dev/null | cut -f1 || echo 0)
    if [ "$size_kb" -gt 102400 ]; then
      echo "    Truncating $log_candidate ($(du -sh "$log_candidate" | cut -f1))..."
      # Keep last 10000 lines, truncate the rest
      tail -n 10000 "$log_candidate" > "/tmp/odoo_log_tail_$$.tmp" 2>/dev/null || true
      if [ -s "/tmp/odoo_log_tail_$$.tmp" ]; then
        cat "/tmp/odoo_log_tail_$$.tmp" > "$log_candidate" 2>/dev/null || \
          echo "$PASSWORD" | sudo -S tee "$log_candidate" < "/tmp/odoo_log_tail_$$.tmp" >/dev/null 2>&1 || true
      fi
      rm -f "/tmp/odoo_log_tail_$$.tmp"
    fi
  done

  # 4. Clean /tmp old files (> 7 days)
  echo "  [cleanup] Old /tmp files (>7 days)..."
  find /tmp -type f -mtime +7 -delete 2>/dev/null || true

  # 5. Clean old rotated logs
  echo "  [cleanup] Old rotated logs..."
  find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null || true
  find /var/log -name "*.old" -mtime +30 -delete 2>/dev/null || true
  find /var/log -name "*.[0-9]" -mtime +30 -delete 2>/dev/null || true

  echo ""
  echo "=== [disk-check] Post-cleanup disk space ==="
  df -h / /var /tmp /home 2>/dev/null | sort -u

  # Re-check if we freed enough
  AUTH_AVAIL_NEW=$(df "$AUTH_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
  echo ""
  echo "  authorized_keys partition available: $AUTH_AVAIL -> $AUTH_AVAIL_NEW"
else
  echo ""
  echo "  [OK] Disk space is healthy, proceeding."
fi
DISK_CHECK_EOF

  # Run the disk check/cleanup BEFORE inject
  # Note: At this point, key is NOT yet injected on the remote, so we must
  # explicitly use password auth (sshpass) if password is available.
  echo "$DISK_CHECK_SCRIPT" > /tmp/disk_check_$$.sh
  if [ -n "$PASSWORD" ]; then
    run_ssh_pass "PASSWORD='$PASSWORD' bash -s" < /tmp/disk_check_$$.sh || {
      echo "[WARN] Disk check failed, attempting inject anyway..."
    }
  else
    run_ssh_auto "PASSWORD='' bash -s" < /tmp/disk_check_$$.sh || {
      echo "[WARN] Disk check failed, attempting inject anyway..."
    }
  fi
  rm -f /tmp/disk_check_$$.sh

  echo ""
  echo "[remote-logrotate] step 1/3: inject key"
  do_inject

  echo ""
  echo "[remote-logrotate] step 2/3: detect Odoo log path & setup logrotate"
  echo "  rotate-days:  ${ROTATE_DAYS}"
  echo "  rotate-size:  ${ROTATE_SIZE:-<no size limit>}"
  echo "  rotate-count: ${ROTATE_COUNT:-<unlimited>}"

  local TMP_SCRIPT="/tmp/odoo_logrotate_run_$$.sh"
  cat <<'REMOTE_LOGROTATE' > "$TMP_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

echo "=== [remote-logrotate] Detecting ALL Odoo instances ==="

# ── Collect all Odoo log paths (multi-instance aware) ────────────────────────
declare -A LOG_PATHS  # associative array: service_name -> log_path

# ── Method 1: systemctl (most reliable for multi-instance) ───────────────────
if command -v systemctl &>/dev/null; then
  echo "[detect] Scanning systemd units for Odoo services..."
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    svc_name="${unit%.service}"
    echo "  [systemd] Found service: $svc_name"

    # Try to get config path from ExecStart
    EXEC_LINE=$(systemctl show "$unit" --property=ExecStart 2>/dev/null | head -1 || true)
    CONF_PATH=""

    # Extract -c or --config= from ExecStart
    if echo "$EXEC_LINE" | grep -qE '(-c|--config[= ])'; then
      CONF_PATH=$(echo "$EXEC_LINE" | grep -oE '(-c |--config[= ])[^ ;]+' | head -1 | sed 's/^-c //;s/^--config[= ]*//')
    fi

    # Also check drop-in or environment files for config path
    if [ -z "$CONF_PATH" ]; then
      ENV_FILE=$(systemctl show "$unit" --property=EnvironmentFile 2>/dev/null | sed 's/^EnvironmentFile=//' | tr -d ' ' || true)
      if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
        CONF_PATH=$(grep -oP '(?<=ODOO_CONFIG=|CONFIG_FILE=).*' "$ENV_FILE" 2>/dev/null | head -1 || true)
      fi
    fi

    # Try to read logfile from the config
    LOG_PATH=""
    if [ -n "$CONF_PATH" ] && [ -f "$CONF_PATH" ]; then
      LOG_PATH=$(awk -F= '/^[[:space:]]*logfile[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$CONF_PATH" 2>/dev/null | head -1 || true)
      [ -n "$LOG_PATH" ] && echo "    [config] $CONF_PATH -> logfile: $LOG_PATH"
    fi

    # Fallback: check ExecStart for --logfile
    if [ -z "$LOG_PATH" ]; then
      LOG_PATH=$(echo "$EXEC_LINE" | grep -oE '(--logfile[= ])[^ ;]+' | head -1 | sed 's/^--logfile[= ]*//' || true)
      [ -n "$LOG_PATH" ] && echo "    [execstart] logfile: $LOG_PATH"
    fi

    if [ -n "$LOG_PATH" ] && [ -f "$LOG_PATH" ]; then
      LOG_PATHS["$svc_name"]="$LOG_PATH"
    else
      echo "    [WARN] Could not find log file for $svc_name (config: ${CONF_PATH:-none}, log: ${LOG_PATH:-none})"
    fi
  done < <(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null | awk '/[Oo]doo/{print $1}')
fi

# ── Method 2: process scan (catch non-systemd or Docker instances) ───────────
echo ""
echo "[detect] Scanning running processes for Odoo instances..."
while IFS= read -r log_path; do
  [ -z "$log_path" ] && continue
  if [ -f "$log_path" ]; then
    # Use the log path as a pseudo service name if not already found
    base_name=$(basename "$log_path" .log)
    key="proc-${base_name}"
    # Don't overwrite systemd-discovered entries
    already_found=0
    for existing in "${LOG_PATHS[@]:-}"; do
      [ "$existing" = "$log_path" ] && already_found=1 && break
    done
    if [ "$already_found" = "0" ]; then
      LOG_PATHS["$key"]="$log_path"
      echo "  [process] Found: $log_path"
    fi
  fi
done < <(ps aux 2>/dev/null | awk '
  /[Oo]doo/ && $0 !~ /awk/ {
    for (i=1; i<=NF; i++) {
      if ($i == "--logfile" && (i+1)<=NF) { print $(i+1) }
      if ($i ~ /^--logfile=/) { sub(/^--logfile=/, "", $i); print $i }
    }
  }
')

# Also scan config files found in process args
while IFS= read -r conf_path; do
  [ -z "$conf_path" ] && continue
  [ ! -f "$conf_path" ] && continue
  log_path=$(awk -F= '/^[[:space:]]*logfile[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$conf_path" 2>/dev/null | head -1 || true)
  if [ -n "$log_path" ] && [ -f "$log_path" ]; then
    already_found=0
    for existing in "${LOG_PATHS[@]:-}"; do
      [ "$existing" = "$log_path" ] && already_found=1 && break
    done
    if [ "$already_found" = "0" ]; then
      base_name=$(basename "$log_path" .log)
      LOG_PATHS["proc-${base_name}"]="$log_path"
      echo "  [config] $conf_path -> $log_path"
    fi
  fi
done < <(ps aux 2>/dev/null | awk '
  /[Oo]doo/ && $0 !~ /awk/ {
    for (i=1; i<=NF; i++) {
      if ($i == "-c" && (i+1)<=NF) { print $(i+1) }
      if ($i ~ /^--config=/) { sub(/^--config=/, "", $i); print $i }
    }
  }
')

# ── Method 3: common path fallback (if nothing found yet) ────────────────────
if [ ${#LOG_PATHS[@]} -eq 0 ]; then
  echo ""
  echo "[detect] No instances found via systemd/process, scanning common paths..."
  for candidate in \
    /var/log/odoo/odoo.log \
    /var/log/odoo/odoo-server.log \
    /var/log/odoo-server.log \
    /var/log/openerp/openerp-server.log \
    /var/log/odoo19/odoo19-cargo-prd.log \
    /opt/odoo/logs/odoo.log \
    /home/odoo/odoo.log; do
    if [ -f "$candidate" ]; then
      base_name=$(basename "$candidate" .log)
      LOG_PATHS["fallback-${base_name}"]="$candidate"
      echo "  [fallback] Found: $candidate"
    fi
  done
fi

# ── Result summary ───────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Discovered ${#LOG_PATHS[@]} Odoo log file(s)"
echo "============================================"

if [ ${#LOG_PATHS[@]} -eq 0 ]; then
  echo "[ERROR] Could not detect any Odoo log file paths automatically."
  exit 1
fi

for svc in "${!LOG_PATHS[@]}"; do
  lp="${LOG_PATHS[$svc]}"
  sz=$(du -sh "$lp" 2>/dev/null | cut -f1 || echo "?")
  own=$(stat -c '%U:%G' "$lp" 2>/dev/null || echo "?:?")
  echo "  [$svc] $lp  (size: $sz, owner: $own)"
done

# ── Generate logrotate config for ALL discovered instances ───────────────────
LOGROTATE_CONF="/etc/logrotate.d/odoo"
TMP_LOGROTATE_CONF="$(mktemp /tmp/odoo.logrotate.XXXXXX.conf)"

{
  echo "# Auto-generated by ssh_key_inject.sh (multi-instance)"
  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Instances: ${#LOG_PATHS[@]}"
  echo ""

  for svc in "${!LOG_PATHS[@]}"; do
    lp="${LOG_PATHS[$svc]}"
    LOG_USER=$(stat -c '%U' "$lp" 2>/dev/null || echo "odoo")
    LOG_GROUP=$(stat -c '%G' "$lp" 2>/dev/null || echo "odoo")

    echo "# Instance: $svc"
    echo "$lp {"
    echo "    daily"
    [ -n "${ROTATE_COUNT:-}" ] && echo "    rotate ${ROTATE_COUNT}"
    echo "    maxage ${ROTATE_DAYS}"
    echo "    compress"
    echo "    delaycompress"
    echo "    missingok"
    echo "    notifempty"
    echo "    copytruncate"
    echo "    su ${LOG_USER} ${LOG_GROUP}"
    [ -n "${ROTATE_SIZE:-}" ] && echo "    size ${ROTATE_SIZE}"
    echo "    dateext"
    echo "    dateformat -%Y%m%d-%H%M%S"
    echo "}"
    echo ""
  done
} > "$TMP_LOGROTATE_CONF"

echo ""
echo "=== [remote-logrotate] Writing $LOGROTATE_CONF ==="
echo "    (covering ${#LOG_PATHS[@]} instance(s))"

# Helper: run sudo with password if available, else try passwordless sudo
do_sudo() {
  if [ -n "${PASSWORD:-}" ]; then
    echo "$PASSWORD" | sudo -S "$@"
  else
    sudo -n "$@"
  fi
}

if do_sudo cp "$TMP_LOGROTATE_CONF" "$LOGROTATE_CONF"; then
  do_sudo chmod 644 "$LOGROTATE_CONF" >/dev/null 2>&1 || true
  echo "[OK] config written: $LOGROTATE_CONF"
  echo ""
  echo "--- Config content ---"
  cat "$LOGROTATE_CONF"
  echo "--- End config ---"
  echo ""
  do_sudo logrotate --debug "$LOGROTATE_CONF" 2>&1 | tail -30 || true
else
  echo "[WARN] Cannot write $LOGROTATE_CONF (sudo issue)."
fi

echo ""
rm -f "$TMP_LOGROTATE_CONF" 2>/dev/null || true

echo "=== [remote-logrotate] Setup complete ==="
echo "  Config:       $LOGROTATE_CONF"
echo "  Instances:    ${#LOG_PATHS[@]}"
echo "  Schedule:     daily, max ${ROTATE_DAYS} days"
[ -n "${ROTATE_COUNT:-}" ] && echo "  File limit:   ${ROTATE_COUNT}" || echo "  File limit:   unlimited"
[ -n "${ROTATE_SIZE:-}" ] && echo "  Size trigger: ${ROTATE_SIZE}"
for svc in "${!LOG_PATHS[@]}"; do
  echo "  [$svc] ${LOG_PATHS[$svc]}"
done
REMOTE_LOGROTATE

  run_ssh_auto "PASSWORD='$PASSWORD' ROTATE_DAYS='$ROTATE_DAYS' ROTATE_SIZE='$ROTATE_SIZE' ROTATE_COUNT='$ROTATE_COUNT' bash -s" < "$TMP_SCRIPT"
  rm -f "$TMP_SCRIPT"

  echo ""
  echo "[remote-logrotate] step 3/3: revoke key (via trap)"
}

do_logrotate() {
  echo "[logrotate] Rotating local OpenClaw gateway logs..."
  local LOG_DIR="$HOME/.openclaw/logs"
  local MAX_LOGS=5

  for log_type in "gateway.log" "gateway.err.log"; do
      local BASE_FILE="$LOG_DIR/$log_type"
      if [ -s "$BASE_FILE" ]; then
          echo "  -> Rotating $log_type..."
          for i in $(seq $((MAX_LOGS - 1)) -1 1); do
              if [ -f "$BASE_FILE.$i.gz" ]; then
                  mv "$BASE_FILE.$i.gz" "$BASE_FILE.$((i + 1)).gz"
              fi
          done
          cp "$BASE_FILE" "$BASE_FILE.1"
          > "$BASE_FILE"
          gzip -f "$BASE_FILE.1"
          echo "  -> Done: $log_type"
      fi
  done

  find "$LOG_DIR" -name "gateway*.gz" -type f | while read -r file; do
      local num=$(echo "$file" | grep -o -E '\.[0-9]+\.gz$' | tr -d '.gz')
      if [ -n "$num" ] && [ "$num" -gt "$MAX_LOGS" ]; then
          echo "  -> Removing old log: $(basename "$file")"
          rm "$file"
      fi
  done
  echo "[logrotate] Finished."
}

# ── Main entry point ──────────────────────────────────────────────────────────
case "$ACTION" in
  inject)           do_inject ;;
  revoke)           do_revoke ;;
  status)           do_status ;;
  auto)             do_auto ;;
  odoo-check)       do_odoo_check ;;
  odoo-setup)       do_odoo_setup ;;
  logrotate)        do_logrotate ;;
  remote-logrotate) do_remote_logrotate ;;
esac
