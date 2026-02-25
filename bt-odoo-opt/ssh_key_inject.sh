#!/usr/bin/env bash
# ssh_key_inject.sh — SSH 公钥注入/撤销 + 远程任务执行框架
# 用法：
#   注入：    ./ssh_key_inject.sh --host <ip> --password <pass> --action inject
#   撤销：    ./ssh_key_inject.sh --host <ip> --password <pass> --action revoke
#   状态检查：./ssh_key_inject.sh --host <ip> --password <pass> --action status
#   执行任务：./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action auto --run-cmd "bash /tmp/xxx.sh"
#   Odoo检测：./ssh_key_inject.sh --host <ip> --password <pass> --key <privkey> --action odoo-check
set -euo pipefail

# ── 参数 ──────────────────────────────────────────────────────────────────────
HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""          # inject | revoke | status | auto | odoo-check
RUN_CMD=""         # 仅 auto 模式
SSH_TIMEOUT="10"
PUBKEY_FILE=""
PUBKEY=""

usage() {
  cat <<'EOF'
Usage: ssh_key_inject.sh --host <ip> --password <pass> --action <action> [options]

Actions:
  inject      将公钥追加到远端 authorized_keys（幂等）
  revoke      从远端 authorized_keys 删除该公钥
  status      检查公钥是否存在于远端
  auto        注入 → 执行 --run-cmd → 撤销
  odoo-check  注入 → 检测并补装 Odoo 19 Python 依赖 → 撤销

Options:
  --host <ip>           required
  --port <port>         default 22
  --user <user>         default root
  --password <pass>     SSH 密码（inject/revoke/status 阶段使用）
  --key <privkey>       私钥路径（auto/odoo-check 模式执行阶段使用）
  --pubkey-file <path>  指定公钥文件（默认自动探测 ~/.ssh/id_*.pub）
  --run-cmd <cmd>       auto 模式中要执行的远程命令
  --ssh-timeout <sec>   default 10
  -h|--help

Examples:
  # 注入公钥
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action inject

  # 撤销公钥
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action revoke

  # 检查公钥状态
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --action status

  # 执行自定义命令
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --key ~/.ssh/id_ed25519 \
    --action auto --run-cmd "bash /tmp/my_script.sh"

  # 检测并补装 Odoo 19 依赖
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'pass' --key ~/.ssh/id_ed25519 \
    --action odoo-check
EOF
}

# ── 参数解析 ──────────────────────────────────────────────────────────────────
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

# ── 校验 ──────────────────────────────────────────────────────────────────────
[ -n "$HOST" ]   || { echo "--host is required"; exit 1; }
[ -n "$ACTION" ] || { echo "--action is required"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto|odoo-check)$ ]] || {
  echo "--action must be inject|revoke|status|auto|odoo-check"; exit 1
}

# ── 加载公钥 ──────────────────────────────────────────────────────────────────
load_pubkey() {
  if [ -n "$PUBKEY_FILE" ]; then
    [ -f "$PUBKEY_FILE" ] || { echo "ERROR: pubkey file not found: $PUBKEY_FILE"; exit 1; }
    PUBKEY="$(cat "$PUBKEY_FILE")"
    echo "[key] using pubkey from: $PUBKEY_FILE"
    return
  fi

  if [ -n "$KEY" ]; then
    local pub="${KEY}.pub"
    if [ -f "$pub" ]; then
      PUBKEY="$(cat "$pub")"
      echo "[key] using pubkey from: $pub"
      return
    fi
  fi

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

# ── SSH 工具函数 ───────────────────────────────────────────────────────────────
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
  echo "[inject] → ${REMOTE}:~/.ssh/authorized_keys"
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
  echo "[revoke] → ${REMOTE}:~/.ssh/authorized_keys"
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

echo "============================================"
echo " Odoo 19 Library 检测 & 补装"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# 探测 Python 环境
for candidate in \
  /opt/odoo/venv/bin/python3 \
  /opt/odoo/.venv/bin/python3 \
  /home/odoo/venv/bin/python3 \
  /home/odoo/.venv/bin/python3 \
  $(which python3 2>/dev/null || true); do
  if [ -f "$candidate" ] || command -v "$candidate" &>/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
PYTHON=${PYTHON:-$(which python3)}

PY_VERSION=$($PYTHON -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PIP="$(dirname $PYTHON)/pip3"
[ -f "$PIP" ] || PIP="$PYTHON -m pip"

echo "[env] Python: $PYTHON ($PY_VERSION)"
echo "[env] Pip:    $PIP"
echo ""

# 下载 requirements.txt
echo "[1/3] 下载 Odoo 19 requirements.txt..."
if command -v curl &>/dev/null; then
  curl -fsSL "$REQUIREMENTS_URL" -o "$TMP_REQ"
elif command -v wget &>/dev/null; then
  wget -q "$REQUIREMENTS_URL" -O "$TMP_REQ"
else
  echo "ERROR: curl/wget 均不可用"; exit 1
fi
echo "[1/3] 下载完成"
echo ""

# 解析包名
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

# 检测
echo "[2/3] 检测安装状态..."
MISSING=()
while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  [[ "$pkg" == "pypiwin32" ]] && continue
  if $PIP show "$pkg" &>/dev/null 2>&1; then
    echo "  ✅ $pkg"
  else
    echo "  ❌ $pkg (缺失)"
    MISSING+=("$pkg")
  fi
done <<< "$PACKAGES"

echo ""
echo "已安装: $(($(echo "$PACKAGES" | wc -l) - ${#MISSING[@]}))  缺失: ${#MISSING[@]}"

if [ ${#MISSING[@]} -eq 0 ]; then
  echo ""
  echo "✅ 所有 Odoo 19 依赖已安装，无需补装。"
  exit 0
fi

# 补装
echo ""
echo "[3/3] 补装缺失的包..."
FAILED=()
for pkg in "${MISSING[@]}"; do
  echo -n "  安装 $pkg ... "
  if $PIP install "$pkg" >> "$LOG_FILE" 2>&1; then
    echo "✅"
  else
    apt_pkg="python3-$(echo $pkg | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    if apt-get install -y "$apt_pkg" >> "$LOG_FILE" 2>&1; then
      echo "✅ (apt: $apt_pkg)"
    else
      echo "❌"
      FAILED+=("$pkg")
    fi
  fi
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "⚠️  以下包安装失败，需手动处理："
  for pkg in "${FAILED[@]}"; do echo "  - $pkg"; done
  echo "日志：$LOG_FILE"
  exit 1
else
  echo "✅ 所有缺失包补装完成！"
  echo "日志：$LOG_FILE"
fi
ODOO_CHECK_SCRIPT

  echo ""
  echo "[odoo-check] step 3/3: revoke key (via trap)"
}

# ── 主入口 ────────────────────────────────────────────────────────────────────
case "$ACTION" in
  inject)      do_inject ;;
  revoke)      do_revoke ;;
  status)      do_status ;;
  auto)        do_auto ;;
  odoo-check)  do_odoo_check ;;
esac
