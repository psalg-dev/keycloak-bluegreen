# Rules for the k6 `app` scenario + out/apps.jsonl (docs/test-apps-contract.md). Appended to gate.sh's prelude, so it
# uses its bindings ($L, $mode, $base, event times, lossok, verdict/skip/info ...). Each r_* yields {r, d, bad?}.
($a | map(. + {ts: (.t | ts)})) as $A
| [$L[] | select(.scenario == "app")] as $P
# One object per app session (login_id). born = t_end of the app callback hop (the code exchange happens in the app);
# lo = start of POST /logout; done = the /me after logout (the logout chain is over); after = those /me lines.
| ($P | group_by(.login_id) | map(sort_by(.ts) | {id: .[0].login_id, reg: (.[0].registration // ""), lines: .,
    sid: ([.[] | select(.step == "app_me" and .status == 200) | .sid] | .[0]),
    born: ([.[] | select(.step == "app_login_callback") | .te] | .[0]),
    hops: [.[] | select(.step | startswith("app_login_")) | .ts],
    me: [.[] | select(.step == "app_me")],
    lo: ([.[] | select(.step == "app_logout_start") | .ts] | .[0]),
    after: [.[] | select(.step == "app_me_after_logout")],
    fc: [.[] | select(.step == "app_frontchannel")]}
  | . + {done: (.after[0].ts)})) as $S
| ($S | map(select(.sid != null) | {key: .sid, value: .}) | from_entries) as $bysid
| ([$A[].ts] | min) as $a0 | ([$A[].ts] | max) as $a1
| def sborn: $bysid[.sid // ""].born;
def line($step): .lines | map(select(.step == $step))[0];
def appcalls: .step | startswith("app_call_");

def r_app_login: [$S[] | select(.me != [])] as $a | [$a[] | select(any(.me[]; .status == 200) | not)] as $f
  # lossy: a login whose hops straddle a flip may lose its auth session / code (expected, like direct logins)
  | [$f[] | select(.hops as $h | $base == "lossy" and any($sw, $rb; . != null and ($h | min) < . and ($h | max) >= .))] as $x
  | ($f - $x) as $b
  | if $a == [] then skip("no app logins") else
    verdict($b == []; "\($a | n) app logins, \($b | n) without an app session (/me != 200)\(if $x != [] then ", \($x | n) excused (hops across a lossy flip)" else "" end)")
    + {bad: [$b[] | .lines | map(select(.step | startswith("app_login_")))[-1]]} end;

def r_introspection: [$A[] | select(.app == "testresource" and .event == "introspection")] as $ie
  | [$P[] | select(.step == "app_call_introspect")] as $c
  | [($ie[] | select(.error != null or .http_status != 200)), ($c[] | select(.upstream_status != null and (.upstream_status >= 500 or .upstream_status == 0)))] as $e
  | [$c[] | select(.upstream_status == 401)] as $in | [$in[] | select(lossok(sborn; .ts))] as $x | ($in - $x) as $fi
  | if $ie == [] and $c == [] then skip("no introspections (no app lines, empty apps.jsonl)") else
    verdict($e == [] and $fi == []; "\($ie | n) introspections at testresource + \($c | n) k6 introspect calls: \($e | n) introspection errors, \($fi | n) inactive for a live session (\($x | n) excused: lost in the window)")
    + {bad: ($e + $fi)} end;

def r_jwt: [$P[] | select(.step == "app_call_jwt" and .upstream_status != null)] as $a | [$a[] | select(.upstream_status != 200)] as $b
  | if $a == [] then skip("no JWT calls reached the resource server") else
    verdict($b == []; "\($a | n) JWT calls at the resource server, \($b | n) not 200") + {bad: $b} end;

def r_app_refresh: [$A[] | select(.app == "testclient" and .event == "refresh")] as $r
  | [($r[] | select(.ok != true)), ($P[] | select(appcalls and ig))] as $f
  | [$f[] | select(ig and lossok(sborn; .ts))] as $x | ($f - $x) as $b
  | if $f == [] and $r == [] then skip("no refreshes by the app (access token outlives the app session?)") else
    verdict($b == []; "\($r | n) app refreshes (testclient), \($r | map(select(.ok != true)) | n) failed; \($P | map(select(appcalls and ig)) | n) k6 calls with invalid_grant; \($x | n) excused (lost in the window)")
    + {bad: $b} end;

# delay of the first ok back-channel logout for the session's sid after its POST /logout (null = none)
def bcdelay: . as $s | [$A[] | select(.event == "backchannel_logout" and .sid == $s.sid and .ok == true and .ts >= $s.lo - 1) | .ts - $s.lo] | min;
def bclogouts: [$S[] | select((.reg | startswith("bc-")) and .lo != null and .after != [] and .sid != null)];
def r_backchannel: bclogouts as $all | if $A == [] then skip("empty apps.jsonl") elif $all == [] then skip("no completed bc logouts") else
    [$all[] | select(.lo >= $a0 and .lo <= $a1 - 10) | . + {d: bcdelay}] as $j
    | [$j[] | select(.d == null or .d > 10)] as $m | [$m[] | select(lossok(.born; .lo))] as $x | ($m - $x) as $b
    | verdict($b == []; "\($j | n) bc logouts in the apps log range (\(($all | n) - ($j | n)) outside, not judged), \($m | n) without an ok back-channel logout within 10 s, \($x | n) excused (session lost in the window)")
    + {bad: [$b[] | line("app_logout_start") + {delay: .d}]} end;
def r_backchannel_late: [bclogouts[] | select(.lo >= $a0) | bcdelay | select(. != null)] as $d
  | if $d == [] then skip("no delivered back-channel logouts") else
    info("\($d | map(select(. > 2 and . <= 10)) | n) of \($d | n) delivered > 2 s after the logout (max \($d | max | secs) s)") end;

def r_frontchannel: [$S[] | select((.reg | startswith("fc-")) and .after != [])] as $all
  | [$all[] | . as $s | . + {why: (
      if .fc == [] then "no front-channel URL on the logout page"
      elif any(.fc[]; .status != 200) then "front-channel URL not 200"
      elif $A != [] and .lo >= $a0 and .lo <= $a1 and ([$A[] | select(.event == "frontchannel_logout" and .sid == $s.sid)] == []) then "no frontchannel_logout at the app"
      else null end)}] as $c
  | [$c[] | select(.why != null)] as $f | [$f[] | select(lossok(.born; .lo))] as $x
  | (($f - $x) + [$c[] | select(any(.after[]; .status != 401)) | . + {why: "/me not 401 after logout"}]) as $b
  | [$A[] | select(.event == "frontchannel_logout")] as $ev
  | if $all == [] then skip("no completed fc logouts") else
    verdict($b == []; "\($all | n) fc logouts, \($b | n) failed, \($x | n) excused (session lost in the window); app found the session in \($ev | map(select(.found_session == true)) | n) of \($ev | n) front-channel calls (not gated)")
    + {bad: [$b[] | line("app_logout_start") + {why}]} end;

def r_logout_effective: [$S[] | select(.after != [])] as $all
  | [$all[] | .after[] | select(.status != 401)] as $me
  | [$all[] | . as $s | ($P[] | select(.sid == $s.sid and appcalls and .status == 200 and .upstream_status == 200 and .ts > $s.done)),
      ($A[] | select(.event == "call" and .sid == $s.sid and .status == 200 and .upstream_status == 200 and .ts > $s.done))] as $c
  | if $all == [] then skip("no completed app logouts") else
    verdict($me == [] and $c == []; "\($all | n) app logouts, \($me | n) with /me != 401 after, \($c | n) successful calls after the logout") + {bad: ($me + $c)} end;

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
