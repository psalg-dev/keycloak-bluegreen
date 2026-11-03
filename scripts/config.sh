#!/usr/bin/env bash
# config.sh <bootstrap|online|maintenance> <color>: run keycloak-config-cli for one stage against one color's own Service
# (bypasses ingress, so it also works during a freeze) and wait for it.
#   bootstrap   first install only; authenticates as the temporary bootstrap admin
#   online      backward-compatible changes, applied under traffic; never deletes anything
#   maintenance breaking changes; run while traffic to the affected paths is blocked
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="config"
stage=${1:?stage} color=${2:?color}
[[ -d config/$stage ]] || die "no config/$stage"

version=$(kubectl -n "$NS" get sts "kc-$color-keycloak" -o jsonpath='{.spec.template.spec.containers[0].image}')
version=${version##*:}
cli=adorsys/keycloak-config-cli:$(cli_tag "${version%%-*}")
ensure_secret kc-config-cli secret
ensure_secret k6-app secret
job=config-$stage-$color

if [[ $stage == bootstrap ]]; then
  auth='[{name:"KEYCLOAK_USER",value:"temp-admin"},
         {name:"KEYCLOAK_PASSWORD",valueFrom:{secretKeyRef:{name:"kc-bootstrap-admin",key:"password"}}}]'
else
  auth='[{name:"KEYCLOAK_GRANTTYPE",value:"client_credentials"},{name:"KEYCLOAK_CLIENTID",value:"config-cli"},
         {name:"KEYCLOAK_CLIENTSECRET",valueFrom:{secretKeyRef:{name:"kc-config-cli",key:"secret"}}}]'
fi
managed='[]' # online must never delete: every managed entity type -> no-delete
[[ $stage == online ]] && managed=$(printf '%s\n' group sub-group required-action client-scope scope-mapping \
  client-scope-mapping role component sub-component authentication-flow identity-provider identity-provider-mapper \
  client client-authorization-resources client-authorization-policies client-authorization-scopes message-bundles \
  | jq -R '{name: ("IMPORT_MANAGED_" + (ascii_upcase | gsub("-"; ""))), value: "no-delete"}' | jq -s .)

log "config $stage -> kc-$color: running config-cli Job"
kubectl -n "$NS" create configmap "$job" --from-file="config/$stage/" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" delete job "$job" --ignore-not-found >/dev/null
jq -n --arg job "$job" --arg color "$color" --arg image "$cli" --argjson managed "$managed" "
  {apiVersion:\"batch/v1\", kind:\"Job\", metadata:{name:\$job, namespace:\"$NS\"},
   spec:{backoffLimit:0, ttlSecondsAfterFinished:3600, template:{
     metadata:{labels:{(\"kc-\" + \$color + \"-keycloak-client\"):\"true\", app:\"config-cli\"}},
     spec:{restartPolicy:\"Never\", volumes:[{name:\"config\", configMap:{name:\$job}}],
       containers:[{name:\"config-cli\", image:\$image, volumeMounts:[{name:\"config\", mountPath:\"/config\"}],
         resources:{requests:{cpu:\"250m\", memory:\"512Mi\"}, limits:{memory:\"768Mi\"}},
         env:([{name:\"KEYCLOAK_URL\", value:(\"http://kc-\" + \$color + \"-keycloak.$NS/keycloak\")},
               {name:\"KEYCLOAK_AVAILABILITYCHECK_ENABLED\", value:\"true\"},
               {name:\"KEYCLOAK_AVAILABILITYCHECK_TIMEOUT\", value:\"180s\"},
               {name:\"IMPORT_FILES_LOCATIONS\", value:\"/config/*\"},
               {name:\"IMPORT_VARSUBSTITUTION_ENABLED\", value:\"true\"},
               # one checksum per FILE: per cache key, files of the same realm overwrite each other's checksum,
               # so nothing is ever skipped and every run rewrites the realm (= cache invalidations under traffic)
               {name:\"IMPORT_BEHAVIORS_CHECKSUMWITHCACHEKEY\", value:\"false\"},
               {name:\"KC_CONFIG_CLI_SECRET\", valueFrom:{secretKeyRef:{name:\"kc-config-cli\", key:\"secret\"}}},
               {name:\"LEGACY_BROKER_SECRET\", valueFrom:{secretKeyRef:{name:\"legacy-broker\", key:\"client-secret\"}}},
               {name:\"K6_APP_SECRET\", valueFrom:{secretKeyRef:{name:\"k6-app\", key:\"secret\"}}},
               {name:\"TESTCLIENT_BC_SECRET\", valueFrom:{secretKeyRef:{name:\"test-apps\", key:\"testclient-bc\"}}},
               {name:\"TESTCLIENT_FC_SECRET\", valueFrom:{secretKeyRef:{name:\"test-apps\", key:\"testclient-fc\"}}},
               {name:\"TESTRESOURCE_SECRET\", valueFrom:{secretKeyRef:{name:\"test-apps\", key:\"testresource\"}}}]
               + $auth + \$managed)}]}}}}" | kubectl apply -f - >/dev/null

if ! kubectl -n "$NS" wait "job/$job" --for=condition=complete --timeout=600s >/dev/null 2>&1; then
  kubectl -n "$NS" logs "job/$job" --tail=40 >&2 || true
  die "config-cli $stage on kc-$color failed"
fi
log "config $stage applied to kc-$color ($cli)"
scripts/check-config.sh "$stage" "$color" # every field must have landed: config-cli drops unknown fields silently
