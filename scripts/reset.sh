#!/usr/bin/env bash
# reset.sh: back to an empty Keycloak namespace with a fresh kc1 schema, so each demo case starts from scratch.
# Keeps the platform (ingress, Oracle, legacy IdP, certs, secrets).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="reset"
check_profile # before the teardown: a wrong PROFILE must not delete anything first

log "reset: removing load, both colors, freeze, config jobs, all DB schemas (Oracle stays up)"
kubectl -n load delete job --all --ignore-not-found >/dev/null 2>&1 || true
for c in blue green; do helm -n "$NS" uninstall "kc-$c" --wait >/dev/null 2>&1 || true; done
kubectl -n "$NS" delete ingress kc-freeze --ignore-not-found >/dev/null # clusters from before kc-gate
kubectl apply -f k8s/edge/kc-gate.yaml >/dev/null && gate_select "$(kc_selector blue)" # unfrozen; install starts blue
kubectl -n "$NS" delete job -l app=config-cli --ignore-not-found >/dev/null
delete_dbs
kubectl -n "$NS" delete configmap kc-state --ignore-not-found >/dev/null
rm -f out/events.jsonl out/k6.jsonl out/apps.jsonl out/kc-*.log
create_db kc1
log "reset: no Keycloak, fresh kc1 schema"
