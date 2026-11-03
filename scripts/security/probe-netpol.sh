#!/usr/bin/env bash
# probe netpol: direct-to-pod bypass. A pod that reaches Keycloak without the ingress can set X-Forwarded-Host itself,
# i.e. forge the issuer. The chart NetworkPolicy must stop unlabelled pods (Services and pod IPs, http + management
# port); a pod labelled kc-<color>-keycloak-client=true in ns keycloak gets through: that label is the trust boundary.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

# Targets: kc-active + every color that has running pods (a Service without endpoints would look "blocked").
targets=("kc-active.$NS:80")
for color in blue green; do
  ips=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=kc-$color,app.kubernetes.io/component=keycloak" \
    --field-selector status.phase=Running -o jsonpath='{.items[*].status.podIP}')
  [[ -n $ips ]] || continue
  ip=${ips%% *}
  targets+=("kc-$color-keycloak.$NS:80" "kc-$color-keycloak-metrics.$NS:9000" "$ip:8080" "$ip:9000")
done
labels=kc-blue-keycloak-client=true,kc-green-keycloak-client=true # both: the active color may flip mid-run

# from <ns> <labels|-> -> "<target> <http code>" per target (000 = no connection), then the issuer seen via kc-active
# with a forged X-Forwarded-Host.
from() {
  local pod=secprobe-np-$RANDOM
  # shellcheck disable=SC2016 # expanded in the pod
  local script='for t in $T; do echo "$t $(curl -s -o /dev/null -m 4 -w %{http_code} http://$t/keycloak/realms/master)"; done
    echo "forged $(curl -s -m 4 -H "X-Forwarded-Host: evil.example" http://kc-active/keycloak/realms/demo/.well-known/openid-configuration | sed -n "s/.*\"issuer\":\"\([^\"]*\)\".*/\1/p")"'
  kubectl -n "$1" run "$pod" --rm -i --restart=Never --quiet --image="$CURL_IMAGE" \
    ${2:+--labels="$2"} --env="T=${targets[*]}" --command -- sh -c "$script" 2>/dev/null
}
open() { awk '$1 != "forged" && $2 != "000" {print $1 "=" $2}' <<<"$1" | xargs; }
# ran <output>: a pod that never ran must not read as "everything blocked"
ran() { [[ $(grep -cE '^[^ ]+ [0-9]{3}$' <<<"$1") == "${#targets[@]}" ]] || { fail "probe pod gave no result: ${1:0:200}"; finish ""; }; }

out=$(from "$NS" "")
ran "$out"
[[ -z $(open "$out") ]] || fail "unlabelled pod in ns $NS reached Keycloak: $(open "$out")"
out=$(from default "$labels")
ran "$out"
[[ -z $(open "$out") ]] || fail "labelled pod in ns default reached Keycloak: $(open "$out")"
out=$(from "$NS" "$labels")
reach=$(open "$out")
[[ $reach == *"kc-active.$NS:80="* ]] || fail "labelled pod in ns $NS cannot reach kc-active (probe broken?): $out"
forged=$(awk '$1 == "forged" {print $2}' <<<"$out")
finish "unlabelled pod (ns $NS) and labelled pod (ns default) blocked on ${#targets[@]} targets; labelled pod in ns $NS reaches ${reach// /, } and can forge the issuer ('$forged'): the label is the trust boundary"
