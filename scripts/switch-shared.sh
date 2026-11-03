#!/usr/bin/env bash
# switch-shared.sh <target_version> <provider_version>: the patch case. Same Keycloak major.minor, one shared DB.
# Deploys the idle color next to the active one, flips kc-active, drains and scales the old color to 0.
# Every step writes an event to out/events.jsonl for the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="deployment"
target=${1:?target_version} provider=${2:?provider_version}
active=$(state activeColor) db=$(state activeDb) from=$(state version)
idle=$([[ $active == blue ]] && echo green || echo blue)
# Same major.minor is the shared-DB rule (Keycloak: different major/minor on one DB is unsupported).
# ponytail: no `kc.sh update-compatibility` pre-flight. It compares the full config, so it needs a throwaway pod with
# the color's exact env; both colors share values-common, so it would re-check this guard. NEVER run it (or any kc.sh
# subcommand) inside a live pod: without --optimized it re-augments into the pod's writable lib/quarkus emptyDir and
# the next container restart boots that build (seen on 2026-11-02: db=dev-file, no stateless).
[[ ${from%.*} == "${target%.*}" ]] || die "$from -> $target is not same major.minor: use switch-lossy.sh"

# 1-2. Idle color on the same DB, its own Infinispan cluster.
build_image "$target" "$provider"
deploy_color "$idle" "$target" "$db" "$provider"
scripts/check-cluster.sh "$idle"
event deployed color="$idle" version="$target" provider="$provider"

# 4. Online config through the new color (a no-op when nothing changed; with stateless the old color sees it too).
scripts/config.sh online "$idle"

# 5. The switch.
event switch from="$active" to="$idle"
set_active "$idle" "$db" "$target"

# 6. Graceful pod kill on each color while traffic moves (gated). The PDB (minAvailable 2; laptop 1) does not apply to
#    deletes. Pod -1 exists in both profiles (3 or 2 replicas); the others keep serving.
old_uid=$(kubectl -n "$NS" get pod "kc-$idle-keycloak-1" -o jsonpath='{.metadata.uid}')
for c in "$active" "$idle"; do
  kubectl -n "$NS" delete pod "kc-$c-keycloak-1" --wait=false >/dev/null
  event kill color="$c" pod="kc-$c-keycloak-1"
done
# rollout status returns at once (spec unchanged), so wait for the replacement pod itself.
for _ in $(seq 150); do
  uid=$(kubectl -n "$NS" get pod "kc-$idle-keycloak-1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  [[ -n $uid && $uid != "$old_uid" ]] && break
  sleep 2
done
kubectl -n "$NS" wait "pod/kc-$idle-keycloak-1" --for=condition=Ready --timeout=600s >/dev/null || die "kc-$idle-keycloak-1 not back"
event recovered color="$idle" pod="kc-$idle-keycloak-1"

# 7. Drain the old color, then scale it to 0 (helm upgrade would restore it; the next switch redeploys it anyway).
#    KEEP_OLD=true keeps it running for the rollback hold (scripts/rollback.sh flips back and scales the new one down).
if [[ ${KEEP_OLD:-false} == true ]]; then
  log "switched $active -> $idle; kc-$active kept running for rollback"; exit 0
fi
sleep "${DRAIN_SECONDS:-60}"
save_logs "$active"
kubectl -n "$NS" scale sts "kc-$active-keycloak" --replicas=0 >/dev/null
event drained color="$active"
log "switched $active -> $idle ($from -> $target, provider v$provider, db $db)"
