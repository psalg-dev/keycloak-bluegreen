#!/usr/bin/env bash
# demo.sh <case|all> [phase]: one standalone demo case (versions in cases.env), all phases or one of them.
# Phases (Jenkins runs each as its own stage): reset install warmup switch rollback cooldown gate
#   reset    empty Keycloak namespace, fresh pg-1           install  blue at FROM, config stages, seeded users
#   warmup   start k6, warm up under load                  switch   the case's switch (old color kept for *-rollback)
#   rollback *-rollback only: soak on the new color, roll back (no-op for other cases)
#   cooldown keep load running, then stop k6                gate     judge out/<case>/ (k6 lines + events)
# Results per case in out/<case>/ (events, k6 lines, gate table). Exit non-zero if a phase or the gate fails.
# Env: WARMUP_SECONDS (120) SOAK_SECONDS (90) COOLDOWN_SECONDS (90) RUN_MAINTENANCE (true|1: maintenance stage in the switch)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
what=${1:?case|all} phase=${2:-all}
phases=(reset install warmup switch rollback cooldown gate)

if [[ $what == all ]]; then
  # one process per case: `set -e` is ignored inside a function called as `f || rc=1`
  rc=0; mapfile -t cases < <(awk '!/^#/ && NF {print $1}' cases.env)
  for c in "${cases[@]}"; do "$0" "$c" || rc=1; done; exit "$rc"
fi
read -r _ from to fp tp mech < <(awk -v c="$what" '$1 == c' cases.env) || true
[[ -n ${mech:-} ]] || die "no case '$what' in cases.env"

run_phase() {
  log "--- $what: $1"
  case $1 in
    reset) log "=== case $what: $from -> $to ($mech)"; scripts/reset.sh ;;
    install) first_install "$from" "$fp" pg-1 ;;
    warmup) scripts/load.sh start; wait_progress "${WARMUP_SECONDS:-120}" warm-up ;;
    switch)
      case $mech in
        shared) scripts/switch-shared.sh "$to" "$tp" ;;
        lossy) scripts/switch-lossy.sh "$to" ;;
        shared-rollback) KEEP_OLD=true scripts/switch-shared.sh "$to" "$tp" ;;
        lossy-rollback) KEEP_OLD=true scripts/switch-lossy.sh "$to" ;;
      esac ;;
    rollback)
      [[ $mech == *-rollback ]] || { log "not a rollback case: nothing to do"; return; }
      wait_progress "${SOAK_SECONDS:-90}" soak # sessions and logouts happen on the new color, so the rollback has something to lose
      REASON=drill scripts/rollback.sh ;;
    cooldown)
      wait_progress "${COOLDOWN_SECONDS:-90}" cool-down # lossy: probes must run well after replay_done
      scripts/load.sh stop
      mkdir -p "out/$what"
      mv out/events.jsonl out/k6.jsonl "out/$what/" ;;
    gate) scripts/gate.sh "$mech" "out/$what/k6.jsonl" "out/$what/events.jsonl" | tee "out/$what/gate.txt" ;;
    *) die "unknown phase '$1' (${phases[*]})" ;;
  esac
}

if [[ $phase == all ]]; then
  for p in "${phases[@]}"; do run_phase "$p"; done
else
  run_phase "$phase"
fi
