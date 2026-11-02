#!/usr/bin/env bash
# probe admin: admin surface on the public hosts. Whether /keycloak/admin (console + REST) may be public is a decision:
# EXPECT_ADMIN_PUBLIC=true (default for now) reports it as WARN, false makes it a FAIL. The management interface
# (metrics, health on :9000) must never be public.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

expect=${EXPECT_ADMIN_PUBLIC:-true}
public=()
for h in "${KC_HOSTS[@]}"; do
  b=https://$h/keycloak
  console=$(pub -o /dev/null -w '%{http_code}' "$b/admin/master/console/")
  rest=$(pub -o /dev/null -w '%{http_code}' "$b/admin/realms")
  [[ $console == 200 || $rest == 401 ]] && public+=("$h (console $console, REST $rest)")
  for p in metrics health health/ready health/live; do
    code=$(pub -o /dev/null -w '%{http_code}' "$b/$p")
    [[ $code == 404 ]] || fail "$h/keycloak/$p is public: HTTP $code"
  done
done
if ((${#public[@]})); then
  if [[ $expect == true ]]; then warn "admin console + REST public on ${public[*]} (EXPECT_ADMIN_PUBLIC=true: decision pending)"
  else fail "admin console + REST public on ${public[*]} (EXPECT_ADMIN_PUBLIC=false)"; fi
elif [[ $expect == true ]]; then fail "admin surface not public although EXPECT_ADMIN_PUBLIC=true (edge changed?)"
fi
finish "admin surface not public (EXPECT_ADMIN_PUBLIC=$expect); metrics/health not public"
