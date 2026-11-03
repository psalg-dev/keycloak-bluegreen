#!/usr/bin/env bash
# seed-users.sh [count]: test data, not config. Pre-links user0001..userN (default 4000) to legacy-net1, the way users
# that logged in before already exist in Keycloak. No credentials: users live in the legacy IdP.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="data"
count=${1:-4000} chunk=500
log "seeding $count linked users via partialImport ($chunk per request)"

for ((from = 1; from <= count; from += chunk)); do
  to=$((from + chunk - 1 < count ? from + chunk - 1 : count))
  jq -n --argjson from "$from" --argjson to "$to" '{ifResourceExists: "SKIP", users: [range($from; $to + 1) as $i
    | ("user" + ($i | tostring | if length < 4 then ("000" + .)[-4:] else . end)) as $u
    | {username: $u, enabled: true, email: ($u + "@legacy.example"), emailVerified: true,
       attributes: {tenant: ["t\($i % 10)"]},
       federatedIdentities: [{identityProvider: "legacy-net1", userId: $u, userName: $u}]}]}' \
    | admin_api POST /realms/demo/partialImport --data-binary @- >/dev/null || die "partialImport $from-$to"
done
n=$(admin_api GET /realms/demo/users/count)
((n >= count)) || die "seeded $count, Keycloak has $n users"
log "seeded: demo has $n users (user0001..user$(printf %04d "$count") linked to legacy-net1)"
