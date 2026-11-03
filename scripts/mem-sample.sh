#!/usr/bin/env bash
# mem-sample.sh [interval]: every N s (default 15), one JSON line per pod with its working-set memory and CPU
# (millicores, kubelet summary API; KinD has no metrics-server) plus one line per KinD node container. Runs on the
# host. Ctrl-C to stop. Used to size the laptop profile from measured peaks and to record the load rate's CPU cost
# (load/RATE.md).
set -euo pipefail
k() { MSYS_NO_PATHCONV=1 docker exec kc-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
while :; do
  t=$(date -u +%FT%TZ)
  for n in $(k get nodes -o name); do
    k get --raw "/api/v1/nodes/${n#node/}/proxy/stats/summary" 2>/dev/null \
      | jq -c --arg t "$t" '.pods[] | {t: $t, ns: .podRef.namespace, pod: .podRef.name, mib: ((.memory.workingSetBytes // 0) / 1048576 | floor), mcpu: ((.cpu.usageNanoCores // 0) / 1000000 | floor)}'
  done
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | awk -v t="$t" '$1 ~ /^kc-|jenkins/ {
    printf "{\"t\":\"%s\",\"ns\":\"docker\",\"pod\":\"%s\",\"usage\":\"%s\"}\n", t, $1, $2}'
  sleep "${1:-15}"
done
