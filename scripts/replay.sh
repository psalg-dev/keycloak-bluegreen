#!/usr/bin/env bash
# replay.sh <from> <to> <since-iso>: re-apply the writes from the lossy window that must not be lost, read from the
# demo-replay event listener's stdout lines on every <from> pod, onto <to> (straight to its Service, so it works
# before the switch). Idempotent: run it twice, and start the window early on purpose.
#   LOGOUT       -> delete that session (404 = it never reached <to>'s DB: fine)
#   REGISTER     -> recreate the brokered user with the SAME id (else `sub` changes for that person), with the realm
#                   roles and groups it was granted at creation (lines of an older provider jar carry none: `// []`)
#   REVOKE_GRANT -> 26: delete that session; 25 (no sessionId): log the user out everywhere (conservative superset)
# Auto-links (second federated link of an existing user) are NOT replayed: the next login on <to> redoes them.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="replay"
from=${1:?from} to=${2:?to} since=${3:?since}

lines=$(mktemp)
for p in $(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=kc-$from" -o name); do
  # Lines are lost if the container restarted in the window (logs of the old container) OR the pod itself was
  # deleted and recreated in the window (a fresh pod has an empty lastState, so the restart check can't see it).
  restarted=$(kubectl -n "$NS" get "$p" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.finishedAt}')
  created=$(kubectl -n "$NS" get "$p" -o jsonpath='{.metadata.creationTimestamp}')
  [[ -z $restarted || $restarted < "$since" ]] || die "$p restarted at $restarted, inside the window: its replay lines are gone"
  [[ $created < "$since" ]] || die "$p was (re)created at $created, inside the window: a predecessor's replay lines may be gone"
  kubectl -n "$NS" logs "$p" -c keycloak --since-time="$since" | grep '^{"replay":true' >> "$lines" || true
done

# apply <what> <METHOD> <path>: 2xx = done, 404 = it never reached <to>'s DB (fine); anything else fails the replay
# (it used to be `|| true`, which counted a 401/5xx as replayed)
apply() {
  local code; code=$(admin_api "$2" "$3" -o /dev/null -w '%{http_code}' || true)
  [[ $code == 2?? || $code == 404 ]] || die "replay $1: $2 $3 -> HTTP ${code:-none}"
}

import_user() { # replay line -> partialImport of that user with its original id (SKIP if the id or username exists)
  jq '{ifResourceExists: "SKIP", users: [{id: .userId, username, email, firstName, lastName, enabled: true, emailVerified: true,
       attributes, federatedIdentities, realmRoles: (.realmRoles // []), groups: (.groups // [])}]}' <<<"$1" \
    | admin_api POST /realms/demo/partialImport --data-binary @- >/dev/null || die "replay user $(jq -r .username <<<"$1")"
}
has_user() { [[ $(admin_api GET "/realms/demo/users/$1" -o /dev/null -w '%{http_code}' || true) == 200 ]]; }
# gone_on_from <id>: 404 for that user on <from>; anything but 200/404 fails (an error must not read as "gone").
# ponytail: re-points the one port-forward at <from> and back; only on the username-conflict path, which is rare.
gone_on_from() {
  local code
  admin_direct_stop; admin_direct_start "$from"
  code=$(admin_api GET "/realms/demo/users/$1" -o /dev/null -w '%{http_code}' || true)
  admin_direct_stop; admin_direct_start "$to"
  [[ $code == 200 || $code == 404 ]] || die "replay: GET user $1 on $from -> HTTP ${code:-none}"
  [[ $code == 404 ]]
}
since_ms=$(( $(date -u -d "$since" +%s) * 1000 ))
repaired=()

admin_direct_start "$to"
trap admin_direct_stop EXIT
realm_id=$(admin_api GET /realms/demo | jq -r .id)
logouts=0 users=0 revokes=0
while read -r l; do
  [[ $(jq -r .realmId <<<"$l") == "$realm_id" ]] || continue
  case $(jq -r .type <<<"$l") in
    LOGOUT)
      sid=$(jq -r '.sessionId // empty' <<<"$l")
      [[ -n $sid ]] || die "replay: LOGOUT without sessionId (user $(jq -r .userId <<<"$l")): would 404 and be counted as done"
      apply logout DELETE "/realms/demo/sessions/$sid"
      logouts=$((logouts + 1)) ;;
    REGISTER)
      import_user "$l"
      # SKIP also skips silently when <to> already has that username under ANOTHER id: the person logged in on <to>
      # after the flip, before this replay, and <to> made a new user (laptop build #28, rollback). Inside the window that
      # duplicate is the race's: delete it and import the original, so the first-issued `sub` wins (the duplicate's
      # sessions die: a silent re-login). An older conflict is not ours to resolve: fail.
      if ! has_user "$(jq -r .userId <<<"$l")"; then
        u=$(jq -r .username <<<"$l")
        dup=$(admin_api GET "/realms/demo/users?username=$u&exact=true" | jq -c '.[0] // empty')
        # The line's user may no longer exist on <from>: it was the duplicate an earlier replay ONTO <from> deleted
        # (repair below), and <to> holds the original. Replaying it would fail here or, worse, "repair" the original
        # away (Oracle minor-rollback 2026-11-11: forward repair of user4634, then the rollback died on its line).
        if [[ -n $dup ]] && gone_on_from "$(jq -r .userId <<<"$l")"; then
          log "skip $u: $(jq -r .userId <<<"$l") no longer exists on $from (a repaired duplicate)"; continue
        fi
        [[ -n $dup && $(jq -r .createdTimestamp <<<"$dup") -ge $since_ms ]] \
          || die "replay user $u: id $(jq -r .userId <<<"$l") not on $to, and the username's user there predates the window: sub changed"
        log "repair $u: $to created it again ($(jq -r .id <<<"$dup")) after the flip; restoring the original id"
        apply repair DELETE "/realms/demo/users/$(jq -r .id <<<"$dup")"
        import_user "$l"
        has_user "$(jq -r .userId <<<"$l")" || die "replay user $u: repair failed"
        repaired+=("$u")
      fi
      users=$((users + 1)) ;;
    REVOKE_GRANT)
      sid=$(jq -r '.sessionId // empty' <<<"$l")
      if [[ -n $sid ]]; then apply revoke DELETE "/realms/demo/sessions/$sid"
      else apply revoke POST "/realms/demo/users/$(jq -r .userId <<<"$l")/logout"; fi
      revokes=$((revokes + 1)) ;;
  esac
done < "$lines"
event replay from="$from" to="$to" since="$since" logouts="$logouts" users="$users" revokes="$revokes" \
  repaired="${repaired[*]}"
log "replayed $from -> $to since $since: $logouts logouts, $users users, $revokes revokes, ${#repaired[@]} repaired${repaired:+ (${repaired[*]})}"
