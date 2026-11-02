# Plan: zero-downtime blue-green Keycloak (3 pods/color) on KinD, Postgres, keycloak-config-cli, driven by Jenkins, launched by `docker compose up`

Research and decision trail: `C:\dev\_worklogs\keycloak-bluegreen\2026-11-02-research-design-questions.md`.

## Shared context

### Two change paths, both proven under load
| Path | Example in demo | DB | Downtime claim |
|---|---|---|---|
| **same-minor** | 26.8.0 -> 26.8.1 patch + provider/theme/config change | one shared CNPG cluster | zero: gate = 0 x 5xx, in-flight logins survive |
| **minor upgrade** | 26.7.5 -> 26.8.0 | green gets its own CNPG cluster (replica of blue's, promoted) | write-freeze only: login/token/admin -> 503 + Retry-After while green's DB migrates; discovery/JWKS stay up; freeze duration measured + reported |

Why there are two paths: Keycloak does not support two different major.minor versions on one DB
("Deploying different Keycloak major/minor versions on each of the sites is not supported",
multi-cluster v2 upgrades doc). A patch upgrade on one shared DB is supported.

Demo narrative (one run of `scripts/demo.sh` = what the README walks through):
1. bootstrap blue @ 26.7.5 on `pg-1`
2. **minor**: green @ 26.8.0 on `pg-2` (replica of pg-1 -> promoted -> migrated)
3. **same-minor**: blue @ 26.8.1 + provider v2 + theme v2 + online config, on shared `pg-2`

Colors are slots, DBs are generations: the active color and active DB are recorded in ConfigMap
`kc-state` (`activeColor`, `activeDb`, `version`), in namespace `keycloak`. Never derive one from the other.

### Topology
```
docker compose (host: only Docker needed)
 ├─ launcher  (toolbox image: kind, kubectl, helm, jq, k6-less) -> `kind create cluster`, installs platform, exits 0
 └─ jenkins   (custom LTS image: JCasC + job-dsl + git + docker CLI + kind/kubectl/helm/jq/mvn)
               docker.sock mounted -> builds images, `kind load`; repo mounted ro at /repo
KinD "kc": 1 control-plane + 3 workers (labels topology.kubernetes.io/zone=a|b|c), host 443 -> ingress
 ├─ ingress-nginx (kind provider manifest, final release)  host https://kc.localtest.me (resolves 127.0.0.1)
 ├─ cnpg-system: CloudNativePG operator
 ├─ keycloak ns:
 │   pg-<n>        CNPG Cluster, 3 instances, synchronous replication (ANY 1)
 │   kc-blue       Bitnami chart release, 3 pods, cluster-name kc-blue
 │   kc-green      Bitnami chart release, 3 pods, cluster-name kc-green
 │   kc-active     plain Service, selector app.kubernetes.io/instance=<color>  <- THE switch
 │   kc-maint      tiny nginx returning 503 + Retry-After: 5 (freeze backend)
 │   Ingress kc          host kc.localtest.me -> kc-active
 │   Ingress kc-freeze   (only during freeze) exact write paths -> kc-maint
 └─ load ns: k6 Job (hostAliases kc.localtest.me -> ingress-nginx ClusterIP)
```
Jenkins UI: http://localhost:8081 (8080 taken on dev box). Jenkins reaches the API server over the
docker network `kind` (compose declares it with `name: kind`; kind reuses an existing network of that
name). Kubeconfig via `kind get kubeconfig --internal`.

### Fixed facts (verified 2026-11-02)
- Keycloak 26.8.1 latest; 26.8.0 and 26.7.5 exist. `stateless` feature = preview since 26.7: auth
  sessions, action tokens, brute-force counters go to the DB; cross-cluster cache invalidation via a
  DB outbox polled every 100 ms. User sessions are in the DB anyway (persistent-user-sessions, 26.0+).
- Default discovery since 26.1 is `jdbc-ping` (through the DB). Blue and green share a DB, so EACH
  COLOR MUST SET ITS OWN cluster name: `--spi-cache-embedded--default--cluster-name=kc-<color>`
  (env `KC_SPI_CACHE_EMBEDDED__DEFAULT__CLUSTER_NAME`; verify the env spelling in Slice 1).
- Bitnami chart: latest is `oci://registry-1.docker.io/bitnamicharts/keycloak` **25.2.0**
  (appVersion 26.3.3, frozen). Templates hard-code `/opt/bitnami/keycloak/{conf,lib/quarkus,data,
  providers,themes}`. The init container `prepare-write-dirs` runs `/bin/bash` and sources
  `/opt/bitnami/scripts/liblog.sh`, then `cp -r` those dirs into emptyDirs. The default readiness probe
  is `GET /realms/master` on the http port. With `usePasswordFiles: true` (the default) the chart sets
  `KC_DB_PASSWORD_FILE`, which only Bitnami's scripts understand.
  => our image re-lays the official image into `/opt/bitnami/keycloak` and adds a `liblog.sh` stub
     (`info(){ echo "$@"; }`). Values set `usePasswordFiles: false`,
     `command: [/opt/bitnami/keycloak/bin/kc.sh]`, `args: [start, --optimized]`, and custom probes.
- keycloak-config-cli: image `adorsys/keycloak-config-cli:6.5.0-26`, built against KC 26.5.4.
  A version mismatch silently drops fields it does not know -> the dropped-field check in Slice 2 is mandatory.
- ingress-nginx has been EOL since March 2026. It is used because it is the user's production edge. The
  switch mechanism (Service selector) does not depend on the edge. Do NOT use `use-regex` (it applies to all
  paths of the host); freeze paths are plain Prefix paths.

### Config-cli stages (`config/<stage>/*.yaml`, one k8s Job per stage run, launched by Jenkins)
- **bootstrap**: first install only. With the temporary bootstrap admin (`KC_BOOTSTRAP_ADMIN_*`),
  creates master client `config-cli` (client_credentials, realm `admin` role) and the empty `demo`
  realm. The Job no-ops if realm `demo` exists. Later stages authenticate as `config-cli`.
- **online**: backward-compatible, applied while traffic flows on the shared DB: clients, client
  scopes (`tenant`), mappers, roles, groups, theme selection, event listeners, additive flows.
- **maintenance**: breaking changes (rebind browser flow, delete/rename clients or scopes).
  On the minor path it runs against green's DB during the freeze, which costs no extra downtime.
  On the same-minor path it needs its own short write-freeze (same `kc-freeze` mechanism, since the DB
  is shared). That is the honest limit of blue-green on a shared DB.
- Settings for all stages: `import.remote-state.enabled=true`, `import.var-substitution.enabled=true`
  (client secrets from env), `import.validate=true`. Keep `import.managed.*` at the defaults except
  `no-delete` in online (online must never delete).
- Users are test data, not config: 5k users are seeded by `scripts/seed-users.sh` via admin
  `partialImport`, not by config-cli.

### Custom code (realism, baked into the image)
`providers/` Maven module `kc-demo-ext`, built against `keycloak-services` ${kc.version}, the lowest version deployed (26.7.5):
- `TenantMapper`: OIDC protocol mapper, user attribute `tenant` -> claim `tenant`. Attached to client scope `tenant`.
- `LoginContextAuthenticator`: no-UI authenticator in custom flow `browser-demo`. Sets auth note
  `login_ctx=<provider version>`. `LoginContextMapper` copies it to claim `login_ctx`. The claim
  proves which provider version handled the login (v1 -> v2 across same-minor).
- `LogoutAuditListener`: event listener, logs `LOGOUT`/`LOGOUT_ERROR` as one JSON line.
- `themes/demo`: login theme (`login.ftl`, `logout-confirm.ftl` overrides, CSS) with a visible version
  marker `data-theme-version`.

### Run / test
- Everything: `docker compose up -d` -> Jenkins at :8081, job `kc-bluegreen` (params: `PATH_TYPE`
  = bootstrap|minor|same-minor, `TARGET_VERSION`, `PROVIDER_VERSION`, `RUN_MAINTENANCE`).
- Full narrative without clicking: `docker compose run --rm launcher scripts/demo.sh`
- Unit: `mvn -f providers verify` (in the jenkins image)
- Static: `shellcheck scripts/*.sh scripts/lib/*.sh`, and `helm template` + `kubeconform` on values
- The real test is the gate (Slice 4). Every path slice is done only when its gate is green in a real run.

## Invariants (all slices)
- caveman + ponytail. Bash only (`set -euo pipefail`). No script over ~150 lines; shared functions go in `scripts/lib/kc.sh`.
- Production realism, not dev mode:
  - `kc.sh start --optimized`, `KC_HOSTNAME=https://kc.localtest.me`, hostname strict, `KC_PROXY_HEADERS=xforwarded`, TLS at ingress (CA + cert from `scripts/certs.sh`, openssl).
  - Per pod: requests 1 CPU / 1.5Gi, limit 2Gi. Anti-affinity + topologySpread across zones. PDB `maxUnavailable: 1`.
  - Readiness `GET /health/ready` on management port 9000. Liveness `/health/live` (period 10s, not the chart's 1s).
  - `preStop: sleep 15`, `terminationGracePeriodSeconds: 60`.
- Secrets are generated at `up` (random), stored as k8s Secrets, never committed. Repo is public.
- Never `kubectl delete --force` in a gated step. A graceful pod kill is gated; a force kill is reported only
  (non-idempotent POST in flight on a SIGKILLed pod gives a 502 that no edge can hide).
- Every switch, freeze and promote step writes a timestamped JSON event to `out/events.jsonl`; the gate reads it.

## Slice 1: platform + blue Keycloak (bootstrap)
- **Files**: create `compose.yaml`, `images/launcher/Dockerfile`, `images/jenkins/Dockerfile` (stub,
  filled in Slice 7), `images/keycloak/Dockerfile`, `images/keycloak/liblog.sh`, `kind/cluster.yaml`,
  `scripts/up.sh`, `scripts/down.sh`, `scripts/certs.sh`, `scripts/lib/kc.sh`, `k8s/postgres/pg.yaml.tpl`,
  `k8s/edge/{kc-active.yaml,ingress.yaml}`, `helm/values-common.yaml`, `helm/values-color.yaml.tpl`
- **Contract**:
  - `scripts/up.sh`: idempotent. Creates cluster `kc`, installs ingress-nginx, CNPG, certs, `pg-1`, and builds +
    `kind load`s `kc-demo:<ver>-p<provider>`.
  - `scripts/lib/kc.sh deploy_color <color> <version> <db>`: helm upgrade --install with `--wait`.
  - `kc.sh set_active <color>`: patches the `kc-active` selector and writes the `kc-state` ConfigMap.
  - Example: `deploy_color blue 26.7.5 pg-1 && set_active blue` -> `curl -k https://kc.localtest.me/realms/master/.well-known/openid-configuration` returns 200 with `"issuer":"https://kc.localtest.me/realms/master"`.
- **Tests**: `scripts/check-cluster.sh blue` asserts: 3 Ready pods on 3 distinct zones; the JGroups view
  has size 3 and contains only kc-blue pods (grep pod logs for `ISPN000094`); `kc-state.activeColor=blue`.
- **Regression scope**: none (pure create)
- **Done**: `docker compose up launcher` on a clean box ends with exit 0 and the check passes. A browser on the host reaches the admin console via TLS.
- **Don't touch**: providers/, config/, load/
- **Depends on**: none

## Slice 2: config-cli stages + seeded users
- **Files**: create `config/bootstrap/00-master-config-cli.yaml`, `config/bootstrap/10-demo-realm.yaml`,
  `config/online/*.yaml` (client `k6-app` confidential + redirect `https://app.localtest.me/cb`,
  scope `tenant`, flow `browser-demo`, theme `demo`, event listener), `config/maintenance/10-bind-browser-demo.yaml`,
  `k8s/config-cli-job.yaml.tpl`, `scripts/config.sh`, `scripts/seed-users.sh`, `scripts/check-config.sh`
- **Contract**:
  - `scripts/config.sh <stage> <color>`: runs the Job against `http://kc-<color>.keycloak:80` (internal,
    bypasses ingress, so it also works during a freeze) and waits until it completes.
  - `scripts/check-config.sh <stage>`: exports the realm via the admin API and asserts every
    leaf key/value in `config/<stage>/*.yaml` appears in the export (jq). This is the dropped-field check.
  - Example: `config.sh online blue && check-config.sh online` -> exit 0. Corrupting a value in the export -> exit 1, naming the path.
- **Tests**: re-running every stage twice is a no-op (second run's admin-event count = 0).
  `seed-users.sh 5000` -> `GET /admin/realms/demo/users/count` = 5000, each user with attribute `tenant`.
- **Regression scope**: Slice 1 check-cluster
- **Done**: bootstrap -> online -> maintenance on blue, all checks green; the bootstrap admin is no longer needed by later stages.
- **Don't touch**: providers/, images/
- **Depends on**: 1

## Slice 3: provider JAR + theme
- **Files**: create `providers/pom.xml`, `providers/src/main/java/demo/kc/{TenantMapper,LoginContextAuthenticator,
  LoginContextAuthenticatorFactory,LoginContextMapper,LogoutAuditListener,LogoutAuditListenerFactory}.java`,
  `providers/src/main/resources/META-INF/services/*`, `providers/src/test/java/demo/kc/*Test.java`,
  `themes/demo/login/{theme.properties,login.ftl,logout-confirm.ftl,resources/css/demo.css}`. Edit `images/keycloak/Dockerfile` (COPY jar + theme before `kc.sh build`).
- **Contract**: `PROVIDER_VERSION` (maven property, default `1`) is baked into the authenticator's note value.
  Example: login through flow `browser-demo` with provider v1 -> access token has `"login_ctx":"v1"` and
  `"tenant":"<user attr>"` (when scope `tenant` is requested).
- **Tests** (JUnit, public behaviour only): mapper with attribute `tenant=acme` -> claim `acme`; no attribute -> no claim.
  Listener formats a LOGOUT event into exactly one JSON line with `type,realmId,userId,sessionId`.
- **Regression scope**: none (pure create); the image rebuild must keep Slice 1's check green.
- **Done**: `mvn verify` green. An image with the jar boots; the claims appear in a manual auth-code login.
- **Don't touch**: config/ (Slice 2 owns it; Slice 3 only names `browser-demo`, `tenant`, `demo` to match)
- **Depends on**: 1 (image); runtime check needs 2

## Slice 4: load + gate
- **Files**: create `load/k6/flows.js`, `k8s/k6-job.yaml.tpl`, `scripts/load.sh`, `scripts/gate.sh`
- **Contract**:
  - k6 scenarios (constant arrival rate, 10 min max, stopped by `load.sh stop`):
    - `login`: full auth-code flow. GET `/auth`, parse the form (`k6/html`), think time 0-20 s, POST the credentials, take the code from `Location` (redirects: 0), POST `/token`.
    - `refresh`: hold a refresh token, refresh every 5 s.
    - `logout`: RP-initiated logout with `id_token_hint`.
    - `reads`: discovery + JWKS every 1 s.
  - Each request logs one JSON line: `{t_start,t_end,scenario,step,status,login_id,claims:{login_ctx,tenant}}`.
  - `gate.sh <path>` reads the k6 lines + `out/events.jsonl` and prints a table. It exits non-zero on any failed rule:
    - same-minor: 0 responses >= 500 or status 0; >= 1 login with GET before `switch` and POST after it, all of them succeeded; every refresh token issued before the switch refreshes OK after it; claims all present.
    - minor: reads show 0 errors over the whole run; 503 appears only in `[freeze_start, freeze_end]` and only on write paths; >= 1 refresh token issued before the freeze refreshes OK after it; prints `freeze_seconds`.
  - Example: a synthetic file where one 502 lands 2 s after `switch` -> `gate.sh same-minor` exit 1, printing that line.
- **Tests**: `scripts/test-gate.sh` feeds 4 synthetic fixtures (`load/fixtures/*.jsonl`): pass, 5xx, broken in-flight login, 503 outside the freeze -> expected exits 0,1,1,1.
- **Regression scope**: none
- **Done**: fixtures green. A 5-minute run against blue with no switch -> `gate.sh same-minor` reports 0 errors (the switch-crossing rule is skipped when there is no `switch` event).
- **Don't touch**: providers/, config/
- **Depends on**: 2, 3

## Slice 5: same-minor switch (shared DB)
- **Files**: create `scripts/switch-same-minor.sh`; edit `scripts/lib/kc.sh` (add `drain_color`, `kill_one`)
- **Contract**: `switch-same-minor.sh <target_version> <provider_version>`
  1. Deploy the idle color with the target image on `activeDb`, own cluster-name, `--wait`.
  2. `check-cluster.sh <idle>`: two separate JGroups views exist, each of size 3.
  3. Smoke on the idle color via its internal Service: login and claims show the new `login_ctx`.
  4. `config.sh online <idle>`. Thanks to stateless invalidation, the active color sees the change within 1 s (asserted).
  5. `event switch`, then `set_active <idle>`.
  6. Graceful-delete one pod of each color, wait for Ready again (event `kill`).
  7. Keep the old color for `DRAIN_SECONDS=60`, then scale it to 0 (event `drained`).
  8. Optional `RUN_MAINTENANCE=1`: freeze -> `config.sh maintenance` -> unfreeze, measured like the minor path.
- **Tests**: a full run under `load.sh` -> `gate.sh same-minor` exit 0. Negative control (run once and record in the README): the same switch WITHOUT `--features=stateless` must fail the in-flight-login rule. This proves the gate can tell the two apart.
- **Regression scope**: Slices 1-4 checks
- **Done**: gate green twice in a row (blue->green, green->blue).
- **Don't touch**: providers/, load/k6 (bugs found there go back to Slice 4)
- **Depends on**: 4

## Slice 6: minor upgrade (per-color DB, write-freeze)
- **Files**: create `scripts/switch-minor.sh`, `k8s/postgres/pg-replica.yaml.tpl`, `k8s/edge/{kc-maint.yaml,kc-freeze-ingress.yaml}`; edit `scripts/lib/kc.sh` (`freeze`, `unfreeze`, `wait_replica_caught_up`, `promote_db`)
- **Contract**: `switch-minor.sh <target_version>`
  1. Create `pg-<n+1>` as a CNPG replica cluster of `activeDb` (streaming) and wait for it to be streaming.
  2. Pre-pull and `kind load` the target image (keeps the freeze short).
  3. `event freeze_start`, then apply `kc-freeze`. Prefix paths under `/realms/` for `protocol/openid-connect/{auth,token,logout}`, `login-actions`, `broker`, plus `/admin` -> kc-maint 503.
  4. `wait_replica_caught_up`: replay LSN = primary current LSN.
  5. Promote (`spec.replica.enabled=false`) and wait until the primary is writable.
  6. Deploy the idle color on the target version against `pg-<n+1>`: 1 replica first, so the migration runs once; then scale to 3.
  7. `config.sh maintenance <idle>` (if any), then smoke internally.
  8. `set_active <idle>`, then `event switch`, `unfreeze`, `event freeze_end`.
  9. Keep the old color + old DB for `ROLLBACK_HOLD=10m`. Rollback = `set_active` back, which loses writes made after the freeze (documented).
- **Tests**: a full 26.7.5 -> 26.8.0 run under load -> `gate.sh minor` exit 0, with `freeze_seconds` printed.
  The image and replica are prepared before the freeze, so the expected freeze is roughly the migration time plus 1-2 pod starts.
- **Regression scope**: Slices 1-5
- **Done**: gate green; sessions created on blue are still valid on green (refresh rule); `kc-state.activeDb=pg-2`.
- **Don't touch**: providers/, load/
- **Depends on**: 5 (shares kc.sh)

## Slice 7: Jenkins in compose
- **Files**: fill `images/jenkins/Dockerfile` (FROM jenkins/jenkins:lts-jdk21, plugins via
  `jenkins-plugin-cli`: configuration-as-code, job-dsl, workflow-aggregator, git, timestamper; installs docker
  CLI, kind, kubectl, helm, jq, maven), `jenkins/casc.yaml`, `jenkins/jobs.groovy`, `Jenkinsfile`; edit `compose.yaml`
- **Contract**:
  - The pipeline checks out `file:///repo` (`-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true`) and runs on the built-in node. ponytail: no agents; add k8s/docker agents when builds need isolation.
  - Stages: build provider + image -> `kind load` -> start load -> path script (`PATH_TYPE`) -> stop load -> gate -> archive `out/` (gate table, events, k6 summary).
  - Example: build with `PATH_TYPE=same-minor TARGET_VERSION=26.8.1 PROVIDER_VERSION=2` -> SUCCESS, with artifact `out/gate.txt` showing 0 errors.
- **Tests**: on a clean box, `docker compose up -d` lets `scripts/demo.sh` trigger the 3 builds in narrative order through the Jenkins REST API. All 3 succeed.
- **Regression scope**: Slices 1-6 via the pipeline
- **Done**: as Tests. Jenkins has no manual setup (JCasC only), and the admin password is generated into a compose secret.
- **Don't touch**: scripts/ logic (Jenkins only orchestrates)
- **Depends on**: 6

## Slice 8: README + publish
- **Files**: create `README.md` (narrative, architecture diagram, measured results table from a real run, the negative control, known limits), `LICENSE` (Apache-2.0)
- **Done**: README numbers come from a real `out/` and none are invented. Push to a public GitHub repo `keycloak-bluegreen` only after the user confirms.
- **Depends on**: 7

## Parallelism
The live cluster is one shared resource, so every slice that runs the cluster is serial: 1 -> 2 -> 4 -> 5 -> 6 -> 7 -> 8.
Slice 3's Java + theme work (mvn verify, no cluster) can run in parallel with Slice 2. The Slice 4
fixtures and `gate.sh` (no cluster) can run in parallel with 2 and 3. Slice 7's Dockerfile/casc can be drafted in parallel with 5 and 6.

## Integration tests (owned by no slice; final review writes + runs)
- Provider v1 on blue, v2 on green, same-minor switch: every login completed after `switch` has `login_ctx=v2`. Logins whose POST lands on green but whose GET was on blue also end with `v2` (the flow continues on green).
- An online config change applied via green is visible on blue within 1 s (stateless invalidation across clusters).
- After the minor path: `GET /admin/realms/demo/users/count` = 5000 on green (data survived replica + promote + migration).
- The refresh token from the first login of the whole demo (issued on 26.7.5, blue) still refreshes after both switches.
- `kubectl get pods -A`: no pod of either color has a JGroups view containing the other color.

## Known limits (state in README, don't build around)
- Minor/major upgrades are not zero-downtime for writes. The freeze is the migration window.
- `stateless` is a preview feature, and it roughly doubles DB load.
- Single host: all KinD "zones" are one machine, and clock skew between clusters (stateless needs < 10 s) cannot occur here.
- Writes on the old color after a rollback flip are lost (no reverse replication).
- No backchannel logout receiver; logout coverage = RP-initiated logout + event listener.
