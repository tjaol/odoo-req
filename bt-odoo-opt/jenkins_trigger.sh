#!/usr/bin/env bash
# ============================================================
# jenkins_trigger.sh — Remote Jenkins Job Trigger via Shell
# Usage:
#   ./jenkins_trigger.sh list
#   ./jenkins_trigger.sh trigger "Deploy Code On Nova (Ansible)" "Deploy Nova Code Odoo18 (NO WAIT)"
#   ./jenkins_trigger.sh trigger "Deploy Code On Nova (Ansible)" "Deploy Nova Code Odoo18 (NO WAIT)" --wait
#   ./jenkins_trigger.sh status "Deploy Code On Nova (Ansible)" "Deploy Nova Code Odoo18 (NO WAIT)"
# ============================================================

set -euo pipefail

JENKINS_URL="${JENKINS_URL:-https://barron.tg.co.th/jenkins}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-tQrGaBERMmA*#03}"
AUTH="$JENKINS_USER:$JENKINS_PASS"

# ── Helpers ────────────────────────────────────────────────────────────────────

jurl() {
  # Replace internal 192.168.x.x URLs with external proxy URL
  echo "$1" | sed "s|http://192\.168\.[0-9]*\.[0-9]*:[0-9]*/|$JENKINS_URL/|g"
}

get_crumb() {
  curl -sf --user "$AUTH" \
    "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" \
    2>/dev/null || echo ""
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

build_job_url() {
  local folder="$1"
  local job="$2"
  local f_enc
  local j_enc
  f_enc=$(urlencode "$folder")
  j_enc=$(urlencode "$job")
  echo "$JENKINS_URL/job/$f_enc/job/$j_enc"
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_list() {
  echo "Jenkins: $JENKINS_URL"
  echo ""
  # Top-level folders
  local folders
  folders=$(curl -sg --user "$AUTH" "$JENKINS_URL/api/json?tree=jobs[name,color]" \
    | python3 -c "import json,sys; [print(j['name']) for j in json.load(sys.stdin).get('jobs',[])]")

  while IFS= read -r folder; do
    echo "📁 $folder"
    f_enc=$(urlencode "$folder")
    curl -sg --user "$AUTH" "$JENKINS_URL/job/$f_enc/api/json?tree=jobs[name,color]" \
      | python3 -c "
import json,sys
for j in json.load(sys.stdin).get('jobs',[]):
    c = j.get('color','?')
    icon = '✅' if c == 'blue' else '🔴' if 'red' in c else '🔄' if 'anime' in c else '⚪'
    print(f'   {icon} {j[\"name\"]}')
"
    echo ""
  done <<< "$folders"
}

cmd_trigger() {
  local folder="${1:-}"
  local job="${2:-}"
  local wait_flag="${3:-}"

  [ -n "$folder" ] && [ -n "$job" ] || { echo "Usage: $0 trigger <folder> <job> [--wait]"; exit 1; }

  local job_url
  job_url=$(build_job_url "$folder" "$job")

  # Get CSRF crumb
  local crumb
  crumb=$(get_crumb)
  local crumb_header=()
  [ -n "$crumb" ] && crumb_header=(-H "$crumb")

  echo "🚀 Triggering: $folder / $job"
  echo "   URL: $job_url/build"

  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    --user "$AUTH" \
    "${crumb_header[@]}" \
    -X POST "$job_url/build")

  if [[ "$http_code" =~ ^(200|201|302)$ ]]; then
    echo "✅ Triggered successfully (HTTP $http_code)"
  else
    echo "❌ Trigger failed (HTTP $http_code)"
    exit 1
  fi

  # --wait: poll until done
  if [ "$wait_flag" = "--wait" ]; then
    echo ""
    echo "⏳ Waiting for build to complete..."
    sleep 3
    local attempt=0
    while true; do
      attempt=$((attempt + 1))
      local result
      result=$(curl -sf --user "$AUTH" "$job_url/lastBuild/api/json?tree=result,building,number,duration" \
        | python3 -c "
import json,sys
d = json.load(sys.stdin)
building = d.get('building', False)
result   = d.get('result', None)
num      = d.get('number', '?')
dur      = int(d.get('duration',0))//1000
print(f'building={building} result={result} num={num} dur={dur}s')
" 2>/dev/null || echo "building=True result=None num=? dur=0s")

      if echo "$result" | grep -q "building=False"; then
        local final
        final=$(echo "$result" | grep -o 'result=[^ ]*' | cut -d= -f2)
        local build_num
        build_num=$(echo "$result" | grep -o 'num=[^ ]*' | cut -d= -f2)
        local dur
        dur=$(echo "$result" | grep -o 'dur=[^ ]*' | cut -d= -f2)
        if [ "$final" = "SUCCESS" ]; then
          echo "✅ Build #$build_num SUCCESS ($dur)"
        else
          echo "❌ Build #$build_num $final ($dur)"
          exit 1
        fi
        break
      fi

      echo "   [attempt $attempt] Still running... ($result)"
      sleep 5
    done
  fi
}

cmd_status() {
  local folder="${1:-}"
  local job="${2:-}"
  [ -n "$folder" ] && [ -n "$job" ] || { echo "Usage: $0 status <folder> <job>"; exit 1; }

  local job_url
  job_url=$(build_job_url "$folder" "$job")

  echo "📊 Status: $folder / $job"
  curl -sf --user "$AUTH" "$job_url/lastBuild/api/json?tree=number,result,building,timestamp,duration,url" \
    | python3 -c "
import json,sys,datetime
d = json.load(sys.stdin)
ts = datetime.datetime.fromtimestamp(d['timestamp']//1000).strftime('%Y-%m-%d %H:%M:%S')
dur = int(d.get('duration',0))//1000
building = d.get('building', False)
result = d.get('result') or ('🔄 RUNNING' if building else '?')
icon = '✅' if result == 'SUCCESS' else '❌' if result in ('FAILURE','ABORTED') else '🔄'
print(f'  Build #: {d[\"number\"]}')
print(f'  Status : {icon} {result}')
print(f'  Started: {ts}')
print(f'  Duration: {dur}s')
"
}

# ── Main ───────────────────────────────────────────────────────────────────────

CMD="${1:-help}"
shift || true

case "$CMD" in
  list)    cmd_list ;;
  trigger) cmd_trigger "$@" ;;
  status)  cmd_status "$@" ;;
  *)
    echo "Usage:"
    echo "  $0 list"
    echo "  $0 trigger <folder> <job> [--wait]"
    echo "  $0 status  <folder> <job>"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 trigger 'Deploy Code On Nova (Ansible)' 'Odoo-DeployServers - PingTest'"
    echo "  $0 trigger 'Deploy Code On Nova (Ansible)' 'Deploy Nova Code Odoo18 (NO WAIT)' --wait"
    echo "  $0 status  'Ops-Console' 'Ops-Console-Health'"
    ;;
esac
