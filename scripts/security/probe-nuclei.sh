#!/usr/bin/env bash
# probe nuclei: the keycloak-tagged nuclei templates (CVEs, exposed admin panel/config, alg=none) against the /keycloak
# base and the master realm of kc-net1 (net2 is the same backend). Most templates hard-code root or /auth paths, so the
# /keycloak context path alone hides much of their surface; realms/master as a second base catches realm-relative ones.
# Findings at or above NUCLEI_MIN_SEVERITY (info|low|medium|high|critical, default medium) fail; lower ones are evidence. Templates pinned (NUCLEI_TEMPLATES_VERSION), cached in docker volume
# kcbg-nuclei-templates. No interactsh (-ni): nothing leaves the box.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
. scripts/security/lib.sh

min=${NUCLEI_MIN_SEVERITY:-medium}
v=$NUCLEI_TEMPLATES_VERSION
# shellcheck disable=SC2016 # runs in the container
tool -v kcbg-nuclei-templates:/t -e "V=$v" --entrypoint sh "$NUCLEI_IMAGE" -c '
  [ -d /t/nuclei-templates-$V ] || wget -qO- "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v$V.tar.gz" | tar xz -C /t
  nuclei -duc -ni -silent -nc -rl 20 -jsonl -t /t/nuclei-templates-$V -tags keycloak "$@"' sh \
  -u https://kc-net1.localtest.me/keycloak -u https://kc-net1.localtest.me/keycloak/realms/master > "$OUT/nuclei.jsonl" 2> "$OUT/nuclei.txt" \
  || { fail "nuclei failed: $(tail -1 "$OUT/nuclei.txt")"; finish ""; }

hits() { jq -r --arg m "$1" --arg op "$2" '{info: 0, low: 1, medium: 2, high: 3, critical: 4} as $r
  | select(($r[.info.severity] // 0) as $s | if $op == "ge" then $s >= $r[$m] else $s < $r[$m] end)
  | "\(.info.severity) \(."template-id") \(."matched-at")"' "$OUT/nuclei.jsonl" | sort -u; }
bad=$(hits "$min" ge)
[[ -z $bad ]] || fail "findings >= $min: $(paste -sd';' <<<"$bad")"
low=$(hits "$min" lt | awk '{print $1 " " $2}' | sort | uniq -c | awk '{print $2 " " $3 " x" $1}' | paste -sd',')
finish "$(grep -c . "$OUT/nuclei.jsonl" || true) matches, none >= $min. Below threshold: ${low:-none}"
