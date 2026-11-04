#!/usr/bin/env bash
# switch-lossy.sh <target_version>: the minor/major case. Old and new Keycloak versions cannot share a schema, so
# green gets its own copy. On Oracle the copy is a consistent Data Pump export of the active schema at a captured SCN,
# imported into a second schema while blue keeps serving logins/tokens ("lossy overlap"): sessions created on blue
# after the copy point are lost (users re-login silently via the legacy IdP's SSO); logouts and user creations from
# that window are replayed onto green. Only admin and the account console are frozen (503). Every step writes an event
# to out/events.jsonl for the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="deployment"
target=${1:?target_version}
active=$(state activeColor) src=$(state activeDb) from=$(state version)
idle=$([[ $active == blue ]] && echo green || echo blue)
new=kc$(( ${src#kc} + 1 ))
check_profile

# 1. Target schema + pre-built target image. Both before the freeze: only the copy point and the export/import
#    belong in the window. The Oracle instance stays up; this is a schema copy, not a database rebuild.
drop_db "$new" # a retry after a failed import must not import into a half-written target
create_db "$new"
build_image "$target" 1

# 2. Freeze only what must not be lost and isn't replayed: admin + account console.
freeze
trap 'unfreeze >/dev/null 2>&1 || true' ERR # a failed copy must not leave admin/account 503
event window_start

# 3. Copy point: the SCN the export reads. Blue keeps writing; logouts/creations after this time are replayed.
copy_iso=$(date -u -d "-5 seconds" +%FT%TZ) # replay window starts a bit early on purpose (idempotent)
copy_scn=$(sql_scalar "$src" "SELECT DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER FROM dual")
[[ -n $copy_scn ]] || die "could not read the current SCN from $src"
event copy_point scn="$copy_scn"

# 4. Consistent export at that SCN. expdp runs as SYSTEM (DBA) because a schema export with REMAP_SCHEMA later needs
#    the Data Pump roles; the KC1 app user never gets DBA rights. The password stays in a Secret and is read here.
src_schema=$(db_schema "$src") new_schema=$(db_schema "$new")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dump="kc_${stamp}_${src}_to_${new}.dmp" dplog="kc_${stamp}_${src}_to_${new}.log"
admin_pw=$(kubectl -n "$NS" get secret "$ORACLE_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)
oracle_pod_name=$(oracle_pod)
log "exporting $src_schema at SCN $copy_scn (blue keeps serving; admin/account frozen)"
kubectl -n "$NS" exec "$oracle_pod_name" -- expdp "system/$admin_pw@//localhost:1521/$DB_SERVICE" \
  "SCHEMAS=$src_schema" "FLASHBACK_SCN=$copy_scn" "DIRECTORY=KC_DUMP" "DUMPFILE=$dump" "LOGFILE=$dplog" \
  REUSE_DUMPFILES=YES >/dev/null || die "expdp $src_schema failed (see $dplog in the Oracle pod)"

# 5. Import into the empty target schema. This is the only long step; blue still serves login/token.
log "importing into $new_schema (REMAP_SCHEMA $src_schema:$new_schema)"
kubectl -n "$NS" exec "$oracle_pod_name" -- impdp "system/$admin_pw@//localhost:1521/$DB_SERVICE" \
  "SCHEMAS=$src_schema" "REMAP_SCHEMA=$src_schema:$new_schema" "DIRECTORY=KC_DUMP" "DUMPFILE=$dump" \
  "LOGFILE=$dplog" EXCLUDE=USER >/dev/null || die "impdp into $new_schema failed (see $dplog in the Oracle pod)"
event copy_ready db="$new" scn="$copy_scn"
event promoted db="$new" scn="$copy_scn" # gate: the lossy window really had a copy to lose sessions against

# 6. Green on its own schema: the new version migrates it. Same copy point; the changelog count proves migration ran.
before=$(sql_scalar "$new" "SELECT COUNT(*) FROM DATABASECHANGELOG")
deploy_color "$idle" "$target" "$new" 1
after=$(sql_scalar "$new" "SELECT COUNT(*) FROM DATABASECHANGELOG")
event migration db="$new" from="$from" to="$target" changesets_before="$before" changesets_after="$after"
scripts/check-cluster.sh "$idle"

# 7. Config on green's own schema before it takes traffic (maintenance stage only when asked).
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

# 11. Unfreeze. 12. KEEP_OLD=true: old color + old schema stay up for scripts/rollback.sh (it reverse-replays green's
#     logouts/creations and flips back). Otherwise the old color is scaled down; its schema stays as a last-resort copy.
unfreeze
trap - ERR
event window_end
if [[ ${KEEP_OLD:-false} == true ]]; then
  log "switched $active -> $idle ($src -> $new); kc-$active on schema $src kept running for rollback"; exit 0
fi
save_logs "$active"
kubectl -n "$NS" scale sts "kc-$active-keycloak" --replicas=0 >/dev/null
event drained color="$active"
log "switched $active -> $idle ($from -> $target, $src -> $new), changesets $before -> $after"
