#!/usr/bin/env bash
# gate.sh <shared|lossy|shared-rollback|lossy-rollback> <k6-lines.jsonl> <events.jsonl> [apps.jsonl]
# Reads the k6 request lines (schema: top of load/k6/flows.js), the switch events (`event` in scripts/lib/kc.sh) and
# optionally the test apps' log lines (docs/test-apps-contract.md, `load.sh collect` -> out/apps.jsonl),
# prints one row per rule (PASS/FAIL/SKIP + numbers, up to 5 offending lines) and exits 1 if any rule FAILs.
# A rule whose precondition event is missing (e.g. no `switch`) is SKIP, not FAIL.
# Interpretations (PLAN.md Slice 4):
# - k6 never requests /admin or /account, so "503 only on the frozen paths" reduces to: no 5xx / status 0 at all.
# - A session is born at the t_end of its `login_token` hop; refresh and probe lines carry the login_id that minted the token.
# - invalid_grant = the token endpoint's OAuth `error` field. logout_probe lines are excluded: they must get it.
# - Re-login tie-back: a lost session's user+net has a later successful `relogin` token.
# - Several `switch` events (one run, two flips): rules use the first. ponytail: split runs per flip, or loop over switches.
# - <base>-rollback = every <base> rule plus the flip back (`rollback` event, KEEP_OLD so nothing drained before it).
#   lossy-rollback swaps invalid_grant_in_window for invalid_grant_phases and caps logout_after_replay at `rollback`.
#   Reverse `replay` events are those with from = the switch's `to` color.
# - lossok(birth; t) is THE "lost in the lossy window" excuse, shared by every rule that tolerates a lost session:
#   lossy: born in [copy_point, switch]; lossy-rollback: born in [copy_point, switch] and failing in [switch,
#   rollback+grace), or born in (switch, rollback) and failing after rollback; shared*: never.
# - A flip's moment is [switch, flipped + grace] (rollback: [rollback, flipped + grace]): `switch`/`rollback` is written
#   before set_active patches the Service, `flipped` after it; without `flipped` the event alone. acrossflip() in
#   prelude.jq. Only the "login across a flip" excuse uses it; every other rule keeps the switch event.
# Rule bodies: scripts/gate/prelude.jq (r_* core rules) + scripts/gate/apps.jq (app rules); scripts/report.sh runs the
# same defs for its failure-mode verdicts.
# App rules (scripts/gate/apps.jq; SKIP without app lines / apps.jsonl, every mode):
# - App session = one app login_id; born = t_end of its app callback hop; sid from its /me. Logout = its first logout
#   request (app_logout_start); completed = it has an app_me_after_logout line (logouts cut by the k6 stop have none: not
#   judged). initiator (k6 field on logout lines, docs/test-apps-contract.md): app = POST /logout at the app, which ends
#   its session ITSELF before Keycloak's back-/front-channel call (those then prove delivery only); kc = the browser
#   logs out at Keycloak's end_session directly while the app holds its session, so only the channel call can end it
#   (delivery AND effect are judged).
# - app_login_ok: every app login that reached /me got 200. Lossy modes: a login whose hops cross a flip (acrossflip)
#   is excused (its auth session/code lives on one color only; direct logins are not gated for this either).
# - introspection_ok: no testresource introspection with error/non-200, no k6 introspect call with upstream 5xx/0, and
#   no upstream 401 (= inactive) on a live session (k6 never calls after logout) unless lossok.
# - jwt_ok: every k6 JWT call that reached the resource server got 200. JWTs are validated locally against the same
#   realm keys on both colors, so no lossy excuse.
# - app_refresh_ok: no testclient refresh with ok != true and no k6 app call with error invalid_grant, except
#   invalid_grant under lossok. NB with Keycloak's default 300 s access token the app (sessions <= ~140 s) never
#   refreshes: SKIP unless the testclient-* clients get a shorter access token lifespan.
# - backchannel_delivered: every completed bc logout has an ok backchannel_logout event for its sid at the app within
#   10 s of its start; initiator kc additionally /me 401 after it (Spring answers 200 also for a sid it holds no session
#   for, so ok:true is delivery; /me 401 without a local logout is the effect). Reading for lossy modes: Keycloak sends
#   the back-channel call only for a session it knows. The color serving end_session does not know a session that lives
#   only on the other color: born in the forward window [copy_point, switch] (not copied to green) and logged out after
#   the switch, or (rollback) born on green and logged out after the flip back. Exactly lossok(born; logout start): a
#   missing delivery is excused under it; delivered without effect never is. Logouts outside the apps.jsonl time range
#   (rotated away, or < 10 s before its end) are not judged. backchannel_late (> 2 s) is INFO.
# - frontchannel_ok: every completed fc logout's page had >= 1 iframe (the front-channel URL), every iframe fetch got
#   200, the app logged a frontchannel_logout for the sid (when inside the apps.jsonl range), /me after logout is 401;
#   initiator kc additionally found_session true (the app found and ended the session). The first three are excused
#   under lossok (Keycloak renders no iframe for a session it doesn't know), and then, for kc, /me too. found_session of
#   initiator app is reported, NOT gated: the app's POST /logout ended the session before Keycloak's call (build #14:
#   25/25 found_session false).
# - logout_effective: every completed app logout's /me after logout is 401, and no k6 app call or testclient call
#   event with that sid succeeded (status 200, upstream 200) after it. Excused (counted): /me of a kc logout under
#   lossok to which Keycloak delivered nothing (it did not know the session, a Keycloak-side logout cannot reach the app).
# - latency_*: INFO p50/p95/p99 per step class in pre / cutover / post (windows: scripts/gate/apps.jq);
#   latency_regression lists classes with cutover p95 > 2x pre p95. Reported, not gated.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
. "$(dirname "$0")/lib/kc.sh"
TAG=verification

mode=${1:-} k6=${2:-} ev=${3:-} apps=${4:-/dev/null}
base=${mode%-rollback}
[[ ($base == shared || $base == lossy) && -f $k6 ]]   || die "usage: gate.sh <shared|lossy|shared-rollback|lossy-rollback> <k6-lines.jsonl> <events.jsonl> [apps.jsonl]"
[[ -f $ev ]] || { log "no events file '$ev': treating as empty"; ev=/dev/null; }
[[ -f $apps || $apps == /dev/null ]] || { log "no apps file '$apps': treating as empty"; apps=/dev/null; }
# ponytail: probes this soon after replay_done may still hit a pod whose session cache is ~100 ms stale (stateless outbox).
GRACE=${GATE_GRACE_SECONDS:-1}
# Live k6 sends ~60 requests/s; a longer silence around the cutover means k6 died or everything stalled.
# The synthetic fixtures are sparse, so test-gate.sh raises it for them.
MAX_GAP=${GATE_MAX_GAP_SECONDS:-5}

# Shared jq prelude + app rules (scripts/gate/prelude.jq, scripts/gate/apps.jq; report.sh runs the same files).
# Newline at the end: the rule body follows.
PRE=$(cat "$(dirname "$0")/gate/prelude.jq" "$(dirname "$0")/gate/apps.jq")$'\n'

fails=0
# why <rule>: the rule's "why it matters" line from scripts/gate/why.tsv (every rule should have one)
why() {
  local w; w=$(awk -F'\t' -v r="$1" '$1 == r {print $2}' "$(dirname "$0")/gate/why.tsv")
  [[ -z $w ]] || printf '    why: %s\n' "$w" | fold -s -w 120 | sed '2,$s/^/         /'
}
# rule <name> <jq expr yielding {r, d, bad?}>
rule() {
  local out head r
  out=$(jq -nr --slurpfile k "$k6" --slurpfile e "$ev" --slurpfile a "$apps" --argjson grace "$GRACE" --argjson maxgap "$MAX_GAP" --arg mode "$mode" \
    "$PRE ($2) | \"\(.r)\t\(.d)\", ((.bad // [])[:5][] | del(.ts, .te) | tojson)")
  head=${out%%$'\n'*} r=${head%%$'\t'*}
  printf '%-32s %-5s %s\n' "$1" "$r" "${head#*$'\t'}"
  why "$1"
  [[ $out != *$'\n'* ]] || printf '%s\n' "${out#*$'\n'}" | sed 's/^/      /'
  [[ $r != FAIL ]] || fails=$((fails + 1))
}

echo "gate $mode: $(wc -l < "$k6") k6 lines, $(wc -l < "$apps") app lines; events:"
jq -r '"  \(.t) \(.event)"' "$ev"
printf '%-32s %-5s %s\n' RULE STATE DETAIL

# --- both paths
# shellcheck disable=SC2016
{
rule has_lines 'verdict($L | n > 0; "\($L | n) k6 lines")'
# Build #11: k6 hit its DURATION mid-switch, so the cutover ran without load and most rules had nothing to judge.
rule load_through_cutover 'if $sw == null then skip("no switch event") else
  (($cp // $sw) - 30) as $lo | ([$sw, $rd, $rb, $rrd] | map(select(. != null)) | max + 30) as $hi
  | ([$lo] + [$L[] | .ts | select(. >= $lo and . <= $hi)] + [$hi] | sort) as $t
  | ([range(1; $t | n) as $i | $t[$i] - $t[$i - 1]] | max) as $gap
  | verdict($gap <= $maxgap; "longest gap between k6 requests from \(if $cp then "copy_point" else "switch" end)-30s to the last switch event+30s: \($gap | secs)s (max \($maxgap))") end'
rule issuer_stable r_issuer_stable
rule no_5xx r_no_5xx
rule reads_ok '[$L[] | select(.scenario == "reads")] as $a | [$a[] | select(.status != 200)] as $b
  | verdict($a != [] and $b == []; "\($a | n) reads, \($b | n) not 200") + {bad: $b}'
rule claims_present '[$L[] | select(tok)] as $a
  | [$a[] | select(.sub == null or .iss == null or .claims.login_ctx == null or .claims.tenant == null)] as $b
  | verdict($a != [] and $b == []; "\($a | n) tokens, \($b | n) missing sub/iss/login_ctx/tenant") + {bad: $b}'
rule sub_stable r_sub_stable
}

# --- test apps (k6 scenario app + apps.jsonl), every mode; rules in scripts/gate/apps.jq, readings in the header
{
rule app_login_ok r_app_login
rule introspection_ok r_introspection
rule jwt_ok r_jwt
rule app_refresh_ok r_app_refresh
rule backchannel_delivered r_backchannel
rule backchannel_late r_backchannel_late
rule frontchannel_ok r_frontchannel
rule logout_effective r_logout_effective
rule latency_login 'lat("login")'
rule latency_token 'lat("token")'
rule latency_refresh 'lat("refresh")'
rule latency_app_call_jwt 'lat("app_call_jwt")'
rule latency_app_call_introspect 'lat("app_call_introspect")'
rule latency_introspection 'lat("introspection")'
rule latency_regression r_latency_regression
}

# --- shared (patch case); shared-rollback adds the flip back (same DB, so nothing may be lost either way)
# shellcheck disable=SC2016
[[ $base != shared ]] || {
rule inflight_login r_inflight_login
rule refresh_across_switch r_refresh_across_switch
rule no_invalid_grant r_no_invalid_grant
rule logout_probe_never_ok r_logout_probe_never_ok
}
# shellcheck disable=SC2016
[[ $mode != shared-rollback ]] || {
rule inflight_login_rollback r_inflight_login_rollback
rule refresh_blue_after_rollback r_refresh_blue_after_rollback
rule refresh_green_after_rollback r_refresh_green_after_rollback
}

# --- lossy (minor/major case)
# shellcheck disable=SC2016
[[ $base != lossy ]] || {
rule refresh_pre_copy r_refresh_pre_copy
rule db_copy_caught_up '([$e[] | select(.event == "copy_point")][0]) as $cp
  | ([$e[] | select(.event == "promoted")][0]) as $pr
  | if $cp == null or $pr == null then skip("needs copy_point + promoted")
    elif ($cp.scn // "") == "" or ($pr.scn // "") == "" then verdict(false; "copy_point or promoted has no SCN")
    else verdict((try (($pr.scn | tonumber) >= ($cp.scn | tonumber)) catch false); "copy_point SCN \($cp.scn), green ready at SCN \($pr.scn)") end'
if [[ $mode == lossy ]]; then
rule invalid_grant_in_window r_invalid_grant_in_window
rule logout_after_replay r_logout_after_replay
else
# Blue window sessions [copy_point, switch] are lost on green only; green's sessions (switch, rollback) are lost on blue.
rule invalid_grant_phases r_invalid_grant_phases
rule logout_after_replay r_logout_after_replay
fi
# DeepSeek review: without this, the lossy rules pass vacuously when no window session is ever refreshed on green.
rule window_exercised 'ev("promoted") as $pr | if $pr == null or $sw == null then skip("needs promoted + switch") else
  [$L[] | select(.step == "refresh" and .ts >= $sw + 5 and .ts < ($rb // 1e18) and bornin($pr; $sw))] as $a
  | [$a[] | select(ig | not)] as $b
  | verdict(($a | n) > 0 and $b == []; "\($a | map(.login_id) | unique | n) sessions born on blue after the promote, \($a | n) refreshes on green (switch+5s), \($b | n) not invalid_grant") + {bad: $b} end'
rule relogin_ok r_relogin_ok
# reported, not gated (forward replay counts only: reverse ones have from = the switch target)
rule lossy_seconds 'info(if $cp and $sw then $sw - $cp else null end | secs)'
rule sessions_lost 'info([$L[] | select(.step == "refresh" and ig) | .login_id] | unique | n)'
rule relogins 'info([$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200)] | n)'
rule logouts_replayed 'info([$e[] | select((.event | startswith("replay")) and ($new == null or .from != $new)) | .logouts // empty | tonumber] | max // "n/a")'
rule users_replayed 'info([$e[] | select((.event | startswith("replay")) and ($new == null or .from != $new)) | .users // empty | tonumber] | max // "n/a")'
rule users_repaired 'info("\($repaired | n)\(if $repaired == [] then "" else " (\($repaired | join(" ")))" end)")'
rule resurrection_seconds 'info(if $sw and $rd then $rd - $sw else null end | secs)'
}
# shellcheck disable=SC2016
[[ $mode != lossy-rollback ]] || {
rule refresh_pre_copy_after_rollback r_refresh_pre_copy_after_rollback
rule logout_after_rollback_replay r_logout_after_rollback_replay
# Users first seen on green whose creation the reverse replay must have kept (same id = same sub) on blue.
rule green_users_sub_kept r_green_users_sub_kept
rule green_sessions_lost 'info(if $sw and $rb then [$L[] | select(.step == "refresh" and ig and ((born // -1) as $t | $t > $sw and $t < $rb)) | .login_id] | unique | n else "n/a" end)'
rule window_sessions_back 'if $cp == null or $sw == null or $rb == null then skip("needs copy_point + switch + rollback") else
  [$L[] | select(.step == "refresh" and .status == 200 and .ts >= $rbe + $grace and ((born // -1) as $t | $t >= $cp and $t <= $swe))] as $b
  | verdict($b == []; "\($b | map(.login_id) | unique | n) forward-window sessions refreshed OK after the rollback (rollback.sh purges them on blue)") + {bad: $b} end'
rule relogins_after_rollback 'info([$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200 and .ts >= ($rb // 1e18))] | n)'
rule reverse_logouts_replayed 'info([$e[] | select(.event == "replay" and $new != null and .from == $new) | .logouts // empty | tonumber] | max // "n/a")'
rule reverse_users_replayed 'info([$e[] | select(.event == "replay" and $new != null and .from == $new) | .users // empty | tonumber] | max // "n/a")'
rule resurrection_seconds_rollback 'info(if $rb and $rrd then $rrd - $rb else null end | secs)'
}
# shellcheck disable=SC2016
[[ $base == "$mode" ]] || rule rollback_seconds 'info(if $rbs and $rb then $rb - $rbs else null end | secs)'

if ((fails)); then echo "GATE FAIL ($mode): $fails rule(s) failed"; exit 1; fi
echo "GATE PASS ($mode)"
