#!/usr/bin/env bash
# switch-lossy.sh <target_version>: the minor/major case. Old and new Keycloak versions cannot share a DB, so green
# gets its own copy (CNPG replica of the active DB, promoted at the copy point). Blue keeps serving login/token the
# whole time ("lossy overlap"): sessions created on blue after the copy point are lost (users re-login silently via
# the legacy IdP's SSO); logouts and user creations from that window are replayed onto green. Only admin and the
# account console are frozen (503). Every step writes an event to out/events.jsonl for the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="deployment"
target=${1:?target_version}
active=$(state activeColor) src=$(state activeDb) from=$(state version)
idle=$([[ $active == blue ]] && echo green || echo blue)
new=pg-$(( ${src#pg-} + 1 ))

# 1. Green's DB: a streaming replica of the active one. 2. Target image ready (keeps the window short).
DB=$new SRC=$src NS=$NS envsubst < k8s/postgres/pg-replica.yaml.tpl | kubectl apply -f - >/dev/null
kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$new" --for=condition=Ready --timeout=900s >/dev/null
event replica_ready db="$new" source="$src"
build_image "$target" 1

# 3. Freeze only what must not be lost and isn't replayed: admin + account console.
freeze
event window_start

# 4. Copy point: everything the primary had at this LSN is in green's DB (equality never holds: blue keeps writing).
lsn=$(psql_db "$src" "select pg_current_wal_lsn()")
event copy_point lsn="$lsn"
copy_iso=$(date -u -d "-5 seconds" +%FT%TZ) # replay window starts a bit early on purpose (idempotent)
for _ in $(seq 120); do
  [[ $(psql_db "$new" "select pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn") == t ]] && break; sleep 1
done
[[ $(psql_db "$new" "select pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn") == t ]] || die "$new never caught up to $lsn"

# 5. Promote. From here blue's writes reach only pg-$src (lost unless replayed).
promote_at=$(date -u +%FT%TZ)
kubectl -n "$NS" patch "cluster.postgresql.cnpg.io/$new" --type merge -p '{"spec":{"replica":{"enabled":false}}}' >/dev/null
for _ in $(seq 120); do [[ $(psql_db "$new" "select pg_is_in_recovery()" 2>/dev/null) == f ]] && break; sleep 1; done
[[ $(psql_db "$new" "select pg_is_in_recovery()") == f ]] || die "$new not promoted"
# The promote changes archive_mode (restart-only), so CNPG then restarts every instance, the primary last with a smart
# shutdown that waits for clients. Green must not connect before that is over (build #10: migrated into it, psql died).
# ponytail: relies on CNPG always flipping Ready after a promote; if a version stops doing that this waits the full 600 s.
ready_after() { kubectl -n "$NS" get "cluster.postgresql.cnpg.io/$new" -o json | jq -e --arg t "$promote_at" \
  '.status.conditions[] | select(.type == "Ready" and .status == "True" and .lastTransitionTime >= $t)' >/dev/null; }
for _ in $(seq 300); do ready_after && break; sleep 2; done
ready_after || die "$new not Ready again after the promote's restart"
event promoted db="$new"

# 6. Green on its own DB: the new version migrates the schema on first start. Same credentials (physical copy).
kubectl -n "$NS" get secret "$src-app" -o json | jq --arg n "$new-app" '{apiVersion, kind, type, data, metadata: {name: $n}}' \
  | kubectl -n "$NS" apply -f - >/dev/null
before=$(psql_db "$new" "select count(*) from databasechangelog" keycloak)
deploy_color "$idle" "$target" "$new" 1
after=$(psql_db "$new" "select count(*) from databasechangelog" keycloak)
event migration db="$new" from="$from" to="$target" changesets_before="$before" changesets_after="$after"
scripts/check-cluster.sh "$idle"

# 7. Config on green's own DB before it takes traffic (maintenance stage only when asked).
scripts/config.sh online "$idle"
[[ ${RUN_MAINTENANCE:-false} =~ ^(true|1)$ ]] && scripts/config.sh maintenance "$idle"

# 8-10. Replay, switch, drain, replay again (catches what blue wrote during the drain).
scripts/replay.sh "$active" "$idle" "$copy_iso"
event switch from="$active" to="$idle"
set_active "$idle" "$new" "$target"
sleep "${DRAIN_SECONDS:-15}"
scripts/replay.sh "$active" "$idle" "$copy_iso"
event replay_done

# 11. Unfreeze. 12. KEEP_OLD=true: old color + old DB stay up for scripts/rollback.sh (it reverse-replays green's
#     logouts/creations and flips back). Otherwise the old color is scaled down; its DB stays as a last-resort copy.
unfreeze
event window_end
if [[ ${KEEP_OLD:-false} == true ]]; then
  log "switched $active -> $idle ($src -> $new); kc-$active on $src kept running for rollback"; exit 0
fi
save_logs "$active"
kubectl -n "$NS" scale sts "kc-$active-keycloak" --replicas=0 >/dev/null
event drained color="$active"
log "switched $active -> $idle ($from -> $target, $src -> $new), changesets $before -> $after"
