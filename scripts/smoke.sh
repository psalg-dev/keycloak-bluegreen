#!/usr/bin/env bash
# smoke.sh: from inside the cluster, via the public URL (CoreDNS rewrite -> ingress -> kc-active), with TLS verified
# against the demo CA: discovery issuer + an admin token for the bootstrap admin.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

base=https://kc.localtest.me/keycloak
pw=$(kubectl -n "$NS" get secret kc-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)
pod=smoke-$RANDOM
# The password goes in on stdin, never on a command line; $PW expands in the pod's shell.
# shellcheck disable=SC2016
out=$(kubectl -n "$NS" run "$pod" --rm -i --restart=Never --quiet --image=curlimages/curl:8.23.0 \
  --overrides='{"spec":{"volumes":[{"name":"ca","secret":{"secretName":"demo-ca"}}],"containers":[{"name":"'"$pod"'","image":"curlimages/curl:8.23.0","stdin":true,"stdinOnce":true,
    "command":["sh","-c","read -r PW; curl -sf --cacert /ca/ca.crt '"$base"'/realms/master/.well-known/openid-configuration; echo; curl -sf --cacert /ca/ca.crt -d grant_type=password -d client_id=admin-cli -d username=temp-admin --data-urlencode password=\"$PW\" '"$base"'/realms/master/protocol/openid-connect/token"],
    "volumeMounts":[{"name":"ca","mountPath":"/ca"}]}]}}' <<<"$pw")

issuer=$(head -1 <<<"$out" | jq -r .issuer)
[[ $issuer == "$base/realms/master" ]] || die "issuer from inside cluster: $issuer"
tail -1 <<<"$out" | jq -e '.access_token | length > 100' >/dev/null || die "no admin token"
log "OK smoke: in-cluster issuer $issuer, admin token issued"
