#!/usr/bin/env bash
# replay.sh <from> <to> <since-iso>: re-apply the writes from the lossy window that must not be lost, read from the
# demo-replay event listener's stdout lines on every <from> pod, onto <to> (straight to its Service, so it works
# before the switch). Idempotent: run it twice, and start the window early on purpose.
#   LOGOUT       -> delete that session (404 = it never reached <to>'s DB: fine)
#   REGISTER     -> recreate the brokered user with the SAME id (else `sub` changes for that person)
#   REVOKE_GRANT -> 26: delete that session; 25 (no sessionId): log the user out everywhere (conservative superset)
# Auto-links (second federated link of an existing user) are NOT replayed: the next login on <to> redoes them.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
from=${1:?from} to=${2:?to} since=${3:?since}

lines=$(mktemp)
for p in $(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=kc-$from" -o name); do
  restarted=$(kubectl -n "$NS" get "$p" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.finishedAt}')
  [[ -z $restarted || $restarted < "$since" ]] || die "$p restarted at $restarted, inside the window: its replay lines are gone"
  kubectl -n "$NS" logs "$p" -c keycloak --since-time="$since" | grep '^{"replay":true' >> "$lines" || true
done

admin_direct_start "$to"
trap admin_direct_stop EXIT
realm_id=$(admin_api GET /realms/demo | jq -r .id)
logouts=0 users=0 revokes=0
while read -r l; do
  [[ $(jq -r .realmId <<<"$l") == "$realm_id" ]] || continue
  case $(jq -r .type <<<"$l") in
    LOGOUT)
      admin_api DELETE "/realms/demo/sessions/$(jq -r .sessionId <<<"$l")" >/dev/null || true
      logouts=$((logouts + 1)) ;;
    REGISTER)
      jq '{ifResourceExists: "SKIP", users: [{id: .userId, username, email, enabled: true, emailVerified: true,
           attributes, federatedIdentities}]}' <<<"$l" \
        | admin_api POST /realms/demo/partialImport --data-binary @- >/dev/null || die "replay user $(jq -r .username <<<"$l")"
      users=$((users + 1)) ;;
    REVOKE_GRANT)
      sid=$(jq -r '.sessionId // empty' <<<"$l")
      if [[ -n $sid ]]; then admin_api DELETE "/realms/demo/sessions/$sid" >/dev/null || true
      else admin_api POST "/realms/demo/users/$(jq -r .userId <<<"$l")/logout" >/dev/null || true; fi
      revokes=$((revokes + 1)) ;;
  esac
done < "$lines"
event replay from="$from" to="$to" since="$since" logouts="$logouts" users="$users" revokes="$revokes"
log "replayed $from -> $to since $since: $logouts logouts, $users users, $revokes revokes"
