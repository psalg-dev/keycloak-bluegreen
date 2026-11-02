# Shared functions. Source from repo root: `. scripts/lib/kc.sh`
# shellcheck shell=bash

NS=keycloak
CLUSTER=kc
CHART=oci://registry-1.docker.io/bitnamicharts/keycloak
CHART_VERSION=25.2.0
KC_IMAGE=kc-bluegreen/keycloak

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

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

# build_image <kc_version> [provider_version]: build + load into kind (skipped if the node already has it)
build_image() {
  local tag; tag=$(image_tag "$1" "${2:-1}")
  docker build -q --build-arg "KC_VERSION=$1" --build-arg "KC_MAJOR=${1%%.*}" \
    --build-arg "PROVIDER_VERSION=${2:-1}" --build-arg "THEME_VERSION=${2:-1}" \
    -t "$KC_IMAGE:$tag" -f images/keycloak/Dockerfile . >/dev/null
  kind load docker-image --name "$CLUSTER" "$KC_IMAGE:$tag" >/dev/null 2>&1 || die "kind load $KC_IMAGE:$tag"
  log "image $KC_IMAGE:$tag loaded"
}

# ensure_secret <name> <key>: random value, created once, never printed
ensure_secret() {
  kubectl -n "$NS" get secret "$1" >/dev/null 2>&1 && return
  kubectl -n "$NS" create secret generic "$1" --from-literal="$2=$(openssl rand -hex 24)" >/dev/null
}

# create_db <name>: CNPG cluster, waits until Ready
create_db() {
  DB=$1 envsubst < k8s/postgres/pg.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$NS" wait "cluster.postgresql.cnpg.io/$1" --for=condition=Ready --timeout=600s >/dev/null
  log "db $1 ready"
}

# deploy_color <color> <kc_version> <db> [provider_version]
deploy_color() {
  local color=$1 version=$2 db=$3 tag; tag=$(image_tag "$2" "${4:-1}")
  helm upgrade --install "kc-$color" "$CHART" --version "$CHART_VERSION" -n "$NS" \
    -f helm/values-common.yaml \
    --set "image.tag=$tag" \
    --set "externalDatabase.host=$db-rw" \
    --set "externalDatabase.existingSecret=$db-app" \
    --wait --timeout 15m >/dev/null
  log "kc-$color @ $version on $db ready"
}

# set_active <color> <db> <kc_version>: flip the switch, record state
set_active() {
  kubectl -n "$NS" patch svc kc-active --type merge \
    -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/instance\":\"kc-$1\"}}}" >/dev/null
  kubectl -n "$NS" create configmap kc-state --from-literal=activeColor="$1" \
    --from-literal=activeDb="$2" --from-literal=version="$3" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "active -> $1 ($3 on $2)"
}

state() { kubectl -n "$NS" get configmap kc-state -o "jsonpath={.data.$1}"; }

# cli_tag <kc_version>: keycloak-config-cli image tag built against the same Keycloak major
cli_tag() { case $1 in 25.*) echo 6.5.1-25 ;; 26.*) echo 6.5.1-26.5.5 ;; *) die "no config-cli for Keycloak $1" ;; esac; }

# admin_api <METHOD> <path under /keycloak/admin> [curl args...]: Keycloak admin REST via the public URL (ingress on the
# control-plane node, TLS verified against the demo CA), authenticated as the config-cli service account.
admin_api() {
  local method=$1 path=$2; shift 2
  [[ -n ${CA_FILE:-} ]] || ca_file >/dev/null
  local ip; ip=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$CLUSTER-control-plane")
  local base=https://kc-net1.localtest.me/keycloak c=(curl -sf --cacert "$CA_FILE" --resolve "kc-net1.localtest.me:443:$ip")
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
