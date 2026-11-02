#!/usr/bin/env bash
# gate.sh <shared|lossy> <k6-lines.jsonl> <events.jsonl>
# Reads the k6 request lines (schema: top of load/k6/flows.js) and the switch events (`event` in scripts/lib/kc.sh),
# prints one row per rule (PASS/FAIL/SKIP + numbers, up to 5 offending lines) and exits 1 if any rule FAILs.
# A rule whose precondition event is missing (e.g. no `switch`) is SKIP, not FAIL.
# Interpretations (PLAN.md Slice 4):
# - k6 never requests /admin or /account, so "503 only on the frozen paths" reduces to: no 5xx / status 0 at all.
# - A session is born at the t_end of its `login_token` hop; refresh and probe lines carry the login_id that minted the token.
# - invalid_grant = the token endpoint's OAuth `error` field. logout_probe lines are excluded: they must get it.
# - Re-login tie-back: a lost session's user+net has a later successful `relogin` token.
# - Several `switch` events (one run, two flips): rules use the first. ponytail: split runs per flip, or loop over switches.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
. "$(dirname "$0")/lib/kc.sh"

mode=${1:-} k6=${2:-} ev=${3:-}
[[ ($mode == shared || $mode == lossy) && -f $k6 ]] || die "usage: gate.sh <shared|lossy> <k6-lines.jsonl> <events.jsonl>"
[[ -f $ev ]] || { log "no events file '$ev': treating as empty"; ev=/dev/null; }
# ponytail: probes this soon after replay_done may still hit a pod whose session cache is ~100 ms stale (stateless outbox).
GRACE=${GATE_GRACE_SECONDS:-1}

# Shared jq prelude: $L = k6 lines with numeric ts/te (epoch s), event times, session birth times.
# shellcheck disable=SC2016 # jq variables, not shell
PRE='
def ts: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("(?<f>\\.[0-9]+)Z$").f // ".0") | "0\(.)" | tonumber);
def ev($n): [$e[] | select(.event == $n) | .t | ts] | .[0];
def n: length;
def hop: .step | startswith("login_");
def ig: .error == "invalid_grant";
def tok: (.step == "login_token" or .step == "refresh") and .status == 200;
def verdict(ok; d): {r: (if ok then "PASS" else "FAIL" end), d: d};
def skip(d): {r: "SKIP", d: d};
def info(v): {r: "INFO", d: "\(v)"};
def secs: if . == null then "n/a" else (. * 100 | round) / 100 end;
($k | map(. + {ts: (.t_start | ts), te: (.t_end | ts)})) as $L
| ev("switch") as $sw | ev("copy_point") as $cp | ev("replay_done") as $rd
| ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .te}] | from_entries) as $born
| def born: $born[.login_id // ""];
'

fails=0
# rule <name> <jq expr yielding {r, d, bad?}>
rule() {
  local out head r
  out=$(jq -nr --slurpfile k "$k6" --slurpfile e "$ev" --argjson grace "$GRACE" \
    "$PRE ($2) | \"\(.r)\t\(.d)\", ((.bad // [])[:5][] | del(.ts, .te) | tojson)")
  head=${out%%$'\n'*} r=${head%%$'\t'*}
  printf '%-24s %-5s %s\n' "$1" "$r" "${head#*$'\t'}"
  [[ $out != *$'\n'* ]] || printf '%s\n' "${out#*$'\n'}" | sed 's/^/      /'
  [[ $r != FAIL ]] || fails=$((fails + 1))
}

echo "gate $mode: $(wc -l < "$k6") k6 lines; events:"
jq -r '"  \(.t) \(.event)"' "$ev"
printf '%-24s %-5s %s\n' RULE STATE DETAIL

# --- both paths
# shellcheck disable=SC2016
{
rule has_lines 'verdict($L | n > 0; "\($L | n) k6 lines")'
rule issuer_stable '[$L[] | select(.iss != null)] as $a
  | [$a[] | select(.iss != "https://kc-\(.net).localtest.me/keycloak/realms/demo")] as $b
  | verdict($a != [] and $b == []; "\($a | n) issuers (\([$a[] | select($sw == null or .ts < $sw)] | n) before switch), \($b | n) not the one of their net") + {bad: $b}'
rule no_5xx '[$L[] | select(.status >= 500 or .status == 0)] as $b
  | verdict($b == []; "\($b | n) of \($L | n) responses >= 500 or status 0") + {bad: $b}'
rule reads_ok '[$L[] | select(.scenario == "reads")] as $a | [$a[] | select(.status != 200)] as $b
  | verdict($a != [] and $b == []; "\($a | n) reads, \($b | n) not 200") + {bad: $b}'
rule claims_present '[$L[] | select(tok)] as $a
  | [$a[] | select(.sub == null or .iss == null or .claims.login_ctx == null or .claims.tenant == null)] as $b
  | verdict($a != [] and $b == []; "\($a | n) tokens, \($b | n) missing sub/iss/login_ctx/tenant") + {bad: $b}'
rule sub_stable '[$L[] | select(.sub != null and .user != null)] | group_by(.user)
  | [.[] | select(map(.sub) | unique | n > 1)] as $b
  | verdict($b == []; "\(n) users, \($b | n) with more than one sub") + {bad: [$b[] | {user: .[0].user, subs: (map(.sub) | unique)}]}'
}

# --- shared (patch case)
# shellcheck disable=SC2016
[[ $mode != shared ]] || {
rule inflight_login 'if $sw == null then skip("no switch event") else
  [$L[] | select(hop)] | group_by(.login_id) | map(sort_by(.ts))
  | [.[] | select(. as $h | any(range(0; n - 1); $h[.].ts < $sw and $h[. + 1].ts >= $sw))] as $x
  | [$x[] | select(any(.[]; .status >= 400 or .status == 0) or (any(.[]; .step == "login_token" and .status == 200) | not))] as $b
  | verdict(($x | n) > 0 and $b == []; "\($x | n) logins with a hop before switch and the next after it, \($b | n) failed (last hop shown)") + {bad: [$b[][-1]]} end'
rule refresh_across_switch 'if $sw == null then skip("no switch event") else
  [$L[] | select(.step == "refresh" and .ts >= $sw and (born // 1e18) < $sw)] as $a | [$a[] | select(.status != 200)] as $b
  | verdict($a != [] and $b == []; "\($a | map(.login_id) | unique | n) sessions born before switch, \($a | n) refreshes after it, \($b | n) failed") + {bad: $b} end'
rule no_invalid_grant '[$L[] | select(ig and .step != "logout_probe")] as $b
  | verdict($b == []; "\($b | n) invalid_grant (logout_probe excluded)") + {bad: $b}'
rule logout_probe_never_ok '[$L[] | select(.step == "logout_probe")] as $a | [$a[] | select(.status == 200)] as $b
  | verdict($b == []; "\($a | n) probes, \($b | n) refreshed a logged-out session") + {bad: $b}'
}

# --- lossy (minor/major case)
# shellcheck disable=SC2016
[[ $mode != lossy ]] || {
rule refresh_pre_copy 'if $cp == null or $sw == null then skip("needs copy_point + switch") else
  [$L[] | select(.step == "refresh" and .ts >= $sw and (born // 1e18) < $cp)] as $a | [$a[] | select(.status != 200)] as $b
  | verdict($a != [] and $b == []; "\($a | map(.login_id) | unique | n) sessions born before copy_point, \($a | n) refreshes after switch, \($b | n) failed") + {bad: $b} end'
rule invalid_grant_in_window 'if $cp == null or $sw == null then skip("needs copy_point + switch") else
  [$L[] | select(.step == "refresh" and ig)] as $a | [$a[] | select((born // -1) as $t | $t < $cp or $t > $sw)] as $b
  | verdict($b == []; "\($a | n) refresh invalid_grant, \($b | n) on sessions not born in [copy_point, switch]") + {bad: $b} end'
rule relogin_ok '[$L[] | select(.step == "refresh" and ig)] as $a
  | [$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200)] as $ok
  | [$a[] | . as $i | select(any($ok[]; .user == $i.user and .net == $i.net and .ts >= $i.te) | not)] as $b
  | verdict($b == []; "\($a | n) lost sessions, \(($a | n) - ($b | n)) re-logged in OK") + {bad: $b}'
rule logout_after_replay 'if $rd == null then skip("no replay_done event") else
  [$L[] | select(.step == "logout_probe" and .ts >= $rd + $grace)] as $a | [$a[] | select(ig | not)] as $b
  | verdict($a != [] and $b == []; "\($a | n) probes after replay_done+\($grace)s, \($b | n) not invalid_grant") + {bad: $b} end'
# reported, not gated
rule lossy_seconds 'info(if $cp and $sw then $sw - $cp else null end | secs)'
rule sessions_lost 'info([$L[] | select(.step == "refresh" and ig) | .login_id] | unique | n)'
rule relogins 'info([$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200)] | n)'
rule logouts_replayed 'info([$e[] | select(.event | startswith("replay")) | .logouts // empty | tonumber] | max // "n/a")'
rule users_replayed 'info([$e[] | select(.event | startswith("replay")) | .users // empty | tonumber] | max // "n/a")'
rule resurrection_seconds 'info(if $sw and $rd then $rd - $sw else null end | secs)'
}

if ((fails)); then echo "GATE FAIL ($mode): $fails rule(s) failed"; exit 1; fi
echo "GATE PASS ($mode)"
