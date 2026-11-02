#!/usr/bin/env bash
# probe dcr: anonymous dynamic client registration. Keycloak's default anonymous policy "Trusted Hosts" (empty list)
# must refuse it, also with a spoofed X-Forwarded-For. A client that does get created is a finding: it is deleted
# right away (admin API) and reported.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

n=0
for realm in demo master; do
  base=https://kc-net1.localtest.me/keycloak/realms/$realm/clients-registrations
  for ep in openid-connect default; do
    for xff in "" "X-Forwarded-For: 127.0.0.1"; do
      name=secprobe-dcr-$RANDOM
      if [[ $ep == default ]]; then body="{\"clientId\":\"$name\"}"; else
        body="{\"client_name\":\"$name\",\"redirect_uris\":[\"https://evil.example/cb\"]}"; fi
      r=$(pub -H 'Content-Type: application/json' ${xff:+-H "$xff"} -w '\n%{http_code}' -d "$body" "$base/$ep")
      code=${r##*$'\n'} n=$((n + 1))
      [[ $code == 201 ]] || { [[ $code == 40[13] ]] || fail "$realm/$ep ${xff:-}: unexpected HTTP $code: ${r:0:120}"; continue; }
      id=$(jq -r '.client_id // .clientId' <<<"${r%$'\n'*}")
      fail "$realm/$ep ${xff:-}: ANONYMOUS REGISTRATION SUCCEEDED (client $id); deleting it"
      uuid=$(admin_api GET "/realms/$realm/clients?clientId=$id" | jq -r '.[0].id')
      if admin_api DELETE "/realms/$realm/clients/$uuid" >/dev/null; then log "deleted client $id"
      else fail "could not delete client $id in $realm: delete it by hand"; fi
    done
  done
  hosts=$(admin_api GET "/realms/$realm/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" |
    jq -r '[.[] | select(.subType == "anonymous" and .providerId == "trusted-hosts") | .config["trusted-hosts"][]?] | join(",")')
  [[ -z $hosts ]] || warn "$realm anonymous Trusted Hosts policy lists: $hosts"
done
finish "$n anonymous registrations (demo+master, openid-connect+default, with/without X-Forwarded-For) refused with 401/403; Trusted Hosts lists empty"
