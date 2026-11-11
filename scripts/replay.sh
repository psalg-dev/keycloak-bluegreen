#!/usr/bin/env bash
# replay.sh <from> <to> <from-db> <to-db> <limit-iso> [reverse]: re-apply onto <to> the writes of the lossy window that
# must not be lost. The source is <from>'s DATABASE compared with <to>'s, not an event log: what <from> committed is
# there, complete, whatever happened to its pods (the old source, the demo-replay listener's stdout lines, lost them
# to log rotation and to a pod dying between commit and println). Works before the switch (straight to <to>'s Service).
#   users     on <from>, not on <to>              -> recreate with the SAME id (else `sub` changes for that person),
#                                                    its federated links, realm roles and groups
#   sessions  on <to> from the copy, gone on <from> -> delete (a logout, or a revoked token: scripts/lib/kc.sh
#                                                    replay_session_diff has the exact rule and its guards)
# <limit-iso>: a moment after the copy point and before <to> took traffic (forward: right after the copy cut; reverse:
# the same moment, read from the `promoted` event). `reverse`: <to> is the old color, idle since the flip.
# Idempotent while <from> still holds the truth. NOT late: once <from> is idle its sessions expire on their idle
# timeout while they live on on <to>, and a forward run would then log those users out; it refuses after
# REPLAY_MAX_AGE seconds (default 1800; set it below the realm's SSO idle timeout).
# Auto-links (second federated link of an existing user) are NOT replayed: the next login on <to> redoes them.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="replay"
from=${1:?from} to=${2:?to} from_db=${3:?from-db} to_db=${4:?to-db} limit=${5:?limit-iso} reverse=0
[[ ${6:-} != reverse ]] || reverse=1
limit_s=$(date -u -d "$limit" +%s)
[[ $reverse == 1 || $(( $(date -u +%s) - limit_s )) -le ${REPLAY_MAX_AGE:-1800} ]] \
  || die "forward replay $(( $(date -u +%s) - limit_s )) s after the copy: $from's idle sessions may have expired, the diff would log their users out on $to"

# apply <what> <METHOD> <path>: 2xx = done, 404 = already gone on <to> (fine); anything else fails the replay
apply() {
  local code; code=$(admin_api "$2" "$3" -o /dev/null -w '%{http_code}' || true)
  [[ $code == 2?? || $code == 404 ]] || die "replay $1: $2 $3 -> HTTP ${code:-none}"
}
import_user() { # user line -> partialImport of that user with its original id (SKIP if the id or username exists)
  jq '{ifResourceExists: "SKIP", users: [{id: .userId, username, email, firstName, lastName, enabled, emailVerified,
       attributes, federatedIdentities, realmRoles, groups}]}' <<<"$1" \
    | admin_api POST /realms/demo/partialImport --data-binary @- >/dev/null || die "replay user $(jq -r .username <<<"$1")"
}
has_user() { [[ $(admin_api GET "/realms/demo/users/$1" -o /dev/null -w '%{http_code}' || true) == 200 ]]; }

d=$(mktemp -d)
trap 'admin_direct_stop; rm -rf "$d"' EXIT

# 1. Read <from>: its users <to> does not have, each with everything the import needs.
admin_direct_start "$from"
realm_id=$(admin_api GET /realms/demo | jq -r .id)
[[ $realm_id =~ ^[A-Za-z0-9-]+$ ]] || die "replay: realm id '$realm_id' is not safe to put into SQL"
# not service-account users: they belong to a client, and clients are not replayed (one created on the new color in a
# rollback hold would come back as a user without its client)
ids() { db_rows "$1" "select id from user_entity where realm_id = '$realm_id' and service_account_client_link is null" | sort; }
ids "$from_db" > "$d/from_ids"; ids "$to_db" > "$d/to_ids"
[[ -s $d/to_ids ]] || die "replay: no users of realm demo in $to_db: broken read"
: > "$d/users"
for id in $(comm -23 "$d/from_ids" "$d/to_ids"); do
  u=/realms/demo/users/$id
  jq -c -n --argjson u "$(admin_api GET "$u")" --argjson f "$(admin_api GET "$u/federated-identity")" \
    --argjson r "$(admin_api GET "$u/role-mappings/realm")" --argjson g "$(admin_api GET "$u/groups")" \
    '{userId: $u.id, username: $u.username, email: $u.email, firstName: $u.firstName, lastName: $u.lastName,
      enabled: $u.enabled, emailVerified: $u.emailVerified, attributes: ($u.attributes // {}), federatedIdentities: $f, realmRoles: [$r[].name], groups: [$g[].path]}' >> "$d/users"
done
admin_direct_stop

# 2. The session diff, from both databases.
us() { db_rows "$1" "select user_session_id || '|' || created_on from offline_user_session where realm_id = '$realm_id' and offline_flag = '0'"; }
cs() { db_rows "$1" "select user_session_id || '|' || client_id || '|' || timestamp from offline_client_session where offline_flag = '0'"; }
us "$to_db" > "$d/to_us"; us "$from_db" > "$d/from_us"; cs "$to_db" > "$d/to_cs"; cs "$from_db" > "$d/from_cs"
replay_session_diff "$d/to_us" "$d/from_us" "$d/to_cs" "$d/from_cs" "$limit_s" "$reverse" > "$d/gone"

# 3. Apply on <to>.
admin_direct_start "$to"
logouts=0 users=0 repaired=()
while read -r sid; do
  apply logout DELETE "/realms/demo/sessions/$sid"
  log "logout $sid"
  logouts=$((logouts + 1))
done < "$d/gone"
while read -r l; do
  id=$(jq -r .userId <<<"$l") u=$(jq -r .username <<<"$l")
  import_user "$l"
  # SKIP also skips silently when <to> already has that username under ANOTHER id: the person logged in on <to>
  # after the flip, before this replay, and <to> made a new user (laptop build #28, rollback). Created after the
  # limit, that duplicate is the race's: delete it and import the original, so the first-issued `sub` wins (the
  # duplicate's sessions die: a silent re-login). An older conflict is not ours to resolve: fail.
  if ! has_user "$id"; then
    dup=$(admin_api GET "/realms/demo/users?username=$u&exact=true" | jq -c '.[0] // empty')
    [[ -n $dup && $(jq -r .createdTimestamp <<<"$dup") -ge $((limit_s * 1000)) ]] \
      || die "replay user $u: id $id not on $to, and the username's user there predates the window: sub changed"
    log "repair $u: $to created it again ($(jq -r .id <<<"$dup")) after the flip; restoring the original id"
    apply repair DELETE "/realms/demo/users/$(jq -r .id <<<"$dup")"
    import_user "$l"
    has_user "$id" || die "replay user $u: repair failed"
    repaired+=("$u")
  fi
  log "user $u ($id)"
  users=$((users + 1))
done < "$d/users"
# The event carries running totals over the passes of one switch (gate and report take the max): a pass only sees
# what the passes before it left to do.
prev=$(jq -c --arg f "$from" --arg l "$limit" 'select(.event == "replay" and .from == $f and .limit == $l)' out/events.jsonl 2>/dev/null | tail -1)
logouts_t=$((logouts + $(jq -r '.logouts // 0' <<<"${prev:-{\}}"))) users_t=$((users + $(jq -r '.users // 0' <<<"${prev:-{\}}")))
event replay from="$from" to="$to" limit="$limit" logouts="$logouts_t" users="$users_t" repaired="${repaired[*]}"
log "replayed $from ($from_db) -> $to ($to_db): $logouts sessions ended, $users users, ${#repaired[@]} repaired${repaired:+ (${repaired[*]})}"
