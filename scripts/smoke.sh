#!/usr/bin/env bash
# smoke.sh: from inside the cluster, via the public URLs (CoreDNS rewrite -> ingress -> kc-active), TLS verified against
# the demo CA. Per network host: discovery issuer follows the host, a spoofed X-Forwarded-Host cannot change it,
# and the config-cli service account gets a token (client_credentials; master admin-cli has no direct grants after the
# online stage).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

hosts=(kc-net1.localtest.me kc-net2.localtest.me)
secret=$(kubectl -n "$NS" get secret kc-config-cli -o jsonpath='{.data.secret}' | base64 -d)
pod=smoke-$RANDOM
# Pod prints "<key> <one-line json>" per check; parsing happens here with jq. The secret goes in on stdin only.
# shellcheck disable=SC2016
script='read -r S; for h in '"${hosts[*]}"'; do b=https://$h/keycloak/realms/master; c="curl -s --cacert /ca/ca.crt"
  echo "$h $($c $b/.well-known/openid-configuration)"
  echo "$h-spoof $($c -H "X-Forwarded-Host: evil.example" $b/.well-known/openid-configuration)"
  echo "$h-token $($c -d grant_type=client_credentials -d client_id=config-cli --data-urlencode client_secret="$S" $b/protocol/openid-connect/token)"
done'
out=$(kubectl -n "$NS" run "$pod" --rm -i --restart=Never --quiet --image=curlimages/curl:8.23.0 \
  --overrides="$(jq -nc --arg n "$pod" --arg s "$script" '{spec:{volumes:[{name:"ca",secret:{secretName:"demo-ca"}}],
    containers:[{name:$n,image:"curlimages/curl:8.23.0",stdin:true,stdinOnce:true,command:["sh","-c",$s],
    volumeMounts:[{name:"ca",mountPath:"/ca"}]}]}}')" <<<"$secret")

val() { awk -v k="$1" '$1==k {sub(/^[^ ]+ /, ""); print}' <<<"$out" | jq -r "$2" 2>/dev/null || true; }
for h in "${hosts[@]}"; do
  want="https://$h/keycloak/realms/master"
  got=$(val "$h" .issuer) spoof=$(val "$h-spoof" .issuer) tok=$(val "$h-token" '.access_token | length')
  [[ $got == "$want" ]] || die "$h issuer: '$got' want '$want'"
  [[ $spoof == "$want" ]] || die "$h: X-Forwarded-Host spoof changed issuer to '$spoof'"
  [[ ${tok:-0} -gt 100 ]] || die "$h: no config-cli token"
  log "OK smoke $h: issuer $got, X-Forwarded-Host spoof ignored, config-cli token"
done
