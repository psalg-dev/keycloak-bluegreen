#!/usr/bin/env bash
# test-gate.sh: feeds gate.sh synthetic fixtures (load/fixtures) and asserts the exit code, the exact set of FAILed
# rules, and any extra rule=STATE expectation. A case's k6 file = its fragments concatenated (base + delta).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="test"

F=load/fixtures
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
# name | mode | k6 fragments | events | exit | expected rule=STATE (all FAILs must be listed)
cases='
pass-shared        |shared|shared-base shared-inflight-ok                  |shared|0|inflight_login=PASS refresh_across_switch=PASS
5xx                |shared|shared-base shared-inflight-ok shared-5xx       |shared|1|no_5xx=FAIL
inflight-broken    |shared|shared-base shared-inflight-broken              |shared|1|inflight_login=FAIL
wrong-iss          |shared|shared-base shared-inflight-ok shared-wrong-iss |shared|1|issuer_stable=FAIL
skip-no-switch     |shared|shared-base shared-inflight-ok                  |none  |0|inflight_login=SKIP refresh_across_switch=SKIP
aborted-at-stop    |shared|shared-base shared-inflight-ok shared-aborted   |shared-stop|0|no_5xx=PASS refresh_across_switch=PASS
neterr-before-stop |shared|shared-base shared-inflight-ok shared-neterr    |shared-stop|1|no_5xx=FAIL refresh_across_switch=FAIL
pass-lossy         |lossy |lossy-base                                       |lossy |0|refresh_pre_copy=PASS invalid_grant_in_window=PASS relogin_ok=PASS logout_after_replay=PASS
probe-after-replay |lossy |lossy-base lossy-probe-ok                       |lossy |1|logout_after_replay=FAIL
pre-copy-grant     |lossy |lossy-base lossy-pre-copy-ig                    |lossy |1|refresh_pre_copy=FAIL invalid_grant_in_window=FAIL
sub-change         |lossy |lossy-base lossy-sub-change                     |lossy |1|sub_stable=FAIL
pass-shared-rb     |shared-rollback|shared-rb-base shared-rb-inflight        |shared-rollback|0|inflight_login=PASS inflight_login_rollback=PASS refresh_blue_after_rollback=PASS refresh_green_after_rollback=PASS
shared-rb-5xx      |shared-rollback|shared-rb-base shared-rb-inflight shared-rb-5xx|shared-rollback|1|no_5xx=FAIL
shared-rb-inflight |shared-rollback|shared-rb-base shared-rb-inflight-broken |shared-rollback|1|inflight_login_rollback=FAIL inflight_login=PASS
skip-no-rollback   |shared-rollback|shared-base shared-inflight-ok          |shared|0|inflight_login_rollback=SKIP refresh_green_after_rollback=SKIP
pass-lossy-rb      |lossy-rollback |lossy-rb-base                            |lossy-rollback|0|invalid_grant_phases=PASS logout_after_replay=PASS logout_after_rollback_replay=PASS refresh_pre_copy_after_rollback=PASS green_users_sub_kept=PASS relogin_ok=PASS
lossy-rb-pre-copy  |lossy-rollback |lossy-rb-base lossy-rb-pre-copy-ig       |lossy-rollback|1|refresh_pre_copy=FAIL refresh_pre_copy_after_rollback=FAIL invalid_grant_phases=FAIL
lossy-rb-probe-ok  |lossy-rollback |lossy-rb-base lossy-rb-probe-ok          |lossy-rollback|1|logout_after_rollback_replay=FAIL
lossy-rb-sub       |lossy-rollback |lossy-rb-base lossy-rb-sub-change        |lossy-rollback|1|sub_stable=FAIL green_users_sub_kept=FAIL
lossy-rb-no-relogin|lossy-rollback |lossy-rb-base lossy-rb-no-relogin        |lossy-rollback|1|relogin_ok=FAIL invalid_grant_phases=PASS
skip-lossy-no-rb   |lossy-rollback |lossy-base                               |lossy |0|invalid_grant_phases=SKIP logout_after_replay=SKIP logout_after_rollback_replay=SKIP green_users_sub_kept=SKIP
'

bad=0
while IFS='|' read -r name mode frags events want expect; do
  [[ -n $name ]] || continue
  read -r name <<<"$name"; read -r mode <<<"$mode"; read -r events <<<"$events"
  : > "$tmp"
  for f in $frags; do cat "$F/$f.k6.jsonl" >> "$tmp"; done
  if out=$(scripts/gate.sh "$mode" "$tmp" "$F/$events.events.jsonl" 2>&1); then rc=0; else rc=$?; fi
  why=()
  [[ $rc == "$want" ]] || why+=("exit $rc, want $want")
  for e in $expect; do
    grep -Eq "^${e%%=*} +${e#*=} " <<<"$out" || why+=("want ${e%%=*} ${e#*=}")
  done
  got=$(awk '$2 == "FAIL" && $1 != "GATE" {print $1}' <<<"$out" | sort | xargs)
  exp=$(tr ' ' '\n' <<<"$expect" | sed -n 's/=FAIL$//p' | sort | xargs)
  [[ $got == "$exp" ]] || why+=("FAIL set '$got', want '$exp'")
  if ((${#why[@]})); then
    bad=$((bad + 1)); log "FAIL $name: ${why[*]}"; printf '%s\n' "$out" | sed 's/^/    /' >&2
  else
    log "ok   $name (exit $rc${exp:+, FAIL: $exp})"
  fi
done <<<"$cases"
((bad == 0)) || die "$bad gate test(s) failed"
log "all gate tests passed"
