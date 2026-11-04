#!/usr/bin/env bash
# demo.sh <case|all> [phase]: one standalone demo case (versions in cases.env), all phases or one of them.
# Phases (Jenkins runs each as its own stage): reset install warmup switch rollback cooldown gate
#   reset    empty Keycloak namespace, fresh kc1 schema      install  blue at FROM, config stages, seeded users
#   warmup   start k6, warm up under load                  switch   the case's switch (old color kept for *-rollback)
#   rollback *-rollback only: soak on the new color, roll back (no-op for other cases)
#   cooldown keep load running, then stop k6                gate     judge out/<case>/ (k6 lines + events)
# Results per case in out/<case>/ (events, k6 lines, gate table). Exit non-zero if a phase or the gate fails.
# Env: WARMUP_SECONDS (60) SOAK_SECONDS (90) COOLDOWN_SECONDS (90) RUN_MAINTENANCE (true|1: maintenance stage in the switch)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
what=${1:?case|all} phase=${2:-all}
phases=(reset install warmup switch rollback cooldown gate)

if [[ $what == all ]]; then
  [[ $phase == all ]] || die "all runs every case end to end; run single phases per case"
  # one process per case: `set -e` is ignored inside a function called as `f || rc=1`
  rc=0; mapfile -t cases < <(awk '!/^#/ && NF {print $1}' cases.env)
  for c in "${cases[@]}"; do "$0" "$c" || rc=1; done; exit "$rc"
fi
read -r _ from to fp tp mech < <(awk -v c="$what" '$1 == c' cases.env) || true
[[ -n ${mech:-} ]] || die "no case '$what' in cases.env"

# explain <phase>: a header saying what the phase does and why, in this case's terms
explain() {
  local n i db=shared; [[ $mech == lossy* ]] && db="own DB per color"
  for i in "${!phases[@]}"; do [[ ${phases[$i]} == "$1" ]] && n=$((i + 1)); done
  local title text keep_old="" keep_db=""
  # plain if, not $([[ ]] && echo): a false [[ ]] inside a substitution fails the assignment under set -e (build #9)
  if [[ $mech == *-rollback ]]; then keep_old=" (no: it stays up for the rollback)"; keep_db=" Blue and its DB stay up for the rollback."; fi
  case $1 in
    reset) title="Reset" text="Remove both colors, k6, any freeze and every DB schema; drop/recreate the Oracle schemas, then create a fresh kc1. Every case starts from the same empty state." ;;
    install) title="Install" text="Blue at $from (provider v$fp) on kc1 (Oracle schema), then the config-cli stages bootstrap -> online -> maintenance (no traffic yet, so breaking changes are fine), then 4000 users pre-linked to legacy-net1." ;;
    warmup) title="Load + warm-up" text="Start k6 in the cluster: brokered logins on net1/net2, refreshes every 5 s, logouts with probes that must stay logged out, discovery/JWKS reads. ${WARMUP_SECONDS:-60} s so sessions exist BEFORE the switch." ;;
    switch)
      case $mech in
        shared*) title="Switch (shared DB)" text="Green $to (provider v$tp) next to blue on the same Oracle schema kc1, own Infinispan cluster; online config through green; flip kc-active; kill one of the $KC_REPLICAS pods per color mid-traffic; drain blue${keep_old}." ;;
        lossy*) title="Switch (lossy overlap)" text="Green's own schema = a consistent Data Pump copy of kc1 at a captured SCN; freeze admin/account only; copy point; import into kc2; green $to migrates the schema on its copy; replay blue's logouts + user creations onto green; flip; replay again after the drain. Login/token never stop.${keep_db}" ;;
      esac ;;
    rollback) title="Soak + rollback" text="Let traffic run ${SOAK_SECONDS:-90} s on the new color (new sessions, logouts), then roll back to blue. Shared DB: just the flip. Own DB: back to blue's old DB, after reverse-replaying green's logouts and user creations." ;;
    cooldown) title="Cool-down" text="Keep k6 running ${COOLDOWN_SECONDS:-90} s on the final color: the gate needs refreshes of older sessions and logout probes AFTER the switch/replay. Then stop k6 (requests it aborts itself are excluded) and collect its lines into out/$what/." ;;
    gate) title="Gate" text="Judge out/$what/ (k6 lines + switch events): no 5xx, issuer stable per network, same sub per user, in-flight logins and refresh tokens survive, logged-out sessions stay logged out (+ the $mech rules)." ;;
  esac
  local kind=${TAG^^} prof=""
  if [[ $PROFILE != default ]]; then prof=", PROFILE=$PROFILE"; fi
  TAG='' log "=== [$n/${#phases[@]}] $kind | $title ($what: $from -> $to, $db$prof)"
  fold -s -w 110 <<<"$text" | sed 's/^/    /' >&2
}

phase_tag() { # what kind of work a phase is: tags every line it logs (scripts it calls set their own)
  case $1 in
    reset) TAG=reset ;; install | switch | rollback) TAG=deployment ;; warmup | cooldown) TAG="load test" ;; gate) TAG=verification ;;
  esac
}

# run_phase <phase>: header, the phase body as its own process (so `set -e` holds inside it and its exit code is
# real), then one result line: OK/FAILED, exit code, duration. A failed phase stops the case with that exit code.
run_phase() {
  phase_tag "$1"; explain "$1"
  local t0=$SECONDS rc=0 n i
  for i in "${!phases[@]}"; do [[ ${phases[$i]} == "$1" ]] && n=$((i + 1)); done
  "$0" "$what" "$1" --body || rc=$? # `||`: the ERR trap stays quiet, the result line below reports it
  local d=$((SECONDS - t0)) kind=${TAG^^}
  if ((rc == 0)); then
    TAG='' log "=== [$n/${#phases[@]}] $kind | $1: OK (exit 0) in $((d / 60))m$((d % 60))s"
  else
    TAG='' log "=== [$n/${#phases[@]}] $kind | $1: FAILED (exit $rc) after $((d / 60))m$((d % 60))s"
    exit "$rc"
  fi
}

run_body() {
  phase_tag "$1"
  case $1 in
    reset) scripts/reset.sh ;;
    install) first_install "$from" "$fp" kc1 ;;
    warmup) scripts/load.sh start; wait_progress "${WARMUP_SECONDS:-60}" warm-up ;;
    switch)
      progress_ticker switch & local ticker=$! # k6 keeps running through the cutover; show it
      case $mech in
        shared) scripts/switch-shared.sh "$to" "$tp" ;;
        lossy) scripts/switch-lossy.sh "$to" ;;
        shared-rollback) KEEP_OLD=true scripts/switch-shared.sh "$to" "$tp" ;;
        lossy-rollback) KEEP_OLD=true scripts/switch-lossy.sh "$to" ;;
      esac
      kill "$ticker" 2>/dev/null || true ;;
    rollback)
      [[ $mech == *-rollback ]] || { log "not a rollback case: nothing to do"; return; }
      wait_progress "${SOAK_SECONDS:-90}" soak # sessions and logouts happen on the new color, so the rollback has something to lose
      progress_ticker rollback & local ticker=$!
      REASON=drill scripts/rollback.sh
      kill "$ticker" 2>/dev/null || true ;;
    cooldown)
      wait_progress "${COOLDOWN_SECONDS:-90}" cool-down # lossy: probes must run well after replay_done
      scripts/load.sh stop
      mkdir -p "out/$what"
      save_logs "$(state activeColor)"
      mv out/events.jsonl out/k6.jsonl "out/$what/"
      mv out/kc-*.log out/apps.jsonl "out/$what/" 2>/dev/null || true ;; # apps.jsonl: none without ns apps
    gate)
      apps=(); [[ ! -s out/$what/apps.jsonl ]] || apps=("out/$what/apps.jsonl")
      scripts/gate.sh "$mech" "out/$what/k6.jsonl" "out/$what/events.jsonl" "${apps[@]}" | tee "out/$what/gate.txt" ;;
    *) die "unknown phase '$1' (${phases[*]})" ;;
  esac
}

if [[ ${3:-} == --body ]]; then
  trap - ERR # the body's failing command is already logged by the script that ran it; run_phase reports the phase
  run_body "$phase"
elif [[ $phase == all ]]; then
  for p in "${phases[@]}"; do run_phase "$p"; done
else
  run_phase "$phase"
fi
