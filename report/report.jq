# report.jq: one case -> the aggregate report/template.html draws. Run by scripts/report.sh:
#   jq -n -f report/report.jq --slurpfile k <k6.jsonl> --slurpfile e <events.jsonl> --slurpfile a <apps lines>
#     --slurpfile meta <meta.json> --rawfile gate <gate.txt> --arg case/from/to/fp/tp/mech/synthetic ...
# Semantics shared with scripts/gate.sh (keep in sync, gate.sh is not sourceable from jq): ts, the load_stop exclusion
# of k6 self-aborts, session birth = t_end of its login_token, the lossy windows, GRACE = 1 s.
# Failure-mode ids and their expectations: docs/test-apps-contract.md, docs/failure-modes.md.
# Must run on jq 1.7 (Jenkins image, Debian 13) and 1.8 (launcher): every `if` has an `else`.

def ts: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("(?<f>\\.[0-9]+)Z$").f // ".0") | "0\(.)" | tonumber);
def ev($n): [$e[] | select(.event == $n) | .t | ts] | .[0];
def r($d): if . == null then null else (. * $d | round) / $d end;
def pct($p): if length == 0 then null else .[([((length * $p) | ceil) - 1, 0] | max)] end;
def stats: sort | {n: length, p50: pct(0.5), p90: pct(0.9), p95: pct(0.95), p99: pct(0.99), max: .[-1]} | map_values(r(10));
def hop: .step | (startswith("login_") or startswith("app_login_"));
def sclass: .step as $s
  | if ($s | startswith("app_login_")) or (($s | startswith("login_")) and $s != "login_token") then "login_hop"
    elif $s == "login_token" then "token" elif $s == "refresh" then "refresh"
    elif $s == "logout" or $s == "logout_probe" then "logout" elif $s == "discovery" or $s == "jwks" then "reads"
    elif ($s | startswith("app_")) then "app_call" else "other" end;
# failure class of one k6 line for the error chart (null = fine). logout_probe must get invalid_grant: that is success.
def cls:
  if .status == 0 then "net_error" elif .status >= 500 then "http_5xx"
  elif .step == "refresh" then (if .status == 200 then null elif .error == "invalid_grant" then "refresh_lost_session" else "refresh_other_error" end)
  elif .step == "logout_probe" or .step == "app_me_after_logout" then (if .status == 200 then "logout_not_effective" else null end)
  elif hop then (if .status >= 400 then "login_failed" else null end)
  elif .status >= 400 then "other_4xx" else null end;

1 as $grace
| ($e | map(.event)) as $names
| ($k | map(. + {ts: (.t_start | ts), te: (.t_end | ts)})) as $all
| ev("load_stop") as $ls
| [$all[] | select(.status == 0 and $ls != null and .ts >= $ls)] as $aborted
| [$all[] | select((.status == 0 and $ls != null and .ts >= $ls) | not)] as $L
| ev("switch") as $sw | ev("copy_point") as $cp | ev("replay_done") as $rd
| ev("rollback_start") as $rbs | ev("rollback") as $rb | ev("rollback_replay_done") as $rrd
| ($mech | sub("-rollback$"; "")) as $base
| ([$L[].ts] | min) as $tmin | ([$L[].te] | max) as $tmax
| ($sw // $tmin) as $T0
| ($ls // $tmax) as $end
| def rel: if . == null then null else (. - $T0) | r(10) end;
  def after($t; $n): [$e[] | select(.event == $n) | .t | ts | select(. >= $t)] | min;
# Cutover windows (shaded, and the "cutover" latency distribution): forward = [copy_point // switch, window_end //
# recovered // drained // +60 s]; rollback = [rollback_start, rollback_window_end // drained // +60 s].
  ([ if $sw != null then [($cp // $sw), (after($sw; "window_end") // after($sw; "recovered") // after($sw; "drained") // ($sw + 60))] else empty end,
     ($rbs // $rb) as $r0 | if $r0 != null then [$r0, (after($r0; "rollback_window_end") // after($r0; "drained") // ($r0 + 60))] else empty end ]) as $W
| def phase($t): if $W == [] or $t < $W[0][0] then "pre" elif any($W[]; $t >= .[0] and $t < .[1]) then "cut" else "post" end;
  def inw($lo; $hi): . != null and $lo != null and $hi != null and . >= $lo and . <= $hi;

# --- app lines (testclient / testresource, contract schema); [] until the apps exist
  [$a[] | select(.t != null) | . + {ts: (.t | ts)}] as $A
| ([$A[].ts] | max) as $aend
| ([$A[] | select(.app == "testclient" and .event == "login" and .sid != null) | {key: .sid, value: .ts}] | from_entries) as $abirth
| ([$A[] | select(.app == "testclient" and .sid != null and (.event == "logout_initiated" or .event == "backchannel_logout" or .event == "frontchannel_logout"))]
   | group_by(.sid) | map({key: .[0].sid, value: (map(.ts) | min)}) | from_entries) as $aout
| def alive: $aout[.sid // ""] as $o | $o == null or .ts < $o;

# --- sessions and logins (gate semantics)
  ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .te}] | from_entries) as $born
| def born: $born[.login_id // ""];
  ([$aborted[].login_id | select(. != null)] | unique) as $abl
| ([$L[] | select(hop)] | group_by(.login_id) | map(sort_by(.ts))) as $hopsets
| [$hopsets[] | . as $h
    | {first: $h[0].ts, last: $h[-1].ts, te: $h[-1].te, id: $h[0].login_id,
       ok: (if any($h[]; .step | startswith("app_login_")) then all($h[]; .status > 0 and .status < 400)
            else any($h[]; .step == "login_token" and .status == 200) end),
       bad: any($h[]; .status >= 400 or .status == 0)}
    | select(.id as $id | any($abl[]; . == $id) | not)
    | select(.ok or .bad or .last < $end - 30)] as $logins   # still thinking at the end = not judged
| def straddles($t): $t != null and .first < $t and .last >= $t;
# a refresh invalid_grant at $t of a session born at $b that this mechanism loses by design (gate.sh rules)
  def lost_ok($t; $b):
    if $base == "shared" then false
    elif $mech == "lossy" then ($b | inw($cp; $sw))
    else ($b | inw($cp; $sw)) and $t >= $sw and $t < ($rb // 1e18) + $grace
      or ($b != null and $sw != null and $rb != null and $b > $sw and $b < $rb and $t >= $rb) end;
  def probe_ok($t): $base == "lossy" and
    (($t | inw($sw; ($rd // 1e18) + $grace)) or ($rb != null and ($t | inw($rb; ($rrd // 1e18) + $grace))));

# --- failure modes: {attempts (null = no source data), occ: [times], unexp: n, ...}
  def mode($id; $att; $occ; $unexp; $exp; $gate):
    {id: $id, attempts: $att, count: ($occ | length), unexpected: $unexp, expected: $exp, gate: $gate,
     rate: (if ($att // 0) > 0 then ($occ | length) / $att | r(100000) else null end),
     first: ($occ | min | rel), last: ($occ | max | rel),
     phases: {pre: ([$occ[] | select(phase(.) == "pre")] | length), cut: ([$occ[] | select(phase(.) == "cut")] | length),
              post: ([$occ[] | select(phase(.) == "post")] | length)},
     verdict: (if ($att // 0) == 0 then "nodata" elif $unexp > 0 then (if $gate == "report only" then "warn" else "fail" end)
               elif ($occ | length) > 0 then "expected" else "ok" end)};
  def lossy($shared; $lossy; $lrb): if $base == "shared" then $shared elif $mech == "lossy" then $lossy else $lrb end;
  def gated($g): if $g == "" then "report only" else $g end;

  ([$L[] | select(.status >= 500)]) as $x5
| ([$L[] | select(.status == 0)]) as $x0
| ([$logins[] | select(.ok | not)]) as $lf
| ([$logins[] | select(straddles($sw) or straddles($rb))]) as $infl
| ([$L[] | select(.step == "refresh") | {ts, b: born, ok: (.status == 200), ig: (.error == "invalid_grant"), net: (.status == 0)}]
   + [$A[] | select(.app == "testclient" and .event == "refresh") | {ts, b: $abirth[.sid // ""], ok: (.ok == true), ig: (.error == "invalid_grant"), net: false}]) as $rf
| ([$rf[] | select(.ig)]) as $rlost
| ([$L[] | select(.step == "logout_probe" or .step == "app_me_after_logout")]) as $probes
| ([$L[] | select(.iss != null)]) as $isss
| ([$L[] | select(.sub != null and .user != null)] | group_by(.user) | map(sort_by(.ts))) as $users
| ([$users[] | .[0].sub as $s0 | [.[] | select(.sub != $s0)] | select(length > 0) | .[0].ts]) as $subch
| ([$A[] | select(.app == "testresource" and .event == "introspection")]) as $intro
| ([$A[] | select(.app == "testclient" and .event == "call" and .target == "introspect" and (.upstream_status == 200 or .upstream_status == 401) and alive)]) as $icalls
| ([$A[] | select(.app == "testclient" and .event == "call" and .target == "jwt" and (.upstream_status == 200 or .upstream_status == 401) and alive)]) as $jcalls
| def delivered($ev; cond): [$A[] | select(.app == "testclient" and .event == $ev and .sid != null) | select(cond)]
    | group_by(.sid) | map({key: .[0].sid, value: (map(.ts) | min)}) | from_entries;
  delivered("backchannel_logout"; .ok == true) as $bcat
| delivered("frontchannel_logout"; .found_session == true) as $fcat
| def rplogouts($p): [$A[] | select(.app == "testclient" and .event == "logout_initiated" and ((.registration // "") | startswith($p)) and .ts < $aend - 10)];
  ([rplogouts("bc-")[] | . + {d: ($bcat[.sid // ""] as $b | if $b == null or $b - .ts > 10 then null else $b - .ts end)}]) as $bcl
| ([rplogouts("fc-")[] | select(($fcat[.sid // ""] as $f | $f != null and $f - .ts <= 10) | not)]) as $fcbad

# --- latency: per step class, the 3 windows (CDF bins: 10 per decade of ms) and 10 s buckets of p50/p95/p99
| ([$L[] | {c: sclass, ts, ms: ((.te - .ts) * 1000)}]
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
   else {B: $LB, x0: (($lbs | min) * $LB), cls: (reduce ($lat | group_by(.c))[] as $g ({}; . + {($g[0].c): ($g | lseries)}))} end) as $latseries
| ([$dist | to_entries[] | select((.value.pre.n // 0) >= 20 and (.value.cut.n // 0) >= 10)
    | {c: .key, pre: .value.pre.p95, cut: .value.cut.p95, ratio: ((.value.cut.p95 / ([.value.pre.p95, 0.1] | max)) | r(100))}]) as $lr

# --- error/request rate series, 2 s buckets: k6 line classes + app failures
| 2 as $B
| ([$L[] | {ts, c: cls}]
   + [$intro[] | select(.error != null or .http_status != 200) | {ts, c: "introspection_error"}]
   + [$A[] | select(.app == "testclient" and .event == "refresh" and .ok != true)
      | {ts, c: (if .error == "invalid_grant" then "refresh_lost_session" else "refresh_other_error" end)}]
   + [$icalls[] | select(.upstream_status == 401 and .error == null) | {ts, c: "introspection_false_inactive"}]
   + [$jcalls[] | select(.upstream_status == 401 and .error == null) | {ts, c: "jwt_rejected"}]
   | map(. + {b: (((.ts - $T0) / $B) | floor)})) as $pts
| ($pts | map(.b)) as $bs
| (if $bs == [] then null else
    ($pts | group_by(.b) | map({key: (.[0].b | tostring), value: {n: length, c: (map(.c // empty) | group_by(.) | map({key: .[0], value: length}) | from_entries)}}) | from_entries) as $G
    | ([$L[] | (((.ts - $T0) / $B) | floor)] | group_by(.) | map({key: (.[0] | tostring), value: length}) | from_entries) as $N
    | [range($bs | min; ($bs | max) + 1)] as $r
    | {B: $B, x0: (($bs | min) * $B), req: [$r[] | ($N[tostring] // 0) / $B | r(100)],
       err: ([$pts[].c // empty] | unique | map(. as $c | {key: $c, value: [$r[] | ($G[tostring].c[$c] // 0) / $B | r(100)]}) | from_entries)} end) as $series

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
    mode("http_5xx"; ($L | length); [$x5[].ts]; ($x5 | length); "0"; "no_5xx"),
    mode("net_error"; ($L | length); [$x0[].ts]; ($x0 | length); "0 (\($aborted | length) k6 self-aborts after load_stop excluded)"; "no_5xx"),
    mode("login_failed"; ($logins | length); [$lf[].te];
      ([$lf[] | select(($base == "lossy" and (straddles($sw) or straddles($rb))) | not)] | length);
      lossy("0"; "only logins straddling the switch"; "only logins straddling the switch or the rollback"); "report only"),
    mode("inflight_login_broken"; ($infl | length); [$infl[] | select(.ok | not) | .te];
      ([$infl[] | select(.ok | not) | select($base == "shared" or (straddles($sw) and .first < $cp))] | length);
      lossy("0"; "only logins started after copy_point"; "only logins started after copy_point, or straddling the rollback");
      lossy(if $mech == "shared" then "inflight_login" else "inflight_login, inflight_login_rollback" end; "report only"; "report only")),
    mode("refresh_lost_session"; ($rf | length); [$rlost[].ts]; ([$rlost[] | select(lost_ok(.ts; .b) | not)] | length);
      lossy("0"; "only sessions born in [copy_point, switch]";
        "born in [copy_point, switch] and lost before rollback+1 s, or born in (switch, rollback) and lost after rollback");
      lossy("no_invalid_grant"; "invalid_grant_in_window, relogin_ok"; "invalid_grant_phases, relogin_ok")),
    ([$rf[] | select((.ok or .ig or .net) | not)]) as $ro
    | mode("refresh_other_error"; ($rf | length); [$ro[].ts]; ($ro | length); "0";
      lossy("refresh_across_switch (sessions born before switch)"; "refresh_pre_copy (sessions born before copy_point)"; "refresh_pre_copy, refresh_pre_copy_after_rollback")),
    ([$intro[] | select(.error != null or .http_status != 200)]) as $ie
    | mode("introspection_error"; ($intro | length); [$ie[].ts]; ($ie | length); "0"; "report only"),
    ([$icalls[] | select(.upstream_status == 401 and .error == null)]) as $fi
    | mode("introspection_false_inactive"; ($icalls | length); [$fi[].ts]; ([$fi[] | select(lost_ok(.ts; $abirth[.sid // ""]) | not)] | length);
      lossy("0"; "only sessions born in [copy_point, switch]"; "only sessions the lossy rules lose"); "report only"),
    ([$jcalls[] | select(.upstream_status == 401 and .error == null)]) as $jr
    | mode("jwt_rejected"; ($jcalls | length); [$jr[].ts]; ($jr | length); "0 (realm keys live in the DB, copied with it)"; "report only"),
    ([$isss[] | select(.iss != "https://kc-\(.net).localtest.me/keycloak/realms/demo")]) as $im
    | mode("issuer_mismatch"; ($isss | length); [$im[].ts]; ($im | length); "0"; "issuer_stable"),
    mode("sub_changed"; ($users | length); $subch; ($subch | length); "0"; if $mech == "lossy-rollback" then "sub_stable, green_users_sub_kept" else "sub_stable" end),
    ([$probes[] | select(.status == 200)]) as $pr
    | mode("logout_not_effective"; ($probes | length); [$pr[].ts]; ([$pr[] | select(probe_ok(.ts) | not)] | length);
      lossy("0"; "only in [switch, replay_done+1 s) (resurrection window)"; "only in [switch, replay_done+1 s) or [rollback, rollback_replay_done+1 s)");
      lossy("logout_probe_never_ok"; "logout_after_replay (probes after replay_done only)"; "logout_after_replay, logout_after_rollback_replay")),
    ([$bcl[] | select(.d == null)]) as $bm
    | mode("backchannel_missing"; ($bcl | length); [$bm[].ts]; ($bm | length); "0 (within 10 s)"; "report only"),
    ([$bcl[] | select(.d != null and .d > 2)]) as $bl
    | mode("backchannel_late"; ([$bcl[] | select(.d != null)] | length); [$bl[].ts]; ($bl | length); "0 (> 2 s after the logout)"; "report only"),
    mode("frontchannel_failed"; (rplogouts("fc-") | length); [$fcbad[].ts]; ($fcbad | length); "0"; "report only"),
    (mode("latency_regression"; ($lr | length); [$lr[] | select(.ratio > 2) | $W[0][0]]; ([$lr[] | select(.ratio > 2)] | length);
      "0 step classes with cutover p95 > 2x pre-switch p95"; "report only")
     | .first = null | .last = null | .note = ([$lr[] | "\(.c) \(.ratio)x"] | join(", ")))
  ]
}
