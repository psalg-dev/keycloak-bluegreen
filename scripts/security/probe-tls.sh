#!/usr/bin/env bash
# probe tls: testssl.sh against the ingress for both Keycloak hosts. No SSLv2/3, TLS 1.0/1.1, no NULL/aNULL/EXPORT/
# LOW/3DES cipher suites, and no testssl finding at or above TLS_MIN_SEVERITY (LOW|MEDIUM|HIGH|CRITICAL, default HIGH).
# The demo CA is added as trust anchor (an untrusted chain is not what this probe is about). Accepted finding ids, each
# with a justification: security/testssl-accept.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

min=${TLS_MIN_SEVERITY:-HIGH}
accept=$(sed 's/#.*//' security/testssl-accept.txt | xargs -n1 | jq -Rsc 'split("\n") | map(select(length > 0))')
for h in "${KC_HOSTS[@]}"; do
  json=$OUT/testssl-$h.json
  # shellcheck disable=SC2016 # runs in the container: $0 = host, $1 = ingress IP (testssl ignores /etc/hosts)
  tool --entrypoint sh "$TESTSSL_IMAGE" -c 'cat > /tmp/ca.pem
    testssl.sh --quiet --color 0 --warnings off --ip "$1" --add-ca /tmp/ca.pem --jsonfile /tmp/r.json "$0:443" >&2
    cat /tmp/r.json' "$h" "$NODE_IP" < "$CA_FILE" > "$json" 2> "$OUT/testssl-$h.txt" || true
  jq -e 'length > 10' "$json" >/dev/null 2>&1 || { fail "$h: testssl produced no result, see $OUT/testssl-$h.txt"; continue; }
  offered=$(jq -r '.[] | select((.id | test("^(SSLv2|SSLv3|TLS1|TLS1_1)$")) and (.finding | test("^not offered") | not)) | .id' "$json" | xargs)
  [[ -z $offered ]] || fail "$h offers $offered"
  weak=$(jq -r '.[] | select((.id | test("^cipherlist_(NULL|aNULL|EXPORT|LOW|3DES_IDEA)$")) and (.finding | test("^not offered") | not)) | .id' "$json" | xargs)
  [[ -z $weak ]] || fail "$h offers weak ciphers: $weak"
  bad=$(jq -r --arg m "$min" --argjson ok "$accept" '{LOW: 1, MEDIUM: 2, HIGH: 3, CRITICAL: 4} as $r
    | .[] | select(($r[.severity] // 0) >= $r[$m] and (.id as $i | $ok | any(. == $i) | not)) | "\(.severity) \(.id)=\(.finding)"' "$json")
  [[ -z $bad ]] || fail "$h testssl findings >= $min: $(head -5 <<<"$bad" | paste -sd';')"
  protos=$(jq -r '.[] | select((.id | test("^TLS1_[23]$")) and (.finding | test("^offered"))) | .id' "$json" | xargs)
  ev+="$h: ${protos:-no TLS 1.2/1.3?}; "
done
finish "${ev:-}no legacy protocols, no weak ciphers, no findings >= $min"
