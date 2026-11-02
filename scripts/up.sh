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

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
scripts/certs.sh "$NS"
ensure_secret kc-bootstrap-admin password
kubectl -n "$NS" get cluster.postgresql.cnpg.io pg-1 >/dev/null 2>&1 || create_db pg-1

build_image "$FROM" 1
kubectl apply -f k8s/edge/ >/dev/null
if ! kubectl -n "$NS" get configmap kc-state >/dev/null 2>&1; then
  deploy_color blue "$FROM" pg-1 1
  set_active blue pg-1 "$FROM"
fi
log "up: https://kc.localtest.me/keycloak/admin (admin: temp-admin, password: kubectl -n $NS get secret kc-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)"
