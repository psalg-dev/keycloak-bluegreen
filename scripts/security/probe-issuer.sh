#!/usr/bin/env bash
# probe issuer: issuer forgery at the edge. With hostname-strict=false Keycloak (and the legacy IdP) build the issuer
# from the forwarded host, so no client-controlled header sent through the ingress may change the discovery issuer,
# and a Host that only differs in case, trailing dot or port is refused (421), never answered with another issuer.
# An unknown Host must not reach Keycloak at all.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

spoofs=('X-Forwarded-Host: evil.example' 'X-Forwarded-Proto: http' 'X-Forwarded-Port: 8443'
  'Forwarded: host=evil.example;proto=http' 'X-Original-Host: evil.example' 'X-Forwarded-Server: evil.example'
  'X-Forwarded-Prefix: /evil')
# Non-canonical Host (HOST / UPPER replaced per target): nginx routes it to the host's server (case-insensitive, trailing
# dot and port ignored) and used to forward it raw. The edge must answer exactly 421 (server-snippet, scripts/up.sh);
# any other answer, an issuer above all, is a FAIL.
hosts=('HOST:8443' 'HOST:443' 'UPPER' 'HOST.')
n=0
# check <host> <discovery url> <expected issuer>
check() {
  local host=$1 url=$2 want=$3 s hdr got r
  for s in "" "${spoofs[@]}"; do
    got=$(pub ${s:+-H "$s"} "$url" | jq -r .issuer 2>/dev/null) || got="(no JSON)"
    n=$((n + 1))
    [[ $got == "$want" ]] || fail "$host ${s:-(no spoof)} -> issuer '$got'"
  done
  for s in "${hosts[@]}"; do
    hdr=${s//UPPER/${host^^}}; hdr="Host: ${hdr//HOST/$host}"
    r=$(pub -H "$hdr" -w '\n%{http_code}' "$url")
    n=$((n + 1))
    [[ ${r##*$'\n'} == 421 && $r != *issuer* ]] || fail "$host $hdr -> HTTP ${r##*$'\n'}, want 421: ${r:0:80}"
  done
}
for h in "${KC_HOSTS[@]}"; do
  for realm in demo master; do
    check "$h" "https://$h/keycloak/realms/$realm/.well-known/openid-configuration" "https://$h/keycloak/realms/$realm"
  done
done
for h in "${LEGACY_HOSTS[@]}"; do check "$h" "https://$h/.well-known/openid-configuration" "https://$h"; done

# Unknown host: as Host header behind a known SNI, and as SNI + Host (ingress default server, fake cert).
d=/keycloak/realms/demo/.well-known/openid-configuration
a=$(pub -H 'Host: evil.example' -w '\n%{http_code}' "https://kc-net1.localtest.me$d")
b=$(curl -sk --max-time 20 --resolve "evil.example:443:$NODE_IP" -w '\n%{http_code}' "https://evil.example$d")
for r in "$a" "$b"; do
  n=$((n + 1))
  [[ ${r##*$'\n'} == 404 && $r != *issuer* ]] || fail "unknown host reached Keycloak: HTTP ${r##*$'\n'} ${r:0:80}"
done
finish "$n issuer checks: no header changes the issuer; non-canonical Host gets 421; unknown host gets the ingress 404"
