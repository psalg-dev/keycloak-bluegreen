#!/usr/bin/env bash
# load.sh start|stop|collect: the k6 Job in namespace `load` (k8s/k6-job.yaml.tpl, script load/k6/flows.js).
#   start    copies the Secrets it needs into `load`, (re)creates ConfigMap k6-flows and Job k6
#   collect  writes k6's JSON lines (schema: top of flows.js) to out/k6.jsonl and the test apps' JSON lines
#            (docs/test-apps-contract.md) since the load started to out/apps.jsonl; works while k6 runs
#   stop     stops k6 gracefully (SIGINT), collects, deletes the Job
# Env: LOGIN_RATE (5; PROFILE=laptop 2) REFRESH_VUS (10) LOGOUT_VUS (4) APP_VUS (6, laptop 3; 0 when ns apps does not exist) DURATION (60m: a cap only, cool-down stops k6; 10m ran out mid-switch in build #11)
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
  collect_apps "$p"
}

# collect_apps <k6-pod>: testclient + testresource JSON lines since the k6 pod started (= load start) -> out/apps.jsonl.
# Pods found via each Service's selector (the contract names only the Services). No ns apps: empty file, gate SKIPs.
# ponytail: `kubectl logs` serves only the CURRENT log file, and kubelet rotates container logs at 10 MiB
# (containerLogMaxSize), so a long or chatty run silently loses its oldest app lines (a pod restart loses the previous
# container's). The gate judges back-channel/front-channel delivery only inside the time range it got. If that bites:
# write to a file on an emptyDir like k6 does (k8s/k6-job.yaml.tpl), or ship logs.
collect_apps() {
  : > out/apps.jsonl
  kubectl get namespace apps >/dev/null 2>&1 || { log "WARN: no namespace apps: out/apps.jsonl is empty"; return 0; }
  local since app sel
  since=$(kubectl -n "$LNS" get "$1" -o jsonpath='{.status.startTime}')
  for app in testclient testresource; do
    sel=$(kubectl -n apps get svc "$app" -o json 2>/dev/null | jq -r '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")') || true
    [[ -n $sel ]] || { log "WARN: no Service $app (or no selector) in ns apps: its lines are missing"; continue; }
    # --tail=-1: with a selector kubectl logs defaults to the last 10 lines
    kubectl -n apps logs -l "$sel" --since-time="$since" --tail=-1 --max-log-requests=5 \
      | jq -cR 'fromjson? | select(type == "object" and has("app"))' >> out/apps.jsonl \
      || log "WARN: kubectl logs for $app failed: its lines are missing"
  done
  log "collected $(wc -l < out/apps.jsonl) app lines (since $since) -> out/apps.jsonl"
}

case ${1:-} in
start)
  kubectl create namespace "$LNS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  for s in "${!SRC[@]}"; do copy_secret "$s" "${SRC[$s]}"; done
  kubectl -n "$LNS" create configmap k6-flows --from-file=flows.js=load/k6/flows.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$LNS" delete job k6 --ignore-not-found --wait >/dev/null
  # no test apps yet: no app scenario, so the run stays judgeable (its logins would all fail on the ingress 404)
  if [[ -z ${APP_VUS:-} ]] && ! kubectl get namespace apps >/dev/null 2>&1; then
    APP_VUS=0; log "WARN: no namespace apps: k6 scenario app off (APP_VUS=0)"
  fi
  : "${LOGIN_RATE:=$LOGIN_RATE_DEFAULT}" "${APP_VUS:=$APP_VUS_DEFAULT}" # per PROFILE (lib/kc.sh)
  LOGIN_RATE=$LOGIN_RATE REFRESH_VUS=${REFRESH_VUS:-10} LOGOUT_VUS=${LOGOUT_VUS:-4} APP_VUS=$APP_VUS DURATION=${DURATION:-60m} \
    envsubst < k8s/k6-job.yaml.tpl | kubectl apply -f - >/dev/null
  kubectl -n "$LNS" wait pod -l job-name=k6 --for=condition=Ready --timeout=120s >/dev/null || die "k6 pod not Ready"
  log "k6 started (rate $LOGIN_RATE/s, app VUs $APP_VUS, ${DURATION:-60m})"
  ;;
collect) collect ;;
stop)
  p=$(pod); [[ -n $p ]] || die "no k6 pod in ns $LNS"
  # k6 must still be running: if it ended on its own, part of the run (maybe the cutover) had no load at all
  ended=$(kubectl -n "$LNS" exec "$p" -- grep '^k6 exited' /out/k6.log 2>/dev/null || true)
  event load_stop # the gate ignores status-0 lines after this: requests k6 itself aborts on SIGINT
  kubectl -n "$LNS" exec "$p" -- pkill -INT k6 2>/dev/null || true # already finished is fine
  for _ in $(seq 60); do
    kubectl -n "$LNS" exec "$p" -- grep -q '^k6 exited' /out/k6.log 2>/dev/null && break
    sleep 1
  done
  collect
  kubectl -n "$LNS" delete job k6 --wait >/dev/null
  [[ -z $ended ]] || die "k6 had ended on its own before the stop ($ended): DURATION too short, the run was not under load to the end"
  log "k6 stopped"
  ;;
*) die "usage: load.sh start|stop|collect" ;;
esac
