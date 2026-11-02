#!/usr/bin/env bash
# check-cluster.sh <color>: 3 Ready pods on 3 distinct zones, one JGroups view of size 3 with only this color's pods.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
color=${1:?color}
sel="app.kubernetes.io/name=keycloak,app.kubernetes.io/instance=kc-$color"

pods=$(kubectl -n "$NS" get pods -l "$sel" -o json)
ready=$(jq '[.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))] | length' <<<"$pods")
[[ $ready == 3 ]] || die "kc-$color: $ready/3 pods Ready"

zones=$(jq -r '.items[].spec.nodeName' <<<"$pods" | while read -r n; do
  kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'; done | sort -u | wc -l)
[[ $zones == 3 ]] || die "kc-$color: pods span $zones zones, want 3"

# ISPN000094: "Received new cluster view for channel <name>: [<coord>|<n>] (<size>) [<members>]"
# 25 has no cluster-name option (channel stays ISPN); its colors are kept apart by DNS_PING on the release's headless
# Service, which the member check below proves.
chan=kc-$color; [[ $(jq -r '.items[0].spec.containers[0].image' <<<"$pods") == *:25.* ]] && chan=ISPN
for p in $(jq -r '.items[].metadata.name' <<<"$pods"); do
  view=$(kubectl -n "$NS" logs "$p" | grep -o 'ISPN000094[^"]*' | tail -1)
  [[ -n $view ]] || die "$p: no cluster view logged"
  grep -q "channel $chan:" <<<"$view" || die "$p: wrong channel: $view"
  grep -q ') (3) \[\|] (3) \[' <<<"$view" || die "$p: view size != 3: $view"
  members=${view##*(3) [}; members=${members%%]*}; members=$(tr ',' '\n' <<<"$members")
  if grep -v "kc-$color-" <<<"$members" | grep -q .; then die "$p: foreign member in view: $view"; fi
done

# Direct access must be refused for unlabelled pods (else they could forge the issuer via X-Forwarded-Host).
direct=$(kubectl -n "$NS" run "np-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.23.0 --labels=app=np-check \
  --command -- sh -c "curl -s -m 5 -o /dev/null -w %{http_code} http://kc-$color-keycloak.$NS/keycloak/realms/master || true")
[[ $direct == 000 ]] || die "kc-$color: unlabelled pod reached Keycloak directly (HTTP $direct); NetworkPolicy not enforced"

[[ $(state activeColor) == "$color" ]] || log "note: kc-state.activeColor=$(state activeColor)"
log "OK kc-$color: 3/3 Ready, 3 zones, one view of 3, direct access blocked"
