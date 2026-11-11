# DB_ENGINE=postgres (the default): CloudNativePG. One CNPG cluster per database (pg-1, pg-2, ...); the lossy copy is
# a streaming replica cluster promoted at the copy point. Sourced by scripts/lib/kc.sh; the Oracle twin is oracle/db.sh.
# Both files define the same functions (the engine interface):
#   db_first, db_next <db>, db_build_opt, db_image_suffix, db_mem_need, db_platform_up, create_db <db>, delete_dbs,
#   db_helm_args <db> <kc_version> (sets DB_HELM_ARGS), db_verify <db>, db_changesets <db>,
#   db_copy_prepare <src> <new> (before the freeze), db_copy_cut <src> <new> (inside it: copy_point .. promoted events)
# and the texts demo.sh prints: DB_ENGINE_TEXT, DB_RESET_TEXT, DB_COPY_TEXT.
# shellcheck shell=bash
CNPG=1.30.1
# PG_INSTANCES 2 on the laptop, not 1: same templates and the same promote/restart path as default (only the count
# differs), sync replication (ANY 1) kept; 1 instance needs the synchronous block removed (no standby to ack) for
# ~340 MiB less per cluster. Cost of 2: a standby restart stalls commits (dataDurability).
case $PROFILE in default) PG_INSTANCES=3 ;; laptop) PG_INSTANCES=2 ;; esac

# shellcheck disable=SC2034 # read by scripts/demo.sh
DB_ENGINE_TEXT="Postgres (CloudNativePG, $PG_INSTANCES instances per DB)"
# shellcheck disable=SC2034
DB_RESET_TEXT="every DB; wait until CNPG has really cleaned up, then create a fresh pg-1"
# shellcheck disable=SC2034
DB_COPY_TEXT="Green's own DB = streaming replica of the active one; freeze admin/account only; copy point; promote"

db_first() { echo pg-1; }
db_next() { echo "pg-$((${1#pg-} + 1))"; }
db_build_opt() { echo "--db=postgres"; }
db_image_suffix() { :; }
# Docker VM GiB the profile peaks at, MEASURED (default 14.0 with Jenkins on 2026-11-11, 14.8 on 2026-11-03; laptop 9.1)
db_mem_need() { if [[ $PROFILE == laptop ]]; then echo 9; else echo 15; fi; }
db_preflight() { :; }

db_platform_up() {
  kubectl apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG/cnpg-$CNPG.yaml" >/dev/null
  kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s >/dev/null
  log "cnpg ready"
}

# psql_db <db-cluster> <sql> [database]: run SQL on the cluster's current primary as postgres
psql_db() {
  local pod; pod=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$1" -o jsonpath='{.status.currentPrimary}')
  kubectl -n "$NS" exec "$pod" -c postgres -- psql -U postgres -d "${3:-postgres}" -Atc "$2"
}

# create_db <name>: CNPG cluster, waits until Ready (no-op when it exists)
create_db() {
  local TAG=database
  check_profile
  if kubectl -n "$NS" get cluster.postgresql.cnpg.io "$1" >/dev/null 2>&1; then log "db $1 already exists"; return; fi
  log "creating db $1 ($PG_INSTANCES instances, sync replication) and waiting for Ready"
  DB=$1 NS=$NS PG_INSTANCES=$PG_INSTANCES envsubst < k8s/postgres/pg.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$1" --for=condition=Ready --timeout=600s >/dev/null
  log "db $1 ready"
}

# delete_dbs: delete every CNPG cluster AND wait until their children (pods, PVCs, secrets) are gone. Recreating a
# cluster under the same name while the old pods still terminate makes CNPG count them, mark the new cluster
# initialized, then find no PVCs -> "unrecoverable" (2026-11-02; `delete --wait` returns before GC is done).
delete_dbs() {
  local TAG=database
  # Teardown only: skip Postgres' smart shutdown (CNPG default: wait up to 180 s for sessions to end before a fast
  # shutdown). It protects in-flight transactions in real operations; here the data is being thrown away.
  local c; for c in $(kubectl -n "$NS" get cluster.postgresql.cnpg.io -o name); do
    kubectl -n "$NS" patch "$c" --type merge -p '{"spec":{"smartShutdownTimeout":1}}' >/dev/null
  done
  kubectl -n "$NS" delete cluster.postgresql.cnpg.io --all --cascade=foreground --wait --timeout=600s >/dev/null
  local _; for _ in $(seq 150); do
    [[ -z $(kubectl -n "$NS" get pod,pvc,secret -l cnpg.io/cluster -o name) ]] && return
    sleep 2
  done
  die "old CNPG pods/PVCs/secrets still present"
}

db_helm_args() { DB_HELM_ARGS=(--set "externalDatabase.host=$1-rw" --set "externalDatabase.existingSecret=$1-app"); }
db_verify() { :; } # ponytail: Postgres has no wrong-schema failure mode here (one database per cluster)
db_changesets() { psql_db "$1" "select count(*) from databasechangelog" keycloak; }

# db_copy_prepare <src> <new>: green's DB as a streaming replica of the active one. Before the freeze: the base backup
# is the long part and blue loses nothing while it runs.
db_copy_prepare() {
  check_profile # before the replica DB takes PG_INSTANCES
  DB=$2 SRC=$1 NS=$NS PG_INSTANCES=$PG_INSTANCES envsubst < k8s/postgres/pg-replica.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$2" --for=condition=Ready --timeout=900s >/dev/null
  event replica_ready db="$2" source="$1"
}

# db_copy_cut <src> <new>: copy point, wait until the replica has replayed it, promote.
db_copy_cut() {
  local src=$1 new=$2 lsn replay promote_at
  # Copy point: everything the primary had at this LSN is in green's DB (equality never holds: blue keeps writing).
  lsn=$(psql_db "$src" "select pg_current_wal_lsn()")
  event copy_point lsn="$lsn"
  for _ in $(seq 120); do
    [[ $(psql_db "$new" "select pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn") == t ]] && break; sleep 1
  done
  # measured on the replica just before the promote: the gate's db_copy_matches_source reads these two fields
  # left(..., 1): a boolean concatenated to text is 'true'/'false', not psql's t/f (first live run died here, caught up)
  replay=$(psql_db "$new" "select pg_last_wal_replay_lsn() || ' ' || left((pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn)::text, 1)")
  [[ ${replay#* } == t ]] || die "$new never caught up to $lsn (replayed ${replay% *})"

  # Promote. From here blue's writes reach only $src (lost unless replayed).
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
  event promoted db="$new" lsn="$lsn" replay_lsn="${replay% *}" caught_up="${replay#* }"
  # Same credentials (physical copy).
  kubectl -n "$NS" get secret "$src-app" -o json | jq --arg n "$new-app" '{apiVersion, kind, type, data, metadata: {name: $n}}' \
    | kubectl -n "$NS" apply -f - >/dev/null
}
