#!/usr/bin/env bash
# synth-lossy.sh <src-case-dir> <dst-case-dir> <lossy|lossy-rollback> <from> <to> <shift-days> [apps]
# SYNTHETIC report input for the lossy cases until they have run for real: a real shared/shared-rollback run's k6
# lines, time-shifted, with the lossy switch's events (real script format: switch-lossy.sh, replay.sh, rollback.sh)
# placed around its real switch/rollback, and what the lossy mechanism does to the traffic:
#   - refreshes after the switch of sessions born in [copy_point, switch] -> invalid_grant, then a silent re-login
#     (lossy-rollback also: sessions born in (switch, rollback), refreshed after the rollback)
#   - logins whose hops straddle the switch and started after copy_point -> 400 at the first hop on green
#   - logout probes of sessions born before copy_point and logged out in [copy_point, switch] -> 200 until replay_done
#   - [apps]: testclient/testresource lines (contract schema) for a few app sessions, same loss rules
# Writes k6.jsonl, events.jsonl, SYNTHETIC (and apps.jsonl); run scripts/gate.sh on the result to check it.
set -euo pipefail
src=${1:?src dir} dst=${2:?dst dir} mode=${3:?lossy|lossy-rollback} from=${4:?from} to=${5:?to} days=${6:?shift days}
mkdir -p "$dst"
here=$(dirname "$0")
# shellcheck disable=SC2016 # jq program
prog='
def ts: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("(?<f>\\.[0-9]+)Z$").f // ".0") | "0\(.)" | tonumber);
def iso: (. * 1000 | round) as $ms | ($ms / 1000 | floor | todate | sub("Z$"; "")) + "." + ("00\($ms - ($ms / 1000 | floor) * 1000)" | .[-3:]) + "Z";
def ev($n): [$e[] | select(.event == $n) | .t | ts] | .[0];
($days * 86400) as $sh
| ev("switch") as $S | ev("rollback") as $R | ev("load_stop") as $LS
| ($S - 36) as $cp | ($S + 15.3) as $rd
| ($k | map(. + {ts: (.t_start | ts), te: (.t_end | ts)})) as $L
| ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .te}] | from_entries) as $born
| ([$L[] | select(.step == "logout") ] | group_by(.login_id) | map({key: .[0].login_id, value: (map(.ts) | min)}) | from_entries) as $lo
# logins whose auth session lives in a DB the next color does not have: [first hop, failing hop]
| def lostlogin($a; $b; $t): [$L[] | select(.step | startswith("login_"))] | group_by(.login_id) | map(sort_by(.ts))
    | map(select(.[0].ts >= $a and .[0].ts < $b and .[-1].ts >= $t) | {key: .[0].login_id, value: ([.[] | select(.ts >= $t)][0].ts)}) | from_entries;
  (lostlogin($cp; $S; $S) + (if $mode == "lossy-rollback" then lostlogin($S; $R; $R) else {} end)) as $ll
# sessions lost: login_id -> time of the first refresh on the color without them
| def lostsess($a; $b; $t): [$L[] | select(.step == "refresh" and .ts >= $t) | select(($born[.login_id] // -1) as $x | $x >= $a and $x <= $b)]
    | group_by(.login_id) | map({key: .[0].login_id, value: (map(.ts) | min)}) | from_entries;
  (lostsess($cp; $S; $S) + (if $mode == "lossy-rollback" then lostsess($S + 0.001; $R - 0.001; $R) else {} end)) as $ls
| ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .}] | from_entries) as $tok
| [ $L[]
    | ($lo[.login_id // ""] // -1) as $o | ($born[.login_id // ""] // 1e18) as $b
    | if $ll[.login_id // ""] != null and .ts > $ll[.login_id] then empty
      elif $ll[.login_id // ""] != null and .ts == $ll[.login_id] then .status = 400 | .error = null
      elif .step == "refresh" and $ls[.login_id // ""] != null and .ts > $ls[.login_id] then empty
      elif .step == "refresh" and $ls[.login_id // ""] != null and .ts == $ls[.login_id] then
        (.status = 400 | .error = "invalid_grant" | .sub = null | .iss = null | .claims = {login_ctx: null, tenant: null}),
        ($tok[.login_id] + {scenario: "relogin", login_id: "\(.login_id)r", ts: (.te + 0.3), te: (.te + 0.35)})
      elif .step == "logout_probe" and .status == 400 and .ts >= $S and .ts < $rd
           and $o >= $cp and $o <= $S and $b < $cp
        then .status = 200 | .error = null
      else . end
    | .t_start = (.ts + $sh | iso) | .t_end = (.te + $sh | iso) | del(.ts, .te) ]
| def at($x): ($x + $sh | iso);
  def cnt($a; $b): [$L[] | select(.step == "logout" and .ts >= $a and .ts < $b)] | map(.login_id) | unique | length;
  def newusers($a; $b): [$L[] | select(.step == "login_token" and .status == 200 and ((.user // "user0")[4:] | tonumber) > 4000)]
    | group_by(.user) | map(map(.te) | min | select(. >= $a and . < $b)) | length; # first login of users 4001-5000
  {k6: ., events: (
    [{t: at($S - 95), event: "replica_ready", db: "pg-2", source: "pg-1"},
     {t: at($S - 40), event: "window_start"},
     {t: at($cp), event: "copy_point", lsn: "0/5A0001C8"},
     {t: at($S - 33), event: "promoted", db: "pg-2"},
     {t: at($S - 12), event: "migration", db: "pg-2", from: $from, to: $to, changesets_before: $cb, changesets_after: $ca},
     {t: at($S - 1), event: "replay", from: "blue", to: "green", since: (($cp - 5 + $sh) | floor | todate), logouts: (cnt($cp - 5; $S - 1) | tostring), users: (newusers($cp - 5; $S - 1) | tostring), revokes: "0"},
     {t: at($S), event: "switch", from: "blue", to: "green"},
     {t: at($S + 15.2), event: "replay", from: "blue", to: "green", since: (($cp - 5 + $sh) | floor | todate), logouts: (cnt($cp - 5; $S + 15) | tostring), users: (newusers($cp - 5; $S + 15) | tostring), revokes: "0"},
     {t: at($rd), event: "replay_done"},
     {t: at($S + 15.6), event: "window_end"}]
    + (if $mode == "lossy" then [{t: at($S + 16), event: "drained", color: "blue"}] else
     [{t: at($R - 2), event: "rollback_start", reason: "drill", from: "green", to: "blue"},
      {t: at($R - 1.9), event: "rollback_window_start"},
      {t: at($R - 0.6), event: "replay", from: "green", to: "blue", since: (($S - 5 + $sh) | floor | todate), logouts: (cnt($S - 5; $R - 0.6) | tostring), users: (newusers($S - 5; $R - 0.6) | tostring), revokes: "0"},
      {t: at($R), event: "rollback", from: "green", to: "blue"},
      {t: at($R + 15.1), event: "replay", from: "green", to: "blue", since: (($S - 5 + $sh) | floor | todate), logouts: (cnt($S - 5; $R + 15) | tostring), users: (newusers($S - 5; $R + 15) | tostring), revokes: "0"},
      {t: at($R + 15.2), event: "rollback_replay_done"},
      {t: at($R + 15.5), event: "rollback_window_end"},
      {t: at($R + 30.6), event: "drained", color: "green"}] end)
    + [{t: at($LS), event: "load_stop"}]),
   apps: (if $apps then
    # one app session every 7 s: login, a call every 5 s for 60 s (jwt/introspect alternating), logout at +65 s
    [range(0; ((($LS - 120) - ($L | map(.ts) | min)) / 7) | floor) as $i
     | (($L | map(.ts) | min) + 20 + $i * 7) as $t0 | ["bc-net1", "fc-net2", "bc-net2", "fc-net1"][$i % 4] as $reg
     | ($reg[3:]) as $net | "https://kc-\($net).localtest.me/keycloak/realms/demo" as $iss | "sid-\($i)" as $sid
     | (if $t0 >= $cp and $t0 <= $S then $S + 2.5 else 1e18 end) as $dead
     | {app: "testclient", ts: $t0, event: "login", registration: $reg, sub: "uuid-\(1000 + $i)", sid: $sid, iss: $iss},
       (range(1; 13) as $j | ($t0 + $j * 5) as $tc | (if $j % 2 == 0 then "jwt" else "introspect" end) as $tg
        | (8 + (($i * 37 + $j * 11) % 40) + (if $tc >= $cp and $tc < $rd then 25 else 0 end)) as $lat
        | if $tc > $dead + 5 then empty
          elif $tc >= $dead then
            {app: "testclient", ts: $tc, event: "refresh", registration: $reg, sid: $sid, ok: false, error: "invalid_grant", latency_ms: 21},
            {app: "testclient", ts: $tc, event: "call", target: $tg, status: 401, upstream_status: null, refreshed: false, latency_ms: 23, error: "invalid_grant", sid: $sid, registration: $reg}
          else
            (if $j % 4 == 0 then {app: "testclient", ts: ($tc - 0.02), event: "refresh", registration: $reg, sid: $sid, ok: true, error: null, latency_ms: 19} else empty end),
            {app: "testclient", ts: $tc, event: "call", target: $tg, status: 200, upstream_status: 200, refreshed: ($j % 4 == 0), latency_ms: $lat, error: null, sid: $sid, registration: $reg},
            {app: "testresource", ts: ($tc + 0.005), event: "request", path: "/api/\($tg)", status: 200, latency_ms: ($lat - 3), iss: $iss, sub: "uuid-\(1000 + $i)", error: null},
            (if $tg == "introspect" then {app: "testresource", ts: ($tc + 0.004), event: "introspection", issuer: $iss, http_status: 200, active: true, latency_ms: ($lat - 5), error: null} else empty end)
          end),
       (if $dead < 1e18 then empty else
        {app: "testclient", ts: ($t0 + 65), event: "logout_initiated", registration: $reg, sid: $sid},
        (if ($reg | startswith("bc")) then {app: "testclient", ts: ($t0 + 65.3), event: "backchannel_logout", registration: $reg, sid: $sid, sub: "uuid-\(1000 + $i)", iss: $iss, ok: true, error: null}
         else {app: "testclient", ts: ($t0 + 65.5), event: "frontchannel_logout", sid: $sid, iss: $iss, found_session: true} end) end)
    ] | sort_by(.ts) | map({app, t: (.ts + $sh | iso)} + del(.ts, .app)) else [] end)}
'
jq -n --slurpfile k "$src/k6.jsonl" --slurpfile e "$src/events.jsonl" --arg mode "$mode" --arg from "$from" --arg to "$to" \
  --argjson days "$days" --argjson apps "$([[ ${7:-} == apps ]] && echo true || echo false)" \
  --arg cb "$([[ $from == 25.* ]] && echo 1086 || echo 1342)" --arg ca "1367" "$prog" > "$dst/all.json"
jq -c '.k6[]' "$dst/all.json" > "$dst/k6.jsonl"
jq -c '.events[]' "$dst/all.json" > "$dst/events.jsonl"
if [[ ${7:-} == apps ]]; then jq -c '.apps[]' "$dst/all.json" > "$dst/apps.jsonl"; fi
rm "$dst/all.json"
printf 'SYNTHETIC: generated by report/synth-lossy.sh from a real %s run (%s), time-shifted %s days; lossy events and losses are modelled, not measured.\n' \
  "$(basename "$src")" "$(jq -r 'select(.event == "switch") | .t' "$src/events.jsonl" | head -1)" "$days" > "$dst/SYNTHETIC"
"$here/../scripts/gate.sh" "$mode" "$dst/k6.jsonl" "$dst/events.jsonl" > "$dst/gate.txt" || true
tail -1 "$dst/gate.txt"
