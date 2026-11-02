#!/usr/bin/env bash
# probe redirect: open redirect. Variations of redirect_uri (client k6-app, exact https://app.localtest.me/cb) and of
# post_logout_redirect_uri (wildcard https://app.localtest.me/*) must be rejected, never redirected to.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

kc=https://kc-net1.localtest.me/keycloak/realms/demo/protocol/openid-connect
good=https://app.localtest.me/cb
bad=(https://evil.example/cb https://app.localtest.me.evil.example/cb https://app.localtest.me@evil.example/cb
  'https://app.localtest.me\@evil.example/cb' https://app.localtest.me%40evil.example/cb //evil.example/cb
  https://app.localtest.me/cb/../../evil https://app.localtest.me/cb%2F..%2F..%2Fevil https://app.localtest.me/cbx
  https://app.localtest.me/cb/extra http://app.localtest.me/cb https://app.localtest.me:444/cb
  'https://app.localtest.me/cb?next=https://evil.example' 'https://app.localtest.me/*' 'https://*.localtest.me/cb')
n=0
# auth <redirect_uri> -> "<http code> <location> <page message>"
auth() {
  local r body
  body=$(pub -H 'Accept: text/html' -w '\n%{http_code} %{redirect_url}' -G "$kc/auth" -d client_id=k6-app \
    -d response_type=code -d scope=openid -d state=s1 --data-urlencode "redirect_uri=$1")
  r=${body##*$'\n'}
  echo "$r $(grep -o 'Invalid parameter: redirect_uri' <<<"$body" | head -1)"
}
ctl=$(auth "$good")
[[ $ctl != *"Invalid parameter"* ]] || fail "control: the registered redirect_uri is rejected too (probe broken?): $ctl"
for u in "${bad[@]}"; do
  n=$((n + 1)); r=$(auth "$u")
  [[ $r == "400  Invalid parameter: redirect_uri" ]] || fail "redirect_uri=$u not rejected: $r"
done

# logout <post_logout_redirect_uri> -> "<http code> <location>"
logout() {
  pub -o /dev/null -w '%{http_code} %{redirect_url}' -G "$kc/logout" -d client_id=k6-app \
    --data-urlencode "post_logout_redirect_uri=$1"
}
ctl=$(logout https://app.localtest.me/bye)
[[ $ctl == "302 https://app.localtest.me/bye"* ]] || fail "control: registered post_logout_redirect_uri not honoured (probe broken?): $ctl"
for u in https://evil.example/ https://app.localtest.me.evil.example/ https://app.localtest.me@evil.example/ \
  'https://app.localtest.me\@evil.example/' https://app.localtest.me%40evil.example/ //evil.example/ \
  http://app.localtest.me/ https://app.localtest.me:444/ https:evil.example 'https://app.localtest.me/..%2F@evil.example'; do
  n=$((n + 1)); r=$(logout "$u")
  [[ $r == 400* ]] || fail "post_logout_redirect_uri=$u not rejected: $r"
done
finish "$n redirect variations rejected (auth 400 'Invalid parameter: redirect_uri', logout 400); registered URIs still work"
