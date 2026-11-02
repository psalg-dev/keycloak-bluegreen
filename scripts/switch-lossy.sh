#!/usr/bin/env bash
# switch-lossy.sh <target_version>: the minor/major case. Old and new Keycloak versions cannot share a DB, so green
# gets its own copy (CNPG replica of the active DB, promoted at the copy point). Blue keeps serving login/token the
# whole time ("lossy overlap"): sessions created on blue after the copy point are lost (users re-login silently via
# the legacy IdP's SSO); logouts and user creations from that window are replayed onto green. Only admin and the
# account console are frozen (503). Every step writes an event to out/events.jsonl for the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
target=${1:?target_version}
active=$(state activeColor) src=$(state activeDb) from=$(state version)
idle=$([[ $active == blue ]] && echo green || echo blue)
new=pg-$(( ${src#pg-} + 1 ))
frozen=(/keycloak/admin /keycloak/realms/demo/account /keycloak/realms/master/account)

# 1. Green's DB: a streaming replica of the active one. 2. Target image ready (keeps the window short).
DB=$new SRC=$src envsubst < k8s/postgres/pg-replica.yaml.tpl | kubectl apply -f - >/dev/null
kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$new" --for=condition=Ready --timeout=900s >/dev/null
event replica_ready db="$new" source="$src"
build_image "$target" 1

# 3. Freeze only what must not be lost and isn't replayed: admin + account console.
freeze "${frozen[@]}"
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
kubectl -n "$NS" patch "cluster.postgresql.cnpg.io/$new" --type merge -p '{"spec":{"replica":{"enabled":false}}}' >/dev/null
for _ in $(seq 120); do [[ $(psql_db "$new" "select pg_is_in_recovery()" 2>/dev/null) == f ]] && break; sleep 1; done
[[ $(psql_db "$new" "select pg_is_in_recovery()") == f ]] || die "$new not promoted"
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

# 11. Unfreeze. 12. Old color + old DB stay for rollback (set_active back loses green's writes since the copy point).
unfreeze
event window_end
sleep "${ROLLBACK_HOLD:-0}"
kubectl -n "$NS" scale sts "kc-$active-keycloak" --replicas=0 >/dev/null
event drained color="$active"
log "switched $active -> $idle ($from -> $target, $src -> $new), changesets $before -> $after"
