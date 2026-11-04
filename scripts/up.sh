#!/usr/bin/env bash
# Idempotent platform bring-up: KinD + ingress-nginx + Oracle + kc1 + blue Keycloak. Run via `docker compose up launcher`.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="platform"

FROM=${FROM:-26.8.1}
INGRESS_NGINX=controller-v1.15.1 # final release; ingress-nginx is EOL since March 2026 (user's prod edge)

# Fail with one sentence when this machine cannot run the demo (ports, Docker memory, shells, DNS), not halfway
# through a cluster build.
scripts/preflight.sh

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config "$KIND_CONFIG" # per PROFILE (lib/kc.sh)
kube_connect
check_profile

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX/deploy/static/provider/kind/deploy.yaml" >/dev/null
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s >/dev/null
# Edge hardening, controller-wide (covers kc, kc-gate and legacy-idp alike); headers: k8s/edge/ingress-nginx.yaml.
# One issuer per host: nginx picks the server case-insensitively and ignores a trailing dot, but forwards the RAW Host
# as X-Forwarded-Host ($best_http_host = $http_host, nginx.tmpl), so `Host: KC-NET1.LOCALTEST.ME` or
# `kc-net1.localtest.me.` changed the issuer. $host is nginx's normalised Host (lower case, no port, no trailing dot):
# a request whose raw Host differs gets 421 Misdirected Request at server level, before any location or backend.
# Rejected: proxy-set-headers X-Forwarded-Host "$host" (appended AFTER the built-in line = two X-Forwarded-Host
# headers); upstream-vhost (sets Host only, one value per Ingress, X-Forwarded-Host stays raw); snippet ANNOTATIONS
# (need allow-snippet-annotations=true + annotations-risk-level=Critical, i.e. raw nginx config for every Ingress author).
# A ConfigMap server-snippet is admin-only and needs neither (the controller gates only *-snippet annotations).
# The hash annotation makes the controller reload when only the referenced ConfigMaps change (it watches just this one).
kubectl apply -f k8s/edge/ingress-nginx.yaml >/dev/null
# shellcheck disable=SC2016 # nginx variables, literal
kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type merge -p "$(jq -nc \
  --arg h "$(sha256sum k8s/edge/ingress-nginx.yaml | cut -c1-16)" --arg w "$NGINX_WORKERS" '{metadata: {annotations: {"kc-bluegreen/edge": $h}},
  data: ({"server-snippet": "if ($http_host != $host) { return 421; }",
    "proxy-set-headers": "ingress-nginx/kc-proxy-headers", "add-headers": "ingress-nginx/kc-response-headers"}
    + if $w == "" then {} else {"worker-processes": $w} end)}')" >/dev/null # NGINX_WORKERS: PROFILE=laptop only
log "ingress-nginx ready"

# *.localtest.me -> ingress inside the cluster too, so pods use the same URLs as the host browser.
corefile=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
if ! grep -q localtest <<<"$corefile"; then
  # shellcheck disable=SC2001 # multi-line insert, sed is clearer than parameter expansion
  corefile=$(sed 's/^\( *\)ready$/&\n\1rewrite name regex (.*)\\.localtest\\.me ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto/' <<<"$corefile")
  kubectl -n kube-system create configmap coredns --from-literal=Corefile="$corefile" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null
  kubectl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  log "coredns rewrite for *.localtest.me"
fi

for ns in "$NS" legacy apps; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
scripts/certs.sh "$NS" legacy apps
ensure_secret kc-bootstrap-admin password
ensure_secret "$ORACLE_ADMIN_SECRET" password 12
kubectl -n "$NS" create configmap oracle-bootstrap --from-file=k8s/oracle/bootstrap.sh --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
if [[ -n $ORACLE_PULL_SECRET && -n $ORACLE_PULL_SECRET_FILE ]]; then
  kubectl -n "$NS" create secret generic "$ORACLE_PULL_SECRET" \
    --from-file=.dockerconfigjson="$ORACLE_PULL_SECRET_FILE" --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
# envsubst takes only the template's inputs: an unrestricted call would eat Oracle's V$PDBS in the probe SQL.
NS=$NS DB_SERVICE=$DB_SERVICE ORACLE_IMAGE=$ORACLE_IMAGE ORACLE_SID=$ORACLE_SID \
  ORACLE_ADMIN_SECRET=$ORACLE_ADMIN_SECRET ORACLE_CPUS=$ORACLE_CPUS ORACLE_MEMORY=$ORACLE_MEMORY \
  ORACLE_SGA_MB=$ORACLE_SGA_MB ORACLE_PGA_MB=$ORACLE_PGA_MB ORACLE_STORAGE=$ORACLE_STORAGE \
  envsubst '$NS $DB_SERVICE $ORACLE_IMAGE $ORACLE_SID $ORACLE_ADMIN_SECRET $ORACLE_CPUS $ORACLE_MEMORY $ORACLE_SGA_MB $ORACLE_PGA_MB $ORACLE_STORAGE' \
  < k8s/oracle/oracle.yaml.tpl | kubectl apply -f - >/dev/null
if [[ -n $ORACLE_PULL_SECRET ]]; then
  kubectl -n "$NS" patch statefulset oracle --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$ORACLE_PULL_SECRET\"}]}}}}" >/dev/null
fi
oracle_ready
log "oracle ready ($ORACLE_IMAGE, service $DB_SERVICE)"
create_db kc1

# Legacy IdP (outside world). Its broker client secret is copied to Keycloak's namespace for the IdP configs.
if ! kubectl -n legacy get secret legacy-idp >/dev/null 2>&1; then
  kubectl -n legacy create secret generic legacy-idp --from-literal=user-password="$(openssl rand -hex 12)" \
    --from-literal=client-secret="$(openssl rand -hex 24)" >/dev/null
fi
kubectl -n "$NS" create secret generic legacy-broker --dry-run=client -o yaml \
  --from-literal=client-secret="$(kubectl -n legacy get secret legacy-idp -o jsonpath='{.data.client-secret}' | base64 -d)" \
  | kubectl apply -f - >/dev/null
legacy_id=$(docker build -q -f images/legacy-idp/Dockerfile legacy-idp) # tests run inside the build
LEGACY_IMAGE=kc-bluegreen/legacy-idp:${legacy_id:7:12} # content tag: a code change rolls the Deployment
docker tag "$legacy_id" "$LEGACY_IMAGE"
kind load docker-image --name "$CLUSTER" "$LEGACY_IMAGE" >/dev/null 2>&1 || die "kind load $LEGACY_IMAGE"
LEGACY_IMAGE=docker.io/$LEGACY_IMAGE envsubst < k8s/legacy/legacy-idp.yaml.tpl | kubectl apply -f - >/dev/null
kubectl -n legacy rollout status deploy/legacy-idp --timeout=300s >/dev/null
log "legacy-idp ready: https://legacy-net1.localtest.me, https://legacy-net2.localtest.me"

# Test apps (docs/test-apps.md): OIDC client + resource server in ns apps, GraalVM native images. Their Keycloak client
# secrets: Secret test-apps, generated once, in ns apps (the apps) AND $NS (config-cli: config/online/70-test-apps.json).
# Before first_install: its online config stage needs the $NS copy.
if ! kubectl -n apps get secret test-apps >/dev/null 2>&1; then
  kubectl -n apps create secret generic test-apps --from-literal=testclient-bc="$(openssl rand -hex 24)" \
    --from-literal=testclient-fc="$(openssl rand -hex 24)" --from-literal=testresource="$(openssl rand -hex 24)" >/dev/null
fi
kubectl -n apps get secret test-apps -o json \
  | jq --arg ns "$NS" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' \
  | kubectl apply -f - >/dev/null
# app_image <app> <var>: build (tests inside; native image = minutes), content tag, kind load; image ref -> <var>
app_image() {
  local id img
  id=$(docker build -q -f "images/$1/Dockerfile" "$1") || die "build $1"
  img=kc-bluegreen/$1:${id:7:12} # content tag: a code change rolls the Deployment
  docker tag "$id" "$img"
  kind load docker-image --name "$CLUSTER" "$img" >/dev/null 2>&1 || die "kind load $img"
  printf -v "$2" '%s' "docker.io/$img"
}
log "building test apps (native images, tests run inside the build: takes minutes)"
app_image testclient TESTCLIENT_IMAGE
app_image testresource TESTRESOURCE_IMAGE
export TESTCLIENT_IMAGE TESTRESOURCE_IMAGE
envsubst < k8s/apps/test-apps.yaml.tpl | kubectl apply -f - >/dev/null
for app in testclient testresource; do kubectl -n apps rollout status "deploy/$app" --timeout=300s >/dev/null; done
log "test apps ready: https://app.localtest.me, https://api.localtest.me"

kubectl apply -f k8s/edge/ >/dev/null
if ! kubectl -n "$NS" get configmap kc-state >/dev/null 2>&1; then
  first_install "$FROM" 1 kc1
else
  set_active "$(state activeColor)" "$(state activeDb)" "$(state version)" # k8s/edge/ hard-codes blue; state wins
fi
log "up: https://kc-net1.localtest.me/keycloak/admin + kc-net2 (admin: temp-admin, password: kubectl -n $NS get secret kc-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)"
