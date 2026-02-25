#!/usr/bin/env bash
# ssh_key_inject.sh - SSH public key injection/revocation + remote task execution framework
# Usage:
#   inject:      ./ssh_key_inject.sh --host <ip> --password <pass> --action inject
#   revoke:      ./ssh_key_inject.sh --host <ip> --password <pass> --action revoke
#   status:      ./ssh_key_inject.sh --host <ip> --password <pass> --action status
#   auto:        ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action auto --run-cmd "bash /tmp/xxx.sh"
#   odoo-check:  ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action odoo-check
#   logrotate:   ./ssh_key_inject.sh --action logrotate
set -euo pipefail

# ── Parameters ────────────────────────────────────────────────────────────────
HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""          # inject | revoke | status | auto | odoo-check | logrotate
RUN_CMD=""         # used by auto action only
SSH_TIMEOUT="10"
PUBKEY_FILE=""
PUBKEY=""

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

Options:
  --host <ip>           required (except for logrotate)
  --port <port>         default 22
  --user <user>         default root
  --password <pass>     SSH password (used for inject/revoke/status phases)
  --key <privkey>       Private key path (used for execution phase in auto/odoo-check)
  --pubkey-file <path>  Public key file (auto-detected from ~/.ssh/id_*.pub if not set)
  --run-cmd <cmd>       Remote command to run (auto mode only)
  --ssh-timeout <sec>   default 10
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
  ./ssh_key_inject.sh --host 10.0.0.1 --port 14321 --user adminfpd \
    --password 'pass' --key ~/.ssh/id_ed25519 --action odoo-check

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
    --action)      ACTION="${2:-}";      shift 2 ;;
    --run-cmd)     RUN_CMD="${2:-}";     shift 2 ;;
    --ssh-timeout) SSH_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[ -n "$ACTION" ] || { echo "--action is required"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto|odoo-check|logrotate)$ ]] || {
  echo "--action must be inject|revoke|status|auto|odoo-check|logrotate"; exit 1
}
if [ "$ACTION" != "logrotate" ]; then
  [ -n "$HOST" ] || { echo "--host is required"; exit 1; }
fi

# ── Load public key ───────────────────────────────────────────────────────────
load_pubkey() {
  [ "$ACTION" = "logrotate" ] && return 0
  # 1. Explicit --pubkey-file
  if [ -n "$PUBKEY_FILE" ]; then
    [ -f "$PUBKEY_FILE" ] || { echo "ERROR: pubkey file not found: $PUBKEY_FILE"; exit 1; }
    PUBKEY="$(cat "$PUBKEY_FILE")"
    echo "[key] using pubkey from: $PUBKEY_FILE"
    return
  fi

  # 2. Derive .pub from --key path
  if [ -n "$KEY" ]; then
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
  sshpass -p "$PASSWORD" ssh "${SSH_BASE_OPTS[@]}" -o PasswordAuthentication=yes "$REMOTE" "$@"
}

run_ssh_key() {
  [ -n "$KEY" ] || { echo "ERROR: --key required"; exit 1; }
  ssh "${SSH_BASE_OPTS[@]}" -i "$KEY" -o BatchMode=yes "$REMOTE" "$@"
}

# ── Actions ───────────────────────────────────────────────────────────────────

do_inject() {
  echo "[inject] -> ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
  local pubkey_escaped
  pubkey_escaped="$(printf '%s' "$PUBKEY" | sed "s/'/'\\\\''/g")"
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
  echo "[revoke] -> ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
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
  echo "[status] checking ${REMOTE}:~/.ssh/authorized_keys"
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"
  local found
  found="$(run_ssh_pass bash -s <<REMOTE_STATUS
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
  [ -n "$KEY" ]     || { echo "ERROR: --key required for auto action"; exit 1; }
  [ -n "$PASSWORD" ] || { echo "ERROR: --password required for auto action"; exit 1; }

  trap 'echo ""; echo "[auto] cleanup: revoking key..."; do_revoke' EXIT

  echo "[auto] step 1/3: inject key"
  do_inject

  echo ""
  echo "[auto] step 2/3: execute via key auth"
  echo "[auto] cmd: ${RUN_CMD}"
  run_ssh_key bash -c "$RUN_CMD"

  echo ""
  echo "[auto] step 3/3: revoke key (via trap)"
}

do_odoo_check() {
  [ -n "$KEY" ]      || { echo "ERROR: --key required for odoo-check action"; exit 1; }
  [ -n "$PASSWORD" ] || { echo "ERROR: --password required for odoo-check action"; exit 1; }

  trap 'echo ""; echo "[odoo-check] cleanup: revoking key..."; do_revoke' EXIT

  echo "[odoo-check] step 1/3: inject key"
  do_inject

  echo ""
  echo "[odoo-check] step 2/3: run Odoo 19 dependency check & install"
  run_ssh_key bash -s <<'ODOO_CHECK_SCRIPT'
set -euo pipefail

REQUIREMENTS_URL="https://raw.githubusercontent.com/odoo/odoo/refs/heads/19.0/requirements.txt"
TMP_REQ="/tmp/odoo19_requirements.txt"
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
if command -v dpkg &>/dev/null; then
  for sys_pkg in build-essential libpq-dev libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libffi-dev libjpeg-dev zlib1g-dev libfreetype6-dev liblcms2-dev libtiff-dev libopenjp2-7-dev libwebp-dev; do
    if dpkg -l | grep -q "^ii  $sys_pkg "; then
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
  echo "[WARN] Missing system packages. To fix, please run as ROOT (or use sudo):"
  echo "  apt-get update"
  # exclude wkhtmltopdf from apt install string to recommend the deb
  APT_MISSING=()
  for p in "${SYS_MISSING[@]}"; do [ "$p" != "wkhtmltopdf" ] && APT_MISSING+=("$p"); done
  if [ ${#APT_MISSING[@]} -gt 0 ]; then
    echo "  apt-get install -y ${APT_MISSING[@]}"
  fi
  if [[ " ${SYS_MISSING[@]} " =~ " wkhtmltopdf " ]]; then
    echo ""
    echo "  # For wkhtmltopdf (with patched qt for full PDF features):"
    echo "  wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    echo "  apt-get install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
  fi
  echo "--------------------------------------------"
  echo "Proceeding with Python dependency check anyway..."
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

  echo ""
  echo "[odoo-check] step 3/3: revoke key (via trap)"
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
  inject)      do_inject ;;
  revoke)      do_revoke ;;
  status)      do_status ;;
  auto)        do_auto ;;
  odoo-check)  do_odoo_check ;;
  logrotate)   do_logrotate ;;
esac
