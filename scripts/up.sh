#!/usr/bin/env bash
# Idempotent platform bring-up: KinD + ingress-nginx + CNPG + pg-1 + blue Keycloak. Run via `docker compose up launcher`.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

FROM=${FROM:-26.8.1}
INGRESS_NGINX=controller-v1.15.1 # final release; ingress-nginx is EOL since March 2026 (user's prod edge)
CNPG=1.30.1

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config kind/cluster.yaml
kube_connect

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX/deploy/static/provider/kind/deploy.yaml" >/dev/null
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s >/dev/null
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

kubectl apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG/cnpg-$CNPG.yaml" >/dev/null
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s >/dev/null
log "cnpg ready"

for ns in "$NS" legacy; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
scripts/certs.sh "$NS" legacy
ensure_secret kc-bootstrap-admin password
kubectl -n "$NS" get cluster.postgresql.cnpg.io pg-1 >/dev/null 2>&1 || create_db pg-1

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

kubectl apply -f k8s/edge/ >/dev/null
if ! kubectl -n "$NS" get configmap kc-state >/dev/null 2>&1; then
  first_install "$FROM" 1 pg-1
else
  set_active "$(state activeColor)" "$(state activeDb)" "$(state version)" # k8s/edge/ hard-codes blue; state wins
fi
log "up: https://kc-net1.localtest.me/keycloak/admin + kc-net2 (admin: temp-admin, password: kubectl -n $NS get secret kc-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)"
