#!/usr/bin/env bash
# probe grants: grant-type hardening of the relying party k6-app, behaviourally (kcwarden audits the per-client config
# flags of every client, job kc-kcwarden). k6-app must be confidential and accept only the authorization code flow:
# password grant, client_credentials and implicit (response_type=token / id_token) are refused.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

kc=https://kc-net1.localtest.me/keycloak/realms/demo/protocol/openid-connect
public=$(admin_api GET "/realms/demo/clients?clientId=k6-app" | jq -r '.[0].publicClient')
[[ $public == false ]] || fail "k6-app publicClient=$public, want confidential"

secret=$(kubectl -n "$NS" get secret k6-app -o jsonpath='{.data.secret}' | base64 -d)
# token <grant args...> -> OAuth error code. Client auth via stdin config (-K -), so the secret stays off the command line.
token() { pub -K - "$@" "$kc/token" <<<"user = \"k6-app:$secret\"" | jq -r '.error // "TOKEN ISSUED"'; }
e=$(token -d grant_type=password -d username=secprobe-nouser -d password=x -d scope=openid)
[[ $e == unauthorized_client ]] || fail "password grant for k6-app: $e (want unauthorized_client)"
e=$(token -d grant_type=client_credentials)
[[ $e == unauthorized_client ]] || fail "client_credentials for k6-app: $e (want unauthorized_client)"
e=$(pub -K - -d grant_type=client_credentials "$kc/token" <<<'user = "k6-app:wrong-secret"' | jq -r '.error // "TOKEN ISSUED"')
[[ $e == unauthorized_client || $e == invalid_client ]] || fail "wrong client secret: $e"

for rt in token 'id_token token' id_token; do
  loc=$(pub -o /dev/null -w '%{redirect_url}' -G "$kc/auth" -d client_id=k6-app -d scope=openid -d nonce=n1 \
    -d state=s1 --data-urlencode "response_type=$rt" --data-urlencode redirect_uri=https://app.localtest.me/cb)
  [[ $loc == *error=* && $loc != *access_token=* && $loc != *id_token=* ]] || fail "response_type=$rt not refused: ${loc:-no redirect}"
done
finish "k6-app confidential; password, client_credentials, implicit (token, id_token token, id_token) refused"
