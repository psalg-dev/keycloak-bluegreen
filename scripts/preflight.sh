#!/usr/bin/env bash
# preflight.sh: fail fast, with one sentence, when this machine cannot run the demo. Run by scripts/up.sh first;
# run it directly on a fresh clone (`bash scripts/preflight.sh`, or `docker compose run --rm launcher bash
# scripts/preflight.sh`). Checks, in the order that bites: docker daemon, Docker VM memory vs PROFILE, host ports
# 443 (kind) and 8081 (Jenkins), the tools the scripts call, and *.localtest.me DNS. It never changes anything.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="preflight"

fails=0 warns=0
ok() { log "ok   $*"; }
warn() { log "WARN $*"; warns=$((warns + 1)); }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# 1. Docker daemon (the socket is mounted into the launcher; on the host it is the same daemon).
dv=$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)
if [[ -n $dv ]]; then
  ok "docker daemon reachable (server $dv)"
else
  bad "no Docker daemon: start Docker Desktop (or dockerd) and re-run"
fi

# 2. Docker VM memory against the profile's measured peak (default 14.8 GiB with Jenkins, laptop 9.1 GiB on
# Postgres). Oracle adds a 2 GiB instance and removes the CNPG instances; the Oracle branch needs ~15 GiB default
# and ~13 GiB laptop.
mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
need=$([[ ${PROFILE} == laptop ]] && echo 13 || echo 15) # GiB
if ((mem > 0)); then
  gib=$((mem / 1073741824))
  if ((gib >= need)); then
    ok "Docker memory ${gib} GiB (${PROFILE} needs ~${need} GiB)"
  else
    bad "Docker VM has ${gib} GiB, ${PROFILE} peaks at ~${need} GiB: raise it (Docker Desktop -> Settings -> Resources, or .wslconfig memory=14GB for the laptop profile) or set PROFILE=laptop"
  fi
fi

# 3. Host ports. A port is tested exactly the way kind and compose will use it (a container bind); skipped when our
# own objects already hold it, so re-running up.sh stays green. Result: 0 free, 1 busy, 2 cannot test.
port_free() {
  local img
  for img in kc-bluegreen/launcher:local alpine:3.24.3; do
    docker image inspect "$img" >/dev/null 2>&1 || continue
    if docker run --rm --entrypoint /bin/true -p "127.0.0.1:$1:1" "$img" >/dev/null 2>&1; then return 0; else return 1; fi
  done
  return 2
}
port_check() { # <port> <fatal|warn> <what>
  local rc=0
  port_free "$1" || rc=$?
  case $rc in
    0) ok "port $1 free ($3)" ;;
    1) if [[ $2 == fatal ]]; then bad "port $1 is in use ($3): stop whatever holds it (often IIS, another dev stack or a previous kind cluster)"; else warn "port $1 is in use ($3): Jenkins will not start until it is free"; fi ;;
    *) warn "port $1 not tested (no local image to bind with)" ;;
  esac
}
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  ok "port 443: the '$CLUSTER' cluster already holds it (bind test skipped)"
else
  port_check 443 fatal "kind ingress, 127.0.0.1"
fi
if [[ -n $(docker ps -q --filter 'publish=8081' 2>/dev/null) ]]; then
  ok "port 8081: this compose project's Jenkins already holds it"
else
  port_check 8081 warn "Jenkins UI"
fi

# 4. Tools the scripts call; missing ones fail deep inside a phase otherwise.
missing=()
for t in bash curl jq openssl git; do have "$t" || missing+=("$t"); done
if ((${#missing[@]} == 0)); then
  ok "tools: bash, curl, jq, openssl, git"
else
  bad "missing tools: ${missing[*]} (on Windows use Git Bash, not WSL: C:\\Windows\\system32\\bash.exe has no jq)"
fi

# 5. *.localtest.me must resolve to 127.0.0.1 for every hostname the demo uses. nslookup prints the DNS server's
# address first, so the test is "does 127.0.0.1 appear among the answers", not the last parsed address.
if have getent; then
  dns=$(getent hosts kc-net1.localtest.me 2>/dev/null || true)
else
  dns=$(nslookup kc-net1.localtest.me 2>/dev/null || true)
fi
if grep -qE '(^|[^0-9.])127\.0\.0\.1([^0-9.]|$)' <<<"$dns"; then
  ok "DNS: *.localtest.me -> 127.0.0.1"
elif [[ -z $dns ]]; then
  warn "DNS: could not resolve *.localtest.me here; the demo needs it to point at 127.0.0.1"
else
  warn "DNS: *.localtest.me does not map to 127.0.0.1 here ($(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$dns" | tr '\n' ' '))"
fi

if ((fails)); then
  die "preflight: $fails problem(s) this machine must fix before the demo can start (${warns} warning(s) above)"
fi
log "preflight passed ($warns warning(s))"
