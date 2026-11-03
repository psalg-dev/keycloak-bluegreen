#!/usr/bin/env bash
# live-demo.sh: the browser live demo (live/demo.mjs) against the running cluster. Runs on the HOST: Node >= 18 plus
# the compose project up; it reads the demo client secret and the legacy user password from the cluster through the
# Jenkins container, and trusts the demo CA. Prints the URL, then keeps running: Ctrl-C stops it.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="live demo"
die() { printf 'live demo: %s\n' "$*" >&2; exit 1; }

ca=out/certs/ca.crt
[[ -s $ca ]] || die "no $ca: run the platform bring-up first (docker compose run --rm launcher)"
command -v node >/dev/null || die "node >= 18 is required on the host (node --version)"
J=${JENKINS_CONTAINER:-kc-bluegreen-jenkins-1}
docker inspect "$J" >/dev/null 2>&1 || die "container $J is not running: docker compose up -d jenkins"
kube() { MSYS_NO_PATHCONV=1 docker exec "$J" kubectl "$@"; }

# Node is a Windows binary under Git Bash: NODE_EXTRA_CA_CERTS needs a Windows path there.
export NODE_EXTRA_CA_CERTS="$(cygpath -w "$PWD/$ca" 2>/dev/null || printf '%s' "$PWD/$ca")"
export TESTCLIENT_BC_SECRET="$(kube -n keycloak get secret test-apps -o jsonpath='{.data.testclient-bc}' | base64 -d)"
export LEGACY_USER_PASSWORD="$(kube -n legacy get secret legacy-idp -o jsonpath='{.data.user-password}' | base64 -d)"
export INTERVAL_MS="${INTERVAL_MS:-2500}" PORT="${PORT:-8098}" DEMO_USER="${DEMO_USER:-user0042}"

printf 'live demo: http://127.0.0.1:%s/  (Ctrl-C stops it; the page keeps reporting while you flip the active color)\n' "$PORT"
exec node live/demo.mjs
