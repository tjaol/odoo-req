#!/usr/bin/env bash
# ssh_key_inject.sh — 临时注入/撤销 SSH 公钥，方便免密执行需要 sudo 的远程任务
# 用法：
#   注入：./ssh_key_inject.sh --host <ip> --password <pass> --action inject [--pubkey-file ~/.ssh/id_rsa.pub]
#   撤销：./ssh_key_inject.sh --host <ip> --password <pass> --action revoke [--pubkey-file ~/.ssh/id_rsa.pub]
#   自动流程（注入→执行→撤销）：--action auto --key <私钥路径> --run-cmd <远程命令>
set -euo pipefail

HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""         # inject | revoke | auto | status
RUN_CMD=""        # 仅 auto 模式使用：注入后要执行的远程命令
SSH_TIMEOUT="10"
PUBKEY_FILE=""    # 本机公钥文件路径，默认自动探测
PUBKEY=""         # 公钥内容（优先级：--pubkey-file > 自动探测）

usage() {
  cat <<'EOF'
Usage: ssh_key_inject.sh --host <ip_or_dns> --password <pass> --action <action> [options]

Actions:
  inject   将公钥追加到远端 ~/.ssh/authorized_keys（幂等，不重复添加）
  revoke   从远端 authorized_keys 删除该公钥
  status   检查公钥当前是否存在于远端
  auto     注入 → 用私钥执行 --run-cmd → 撤销（三步自动完成，保证 revoke）

Options:
  --host <ip_or_dns>        required
  --port <ssh_port>         default 22
  --user <ssh_user>         default root
  --password <password>     SSH 密码（用于 inject/revoke/status 阶段）
  --key <private_key>       私钥路径（auto 模式中用于执行阶段）
  --pubkey-file <path>      本机公钥文件路径，默认自动探测 ~/.ssh/id_rsa.pub / id_ed25519.pub
  --run-cmd <cmd>           auto 模式中注入后执行的远程命令
  --ssh-timeout <sec>       default 10
  -h|--help

Examples:
  # 注入公钥（自动探测本机公钥）
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action inject

  # 注入指定公钥文件
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action inject --pubkey-file ~/.ssh/id_ed25519.pub

  # 撤销公钥
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action revoke

  # 检查是否已注入
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action status

  # 自动流程：注入 → 执行 bt 脚本 → 撤销
  ./ssh_key_inject.sh \
    --host 10.0.0.1 \
    --password 'mypass' \
    --key ~/.ssh/id_rsa \
    --action auto \
    --run-cmd "bash /tmp/bt_odoo_optimize.sh --apply --logrotate"
EOF
}

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
[ -n "$ACTION" ] || { echo "--action is required (inject|revoke|status|auto)"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto)$ ]] || { echo "--action must be inject|revoke|status|auto"; exit 1; }

# ── 加载公钥（从文件读取，不硬编码）─────────────────────────────────────────
load_pubkey() {
  # 1. 显式指定 --pubkey-file
  if [ -n "$PUBKEY_FILE" ]; then
    [ -f "$PUBKEY_FILE" ] || { echo "ERROR: pubkey file not found: $PUBKEY_FILE"; exit 1; }
    PUBKEY="$(cat "$PUBKEY_FILE")"
    echo "[key] using pubkey from: $PUBKEY_FILE"
    return
  fi

  # 2. 从 --key 私钥路径推导 .pub 文件
  if [ -n "$KEY" ]; then
    local pub="${KEY}.pub"
    if [ -f "$pub" ]; then
      PUBKEY="$(cat "$pub")"
      echo "[key] using pubkey from: $pub"
      return
    fi
  fi

  # 3. 自动探测常见路径
  local candidates=(
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_rsa.pub"
    "$HOME/.ssh/id_ecdsa.pub"
  )
  for f in "${candidates[@]}"; do
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
  [ -n "$KEY" ] || { echo "ERROR: --key required for key-auth step"; exit 1; }
  ssh "${SSH_BASE_OPTS[@]}" -i "$KEY" -o BatchMode=yes "$REMOTE" "$@"
}

# ── 动作实现 ──────────────────────────────────────────────────────────────────

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
  [ -n "$KEY" ]     || { echo "ERROR: --key required for auto action (used after inject)"; exit 1; }
  [ -n "$PASSWORD" ] || { echo "ERROR: --password required for auto action (used for inject/revoke)"; exit 1; }

  revoke_on_exit() {
    echo ""
    echo "[auto] cleaning up: revoking injected key..."
    do_revoke
  }
  trap revoke_on_exit EXIT

  echo "[auto] step 1/3: inject key"
  do_inject

  echo ""
  echo "[auto] step 2/3: execute via key auth"
  echo "[auto] cmd: ${RUN_CMD}"
  run_ssh_key bash -c "$RUN_CMD"

  echo ""
  echo "[auto] step 3/3: revoke key (via trap on EXIT)"
}

# ── 主入口 ────────────────────────────────────────────────────────────────────
case "$ACTION" in
  inject) do_inject ;;
  revoke) do_revoke ;;
  status) do_status ;;
  auto)   do_auto   ;;
esac
# 用法：
#   注入：./ssh_key_inject.sh --host <ip> --password <pass> --action inject [--pubkey <key_string>]
#   撤销：./ssh_key_inject.sh --host <ip> --password <pass> --action revoke [--pubkey <key_string>]
#   自动流程（注入→执行→撤销）：--action auto --key <私钥路径> --run-cmd <远程命令>
set -euo pipefail

HOST=""
PORT="22"
USER="root"
PASSWORD=""
KEY=""
ACTION=""         # inject | revoke | auto | status
RUN_CMD=""        # 仅 auto 模式使用：注入后要执行的远程命令
SSH_TIMEOUT="10"

# 默认公钥（Henri 的）
DEFAULT_PUBKEY="# PUBKEY_REMOVED
PUBKEY=""

usage() {
  cat <<'EOF'
Usage: ssh_key_inject.sh --host <ip_or_dns> --password <pass> --action <action> [options]

Actions:
  inject   将公钥追加到远端 ~/.ssh/authorized_keys（幂等，不重复添加）
  revoke   从远端 authorized_keys 删除该公钥
  status   检查公钥当前是否存在于远端
  auto     注入 → 用私钥执行 --run-cmd → 撤销（三步自动完成，保证 revoke）

Options:
  --host <ip_or_dns>      required
  --port <ssh_port>       default 22
  --user <ssh_user>       default root
  --password <password>   SSH 密码（用于 inject/revoke/status 阶段）
  --key <private_key>     私钥路径（auto 模式中用于执行阶段）
  --pubkey <key_string>   要注入的公钥内容（默认使用内置公钥）
  --run-cmd <cmd>         auto 模式中注入后执行的远程命令
  --ssh-timeout <sec>     default 10
  -h|--help

Examples:
  # 注入公钥
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action inject

  # 撤销公钥
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action revoke

  # 检查是否已注入
  ./ssh_key_inject.sh --host 10.0.0.1 --password 'mypass' --action status

  # 自动流程：注入 → 执行 bt 脚本 → 撤销
  ./ssh_key_inject.sh \
    --host 10.0.0.1 \
    --password 'mypass' \
    --key ~/.ssh/id_rsa \
    --action auto \
    --run-cmd "bash /tmp/bt_odoo_optimize.sh --apply --logrotate"
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)        HOST="${2:-}";        shift 2 ;;
    --port)        PORT="${2:-}";        shift 2 ;;
    --user)        USER="${2:-}";        shift 2 ;;
    --password)    PASSWORD="${2:-}";    shift 2 ;;
    --key)         KEY="${2:-}";         shift 2 ;;
    --pubkey)      PUBKEY="${2:-}";      shift 2 ;;
    --action)      ACTION="${2:-}";      shift 2 ;;
    --run-cmd)     RUN_CMD="${2:-}";     shift 2 ;;
    --ssh-timeout) SSH_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ── 校验 ──────────────────────────────────────────────────────────────────────
[ -n "$HOST" ]   || { echo "--host is required"; exit 1; }
[ -n "$ACTION" ] || { echo "--action is required (inject|revoke|status|auto)"; exit 1; }
[[ "$ACTION" =~ ^(inject|revoke|status|auto)$ ]] || { echo "--action must be inject|revoke|status|auto"; exit 1; }

if [ -z "$PUBKEY" ]; then
  PUBKEY="$DEFAULT_PUBKEY"
fi

REMOTE="${USER}@${HOST}"

# ── SSH 工具函数 ───────────────────────────────────────────────────────────────
SSH_BASE_OPTS=(
  -p "$PORT"
  -o ConnectTimeout="$SSH_TIMEOUT"
  -o StrictHostKeyChecking=accept-new
  -o BatchMode=no
)

run_ssh_pass() {
  # 用 password 执行（需要 sshpass）
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass not found. Install: brew install hudochenkov/sshpass/sshpass  OR  apt install sshpass"
    exit 1
  fi
  sshpass -p "$PASSWORD" ssh "${SSH_BASE_OPTS[@]}" -o PasswordAuthentication=yes "$REMOTE" "$@"
}

run_ssh_key() {
  # 用私钥执行
  [ -n "$KEY" ] || { echo "ERROR: --key required for key-auth step"; exit 1; }
  ssh "${SSH_BASE_OPTS[@]}" -i "$KEY" -o BatchMode=yes "$REMOTE" "$@"
}

# ── 动作实现 ──────────────────────────────────────────────────────────────────

do_inject() {
  echo "[inject] → ${REMOTE}:~/.ssh/authorized_keys"
  # 幂等：先检查是否已存在，再追加
  local key_id
  key_id="$(printf '%s' "$PUBKEY" | awk '{print $NF}')"   # 取注释部分作为标识
  run_ssh_pass bash -s <<REMOTE_INJECT
set -e
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
if grep -qF '${key_id}' ~/.ssh/authorized_keys 2>/dev/null; then
  echo "[inject] key already present (${key_id}), skipping."
else
  printf '%s\n' '${PUBKEY}' >> ~/.ssh/authorized_keys
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
  # 创建临时文件再原子替换，避免清空文件
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
  [ -n "$KEY" ]     || { echo "ERROR: --key required for auto action (used after inject)"; exit 1; }
  [ -n "$PASSWORD" ] || { echo "ERROR: --password required for auto action (used for inject/revoke)"; exit 1; }

  # 保证无论如何都会 revoke
  revoke_on_exit() {
    echo ""
    echo "[auto] cleaning up: revoking injected key..."
    do_revoke
  }
  trap revoke_on_exit EXIT

  echo "[auto] step 1/3: inject key"
  do_inject

  echo ""
  echo "[auto] step 2/3: execute via key auth"
  echo "[auto] cmd: ${RUN_CMD}"
  run_ssh_key bash -c "$RUN_CMD"

  echo ""
  echo "[auto] step 3/3: revoke key (via trap on EXIT)"
  # trap 会自动执行 revoke_on_exit
}

# ── 主入口 ────────────────────────────────────────────────────────────────────
case "$ACTION" in
  inject) do_inject ;;
  revoke) do_revoke ;;
  status) do_status ;;
  auto)   do_auto   ;;
esac
