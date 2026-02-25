#!/usr/bin/env bash
# ssh_key_inject.sh - SSH public key injection/revocation + remote task execution framework
# Usage:
#   inject:      ./ssh_key_inject.sh --host <ip> --password <pass> --action inject
#   revoke:      ./ssh_key_inject.sh --host <ip> --password <pass> --action revoke
#   status:      ./ssh_key_inject.sh --host <ip> --password <pass> --action status
#   auto:        ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action auto --run-cmd "bash /tmp/xxx.sh"
#   odoo-check:  ./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action odoo-check
set -euo pipefail

# ── Parameters ────────────────────────────────────────────────────────────────
HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""          # inject | revoke | status | auto | odoo-check
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

Options:
  --host <ip>           required
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
[ -n "$HOST" ]   || { echo "--host is required"; exit 1; }
[ -n "$ACTION" ] || { echo "--action is required"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto|odoo-check)$ ]] || {
  echo "--action must be inject|revoke|status|auto|odoo-check"; exit 1
}

# ── Load public key ───────────────────────────────────────────────────────────
load_pubkey() {
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
VENV_PATH="/opt/odoo/venv"

echo "============================================"
echo " Odoo 19 Dependency Check & Install"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

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

# ── Main entry point ──────────────────────────────────────────────────────────
case "$ACTION" in
  inject)      do_inject ;;
  revoke)      do_revoke ;;
  status)      do_status ;;
  auto)        do_auto ;;
  odoo-check)  do_odoo_check ;;
esac
