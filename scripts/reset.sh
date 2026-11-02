#!/usr/bin/env bash
# reset.sh: back to an empty Keycloak namespace with a fresh pg-1, so each demo case starts from scratch.
# Keeps the platform (ingress, CNPG operator, legacy IdP, certs, secrets).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

kubectl -n load delete job --all --ignore-not-found >/dev/null 2>&1 || true
for c in blue green; do helm -n "$NS" uninstall "kc-$c" --wait >/dev/null 2>&1 || true; done
kubectl -n "$NS" delete ingress kc-freeze --ignore-not-found >/dev/null
kubectl -n "$NS" delete job -l app=config-cli --ignore-not-found >/dev/null
delete_dbs
kubectl -n "$NS" delete configmap kc-state --ignore-not-found >/dev/null
rm -f out/events.jsonl out/k6.jsonl
create_db pg-1
log "reset: no Keycloak, fresh pg-1"
