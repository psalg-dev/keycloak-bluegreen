# Keycloak blue/green under load

A self-contained demo of zero-downtime Keycloak upgrades on Kubernetes (KinD): three Keycloak pods per color behind
ingress-nginx, Oracle Database instead of Postgres, realm configuration through keycloak-config-cli, driven by Jenkins,
measured by k6 and two OIDC test apps while the cutover happens, and judged by a gate plus an HTML report.

> **Branch `oracle-19c`.** The engine is Oracle; the zero-downtime contract is unchanged. The runnable default is
> 23ai Free because 19c has no free XE image; the code path is 19.3-compatible and `ORACLE_IMAGE` switches to the
> 19.3 EE image. The route, tools and limits are in [docs/oracle.md](docs/oracle.md). The Results table is the
> **Oracle 23ai Free run of 2026-11-04**, all five cases gate-pass; 19.3 EE itself was not started because the Oracle
> container registry needs a login that was not available here.

Nothing is mocked on the path that matters: real brokered logins against a legacy Spring Authorization Server (users
live there; Keycloak holds no passwords), real token refreshes, logouts, back-/front-channel logout, introspection and
JWT validation at a resource server, with a custom provider JAR (mappers, authenticator, event listener) and theme.

## What it shows

| Case | From -> to | Mechanism | Downtime | What is lost |
|---|---|---|---|---|
| `patch` | 26.8.0 -> 26.8.1 | **shared DB**: green joins next to blue on the same Oracle schema, flip the `kc-active` Service | none | nothing |
| `minor` | 26.7.5 -> 26.8.1 | **lossy overlap**: green gets its own Oracle schema (Data Pump copy of blue's at an SCN) and migrates it; blue keeps serving logins/tokens; logouts + new users from the window are replayed onto green; flip | none for login/token; admin + account console answer 503 for the window | sessions created in the window (`[copy_point, switch]`): users re-login silently through the legacy IdP's SSO |
| `major` | 25.0.6 -> 26.8.1 | lossy overlap | same | same |
| `patch-rollback`, `minor-rollback` | as above | switch, soak 90 s on the new version, roll back to the old color (lossy: to the old DB, after reverse-replaying the new color's logouts and new users) | none | rollback (lossy): sessions created on the new version |

Why lossy for minor/major: two Keycloak versions cannot share one database (the newer one migrates the schema), so a
strictly lossless cutover would need a write freeze. Because users authenticate at the legacy IdP, a lost Keycloak
session costs a redirect, not a password prompt; the demo makes that trade explicit and measures it.

## Topology

```mermaid
flowchart LR
  U["browser + k6 (2 logins/s)"] --> E["ingress-nginx<br/>*.localtest.me"]
  E --> S["kc-active Service<br/>(the only thing the cutover patches)"]
  S --> B["Keycloak blue<br/>3 pods"]
  S --> G["Keycloak green<br/>3 pods"]
  B --> DB[("Oracle<br/>one instance, KC1/KC2 schemas")]
  G --> DB
  B --> L["legacy IdP<br/>Spring Authorization Server"]
  G --> L
  A["testclient / testresource"] --> E
```

One Service selector routes the edge to exactly one color; the flip is a `kubectl patch` of that selector, so neither
the clients, the ingress nor the realm configuration change. Blue and green share an Oracle schema in `patch` and have
one each in `minor`/`major` (green gets a Data Pump copy of blue's at an SCN).

## Run it

Requirements: Docker with about 16 GB for the containers (the Oracle instance is 4 GiB; measured Postgres peak was
14.8 GiB, see Results), git,
bash with `curl`, `jq` and `openssl` on the host (Git Bash works on Windows). Everything else (kind, kubectl, helm,
Maven, GraalVM, k6) runs in containers. Hostnames are `*.localtest.me`, which resolve to 127.0.0.1 publicly.
`bash scripts/preflight.sh` (the launcher runs it first) checks exactly that: Docker daemon, Docker VM memory for the
profile, ports 443 and 8081, the host tools and the DNS record, and stops with one sentence instead of failing halfway
through a cluster build.

```bash
bash scripts/jenkins-secret.sh
```

```bash
docker compose run --rm launcher
```

```bash
docker compose up -d jenkins
```

1. `jenkins-secret.sh` generates the Jenkins admin password into `out/jenkins-admin-password` (gitignored).
2. The launcher runs `scripts/up.sh`: KinD cluster (1 control plane + 3 workers labelled zones a/b/c), ingress-nginx,
   the Oracle instance (4 GiB), certificates (demo CA in `out/certs/ca.crt`), the legacy IdP, the two native test apps,
   and a first blue Keycloak on schema `kc1`. Idempotent; the first run builds images and creates the Oracle database
   (a few minutes; 19c EE takes longer).
3. Jenkins: <http://localhost:8081>, user `admin`, password from step 1. Job **kc-bluegreen**, parameter `CASE`.
   Reset and Install run first; then two parallel branches — **Load** (k6 start, warm-up, cool-down) and **Cutover**
   (Switch, Soak + rollback) — joined by **Gate**. The load branch owns k6 for the whole run, so no pipeline step ever
   waits on the load; the one ordering point is the warm-up (the switch starts once sessions exist). Each phase logs a
   header saying what it does and why, and a result line with exit code and duration. The HTML report is built in
   every build's post step and archived with `out/**`.

Without Jenkins: `docker compose run --rm launcher bash scripts/demo.sh minor` (or `all`, or one phase:
`demo.sh minor switch`). Results land in `out/<case>/`: `k6.jsonl`, `apps.jsonl`, `events.jsonl`, `gate.txt`, the
Keycloak logs of each color, and `bash scripts/report.sh` writes `out/report.html`.

### Live demo, for an audience

One case, in a browser tab: a page that runs a real user journey every 2.5 s - brokered login through the legacy IdP
(authorization code + PKCE), a JWT-validated API call, a server-side introspection at the resource server, a refresh,
and a logout that must end the session - and reports every step as it happens.

```bash
bash scripts/live-demo.sh        # -> http://127.0.0.1:8098/
```

Flip the active color in another terminal while it runs (`docker compose run --rm launcher bash scripts/demo.sh patch
switch`, or a Jenkins build) and the page keeps counting through it: login, refresh and logout stay green,
introspection keeps answering `active: true`, and the latency bars show the cutover. The header links to the
pre-generated report (`out/report.html`, all five cases) so the detailed numbers are one click away. Needs Node >= 18
on the host; the client secret, the legacy user password and the CA come from the running cluster.

Admin console: <https://kc-net1.localtest.me/keycloak/admin> (trust `out/certs/ca.crt`; user `temp-admin`, password:
`kubectl -n keycloak get secret kc-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d`).

Tear down: `bash scripts/down.sh`, then `docker compose down -v`.

### On a 16 GB laptop

```bash
PROFILE=laptop docker compose run --rm launcher
```

Then run cases with `PROFILE=laptop` (Jenkins build parameter, or
`PROFILE=laptop docker compose run --rm launcher bash scripts/demo.sh all`). The profile is recorded on the cluster;
a run with a different `PROFILE` stops before it changes anything.

Laptop = 2 KinD workers (zones a, b) instead of 3, 2 Keycloak pods per color instead of 3 (PDB 1 of 2, 1 GiB memory
limit), the same 4 GiB Oracle instance, the same load profile (2 logins/s, 3 app VUs), 2 ingress-nginx workers. Same
images, config stages, switch scripts and gate rules. Give Docker Desktop / WSL2 about 13 GB (`.wslconfig`:
`memory=13GB`); Oracle is the reason this is no longer a 10 GB profile.

Measured over all five Postgres cases (2.3 h of 15 s samples): **8.1 GiB** peak for the KinD nodes, **9.1 GiB** with
Jenkins (rollback phase of `minor-rollback`: both colors and both Postgres clusters up). No Oracle memory measurement
has been recorded yet. The default Postgres profile peaked at 13.8 GiB / 14.8 GiB (Results); Oracle replaces the CNPG
instances with one 4 GiB instance, so expect a similar or slightly higher peak. Not shown on the laptop profile: the
3-zone spread, a pod kill that leaves 2 serving pods per color (here 1), the production PDB of 2 out of 3. Latency
numbers are comparable within a run, not across profiles.

## How a run is judged

- **Gate** (`scripts/gate.sh`, rules explained in `scripts/gate/why.tsv`, printed under each row): no 5xx; issuer
  stable per network; same `sub` per user across versions; in-flight logins and refresh tokens survive (patch);
  pre-copy sessions survive and only window-born sessions are lost, each followed by a successful re-login (lossy);
  the Oracle copy's SCN is at least the declared copy point (`db_copy_caught_up`); logged-out sessions never come back
  after the replay; the app rules (introspection, JWT, refresh, back-/front-channel logout delivered, logout effective);
  and that load really ran through the cutover (`load_through_cutover`) and the lossy window really was exercised
  (`window_exercised`), so no rule can pass on silence.
- **Report** (`out/report.html`, one tab per case): the data baseline (requests, users), error rates over time with
  the switch events marked, latency distributions before/during/after the cutover, and the failure-mode table with
  counts, rates and expected bounds. Every failure mode carries a one-line explainer of what it means to a user
  (`report/modes.tsv`). Definitions: [docs/failure-modes.md](docs/failure-modes.md).

## Results

**Oracle run, 2026-11-04:** Jenkins builds **#2** (`patch`), **#4** (`minor`), **#6** (`major`), **#7**
(`patch-rollback`), **#9** (`minor-rollback`) on the `oracle-19c` branch, default profile, one KinD cluster, five cases
back to back. Every gate PASSes. The database is Oracle 23ai Free (`gvenzl/oracle-free:23.26.3-slim`), not 19.3:
the 19.3 EE image is behind an Oracle registry login that was not available here ([docs/oracle.md](docs/oracle.md)).
Fixes landed between cases; the last case ran at commit `65a6c80`. The full report is `out/oracle-run/report.html`
(gitignored; Jenkins archives the same file).

| | `patch` | `patch-rollback` | `minor` | `minor-rollback` | `major` |
|---|---|---|---|---|---|
| k6 requests | 16,112 | 16,494 | 17,525 | 24,391 | 15,354 |
| 5xx / network errors | 0 | 0 | 0 | 0 | 0 |
| error rate, whole run (cutover window) | 0 % (0 %) | 0 % (0 %) | 0.22 % (0.43 %) | 0.46 % (0.76 %) | 0.35 % (0.58 %) |
| users potentially impacted (of users seen) | 0 of 938 | 8 of 949 (0.8 %) | 27 of 1,015 (2.7 %) | 68 of 1,314 (5.2 %) | 25 of 904 (2.8 %) |
| lossy window (copy point -> switch) | - | - | 198.7 s | 168.5 s | 168.6 s |
| sessions lost = silent re-logins | 0 | 0 | 4 | 6 (+3 green-born, at the rollback) | 5 |
| logouts / new users replayed | - | - | 27 / 93 | 23 / 62 forward, 21 / 82 back | 21 / 70 |
| users repaired (post-flip race) | - | - | 0 | 1 | 0 |
| resurrection window (switch -> replay done) | - | - | 59.0 s | 60.8 s, rollback 49.3 s | 50.5 s |
| pod kill -> recovered (3 -> 2 -> 3 pods) | 43.1 s | 43.8 s | - | - | - |
| rollback (start -> traffic on the old color) | - | 0.02 s (Service flip) | - | 50.6 s (reverse replay + purge) | - |
| p95 network latency pre / cutover / post | 73 / 78 / 66 ms | 115 / 97 / 90 ms | 97 / 82 / 72 ms | 135 / 105 / 92 ms | 73 / 71 / 76 ms |
| step classes with cutover p95 > 2x | introspection 2.18x | none | none | none | none |
| schema changesets | - | - | 211 -> 238 | 211 -> 238 | 134 -> 238 |

Reading it:

- **Users first**: 27 of 1,015 people in `minor`, 68 of 1,314 in `minor-rollback` and 25 of 904 in `major` were
  potentially impacted - they hit at least one error line (a lost session's `invalid_grant`, a straddling login, a
  channel logout for a session Keycloak no longer had) or a request over 1 s. The shared cases: nobody in `patch`,
  eight in `patch-rollback` (slow only). The report counts each user once; the definition is in
  [docs/failure-modes.md](docs/failure-modes.md).
- The errors in the lossy cases are the trade the mechanism makes, all inside its bound: logins whose hops straddle
  the flip (started on blue, finished on green; the next attempt goes through legacy SSO), refreshes of sessions born
  in the lossy window (`invalid_grant`, then a silent re-login), and the apps' back-/front-channel logouts for those
  sessions (Keycloak on green never knew them). No session born before the copy point was lost, no logged-out session
  came back after the replay. In `minor-rollback` one person was created twice in the post-flip race; the replay
  repaired them (first `sub` restored) and the gate excuses exactly that user.
- The shared cases (same Oracle schema) lose nothing. `patch` has one class over 2x, introspection 2.18x, inside a
  cutover window that also holds a pod kill (3 -> 2 pods for ~43 s); `patch-rollback`, same mechanism, has none. One
  run per case on one machine: expect run-to-run spread of that size.
- Admin and account console answer 503 for the whole cutover window in the lossy cases (copy point -> window end,
  ~170-200 s). Login, token, refresh, logout, discovery and JWKS never stop.
- The Data Pump copy is visible in the report: `copy_point`/`promoted` carry the same SCN, and every green schema
  ends at the target Keycloak changeset count (238). The Oracle instance is one 4 GiB pod; no Oracle memory sample was
  taken in this five-case run. The earlier Postgres baseline peaked at 13.8/14.8 GiB.

The full numbers, per failure mode and per step class, are in the report (one tab per case).

## More

- [docs/oracle.md](docs/oracle.md): the Oracle route, Data Pump cutover, 19.3 vs 23ai Free, tools, limits.
- [PLAN.md](PLAN.md): design, decisions and the **known limits** (the Postgres sections are the historical design;
  docs/oracle.md is the Oracle delta).
- [docs/production-readiness.md](docs/production-readiness.md): what it would take to run this in an enterprise.
- [docs/test-apps.md](docs/test-apps.md): the OIDC test client and resource server (Spring Boot, GraalVM native).
- Security pipelines: Jenkins jobs **kc-kcwarden** (realm configuration audit) and **kc-security** (probes: TLS,
  tokens, redirect URIs, brute force, DCR, issuer, network policy, trivy, nuclei, ZAP, ...).
- Apache-2.0: [LICENSE](LICENSE). CI runs the offline checks (shellcheck, gate/report/lib tests) on every push
  (`.github/workflows/checks.yml`); the live cases need Docker and run through the local Jenkins.
