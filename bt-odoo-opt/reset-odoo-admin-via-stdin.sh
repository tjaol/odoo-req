#!/bin/bash
set -euo pipefail

# expect-driven stable version for environments where the only reliable entry is:
#   ssh -tt ... 'sudo -S -p "" -iu odoo'
# We enter the odoo shell first, then use expect to paste a temp script and execute it.

SSH_USER="adminfpd"
SSH_HOST="203.150.106.153"
SSH_PORT="14321"
KEYCHAIN_SERVICE="bt-odoo-pass"
DB_NAME="v19_production_horizon_06032026"
INSTANCE_HINT="odoo19-prd"
PINNED_PYTHON_BIN="/data/odoo19/venv/bin/python"
PINNED_ODOO_BIN="/data/odoo19/odoo/odoo-bin"
PINNED_ODOO_CONF="/etc/odoo19/odoo19-prd.conf"
ADMIN_LOGIN="admin"
ADMIN_ID="2"

usage() {
  cat <<'EOF'
Usage:
  odoo-reset-admin probe
  odoo-reset-admin reset '<NEW_PASSWORD>'

Modes:
  probe                探测远端 Odoo 运行参数，不改数据
  reset <NEW_PASSWORD> 使用 Odoo shell 重置 admin 密码
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

MODE="$1"
shift || true
NEW_PASSWORD="${1:-}"

if [[ "$MODE" != "probe" && "$MODE" != "reset" ]]; then
  usage
  exit 1
fi

if [[ "$MODE" == "reset" && -z "$NEW_PASSWORD" ]]; then
  echo "ERROR: reset 模式必须提供新密码" >&2
  exit 1
fi

if ! command -v security >/dev/null 2>&1; then
  echo "ERROR: macOS 'security' command not found" >&2
  exit 1
fi
if ! command -v ssh >/dev/null 2>&1; then
  echo "ERROR: ssh command not found" >&2
  exit 1
fi
if ! command -v expect >/dev/null 2>&1; then
  echo "ERROR: expect command not found" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECT_SCRIPT="$SCRIPT_DIR/odoo-reset-admin.expect"
if [[ ! -x "$EXPECT_SCRIPT" ]]; then
  chmod +x "$EXPECT_SCRIPT"
fi

ODOO_SUDO_PASS="$(security find-generic-password -a "$SSH_USER" -s "$KEYCHAIN_SERVICE" -w)"
export ODOO_SUDO_PASS

REMOTE_TMP="/tmp/odoo-reset-admin-${MODE}-$$.sh"
LOCAL_TMP="$(mktemp -t "odoo-reset-admin.${MODE}")"
chmod 600 "$LOCAL_TMP"

cleanup() {
  unset ODOO_SUDO_PASS NEW_PASSWORD NEW_PASSWORD_B64 || true
  rm -f "$LOCAL_TMP" || true
}
trap cleanup EXIT

if [[ "$MODE" == "probe" ]]; then
  cat > "$LOCAL_TMP" <<EOF
#!/bin/bash
set -eu
RAW_CMD="\$(ps -ef | grep '[o]doo' | grep -v 'odoo-bin shell' | grep -E '${INSTANCE_HINT}|${PINNED_ODOO_CONF}|${DB_NAME}' | head -n1 || true)"
echo "RAW_CMD=\$RAW_CMD"

PYTHON_BIN="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i ~ /\/venv\/bin\/python([0-9.]*)?$/){print \$i; exit}}}')"
[ -n "\${PYTHON_BIN:-}" ] || PYTHON_BIN="${PINNED_PYTHON_BIN}"
ODOO_BIN="${PINNED_ODOO_BIN}"
ODOO_CONF="${PINNED_ODOO_CONF}"
DB_HOST="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_host"){print \$(i+1); exit} if(index(\$i,"--db_host=")==1){sub(/^--db_host=/,"",\$i); print \$i; exit}}}')"
DB_PORT="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_port"){print \$(i+1); exit} if(index(\$i,"--db_port=")==1){sub(/^--db_port=/,"",\$i); print \$i; exit}}}')"
DB_USER="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_user"){print \$(i+1); exit} if(index(\$i,"--db_user=")==1){sub(/^--db_user=/,"",\$i); print \$i; exit}}}')"
DB_PASSWORD="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_password"){print \$(i+1); exit} if(index(\$i,"--db_password=")==1){sub(/^--db_password=/,"",\$i); print \$i; exit}}}')"

echo "PYTHON_BIN=\$PYTHON_BIN"
echo "ODOO_BIN=\$ODOO_BIN"
echo "ODOO_CONF=\$ODOO_CONF"
echo "DB_HOST=\${DB_HOST:-}"
echo "DB_PORT=\${DB_PORT:-}"
echo "DB_USER=\${DB_USER:-}"
if [ -n "\${DB_PASSWORD:-}" ]; then
  echo "DB_PASSWORD=<present>"
else
  echo "DB_PASSWORD=<empty>"
fi

[ -n "\$ODOO_BIN" ] || { echo "ERROR: ODOO_BIN not found"; exit 21; }
[ -n "\$ODOO_CONF" ] || { echo "ERROR: ODOO_CONF not found"; exit 22; }

echo "PROBE_OK"
EOF
else
  NEW_PASSWORD_B64="$(python3 - <<'PY' "$NEW_PASSWORD"
import base64, sys
print(base64.b64encode(sys.argv[1].encode('utf-8')).decode('ascii'))
PY
)"
  cat > "$LOCAL_TMP" <<EOF
#!/bin/bash
set -eu
RAW_CMD="\$(ps -ef | grep '[o]doo' | grep -v 'odoo-bin shell' | grep -E '${INSTANCE_HINT}|${PINNED_ODOO_CONF}|${DB_NAME}' | head -n1 || true)"
echo "RAW_CMD=\$RAW_CMD"

PYTHON_BIN="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i ~ /\/venv\/bin\/python([0-9.]*)?$/){print \$i; exit}}}')"
[ -n "\${PYTHON_BIN:-}" ] || PYTHON_BIN="${PINNED_PYTHON_BIN}"
ODOO_BIN="${PINNED_ODOO_BIN}"
ODOO_CONF="${PINNED_ODOO_CONF}"
DB_HOST="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_host"){print \$(i+1); exit} if(index(\$i,"--db_host=")==1){sub(/^--db_host=/,"",\$i); print \$i; exit}}}')"
DB_PORT="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_port"){print \$(i+1); exit} if(index(\$i,"--db_port=")==1){sub(/^--db_port=/,"",\$i); print \$i; exit}}}')"
DB_USER="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_user"){print \$(i+1); exit} if(index(\$i,"--db_user=")==1){sub(/^--db_user=/,"",\$i); print \$i; exit}}}')"
DB_PASSWORD="\$(printf '%s\n' "\$RAW_CMD" | awk '{for(i=1;i<=NF;i++){if(\$i=="--db_password"){print \$(i+1); exit} if(index(\$i,"--db_password=")==1){sub(/^--db_password=/,"",\$i); print \$i; exit}}}')"

[ -n "\$PYTHON_BIN" ] || { echo "ERROR: PYTHON_BIN not found"; exit 20; }
[ -n "\$ODOO_BIN" ] || { echo "ERROR: ODOO_BIN not found"; exit 21; }
[ -n "\$ODOO_CONF" ] || { echo "ERROR: ODOO_CONF not found"; exit 22; }

unset PYTHONPATH PYTHONHOME PYTHONUSERBASE || true
CMD="PYTHONNOUSERSITE=1 \$PYTHON_BIN -s \$ODOO_BIN shell --no-http -c \$ODOO_CONF -d ${DB_NAME}"
[ -n "\${DB_HOST:-}" ] && CMD="\$CMD --db_host \$DB_HOST"
[ -n "\${DB_PORT:-}" ] && CMD="\$CMD --db_port \$DB_PORT"
[ -n "\${DB_USER:-}" ] && CMD="\$CMD --db_user \$DB_USER"
[ -n "\${DB_PASSWORD:-}" ] && CMD="\$CMD --db_password \$DB_PASSWORD"

echo "RUNNING: \$CMD"

eval "\$CMD" <<'PYEOF'
import base64
new_password = base64.b64decode('${NEW_PASSWORD_B64}').decode('utf-8')
users = env['res.users'].sudo()
admin = users.browse(${ADMIN_ID})
if not admin.exists():
    admin = users.search([('login', '=', '${ADMIN_LOGIN}')], limit=1)
if not admin:
    raise Exception('admin user not found')
admin.write({'password': new_password})
env.cr.commit()
print('OK: admin password reset done')
PYEOF
EOF
fi

exec "$EXPECT_SCRIPT" "$SSH_USER" "$SSH_HOST" "$SSH_PORT" "$REMOTE_TMP" "$LOCAL_TMP"
