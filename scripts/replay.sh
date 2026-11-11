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
import_user() { # one user line (a UserRepresentation with its original id) -> partialImport, SKIP if it exists
  jq '{ifResourceExists: "SKIP", users: [.]}' <<<"$1" \
    | admin_api POST /realms/demo/partialImport --data-binary @- >/dev/null || die "replay user $(jq -r .username <<<"$1")"
}
has_user() { [[ $(admin_api GET "/realms/demo/users/$1" -o /dev/null -w '%{http_code}' || true) == 200 ]]; }

d=$(mktemp -d)
trap 'admin_direct_stop; rm -rf "$d"' EXIT

# 1. Read both databases, ONE query each, side by side (a read is a second on Oracle: a sqlplus session through
#    kubectl exec; three per side in a row cost 6-7 s of the lossy window). Rows are tagged: U|id, S|sid|created_on,
#    C|sid|client|timestamp. Not service-account users: they belong to a client, and clients are not replayed (one
#    created on the new color in a rollback hold would come back as a user without its client).
admin_direct_start "$from"
# NOT in $(...): admin_api caches its token in ADMIN_TOKEN, and a command substitution is a subshell that forgets it,
# so every later call would fetch the client secret and a new token again (most of a call's ~0.2 s).
# ponytail: one token per color and pass; a pass longer than the token's lifespan dies on a 401 (fails closed, rerun).
admin_api GET /realms/demo > "$d/realm"
realm_id=$(jq -r .id "$d/realm")
[[ $realm_id =~ ^[A-Za-z0-9-]+$ ]] || die "replay: realm id '$realm_id' is not safe to put into SQL"
read_db() { # <db> <prefix>: -> <prefix>_ids, _us, _cs; dies on anything that is not a tagged row, or on no users
  db_rows "$1" "select 'U|' || id from user_entity where realm_id = '$realm_id' and service_account_client_link is null
    union all select 'S|' || user_session_id || '|' || created_on from offline_user_session where realm_id = '$realm_id' and offline_flag = '0'
    union all select 'C|' || user_session_id || '|' || client_id || '|' || timestamp from offline_client_session where offline_flag = '0'" > "$2"
  ! grep -qv '^[USC]|' "$2" || die "replay: unexpected output reading $1: $(grep -v '^[USC]|' "$2" | head -1)"
  sed -n 's/^U|//p' "$2" | sort > "$2_ids"; sed -n 's/^S|//p' "$2" > "$2_us"; sed -n 's/^C|//p' "$2" > "$2_cs"
  [[ -s $2_ids ]] || die "replay: no users of realm demo in $1: broken read"
}
read_db "$from_db" "$d/from" & p1=$!
read_db "$to_db" "$d/to" & p2=$!
wait "$p1" || die "replay: reading $from_db failed"
wait "$p2" || die "replay: reading $to_db failed"

# 2. <from>'s users <to> does not have, each with everything the import needs (8 at a time).
fetch_user() {
  local u=/realms/demo/users/$1
  jq -c -n --argjson u "$(admin_api GET "$u")" --argjson f "$(admin_api GET "$u/federated-identity")" \
    --argjson r "$(admin_api GET "$u/role-mappings/realm")" --argjson g "$(admin_api GET "$u/groups")" \
    '{id: $u.id, username: $u.username, email: $u.email, firstName: $u.firstName, lastName: $u.lastName,
      enabled: $u.enabled, emailVerified: $u.emailVerified, attributes: ($u.attributes // {}),
      federatedIdentities: $f, realmRoles: [$r[].name], groups: [$g[].path]}' > "$d/u.$1"
}
comm -23 "$d/from_ids" "$d/to_ids" > "$d/new"
pids=()
while read -r id; do
  fetch_user "$id" & pids+=($!)
  if ((${#pids[@]} == 8)); then wait "${pids[@]}" || true; pids=(); fi
done < "$d/new"
((${#pids[@]} == 0)) || wait "${pids[@]}" || true
: > "$d/users"
while read -r id; do # a failed fetch left no (or an empty) file: checked here, not through wait's one exit status
  [[ $(jq -r .id "$d/u.$id" 2>/dev/null) == "$id" ]] || die "replay: could not read user $id from $from"
  cat "$d/u.$id" >> "$d/users"
done < "$d/new"
admin_direct_stop

# 3. The session diff.
replay_session_diff "$d/to_us" "$d/from_us" "$d/to_cs" "$d/from_cs" "$limit_s" "$reverse" > "$d/gone"

# 4. Apply on <to>: the sessions, then the users, 200 per partialImport (one request per user cost ~0.2 s each).
admin_direct_start "$to"
admin_api GET /realms/demo > /dev/null # token for this color, kept (see above)
logouts=0 users=0 repaired=()
while read -r sid; do
  apply logout DELETE "/realms/demo/sessions/$sid"
  log "logout $sid"
  logouts=$((logouts + 1))
done < "$d/gone"
split -l 200 "$d/users" "$d/batch."
for b in "$d"/batch.*; do
  [[ -s $b ]] || continue
  jq -s '{ifResourceExists: "SKIP", users: .}' "$b" | admin_api POST /realms/demo/partialImport --data-binary @- > "$b.res" \
    || die "replay: partialImport of $(wc -l < "$b") users on $to failed"
  n=$(wc -l < "$b")
  [[ $(jq -r '(.added // 0) + (.skipped // 0)' "$b.res") -eq $n ]] || die "replay: partialImport on $to answered for fewer than the $n users sent"
  # SKIPPED = <to> already has that username under ANOTHER id (ids <to> has are not in the batch): the person logged
  # in on <to> after the flip, before this replay, and <to> made a new user (laptop build #28, rollback). Created
  # after the limit, that duplicate is the race's: delete it and import the original, so the first-issued `sub` wins
  # (the duplicate's sessions die: a silent re-login). An older conflict is not ours to resolve: fail.
  for u in $(jq -r '.results[]? | select(.action == "SKIPPED") | .resourceName' "$b.res"); do
    l=$(jq -c --arg u "$u" 'select(.username == $u)' "$b"); id=$(jq -r .id <<<"$l")
    dup=$(admin_api GET "/realms/demo/users?username=$u&exact=true" | jq -c '.[0] // empty')
    [[ -n $dup && $(jq -r .createdTimestamp <<<"$dup") -ge $((limit_s * 1000)) ]] \
      || die "replay user $u: id $id not on $to, and the username's user there predates the window: sub changed"
    log "repair $u: $to created it again ($(jq -r .id <<<"$dup")) after the flip; restoring the original id"
    apply repair DELETE "/realms/demo/users/$(jq -r .id <<<"$dup")"
    import_user "$l"
    has_user "$id" || die "replay user $u: repair failed"
    repaired+=("$u")
  done
  while read -r line; do log "$line"; done < <(jq -r '"user \(.username) (\(.id))"' "$b")
  users=$((users + n))
done
# The event carries running totals over the passes of one switch (gate and report take the max): a pass only sees
# what the passes before it left to do.
prev=$(jq -c --arg f "$from" --arg l "$limit" 'select(.event == "replay" and .from == $f and .limit == $l)' out/events.jsonl 2>/dev/null | tail -1)
logouts_t=$((logouts + $(jq -r '.logouts // 0' <<<"${prev:-{\}}"))) users_t=$((users + $(jq -r '.users // 0' <<<"${prev:-{\}}")))
event replay from="$from" to="$to" limit="$limit" logouts="$logouts_t" users="$users_t" repaired="${repaired[*]}"
log "replayed $from ($from_db) -> $to ($to_db): $logouts sessions ended, $users users, ${#repaired[@]} repaired${repaired:+ (${repaired[*]})}"
