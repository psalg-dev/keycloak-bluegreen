#!/usr/bin/env bash
# probe tokens: token/session behaviour, in a throwaway realm (no demo user is touched).
#  - a token from net1 is rejected at net2 (issuer binding: one issuer per host)
#  - alg=none and HS256-signed-with-the-RSA-public-key ("key confusion") tokens are rejected by userinfo
#  - after RP-initiated logout (end-session with id_token_hint) the refresh token stays rejected
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

tmp_realm
n1=https://kc-net1.localtest.me/keycloak/realms/$TMP_REALM/protocol/openid-connect
n2=https://kc-net2.localtest.me/keycloak/realms/$TMP_REALM/protocol/openid-connect
# client auth + user password go in on stdin (-K -), never on a command line
creds() { printf 'user = "probe:%s"\ndata-urlencode = "password=%s"\n' "$TMP_SECRET" "$TMP_PW"; }
tok=$(creds | pub -K - -d grant_type=password -d username=probe -d scope=openid "$n1/token")
at=$(jq -r .access_token <<<"$tok") rt=$(jq -r .refresh_token <<<"$tok") idt=$(jq -r .id_token <<<"$tok")
[[ ${#at} -gt 100 ]] || { fail "no token from the throwaway realm: $(jq -c 'del(.access_token,.refresh_token,.id_token)' <<<"$tok")"; finish ""; }
userinfo() { pub -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $2" "$1/userinfo"; }
refresh() { printf 'user = "probe:%s"\n' "$TMP_SECRET" | pub -K - -d grant_type=refresh_token -d "refresh_token=$2" "$1/token" | jq -r '.error // "REFRESHED"'; }

code=$(userinfo "$n1" "$at"); [[ $code == 200 ]] || fail "control: valid token rejected at net1 userinfo: $code (probe broken?)"
code=$(userinfo "$n2" "$at"); [[ $code == 401 ]] || fail "net1 access token at net2 userinfo: HTTP $code (want 401)"
e=$(refresh "$n2" "$rt"); [[ $e == invalid_grant ]] || fail "net1 refresh token at net2: $e (want invalid_grant)"

payload=$(cut -d. -f2 <<<"$at")
none=$(printf '{"alg":"none","typ":"JWT"}' | b64url).$payload.
code=$(userinfo "$n1" "$none"); [[ $code == 401 ]] || fail "alg=none token at userinfo: HTTP $code (want 401)"
# Key confusion: HS256 with the realm's RS256 public key (PEM, as served in the JWKS x5c) as the HMAC secret.
kid=$(jwt_part "$at" 1 | jq -r .kid)
pem=$(pub "$n1/certs" | jq -r --arg k "$kid" '.keys[] | select(.kid == $k) | .x5c[0]' |
  fold -w64 | { echo '-----BEGIN CERTIFICATE-----'; cat; echo '-----END CERTIFICATE-----'; } | openssl x509 -pubkey -noout)
input=$(printf '{"alg":"HS256","typ":"JWT","kid":"%s"}' "$kid" | b64url).$payload
hexkey=$(printf '%s\n' "$pem" | od -An -v -tx1 | tr -d ' \n')
sig=$(printf '%s' "$input" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hexkey" -binary | b64url)
code=$(userinfo "$n1" "$input.$sig"); [[ $code == 401 ]] || fail "HS256 key-confusion token at userinfo: HTTP $code (want 401)"

# RP-initiated logout, then the refresh token (and the access token's session) must be dead.
e=$(refresh "$n1" "$rt"); [[ $e == REFRESHED ]] || fail "control: refresh before logout: $e (probe broken?)"
lo=$(pub -o /dev/null -w '%{http_code}' -G "$n1/logout" --data-urlencode "id_token_hint=$idt" -d client_id=probe)
e=$(refresh "$n1" "$rt"); [[ $e == invalid_grant ]] || fail "refresh token after RP-initiated logout (HTTP $lo): $e (want invalid_grant)"
code=$(userinfo "$n1" "$at"); [[ $code == 401 ]] || fail "access token after logout at userinfo: HTTP $code (want 401)"
finish "net1 token rejected at net2 (userinfo 401, refresh invalid_grant); alg=none + HS256 key confusion -> 401; after RP logout (HTTP $lo) refresh invalid_grant, userinfo 401"
