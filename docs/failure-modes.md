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
| `login` | 5 logins/s (constant arrival) | full brokered auth-code flow, every hop logged: KC `/auth` -> legacy IdP authorize -> legacy login form (think time 0-20 s) -> POST -> KC broker endpoint -> (first-broker-login form) -> code -> `/token`. 80 % users 1-4000 (pre-linked), 20 % 4001-5000 (created on first login). Each session sticks to net1 or net2. |
| `refresh` | 10 VUs, one refresh every 5 s | holds a session and refreshes it; on `invalid_grant` a silent re-login (`relogin`) through the legacy IdP's SSO. Half the VUs start a new session every 60 s, so sessions are born on every color. |
| `logout` | 4 VUs, one logout per VU every ~45 s | login, RP-initiated logout (`id_token_hint`, following the brokered round trip), then probes the logged-out refresh token every 5 s until the end (`logout_probe`, must get `invalid_grant`). |
| `reads` | 1/s per network | discovery + JWKS. |
| `app` (contract, not built yet) | per contract | browser login through the test client app, `/call/jwt` and `/call/introspect` every 5 s, RP logout with back- or front-channel delivery. |

Roughly 60-70 k6 requests/s, ~30 000 lines per case. Every request is one JSON line (schema at the top of
`flows.js`); the switch scripts write one JSON line per step to `events.jsonl` (`event` in `scripts/lib/kc.sh`). The
test apps (once built) log one JSON line per login/call/refresh/logout/introspection to `apps.jsonl`
(`docs/test-apps-contract.md`). Nothing else is measured: no server-side metrics, no edge logs.

**Time.** All times are seconds relative to the first `switch` event (t = 0). k6 and the scripts share the host
clock (KinD containers on one machine). A request belongs to the moment it started (`t_start`).

**Windows** (report and `latency_regression`; the shaded band in every time chart):

| window | definition |
|---|---|
| pre-switch | before the first cutover window starts |
| cutover | forward: [`copy_point` (lossy) or `switch` (shared), `window_end` (lossy) or `recovered` (shared, the killed pod is back) or `drained`, else +60 s]; rollback cases add [`rollback_start`, `rollback_window_end` or `drained`, else +60 s] |
| post-switch | everything else after the first window start (for rollback cases this includes the soak on the new color) |

The gate's own windows are event boundaries, used per rule: before/after `switch`; the lossy window
[`copy_point`, `switch`]; the resurrection window [`switch`, `replay_done` + 1 s]; for rollbacks [`switch`,
`rollback`) and [`rollback`, `rollback_replay_done` + 1 s]. The report uses exactly those for "expected".

**Exclusions** (same as the gate): requests with status 0 that start at/after `load_stop` are k6 aborting itself on
SIGINT, not server behaviour; they are counted ("aborted") and judged by no rule. Logins still in their think time at
the end of the data (no failed hop, no token, last hop < 30 s before the end) are not judged.

**Limits.** One machine (KinD, 3 worker nodes in Docker, 3 Keycloak pods per color, CNPG Postgres in-cluster;
`PROFILE=laptop`: 2 workers, 2 pods per color, 2 Postgres instances, ~2 logins/s): k6, both
colors, Postgres and the legacy IdP compete for the same CPUs, so latency numbers are relative (pre vs cutover), never
absolute capacity numbers. Synthetic load at a fixed, modest rate (~5 logins/s): rare races need far more traffic to
show up. One run per case: a count of 0 is "not seen in this run", not a probability; compare rates across runs before
calling something fixed. No real network between zones, no cloud load balancer: the flip is a Service selector change
seen by ingress-nginx. Lossy cases have not passed live yet (`docs/production-readiness.md`); report tabs built from
generated data are marked SYNTHETIC.

## Reading a mode

Every mode is reported per case as **count**, **attempts** (the denominator), **rate** = count / attempts, the split
**pre / cutover / post**, **first / last** occurrence relative to the switch, the **expected** bound for the case's
mechanism, **unexpected** = occurrences outside that bound, which gate rule **enforces** it, and a verdict:

| verdict | meaning |
|---|---|
| OK | count 0 |
| expected | count > 0, all inside the mechanism's bound (e.g. lossy sessions born in the window) |
| over bound | unexpected > 0 and a gate rule enforces the mode (the gate should have failed) |
| over bound (not gated) | unexpected > 0, the mode is report-only |
| not measured (no data) | no source lines, or 0 attempts. Never shown as 0 |

"Report only" means only the report judges it as of this commit; the k6/gate work for the apps may add gate rules.

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
- **Detected**: k6 lines with `status == 0`, minus those starting at/after `load_stop`.
- **Causes**: connections cut when a pod dies or the selector flips, ingress upstream gone, TLS problems (a stale
  demo CA once produced 353/353 status 0).
- **Expected**: 0. **Enforced**: gate `no_5xx` (it counts status 0 too).
- **Blind spots**: k6's 60 s request timeout means a slow-but-alive answer is not a net error; a status-0 line right
  before `load_stop` that k6 aborted is counted (the exclusion starts at the event).

### `login_failed`
- **Definition**: a login (direct or via the app) that does not end with tokens / an app session.
- **Experienced as**: an error page or a login loop; the user has to start again.
- **Detected**: k6 login hops grouped by `login_id`. Direct login = success iff it has a `login_token` with 200.
  App login (steps `app_login_*`) = success iff no hop is status 0 or >= 400 [assumed until the app scenario exists].
  Failed = a hop >= 400 / status 0, or no token and the last hop more than 30 s before the end. Attempts = judged
  logins. Time = end of the last hop.
- **Causes**: shared DB: any server error during the flip. Lossy: the auth session of a login that started on blue
  after `copy_point` is not in green's DB, so its broker callback on green fails (in-window code exchange
  `invalid_grant` too). Rollback (lossy): the same for logins started on green before the flip back.
- **Expected**: shared 0; lossy only logins straddling the switch (and the rollback for `minor-rollback`).
- **Enforced**: report only. The gate checks the straddling logins on the shared path (`inflight_login`) and the
  re-login after a lost session (`relogin_ok`), not logins in general.
- **Blind spots**: a login abandoned at a form k6 does not recognise counts as failed; logins cut off by the k6 stop
  are excluded.

### `inflight_login_broken`
- **Definition**: a login whose hops straddle a flip (a hop before `switch`/`rollback`, the next after) and that fails.
- **Experienced as**: the user typed their password on the legacy IdP, came back to Keycloak and got an error.
- **Detected**: as `login_failed`, restricted to logins with first hop < flip <= last hop. Attempts = straddling logins.
- **Causes**: auth sessions not shared between colors (shared DB without `stateless`: the planned negative control),
  or not in the new color's DB (lossy). This is the mode the shared-DB mechanism exists to remove.
- **Expected**: shared 0; lossy only logins started after `copy_point` (or straddling the rollback).
- **Enforced**: gate `inflight_login` (+ `inflight_login_rollback`) on the shared path; report only on lossy.
- **Blind spots**: ~50 straddling logins per flip at 5 logins/s; a rare race needs more. The gate counts every
  straddling login, the report leaves out those cut off by the k6 stop (one fewer in build #6: 53 vs 54).

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
  (lossy). The lossy numbers `sessions_lost`, `relogins` are reported.
- **Blind spots**: k6 drops a lost token after the first `invalid_grant`, so each lost session counts once; offline
  tokens are not exercised; `window_sessions_back` (window sessions refreshing after a rollback) is structurally ~0.

### `refresh_other_error`
- **Definition**: a refresh fails for any reason other than `invalid_grant` (4xx/5xx, other OAuth error).
- **Experienced as**: as a lost session, but not expected by any mechanism.
- **Detected**: refresh lines/events not 200, not `invalid_grant`, not status 0 (that is `net_error`).
- **Causes**: token endpoint errors during the flip, a client/realm config difference between colors.
- **Expected**: 0. **Enforced**: partly: `refresh_across_switch` (shared) / `refresh_pre_copy` (lossy) require every
  refresh of sessions born before the switch / copy point to be 200; later sessions are report only.
- **Blind spots**: as `refresh_lost_session`.

### `introspection_error`
- **Definition**: the resource server's introspection call to Keycloak failed (5xx, timeout, connect error).
- **Experienced as**: an API answering 503 although the token is fine.
- **Detected**: testresource `introspection` events with `error != null` or `http_status != 200`.
  Attempts = introspection events. No apps lines -> not measured.
- **Causes**: the introspection endpoint hit during the flip/kill, connection pool to the old color.
- **Expected**: 0. **Enforced**: report only.
- **Blind spots**: one resource server replica, no cache (deliberately: it measures Keycloak), so real APIs with an
  introspection cache would see less.

### `introspection_false_inactive`
- **Definition**: introspection says `active: false` for a token whose session is alive (not logged out).
- **Experienced as**: an API rejecting (401) a logged-in user's valid token.
- **Detected**: testclient `call` events to `introspect` with `upstream_status == 401` and no client error, for a sid
  with no logout (`logout_initiated` / `backchannel_logout` / `frontchannel_logout`) before the call. Attempts =
  such calls with upstream 200/401 on live sids.
- **Causes**: session not on the color that answers (lossy window sessions, as `refresh_lost_session`).
- **Expected**: shared 0; lossy only sessions born in [`copy_point`, `switch`] (lossy-rollback: the lossy rules).
- **Enforced**: report only.
- **Blind spots**: depends on the testclient logging the sid on every call; the join is by sid only.

### `jwt_rejected`
- **Definition**: the resource server rejects a JWT from a live session (signature or issuer).
- **Experienced as**: 401 from an API with a fresh, valid token.
- **Detected**: testclient `call` events to `jwt` with `upstream_status == 401` and no client error, on a live sid.
- **Causes**: signing keys differing between colors (they live in the realm, in the DB, and the lossy copy carries
  them), an issuer change, a JWKS cache that does not know a new key.
- **Expected**: 0 in every case. **Enforced**: report only.
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
- **Detected**: k6 `logout_probe` lines with status 200, plus `app_me_after_logout` with 200. Attempts = probes.
- **Causes**: shared: logout not propagated (seen live: k6 stopped at the first redirect of a brokered logout, so
  1366/1368 sessions stayed alive; fixed in k6). Lossy: a logout on blue after `copy_point` is not in green's DB
  until the replay; between `switch` and `replay_done` it is alive on green (the "resurrection window",
  `resurrection_seconds`). Rollback: the same in reverse until `rollback_replay_done`.
- **Expected**: shared 0; lossy only in [`switch`, `replay_done` + 1 s) (and [`rollback`, `rollback_replay_done` + 1 s)).
- **Enforced**: gate `logout_probe_never_ok` (shared), `logout_after_replay` (+ `logout_after_rollback_replay`) for
  probes after the replay only.
- **Blind spots**: replay reads Keycloak's stdout (`replay.sh`): a log line lost to rotation or a recreated pod is a
  silently lost logout (`docs/production-readiness.md` recommends an outbox table). 1 s grace for a stale cache.
  Only ~4 logouts per lossy window at the current rate.

### `backchannel_missing`
- **Definition**: an RP-initiated logout of a `bc` session without a matching back-channel logout at the app within 10 s.
- **Experienced as**: the app keeps its local session after the user logged out at Keycloak.
- **Detected**: testclient `logout_initiated` with a `bc-*` registration, matched by sid to `backchannel_logout`
  with `ok: true` within 10 s. Logouts in the last 10 s of the data are not judged.
- **Causes**: the color handling the logout cannot reach the app (NetworkPolicy, DNS), the session not known to
  that color (lossy window), a logout replayed through the admin API without back-channel delivery.
- **Expected**: 0. **Enforced**: report only.
- **Blind spots**: one app replica; the delay is measured from the app's own log line, not from Keycloak.

### `backchannel_late`
- **Definition**: delivered, but more than 2 s after the logout.
- **Detected**: as above, delay > 2 s. Attempts = delivered back-channel logouts.
- **Expected**: 0. **Enforced**: report only.

### `frontchannel_failed`
- **Definition**: an `fc` logout whose front-channel URL was missing from Keycloak's logout page or did not end the
  app session.
- **Experienced as**: the app stays logged in after a browser logout.
- **Detected**: testclient `logout_initiated` with an `fc-*` registration without a `frontchannel_logout` with
  `found_session: true` for that sid within 10 s.
- **Expected**: 0. **Enforced**: report only.
- **Blind spots**: k6 fetches the iframes like a browser would, but no real browser (third-party cookie rules) is involved.

### `latency_regression`
- **Definition**: the p95 latency of a step class in the cutover window is more than 2x its pre-switch p95.
- **Experienced as**: slow logins/APIs during the cutover, timeouts in impatient clients.
- **Detected**: request duration (`t_end - t_start`) per step class: login hops, token (code exchange), refresh,
  logout + probes, reads, app calls, introspection (testresource `latency_ms`). Needs >= 20 pre and >= 10 cutover
  samples. Count = classes over 2x; attempts = classes with enough samples. The ratios are listed in the table.
- **Causes**: cold caches on the new color, the killed pod's share moving to two pods, DB load (`stateless` roughly
  doubles it), schema migration on the copy (lossy), CPU contention on the one test machine.
- **Expected**: 0 classes. **Enforced**: report only (the gate has no latency rule).
- **Blind spots**: one machine, so contention from the second color's startup shows up as regression; the cutover
  window is short (tens of seconds), so p95 rests on few samples for low-rate classes. Read it with the per-class
  CDF and the percentile table.

## The report (`out/report.html`)

`scripts/report.sh [out-dir]` (default `out`) reads every `<out-dir>/<case>/` it finds, in `cases.env` order, and
writes `<out-dir>/report.html`: one self-contained page (~250-310 KB), an Overview tab and one tab per case.
Chart.js 4.6.1 is inlined from `report/vendor/` (checksum in `chart.umd.min.js.sha256`, verified on every run; the
MIT header stays in the file, the full license is `chart.js.LICENSE.md`); the data is one embedded JSON blob. No
fetches at view time. Needs bash, jq 1.7+ and coreutils (launcher and Jenkins images).
Aggregation: `report/report.jq`, one jq run per case (2 s rate buckets, 10 s latency buckets with p50/p95/p99,
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
