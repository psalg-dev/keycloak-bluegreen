# Failure modes: what a cutover can break, and how it is measured

The specification behind the results report (`scripts/report.sh` -> `out/report.html`) and the gate
(`scripts/gate.sh`). The ids are the contract's (`docs/test-apps-contract.md`, "Failure modes the report must
quantify") and are stable: gate, report and this document use the same names. It exists so that a discussion of
"is this cutover good enough" can argue about defined numbers instead of impressions.

## Measurement setup

**Cases** (`cases.env`): `patch` 26.8.0 -> 26.8.1 on a shared DB; `minor` 26.7.5 -> 26.8.1 and `major` 25.0.6 ->
26.8.1 with the lossy overlap (own DB per color); `patch-rollback` and `minor-rollback` switch, soak 90 s on the new
color, then flip back. Each case is standalone: reset, install blue, warm up 120 s under load, switch (and roll back),
cool down 90 s, stop the load, gate (`scripts/demo.sh`).

**Load** (`load/k6/flows.js`, one k6 Job in the cluster, through the ingress like a browser):

| k6 scenario | rate | what it does |
|---|---|---|
| `login` | 2 logins/s (constant arrival) | full brokered auth-code flow, every hop logged: KC `/auth` -> legacy IdP authorize -> legacy login form (think time 0-20 s) -> POST -> KC broker endpoint -> (first-broker-login form) -> code -> `/token`. 80 % users 1-4000 (pre-linked), 20 % 4001-5000 (created on first login). Each session sticks to net1 or net2. |
| `refresh` | 10 VUs, one refresh every 5 s | holds a session and refreshes it; on `invalid_grant` a silent re-login (`relogin`) through the legacy IdP's SSO. Half the VUs start a new session every 60 s, so sessions are born on every color. |
| `logout` | 4 VUs, one logout per VU every ~45 s | login, RP-initiated logout (`id_token_hint`, following the brokered round trip), then probes the logged-out refresh token every 5 s until the end (`logout_probe`, must get `invalid_grant`). |
| `reads` | 1/s per network | discovery + JWKS. |
| `app` | 3 VUs | browser login through the test client app, `/call/jwt` and `/call/introspect` every 5 s for 30-120 s, then a logout with back- or front-channel delivery: half `initiator: app` (POST /logout at the app, which ends its own session first), half `initiator: kc` (the browser logs out at Keycloak's end_session directly while the app holds its session: only the channel call can end it). |

Roughly 25-30 k6 requests/s, 12 000-31 000 lines per case. Every request is one JSON line (schema at the top of
`flows.js`); the switch scripts write one JSON line per step to `events.jsonl` (`event` in `scripts/lib/kc.sh`). The
test apps (once built) log one JSON line per login/call/refresh/logout/introspection to `apps.jsonl`
(`docs/test-apps-contract.md`). Nothing else is measured: no server-side metrics, no edge logs.

**Impact per user.** The report counts each `user` (present on every k6 line) once and marks it *potentially impacted*
when it had at least one error line (any failure class above) or at least one request slower than 1 s. The case tab
splits "hit an error" from "slow only"; the Overview column is the union over the users seen in that run. This is the
number to quote for user experience: an error rate of 0.23 % of 23 451 requests reads differently as "26 of 1 252
users", because a lost session costs one person a re-login, not one request.

**Time.** All times are seconds relative to the first `switch` event (t = 0). k6 and the scripts share the host
clock (KinD containers on one machine). A request belongs to the moment it started (`t_start`).

**network latency** = each request's duration as the k6 client measures it (`t_end - t_start`): the network round
trip plus the server's own processing (the demo has no server-side timing). The charts, the gate's `latency_*` rows
and `latency_regression` all use it.

**Windows** (report, the gate's `latency_*` rows and `latency_regression`; the shaded band in every time chart; one
definition, `$W` in `scripts/gate/apps.jq`, half-open):

| window | definition |
|---|---|
| pre-switch | before the first cutover window starts |
| cutover | forward: [`copy_point` (lossy) or `switch` (shared), `window_end` (lossy) or `recovered` (shared, the killed pod is back) or `drained`, else +60 s]; rollback cases add [`rollback_start`, `rollback_window_end` or `drained`, else +60 s] |
| post-switch | everything else after the first window start (for rollback cases this includes the soak on the new color) |

The gate's own windows are event boundaries, used per rule: before/after `switch`; the lossy window
[`copy_point`, `switch`]; the resurrection window [`switch`, `replay_done` + 1 s]; for rollbacks [`switch`,
`rollback`) and [`rollback`, `rollback_replay_done` + 1 s]. The report uses exactly those for "expected".
The flip itself (the Service selector patch) happens AFTER the `switch` / `rollback` event: the scripts write the event,
then `set_active` reads state and patches, then write `flipped`. "A login across a flip" means a hop before the flip
window's end and one at/after its start, flip window = [`switch`, `flipped` + 1 s] (the 1 s: ingress-nginx following
the endpoints); runs without `flipped` use the event alone (`acrossflip` in `scripts/gate/prelude.jq`).

**Exclusions** (same as the gate): requests with status 0 still in flight at `load_stop` (ending at/after it; by end, since build #20 had one started 17 ms before) are k6 aborting itself on
SIGINT, not server behaviour; they are counted ("aborted") and judged by no rule. Logins still in their think time at
the end of the data (no failed hop, no token, last hop < 30 s before the end) are not judged.

**Limits.** One machine (KinD, 3 worker nodes in Docker, 3 Keycloak pods per color, the database in-cluster;
`PROFILE=laptop`: 2 workers, 2 pods per color, ~2 logins/s): k6, both
colors, the database and the legacy IdP compete for the same CPUs, so latency numbers are relative (pre vs cutover), never
absolute capacity numbers. Synthetic load at a fixed, modest rate (~2 logins/s): rare races need far more traffic to
show up. One run per case: a count of 0 is "not seen in this run", not a probability; compare rates across runs before
calling something fixed. No real network between zones, no cloud load balancer: the flip is a Service selector change
seen by ingress-nginx. All five cases passed live on both engines on 2026-11-11
(`README.md` Results). Copy instrumentation on the `promoted` event in `events.jsonl`, checked by the
`db_copy_matches_source` gate rule: Postgres `replay_lsn` / `caught_up` (replica vs the copy LSN, just before the
promote), Oracle `src_rows` / `copy_rows` (users + sessions, source AS OF the copy SCN vs the copy). Report tabs built from generated data are marked SYNTHETIC.

## Reading a mode

Every mode is reported per case as **count**, **attempts** (the denominator), **rate** = count / attempts, the split
**pre / cutover / post**, **first / last** occurrence relative to the switch, the **expected** bound for the case's
mechanism, **unexpected** = occurrences outside that bound, which gate rule **enforces** it, and a verdict:

| verdict | meaning |
|---|---|
| OK | count 0 |
| expected | count > 0, all inside the mechanism's bound (e.g. lossy sessions born in the window) |
| over bound | a gate rule the mode names FAILed on items of this mode's class (the gate failed too) |
| over bound (not gated) | unexpected > 0 among occurrences no gate rule judges (report-only part of the mode) |
| not measured (no data) | no source lines, or 0 attempts. Never shown as 0 |

**Report and gate cannot disagree.** `scripts/report.sh` runs the gate's own jq (`scripts/gate/prelude.jq`,
`scripts/gate/apps.jq`) in front of `report/report.jq`: for every gate-enforced mode the report recomputes the gate
rules it names ("enforced by") with the same definitions and excuses (`lossok`, flips, grace, the apps.jsonl range),
and the gated part of "unexpected" is the number of those rules' offending items of this mode's class. A rule that
FAILs with nothing to judge (no data) puts its primary mode over bound. `scripts/test-report.sh` checks on fixtures
that every rule a mode names has the same state as the gate.txt row, and that over bound <=> a named rule FAILed.
"Report only" means no gate rule judges those occurrences; its bound is stated in "expected" and computed as stated.

## The modes

### `http_5xx`
- **Definition**: any response >= 500 (Keycloak, legacy IdP, ingress, apps) seen by k6.
- **Experienced as**: an error page in the middle of a login, a failed token call, an app error.
- **Detected**: k6 lines with `status >= 500`. Attempts = all judged k6 lines.
- **Causes**: a pod killed or drained with requests in flight (graceful shutdown not covering them), the ingress
  routing to a not-ready endpoint after the flip, overload of the remaining pods, a bug on the new version. Seen
  live: a 502 from a Ready pod caused by a `ConcurrentModificationException` in the legacy IdP's in-memory
  authorization store (fixed, worklog slice5-6).
- **Expected**: 0 in every case (the freeze's 503 on `/admin` + account is not on k6's paths).
- **Enforced**: gate `no_5xx`.
- **Blind spots**: only k6's paths; admin/account 503 during the freeze is not exercised; an abrupt node loss
  (`ZONE_LOSS`) is not part of the cases.

### `net_error`
- **Definition**: status 0 (connection refused/reset, timeout) not caused by the k6 stop.
- **Experienced as**: a hung or failed request with no response at all.
- **Detected**: k6 lines with `status == 0`, minus those still in flight at `load_stop` (ending at/after it).
- **Causes**: connections cut when a pod dies or the selector flips, ingress upstream gone, TLS problems (a stale
  demo CA once produced 353/353 status 0).
- **Expected**: 0. **Enforced**: gate `no_5xx` (it counts status 0 too).
- **Blind spots**: k6's 60 s request timeout means a slow-but-alive answer is not a net error; a status-0 line that
  failed and ended just before `load_stop` is counted (the exclusion starts at the event).

### `login_failed`
- **Definition**: a login (direct or via the app) that does not end with tokens / an app session.
- **Experienced as**: an error page or a login loop; the user has to start again.
- **Detected**: direct logins: k6 login hops grouped by `login_id`, success iff it has a `login_token` with 200;
  failed = a hop >= 400 / status 0, or no token and the last hop more than 30 s before the end; time = end of the last
  hop. App logins: exactly the gate's `app_login_ok` (success iff its `/me` got 200; a Spring callback that redirects
  to `/login?error` is a 302, so hop statuses alone would miss it); time = the `/me`. Attempts = both.
- **Causes**: shared DB: any server error during the flip. Lossy: the auth session of a login that started on blue
  after `copy_point` is not in green's DB, so its broker callback on green fails (in-window code exchange
  `invalid_grant` too). Rollback (lossy): the same for logins started on green before the flip back.
- **Expected**: shared 0; lossy only logins across a flip (a hop before the flip window's end, one at/after its start;
  flip window = [`switch`, `flipped` + 1 s], plus the rollback's for `minor-rollback`).
- **Enforced**: app logins: gate `app_login_ok` (same excuse). Direct logins: report only (the gate checks the
  straddling ones on the shared path, `inflight_login`, and the re-login after a lost session, `relogin_ok`); their
  unexpected failures are listed under the mode (end of last hop, s relative to t = 0).
- **Build #14 (minor)**: 54 failed of 3811, 20 unexpected against "straddling the switch", gate PASS. Not a gate/report
  disagreement: `app_login_ok` passed with the same excuse, so the 20 were direct logins, which no lossy gate rule
  judges [deduced from the code, not the data]. Cause [assumed]: the `switch` event is written BEFORE `set_active`
  (3 kubectl reads + the Service patch, then ingress-nginx), so logins starting in the first seconds "after the
  switch" still began on blue and failed on green, counted outside "straddling the switch event". Verify on the next
  run: the listed unexpected times cluster in [0, `flipped` + 1 s] and disappear from "unexpected" with `flipped`.
- **Blind spots**: a login abandoned at a form k6 does not recognise counts as failed; logins cut off by the k6 stop
  are excluded.

### `inflight_login_broken`
- **Definition**: a login whose hops straddle a flip (a hop before `switch`/`rollback`, the next after) and that fails.
- **Experienced as**: the user typed their password on the legacy IdP, came back to Keycloak and got an error.
- **Detected**: the gate's `inflight` sets: direct logins (app logins are `app_login_ok`'s) with a hop before the
  `switch`/`rollback` event and the next at/after it; failed = a hop >= 400 / status 0 or no `login_token` 200.
  Attempts = straddling logins.
- **Causes**: auth sessions not shared between colors (shared DB without `stateless`: the planned negative control),
  or not in the new color's DB (lossy). This is the mode the shared-DB mechanism exists to remove.
- **Expected**: shared 0; lossy only logins started after `copy_point` (or straddling the rollback).
- **Enforced**: gate `inflight_login` (+ `inflight_login_rollback`) on the shared path; report only on lossy.
- **Blind spots**: ~20 straddling logins per flip at 2 logins/s; a rare race needs more. Report and gate count the
  same set (since 2026-11-03; before, the report left out logins cut off by the k6 stop: 53 vs 54 in build #6).

### `refresh_lost_session`
- **Definition**: a refresh gets `invalid_grant` (direct, or via the app's OAuth2 client manager): the session is gone.
- **Experienced as**: the RP silently re-authenticates through the legacy IdP's SSO (k6 `relogin`), or, for an app
  without automatic re-auth (the test client), a failed `/call/*` until the user logs in again.
- **Detected**: k6 `refresh` lines with `error == "invalid_grant"` plus testclient `refresh` events with that error.
  Session birth = `t_end` of its `login_token` (k6) or the testclient `login` event (apps). Attempts = all refreshes.
- **Causes**: lossy: sessions created on blue after `copy_point` are not in green's DB (by design). Rollback (lossy):
  sessions created on green are not in blue's old DB. Shared: none expected; a loss means the sessions are not
  shared (cache/DB problem).
- **Expected**: shared 0. lossy: only sessions born in [`copy_point`, `switch`]. lossy-rollback: born in
  [`copy_point`, `switch`] and lost before `rollback` + 1 s, or born in (`switch`, `rollback`) and lost after it.
- **Enforced**: gate `no_invalid_grant` (shared), `invalid_grant_in_window` / `invalid_grant_phases` + `relogin_ok`
  (lossy), the `invalid_grant` part of the `refresh_*` session rules and of `app_refresh_ok`. The lossy numbers
  `sessions_lost` (every session born in the window), `sessions_lost_observed`, `relogins` are reported.
- **Blind spots**: k6 comes back to ~10 sessions only (refresh VUs; the `login` scenario never refreshes), so this
  mode's count and "users impacted" are a sample: the loss itself is every session born in the window
  (`sessions_lost`, about a third of the users of a run). k6 drops a lost token after the first `invalid_grant`, so each lost session counts once; offline
  tokens are not exercised; `window_sessions_back` (window sessions refreshing after a rollback) is structurally ~0.

### `refresh_other_error`
- **Definition**: a refresh fails for any reason other than `invalid_grant` (4xx/5xx, other OAuth error).
- **Experienced as**: as a lost session, but not expected by any mechanism.
- **Detected**: refresh lines/events not 200, not `invalid_grant`, not status 0 (that is `net_error`).
- **Causes**: token endpoint errors during the flip, a client/realm config difference between colors.
- **Expected**: 0. **Enforced**: partly: the `refresh_*` session rules (`refresh_across_switch` shared,
  `refresh_pre_copy` lossy, + the rollback ones) require every refresh of sessions born before the switch / copy point
  to be 200 (a rule with no such refresh at all FAILs and puts this mode over bound); `app_refresh_ok` gates the app's
  refreshes. k6 refreshes of later sessions are report only ("over bound (not gated)").
- **Blind spots**: as `refresh_lost_session`.

### `introspection_error`
- **Definition**: the resource server's introspection call to Keycloak failed (5xx, timeout, connect error).
- **Experienced as**: an API answering 503 although the token is fine.
- **Detected**: the gate's `introspection_ok` errors: testresource `introspection` events with `error != null` or
  `http_status != 200`, and k6 `app_call_introspect` lines with upstream 5xx / 0. Attempts = introspection events + k6
  introspect calls. No app lines -> not measured.
- **Causes**: the introspection endpoint hit during the flip/kill, connection pool to the old color.
- **Expected**: 0. **Enforced**: gate `introspection_ok`.
- **Blind spots**: one resource server replica, no cache (deliberately: it measures Keycloak), so real APIs with an
  introspection cache would see less.

### `introspection_false_inactive`
- **Definition**: introspection says `active: false` for a token whose session is alive (not logged out).
- **Experienced as**: an API rejecting (401) a logged-in user's valid token.
- **Detected**: k6 `app_call_introspect` lines with upstream 401 (k6 never calls after its own logout, so the
  session is alive); excused under `lossok` (born per the app callback). Attempts = k6 introspect calls with upstream
  200/401. Same set as the gate's `introspection_ok`.
- **Causes**: session not on the color that answers (lossy window sessions, as `refresh_lost_session`).
- **Expected**: shared 0; lossy only sessions born in [`copy_point`, `switch`] (lossy-rollback: the lossy rules).
- **Enforced**: gate `introspection_ok`.
- **Blind spots**: a 401 caused by an expired access token would count too (the app refreshes 30 s before expiry).

### `jwt_rejected`
- **Definition**: the resource server rejects a JWT from a live session (signature or issuer).
- **Experienced as**: 401 from an API with a fresh, valid token.
- **Detected**: k6 `app_call_jwt` lines that reached the resource server (upstream status set) with upstream != 200.
  Attempts = those calls. Same set as the gate's `jwt_ok`.
- **Causes**: signing keys differing between colors (they live in the realm, in the DB, and the lossy copy carries
  them), an issuer change, a JWKS cache that does not know a new key.
- **Expected**: 0 in every case. **Enforced**: gate `jwt_ok`.
- **Blind spots**: no key rotation happens during the cases.

### `issuer_mismatch`
- **Definition**: a token's `iss` is not the one of the network it was requested on.
- **Experienced as**: every RP of that network rejects the token (issuer validation), i.e. a full outage for it.
- **Detected**: k6 lines with `iss` (token lines, discovery) where `iss != https://kc-<net>.localtest.me/keycloak/realms/demo`.
- **Causes**: hostname configuration differing between colors, a forwarded-host header passed through.
- **Expected**: 0. **Enforced**: gate `issuer_stable`.
- **Blind spots**: only the two hosts k6 uses.

### `sub_changed`
- **Definition**: the same user gets a different `sub` over the run.
- **Experienced as**: the RP sees a new person: lost data, duplicate accounts.
- **Detected**: k6 lines grouped by `user`; a user with more than one `sub`. Attempts = users with a `sub`. Time =
  first line with the new `sub`.
- **Causes**: lossy: a first-broker-login user creation on blue in the window not replayed onto green (the next
  login creates a new user id). Rollback: a creation on green not reverse-replayed onto blue.
- **Expected**: 0. **Enforced**: gate `sub_stable` (+ `green_users_sub_kept` for lossy-rollback).
- **Blind spots**: only users k6 logs in again after the change.

### `logout_not_effective`
- **Definition**: refresh (or the app session) still works after the logout completed.
- **Experienced as**: a security issue: a logged-out session is resurrected.
- **Detected**: k6 `logout_probe` lines with status 200, plus `app_me_after_logout` not 401. Attempts = both.
- **Causes**: shared: logout not propagated (seen live: k6 stopped at the first redirect of a brokered logout, so
  1366/1368 sessions stayed alive; fixed in k6). Lossy: a logout on blue after `copy_point` is not in green's DB
  until the replay; between `switch` and `replay_done` it is alive on green (the "resurrection window",
  `resurrection_seconds`). Rollback: the same in reverse until `rollback_replay_done`. App: a Keycloak-initiated
  logout of a session Keycloak no longer knows (lossy window) reaches no app: the app session survives.
- **Expected**: shared 0; lossy probes only in [`switch`, `replay_done` + 1 s) (and [`rollback`,
  `rollback_replay_done` + 1 s)), app `/me` only for Keycloak-initiated logouts excused by `logout_effective`.
- **Enforced**: gate `logout_probe_never_ok` (shared), `logout_after_replay` (+ `logout_after_rollback_replay`) for
  probes after the replay, `logout_effective` for the app (`/me` 401, no successful call after the logout). Lossy
  probes with 200 before the switch are judged by no rule (report only).
- **Blind spots**: 1 s grace for a stale cache. The replay reads the old color's DB (`replay.sh`, since 2026-11-11;
  before, pod stdout); k6 gives it only 3-4 copied sessions to end per lossy window and none on a rollback, so the
  logout rules pass mostly on sessions the new color never had (`docs/production-readiness.md` 2.3 has the planted
  check that covers the rest).

### `backchannel_missing`
- **Definition**: a logout of a `bc` session without a matching ok back-channel logout at the app within 10 s, or
  (initiator `kc`) delivered but the app session not ended.
- **Experienced as**: the app keeps its local session after the user logged out at Keycloak.
- **Detected**: the gate's `bc_judged`: completed k6 logouts of `bc-*` sessions (start = `app_logout_start`), matched
  by sid to a `backchannel_logout` with `ok: true` within 10 s; for initiator `kc` also `/me` 401 after it. Spring
  answers 200 for a sid it holds no session for, so `ok: true` alone is delivery; with initiator `app` the app had
  already ended the session itself, so only `kc` logouts measure the effect. Logouts outside the apps.jsonl time range
  (or in its last 10 s) are not judged.
- **Causes**: the color handling the logout cannot reach the app (NetworkPolicy, DNS), the session not known to
  that color (lossy window), a logout replayed through the admin API without back-channel delivery; without effect:
  the app's sid registry (Spring's OIDC session registry) not finding the session.
- **Expected**: 0; lossy: undelivered only for sessions lost in the window (`lossok`). Delivered without effect is
  never expected. **Enforced**: gate `backchannel_delivered`.
- **Blind spots**: one app replica; the delay is measured from the app's own log line, not from Keycloak.

### `backchannel_late`
- **Definition**: delivered, but more than 2 s after the logout.
- **Detected**: as above, delay in (2 s, 10 s]. Attempts = judged logouts delivered within 10 s.
- **Expected**: 0. **Enforced**: report only (gate `backchannel_late` is INFO).

### `frontchannel_failed`
- **Definition**: an `fc` logout whose front-channel URL was missing from Keycloak's logout page or did not end the
  app session.
- **Experienced as**: the app stays logged in after a browser logout.
- **Detected**: the gate's `fc_judged`: completed k6 logouts of `fc-*` sessions; failed = no iframe on the logout
  page, an iframe fetch not 200, no `frontchannel_logout` at the app for the sid (inside the apps.jsonl range), `/me`
  not 401 after; initiator `kc` also `found_session` never true. For initiator `app`, `found_session: false` is no
  failure: the app's POST /logout ended the session before Keycloak's call (build #14: 25/25; the report used to count
  those as failed, the gate did not).
- **Expected**: 0; lossy: undelivered only for sessions lost in the window (`lossok`). **Enforced**: gate `frontchannel_ok`.
- **Blind spots**: k6 fetches the iframes like a browser would, but no real browser (third-party cookie rules) is involved.

### `latency_regression`
- **Definition**: the p95 latency of a step class in the cutover window is more than 2x its pre-switch p95.
- **Experienced as**: slow logins/APIs during the cutover, timeouts in impatient clients.
- **Detected**: request duration (`t_end - t_start`) per step class: login hops, token (code exchange), refresh,
  logout + probes, reads, app calls, introspection (testresource `latency_ms`). Needs >= 20 pre and >= 10 cutover
  samples. Count = classes over 2x; attempts = classes with enough samples. The ratios are listed in the table.
- **Causes**: cold caches on the new color, the killed pod's share moving to two pods, DB load (`stateless` roughly
  doubles it), schema migration on the copy (lossy), CPU contention on the one test machine.
- **Expected**: 0 classes. **Enforced**: report only. The gate prints the same list as an INFO row (one definition,
  `regress` in `scripts/gate/apps.jq`; `test-report.sh` checks the counts agree).
- **Blind spots**: one machine, so contention from the second color's startup shows up as regression; the cutover
  window is short (tens of seconds), so p95 rests on few samples for low-rate classes. Read it with the per-class
  CDF and the percentile table.

## The report (`out/report.html`)

`scripts/report.sh [out-dir]` (default `out`) reads every `<out-dir>/<case>/` it finds, in `cases.env` order, and
writes `<out-dir>/report.html`: one self-contained page (~250-310 KB), an Overview tab and one tab per case.
Chart.js 4.6.1 is inlined from `report/vendor/` (checksum in `chart.umd.min.js.sha256`, verified on every run; the
MIT header stays in the file, the full license is `chart.js.LICENSE.md`); the data is one embedded JSON blob. No
fetches at view time. Needs bash, jq 1.7+ and coreutils (launcher and Jenkins images).
Aggregation: `report/report.jq` (run behind the gate's `scripts/gate/prelude.jq` + `apps.jq`, one program), one jq run per case (2 s rate buckets, 10 s latency buckets with p50/p95/p99,
per-window CDF bins, the failure-mode table); drawing: `report/template.html`.
Test: `bash scripts/test-report.sh` (input built from `load/fixtures`) or `bash scripts/test-report.sh out/samples`.

| file in `<case>/` | written by | needed |
|---|---|---|
| `k6.jsonl` | `demo.sh` cool-down | yes, else the case is skipped |
| `events.jsonl` | switch / rollback scripts | windows, markers, lossy numbers |
| `gate.txt` | `demo.sh` gate phase | gate verdict and rules |
| `apps.jsonl` | test apps, once collected per case | app modes, else "not measured" |
| `meta.json` | Jenkins post step: `{build, commit, url}` | optional |
| `SYNTHETIC` | `report/synth-lossy.sh` | marks generated data; its text is shown on the tab |

**In Jenkins** the `kc-bluegreen` job builds the report in `post { always }`, so it is also made when a stage or the
gate failed, and archives it with `out/**`. It first writes `meta.json` (build number, `GIT_COMMIT`, build URL) into
each case dir whose `k6.jsonl` is newer than the build's start; older dirs keep theirs. A report failure marks the
build UNSTABLE.

**The report accumulates.** The job workspace keeps `out/` between builds, so `out/<case>/` of every case run so far
stays, and each build's report shows all of them, each tab with the build that produced it. Running a case again
replaces its dir. A case whose run failed before the cool-down keeps the PREVIOUS run's dir and `meta.json`: check
the build number in the tab header.
**Reset**: delete `out/` in the workspace ("Wipe Out Current Workspace" on the job page, or
`docker compose exec jenkins rm -rf /var/jenkins_home/workspace/kc-bluegreen/out`); one case: remove its `out/<case>/`.

**`CASE=all` needs a pipeline change.** `all` is in the `CASE` choices, but every stage calls
`scripts/demo.sh "$CASE" <phase>`, and `demo.sh all <phase>` ignores the phase and runs every case end to end, so the
Reset stage alone would run the whole suite, Install again, and so on (~6x), and `Soak + rollback` is skipped.
Passing the phase through in `demo.sh` does not fix it: the cases share one cluster and must each run reset -> gate
in turn. Needed in the Jenkinsfile: when `CASE == 'all'`, loop cases x phases in one `script` stage, e.g.
`for (c in cases) for (p in phases) stage("${c}: ${p}") { withEnv(["CASE=${c}"]) { phase(p) } }` (cases from
`cases.env`; demo.sh's `rollback` phase is a no-op for non-rollback cases), `when { expression { env.CASE != 'all' } }`
on the existing stages, a `catchError` per case if one failed case should not stop the others, and `timeout` raised
from 60 to ~150 minutes. Recommended `demo.sh` guard in the `all` branch:
`[[ $phase == all ]] || die "all runs every case end to end; run phases per case"`.

**Synthetic samples.** `report/synth-lossy.sh <src-case-dir> <dst-case-dir> <lossy|lossy-rollback> <from> <to>
<shift-days> [apps]` makes report input for the lossy cases from a real shared run until they have run for real:
time-shifted, the lossy events in the real scripts' format, and the mechanism's losses applied (window sessions ->
`invalid_grant` + silent re-login, straddling logins started after `copy_point` -> 400 on green, logged-out sessions
resurrected until `replay_done`), optionally test-app lines; it runs the gate on the result and writes `SYNTHETIC`.

## Optional live view (Grafana), not built

The deliverable is the static page: it works offline, is archived with the build, and needs no backend. A live view
would add watching a cutover as it happens (and long-run trends across builds), at the cost of running a stack:

- **Metrics**: k6's Prometheus remote-write output (`K6_PROMETHEUS_RW_SERVER_URL`, `-o experimental-prometheus-rw`)
  into an in-cluster Prometheus (kube-prometheus-stack), Grafana on top. Tags per request (`scenario`, step `name`)
  give rates and latency histograms per step; the switch events would become Grafana annotations (a small
  `curl` to the annotations API in `event()`).
- **Logs**: alternatively Loki (+ Promtail/Alloy) on the k6 pod and the apps, with LogQL over the same JSON lines the
  report reads (`| json | status >= 500`), which keeps one source of truth with the gate.
- Either way it adds ~1-2 GiB of memory to a box already at ~11.7 GiB peak, and the failure-mode bounds (birth
  windows, replay windows) would have to be rewritten as queries. Worth it only for long or repeated runs.
