#!/usr/bin/env bash
# load.sh start|stop|collect: the k6 Job in namespace `load` (k8s/k6-job.yaml.tpl, script load/k6/flows.js).
#   start    copies the Secrets it needs into `load`, (re)creates ConfigMap k6-flows and Job k6
#   collect  writes k6's JSON lines (schema: top of flows.js) to out/k6.jsonl; works while k6 runs
#   stop     stops k6 gracefully (SIGINT), collects, deletes the Job
# Env: LOGIN_RATE (5) REFRESH_VUS (10) LOGOUT_VUS (4) DURATION (10m)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="load test"

LNS=load
# Secret -> namespace it is copied from. ponytail: k6-app assumed in ns keycloak (Slice 2 owns it).
declare -A SRC=([legacy-idp]=legacy [demo-ca]=keycloak [k6-app]=keycloak)

copy_secret() { # <name> <from-ns>: always re-synced; a copy made once went stale when the demo CA was rotated
  kubectl -n "$2" get secret "$1" -o json \
    | jq --arg ns "$LNS" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns}}' \
    | kubectl apply -f - >/dev/null || die "secret $1 not found in ns $2 (needed in ns $LNS)"
}

pod() { kubectl -n "$LNS" get pod -l job-name=k6 -o name | head -1; }

collect() {
  local p; p=$(pod); [[ -n $p ]] || die "no k6 pod in ns $LNS"
  mkdir -p out
  kubectl -n "$LNS" exec "$p" -- cat /out/k6.log | jq -cR 'fromjson? | select(type == "object" and has("t_start"))' > out/k6.jsonl
  log "collected $(wc -l < out/k6.jsonl) k6 lines -> out/k6.jsonl"
}

case ${1:-} in
start)
  kubectl create namespace "$LNS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  for s in "${!SRC[@]}"; do copy_secret "$s" "${SRC[$s]}"; done
  kubectl -n "$LNS" create configmap k6-flows --from-file=flows.js=load/k6/flows.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$LNS" delete job k6 --ignore-not-found --wait >/dev/null
  LOGIN_RATE=${LOGIN_RATE:-5} REFRESH_VUS=${REFRESH_VUS:-10} LOGOUT_VUS=${LOGOUT_VUS:-4} DURATION=${DURATION:-10m} \
    envsubst < k8s/k6-job.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$LNS" wait pod -l job-name=k6 --for=condition=Ready --timeout=120s >/dev/null || die "k6 pod not Ready"
  log "k6 started (rate ${LOGIN_RATE:-5}/s, ${DURATION:-10m})"
  ;;
collect) collect ;;
stop)
  p=$(pod); [[ -n $p ]] || die "no k6 pod in ns $LNS"
  event load_stop # the gate ignores status-0 lines after this: requests k6 itself aborts on SIGINT
  kubectl -n "$LNS" exec "$p" -- pkill -INT k6 2>/dev/null || true # already finished is fine
  for _ in $(seq 60); do
    kubectl -n "$LNS" exec "$p" -- grep -q '^k6 exited' /out/k6.log 2>/dev/null && break
    sleep 1
  done
  collect
  kubectl -n "$LNS" delete job k6 --wait >/dev/null
  log "k6 stopped"
  ;;
*) die "usage: load.sh start|stop|collect" ;;
esac
