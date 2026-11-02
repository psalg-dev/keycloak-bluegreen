#!/usr/bin/env bash
# probe cookies: cookie flags and security headers on login pages.
#  - AUTH_SESSION_ID, KC_RESTART (master login page) and KEYCLOAK_IDENTITY, KEYCLOAK_SESSION (after a login in a
#    throwaway realm): Secure + SameSite on all, HttpOnly on all but KEYCLOAK_SESSION (read by keycloak-js by design)
#  - login page: CSP with frame-ancestors, X-Frame-Options, Referrer-Policy, X-Content-Type-Options, HSTS
#  - HSTS also from the ingress itself (its own 404). EXPECT_HSTS=false turns a missing HSTS into a WARN.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

# cookie <headers> <name> <want HttpOnly: yes|no>
cookie() {
  local c; c=$(grep -i "^set-cookie: $2=" <<<"$1" | head -1 | tr -d '\r')
  [[ -n $c ]] || { fail "cookie $2 not set"; return; }
  [[ ${c,,} == *";secure"* ]] || fail "cookie $2 without Secure: ${c:0:40}...${c: -60}"
  [[ ${c,,} == *";samesite="* ]] || fail "cookie $2 without SameSite"
  [[ $3 == no || ${c,,} == *";httponly"* ]] || fail "cookie $2 without HttpOnly"
  seen+=("$2")
}
seen=()
hsts=${EXPECT_HSTS:-true}
missing_hsts() { if [[ $hsts == true ]]; then fail "$1: no Strict-Transport-Security"; else warn "$1: no Strict-Transport-Security (EXPECT_HSTS=false)"; fi; }

for h in "${KC_HOSTS[@]}"; do
  login=https://$h/keycloak/realms/master/protocol/openid-connect/auth
  hdr=$(pub -D - -o /dev/null -G "$login" -d client_id=security-admin-console -d response_type=code -d scope=openid \
    -d code_challenge_method=S256 -d code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM \
    --data-urlencode "redirect_uri=https://$h/keycloak/admin/master/console/")
  grep -q '^HTTP/[0-9.]* 200' <<<"$hdr" || { fail "$h master login page: $(head -1 <<<"$hdr")"; continue; }
  cookie "$hdr" AUTH_SESSION_ID yes
  cookie "$hdr" KC_RESTART yes
  csp=$(grep -i '^content-security-policy:' <<<"$hdr" | tr -d '\r')
  [[ $csp == *frame-ancestors* ]] || fail "$h login page CSP without frame-ancestors: '${csp:-none}'"
  for x in x-frame-options referrer-policy x-content-type-options; do
    grep -qi "^$x:" <<<"$hdr" || fail "$h login page without $x"
  done
  grep -qi '^strict-transport-security: max-age=[1-9]' <<<"$hdr" || missing_hsts "$h login page"
  grep -qi '^strict-transport-security: max-age=[1-9]' <<<"$(pub -D - -o /dev/null "https://$h/")" || missing_hsts "$h ingress (non-Keycloak path /)"
done

# KEYCLOAK_IDENTITY / KEYCLOAK_SESSION only exist after a login: browser login in a throwaway realm.
tmp_realm
jar=$(mktemp)
page=$(pub -c "$jar" -b "$jar" -G "https://kc-net1.localtest.me/keycloak/realms/$TMP_REALM/protocol/openid-connect/auth" \
  -d client_id=probe -d response_type=code -d scope=openid --data-urlencode redirect_uri=https://app.localtest.me/cb)
action=$(grep -o 'action="[^"]*"' <<<"$page" | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
[[ $action == https://* ]] || { fail "no login form in throwaway realm"; finish ""; }
hdr=$(printf 'data-urlencode = "password=%s"\n' "$TMP_PW" |
  pub -K - -c "$jar" -b "$jar" -D - -o /dev/null --data-urlencode username=probe "$action")
grep -qi '^location: https://app.localtest.me/cb?.*code=' <<<"$hdr" || fail "throwaway realm login did not redirect with a code: $(grep -i '^location' <<<"$hdr")"
cookie "$hdr" KEYCLOAK_IDENTITY yes
cookie "$hdr" KEYCLOAK_SESSION no
rm -f "$jar"
finish "cookies $(printf '%s\n' "${seen[@]}" | sort -u | xargs): Secure, SameSite, HttpOnly (KEYCLOAK_SESSION is JS-readable by design); login pages send CSP frame-ancestors, X-Frame-Options, Referrer-Policy, nosniff, HSTS; ingress sends HSTS"
