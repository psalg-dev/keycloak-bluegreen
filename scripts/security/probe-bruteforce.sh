#!/usr/bin/env bash
# probe bruteforce: brute-force protection on (config, realms master + demo) and no user enumeration: bad logins return
# one uniform error whether or not the user exists, without a timing gap. Never against a real user: a non-existent
# name in master, and the throwaway realm's own user for the existing-user side.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

for realm in ${BRUTEFORCE_REALMS:-master demo}; do
  on=$(admin_api GET "/realms/$realm" | jq -r .bruteForceProtected)
  [[ $on == true ]] || fail "realm $realm bruteForceProtected=$on"
done
cfg=$FAILED FAILED=0 # behaviour below gets its own PASS line, visible even when the config check failed

# attempt <realm> <client> <secret|-> <user> -> "<http code> <error>/<description> <seconds>"
attempt() {
  local auth=() r
  [[ $3 == - ]] || auth=(-K -)
  r=$(printf 'user = "%s:%s"\n' "$2" "$3" | pub "${auth[@]}" -w '\n%{http_code} %{time_total}' -d grant_type=password \
    -d client_id="$2" -d "username=$4" -d "password=wrong-$RANDOM" \
    "https://kc-net1.localtest.me/keycloak/realms/$1/protocol/openid-connect/token")
  local tail=${r##*$'\n'}
  echo "${tail% *} $(jq -r '"\(.error)/\(.error_description)"' <<<"${r%$'\n'*}" | tr ' ' _) ${tail#* }"
}
msgs() { cut -d' ' -f1,2 <<<"$1" | sort -u | xargs; }
median() { cut -d' ' -f3 <<<"$1" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

nouser=secprobe-nouser-$RANDOM
m=$(for _ in 1 2 3 4 5 6; do attempt master admin-cli - "$nouser"; done)
[[ $(msgs "$m" | wc -w) == 2 ]] || fail "master: bad logins for a non-existent user are not uniform: $(msgs "$m")"

tmp_realm
ex=$(for _ in 1 2 3 4 5; do attempt "$TMP_REALM" probe "$TMP_SECRET" probe; done)
no=$(for _ in 1 2 3 4 5; do attempt "$TMP_REALM" probe "$TMP_SECRET" "$nouser"; done)
[[ $(msgs "$ex") == "$(msgs "$no")" ]] || fail "user enumeration by message: existing user '$(msgs "$ex")' vs unknown '$(msgs "$no")'"
te=$(median "$ex") tn=$(median "$no")
ratio=${BRUTEFORCE_TIMING_RATIO:-3}
if awk -v a="$te" -v b="$tn" -v r="$ratio" 'BEGIN {exit !((a > b ? a / b : b / a) > r && (a > b ? a - b : b - a) > 0.05)}'; then
  fail "user enumeration by timing: median bad login ${te}s for an existing user vs ${tn}s for an unknown one (> ${ratio}x)"
fi
((FAILED)) || pass "behaviour: uniform error '$(msgs "$m")'; existing vs unknown user: same message, median ${te}s vs ${tn}s"
exit $((FAILED || cfg))
