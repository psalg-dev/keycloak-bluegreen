# Keycloak blue/green under load

A self-contained demo of zero-downtime Keycloak upgrades on Kubernetes (KinD): three Keycloak pods per color behind
ingress-nginx, Postgres (CloudNativePG) or Oracle Database, realm configuration through keycloak-config-cli, driven by Jenkins,
measured by k6 and two OIDC test apps while the cutover happens, and judged by a gate plus an HTML report.

Two database engines, one tree, one cluster at a time: **Postgres** (default, CloudNativePG) and **Oracle**
(`DB_ENGINE=oracle`, everything Oracle-specific in [oracle/](oracle/README.md)). The cases, load, gate and report are
the same; only the way green gets its copy of the database differs.

Nothing is mocked on the path that matters: real brokered logins against a legacy Spring Authorization Server (users
live there; Keycloak holds no passwords), real token refreshes, logouts, back-/front-channel logout, introspection and
JWT validation at a resource server, with a custom provider JAR (mappers, authenticator, event listener) and theme.

## What it shows

| Case | From -> to | Mechanism | Downtime | What is lost |
|---|---|---|---|---|
| `patch` | 26.8.0 -> 26.8.1 | **shared DB**: green joins next to blue on the same database, flip the `kc-active` Service | none | nothing |
| `minor` | 26.7.5 -> 26.8.1 | **lossy overlap**: green gets its own copy of blue's database at a copy point (Postgres: CNPG replica promoted at an LSN; Oracle: Data Pump copy of the schema at an SCN) and migrates it; blue keeps serving logins/tokens; logouts + new users from the window are replayed onto green; flip | none for login/token; admin + account console answer 503 for the window | sessions created in the window (`[copy_point, switch]`): users re-login silently through the legacy IdP's SSO |
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
  B --> DB[("Postgres: pg-1 / pg-2 clusters<br/>Oracle: one instance, KC1 / KC2 schemas")]
  G --> DB
  B --> L["legacy IdP<br/>Spring Authorization Server"]
  G --> L
  A["testclient / testresource"] --> E
```

One Service selector routes the edge to exactly one color; the flip is a `kubectl patch` of that selector, so neither
the clients, the ingress nor the realm configuration change. Blue and green share a database in `patch` and have
one each in `minor`/`major` (green gets a copy of blue's at a copy point).

## Run it

Requirements: Docker with about 16 GB for the containers (measured peaks per engine: Results), git,
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

Oracle instead of Postgres: `DB_ENGINE=oracle docker compose run --rm launcher` (and `DB_ENGINE=oracle` on every later
launcher command, or the Jenkins build parameter `DB_ENGINE`). The engine is recorded on the cluster; a run with the
other engine stops before it changes anything. To change engines: `bash scripts/down.sh`, then bring up again.

```bash
docker compose up -d jenkins
```

1. `jenkins-secret.sh` generates the Jenkins admin password into `out/jenkins-admin-password` (gitignored).
2. The launcher runs `scripts/up.sh`: KinD cluster (1 control plane + 3 workers labelled zones a/b/c), ingress-nginx,
   the database platform (CNPG operator, or the 6 GiB Oracle 19.3 instance), certificates (demo CA in `out/certs/ca.crt`), the legacy IdP, the two native test apps,
   and a first blue Keycloak on the first database (`pg-1` / schema `kc1`). Idempotent; the first run builds images
   (a few minutes; Oracle 19.3 also creates its database, 15-20 minutes).
3. Jenkins: <http://localhost:8081>, user `admin`, password from step 1. Job **kc-bluegreen**, parameter `CASE`.
   Reset and Install run first; then two parallel branches — **Load** (k6 start, warm-up, cool-down) and **Cutover**
   (Switch, Soak + rollback) — joined by **Gate**. The load branch owns k6 for the whole run, so no pipeline step ever
   waits on the load; the one ordering point is the warm-up (the switch starts once sessions exist). Each phase logs a
   header saying what it does and why, and a result line with exit code and duration. The HTML report is built in
   every build's post step and archived with `out/**`.

Without Jenkins: `docker compose run --rm launcher bash scripts/demo.sh minor` (or `all`, or one phase:
`demo.sh minor switch`). Results land in `out/<case>/` (Oracle: `out/oracle/<case>/`): `k6.jsonl`, `apps.jsonl`, `events.jsonl`, `gate.txt`, the
Keycloak logs of each color, and `bash scripts/report.sh` writes `out/report.html` (`scripts/report.sh out/oracle` for the Oracle one).

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

Oracle: `PROFILE=laptop DB_ENGINE=oracle ORACLE_IMAGE=gvenzl/oracle-free:23.26.3-slim ORACLE_MEMORY=4Gi docker compose
run --rm launcher` (the 19.3 default needs the full profile; preflight refuses it here).

Then run cases with `PROFILE=laptop` (Jenkins build parameter, or
`PROFILE=laptop docker compose run --rm launcher bash scripts/demo.sh all`). The profile is recorded on the cluster;
a run with a different `PROFILE` stops before it changes anything.

Laptop = 2 KinD workers (zones a, b) instead of 3, 2 Keycloak pods per color instead of 3 (PDB 1 of 2, 1 GiB memory
limit), 2 Postgres instances per cluster instead of 3 or the 4 GiB gvenzl Free Oracle instance, the same load profile
(2 logins/s, 3 app VUs), 2 ingress-nginx workers. Same images, config stages, switch scripts and gate rules. Docker
Desktop / WSL2 memory (`.wslconfig`): 10 GB for Postgres (measured: 8.1 GiB peak for the KinD nodes, 9.1 GiB with
Jenkins, all five cases, 2026-11-03), about 13 GB for Oracle (an estimate, not measured). Not shown on the laptop
profile: the 3-zone spread, a pod kill that leaves 2 serving pods per color (here 1), the production PDB of 2 out of
3. Latency numbers are comparable within a run, not across profiles.

## How a run is judged

- **Gate** (`scripts/gate.sh`, rules explained in `scripts/gate/why.tsv`, printed under each row): no 5xx; issuer
  stable per network; same `sub` per user across versions; in-flight logins and refresh tokens survive (patch);
  pre-copy sessions survive and only window-born sessions are lost, each followed by a successful re-login (lossy);
  green's database copy is proven against the source (`db_copy_matches_source`: Postgres replica replayed past the
  copy LSN before the promote; Oracle copy holds exactly the users and sessions the source had at the copy SCN); logged-out sessions never come back
  after the replay; the app rules (introspection, JWT, refresh, back-/front-channel logout delivered, logout effective);
  and that load really ran through the cutover (`load_through_cutover`) and the lossy window really was exercised
  (`window_exercised`), so no rule can pass on silence.
- **Report** (`out/report.html`, one tab per case): the data baseline (requests, users), error rates over time with
  the switch events marked, latency distributions before/during/after the cutover, and the failure-mode table with
  counts, rates and expected bounds. Every failure mode carries a one-line explainer of what it means to a user
  (`report/modes.tsv`). Definitions: [docs/failure-modes.md](docs/failure-modes.md).

## Results

Both engines measured on **2026-11-11**, default profile, one machine, one KinD cluster per engine, five cases back to
back through Jenkins. **All ten gates PASS; 0 5xx / network errors in every case.** One run per
case: expect run-to-run spread. The full reports are `out/report.html` and `out/oracle/report.html` (gitignored;
Jenkins archives them).

Three defects surfaced during these runs and were fixed before the passing builds (details in the commits):
the new Postgres caught-up check compared `true` with `t` (first Postgres `minor`/`major`/`minor-rollback` died before
the promote); the rotating k6 sessions were in phase and could all rotate at the switch, leaving `window_exercised`
nothing to judge (one Oracle `minor-rollback` gate FAIL); and a rollback's reverse replay died on the log line of a
duplicate user the forward replay had already repaired (one Oracle `minor-rollback`). The last one is a real bug in
the mechanism, engine-independent, and needs a post-flip duplicate followed by a rollback to show.

### Postgres (CloudNativePG)

Builds **#16** (`patch`), **#17** (`minor`), **#18** (`major`), **#19** (`patch-rollback`), **#20** (`minor-rollback`),
all on `f159cbe` (the final code, all three fixes in): a second run of the day on a fresh cluster. The first run
(passing builds #1, #4, #6, #7, #8, before the k6 and replay fixes) passed the same gates; its lossy windows were
119-170 s and its lossy rollback took 65.5 s, which is the run-to-run spread to expect.

| | `patch` | `patch-rollback` | `minor` | `minor-rollback` | `major` |
|---|---|---|---|---|---|
| k6 requests | 14,181 | 14,765 | 24,005 | 30,265 | 24,626 |
| 5xx / network errors | 0 | 0 | 0 | 0 | 0 |
| error rate, whole run (cutover window) | 0 % (0 %) | 0 % (0 %) | 0.19 % (0.66 %) | 0.35 % (0.96 %) | 0.17 % (0.57 %) |
| users potentially impacted (of users seen) | 0 of 847 | 4 of 854 (slow only) | 25 of 1,285 (1.9 %) | 68 of 1,525 (4.5 %) | 26 of 1,313 (2.0 %) |
| lossy window (copy point -> switch) | - | - | 109.5 s | 112.8 s | 115.1 s |
| sessions lost (born on the old color in the window) | 0 | 0 | 254 (249 users) | 261 (253 users), +358 green-born (345 users) at the rollback | 265 (257 users) |
| of those, seen lost by k6 = silent re-logins | 0 | 0 | 3 | 9 (+4 green-born, at the rollback) | 4 |
| logouts / new users replayed | - | - | 14 / 49 | 16 / 40 forward, 17 / 53 back | 16 / 50 |
| users repaired (post-flip race) | - | - | 0 | 1 (on the rollback) | 0 |
| resurrection window (switch -> replay done) | - | - | 38.8 s | 40.0 s, rollback 42.8 s | 39.1 s |
| pod kill -> recovered (3 -> 2 -> 3 pods) | 43.1 s | 42.9 s | - | - | - |
| rollback (start -> traffic on the old color) | - | 0 s (Service flip) | - | 39.3 s (reverse replay + purge) | - |
| p95 network latency pre / cutover / post | 60 / 62 / 57 ms | 82 / 82 / 73 ms | 60 / 60 / 69 ms | 77 / 80 / 83 ms | 86 / 70 / 69 ms |
| step classes with cutover p95 >= 2x | introspection 2.2x | none | none | introspection 2.3x | none |
| schema changesets | - | - | 211 -> 238 | 211 -> 238 | 134 -> 238 |
| replica at the promote vs copy LSN | - | - | 0/AE17F78 >= 0/AE115D0 | 0/AB57278 >= 0/AB2B458 | 0/932D0F0 >= 0/932D0F0 |

Memory, all five cases (docker stats every 15 s): **12.23 GiB** peak for the KinD nodes, **13.16 GiB** with Jenkins
(rollback phase of `minor-rollback`: both colors and both Postgres clusters up). The first run of the day peaked at
12.65 / 14.03 GiB.

The lossy cases carry more requests than on Oracle: the switch stage first builds green's Postgres cluster as a
streaming replica (4.3 to 5 minutes from stage start to `replica_ready` in these runs), under load and before the copy
point, so none of it is in the lossy window.

### Oracle 19.3

Builds **#9** (`patch`), **#10** (`minor`), **#11** (`major`), **#12** (`patch-rollback`) on `df36c1b`; **#15**
(`minor-rollback`) on `f505a83`. Image `mohammedesafi/oracle-database:19.3.0-ee` (community build of Oracle's official
19.3 Dockerfiles, OTN Developer License; not an Oracle-supported production image), `ORACLE_MEMORY=6Gi`. The gvenzl
Free route was not re-run on this tree (last passed 2026-11-05 on the `oracle-19c` branch).

| | `patch` | `patch-rollback` | `minor` | `minor-rollback` | `major` |
|---|---|---|---|---|---|
| k6 requests | 15,260 | 14,803 | 13,795 | 21,441 | 14,152 |
| 5xx / network errors | 0 | 0 | 0 | 0 | 0 |
| error rate, whole run (cutover window) | 0 % (0 %) | 0 % (0 %) | 0.30 % (0.68 %) | 0.45 % (0.91 %) | 0.46 % (0.73 %) |
| users potentially impacted (of users seen) | 5 of 905 (slow only) | 4 of 892 (slow only) | 35 of 810 (4.3 %) | 57 of 1,180 (4.8 %) | 31 of 857 (3.6 %) |
| lossy window (copy point -> switch) | - | - | 129.1 s | 123.9 s | 141.7 s |
| sessions lost (born on the old color in the window) | 0 | 0 | 291 (278 users) | 286 (276 users), +360 green-born (351 users) at the rollback | 315 (305 users) |
| of those, seen lost by k6 = silent re-logins | 0 | 0 | 8 | 6 (+3 green-born, at the rollback) | 3 |
| logouts / new users replayed | - | - | 18 / 69 | 18 / 54 forward, 16 / 65 back | 21 / 71 |
| users repaired (post-flip race) | - | - | 3 | 1 (on the rollback) | 0 |
| resurrection window (switch -> replay done) | - | - | 44.9 s | 41.5 s, rollback 48.6 s | 44.2 s |
| pod kill -> recovered (3 -> 2 -> 3 pods) | 43.8 s | 43.3 s | - | - | - |
| rollback (start -> traffic on the old color) | - | 0 s (Service flip) | - | 40.4 s (reverse replay + purge) | - |
| p95 network latency pre / cutover / post | 85 / 70 / 62 ms | 77 / 81 / 74 ms | 73 / 67 / 65 ms | 101 / 89 / 93 ms | 67 / 63 / 68 ms |
| step classes with cutover p95 >= 2x | introspection 32.7x, app call 7.5x, refresh 4.6x | introspection 5.6x, app call 3.2x | none | none | none |
| schema changesets | - | - | 211 -> 238 | 211 -> 238 | 134 -> 238 |
| copy rows vs source AS OF the copy SCN | - | - | 4,317 = 4,317 | 4,322 = 4,322 | 4,306 = 4,306 |

Memory, all five cases plus two failed `minor-rollback` attempts: **13.19 GiB** peak for the KinD nodes, **14.71 GiB**
with Jenkins. The Oracle pod's working set peaked at 2.5 GiB of its 6 GiB limit.

### Reading it

- **Sessions lost is the exposure, not what k6 saw.** Every session created on the old color between the copy point
  and the flip is missing on the new one: 254-265 sessions per lossy case on Postgres, 286-315 on Oracle, roughly a
  fifth to a third of the users seen in a run. Each of them re-logins (silently, through legacy SSO) the next time
  they return. k6 comes back to about ten sessions (its refresh VUs), so it sees 3-9 of them die; those are the
  sample the gate judges. A rollback additionally drops every session born on the new color (358-360).
- **Users potentially impacted** (1.9-4.8 % in the lossy cases) counts people who hit at least one error line (a lost
  session's `invalid_grant`, a login straddling the flip, a channel logout for a session Keycloak no longer had) or a
  request over 1 s. The shared cases: at most a few slow-only users, no errors. Definition:
  [docs/failure-modes.md](docs/failure-modes.md).
- The errors in the lossy cases are the trade the mechanism makes, all inside its bound. No session born before the
  copy point was lost and no logged-out session came back after the replay, on either engine.
- **The copy is now proven per run** (`db_copy_matches_source`): Postgres by the replica's replay LSN at the promote,
  Oracle by row counts against the source `AS OF` the copy SCN. Before this run the rule had never passed live.
- **Engines compared**: the lossy window is the same order on both (110-115 s Postgres, 124-142 s Oracle); it is
  dominated by green's start and migration, not by the copy. The lossy rollback took about 40 s on both.
- **Oracle shared cases, latency during the pod kill**: `patch` shows introspection at 32.7x its pre-cutover p95 and
  `patch-rollback` at 5.6x, with no errors and the overall p95 unchanged. The Postgres runs show at most 2.3x. One run
  each; the cause was not investigated.
- Admin and account console answer 503 for the whole cutover window in the lossy cases (copy point -> window end,
  about 155-190 s). Login, token, refresh, logout, discovery and JWKS never stop.

## More

- [oracle/README.md](oracle/README.md): the Oracle route, Data Pump cutover, 19.3/Free images, tools, limits.
- [PLAN.md](PLAN.md): design, decisions and the **known limits** (written for Postgres; oracle/README.md is
  the Oracle delta).
- [docs/production-readiness.md](docs/production-readiness.md): what it would take to run this in an enterprise.
- [docs/test-apps.md](docs/test-apps.md): the OIDC test client and resource server (Spring Boot, GraalVM native).
- Security pipelines: Jenkins jobs **kc-kcwarden** (realm configuration audit) and **kc-security** (probes: TLS,
  tokens, redirect URIs, brute force, DCR, issuer, network policy, trivy, nuclei, ZAP, ...).
- Apache-2.0: [LICENSE](LICENSE). CI runs the offline checks (shellcheck, gate/report/lib tests) on every push
  (`.github/workflows/checks.yml`); the live cases need Docker and run through the local Jenkins.
