#!/usr/bin/env bash
# ============================================================
# nova.sh — Jenkins Nova Deploy CLI
#
# Usage:
#   ./nova.sh list                    # 列出所有 job 及状态
#   ./nova.sh deploy                  # 部署 Odoo18（不等待）
#   ./nova.sh deploy --rolling        # 部署 Odoo18（滚动重启）
#   ./nova.sh deploy --rolling --wait # 滚动重启并等待完成
#   ./nova.sh restart                 # 重启所有 App Server
#   ./nova.sh ping                    # Ping 连通性测试
#   ./nova.sh ping --wait             # Ping 并等待结果
#   ./nova.sh status [alias]          # 查看最近构建状态
#   ./nova.sh log [alias]             # 查看最近 console log
# ============================================================

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
JENKINS_URL="${JENKINS_URL:-https://barron.tg.co.th/jenkins}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-tQrGaBERMmA*#03}"
AUTH="$JENKINS_USER:$JENKINS_PASS"
FOLDER="Deploy Code On Nova (Ansible)"

# ── Job alias map ───────────────────────────────────────────────────────────────
# deploy          → Deploy Nova Code Odoo18 (NO WAIT)
# deploy-rolling  → Deploy Nova Code Odoo18 (ROLLING RESTART)
# restart         → Just Restart all app servers (NO WAIT)
# ping            → Odoo-DeployServers - PingTest

job_name() {
  case "$1" in
    deploy)         echo "Deploy Nova Code Odoo18 (NO WAIT)" ;;
    deploy-rolling) echo "Deploy Nova Code Odoo18 (ROLLING RESTART)" ;;
    restart)        echo "Just Restart all app servers (NO WAIT)" ;;
    ping)           echo "Odoo-DeployServers - PingTest" ;;
    *)              echo ""; return 1 ;;
  esac
}

# ── Helpers ────────────────────────────────────────────────────────────────────
urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

job_url() {
  local alias="$1"
  local jname
  jname=$(job_name "$alias") || { echo "❌ Unknown alias: $alias"; exit 1; }
  local f_enc j_enc
  f_enc=$(urlencode "$FOLDER")
  j_enc=$(urlencode "$jname")
  echo "$JENKINS_URL/job/$f_enc/job/$j_enc"
}

get_crumb() {
  curl -sg --user "$AUTH" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" \
    2>/dev/null || echo ""
}

color_status() {
  local result="$1"
  case "$result" in
    SUCCESS)  echo "✅ SUCCESS" ;;
    FAILURE)  echo "❌ FAILURE" ;;
    ABORTED)  echo "⛔ ABORTED" ;;
    UNSTABLE) echo "⚠️  UNSTABLE" ;;
    *)        echo "🔄 $result" ;;
  esac
}

# ── wait_for_build <job_url> ───────────────────────────────────────────────────
wait_for_build() {
  local jurl="$1"
  echo "⏳ Waiting for build to complete..."
  sleep 5
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    local raw
    raw=$(curl -sg --user "$AUTH" "$jurl/lastBuild/api/json?tree=result,building,number,duration" 2>/dev/null)
    local building result num dur
    building=$(echo "$raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('building',True))")
    result=$(echo "$raw"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or 'RUNNING')")
    num=$(echo "$raw"      | python3 -c "import json,sys; print(json.load(sys.stdin).get('number','?'))")
    dur=$(echo "$raw"      | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('duration',0))//1000)")

    if [ "$building" = "False" ]; then
      echo "   Build #$num → $(color_status "$result") (${dur}s)"
      [ "$result" = "SUCCESS" ] && return 0 || return 1
    fi
    printf "   [%2ds] Build #%s still running...\r" $((attempt * 5)) "$num"
    sleep 5
  done
}

# ── cmd: list ─────────────────────────────────────────────────────────────────
cmd_list() {
  echo "📡 Jenkins: $JENKINS_URL"
  echo ""
  printf "%-14s %-48s %s\n" "ALIAS" "JOB NAME" "LAST STATUS"
  printf "%-14s %-48s %s\n" "──────────────" "────────────────────────────────────────────────" "────────────"
  for alias in deploy deploy-rolling restart ping; do
    local jname jurl raw result building num
    jname=$(job_name "$alias")
    jurl=$(job_url "$alias")
    raw=$(curl -sg --user "$AUTH" "$jurl/lastBuild/api/json?tree=result,building,number" 2>/dev/null)
    building=$(echo "$raw" | python3 -c "import json,sys; print(json.load(sys.stdin).get('building',False))" 2>/dev/null || echo "False")
    result=$(echo "$raw"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or 'RUNNING')" 2>/dev/null || echo "?")
    num=$(echo "$raw"      | python3 -c "import json,sys; print(json.load(sys.stdin).get('number','?'))" 2>/dev/null || echo "?")
    [ "$building" = "True" ] && result="RUNNING"
    printf "%-14s %-48s %s\n" "$alias" "$jname" "$(color_status "$result") #$num"
  done
  echo ""
}

# ── cmd: trigger <alias> [--wait] ─────────────────────────────────────────────
cmd_trigger() {
  local alias="$1"
  local wait_flag="${2:-}"
  local jname jurl
  jname=$(job_name "$alias") || exit 1
  jurl=$(job_url "$alias")

  # CSRF crumb
  local crumb crumb_header=()
  crumb=$(get_crumb)
  [ -n "$crumb" ] && crumb_header=(-H "$crumb")

  echo "🚀 Triggering: $jname"

  local http_code
  http_code=$(curl -sg -o /dev/null -w "%{http_code}" \
    --user "$AUTH" \
    "${crumb_header[@]}" \
    -X POST "$jurl/build")

  if [[ "$http_code" =~ ^(200|201|302)$ ]]; then
    echo "   ✅ Triggered (HTTP $http_code)"
  else
    echo "   ❌ Failed (HTTP $http_code)"
    exit 1
  fi

  [ "$wait_flag" = "--wait" ] && wait_for_build "$jurl"
}

# ── cmd: status [alias] ────────────────────────────────────────────────────────
cmd_status() {
  local alias="${1:-}"
  if [ -z "$alias" ]; then
    cmd_list; return
  fi

  local jname jurl
  jname=$(job_name "$alias") || exit 1
  jurl=$(job_url "$alias")

  echo "📊 Status: $jname"
  curl -sg --user "$AUTH" "$jurl/lastBuild/api/json?tree=number,result,building,timestamp,duration,url" \
    | python3 -c "
import json,sys,datetime
d = json.load(sys.stdin)
ts  = datetime.datetime.fromtimestamp(d['timestamp']//1000).strftime('%Y-%m-%d %H:%M:%S')
dur = int(d.get('duration',0))//1000
building = d.get('building', False)
result   = d.get('result') or ('RUNNING' if building else '?')
icons = {'SUCCESS':'✅','FAILURE':'❌','ABORTED':'⛔','UNSTABLE':'⚠️ ','RUNNING':'🔄'}
icon = icons.get(result, '❓')
print(f'  Build #  : {d[\"number\"]}')
print(f'  Status   : {icon} {result}')
print(f'  Started  : {ts}')
print(f'  Duration : {dur}s')
print(f'  URL      : {d.get(\"url\",\"\").replace(\"http://192.168.12.1:8080\",\"$JENKINS_URL\".rstrip(\"/\"))}')
"
}

# ── cmd: log [alias] ──────────────────────────────────────────────────────────
cmd_log() {
  local alias="${1:-}"
  [ -n "$alias" ] || { echo "Usage: $0 log <alias>"; exit 1; }
  local jname jurl
  jname=$(job_name "$alias") || exit 1
  jurl=$(job_url "$alias")

  echo "📋 Console log: $jname (last build)"
  echo "──────────────────────────────────────"
  curl -sg --user "$AUTH" "$jurl/lastBuild/consoleText" | tail -60
}

# ── Main ───────────────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
  list)
    cmd_list
    ;;
  deploy)
    ROLLING=""
    WAIT=""
    for arg in "$@"; do
      [ "$arg" = "--rolling" ] && ROLLING=1
      [ "$arg" = "--wait" ]    && WAIT="--wait"
    done
    if [ -n "$ROLLING" ]; then
      cmd_trigger "deploy-rolling" "$WAIT"
    else
      cmd_trigger "deploy" "$WAIT"
    fi
    ;;
  restart)
    WAIT=""
    [[ "${1:-}" == "--wait" ]] && WAIT="--wait"
    cmd_trigger "restart" "$WAIT"
    ;;
  ping)
    WAIT=""
    [[ "${1:-}" == "--wait" ]] && WAIT="--wait"
    cmd_trigger "ping" "$WAIT"
    ;;
  status)
    cmd_status "${1:-}"
    ;;
  log)
    cmd_log "${1:-}"
    ;;
  *)
    cat <<EOF
nova.sh — Jenkins Nova Deploy CLI

Usage:
  ./nova.sh list                      列出所有 job 及最近状态
  ./nova.sh deploy                    部署 Odoo18（不等待）
  ./nova.sh deploy --rolling          部署 Odoo18（滚动重启）
  ./nova.sh deploy --rolling --wait   滚动重启 + 等待完成
  ./nova.sh restart                   重启所有 App Server
  ./nova.sh restart --wait            重启 + 等待完成
  ./nova.sh ping                      Ping 连通性测试
  ./nova.sh ping --wait               Ping + 等待结果
  ./nova.sh status                    查看所有 job 状态
  ./nova.sh status <alias>            查看某 job 详细状态
  ./nova.sh log <alias>               查看最近 console log

Aliases:
  deploy          → Deploy Nova Code Odoo18 (NO WAIT)
  deploy-rolling  → Deploy Nova Code Odoo18 (ROLLING RESTART)
  restart         → Just Restart all app servers (NO WAIT)
  ping            → Odoo-DeployServers - PingTest

Override credentials:
  JENKINS_USER=xxx JENKINS_PASS=yyy ./nova.sh list
EOF
    ;;
esac
