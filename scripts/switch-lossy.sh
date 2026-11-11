#!/usr/bin/env bash
# switch-lossy.sh <target_version>: the minor/major case. Old and new Keycloak versions cannot share a DB, so green
# gets its own copy, taken at a copy point by the engine (Postgres: CNPG replica promoted there; Oracle: Data Pump
# export at an SCN into a second schema). Blue keeps serving login/token the whole time ("lossy overlap"): sessions
# created on blue after the copy point are lost (users re-login silently via the legacy IdP's SSO); logouts and user
# creations from that window are replayed onto green. Only admin and the account console are frozen (503). Every step
# writes an event to out/events.jsonl for the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="deployment"
target=${1:?target_version}
active=$(state activeColor) src=$(state activeDb) from=$(state version)
idle=$([[ $active == blue ]] && echo green || echo blue)
new=$(db_next "$src")
check_profile

# 1. Whatever of green's DB can be made before the freeze (Postgres: the whole replica; Oracle: the empty schema), and
#    the target image: only the copy point and what must follow it belong in the window.
db_copy_prepare "$src" "$new"
build_image "$target" 1

# 2. Freeze only what must not be lost and isn't replayed: admin + account console.
freeze
# EXIT, not ERR: `die` exits without raising ERR, so a `die` in the copy step below left the paths
# frozen; and ERR stays kc.sh's trap, which logs the failing command.
trap 'unfreeze >/dev/null 2>&1 || true' EXIT # a failed copy must not leave admin/account 503
event window_start

# 3-5. Copy point .. green's DB is a writable copy of it (events copy_point, promoted). Blue keeps writing;
#      logouts/creations after this time are replayed.
copy_iso=$(date -u -d "-5 seconds" +%FT%TZ) # replay window starts a bit early on purpose (idempotent)
db_copy_cut "$src" "$new"

# 6. Green on its own DB: the new version migrates it. The changelog count proves the migration ran.
before=$(db_changesets "$new")
deploy_color "$idle" "$target" "$new" 1
after=$(db_changesets "$new")
event migration db="$new" from="$from" to="$target" changesets_before="$before" changesets_after="$after"
scripts/check-cluster.sh "$idle"

# 7. Config on green's own DB before it takes traffic (maintenance stage only when asked).
scripts/config.sh online "$idle"
[[ ${RUN_MAINTENANCE:-false} =~ ^(true|1)$ ]] && scripts/config.sh maintenance "$idle"

# 8-10. Replay, switch, replay at once, drain, replay again (catches what blue wrote during the drain).
scripts/replay.sh "$active" "$idle" "$copy_iso"
event switch from="$active" to="$idle"
set_active "$idle" "$new" "$target"
event flipped to="$idle" # ingress-nginx routes to the new color now (set_active waits for it; gate: acrossflip)
# right away: users the old color created since the first replay, before the person logs in on the new color and it
# makes a duplicate (replay.sh repairs any that slip through); the post-drain replay below catches in-flight stragglers
scripts/replay.sh "$active" "$idle" "$copy_iso"
sleep "${DRAIN_SECONDS:-15}"
scripts/replay.sh "$active" "$idle" "$copy_iso"
event replay_done

# 11. Unfreeze. 12. KEEP_OLD=true: old color + old DB stay up for scripts/rollback.sh (it reverse-replays green's
#     logouts/creations and flips back). Otherwise the old color is scaled down; its DB stays as a last-resort copy.
unfreeze
trap - EXIT
event window_end
if [[ ${KEEP_OLD:-false} == true ]]; then
  log "switched $active -> $idle ($src -> $new); kc-$active on $src kept running for rollback"; exit 0
fi
save_logs "$active"
kubectl -n "$NS" scale sts "kc-$active-keycloak" --replicas=0 >/dev/null
event drained color="$active"
log "switched $active -> $idle ($from -> $target, $src -> $new), changesets $before -> $after"
