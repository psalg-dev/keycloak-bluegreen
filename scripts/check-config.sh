#!/usr/bin/env bash
# check-config.sh <stage>: the dropped-field check. keycloak-config-cli silently drops fields its Keycloak client
# library doesn't know (it is built against an older Keycloak), so every leaf of config/<stage>/*.json must be visible
# in Keycloak's own export. Arrays of objects are matched by their identity key (alias, clientId, name, ...).
# Values with $(...) substitutions (secrets) are skipped; so is "users" (service-account role mappings).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="verification"
stage=${1:?stage}

# shellcheck disable=SC2016 # jq program
subset='
# identity of an array element = all of these keys it has (IdP mappers share a name, so name+identityProviderAlias)
def ids: with_entries(select(.key | IN("alias","clientId","name","username","authenticator","identityProviderAlias")));
def miss($in; $out; $p):
  if ($in | type) == "object" then
    $in | to_entries[] | select(.key != "users") | miss(.value; (if ($out | type) == "object" then $out[.key] else null end); "\($p).\(.key)")
  elif ($in | type) == "array" and ($in | length) > 0 and ($in | all(type == "object")) then
    $in[] as $e | ($e | ids) as $id
    | ([($out // [])[] | select(($id | length) > 0 and (to_entries | from_entries | contains($id)))] | first) as $o
    | if $o == null then "\($p)[\($id | tojson)]: missing" else miss($e; $o; "\($p)[\($id | tojson)]") end
  elif ($in | type) == "array" then
    $in[] as $v | select([($out // [])[] | tostring] | index($v | tostring) | not) | "\($p): \($v) missing"
  elif ($in | type) == "string" and ($in | contains("$(")) then empty
  elif ($in | tostring) == ($out | tostring) then empty
  else "\($p): want \($in | tojson) got \($out | tojson)" end;
miss($want; $got; $want.realm)'

fail=0
for f in config/"$stage"/*.json; do
  realm=$(jq -r .realm "$f")
  got=$(jq -s '.[0] * .[1] * {userProfile: .[2]}' \
    <(admin_api GET "/realms/$realm") \
    <(admin_api POST "/realms/$realm/partial-export?exportClients=true&exportGroupsAndRoles=true") \
    <(admin_api GET "/realms/$realm/users/profile"))
  missing=$(jq -rn --slurpfile want "$f" --argjson got "$got" "\$want[0] as \$want | $subset")
  if [[ -n $missing ]]; then
    fail=1; log "DROPPED in $f:"
    while read -r line; do printf '  %s\n' "$line" >&2; done <<<"$missing"
  fi
done
((fail == 0)) || die "check-config $stage: fields missing in Keycloak"
log "OK check-config $stage: every field of config/$stage is in Keycloak"
