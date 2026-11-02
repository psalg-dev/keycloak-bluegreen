#!/usr/bin/env bash
# check-login.sh: real brokered logins through the public URLs (ingress -> Keycloak -> legacy IdP form -> Keycloak
# first-broker-login -> code exchange), like a browser. Proves the IdP configs, auto-link and the issuer per network:
#   user0042 via net1 -> existing user, iss kc-net1
#   user0042 via net2 -> SAME user id (auto-linked), iss kc-net2, now 2 federated links
#   user4500 via net2 -> created on first login, tenant t0
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

ip=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$CLUSTER-control-plane")
resolve=(); for h in kc-net1 kc-net2 legacy-net1 legacy-net2; do resolve+=(--resolve "$h.localtest.me:443:$ip"); done
app_secret=$(kubectl -n "$NS" get secret k6-app -o jsonpath='{.data.secret}' | base64 -d)
user_pw=$(kubectl -n legacy get secret legacy-idp -o jsonpath='{.data.user-password}' | base64 -d)
body=$(mktemp)

jwt() { local p; p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+'); while ((${#p} % 4)); do p+="="; done; base64 -d <<<"$p"; }

# login <net> <user> -> id_token claims JSON on stdout
login() {
  local net=$1 user=$2 jar code loc url csrf
  jar=$(mktemp)
  local c=(curl -s --cacert out/certs/ca.crt "${resolve[@]}" -b "$jar" -c "$jar" -H 'Accept: text/html' -o "$body" -w '%{http_code} %{redirect_url}')
  local kc=https://kc-$net.localtest.me/keycloak/realms/demo cb=https://app.localtest.me/cb
  url="$kc/protocol/openid-connect/auth?client_id=k6-app&response_type=code&scope=openid%20tenant&state=s1&kc_idp_hint=legacy-$net&redirect_uri=$cb"
  # follow [curl args for the first request]: follow redirects until the app callback or a page (left in $body)
  follow() { while :; do
      read -r code loc < <("${c[@]}" "$@" "$url"); set --
      [[ $loc == "$cb"* ]] && { url=$loc; return; }
      [[ $code == 30? ]] || return 0; url=$loc; done; }
  follow # -> legacy login form
  csrf=$(grep -o 'name="_csrf"[^>]*value="[^"]*"' "$body" | sed 's/.*value="//; s/"$//') || die "$net/$user: no legacy login form (last: $url)"
  url=https://legacy-$net.localtest.me/login
  follow --data-urlencode "username=$user" --data-urlencode "password=$user_pw" --data-urlencode "_csrf=$csrf"
  [[ $url == "$cb"* ]] || die "$net/$user: stopped at $url: $(grep -o '<title>[^<]*' "$body" | head -1)"
  code=${url#*code=}; code=${code%%&*}
  local tok; tok=$(curl -sf --cacert out/certs/ca.crt "${resolve[@]}" -u "k6-app:$app_secret" -d grant_type=authorization_code \
    -d "code=$code" -d "redirect_uri=$cb" "$kc/protocol/openid-connect/token") || die "$net/$user: code exchange failed"
  jwt "$(jq -r .id_token <<<"$tok")"
  rm -f "$jar"
}

uid() { admin_api GET "/realms/demo/users?username=$1&exact=true" | jq -r '.[0].id'; }
links() { admin_api GET "/realms/demo/users/$(uid "$1")/federated-identity" | jq -r '[.[].identityProvider] | sort | join(",")'; }

a=$(login net1 user0042); b=$(login net2 user0042); n=$(login net2 user4500)
expect() { [[ $2 == "$3" ]] || die "$1: got '$2' want '$3'"; }
expect "net1 iss" "$(jq -r .iss <<<"$a")" https://kc-net1.localtest.me/keycloak/realms/demo
expect "net2 iss" "$(jq -r .iss <<<"$b")" https://kc-net2.localtest.me/keycloak/realms/demo
expect "net1 sub = user id" "$(jq -r .sub <<<"$a")" "$(uid user0042)"
expect "net2 sub = same user" "$(jq -r .sub <<<"$b")" "$(jq -r .sub <<<"$a")"
expect "user0042 tenant" "$(jq -r .tenant <<<"$a")" t2
expect "user0042 links" "$(links user0042)" legacy-net1,legacy-net2
expect "user4500 sub = created user" "$(jq -r .sub <<<"$n")" "$(uid user4500)"
expect "user4500 tenant" "$(jq -r .tenant <<<"$n")" t0
log "OK check-login: net1+net2 issuers, auto-link keeps sub, new user created on first broker login"
