#!/usr/bin/env bash
# kcwarden.sh: download realms master + demo with kcwarden (as the config-cli service account, through the public URL)
# and audit them. Reports: out/security/kcwarden-<realm>.{json,txt} (all severities). Exits 1 if any finding is at or
# above KCWARDEN_MIN_SEVERITY (INFO|LOW|MEDIUM|HIGH|CRITICAL, default HIGH) after security/kcwarden-ignore.yaml.
# Needs kcwarden on PATH (Jenkins image).
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/lib/kc.sh
TAG=security

min=${KCWARDEN_MIN_SEVERITY:-HIGH}
out=out/security base=https://kc-net1.localtest.me/keycloak
mkdir -p "$out"

# kcwarden uses python requests: no --resolve, and kc-net1.localtest.me resolves to 127.0.0.1. So forward this
# container's 127.0.0.1:443 to the ingress controller: same hostname, same certificate, same edge as any client.
kubectl -n ingress-nginx port-forward --address 127.0.0.1 svc/ingress-nginx-controller 443:443 >/dev/null &
pf=$!
bundle=$(mktemp)
trap 'kill $pf 2>/dev/null; rm -f "$bundle"' EXIT
# Trust: public CAs (kcwarden asks GitHub for the latest Keycloak) + the demo CA (Secret demo-ca). Python >= 3.13
# verifies X509-strict: a demo CA made before scripts/certs.sh set keyUsage is rejected ("CA cert does not include key
# usage extension"); see certs.sh for regenerating it.
cat /etc/ssl/certs/ca-certificates.crt "$(ca_file)" > "$bundle"
export REQUESTS_CA_BUNDLE=$bundle
KCWARDEN_CLIENT_SECRET=$(kubectl -n "$NS" get secret kc-config-cli -o jsonpath='{.data.secret}' | base64 -d)
export KCWARDEN_CLIENT_SECRET # read by kcwarden from env, never on a command line

for _ in $(seq 30); do curl -sf -o /dev/null --cacert "$bundle" "$base/realms/master" && break; sleep 1; done

rc=0
for realm in master demo; do
  dump="$out/kcwarden-$realm-export.json" # partial export: client secrets come back masked
  kcwarden download -m client --client-id config-cli -r "$realm" -o "$dump" "$base"
  jq -e .realm "$dump" >/dev/null || die "kcwarden download $realm: $(head -c 300 "$dump")"
  COLUMNS=200 kcwarden audit -c security/kcwarden-ignore.yaml -f txt -o "$out/kcwarden-$realm.txt" "$dump"
  kcwarden audit -c security/kcwarden-ignore.yaml -f json -o "$out/kcwarden-$realm.json" "$dump"
  # Gate: same audit, only findings >= threshold; kcwarden exits 42 if there are any.
  r=0; kcwarden audit -c security/kcwarden-ignore.yaml -s "$min" --fail-on-findings -f json -o "$out/gate.json" "$dump" || r=$?
  case $r in
    0) log "kcwarden $realm: no findings >= $min" ;;
    42) rc=1; log "kcwarden $realm: findings >= $min:"
        jq -r '.[] | "  \(.severity) \(.reporting_auditor) \(.entity_type) \(.entity)"' "$out/gate.json" >&2 ;;
    *) die "kcwarden audit $realm exited $r" ;;
  esac
  rm -f "$out/gate.json"
done
exit "$rc"
