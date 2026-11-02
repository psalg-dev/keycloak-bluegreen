#!/usr/bin/env bash
# probe trivy: supply chain. trivy scans the image the ACTIVE color runs (StatefulSet of kc-state's activeColor) and the
# legacy IdP image (its Deployment), from the local docker daemon (images are built there, then `kind load`ed).
# Fixable vulnerabilities at TRIVY_SEVERITY (default HIGH,CRITICAL) fail. DB cached in docker volume kcbg-trivy-cache.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

sev=${TRIVY_SEVERITY:-HIGH,CRITICAL}
# The active color may flip during a blue/green test: re-read kc-state if its StatefulSet is not there (yet/any more).
for _ in 1 2 3; do
  color=$(state activeColor)
  kc=$(kubectl -n "$NS" get sts "kc-$color-keycloak" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) && break
  sleep 5
done
[[ -n ${kc:-} ]] || { fail "no StatefulSet for active color '$color'"; finish ""; }
legacy=$(kubectl -n legacy get deploy legacy-idp -o jsonpath='{.spec.template.spec.containers[0].image}')

for img in "$kc" "$legacy"; do
  local_img=${img#docker.io/} name=${img##*/}; name=${name%%:*}
  docker image inspect "$local_img" >/dev/null 2>&1 || { warn "$local_img not in the local docker daemon, not scanned"; continue; }
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v kcbg-trivy-cache:/root/.cache/ "$TRIVY_IMAGE" \
    image --quiet --image-src docker --scanners vuln --severity "$sev" --ignore-unfixed --format json "$local_img" \
    > "$OUT/trivy-$name.json" 2> "$OUT/trivy-$name.txt" || { fail "trivy $local_img failed: $(tail -1 "$OUT/trivy-$name.txt")"; continue; }
  vulns=$(jq -r '[.Results[]?.Vulnerabilities[]? | "\(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion)->\(.FixedVersion)"] | unique | .[]' "$OUT/trivy-$name.json")
  if [[ -n $vulns ]]; then
    fail "$local_img: $(wc -l <<<"$vulns") fixable $sev: $(head -6 <<<"$vulns" | paste -sd';')$( (($(wc -l <<<"$vulns") > 6)) && echo ';...')"
  else pass "$local_img: no fixable $sev vulnerabilities"; fi
done
log "active color: $color"
exit "$FAILED"
