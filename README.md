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

## Run it

Requirements: Docker with about 14 GB for the containers (see the laptop profile below for 16 GB machines), git,
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
   One stage per phase: Reset, Install, Load + warm-up, Switch, Soak + rollback, Cool-down, Gate. Each phase logs a
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
limit), 2 Postgres instances per cluster instead of 3 (synchronous replication kept), 2 logins/s instead of 5,
3 app VUs instead of 6, 2 ingress-nginx workers. Same images, config stages, switch scripts and gate rules.

Measured over all five cases (2.3 h of 15 s samples): **8.1 GiB** peak for the KinD nodes, **9.1 GiB** with Jenkins
(rollback phase of `minor-rollback`: both colors and both Postgres clusters up). The default profile peaks at about
11.7 GiB. So give Docker Desktop / WSL2 about 10 GB (`.wslconfig`: `memory=10GB`), or skip Jenkins and use the
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

## More

- [PLAN.md](PLAN.md): design, decisions and the **known limits** (what this demo deliberately does not solve).
- [docs/production-readiness.md](docs/production-readiness.md): what it would take to run this in an enterprise.
- [docs/test-apps.md](docs/test-apps.md): the OIDC test client and resource server (Spring Boot, GraalVM native).
- Security pipelines: Jenkins jobs **kc-kcwarden** (realm configuration audit) and **kc-security** (probes: TLS,
  tokens, redirect URIs, brute force, DCR, issuer, network policy, trivy, nuclei, ZAP, ...).
