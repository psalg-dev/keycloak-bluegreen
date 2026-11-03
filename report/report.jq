# report.jq: one case -> the aggregate report/template.html draws. Run by scripts/report.sh AFTER the gate's own jq
# (scripts/gate/prelude.jq + scripts/gate/apps.jq, concatenated into one program, same bindings):
#   jq -n -f <prelude+apps+report.jq> --slurpfile k <k6.jsonl> --slurpfile e <events.jsonl> --slurpfile a <apps lines>
#     --arg mode <mech> --argjson grace <s> --slurpfile meta <meta.json> --rawfile gate <gate.txt> --arg case/from/to/...
# Every gate-enforced failure mode takes its verdict from the gate's own rule defs (r_*, *_sets, *_judged), so report
# and gate cannot disagree: a mode is "over bound" iff a gate rule it names FAILs on items of this mode's class.
# Failure-mode ids and their expectations: docs/test-apps-contract.md, docs/failure-modes.md.
# Must run on jq 1.7 (Jenkins image, Debian 13) and 1.8 (launcher): every `if` has an `else`.

def ts: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("(?<f>\\.[0-9]+)Z$").f // ".0") | "0\(.)" | tonumber);
def ev($n): [$e[] | select(.event == $n) | .t | ts] | .[0];
def r($d): if . == null then null else (. * $d | round) / $d end;
def pct($p): if length == 0 then null else .[([((length * $p) | ceil) - 1, 0] | max)] end;
def stats: sort | {n: length, p50: pct(0.5), p90: pct(0.9), p95: pct(0.95), p99: pct(0.99), max: .[-1]} | map_values(r(10));
def hop: .step | (startswith("login_") or startswith("app_login_"));
# failure class of one k6 line for the error chart (null = fine). logout_probe must get invalid_grant: that is success.
def cls:
  if .status == 0 then "net_error" elif .status >= 500 then "http_5xx"
  elif .step == "refresh" then (if .status == 200 then null elif .error == "invalid_grant" then "refresh_lost_session" else "refresh_other_error" end)
  elif .step == "logout_probe" or .step == "app_me_after_logout" then (if .status == 200 then "logout_not_effective" else null end)
  elif hop then (if .status >= 400 then "login_failed" else null end)
  elif .status >= 400 then "other_4xx" else null end;

($e | map(.event)) as $names
# $all, $ls, $aborted, $L (the k6 self-abort exclusion) come from scripts/gate/prelude.jq, as in the gate
| ev("switch") as $sw | ev("copy_point") as $cp | ev("replay_done") as $rd
| ev("rollback_start") as $rbs | ev("rollback") as $rb | ev("rollback_replay_done") as $rrd
| ($mech | sub("-rollback$"; "")) as $base
| ([$L[].ts] | min) as $tmin | ([$L[].te] | max) as $tmax
| ($sw // $tmin) as $T0
| ($ls // $tmax) as $end
| def rel: if . == null then null else (. - $T0) | r(10) end;
# Cutover windows $W (shaded, and the "cutover" latency distribution) and phase: scripts/gate/apps.jq, shared with
# the gate. The report has no "mid": between two windows counts as post.
  def phase($t): $t | phase | if . == "mid" then "post" else . end;
  def inw($lo; $hi): . != null and $lo != null and $hi != null and . >= $lo and . <= $hi;

# --- app lines (testclient / testresource, contract schema); [] until the apps exist
  [$a[] | select(.t != null) | . + {ts: (.t | ts)}] as $A

# --- sessions and logins (gate semantics)
| ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .te}] | from_entries) as $born
| def born: $born[.login_id // ""];
  ([$aborted[].login_id | select(. != null)] | unique) as $abl
| ([$L[] | select(hop)] | group_by(.login_id) | map(sort_by(.ts))) as $hopsets
| [$hopsets[] | . as $h
    | {first: $h[0].ts, last: $h[-1].ts, te: $h[-1].te, id: $h[0].login_id,
       ok: any($h[]; .step == "login_token" and .status == 200), app: any($h[]; .step | startswith("app_login_")),
       bad: any($h[]; .status >= 400 or .status == 0)}
    | select(.id as $id | any($abl[]; . == $id) | not)
    | select(.app or .ok or .bad or .last < $end - 30)] as $logins   # direct logins still thinking at the end = not judged

# --- gate rule results (the gate's own defs, prelude.jq / apps.jq) for the rules this mechanism runs (gate.sh blocks;
# test-report.sh checks each named rule is a row of the case's gate.txt with the same state)
| (["no_5xx", "issuer_stable", "sub_stable", "app_login_ok", "introspection_ok", "jwt_ok", "app_refresh_ok",
    "backchannel_delivered", "frontchannel_ok", "logout_effective"]
   + (if $base == "shared" then ["inflight_login", "refresh_across_switch", "no_invalid_grant", "logout_probe_never_ok"]
      else ["refresh_pre_copy", "logout_after_replay", "relogin_ok"] end)
   + (if $mech == "shared-rollback" then ["inflight_login_rollback", "refresh_blue_after_rollback", "refresh_green_after_rollback"]
      elif $mech == "lossy" then ["invalid_grant_in_window"]
      elif $mech == "lossy-rollback" then ["invalid_grant_phases", "refresh_pre_copy_after_rollback", "logout_after_rollback_replay", "green_users_sub_kept"]
      else [] end)) as $active
| def rr($r): if $r == "no_5xx" then r_no_5xx elif $r == "issuer_stable" then r_issuer_stable elif $r == "sub_stable" then r_sub_stable
    elif $r == "app_login_ok" then r_app_login elif $r == "introspection_ok" then r_introspection elif $r == "jwt_ok" then r_jwt
    elif $r == "app_refresh_ok" then r_app_refresh elif $r == "backchannel_delivered" then r_backchannel
    elif $r == "frontchannel_ok" then r_frontchannel elif $r == "logout_effective" then r_logout_effective
    elif $r == "inflight_login" then r_inflight_login elif $r == "refresh_across_switch" then r_refresh_across_switch
    elif $r == "no_invalid_grant" then r_no_invalid_grant elif $r == "logout_probe_never_ok" then r_logout_probe_never_ok
    elif $r == "refresh_pre_copy" then r_refresh_pre_copy elif $r == "logout_after_replay" then r_logout_after_replay
    elif $r == "relogin_ok" then r_relogin_ok elif $r == "inflight_login_rollback" then r_inflight_login_rollback
    elif $r == "refresh_blue_after_rollback" then r_refresh_blue_after_rollback
    elif $r == "refresh_green_after_rollback" then r_refresh_green_after_rollback
    elif $r == "invalid_grant_in_window" then r_invalid_grant_in_window elif $r == "invalid_grant_phases" then r_invalid_grant_phases
    elif $r == "refresh_pre_copy_after_rollback" then r_refresh_pre_copy_after_rollback
    elif $r == "logout_after_rollback_replay" then r_logout_after_rollback_replay
    elif $r == "green_users_sub_kept" then r_green_users_sub_kept else error("report.jq: no def for rule \($r)") end;
  ($active | map({key: ., value: rr(.)}) | from_entries) as $GR
# A mode's share of a gate rule: the rule's bad items of this mode's class (f). The mode is over bound when the rule
# FAILs on items of its class, or (primary owner) the rule FAILs with no bad item at all (nothing to judge).
| def share($r; f; $primary): $GR[$r] as $g | if $g == null then empty else ([($g.bad // [])[] | select(f)] | length) as $m
    | {rule: $r, state: $g.r, mine: $m, fail: ($g.r == "FAIL" and ($m > 0 or ($primary and ($g.bad // []) == [])))} end;

# --- failure modes: attempts (null = no source data), occ: [times], ur: unexpected that no gate rule judges (report
# only), own: [share(...)] the gate rules enforcing the mode. unexpected = gated (the rules' bad items) + ur.
  def mode($id; $att; $occ; $ur; $exp; $own):
    ([$own[].mine] | add // 0) as $ug
    | {id: $id, attempts: $att, count: ($occ | length), unexpected: ($ug + $ur), gated: $ug, expected: $exp,
     rules: [$own[].rule], own: $own, gate: (if $own == [] then "report only" else [$own[].rule] | join(", ") end),
     rate: (if ($att // 0) > 0 then ($occ | length) / $att | r(100000) else null end),
     first: ($occ | min | rel), last: ($occ | max | rel),
     phases: {pre: ([$occ[] | select(phase(.) == "pre")] | length), cut: ([$occ[] | select(phase(.) == "cut")] | length),
              post: ([$occ[] | select(phase(.) == "post")] | length)},
     verdict: (if ($att // 0) == 0 then "nodata" elif any($own[]; .fail) then "fail" elif $ur > 0 then "warn"
               elif ($occ | length) > 0 then "expected" else "ok" end)};
  def lossy($shared; $lossy; $lrb): if $base == "shared" then $shared elif $mech == "lossy" then $lossy else $lrb end;
  def refreshrules: "refresh_across_switch", "refresh_blue_after_rollback", "refresh_green_after_rollback", "refresh_pre_copy",
    "refresh_pre_copy_after_rollback";

  ([$L[] | select(.status >= 500)]) as $x5
| ([$L[] | select(.status == 0)]) as $x0
| ([$logins[] | select(.app | not)]) as $dl
| ([$dl[] | select(.ok | not)]) as $dlf
| ([$dlf[] | select(($base == "lossy" and acrossflip([.first, .last])) | not)]) as $dlu
| app_logins as $al
| ([$L[] | select(.step == "refresh") | {ts, ok: (.status == 200), ig: (.error == "invalid_grant"), net: (.status == 0)}]
   + [$A[] | select(.app == "testclient" and .event == "refresh") | {ts, ok: (.ok == true), ig: (.error == "invalid_grant"), net: false}]) as $rf
| ([$rf[] | select(.ig)]) as $rlost
| ([$L[] | select(.step == "logout_probe" or .step == "app_me_after_logout")]) as $probes
| ([$L[] | select(.iss != null)]) as $isss
| ([$L[] | select(.sub != null and .user != null)] | group_by(.user) | map(sort_by(.ts))) as $users
| ([$users[] | .[0].sub as $s0 | [.[] | select(.sub != $s0)] | select(length > 0) | .[0].ts]) as $subch
| ([$A[] | select(.app == "testresource" and .event == "introspection")]) as $intro
| intro_sets as $isets | jwt_sets as $jsets | bc_judged as $bcj | fc_judged as $fcj
| ((if $sw != null then inflight_sets($sw) else {x: [], b: []} end) as $f | (if $rb != null then inflight_sets($rb) else {x: [], b: []} end) as $r
   | {x: ($f.x + $r.x), b: ($f.b + $r.b), bu: [$f.b[] | select($cp != null and .[0].ts < $cp)]}) as $infl

# --- latency: per step class, the 3 windows (CDF bins: 10 per decade of ms) and 10 s buckets of p50/p95/p99
| ([$L[] | select(.status != 0) | {c: sclass, ts, ms: ((.te - .ts) * 1000)}]   # as regress: a net error has no latency
   + [$intro[] | select(.latency_ms != null) | {c: "introspection", ts, ms: .latency_ms}]) as $lat
| (reduce ($lat | group_by(.c))[] as $g ({}; . + {($g[0].c): (
     ($g | map(. + {p: phase(.ts)}) | group_by(.p) | map({key: .[0].p, value: ((map(.ms) | stats)
       + {bins: (map(if .ms < 1 then 0 else (.ms | log10 * 10 | floor) end) | group_by(.) | map({key: (.[0] | tostring), value: length}) | from_entries)})}) | from_entries))})) as $dist
| 10 as $LB
| ($lat | map(((.ts - $T0) / $LB) | floor)) as $lbs
| def lseries: [range($lbs | min; ($lbs | max) + 1) | tostring] as $r
    | (map(. + {b: (((.ts - $T0) / $LB) | floor)}) | group_by(.b) | map({key: (.[0].b | tostring), value: (map(.ms) | sort)}) | from_entries) as $m
    | {p50: [$r[] | ($m[.] // []) | pct(0.5) | r(10)], p95: [$r[] | ($m[.] // []) | pct(0.95) | r(10)], p99: [$r[] | ($m[.] // []) | pct(0.99) | r(10)]};
  (if $lbs == [] then null
   else {B: $LB, x0: (($lbs | min) * $LB), all: ($lat | lseries),
         cls: (reduce ($lat | group_by(.c))[] as $g ({}; . + {($g[0].c): ($g | lseries)}))} end) as $latseries
| regress as $lr   # the gate's latency_regression classes (scripts/gate/apps.jq)

# --- error/request rate series, 2 s buckets: k6 line classes + app failures
| 2 as $B
| ([$L[] | {ts, c: cls, u: .user}]
   + [$intro[] | select(.error != null or .http_status != 200) | {ts, c: "introspection_error"}]
   + [$A[] | select(.app == "testclient" and .event == "refresh" and .ok != true)
      | {ts, c: (if .error == "invalid_grant" then "refresh_lost_session" else "refresh_other_error" end)}]
   + [($isets.x + $isets.fi)[] | {ts, c: "introspection_false_inactive"}]
   + [$jsets.b[] | {ts, c: "jwt_rejected"}]
   | map(. + {b: (((.ts - $T0) / $B) | floor)})) as $pts
| ($pts | map(.b)) as $bs
| (if $bs == [] then null else
    ($pts | group_by(.b) | map({key: (.[0].b | tostring), value: {n: length, c: (map(.c // empty) | group_by(.) | map({key: .[0], value: length}) | from_entries)}}) | from_entries) as $G
    | ([$L[] | (((.ts - $T0) / $B) | floor)] | group_by(.) | map({key: (.[0] | tostring), value: length}) | from_entries) as $N
    | [range($bs | min; ($bs | max) + 1)] as $r
    | {B: $B, x0: (($bs | min) * $B), req: [$r[] | ($N[tostring] // 0) / $B | r(100)],
       err: ([$pts[].c // empty] | unique | map(. as $c | {key: $c, value: [$r[] | ($G[tostring].c[$c] // 0) / $B | r(100)]}) | from_entries)} end) as $series

# --- user impact: distinct k6 users, of which how many hit an error and how many only had a request slower than 1 s
# (a user counts once; "slow" users are those with no error at all, so errors + slow = affected)
| ([$L[] | select(.user != null) | .user] | unique) as $all_users
| ([$pts[] | select(.c != null and .u != null) | .u] | unique) as $err_users
| ([$L[] | select(.user != null and ((.te - .ts) > 1)) | .user] | unique) as $slow_users
| (($err_users + $slow_users) | unique) as $hit_users

| def ph($p): [$L[] | select(phase(.ts) == $p)];
  def errs: [.[] | select(cls != null)] | length;
  def p95: map((.te - .ts) * 1000) | sort | pct(0.95) | r(10);
  ($gate | split("\n")) as $gl
| ([$e[] | select(.event == "replay" and (.from != ([$e[] | select(.event == "switch") | .to] | .[0])))]) as $fwd
| ([$e[] | select(.event == "replay" and (.from == ([$e[] | select(.event == "switch") | .to] | .[0])))]) as $rev
| ([$e[] | select(.event == "migration")] | .[0]) as $mig
| {
  case: $case, from: $from, to: $to, from_provider: $fp, to_provider: $tp, mechanism: $mech,
  synthetic: (if $synthetic == "" then null else $synthetic end),
  meta: ($meta[0] // {}),
  run: {start: ($all | min_by(.ts) | .t_start), end: ($all | max_by(.te) | .t_end), seconds: (($tmax - $tmin) | r(10)),
        lines: ($L | length), aborted: ($aborted | length)},
  t0: {event: (if $sw then "switch" else "first request" end), t: ([$e[] | select(.event == "switch") | .t] | .[0] // ($all | min_by(.ts) | .t_start))},
  events: [$e[] | {x: (.t | ts | rel), event, d: (del(.t, .event) | to_entries | map("\(.key)=\(.value)") | join(" "))}],
  windows: [$W[] | map(rel)],
  gate: {verdict: ([$gl[] | capture("^GATE (?<v>PASS|FAIL) \\((?<mode>[^)]*)\\)")] | .[0]),
         rules: [$gl[] | capture("^(?<rule>[a-z0-9_]+) +(?<state>PASS|FAIL|SKIP|INFO) +(?<detail>.*)$")]},
  series: $series, latency: $latseries, dist: $dist,
  users: {total: ($all_users | length), errors: ($err_users | length),
          slow: (($slow_users - $err_users) | unique | length), affected: ($hit_users | length), slow_ms: 1000},
  headline: {requests: ($L | length), errors: ($L | errs), error_rate: (if $L == [] then null else ($L | errs) / ($L | length) | r(100000) end),
             cut_requests: (ph("cut") | length), cut_errors: (ph("cut") | errs),
             cut_error_rate: (ph("cut") as $c | if $c == [] then null else ($c | errs) / ($c | length) | r(100000) end),
             p95_pre: (ph("pre") | p95), p95_cut: (ph("cut") | p95), p95_post: (ph("post") | p95)},
  latency_ratios: $lr,
  numbers: ([
    {k: "cutover window(s)", v: ([$W[] | "\(.[0] | rel) .. \(.[1] | rel) s"] | join(", ") | if . == "" then "none (no switch)" else . end)},
    (if $base == "lossy" then
      {k: "lossy window: copy_point -> switch", v: (if $cp and $sw then "\($sw - $cp | r(10)) s" else "n/a" end)},
      {k: "sessions lost (refresh invalid_grant, distinct)", v: ([$L[] | select(.step == "refresh" and .error == "invalid_grant") | .login_id] | unique | length)},
      {k: "silent re-logins", v: ([$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200)] | length)},
      {k: "logouts replayed (forward)", v: ([$fwd[] | .logouts // empty | tonumber] | max // "n/a")},
      {k: "user creations replayed (forward)", v: ([$fwd[] | .users // empty | tonumber] | max // "n/a")},
      {k: "resurrection: switch -> replay_done", v: (if $sw and $rd then "\($rd - $sw | r(100)) s" else "n/a" end)},
      {k: "migration changesets before -> after", v: (if $mig then "\($mig.changesets_before) -> \($mig.changesets_after) (\($mig.from) -> \($mig.to))" else "n/a" end)}
     else
      {k: "pod kill -> recovered", v: (if ev("kill") and ev("recovered") then "\(ev("recovered") - ev("kill") | r(10)) s" else "n/a" end)},
      {k: "switch -> drained", v: (if $sw and ev("drained") then "\(ev("drained") - $sw | r(10)) s" else "n/a" end)}
     end),
    (if $rbs or $rb then
      {k: "rollback: rollback_start -> flip", v: (if $rbs and $rb then "\($rb - $rbs | r(100)) s" else "n/a" end)},
      {k: "time on the new color: switch -> rollback", v: (if $sw and $rb then "\($rb - $sw | r(10)) s" else "n/a" end)}
     else empty end),
    (if $mech == "lossy-rollback" then
      {k: "green-born sessions lost at rollback", v: (if $sw and $rb then [$L[] | select(.step == "refresh" and .error == "invalid_grant" and (born as $t | $t != null and $t > $sw and $t < $rb)) | .login_id] | unique | length else "n/a" end)},
      {k: "logouts / users reverse-replayed", v: "\([$rev[] | .logouts // empty | tonumber] | max // "n/a") / \([$rev[] | .users // empty | tonumber] | max // "n/a")"},
      {k: "resurrection on rollback: rollback -> rollback_replay_done", v: (if $rb and $rrd then "\($rrd - $rb | r(100)) s" else "n/a" end)}
     else empty end)
  ] | map(.v |= tostring)),
  modes: [
    mode("http_5xx"; ($L | length); [$x5[].ts]; 0; "0"; [share("no_5xx"; .status >= 500; false)]),
    mode("net_error"; ($L | length); [$x0[].ts]; 0; "0 (\($aborted | length) k6 self-aborts after load_stop excluded)";
      [share("no_5xx"; .status == 0; false), share(refreshrules; .status == 0; false)]),
    # direct logins: report only (no gate rule in lossy; shared: their in-flight part is inflight_login_broken)
    (mode("login_failed"; ($dl | length) + ($al | length); [$dlf[].te] + [$al[] | select(.fail) | .me[0].ts]; ($dlu | length);
      lossy("0"; "only logins with a hop before the flip and one at/after it; flip = [switch, flipped + \($grace) s] (the switch event alone without a flipped event)";
        "only logins with a hop before a flip and one at/after it; flips = [switch, flipped + \($grace) s], [rollback, flipped + \($grace) s]")
      + "; app logins: gated (app_login_ok), direct logins: report only";
      [share("app_login_ok"; true; false)])
     | .note = (if $dlu == [] then "" else "unexpected direct logins (end of last hop, s): " + ([$dlu[].te | rel | tostring] | .[:20] | join(", ")) end)),
    mode("inflight_login_broken"; ($infl.x | length); [$infl.b[] | .[-1].te]; (if $base == "lossy" then $infl.bu | length else 0 end);
      lossy("0"; "only logins started after copy_point"; "only logins started after copy_point, or straddling the rollback");
      [share("inflight_login"; true; true), share("inflight_login_rollback"; true; true)]),
    mode("refresh_lost_session"; ($rf | length); [$rlost[].ts]; 0;
      lossy("0"; "only sessions born in [copy_point, switch]";
        "born in [copy_point, switch] and lost before rollback+\($grace) s, or born in (switch, rollback) and lost after rollback");
      [share("no_invalid_grant"; true; true), share("invalid_grant_in_window"; true; false), share("invalid_grant_phases"; true; false),
       share("relogin_ok"; true; false), share(refreshrules; ig; false), share("app_refresh_ok"; ig; false)]),
    ([$GR[(refreshrules)] | values | .bad[]? | "\(.login_id)@\(.t_start)"]) as $rgated
    | ([$L[] | select(.step == "refresh" and .status != 200 and .status != 0 and (ig | not)) | "\(.login_id)@\(.t_start)" as $k
        | select(any($rgated[]; . == $k) | not)]) as $rur
    | mode("refresh_other_error"; ($rf | length); [$rf[] | select((.ok or .ig or .net) | not) | .ts]; ($rur | length);
      "0; gated for k6 sessions born before the switch (lossy: copy_point) and app refreshes, report only for the rest";
      [share(refreshrules; (ig | not) and .status != 0; true), share("app_refresh_ok"; ig | not; false)]),
    mode("introspection_error"; ($isets.ie | length) + ($isets.c | length); [$isets.e[].ts]; 0; "0";
      [share("introspection_ok"; (.step == "app_call_introspect" and .upstream_status == 401) | not; false)]),
    mode("introspection_false_inactive"; ([$isets.c[] | select(.upstream_status == 200 or .upstream_status == 401)] | length);
      [($isets.x + $isets.fi)[].ts]; 0; lossy("0"; "only sessions born in [copy_point, switch]"; "only sessions the lossy rules lose (lossok)");
      [share("introspection_ok"; .step == "app_call_introspect" and .upstream_status == 401; false)]),
    mode("jwt_rejected"; ($jsets.a | length); [$jsets.b[].ts]; 0; "0 (realm keys live in the DB, copied with it)"; [share("jwt_ok"; true; false)]),
    ([$isss[] | select(.iss != "https://kc-\(.net).localtest.me/keycloak/realms/demo")]) as $im
    | mode("issuer_mismatch"; ($isss | length); [$im[].ts]; 0; "0"; [share("issuer_stable"; true; true)]),
    mode("sub_changed"; ($users | length); $subch; 0; "0"; [share("sub_stable"; true; false), share("green_users_sub_kept"; true; false)]),
    mode("logout_not_effective"; ($probes | length);
      [$probes[] | select(if .step == "logout_probe" then .status == 200 else .status != 401 end) | .ts];
      ([$probes[] | select(.step == "logout_probe" and .status == 200 and $base == "lossy" and ($sw == null or .ts < $sw))] | length);
      lossy("0";
        "probes: only in [switch, replay_done+\($grace) s) (resurrection window); app /me: only Keycloak-initiated logouts of sessions lost in the window (Keycloak did not know them)";
        "probes: only in [switch, replay_done+\($grace) s) or [rollback, rollback_replay_done+\($grace) s); app /me: only Keycloak-initiated logouts of sessions the lossy rules lose");
      [share("logout_probe_never_ok"; true; true), share("logout_after_replay"; true; true), share("logout_after_rollback_replay"; true; true),
       share("logout_effective"; true; false)]),
    mode("backchannel_missing"; ($bcj | length); [$bcj[] | select(.why != null or .exc) | .lo]; 0;
      "0: ok delivery within 10 s, Keycloak-initiated also /me 401 after it" + lossy(""; "; undelivered only for sessions lost in the window (lossok)"; "; undelivered only for sessions the lossy rules lose (lossok)");
      [share("backchannel_delivered"; true; false)]),
    ([$bcj[] | select(.d != null and .d <= 10)]) as $bd
    | mode("backchannel_late"; ($bd | length); [$bd[] | select(.d > 2) | .lo]; ([$bd[] | select(.d > 2)] | length); "0 (> 2 s after the logout)"; []),
    mode("frontchannel_failed"; ($fcj | length); [$fcj[] | select(.why != null or .exc) | .lo]; 0;
      "0: iframe on the logout page, fetched 200, frontchannel_logout at the app, /me 401; Keycloak-initiated also found_session true"
      + lossy(""; "; undelivered only for sessions lost in the window (lossok)"; "; undelivered only for sessions the lossy rules lose (lossok)");
      [share("frontchannel_ok"; true; false)]),
    (mode("latency_regression"; ($lr | length); [$lr[] | select(.ratio > 2) | $W[0][0]]; ([$lr[] | select(.ratio > 2)] | length);
      "0 step classes with cutover p95 > 2x pre-switch p95"; [])
     | .first = null | .last = null | .note = ([$lr[] | "\(.c) \(.ratio)x"] | join(", ")))
  ]
}
