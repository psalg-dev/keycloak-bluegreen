#!/usr/bin/env bash
# probe zap: OWASP ZAP baseline (spider + passive scan only, no attacks) against the demo account console and the demo
# login page on kc-net1. security/zap-rules.conf turns known-acceptable alerts into INFO, each with a justification.
# ZAP FAIL-level alerts fail; WARN-level alerts are WARN (ZAP_FAIL_ON_WARN=true makes them fail too).
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security
. scripts/security/lib.sh

kc=https://kc-net1.localtest.me/keycloak/realms/demo
targets=(account "$kc/account"
  login "$kc/protocol/openid-connect/auth?client_id=k6-app&response_type=code&scope=openid&redirect_uri=https%3A%2F%2Fapp.localtest.me%2Fcb&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256")
# k6-app enforces PKCE: without a challenge Keycloak rejects the request and the spider fails (exit 3, kc-security #4);
# a static S256 challenge (RFC 7636 example) is enough, the scan never completes a login
for ((i = 0; i < ${#targets[@]}; i += 2)); do
  name=${targets[i]} url=${targets[i + 1]} rc=0
  # shellcheck disable=SC2016 # runs in the container: $0 = target; rules on stdin, report on stdout
  tool --entrypoint sh "$ZAP_IMAGE" -c 'mkdir -p /zap/wrk && cd /zap/wrk && cat > rules.conf
    zap-baseline.py -t "$0" -c rules.conf -m 1 -z "-config spider.maxDepth=3 -config spider.maxChildren=10"' "$url" \
    < security/zap-rules.conf > "$OUT/zap-$name.txt" 2>&1 || rc=$?
  alerts() { grep -E "^$1-NEW:" "$OUT/zap-$name.txt" | sed -E "s/^$1-NEW: //; s/ x [0-9]+ *$//" | paste -sd';'; }
  case $rc in
    0) ev+="$name: $(grep -o 'PASS: [0-9]*' "$OUT/zap-$name.txt" | tail -1) rules pass; " ;;
    1) fail "$name: ZAP FAIL alerts: $(alerts FAIL)" ;;
    2) if [[ ${ZAP_FAIL_ON_WARN:-false} == true ]]; then fail "$name: ZAP WARN alerts: $(alerts WARN)"
       else warn "$name: ZAP WARN alerts: $(alerts WARN)"; fi ;;
    *) fail "$name: ZAP exited $rc: $(tail -2 "$OUT/zap-$name.txt" | paste -sd' ')" ;;
  esac
done
finish "${ev:-}no ZAP WARN/FAIL alerts"
