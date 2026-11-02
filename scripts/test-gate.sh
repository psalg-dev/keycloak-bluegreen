#!/usr/bin/env bash
# test-gate.sh: feeds gate.sh synthetic fixtures (load/fixtures) and asserts the exit code, the exact set of FAILed
# rules, and any extra rule=STATE expectation. A case's k6 file = its fragments concatenated (base + delta).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh

F=load/fixtures
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
# name | mode | k6 fragments | events | exit | expected rule=STATE (all FAILs must be listed)
cases='
pass-shared        |shared|shared-base shared-inflight-ok                  |shared|0|inflight_login=PASS refresh_across_switch=PASS
5xx                |shared|shared-base shared-inflight-ok shared-5xx       |shared|1|no_5xx=FAIL
inflight-broken    |shared|shared-base shared-inflight-broken              |shared|1|inflight_login=FAIL
wrong-iss          |shared|shared-base shared-inflight-ok shared-wrong-iss |shared|1|issuer_stable=FAIL
skip-no-switch     |shared|shared-base shared-inflight-ok                  |none  |0|inflight_login=SKIP refresh_across_switch=SKIP
pass-lossy         |lossy |lossy-base                                       |lossy |0|refresh_pre_copy=PASS invalid_grant_in_window=PASS relogin_ok=PASS logout_after_replay=PASS
probe-after-replay |lossy |lossy-base lossy-probe-ok                       |lossy |1|logout_after_replay=FAIL
pre-copy-grant     |lossy |lossy-base lossy-pre-copy-ig                    |lossy |1|refresh_pre_copy=FAIL invalid_grant_in_window=FAIL
sub-change         |lossy |lossy-base lossy-sub-change                     |lossy |1|sub_stable=FAIL
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
