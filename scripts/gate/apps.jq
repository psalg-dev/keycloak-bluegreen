# Rules for the k6 `app` scenario + out/apps.jsonl (docs/test-apps-contract.md). Appended to scripts/gate/prelude.jq,
# so it uses its bindings ($L, $mode, $base, event times, lossok, verdict/skip/info ...). Each r_* yields {r, d, bad?};
# the *_sets / *_judged defs behind them are what scripts/report.sh reuses, so gate and report judge alike.
($a | map(. + {ts: (.t | ts)})) as $A
| [$L[] | select(.scenario == "app")] as $P
# One object per app session (login_id). born = t_end of the app callback hop (the code exchange happens in the app);
# lo = start of the logout (app_logout_start: POST /logout, or GET Keycloak end_session for initiator kc); ini = the
# logout's initiator (app|kc; lines without the field = app); done = the /me after logout (the logout chain is over);
# after = those /me lines.
| ($P | group_by(.login_id) | map(sort_by(.ts) | {id: .[0].login_id, reg: (.[0].registration // ""), lines: .,
    sid: ([.[] | select(.step == "app_me" and .status == 200) | .sid] | .[0]),
    born: ([.[] | select(.step == "app_login_callback") | .te] | .[0]),
    hops: [.[] | select(.step | startswith("app_login_")) | .ts],
    me: [.[] | select(.step == "app_me")],
    lo: ([.[] | select(.step == "app_logout_start") | .ts] | .[0]),
    ini: ([.[] | select(.step == "app_logout_start") | .initiator // "app"] | .[0]),
    after: [.[] | select(.step == "app_me_after_logout")],
    fc: [.[] | select(.step == "app_frontchannel")]}
  | . + {done: (.after[0].ts)})) as $S
| ($S | map(select(.sid != null) | {key: .sid, value: .}) | from_entries) as $bysid
| ([$A[].ts] | min) as $a0 | ([$A[].ts] | max) as $a1
| def sborn: $bysid[.sid // ""].born;
def line($step): .lines | map(select(.step == $step))[0];
def appcalls: .step | startswith("app_call_");

# App logins that reached /me: fail = no /me 200; exc = excused: lossy, hops across a flip (auth session / code live on
# one color only, like direct logins).
def app_logins: [$S[] | select(.me != []) | . + {fail: (any(.me[]; .status == 200) | not)}
  | . + {exc: (.fail and $base == "lossy" and acrossflip(.hops))}];
def r_app_login: app_logins as $a | [$a[] | select(.fail)] as $f | [$f[] | select(.exc)] as $x | [$f[] | select(.exc | not)] as $b
  | if $a == [] then skip("no app logins") else
    verdict($b == []; "\($a | n) app logins, \($b | n) without an app session (/me != 200)\(if $x != [] then ", \($x | n) excused (hops across a lossy flip)" else "" end)")
    + {bad: [$b[] | .lines | map(select(.step | startswith("app_login_")))[-1]]} end;

# ie = testresource introspections, c = k6 introspect calls, e = errors (either side), fi = inactive on a live session
# (k6 never calls after its logout) not excused, x = excused (lossok)
def intro_sets: [$A[] | select(.app == "testresource" and .event == "introspection")] as $ie
  | [$P[] | select(.step == "app_call_introspect")] as $c
  | [$c[] | select(.upstream_status == 401)] as $in | [$in[] | select(lossok(sborn; .ts))] as $x
  | {ie: $ie, c: $c, x: $x, fi: ($in - $x),
     e: [($ie[] | select(.error != null or .http_status != 200)), ($c[] | select(.upstream_status != null and (.upstream_status >= 500 or .upstream_status == 0)))]};
def r_introspection: intro_sets as {ie: $ie, c: $c, e: $e, x: $x, fi: $fi}
  | if $ie == [] and $c == [] then skip("no introspections (no app lines, empty apps.jsonl)") else
    verdict($e == [] and $fi == []; "\($ie | n) introspections at testresource + \($c | n) k6 introspect calls: \($e | n) introspection errors, \($fi | n) inactive for a live session (\($x | n) excused: lost in the window)")
    + {bad: ($e + $fi)} end;

def jwt_sets: [$P[] | select(.step == "app_call_jwt" and .upstream_status != null)] as $a | {a: $a, b: [$a[] | select(.upstream_status != 200)]};
def r_jwt: jwt_sets as {a: $a, b: $b}
  | if $a == [] then skip("no JWT calls reached the resource server") else
    verdict($b == []; "\($a | n) JWT calls at the resource server, \($b | n) not 200") + {bad: $b} end;

# r = testclient refreshes, f = failed ones + k6 app calls with invalid_grant, x = invalid_grant under lossok, b = f - x
def app_refresh_sets: [$A[] | select(.app == "testclient" and .event == "refresh")] as $r
  | [($r[] | select(.ok != true)), ($P[] | select(appcalls and ig))] as $f
  | [$f[] | select(ig and lossok(sborn; .ts))] as $x | {r: $r, f: $f, x: $x, b: ($f - $x)};
def r_app_refresh: app_refresh_sets as {r: $r, f: $f, x: $x, b: $b}
  | if $f == [] and $r == [] then skip("no refreshes by the app (access token outlives the app session?)") else
    verdict($b == []; "\($r | n) app refreshes (testclient), \($r | map(select(.ok != true)) | n) failed; \($P | map(select(appcalls and ig)) | n) k6 calls with invalid_grant; \($x | n) excused (lost in the window)")
    + {bad: $b} end;

# delay of the first ok back-channel logout for the session's sid after its POST /logout (null = none)
def bcdelay: . as $s | [$A[] | select(.event == "backchannel_logout" and .sid == $s.sid and .ok == true and .ts >= $s.lo - 1) | .ts - $s.lo] | min;
def bclogouts: [$S[] | select((.reg | startswith("bc-")) and .lo != null and .after != [] and .sid != null)];
# Judged bc logouts (inside the apps.jsonl range): d = delay of the first ok delivery; why = failure or null: not
# delivered within 10 s, or (initiator kc) delivered but /me after it not 401, i.e. the app did not find/end the session
# (Spring answers 200 also for a sid it has no session for, so ok:true proves delivery, not effect). exc = excused:
# only "not delivered", under lossok (Keycloak does not know the session). Delivered without effect is never excused.
def bc_judged: if $A == [] then [] else [bclogouts[] | select(.lo >= $a0 and .lo <= $a1 - 10) | . + {d: bcdelay}
  | . + {miss: (.d == null or .d > 10)}
  | . + {why: (if .miss then "no ok back-channel logout within 10 s"
      elif .ini == "kc" and any(.after[]; .status != 401) then "Keycloak-initiated: delivered, but /me not 401 (the app did not end the session)"
      else null end), exc: (.miss and lossok(.born; .lo))}] end;
def r_backchannel: bclogouts as $all | if $A == [] then skip("empty apps.jsonl") elif $all == [] then skip("no completed bc logouts") else
    bc_judged as $j | [$j[] | select(.exc)] as $x | [$j[] | select(.why != null and (.exc | not))] as $b | [$j[] | select(.ini == "kc")] as $k
    | verdict($b == []; "\($j | n) bc logouts in the apps log range (\(($all | n) - ($j | n)) outside, not judged; \($k | n) Keycloak-initiated), \($j | map(select(.miss)) | n) without an ok back-channel logout within 10 s, \($x | n) excused (session lost in the window); Keycloak-initiated ended in the app (/me 401 after): \($k | map(select((.miss | not) and all(.after[]; .status == 401))) | n) of \($k | n)")
    + {bad: [$b[] | line("app_logout_start") + {delay: .d, why}]} end;
def r_backchannel_late: [bclogouts[] | select(.lo >= $a0) | bcdelay | select(. != null)] as $d
  | if $d == [] then skip("no delivered back-channel logouts") else
    info("\($d | map(select(. > 2 and . <= 10)) | n) of \($d | n) delivered > 2 s after the logout (max \($d | max | secs) s)") end;

# Completed fc logouts. miss = not delivered: no iframe on the logout page, an iframe not 200, or (inside the apps.jsonl
# range) no frontchannel_logout at the app; exc = miss under lossok (Keycloak renders no iframe for a session it does not
# know). why = what is not excused: the miss; (initiator kc) found_session never true: the app did not find the session;
# /me not 401 after the logout (initiator kc: excused together with an excused miss, nothing reached the app).
# found_session is NOT gated for initiator app: Spring's POST /logout ended the session before Keycloak's call.
def fc_judged: [$S[] | select((.reg | startswith("fc-")) and .after != []) | . as $s
  | ($A != [] and .lo != null and .lo >= $a0 and .lo <= $a1) as $inr
  | [$A[] | select(.event == "frontchannel_logout" and .sid == $s.sid)] as $ev
  | . + {ev: $ev, miss: (if .fc == [] then "no front-channel URL on the logout page" elif any(.fc[]; .status != 200) then "front-channel URL not 200"
      elif $inr and $ev == [] then "no frontchannel_logout at the app" else null end)}
  | . + {exc: (.miss != null and lossok(.born; .lo))}
  | . + {why: ([(if .exc then null else .miss end),
      (if .miss == null and .ini == "kc" and $inr and (any($ev[]; .found_session == true) | not) then "Keycloak-initiated: the app did not find the session (found_session false)" else null end),
      (if any(.after[]; .status != 401) and (.ini != "kc" or (.exc | not)) then "/me not 401 after logout" else null end)]
      | map(select(. != null)) | if . == [] then null else join("; ") end)}];
def r_frontchannel: fc_judged as $c | [$c[] | select(.why != null)] as $b | [$c[] | select(.exc)] as $x
  | [$c[] | select(.ini == "kc")] as $k | [$c[] | select(.ini != "kc")] as $p
  | def found: map(select(any(.ev[]; .found_session == true))) | n;
  if $c == [] then skip("no completed fc logouts") else
    verdict($b == []; "\($c | n) fc logouts (\($k | n) Keycloak-initiated), \($b | n) failed, \($x | n) excused (session lost in the window); app found the session: Keycloak-initiated \($k | found) of \($k | n) (gated), app-initiated \($p | found) of \($p | n) (not gated: the app had ended it itself)")
    + {bad: [$b[] | line("app_logout_start") + {why}]} end;

# Completed app logouts: me = /me after it not 401, calls = successful calls with its sid after it. exc = its /me
# excused: initiator kc, lossok and Keycloak delivered nothing (bc: no ok back-channel event; fc: no iframe fetched with
# 200), i.e. Keycloak did not know the session, so a Keycloak-side logout cannot reach the app. Counted in the detail.
def logouts_judged: [$S[] | select(.after != []) | . as $s
  | . + {me: [.after[] | select(.status != 401)],
      calls: [($P[] | select(.sid == $s.sid and appcalls and .status == 200 and .upstream_status == 200 and .ts > $s.done)),
        ($A[] | select(.event == "call" and .sid == $s.sid and .status == 200 and .upstream_status == 200 and .ts > $s.done))],
      delivered: (if (.reg | startswith("bc-")) then $A != [] and .sid != null and .lo != null and bcdelay != null else any(.fc[]; .status == 200) end)}
  | . + {exc: (.me != [] and .ini == "kc" and (.delivered | not) and lossok(.born; .lo))}];
def r_logout_effective: logouts_judged as $all
  | [$all[] | select(.exc | not) | .me[]] as $me | [$all[] | .calls[]] as $c | [$all[] | select(.exc)] as $x
  | if $all == [] then skip("no completed app logouts") else
    verdict($me == [] and $c == []; "\($all | n) app logouts (\($all | map(select(.ini == "kc")) | n) Keycloak-initiated), \($me | n) with /me != 401 after, \($c | n) successful calls after the logout, \($x | n) excused (Keycloak-initiated on a session lost in the window: Keycloak did not know it)") + {bad: ($me + $c)} end;

# Latency per step class: pre / cutover window(s) / post. Windows: shared [switch-30 s, switch+30 s] (+ the same
# around rollback); lossy [copy_point, replay_done] (+ [rollback_start, rollback_replay_done]). Between two windows = "mid".
def wins: [(if $base == "lossy" then [$cp, $rd] elif $sw != null then [$sw - 30, $sw + 30] else empty end),
    (if $mode == "lossy-rollback" then [$rbs, $rrd] elif $mode == "shared-rollback" and $rb != null then [$rb - 30, $rb + 30] else empty end)]
  | map(select(all(.[]; . != null)));
def phase: . as $t | wins as $w | if $w == [] then "pre" elif any($w[]; $t >= .[0] and $t <= .[1]) then "cut"
  elif $t < $w[0][0] then "pre" elif $t > $w[-1][1] then "post" else "mid" end;
def samples($c): if $c == "introspection" then [$A[] | select(.event == "introspection" and .latency_ms != null) | {ts, ms: .latency_ms}]
  else [$L[] | select(.status != 0 and (if $c == "login" then (.step | test("^(app_)?login_")) and .step != "login_token"
    elif $c == "token" then .step == "login_token" else .step == $c end)) | {ts, ms: ((.te - .ts) * 1000)}] end;
def pct($p): sort | .[([(n * $p | ceil) - 1, 0] | max)];
def p95($c; $ph): [samples($c)[] | select(.ts | phase == $ph) | .ms] | if n == 0 then null else pct(0.95) end;
def lat($c): samples($c) as $s | if $s == [] then skip("no samples") else
  info(["pre", "cut"] + (if (wins | n) > 1 then ["mid"] else [] end) + ["post"] | map(. as $ph | [$s[] | select(.ts | phase == $ph) | .ms]
    | "\($ph) " + if n == 0 then "n=0" else "n=\(n) p50/95/99=\(pct(0.5) | round)/\(pct(0.95) | round)/\(pct(0.99) | round)ms" end) | join(" | ")) end;
def r_latency_regression: if wins == [] then skip("no cutover window") else
  ["login", "token", "refresh", "app_call_jwt", "app_call_introspect", "introspection"]
  | map(. as $c | {c: ., pre: p95($c; "pre"), cut: p95($c; "cut")} | select(.pre != null and .cut != null and .pre > 0 and .cut > 2 * .pre))
  | info(if . == [] then "none (no step class with cutover p95 > 2x pre-switch p95)"
    else map("\(.c) p95 \(.pre | round) -> \(.cut | round) ms (\(.cut / .pre * 10 | round / 10)x)") | join(", ") end) end;
