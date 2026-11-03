# Keycloak blue/green under load

A self-contained demo of zero-downtime Keycloak upgrades on Kubernetes (KinD): three Keycloak pods per color behind
ingress-nginx, Postgres via CloudNativePG, realm configuration through keycloak-config-cli, driven by Jenkins, measured
by k6 and two OIDC test apps while the cutover happens, and judged by a gate plus an HTML report.

Nothing is mocked on the path that matters: real brokered logins against a legacy Spring Authorization Server (users
live there; Keycloak holds no passwords), real token refreshes, logouts, back-/front-channel logout, introspection and
JWT validation at a resource server, with a custom provider JAR (mappers, authenticator, event listener) and theme.

## What it shows

| Case | From -> to | Mechanism | Downtime | What is lost |
|---|---|---|---|---|
| `patch` | 26.8.0 -> 26.8.1 | **shared DB**: green joins next to blue on the same Postgres, flip the `kc-active` Service | none | nothing |
| `minor` | 26.7.5 -> 26.8.1 | **lossy overlap**: green gets its own DB (CNPG replica of blue's, promoted at a copy point) and migrates it; blue keeps serving logins/tokens; logouts + new users from the window are replayed onto green; flip | none for login/token; admin + account console answer 503 for the window | sessions created in the window (`[copy_point, switch]`): users re-login silently through the legacy IdP's SSO |
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
  B --> DB[("PostgreSQL<br/>CNPG, sync replica")]
  G --> DB
  B --> L["legacy IdP<br/>Spring Authorization Server"]
  G --> L
  A["testclient / testresource"] --> E
```

One Service selector routes the edge to exactly one color; the flip is a `kubectl patch` of that selector, so neither
the clients, the ingress nor the realm configuration change. Blue and green share a database in `patch` and have one
each in `minor`/`major` (green gets a replica of blue's, promoted at the copy point).

## Run it

Requirements: Docker with about 16 GB for the containers (measured peak 13.6 GiB, see Results; the laptop profile
below fits 10 GB), git,
bash with `curl`, `jq` and `openssl` on the host (Git Bash works on Windows). Everything else (kind, kubectl, helm,
Maven, GraalVM, k6) runs in containers. Hostnames are `*.localtest.me`, which resolve to 127.0.0.1 publicly.

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
   CloudNativePG, certificates (demo CA in `out/certs/ca.crt`), the legacy IdP, the two native test apps, and a first
   blue Keycloak. Idempotent; the first run builds images and takes a while.
3. Jenkins: <http://localhost:8081>, user `admin`, password from step 1. Job **kc-bluegreen**, parameter `CASE`.
   Reset and Install run first; then two parallel branches — **Load** (k6 start, warm-up, cool-down) and **Cutover**
   (Switch, Soak + rollback) — joined by **Gate**. The load branch owns k6 for the whole run, so no pipeline step ever
   waits on the load; the one ordering point is the warm-up (the switch starts once sessions exist). Each phase logs a
   header saying what it does and why, and a result line with exit code and duration. The HTML report is built in
   every build's post step and archived with `out/**`.

Without Jenkins: `docker compose run --rm launcher bash scripts/demo.sh minor` (or `all`, or one phase:
`demo.sh minor switch`). Results land in `out/<case>/`: `k6.jsonl`, `apps.jsonl`, `events.jsonl`, `gate.txt`, the
Keycloak logs of each color, and `bash scripts/report.sh` writes `out/report.html`.

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
limit), 2 Postgres instances per cluster instead of 3 (synchronous replication kept), the same load profile (2
logins/s, 3 app VUs), 2 ingress-nginx workers. Same images, config stages, switch scripts and gate rules.

Measured over all five cases (2.3 h of 15 s samples): **8.1 GiB** peak for the KinD nodes, **9.1 GiB** with Jenkins
(rollback phase of `minor-rollback`: both colors and both Postgres clusters up). The default profile peaks at
12.6 GiB / 13.6 GiB (Results). So give Docker Desktop / WSL2 about 10 GB (`.wslconfig`: `memory=10GB`), or skip Jenkins and use the
launcher. Not shown on the laptop profile: the 3-zone spread, a pod kill that leaves 2 serving pods per color (here 1),
the production PDB of 2 out of 3. Latency numbers are comparable within a run, not across profiles.

## How a run is judged

- **Gate** (`scripts/gate.sh`, rules explained in `scripts/gate/why.tsv`, printed under each row): no 5xx; issuer
  stable per network; same `sub` per user across versions; in-flight logins and refresh tokens survive (patch);
  pre-copy sessions survive and only window-born sessions are lost, each followed by a successful re-login (lossy);
  logged-out sessions never come back after the replay; the app rules (introspection, JWT, refresh, back-/front-channel
  logout delivered, logout effective); and that load really ran through the cutover (`load_through_cutover`) and the
  lossy window really was exercised (`window_exercised`), so no rule can pass on silence.
- **Report** (`out/report.html`, one tab per case): error rates over time with the switch events marked, latency
  distributions before/during/after the cutover, and the failure-mode table with counts, rates and expected bounds.
  Definitions: [docs/failure-modes.md](docs/failure-modes.md).

## Results

Final run: Jenkins builds #33-#37, default profile, one fresh cluster, commit `f3d94e3` (latency rows re-judged with
`461bb41`, which unified the gate's and the report's cutover windows; no verdict changed). Load throughout: 2 brokered logins/s, refreshes every 5 s, logouts with probes, discovery/JWKS reads, 3 app VUs through the two test apps.
Every gate PASSes.

| | `patch` | `patch-rollback` | `minor` | `minor-rollback` | `major` |
|---|---|---|---|---|---|
| k6 requests | 29,030 | 32,183 | 53,345 | 69,243 | 56,739 |
| 5xx / network errors | 0 | 0 | 0 | 0 | 0 |
| error rate, whole run (cutover window) | 0 % (0 %) | 0 % (0 %) | 0.20 % (0.70 %) | 0.30 % (0.91 %) | 0.21 % (0.85 %) |
| lossy window (copy point -> switch) | - | - | 115.2 s | 111.6 s | 112.6 s |
| sessions lost = silent re-logins | 0 | 0 | 4 | 9 (+2 green-born, at the rollback) | 5 |
| logouts / new users replayed | - | - | 21 / 82 | 19 / 84 forward, 30 / 90 back | 21 / 68 |
| users repaired (post-flip race) | - | - | 0 | 1 | 0 |
| resurrection window (switch -> replay done) | - | - | 49.3 s | 49.9 s, rollback 50.4 s | 46.5 s |
| pod kill -> recovered (3 -> 2 -> 3 pods) | 43.3 s | 43.5 s | - | - | - |
| rollback (start -> traffic on the old color) | - | 0 s (Service flip) | - | 62.6 s (reverse replay) | - |
| p95 latency pre / cutover / post | 57 / 70 / 61 ms | 68 / 76 / 72 ms | 81 / 96 / 93 ms | 105 / 119 / 121 ms | 141 / 155 / 152 ms |
| step classes with cutover p95 > 2x | refresh 6.2x, introspection 3.4x, logout 2.2x, app calls 2.1x | introspection 2.8x | none | none | none |
| schema changesets | - | - | 211 -> 238 | 211 -> 238 | 134 -> 238 |

Reading it:

- The errors in the lossy cases are the trade the mechanism makes, all inside its bound: logins whose hops straddle
  the flip (started on blue, finished on green: 29 in `minor`, 69 in `minor-rollback`, 42 in `major`; the next attempt goes
  through legacy SSO), refreshes of sessions born in the lossy window (`invalid_grant`, then a silent re-login), and the
  apps' back-/front-channel logouts for those sessions (Keycloak on green never knew them). No session born before the
  copy point was lost, no logged-out session came back after the replay. One user in `minor-rollback` got a second
  `sub` in the post-flip race; the replay repaired it (first `sub` restored), the gate excuses exactly that one.
- The shared cases (same DB) lose nothing. Their slower classes fall in a cutover window that also holds a pod kill
  (3 -> 2 pods for ~45 s): refresh p95 22 -> 137 ms in `patch`, far below any client timeout. `patch-rollback`, same
  mechanism and pod kill, has only introspection over 2x (2.8x; refresh 1.5x): one machine, so expect run-to-run
  spread of that size.
- Admin and account console answer 503 from the copy point to the window end: 164-169 s per lossy switch, 112 s for
  the lossy rollback. Login, token, refresh, logout, discovery and JWKS never stop.
- Memory, default profile (`scripts/mem-sample.sh`, 262 samples, ~20 s apart, over all five cases): **12.6 GiB** peak for the four
  KinD nodes, **13.6 GiB** with Jenkins, during the `major` switch (both colors, both Postgres clusters, green
  migrating). Keycloak pod max 1.3 GiB, Postgres instance max 352 MiB.

The full numbers, per failure mode and per step class, are in the report (one tab per case).

## More

- [PLAN.md](PLAN.md): design, decisions and the **known limits** (what this demo deliberately does not solve).
- [docs/production-readiness.md](docs/production-readiness.md): what it would take to run this in an enterprise.
- [docs/test-apps.md](docs/test-apps.md): the OIDC test client and resource server (Spring Boot, GraalVM native).
- Security pipelines: Jenkins jobs **kc-kcwarden** (realm configuration audit) and **kc-security** (probes: TLS,
  tokens, redirect URIs, brute force, DCR, issuer, network policy, trivy, nuclei, ZAP, ...).
- Apache-2.0: [LICENSE](LICENSE). CI runs the offline checks (shellcheck, gate/report/lib tests) on every push
  (`.github/workflows/checks.yml`); the live cases need Docker and run through the local Jenkins.
