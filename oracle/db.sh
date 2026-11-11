# DB_ENGINE=oracle: one Oracle instance; the blue/green "databases" are two schemas (KC1, KC2) in one PDB and
# Keycloak's db-schema selects which one a color uses. The lossy copy is a Data Pump export at an SCN, imported into
# the other schema. Sourced by scripts/lib/kc.sh instead of scripts/lib/db-postgres.sh (which lists the interface).
# One instance makes reset a schema drop, not a database rebuild. 19c production shape (Data Guard / RAC / separate
# CDBs) is in oracle/README.md; the zero-downtime mechanism does not depend on it.
# shellcheck shell=bash
DB_HOST=${DB_HOST:-oracle}
DB_SERVICE=${DB_SERVICE:-FREEPDB1}
ORACLE_IMAGE=${ORACLE_IMAGE:-mohammedesafi/oracle-database:19.3.0-ee} # community 19.3 EE; gvenzl Free alternative: gvenzl/oracle-free:23.26.3-slim
ORACLE_PULL_SECRET=${ORACLE_PULL_SECRET:-}
ORACLE_PULL_SECRET_FILE=${ORACLE_PULL_SECRET_FILE:-} # docker config.json; db_platform_up turns it into the k8s secret
ORACLE_ADMIN_SECRET=${ORACLE_ADMIN_SECRET:-oracle-admin}
ORACLE_DUMP_DIR=${ORACLE_DUMP_DIR:-/opt/oracle/oradata/dpdump}
ORACLE_STORAGE=${ORACLE_STORAGE:-20Gi}
ORACLE_SGA_MB=${ORACLE_SGA_MB:-1024}
ORACLE_PGA_MB=${ORACLE_PGA_MB:-512}
ORACLE_CPUS=${ORACLE_CPUS:-1}
# gvenzl Free needs 4 GiB in-cluster (1 GiB /dev/shm + 3.0 GiB first-start extraction); the 19.3 DBCA run used 6 GiB.
if [[ $ORACLE_IMAGE == *oracle-free* ]]; then
  ORACLE_SID=${ORACLE_SID:-FREE} ORACLE_MEMORY=${ORACLE_MEMORY:-4Gi}
else
  ORACLE_SID=${ORACLE_SID:-ORCLCDB} ORACLE_MEMORY=${ORACLE_MEMORY:-6Gi}
fi

# shellcheck disable=SC2034 # read by scripts/demo.sh
DB_ENGINE_TEXT="Oracle (${ORACLE_IMAGE##*/}, one instance, one schema per DB)"
# shellcheck disable=SC2034
DB_RESET_TEXT="every DB schema (the Oracle instance stays up), then create a fresh kc1"
# shellcheck disable=SC2034
DB_COPY_TEXT="Green's own schema = a Data Pump copy of the active one; freeze admin/account only; copy point (SCN); export at that SCN; import into the new schema; row counts checked against the source AS OF the SCN"

db_first() { echo kc1; }
db_next() { echo "kc$((${1#kc} + 1))"; }
db_build_opt() { echo "--db=oracle"; }
db_image_suffix() { echo "-ora"; }
# ESTIMATES, not measurements, until an Oracle run with scripts/mem-sample.sh says otherwise (README Results).
db_mem_need() { if [[ $PROFILE == laptop ]]; then echo 13; else echo 15; fi; }
# db_preflight: prints one line per problem this engine has with the machine/profile (preflight.sh fails on any)
db_preflight() {
  [[ $PROFILE != laptop || $ORACLE_IMAGE == *oracle-free* ]] \
    || echo "PROFILE=laptop is sized for the gvenzl Free image (4 GiB), not $ORACLE_IMAGE: set ORACLE_IMAGE=gvenzl/oracle-free:23.26.3-slim (oracle/README.md) or use the default profile"
}

# db_schema <name>: the demo's logical DB names are kc1/kc2; Oracle schemas are upper-case.
db_schema() {
  [[ $1 =~ ^kc[0-9]+$ ]] || die "invalid db name '$1' (expected kc<number>)"
  printf '%s' "${1^^}"
}

# oracle_pod: the one Oracle StatefulSet pod (oracle/oracle.yaml.tpl)
oracle_pod() {
  kubectl -n "$NS" get pod -l app=oracle -o jsonpath='{.items[0].metadata.name}'
}

oracle_ready() {
  kubectl -n "$NS" rollout status statefulset/oracle --timeout=1800s >/dev/null
  local pod n; pod=$(oracle_pod)
  [[ -n $pod ]] || die "oracle: no pod after rollout"
  kubectl -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=1800s >/dev/null
  # A plain `sqlplus / as sysdba` succeeds while DBCA is still building the database (and the listener is already up),
  # so the pod can be Ready before the PDB exists. Wait for the PDB itself before creating schemas.
  for _ in $(seq 360); do
    n=$(sql_root "SELECT COUNT(*) FROM V\$PDBS WHERE NAME = '$DB_SERVICE' AND OPEN_MODE = 'READ WRITE';" \
      | tr -d '\r' | awk 'NF == 1 && $1 ~ /^[0-9]+$/ { v = $1 } END { print v }')
    [[ ${n:-0} -gt 0 ]] && return 0
    sleep 5
  done
  die "oracle: PDB $DB_SERVICE did not open read-write within 30 min"
}

# db_platform_up: the Oracle StatefulSet + its bootstrap script, waits until the PDB is open (first start creates the
# database: minutes on Free, 15-20 min on 19.3).
db_platform_up() {
  ensure_secret "$ORACLE_ADMIN_SECRET" password 12
  kubectl -n "$NS" create configmap oracle-bootstrap --from-file=oracle/bootstrap.sh --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  if [[ -n $ORACLE_PULL_SECRET && -n $ORACLE_PULL_SECRET_FILE ]]; then
    kubectl -n "$NS" create secret generic "$ORACLE_PULL_SECRET" \
      --from-file=.dockerconfigjson="$ORACLE_PULL_SECRET_FILE" --type=kubernetes.io/dockerconfigjson \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  # envsubst takes only the template's inputs: an unrestricted call would eat Oracle's V$PDBS in the probe SQL.
  # shellcheck disable=SC2016 # the single-quoted list is envsubst's variable whitelist, not a shell expansion
  NS=$NS DB_SERVICE=$DB_SERVICE ORACLE_IMAGE=$ORACLE_IMAGE ORACLE_SID=$ORACLE_SID \
    ORACLE_ADMIN_SECRET=$ORACLE_ADMIN_SECRET ORACLE_CPUS=$ORACLE_CPUS ORACLE_MEMORY=$ORACLE_MEMORY \
    ORACLE_SGA_MB=$ORACLE_SGA_MB ORACLE_PGA_MB=$ORACLE_PGA_MB ORACLE_STORAGE=$ORACLE_STORAGE \
    envsubst '$NS $DB_SERVICE $ORACLE_IMAGE $ORACLE_SID $ORACLE_ADMIN_SECRET $ORACLE_CPUS $ORACLE_MEMORY $ORACLE_SGA_MB $ORACLE_PGA_MB $ORACLE_STORAGE' \
    < oracle/oracle.yaml.tpl | kubectl apply -f - >/dev/null
  if [[ -n $ORACLE_PULL_SECRET ]]; then
    kubectl -n "$NS" patch statefulset oracle --type merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$ORACLE_PULL_SECRET\"}]}}}}" >/dev/null
  fi
  oracle_ready
  log "oracle ready ($ORACLE_IMAGE, service $DB_SERVICE)"
}

# sql_root <sql>: SQL in CDB$ROOT (before the PDB exists). Used only to wait for the PDB to open.
# NUMWIDTH 20 (here and in sql_admin): the default 10 prints an SCN >= 1e10 as 1.2346E+10, which sql_scalar drops.
sql_root() {
  local pod; pod=$(oracle_pod)
  [[ -n $pod ]] || die "oracle pod not running"
  printf '%s\n' \
    "WHENEVER SQLERROR EXIT SQL.SQLCODE" \
    "SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON NUMWIDTH 20" \
    "$1" \
    "exit;" \
    | kubectl -n "$NS" exec -i "$pod" -- sqlplus -s / as sysdba
}

# sql_admin <sql>: run SQL in the Keycloak PDB as SYSDBA through stdin (no quoting inside the pod, no password in
# argv). Used for schema lifecycle and instrumentation only; Keycloak connects as its own schema user.
sql_admin() {
  local pod; pod=$(oracle_pod)
  [[ -n $pod ]] || die "oracle pod not running"
  printf '%s\n' \
    "WHENEVER SQLERROR EXIT SQL.SQLCODE" \
    "SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON NUMWIDTH 20" \
    "ALTER SESSION SET CONTAINER = $DB_SERVICE;" \
    "$1" \
    "exit;" \
    | kubectl -n "$NS" exec -i "$pod" -- sqlplus -s / as sysdba
}

# sql_db <db> <sql>: SQL in that schema. The SYSDBA session can read any schema, so the password never leaves its Secret.
# SQL*Plus needs a statement terminator before the closing `exit`; callers pass a bare SELECT, so add one here.
sql_db() {
  local schema sql; schema=$(db_schema "$1"); sql=${2%;}
  sql_admin "ALTER SESSION SET CURRENT_SCHEMA = $schema;
$sql;"
}

# sql_scalar <db> <sql>: the one numeric/hex value a scalar SELECT returns (SCN, count), ignoring SQL*Plus noise.
sql_scalar() {
  sql_db "$1" "$2" | tr -d '\r' | awk 'NF == 1 && $1 ~ /^[0-9A-Fa-f]+$/ { v = $1 } END { print v }'
}

# drop_schema <SCHEMA>: kill any sessions still connected to the schema, then DROP USER CASCADE with a short retry.
# Helm uninstall returns before every Keycloak connection is gone; Oracle refuses to drop a connected user.
drop_schema() {
  local schema=$1 s
  for _ in $(seq 30); do
    for s in $(sql_admin "SELECT sid || ',' || serial# FROM v\$session WHERE username = '$schema';" | tr -d '\r' \
      | awk '/^[0-9]+,[0-9]+$/ { print }'); do
      sql_admin "ALTER SYSTEM KILL SESSION '$s' IMMEDIATE;" >/dev/null 2>&1 || true
    done
    if sql_admin "DROP USER $schema CASCADE;" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "could not drop schema $schema (sessions kept reconnecting?)"
}

# drop_db <name>: remove one schema and its Secret, if present. Used before a lossy switch so a retry after a failed
# Data Pump import starts from an empty target (create_db alone would reuse the half-written schema).
drop_db() {
  local TAG=database schema count
  schema=$(db_schema "$1")
  [[ -n $(oracle_pod) ]] || return 0
  count=$(sql_admin "SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME = '$schema';" | tr -d '\r' \
    | awk 'NF == 1 && $1 ~ /^[0-9]+$/ { v = $1 } END { print v }')
  if [[ ${count:-0} != 0 ]]; then
    log "dropping Oracle schema $schema"
    drop_schema "$schema"
  fi
  kubectl -n "$NS" delete secret "$1-app" --ignore-not-found >/dev/null
}

# create_db <name>: an Oracle schema/user, waits until it can be used. The Oracle instance itself is created once by
# db_platform_up; reset drops and recreates schemas, which is why a demo case does not rebuild a database.
create_db() {
  local TAG=database name=$1 schema count pass
  schema=$(db_schema "$name")
  check_profile
  [[ -n $(oracle_pod) ]] || die "oracle pod not running (run scripts/up.sh first)"
  if kubectl -n "$NS" get secret "$name-app" >/dev/null 2>&1; then
    log "db $name ($schema) already exists"
    return
  fi
  pass="Kc$(openssl rand -hex 12)" # 26 chars: Oracle 19c's password limit is 30
  count=$(sql_admin "SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME = '$schema';" | tr -d '\r' | awk 'NF == 1 && $1 ~ /^[0-9]+$/ { v = $1 } END { print v }')
  if [[ ${count:-0} == 0 ]]; then
    log "creating Oracle schema $schema (user + quota)"
    sql_admin "CREATE USER $schema IDENTIFIED BY \"$pass\" DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;" >/dev/null
  else
    log "Oracle schema $schema exists without its Secret: resetting its password"
    sql_admin "ALTER USER $schema IDENTIFIED BY \"$pass\" ACCOUNT UNLOCK;" >/dev/null
  fi
  sql_admin "GRANT CONNECT, RESOURCE, CREATE VIEW, CREATE SYNONYM TO $schema;
GRANT SELECT ON SYS.DBA_RECYCLEBIN TO $schema;
ALTER USER $schema QUOTA UNLIMITED ON USERS;" >/dev/null
  kubectl -n "$NS" create secret generic "$name-app" --from-literal=username="$schema" --from-literal=password="$pass" >/dev/null
  log "db $name ready (Oracle schema $schema in $DB_SERVICE)"
}

# delete_dbs: drop every demo schema (KC1, KC2, ...) and its Secret. The Oracle instance and its PVC stay: startup
# costs minutes, a schema drop costs seconds. Data Pump dumps are removed too.
delete_dbs() {
  local TAG=database s
  [[ -n $(oracle_pod) ]] || { log "no Oracle pod: nothing to delete"; return; }
  for s in $(sql_admin "SELECT USERNAME FROM DBA_USERS WHERE REGEXP_LIKE(USERNAME, '^KC[0-9]+$') ORDER BY USERNAME;" \
    | tr -d '\r' | awk '/^KC[0-9]+$/ { print }'); do
    log "dropping Oracle schema $s"
    drop_schema "$s"
    kubectl -n "$NS" delete secret "${s,,}-app" --ignore-not-found >/dev/null
  done
  kubectl -n "$NS" exec "$(oracle_pod)" -- bash -c "rm -f '$ORACLE_DUMP_DIR'/*.dmp '$ORACLE_DUMP_DIR'/*.log" 2>/dev/null || true
}

# db_helm_args <db> <kc_version>: oracle/values.yaml carries the JDBC URL (the chart only renders a postgres one) and
# the FULL extraEnvVars list (Helm replaces lists); 25.x needs its own list, so its overlay comes after it.
db_helm_args() {
  DB_HELM_ARGS=(-f oracle/values.yaml)
  [[ $2 != 25.* ]] || DB_HELM_ARGS+=(-f oracle/values-kc25.yaml)
  DB_HELM_ARGS+=(--set "externalDatabase.host=$DB_HOST" --set "externalDatabase.database=$DB_SERVICE"
    --set "externalDatabase.schema=$(db_schema "$1")" --set "externalDatabase.existingSecret=$1-app")
}
db_verify() { oracle/check-db.sh "$1"; } # Keycloak Ready is not proof it used the schema we intended
db_changesets() { sql_scalar "$1" "SELECT COUNT(*) FROM DATABASECHANGELOG"; }

# db_copy_prepare <src> <new>: the empty target schema. A retry after a failed import must not import into a
# half-written target.
db_copy_prepare() { drop_db "$2"; create_db "$2"; }

# db_copy_cut <src> <new>: copy point (SCN), consistent export at that SCN, import, row-count proof.
db_copy_cut() {
  local src=$1 new=$2 copy_scn src_schema new_schema stamp dump dplog admin_pw pod rows src_rows copy_rows
  copy_scn=$(sql_scalar "$src" "SELECT DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER FROM dual")
  [[ -n $copy_scn ]] || die "could not read the current SCN from $src"
  event copy_point scn="$copy_scn"

  # expdp/impdp run as SYSTEM (DBA): a schema export with REMAP_SCHEMA needs the Data Pump roles; the app user never
  # gets DBA rights. ponytail: the password is on the tools' command line inside the Oracle pod (its process list);
  # production: a parfile or a wallet.
  src_schema=$(db_schema "$src") new_schema=$(db_schema "$new")
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dump="kc_${stamp}_${src}_to_${new}.dmp" dplog="kc_${stamp}_${src}_to_${new}.log"
  admin_pw=$(kubectl -n "$NS" get secret "$ORACLE_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)
  pod=$(oracle_pod)
  log "exporting $src_schema at SCN $copy_scn (blue keeps serving; admin/account frozen)"
  kubectl -n "$NS" exec "$pod" -- expdp "system/$admin_pw@//localhost:1521/$DB_SERVICE" \
    "SCHEMAS=$src_schema" "FLASHBACK_SCN=$copy_scn" "DIRECTORY=KC_DUMP" "DUMPFILE=$dump" "LOGFILE=$dplog" \
    REUSE_DUMPFILES=YES >/dev/null || die "expdp $src_schema failed (see $dplog in the Oracle pod)"
  # The only long step; blue still serves login/token. STATISTICS: 19c fails on three function-based index statistics.
  log "importing into $new_schema (REMAP_SCHEMA $src_schema:$new_schema)"
  kubectl -n "$NS" exec "$pod" -- impdp "system/$admin_pw@//localhost:1521/$DB_SERVICE" \
    "SCHEMAS=$src_schema" "REMAP_SCHEMA=$src_schema:$new_schema" "DIRECTORY=KC_DUMP" "DUMPFILE=$dump" \
    "LOGFILE=$dplog" EXCLUDE=USER EXCLUDE=STATISTICS >/dev/null || die "impdp into $new_schema failed (see $dplog in the Oracle pod)"

  # Proof that the copy IS the source at the copy point, measured, not restated: users + persisted sessions (the two
  # tables blue keeps writing) in the source AS OF the copy SCN against the copy now. The source's CURRENT count has
  # moved on, so an export that ignored FLASHBACK_SCN or an import that dropped rows shows up here.
  # ponytail: two tables, counts only; DBMS_COMPARISON / per-table hashes if a production copy needs more.
  rows="(SELECT COUNT(*) FROM %s.USER_ENTITY%s) + (SELECT COUNT(*) FROM %s.OFFLINE_USER_SESSION%s)"
  # shellcheck disable=SC2059 # $rows is the format
  src_rows=$(sql_scalar "$src" "SELECT $(printf "$rows" "$src_schema" " AS OF SCN $copy_scn" "$src_schema" " AS OF SCN $copy_scn") FROM dual") || true
  # shellcheck disable=SC2059
  copy_rows=$(sql_scalar "$new" "SELECT $(printf "$rows" "$new_schema" "" "$new_schema" "") FROM dual") || true
  event copy_ready db="$new" scn="$copy_scn"
  event promoted db="$new" scn="$copy_scn" src_rows="$src_rows" copy_rows="$copy_rows" # gate: db_copy_matches_source
  [[ -n $src_rows && $src_rows == "$copy_rows" ]] \
    || die "copy $new_schema has ${copy_rows:-no} user+session rows, $src_schema had ${src_rows:-none} at SCN $copy_scn: not a copy of the copy point"
}
