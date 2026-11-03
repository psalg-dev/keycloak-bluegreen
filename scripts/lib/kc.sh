# Shared functions. Source from repo root: `. scripts/lib/kc.sh`
# shellcheck shell=bash

NS=${NS:-keycloak} # overridable, e.g. for a test namespace
CLUSTER=kc
CHART=oci://registry-1.docker.io/bitnamicharts/keycloak
CHART_VERSION=25.2.0
KC_IMAGE=kc-bluegreen/keycloak

# TAG (each script sets one; helpers here inherit the caller's) says what kind of work a line belongs to:
# [deployment], [load test], [config], [database], [replay], [verification], ...
log() { printf '%s %s%s\n' "$(date -u +%FT%TZ)" "${TAG:+[$TAG] }" "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# PROFILE: default = the demo as designed (prod shape: 3 zones, 3 Keycloak pods per color, 3 Postgres instances).
# laptop = fits a 16 GB laptop (Docker VM 8-10 GB): kind/cluster-laptop.yaml (2 workers) + helm/values-laptop.yaml
# (2 pods/color, PDB 1, smaller heap), reasons in those files. KC_REPLICAS must equal the profile's helm replicaCount
# (check-cluster.sh compares them). PG_INSTANCES 2, not 1: same pg templates and the same promote/restart path as
# default (only the count differs), sync replication (ANY 1) kept; 1 instance needs the synchronous block removed
# (no standby to ack) for ~340 MiB less per cluster. Cost of 2: a standby restart stalls commits (dataDurability).
# laptop k6: fewer logins/s (login VUs = rate x 25) and app VUs; refresh/logout VUs stay (cheap, the gate needs them).
# NGINX_WORKERS: ingress-nginx defaults to one worker per CPU the node sees (= every host CPU); 2 carry this load.
PROFILE=${PROFILE:-default}
# shellcheck disable=SC2034 # read by the scripts that source this file
case $PROFILE in
  default) KC_REPLICAS=3 PG_INSTANCES=3 LOGIN_RATE_DEFAULT=5 APP_VUS_DEFAULT=6 NGINX_WORKERS='' KIND_CONFIG=kind/cluster.yaml ;;
  laptop) KC_REPLICAS=2 PG_INSTANCES=2 LOGIN_RATE_DEFAULT=2 APP_VUS_DEFAULT=3 NGINX_WORKERS=2 KIND_CONFIG=kind/cluster-laptop.yaml ;;
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
  kind get kubeconfig --internal --name "$CLUSTER" > ~/.kube/config
}

image_tag() { echo "$1-p${2:-1}"; } # <kc_version> [provider_version]

# build_opts <kc_major>: `kc.sh build` options. 26 = the Dockerfile default. On 25 cache/cache-stack are runtime
# options (build rejects them, exit 2; the chart env sets them) and there is no stateless/jdbc-ping. User sessions
# reach the DB only with the preview feature persistent-user-sessions, which must be on from the first start.
build_opts() {
  case $1 in
    25) echo "--db=postgres --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=persistent-user-sessions" ;;
    26) echo "--db=postgres --cache=ispn --cache-stack=jdbc-ping --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=stateless" ;;
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
    # stream only the build-step headers ("#7 [ext 4/7] RUN mvn ... verify"), so a long build is visibly alive
    docker build --progress=plain --build-arg "KC_VERSION=$1" --build-arg "KC_MAJOR=${1%%.*}" --build-arg "KC_BUILD_OPTS=$opts" \
      --build-arg "PROVIDER_VERSION=${2:-1}" --build-arg "THEME_VERSION=${2:-1}" --label "kc-bluegreen.inputs=$inputs" \
      -t "$KC_IMAGE:$tag" -f images/keycloak/Dockerfile . 2>&1 \
      | { grep --line-buffered -E '^#[0-9]+ (\[|CACHED|DONE [0-9]+\.[0-9]+s$|ERROR)' || true; } | sed -u 's/^/  docker /' >&2
  fi
  kind load docker-image --name "$CLUSTER" "$KC_IMAGE:$tag" >/dev/null 2>&1 || die "kind load $KC_IMAGE:$tag" # skips nodes that have it
  log "image $KC_IMAGE:$tag loaded"
}

# ensure_secret <name> <key>: random value, created once, never printed
ensure_secret() {
  kubectl -n "$NS" get secret "$1" >/dev/null 2>&1 && return
  kubectl -n "$NS" create secret generic "$1" --from-literal="$2=$(openssl rand -hex 24)" >/dev/null
}

# create_db <name>: CNPG cluster, waits until Ready
create_db() {
  local TAG=database
  check_profile
  log "creating db $1 ($PG_INSTANCES instances, sync replication) and waiting for Ready"
  DB=$1 NS=$NS PG_INSTANCES=$PG_INSTANCES envsubst < k8s/postgres/pg.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$1" --for=condition=Ready --timeout=600s >/dev/null
  log "db $1 ready"
}

# deploy_color <color> <kc_version> <db> [provider_version]
deploy_color() {
  local color=$1 version=$2 db=$3 tag; tag=$(image_tag "$2" "${4:-1}")
  local overlay=(); [[ $version == 25.* ]] && overlay=(-f helm/values-kc25.yaml)
  [[ $PROFILE == default ]] || overlay+=(-f "helm/values-$PROFILE.yaml") # last: wins over common + kc25
  check_profile
  log "deploying kc-$color @ $version ($tag) on $db, waiting for $KC_REPLICAS Ready pods (helm --wait)"
  helm upgrade --install "kc-$color" "$CHART" --version "$CHART_VERSION" -n "$NS" \
    -f helm/values-common.yaml "${overlay[@]}" \
    --set "image.tag=$tag" \
    --set "externalDatabase.host=$db-rw" \
    --set "externalDatabase.existingSecret=$db-app" \
    --wait --timeout 15m >/dev/null
  log "kc-$color @ $version on $db ready"
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

# psql_db <db-cluster> <sql> [database]: run SQL on the cluster's current primary as postgres
psql_db() {
  local pod; pod=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$1" -o jsonpath='{.status.currentPrimary}')
  kubectl -n "$NS" exec "$pod" -c postgres -- psql -U postgres -d "${3:-postgres}" -Atc "$2"
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
