#!/usr/bin/env bash
# Demo CA + wildcard cert for *.localtest.me (public DNS resolves it to 127.0.0.1).
# Creates TLS secret localtest-tls and CA secret demo-ca in every namespace given (default: keycloak).
set -euo pipefail
cd "$(dirname "$0")/.."
d=out/certs
mkdir -p "$d"

if [[ ! -f $d/ca.crt ]]; then
  openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=kc-bluegreen demo CA" \
    -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=*.localtest.me" \
    -keyout "$d/tls.key" -out "$d/tls.csr" 2>/dev/null
  openssl x509 -req -in "$d/tls.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 825 \
    -extfile <(printf 'subjectAltName=DNS:*.localtest.me,DNS:localtest.me\nextendedKeyUsage=serverAuth') \
    -out "$d/tls.crt" 2>/dev/null
fi

for ns in "${@:-keycloak}"; do
  kubectl -n "$ns" create secret tls localtest-tls --cert="$d/tls.crt" --key="$d/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" create secret generic demo-ca --from-file=ca.crt="$d/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
