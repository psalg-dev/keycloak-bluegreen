#!/usr/bin/env bash
# purge-sessions.sh <color> <since-iso>: delete every user session <color> created at/after <since> (straight to its
# Service, before it takes traffic again). rollback.sh runs it on the old color: sessions born there after the copy
# point were already lost on the new color (their users logged in again there), so deleting them loses nothing new,
# and it closes the one hole the reverse replay cannot: a window session logged out on the new color, which never knew
# it (LOGOUT_ERROR session_expired, no replay line), came back to life after the rollback (laptop build #29).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="replay"
color=${1:?color} since=${2:?since-iso}
since_ms=$(( $(date -u -d "$since" +%s) * 1000 ))

admin_direct_start "$color"
trap admin_direct_stop EXIT
# sessions are listed per client; one session can show up under several clients
sids=$(for c in $(admin_api GET /realms/demo/clients | jq -r '.[].id'); do
  admin_api GET "/realms/demo/clients/$c/user-sessions?first=0&max=100000" | jq -r --argjson s "$since_ms" '.[] | select(.start >= $s) | .id'
done | sort -u)
n=0
for sid in $sids; do
  code=$(admin_api DELETE "/realms/demo/sessions/$sid" -o /dev/null -w '%{http_code}' || true)
  [[ $code == 2?? || $code == 404 ]] || die "purge session $sid on kc-$color: HTTP ${code:-none}"
  n=$((n + 1))
done
event purge color="$color" since="$since" sessions="$n"
log "purged $n sessions kc-$color created since $since"
