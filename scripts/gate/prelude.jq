# Shared jq prelude of scripts/gate.sh AND scripts/report.sh (one definition of every gate semantics):
# $L = k6 lines with numeric ts/te (epoch s), event times, session birth times, the loss excuse, rule helpers.
# Needs --slurpfile k/e/a, --arg mode, --argjson grace. scripts/gate/apps.jq continues the pipeline.

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
($mode | sub("-rollback$"; "")) as $base |
($k | map(. + {ts: (.t_start | ts), te: (.t_end | ts)})) as $all
# Requests k6 aborts itself on SIGINT (status 0, still in flight at load_stop: ending at/after it) are not server
# behaviour: no rule sees them. By end, not start: build #20 had one started 17 ms before load_stop, aborted with the rest.
| ev("load_stop") as $ls
| [$all[] | select(.status == 0 and $ls != null and .te >= $ls)] as $aborted
| [$all[] | select((.status == 0 and $ls != null and .te >= $ls) | not)] as $L
| ev("switch") as $sw | ev("copy_point") as $cp | ev("replay_done") as $rd
| ev("rollback_start") as $rbs | ev("rollback") as $rb | ev("rollback_replay_done") as $rrd
| ([$e[] | select(.event == "switch") | .to] | .[0]) as $new
# users a replay found duplicated on its target (created there after the flip, before the replay) and restored to the
# original id (scripts/replay.sh): their sub changed for seconds; counted, and excused in the sub rules
| ([$e[] | select(.event == "replay") | .repaired // "" | split(" ")[] | select(. != "")] | unique) as $repaired
| ([$L[] | select(.step == "login_token" and .status == 200) | {key: .login_id, value: .te}] | from_entries) as $born
| def born: $born[.login_id // ""];
# A flip's moment is known only as [switch, flipped] (rollback: [rollback, flipped]): the event is written before
# set_active patches the Service, `flipped` once ingress-nginx's own upstream list holds only the new color
# (kc.sh wait_routed); + grace for requests nginx had already sent. No `flipped` (older runs, fixtures): the event alone.
def flipwin($t): if $t == null then empty
  else [$t, ([$e[] | select(.event == "flipped") | .t | ts | select(. >= $t)] | min | if . == null then $t else . + $grace end)] end;
# Lossy-rollback: window sessions are lost on green AND, after the rollback, on blue too (rollback.sh purges blue's
# sessions born after the copy point: purge-sessions.sh). Lossy windows end when traffic really moved, not at the switch event: laptop build #24 had a session born on blue
# 2.8 s after `switch` (nginx still routed there), lost on green, and not excused while the window ended at `switch`.
([flipwin($sw)] | .[0][1] // $sw) as $swe | ([flipwin($rb)] | .[0][1] // $rb) as $rbe
| def lossok($t; $at): $t != null and $cp != null and $sw != null and
  if $mode == "lossy" then $t >= $cp and $t <= $swe
  elif $mode == "lossy-rollback" then $rb != null
    and (($t >= $cp and $t <= $swe and $at >= $sw) or ($t > $sw and $t < $rbe and $at >= $rb))
  else false end;
def bornin($lo; $hi): born as $t | $t != null and $t >= $lo and $t < $hi;
# direct logins (hop lines, sorted) with a hop before $t and the next at/after it: {x: all, b: failed ones}
def inflight_sets($t): [$L[] | select(hop)] | group_by(.login_id) | map(sort_by(.ts))
  | [.[] | select(. as $h | any(range(0; n - 1); $h[.].ts < $t and $h[. + 1].ts >= $t))] as $x
  | {x: $x, b: [$x[] | select(any(.[]; .status >= 400 or .status == 0) or (any(.[]; .step == "login_token" and .status == 200) | not))]};
def inflight($t; $what): inflight_sets($t) as {x: $x, b: $b}
  | verdict(($x | n) > 0 and $b == []; "\($x | n) logins with a hop before \($what) and the next after it, \($b | n) failed (last hop shown)") + {bad: [$b[][-1]]};
def acrossflip($ts): ($ts | min) as $a | ($ts | max) as $z | any(flipwin($sw), flipwin($rb); $a < .[1] and $z >= .[0]);
def refresh_ok($lo; $hi; $after; $what; $when):
  [$L[] | select(.step == "refresh" and .ts >= $after and bornin($lo; $hi))] as $a | [$a[] | select(.status != 200)] as $b
  | verdict($a != [] and $b == []; "\($a | map(.login_id) | unique | n) sessions born \($what), \($a | n) refreshes after \($when), \($b | n) failed") + {bad: $b};
def probes_ig($from; $to; $what): [$L[] | select(.step == "logout_probe" and .ts >= $from + $grace and .ts < $to)] as $a
  | [$a[] | select(ig | not)] as $b | verdict($a != [] and $b == []; "\($a | n) probes after \($what), \($b | n) not invalid_grant") + {bad: $b};

# Gated rules (gate.sh runs them per mode; scripts/report.sh reuses them for the failure-mode verdicts).
def r_issuer_stable: [$L[] | select(.iss != null)] as $a
  | [$a[] | select(.iss != "https://kc-\(.net).localtest.me/keycloak/realms/demo")] as $b
  | verdict($a != [] and $b == []; "\($a | n) issuers (\([$a[] | select($sw == null or .ts < $sw)] | n) before switch), \($b | n) not the one of their net") + {bad: $b};
def r_no_5xx: [$L[] | select(.status >= 500 or .status == 0)] as $b
  | verdict($b == []; "\($b | n) of \($L | n) responses >= 500 or status 0 (\($aborted | n) aborted by the k6 stop, not judged)") + {bad: $b};
def r_sub_stable: [$L[] | select(.sub != null and .user != null)] | group_by(.user)
  | [.[] | select(map(.sub) | unique | n > 1)] as $c | [$c[] | select(.[0].user | IN($repaired[]) | not)] as $b
  | verdict($b == []; "\(n) users, \($b | n) with more than one sub (\(($c | n) - ($b | n)) excused: repaired by the replay, first sub restored)")
    + {bad: [$b[] | {user: .[0].user, subs: (map(.sub) | unique)}]};
def r_inflight_login: if $sw == null then skip("no switch event") else inflight($sw; "switch") end;
def r_inflight_login_rollback: if $rb == null then skip("no rollback event") else inflight($rb; "rollback") end;
def r_refresh_across_switch: if $sw == null then skip("no switch event") else refresh_ok(-1e18; $sw; $sw; "before switch"; "it") end;
def r_no_invalid_grant: [$L[] | select(ig and .step != "logout_probe")] as $b
  | verdict($b == []; "\($b | n) invalid_grant (logout_probe excluded)") + {bad: $b};
def r_logout_probe_never_ok: [$L[] | select(.step == "logout_probe")] as $a | [$a[] | select(.status == 200)] as $b
  | verdict($b == []; "\($a | n) probes, \($b | n) refreshed a logged-out session") + {bad: $b};
def r_refresh_blue_after_rollback: if $sw == null or $rb == null then skip("needs switch + rollback") else
  refresh_ok(-1e18; $sw; $rb; "before switch"; "rollback") end;
def r_refresh_green_after_rollback: if $sw == null or $rb == null then skip("needs switch + rollback") else
  refresh_ok($sw; $rb; $rb; "in [switch, rollback)"; "rollback") end;
def r_refresh_pre_copy: if $cp == null or $sw == null then skip("needs copy_point + switch") else
  refresh_ok(-1e18; $cp; $sw; "before copy_point"; "switch") end;
# repok: the line's user was repaired by a replay (scripts/replay.sh deleted the duplicate the new color had made, so
# that duplicate's sessions died after the switch: a silent re-login, the documented price of keeping the first sub)
def repok: (.user // "") as $u | $u != "" and ($u | IN($repaired[])) and .ts >= $sw;
def r_invalid_grant_in_window: if $cp == null or $sw == null then skip("needs copy_point + switch") else
  [$L[] | select(.step == "refresh" and ig)] as $a | [$a[] | select((lossok(born; .ts) or repok) | not)] as $b
  | verdict($b == []; "\($a | n) refresh invalid_grant, \($b | n) on sessions not born in [copy_point, flip] (\([$a[] | select(repok)] | n) excused: a repaired user's duplicate)") + {bad: $b} end;
def r_logout_after_replay: if $mode == "lossy-rollback" then if $rd == null or $rb == null then skip("needs replay_done + rollback") else
  probes_ig($rd; $rb; "replay_done+\($grace)s and before rollback") end
  else if $rd == null then skip("no replay_done event") else probes_ig($rd; 1e18; "replay_done+\($grace)s") end end;
def r_invalid_grant_phases: if $cp == null or $sw == null or $rb == null then skip("needs copy_point + switch + rollback") else
  [$L[] | select(.step == "refresh" and ig)] as $a
  | [$a[] | select((lossok(born; .ts) or repok) | not)] as $b
  | verdict($b == []; "\($a | n) refresh invalid_grant, \($b | n) not (born in [copy_point, flip] and lost after the switch) nor (born in (switch, rollback flip) and lost after rollback) nor a repaired user's duplicate") + {bad: $b} end;
def r_relogin_ok: [$L[] | select(.step == "refresh" and ig)] as $a
  | [$L[] | select(.scenario == "relogin" and .step == "login_token" and .status == 200)] as $ok
  | [$a[] | . as $i | select(any($ok[]; .user == $i.user and .net == $i.net and .ts >= $i.te) | not)] as $b
  | verdict($b == []; "\($a | n) lost sessions, \(($a | n) - ($b | n)) re-logged in OK") + {bad: $b};
def r_refresh_pre_copy_after_rollback: if $cp == null or $rb == null then skip("needs copy_point + rollback") else
  refresh_ok(-1e18; $cp; $rb; "before copy_point"; "rollback") end;
def r_logout_after_rollback_replay: if $rrd == null then skip("no rollback_replay_done event") else
  probes_ig($rrd; 1e18; "rollback_replay_done+\($grace)s") end;
def r_green_users_sub_kept: if $sw == null or $rb == null then skip("needs switch + rollback") else
  [$L[] | select(.sub != null and .user != null)] | group_by(.user) | map(sort_by(.ts))
  | [.[] | select(.[0].ts >= $sw and .[0].ts < $rb and any(.[]; .ts >= $rb))] as $g
  | [$g[] | select((map(.sub) | unique | n > 1) and (.[0].user | IN($repaired[]) | not))] as $b
  | if $g == [] then skip("no user first seen in [switch, rollback) has a token after rollback") else
    verdict($b == []; "\($g | n) users first seen on green with a token after rollback, \($b | n) with a changed sub")
    + {bad: [$b[] | {user: .[0].user, subs: (map(.sub) | unique)}]} end end;
