#!/usr/bin/env bash
# demo.sh <case|all>: one standalone demo case per run (cases.env). Each case:
# reset -> blue at FROM (config stages, seeded users) -> load -> warm-up -> switch -> cool-down -> stop load -> gate.
# *-rollback cases: the switch keeps the old color running, load soaks on the new one, then rollback.sh flips back.
# Results per case in out/<case>/ (events, k6 lines, gate table). Exit non-zero if a gate fails.
# Env: WARMUP_SECONDS (120) SOAK_SECONDS (90) COOLDOWN_SECONDS (90) RUN_MAINTENANCE (true|1: maintenance stage in the switch)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
what=${1:?patch|minor|major|all}

run_case() {
  local name=$1 from to fp tp mech
  read -r _ from to fp tp mech < <(awk -v c="$name" '$1 == c' cases.env)
  [[ -n ${mech:-} ]] || die "no case '$name' in cases.env"
  log "=== case $name: $from -> $to ($mech)"
  scripts/reset.sh
  first_install "$from" "$fp" pg-1
  scripts/load.sh start
  sleep "${WARMUP_SECONDS:-120}"
  case $mech in
    shared) scripts/switch-shared.sh "$to" "$tp" ;;
    lossy) scripts/switch-lossy.sh "$to" ;;
    shared-rollback) KEEP_OLD=true scripts/switch-shared.sh "$to" "$tp" ;;
    lossy-rollback) KEEP_OLD=true scripts/switch-lossy.sh "$to" ;;
  esac
  if [[ $mech == *-rollback ]]; then
    sleep "${SOAK_SECONDS:-90}" # sessions and logouts happen on the new color, so the rollback has something to lose
    REASON=drill scripts/rollback.sh
  fi
  sleep "${COOLDOWN_SECONDS:-90}" # lossy: probes must run well after replay_done
  scripts/load.sh stop
  mkdir -p "out/$name"
  mv out/events.jsonl out/k6.jsonl "out/$name/"
  scripts/gate.sh "$mech" "out/$name/k6.jsonl" "out/$name/events.jsonl" | tee "out/$name/gate.txt"
}

if [[ $what == all ]]; then
  # one process per case: `set -e` is ignored inside a function called as `f || rc=1`
  rc=0; mapfile -t cases < <(awk '!/^#/ && NF {print $1}' cases.env)
  for c in "${cases[@]}"; do "$0" "$c" || rc=1; done; exit "$rc"
fi
run_case "$what"
