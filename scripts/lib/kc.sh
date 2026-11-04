# Shared functions. Source from repo root: `. scripts/lib/kc.sh`
# shellcheck shell=bash

NS=${NS:-keycloak} # overridable, e.g. for a test namespace
CLUSTER=kc
CHART=oci://registry-1.docker.io/bitnamicharts/keycloak
CHART_VERSION=25.2.0
KC_IMAGE=kc-bluegreen/keycloak

# Oracle replaces CloudNativePG in this branch. The two blue/green "databases" are two schemas
# (KC1, KC2) in one PDB; Keycloak's db-schema selects which one a color uses. One Oracle
# instance keeps the demo on a 16 GB laptop possible and makes reset a schema drop, not a
# database rebuild. 19c production shape (Data Guard / RAC / separate CDBs) is documented in
# docs/oracle.md; the zero-downtime mechanism does not depend on it.
DB_HOST=${DB_HOST:-oracle}
DB_SERVICE=${DB_SERVICE:-FREEPDB1}
ORACLE_IMAGE=${ORACLE_IMAGE:-gvenzl/oracle-free:23.26.3-slim} # optional 19.3 EE: container-registry.oracle.com/database/enterprise:19.3.0.0
ORACLE_PULL_SECRET=${ORACLE_PULL_SECRET:-}
ORACLE_PULL_SECRET_FILE=${ORACLE_PULL_SECRET_FILE:-} # docker config.json; up.sh turns it into the k8s secret
ORACLE_ADMIN_SECRET=${ORACLE_ADMIN_SECRET:-oracle-admin}
ORACLE_DUMP_DIR=${ORACLE_DUMP_DIR:-/opt/oracle/oradata/dpdump}
# Oracle Free's documented minimum is 2 GiB, but the Kubernetes pod also mounts a 1 GiB memory-backed /dev/shm
# and the image's first start decompresses a 3.0 GiB database archive with 32-thread 7-Zip: 2 GiB (and even 3 GiB)
# is OOMKilled during that extraction in-cluster. 4 GiB is the tested default; a standalone container starts at 2 GiB.
ORACLE_MEMORY=${ORACLE_MEMORY:-4Gi}
ORACLE_STORAGE=${ORACLE_STORAGE:-20Gi}
ORACLE_SGA_MB=${ORACLE_SGA_MB:-1024}
ORACLE_PGA_MB=${ORACLE_PGA_MB:-512}
if [[ $ORACLE_IMAGE == *oracle-free* ]]; then
  ORACLE_SID=${ORACLE_SID:-FREE}
else
  ORACLE_SID=${ORACLE_SID:-ORCLCDB}
fi

# TAG (each script sets one; helpers here inherit the caller's) says what kind of work a line belongs to:
# [deployment], [load test], [config], [database], [replay], [verification], ...
log() { printf '%s %s%s\n' "$(date -u +%FT%TZ)" "${TAG:+[$TAG] }" "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# PROFILE: default = the demo as designed (prod shape: 3 zones, 3 Keycloak pods per color).
# laptop = fits a 16 GB laptop (Docker VM 8-10 GB): kind/cluster-laptop.yaml (2 workers) + helm/values-laptop.yaml
# (2 pods/color, PDB 1, smaller heap), reasons in those files. KC_REPLICAS must equal the profile's helm replicaCount
# (check-cluster.sh compares them). Oracle is one instance in both profiles: 4 GiB is the tested K8s default, so
# PROFILE=laptop needs a 16 GB Docker VM here rather than the 10 GB Postgres profile. The old PG_INSTANCES knob is
# gone: schemas KC1/KC2 are cheap, the Oracle instance is the unit.
# laptop k6: fewer logins/s (login VUs = rate x 25) and app VUs; refresh/logout VUs stay (cheap, the gate needs them).
# NGINX_WORKERS: ingress-nginx defaults to one worker per CPU the node sees (= every host CPU); 2 carry this load.
PROFILE=${PROFILE:-default}
# shellcheck disable=SC2034 # read by the scripts that source this file
case $PROFILE in
  default) KC_REPLICAS=3 ORACLE_CPUS=1 LOGIN_RATE_DEFAULT=2 APP_VUS_DEFAULT=3 NGINX_WORKERS='' KIND_CONFIG=kind/cluster.yaml ;;
  laptop) KC_REPLICAS=2 ORACLE_CPUS=1 LOGIN_RATE_DEFAULT=2 APP_VUS_DEFAULT=3 NGINX_WORKERS=2 KIND_CONFIG=kind/cluster-laptop.yaml ;;
  *) die "unknown PROFILE '$PROFILE' (default|laptop)" ;;
esac

# check_profile: a cluster records its profile as node label kc-bluegreen/profile (kind/cluster-<profile>.yaml; no label
# = default). Running one profile against a cluster made with another fails here, not deep inside a switch. Called where
# the profile shapes cluster objects (up.sh, create_db, deploy_color, switch-lossy, rollback), not in kube_connect: the
# security jobs are profile-agnostic.
check_profile() {
  local p; p=$(kubectl get node "$CLUSTER-control-plane" -o json | jq -r '.metadata.labels["kc-bluegreen/profile"] // "default"') \
    || die "cannot read node $CLUSTER-control-plane"
  [[ $p == "$PROFILE" ]] || die "cluster $CLUSTER was created with PROFILE=$p, this run has PROFILE=$PROFILE (use PROFILE=$p or recreate the cluster)"
}

# Any command that fails (and isn't handled with if/||) logs its exit code, script:line and the command itself, so a
# red Jenkins stage says WHAT failed. errtrace: also inside functions. (Same rules as set -e: conditions don't trigger.)
set -o errtrace
trap 'log "FAILED (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR

# event <name> [key=value...] -> one JSON line in out/events.jsonl (the gate reads these)
event() {
  local name=$1; shift
  mkdir -p out
  local args=(--arg t "$(date -u +%FT%T.%3NZ)" --arg event "$name")
  # shellcheck disable=SC2016 # $t/$event are jq variables
  local obj='{t:$t,event:$event}' kv
  for kv in "$@"; do
    args+=(--arg "${kv%%=*}" "${kv#*=}")
    obj="${obj%\}},${kv%%=*}:\$${kv%%=*}}"
  done
  jq -nc "${args[@]}" "$obj" >> out/events.jsonl
}

# kube_connect: join kind's docker network (created by kind, possibly shared with other kind clusters)
# and write an internal kubeconfig. No-op if the cluster does not exist yet.
kube_connect() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || return 0
  local me; me=$(docker inspect -f '{{.Name}}' "$HOSTNAME" | tr -d /)
  docker network inspect kind -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "$me" \
    || docker network connect kind "$HOSTNAME"
  mkdir -p ~/.kube
  # atomic and only on change: an in-place rewrite left the file empty for a moment, and a concurrent kubectl (another
  # job on the shared kube volume) fell back to localhost:8080 = Jenkins (laptop build #26)
  local tmp=~/.kube/config.$$
  kind get kubeconfig --internal --name "$CLUSTER" > "$tmp"
  if cmp -s "$tmp" ~/.kube/config; then rm -f "$tmp"; else mv -f "$tmp" ~/.kube/config; fi
}

image_tag() { echo "$1-p${2:-1}"; } # <kc_version> [provider_version]

# build_opts <kc_major>: `kc.sh build` options. 26 = the Dockerfile default. On 25 cache/cache-stack are runtime
# options (build rejects them, exit 2; the chart env sets them) and there is no stateless/jdbc-ping. User sessions
# reach the DB only with the preview feature persistent-user-sessions, which must be on from the first start.
# --db=oracle is baked here; the Oracle JDBC driver (ojdbc17 + orai18n) is added in images/keycloak/Dockerfile.
build_opts() {
  case $1 in
    25) echo "--db=oracle --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=persistent-user-sessions" ;;
    26) echo "--db=oracle --cache=ispn --cache-stack=jdbc-ping --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=stateless" ;;
    *) die "no build options for Keycloak major $1" ;;
  esac
}

# build_image <kc_version> [provider_version]: build + load into kind. Skips `docker build` when an image built from
# exactly these inputs exists (label kc-bluegreen.inputs = hash of Dockerfile, provider + theme sources, build args):
# even a fully cached build of the 1.1 GB image took ~28 s, ~45 s with kind load, twice per case.
build_image() {
  local TAG=build
  local tag opts inputs; tag=$(image_tag "$1" "${2:-1}"); opts=$(build_opts "${1%%.*}")
  inputs=$( { printf '%s\n' "$1" "$2" "$opts"; find images/keycloak providers/pom.xml providers/src themes -type f -print0 \
    | sort -z | xargs -0 sha256sum; } | sha256sum | cut -c1-16)
  if [[ $(docker image inspect -f '{{index .Config.Labels "kc-bluegreen.inputs"}}' "$KC_IMAGE:$tag" 2>/dev/null) == "$inputs" ]]; then
    log "image $KC_IMAGE:$tag is up to date (inputs $inputs): no rebuild"
  else
    log "building image $KC_IMAGE:$tag (inputs $inputs; provider jar + tests + kc.sh build; a new version takes minutes)"
    # stream the build log with a prefix (the launcher is Alpine/BusyBox: no GNU `sed -u` or `grep --line-buffered`)
    docker build --progress=plain --build-arg "KC_VERSION=$1" --build-arg "KC_MAJOR=${1%%.*}" --build-arg "KC_BUILD_OPTS=$opts" \
      --build-arg "PROVIDER_VERSION=${2:-1}" --build-arg "THEME_VERSION=${2:-1}" --label "kc-bluegreen.inputs=$inputs" \
      -t "$KC_IMAGE:$tag" -f images/keycloak/Dockerfile . 2>&1 | sed 's/^/  docker /' >&2
  fi
  kind load docker-image --name "$CLUSTER" "$KC_IMAGE:$tag" >/dev/null 2>&1 || die "kind load $KC_IMAGE:$tag" # skips nodes that have it
  log "image $KC_IMAGE:$tag loaded"
}

# ensure_secret <name> <key> [bytes]: random value, created once, never printed. Oracle 19c limits passwords to 30
# characters, so the Oracle admin secret uses 12 bytes (24 hex); Keycloak secrets keep the default 24 bytes.
ensure_secret() {
  kubectl -n "$NS" get secret "$1" >/dev/null 2>&1 && return
  kubectl -n "$NS" create secret generic "$1" --from-literal="$2=$(openssl rand -hex "${3:-24}")" >/dev/null
}

# db_schema <name>: the demo's logical DB names are kc1/kc2; Oracle schemas are upper-case.
db_schema() {
  [[ $1 =~ ^kc[0-9]+$ ]] || die "invalid db name '$1' (expected kc<number>)"
  printf '%s' "${1^^}"
}

# oracle_pod: the one Oracle StatefulSet pod (k8s/oracle/oracle.yaml.tpl)
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

# sql_root <sql>: SQL in CDB$ROOT (before the PDB exists). Used only to wait for the PDB to open.
sql_root() {
  local pod; pod=$(oracle_pod)
  [[ -n $pod ]] || die "oracle pod not running"
  printf '%s\n' \
    "WHENEVER SQLERROR EXIT SQL.SQLCODE" \
    "SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON" \
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
    "SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON" \
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
# up.sh; reset drops and recreates schemas, which is why a demo case no longer rebuilds a database.
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
    log "creating Oracle schema $schema (user + quota; no CNPG cluster)"
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

# deploy_color <color> <kc_version> <db> [provider_version]
deploy_color() {
  local color=$1 version=$2 db=$3 tag; tag=$(image_tag "$2" "${4:-1}")
  local overlay=(); [[ $version == 25.* ]] && overlay=(-f helm/values-kc25.yaml)
  [[ $PROFILE == default ]] || overlay+=(-f "helm/values-$PROFILE.yaml") # last: wins over common + kc25
  local schema; schema=$(db_schema "$db")
  check_profile
  log "deploying kc-$color @ $version ($tag) on Oracle schema $schema, waiting for $KC_REPLICAS Ready pods (helm --wait)"
  helm upgrade --install "kc-$color" "$CHART" --version "$CHART_VERSION" -n "$NS" \
    -f helm/values-common.yaml "${overlay[@]}" \
    --set "image.tag=$tag" \
    --set "externalDatabase.host=$DB_HOST" \
    --set "externalDatabase.port=1521" \
    --set "externalDatabase.database=$DB_SERVICE" \
    --set "externalDatabase.schema=$schema" \
    --set "externalDatabase.existingSecret=$db-app" \
    --wait --timeout 15m >/dev/null
  scripts/check-db.sh "$db" # Keycloak Ready is not proof it used the schema we intended
  log "kc-$color @ $version on Oracle schema $schema ready"
}

# set_active <color> <db> <kc_version>: flip the switch, record state (the previous one too, for rollback.sh)
set_active() {
  local pc pd pv
  pc=$(state activeColor 2>/dev/null || true) pd=$(state activeDb 2>/dev/null || true) pv=$(state version 2>/dev/null || true)
  [[ $pc == "$1" && $pd == "$2" ]] && { pc=$(state previousColor 2>/dev/null || true); pd=$(state previousDb 2>/dev/null || true)
    pv=$(state previousVersion 2>/dev/null || true); } # re-assert (up.sh): keep the real previous state
  kubectl -n "$NS" patch svc kc-active --type merge \
    -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/instance\":\"kc-$1\"}}}" >/dev/null
  frozen || gate_select "$(kc_selector "$1")" # a freeze keeps admin/account on kc-maint until unfreeze
  wait_routed "$1"
  kubectl -n "$NS" create configmap kc-state --from-literal=activeColor="$1" --from-literal=activeDb="$2" \
    --from-literal=version="$3" --from-literal=previousColor="$pc" --from-literal=previousDb="$pd" \
    --from-literal=previousVersion="$pv" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "active -> $1 ($3 on $2)"
}

state() { kubectl -n "$NS" get configmap kc-state -o "jsonpath={.data.$1}"; }

# wait_routed <color>: until ingress-nginx's OWN upstream list for kc-active (its /dbg view of the Lua balancer) holds
# exactly that color's ready pods. Patching the Service is not routing: laptop build #24 saw blue serve a new login
# 2.8 s after the patch, so the `flipped` event written after set_active must mean "traffic moved".
wait_routed() {
  local p want got; p=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o name | head -1)
  want=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=kc-$1" -o json | jq -r '[.items[]
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .status.podIP] | sort | join(" ")')
  for _ in $(seq 120); do
    got=$(kubectl -n ingress-nginx exec "$p" -- /dbg backends get keycloak-kc-active-http 2>/dev/null \
      | jq -r '[.endpoints[]?.address] | sort | join(" ")') || got=
    [[ -n $want && $got == "$want" ]] && return 0
    sleep 0.5
  done
  die "ingress-nginx routes kc-active to '${got:-nothing}', want kc-$1's ready pods ($want)"
}

# save_logs <color>: that color's Keycloak logs (every pod) to out/kc-<color>.log, before a scale-down deletes them:
# the only evidence behind a 5xx the gate counts (build #11: three 500s on blue, unexplained once blue was gone).
save_logs() {
  local p; : > "out/kc-$1.log"
  for p in $(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=kc-$1" -o name); do
    kubectl -n "$NS" logs "$p" -c keycloak --prefix --timestamps >> "out/kc-$1.log" 2>/dev/null || true
  done
  log "saved kc-$1 logs -> out/kc-$1.log ($(grep -c ' ERROR ' "out/kc-$1.log" || true) ERROR lines)"
}

# cli_tag <kc_version>: keycloak-config-cli image tag built against the same Keycloak major
cli_tag() { case $1 in 25.*) echo 6.5.1-25 ;; 26.*) echo 6.5.1-26.5.5 ;; *) die "no config-cli for Keycloak $1" ;; esac; }

# admin_api <METHOD> <path under /keycloak/admin> [curl args...]: Keycloak admin REST via the public URL (ingress on the
# control-plane node, TLS verified against the demo CA), authenticated as the config-cli service account.
admin_api() {
  local method=$1 path=$2; shift 2
  local base c
  if [[ -n ${ADMIN_BASE:-} ]]; then # admin_direct_start: one color via port-forward
    base=$ADMIN_BASE c=(curl -sf)
  else
    [[ -n ${CA_FILE:-} ]] || ca_file >/dev/null
    local ip; ip=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$CLUSTER-control-plane")
    base=https://kc-net1.localtest.me/keycloak c=(curl -sf --cacert "$CA_FILE" --resolve "kc-net1.localtest.me:443:$ip")
  fi
  if [[ -z ${ADMIN_TOKEN:-} ]]; then
    ADMIN_TOKEN=$("${c[@]}" -d grant_type=client_credentials -d client_id=config-cli \
      --data-urlencode "client_secret=$(kubectl -n "$NS" get secret kc-config-cli -o jsonpath='{.data.secret}' | base64 -d)" \
      "$base/realms/master/protocol/openid-connect/token" | jq -r .access_token) || die "admin token"
  fi
  "${c[@]}" -X "$method" -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' "$@" "$base/admin$path"
}

# ca_file: path to the demo CA, read from the cluster (Secret demo-ca), so scripts also work in a fresh checkout such
# as a Jenkins workspace, where out/certs does not exist.
ca_file() {
  if [[ -z ${CA_FILE:-} ]]; then
    CA_FILE=$(mktemp)
    kubectl -n "$NS" get secret demo-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE" || die "no Secret demo-ca"
  fi
  echo "$CA_FILE"
}

# first_install <kc_version> <provider_version> <db>: blue on a fresh DB, config stages, seeded users. No traffic yet,
# so the maintenance stage runs right away.
first_install() {
  build_image "$1" "$2"
  deploy_color blue "$1" "$3" "$2"
  set_active blue "$3" "$1"
  local stage; for stage in bootstrap online maintenance; do scripts/config.sh "$stage" blue; done
  scripts/seed-users.sh 4000
}

# kc_selector <color>: the selector of that color's Keycloak pods (JSON). gate_select <json>: Service kc-gate's
# selector (k8s/edge/kc-gate.yaml): the admin/account paths follow it. frozen: they go to kc-maint right now.
kc_selector() { printf '{"app.kubernetes.io/name":"keycloak","app.kubernetes.io/instance":"kc-%s"}' "$1"; }
gate_select() {
  kubectl -n "$NS" patch svc kc-gate --type json -p "[{\"op\":\"add\",\"path\":\"/spec/selector\",\"value\":$1}]" >/dev/null
}
frozen() { [[ $(kubectl -n "$NS" get svc kc-gate -o jsonpath='{.spec.selector.app}' 2>/dev/null) == kc-maint ]]; }

# gate_wait <503|open>: patched is not routed (endpoints propagate in seconds): wait until /keycloak/admin answers 503,
# or anything else, on both hosts.
gate_wait() {
  [[ -n ${CA_FILE:-} ]] || ca_file >/dev/null
  local ip h code ok; ip=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$CLUSTER-control-plane")
  for h in kc-net1 kc-net2; do
    for _ in $(seq 60); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" --resolve "$h.localtest.me:443:$ip"         "https://$h.localtest.me/keycloak/admin/") || true
      if [[ $1 == 503 ]]; then [[ $code == 503 ]] && ok=1 || ok=; else [[ $code =~ ^[1-4] ]] && ok=1 || ok=; fi
      [[ -n $ok ]] && break; sleep 1
    done
    [[ -n $ok ]] || die "gate: $h.localtest.me/keycloak/admin answers ${code:-nothing}, want $1"
  done
}

# freeze: admin + account console (both hosts, k8s/edge/kc-gate.yaml) answer 503 + Retry-After from kc-maint.
# A selector flip, not an Ingress change: no nginx reload (that dropped Keycloak's pooled IdP connections, build #12).
freeze() {
  kubectl apply -f k8s/edge/kc-maint.yaml >/dev/null
  kubectl -n "$NS" rollout status deploy/kc-maint --timeout=120s >/dev/null
  gate_select '{"app":"kc-maint"}'
  gate_wait 503
  # let requests blue already admitted finish, so no admin/account write commits after the copy point that follows
  sleep "${FREEZE_SETTLE_SECONDS:-2}" # ponytail: admitted admin calls take ms; a fixed settle, not request tracking
  log "frozen: /keycloak/admin /keycloak/realms/{demo,master}/account (kc-gate -> kc-maint)"
}
unfreeze() {
  gate_select "$(kc_selector "$(state activeColor)")"
  gate_wait open
  log "unfrozen (kc-gate -> kc-$(state activeColor))"
}

# delete_dbs: drop every demo schema (KC1, KC2, ...) and its Secret. The Oracle instance and its PVC stay: startup
# costs minutes, a schema drop costs seconds. Data Pump dumps are removed too, unless one is being kept for evidence.
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

# admin_direct_start <color> / admin_direct_stop: like admin_api, but straight to one color's Service via a
# port-forward (kubelet path, not subject to the NetworkPolicy). Needed before a switch, when ingress still points at
# the other color. Sets ADMIN_BASE; admin_api uses it when set.
admin_direct_start() {
  local port=$((20000 + RANDOM % 10000))
  kubectl -n "$NS" port-forward "svc/kc-$1-keycloak" "$port:80" >/dev/null 2>&1 &
  ADMIN_PF=$!
  ADMIN_BASE=http://127.0.0.1:$port/keycloak ADMIN_TOKEN=
  local _; for _ in $(seq 30); do curl -sf "$ADMIN_BASE/realms/master" >/dev/null && return; sleep 1; done
  die "port-forward to kc-$1 failed"
}
admin_direct_stop() { kill "${ADMIN_PF:-}" 2>/dev/null || true; unset ADMIN_BASE ADMIN_PF; ADMIN_TOKEN=; }

# k6_status: one line of what the load generator has seen so far (requests, 5xx/status 0, refresh invalid_grant,
# logins, logged-out sessions that still refresh), or "k6 not running"
k6_status() {
  local p; p=$(kubectl -n load get pod -l job-name=k6 -o name 2>/dev/null | head -1)
  [[ -n $p ]] || { echo "k6 not running"; return; }
  kubectl -n load exec "$p" -- cat /out/k6.log 2>/dev/null \
    | jq -rRs '(split("\n") | map(select(startswith("k6 exited"))) | first // null) as $end
      | [split("\n")[] | fromjson? | select(type == "object" and has("t_start"))]
      | (if $end then "K6 ENDED (\($end)): NO LOAD NOW | " else "" end) + "k6:\(length) requests, \(map(select(.status >= 500 or .status == 0)) | length) 5xx/neterr, \(map(select(.error == "invalid_grant" and .step == "refresh")) | length) refresh invalid_grant, \(map(select(.step == "login_token" and .status == 200)) | length) logins, \(map(select(.step == "logout_probe" and .status == 200)) | length) logged-out refreshes"'
}

# wait_progress <seconds> <label>: sleep, but log k6_status every 30 s. Silent sleeps make a live run look dead.
wait_progress() {
  local total=$1 label=$2 waited=0 step TAG="load test"
  while ((waited < total)); do
    step=$((total - waited < 30 ? total - waited : 30)); sleep "$step"; waited=$((waited + step))
    log "$label ${waited}/${total}s | $(k6_status)"
  done
}

# progress_ticker <label>: background k6_status every 30 s while a switch/rollback runs (the load never pauses;
# this makes that visible). Start with `progress_ticker x & t=$!`, stop with `kill $t`.
progress_ticker() {
  local TAG="load test" s=0
  trap - ERR
  while sleep 30; do s=$((s + 30)); log "$1 +${s}s | $(k6_status)"; done
}
