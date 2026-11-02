#!/usr/bin/env bash
# probe kcversion: known vulnerabilities of the running Keycloak itself (trivy covers its Java libraries). Version from
# serverinfo (admin API), advisories from OSV for Maven org.keycloak:keycloak-services at that version.
# Advisories at or above KC_CVE_MIN_SEVERITY (LOW|MEDIUM|HIGH|CRITICAL, default HIGH) fail, lower ones WARN.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

min=${KC_CVE_MIN_SEVERITY:-HIGH}
version=$(admin_api GET /serverinfo | jq -r .systemInfo.version)
[[ $version =~ ^[0-9]+\.[0-9]+ ]] || { fail "no Keycloak version from serverinfo: '$version'"; finish ""; }
osv=$(curl -sf --max-time 30 https://api.osv.dev/v1/query -d "$(jq -nc --arg v "$version" \
  '{package: {ecosystem: "Maven", name: "org.keycloak:keycloak-services"}, version: $v}')") \
  || { fail "OSV query failed"; finish ""; }
# GHSA severities: LOW, MODERATE, HIGH, CRITICAL
list() { jq -r --arg m "$min" --arg op "$1" '{LOW: 1, MODERATE: 2, MEDIUM: 2, HIGH: 3, CRITICAL: 4} as $r
  | .vulns[]? | (.database_specific.severity // "UNKNOWN") as $s | (($r[$s] // 3) >= $r[$m]) as $hit
  | select(if $op == "ge" then $hit else ($hit | not) end) | "\($s) \(.aliases[0] // .id)"' <<<"$osv" | sort -u | paste -sd';'; }
hi=$(list ge) lo=$(list lt)
[[ -z $hi ]] || fail "Keycloak $version has advisories >= $min: $hi"
[[ -z $lo ]] || warn "Keycloak $version has advisories below $min: $lo"
finish "Keycloak $version: no OSV advisories for org.keycloak:keycloak-services"
