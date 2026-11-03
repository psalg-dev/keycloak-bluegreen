# Plan: zero-downtime blue-green Keycloak (3 pods/color) on KinD, Postgres, keycloak-config-cli, driven by Jenkins, launched by `docker compose up`

Research and decision trail: `C:\dev\_worklogs\keycloak-bluegreen\2026-11-02-research-design-questions.md`.

## Shared context

### Three cases, two mechanisms, all proven under load
| Case (`CASE=`) | FROM -> TO (standalone run) | Mechanism | DB | Downtime claim |
|---|---|---|---|---|
| **patch** | 26.8.0 -> 26.8.1, plus provider v2 + theme v2 + online config | shared-DB switch | one shared CNPG cluster | zero: gate = 0 x 5xx, in-flight logins survive |
| **minor** | 26.7.5 -> 26.8.1 | lossy overlap | green gets its own CNPG cluster (replica of blue's, promoted) | no login/token outage (see below) |
| **major** | 25.0.6 -> 26.8.1 | lossy overlap | same as minor | same as minor, plus a measured cross-major refresh-token result |

**Lossy overlap**:
- No login/token outage: blue keeps serving while green's copy migrates.
- Sessions created on blue in the window are lost; those users re-login silently via the legacy IdP's SSO.
- Logouts and first-broker-login user creations from the window are REPLAYED onto green.
- Only `/admin` + the account console get 503.
- Window length and sessions lost are measured.

Why two mechanisms: Keycloak does not support two different major.minor versions on one DB
("Deploying different Keycloak major/minor versions on each of the sites is not supported",
multi-cluster v2 upgrades doc). A patch upgrade on one shared DB is supported.
On the minor path a write made on blue after the copy point has to be blocked, lost or replayed.
Lossy works here because users live in the legacy Spring IdP (Keycloak only brokers; it holds no
passwords). A lost session costs one silent redirect. Two kinds of lost write are NOT acceptable and are replayed:
- **logout**: lost logout = the session is resurrected on green and an RP refresh token works again (security)
- **first-broker-login**: lost user creation = the next login on green creates a NEW user id, so `sub` changes for that person

Strict write-freeze variant (503 on login/token during migration): designed earlier, not built (lossy chosen 2026-11-02).

**Two networks (mirrors prod, user 2026-11-02)**. This supersedes any single `legacy` alias / `kc.localtest.me` /
`legacy.localtest.me` mention below.
| Network | Keycloak host (hostname-strict=false) | Legacy IdP host | Keycloak IdP alias |
|---|---|---|---|
| net1 | `kc-net1.localtest.me/keycloak` | `legacy-net1.localtest.me` | `legacy-net1` |
| net2 | `kc-net2.localtest.me/keycloak` | `legacy-net2.localtest.me` | `legacy-net2` |
- One legacy IdP instance serves both hosts; its issuer follows the host (`https://legacy-netN.localtest.me`).
  One client `keycloak-broker` (secret in Secret `legacy-broker` in ns `keycloak`, key `client-secret`), redirect URI per pair:
  `https://kc-netN.localtest.me/keycloak/realms/demo/broker/legacy-netN/endpoint`. PKCE required.
  Its id_token carries `sub`=`preferred_username`=`userNNNN`, `email`=`userNNNN@legacy.example`, `tenant`=`t<NNNN % 10>`.
- The issuer must stay stable to the outside world: exactly one issuer per Keycloak host, identical on blue and green.
  Enforced by the ingress (routes only the two hosts, overwrites X-Forwarded-Host) plus the chart NetworkPolicy: only
  ingress-nginx, the release's own pods and pods labelled `kc-<color>-keycloak-client: "true"` reach Keycloak directly.
  EVERY in-cluster job that talks to a color's Service directly (config-cli, seed, replay, smoke-direct) MUST carry
  that label, or it gets no connection.
- The same person can arrive via either network: first-broker-login flow `first-broker-auto-link` = Create User If
  Unique (ALTERNATIVE) + Automatically Set Existing User (ALTERNATIVE), on both IdP configs. A net2 login of a user
  linked via net1 adds a second federated link to the SAME user (same id, same `sub`).
  Auto-links written on blue in a lossy window are simply redone on the next login via green (same user), so they are
  NOT replayed. Only brand-new user creations are.
- A token issued via net1 is only valid at net1 (issuer differs). k6 keeps each VU on one network per session.
- Browser-like clients must send `Accept: text/html` to the legacy IdP; without it Spring answers 401 instead of
  redirecting to /login (found in Slice 1b).

Users: the legacy IdP has 5k users. Keycloak has users 1-4000 pre-linked (federated identity
`legacy-net1`); 4001-5000 hit first-broker-login on their first login (exercises the creation-replay path).

Demos are STANDALONE (user's choice): `scripts/demo.sh <patch|minor|major|all>`.
- Each case starts with `scripts/reset.sh`: uninstall both colors, delete every `pg-*`, delete the `load` Jobs, and recreate `pg-1`.
- Then it bootstraps blue at the case's FROM version (config bootstrap + online, seed users), warms up 2 min under load, and runs the case's switch under load.
- `all` = the three cases in sequence, with a reset between them.
- One case = one Jenkins build (param `CASE`). The legacy IdP, ingress, CNPG operator and Jenkins survive resets.

Colors are slots, DBs are generations: the active color and active DB are recorded in ConfigMap
`kc-state` (`activeColor`, `activeDb`, `version`), in namespace `keycloak`. Never derive one from the other.

**Context path `/keycloak`** (user, 2026-11-02): the public base is `https://kc.localtest.me/keycloak`. Every Keycloak
path in this plan (`/realms/...`, `/admin`, `/health/...`, freeze paths, broker redirect URIs) is relative to `/keycloak`.
It is baked at build (`--http-relative-path=/keycloak`) and must equal the chart's `httpRelativePath` exactly.
On 26.8.1 a mismatch makes `start --optimized` exit with code 2 after a single warning line, hiding the real error.
The management port inherits it (`/keycloak/health/*`).

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
 │   Ingress kc-gate     (permanent) admin/account Prefix paths -> Service kc-gate: active color, kc-maint when frozen
 ├─ legacy ns: legacy-idp (Spring Authorization Server, 1 replica, in-memory sessions), https://legacy.localtest.me
 │             NOT part of blue/green; it is the "outside world" Keycloak brokers to
 └─ load ns: k6 Job
CoreDNS rewrite: `*.localtest.me` -> ingress-nginx controller Service. Pods, Keycloak's broker
back-channel and k6 all use the same public URLs as the host browser. No hostAliases, no internal/external URL split.
Keycloak trusts the demo CA via the chart's `trustedCertsExistingSecret` (-> `KC_TRUSTSTORE_PATHS`).
```
Jenkins UI: http://localhost:8081 (8080 taken on dev box). Jenkins reaches the API server over the
docker network `kind`. Compose does NOT declare it: a `kind` network created by another kind cluster carries no compose
labels, and compose refuses to adopt it. Instead the launcher entrypoint (`kube_connect`) runs `docker network connect kind`.
Kubeconfig via `kind get kubeconfig --internal`.
`demo.sh` runs with `ROLLBACK_HOLD=0` (the next case resets anyway); Jenkins builds default to 10m.

### Fixed facts (verified 2026-11-02)
- Keycloak 26.8.1 latest; 26.8.0 and 26.7.5 exist. `stateless` feature = preview since 26.7: auth
  sessions, action tokens, brute-force counters go to the DB; cross-cluster cache invalidation via a
  DB outbox polled every 100 ms. User sessions are in the DB anyway (persistent-user-sessions, 26.0+).
- Default discovery since 26.1 is `jdbc-ping` (through the DB). Blue and green share a DB, so EACH
  COLOR MUST SET ITS OWN cluster name. On 26.8.1 that is `cache-embedded-cluster-name` (env `KC_CACHE_EMBEDDED_CLUSTER_NAME`),
  and it is REQUIRED once `stateless` is on. The SPI form from the nightly docs is ignored.
  Verified in Slice 1: JGroups channel `kc-blue`, `jgroups_ping.cluster_name = kc-blue`.
- Bitnami chart: latest is `oci://registry-1.docker.io/bitnamicharts/keycloak` **25.2.0**
  (appVersion 26.3.3, frozen). Templates hard-code `/opt/bitnami/keycloak/{conf,lib/quarkus,data,
  providers,themes}`. The init container `prepare-write-dirs` runs `/bin/bash` and sources
  `/opt/bitnami/scripts/liblog.sh`, then `cp -r` those dirs into emptyDirs. The default readiness probe
  is `GET /realms/master` on the http port. With `usePasswordFiles: true` (the default) the chart sets
  `KC_DB_PASSWORD_FILE`, which only Bitnami's scripts understand.
  => our image re-lays the official image into `/opt/bitnami/keycloak` and adds a `liblog.sh` stub
     (`info(){ echo "$@"; }`). Values set `usePasswordFiles: false`,
     `command: [/opt/bitnami/keycloak/bin/kc.sh]`, `args: [start, --optimized]`, custom probes, and
     `global.security.allowInsecureImages: true` (in values-common).
- Build-time options are baked by `kc.sh build`. Under `start --optimized`, a different runtime value is
  ignored with a warning. Exact Dockerfile line:
  `kc.sh build --db=postgres --cache=ispn --cache-stack=jdbc-ping --health-enabled=true --metrics-enabled=true --features=stateless`.
  The chart env (`KC_CACHE`, `KC_CACHE_STACK`, `KC_METRICS_ENABLED`) must match it. Without
  `--health-enabled=true`, `/health/ready` returns 404 and no pod ever goes Ready. `stateless` is
  build-time, so the Slice 5 negative control needs a second image tag (`-nostateless`).
- keycloak-config-cli images are picked per Keycloak MAJOR of the target color: `adorsys/keycloak-config-cli:6.5.1-26.5.5`
  for 26.x, `6.5.1-25` (built against 25.0.1) for 25.x (Docker Hub tag list, 2026-11-02).
  A version mismatch silently drops fields it does not know -> the dropped-field check in Slice 2 is mandatory.
- Keycloak 25 differs from 26 in ways the image/values must handle (Slice 6b):
  - User sessions are in the DB only with the preview flag `persistent-user-sessions`. It must be on from
    the FIRST start; enabling it later never migrates existing sessions. Spelling: the 25.0.0 docs say
    `persistent-user-session`, later docs the plural; verify on 25.0.6.
  - No `stateless`, no `jdbc-ping`: use `--cache-stack=kubernetes` (DNS_PING on the release's headless
    Service, so colors are separated by DNS).
  - Bootstrap admin env is `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` (not `KC_BOOTSTRAP_ADMIN_*`).
  - No `update-compatibility` command.
- ingress-nginx has been EOL since March 2026. It is used because it is the user's production edge. The
  switch mechanism (Service selector) does not depend on the edge. Do NOT use `use-regex` (it applies to all
  paths of the host); freeze paths are plain Prefix paths.

### Config-cli stages (`config/<stage>/*.yaml`, one k8s Job per stage run, launched by Jenkins)
- **bootstrap**: first install only. With the temporary bootstrap admin (`KC_BOOTSTRAP_ADMIN_*`),
  creates master client `config-cli` (client_credentials, realm `admin` role) and the empty `demo`
  realm. The Job no-ops if realm `demo` exists. Later stages authenticate as `config-cli`.
- **online**: backward-compatible, applied while traffic flows on the shared DB: identity providers
  `legacy-net1` + `legacy-net2` (OIDC, client `keycloak-broker`, PKCE, sync mode FORCE, mapper `tenant` claim -> attr,
  first-broker-login flow `first-broker-auto-link`), clients, client
  scopes (`tenant`), mappers, roles, groups, theme selection, event listeners, additive flows.
- **maintenance**: breaking changes (rebind browser flow, delete/rename clients or scopes).
  On the minor/major path it runs against green's own DB before the switch, which costs no extra downtime.
  On the patch (shared-DB) path it needs its own short write-freeze (same `kc-gate` mechanism, since the DB
  is shared). That is the honest limit of blue-green on a shared DB.
- Settings for all stages: `import.remote-state.enabled=true`, `import.var-substitution.enabled=true`
  (client secrets from env), `import.validate=true`. Keep `import.managed.*` at the defaults except
  `no-delete` in online (online must never delete).
- Users are test data, not config. `scripts/seed-users.sh` pre-links users 1-4000 via admin
  `partialImport` (`federatedIdentities: [{identityProvider: legacy, userId: <legacy sub>, userName}]`,
  no credentials), not via config-cli.
- The bootstrap realm sets `ssoSessionIdleTimeout`/`ssoSessionMaxLifespan` long enough (2h/10h) for the
  first-login refresh token to survive the whole demo.

### Custom code (realism, baked into the image)
`providers/` Maven module `kc-demo-ext`, ONE source tree built per Keycloak major via Maven profiles `kc25` (25.0.6)
and `kc26` (26.7.5, the lowest 26 deployed); jar classifier `-kc25`/`-kc26`. The image Dockerfile picks the jar by major.
If the 25 vs 26 SPI forces a code difference, isolate it in one class per profile (`src/kc25`, `src/kc26`); don't fork the module.
- `TenantMapper`: OIDC protocol mapper, user attribute `tenant` -> claim `tenant`. Attached to client scope `tenant`.
- `LoginContextAuthenticator`: no-UI authenticator in custom flow `browser-demo`. Sets auth note
  `login_ctx=<provider version>`. `LoginContextMapper` copies it to claim `login_ctx`. The claim
  proves which provider version handled the login (v1 -> v2 across the patch case).
- `ReplayEventListener`: event listener. For each `LOGOUT` and first-broker-login user creation
  (`IDENTITY_PROVIDER_FIRST_LOGIN` / `REGISTER` with `identity_provider` detail; verify the exact event
  types on 25.0.6 AND 26.7.5 in Slice 3), it writes ONE JSON line to stdout tagged `"replay":true`: `type, time,
  realmId, sessionId, userId`. For creations it also writes `username, email, attributes,
  federatedIdentities`, loaded via the KeycloakSession. Token revocation (`/revoke`): check which event it
  emits; if one exists, replay it as a session delete (conservative superset).
  This is the minor-path replay source.
- `themes/demo`: login theme (`login.ftl`, `logout-confirm.ftl` overrides, CSS) with a visible version
  marker `data-theme-version`.

### Run / test
- Everything: `docker compose up -d` -> Jenkins at :8081, job `kc-bluegreen` (params: `CASE` = patch|minor|major,
  `RUN_MAINTENANCE`; FROM/TO versions come from `cases.env`, one line per case, so they are never typed by hand).
- All three demos without clicking: `docker compose run --rm launcher scripts/demo.sh all`
- 16 GB laptop (2026-11-03): `PROFILE=laptop` on every compose/Jenkins run (2 workers, 2 pods/color, 2 PG instances; scripts/lib/kc.sh)
- Unit: `mvn -f providers verify` (in the jenkins image)
- Static: `shellcheck scripts/*.sh scripts/lib/*.sh`, and `helm template` + `kubeconform` on values
- The real test is the gate (Slice 4). Every path slice is done only when its gate is green in a real run.

## Invariants (all slices)
- caveman + ponytail. Bash only (`set -euo pipefail`). No script over ~150 lines; shared functions go in `scripts/lib/kc.sh`.
- Production realism, not dev mode:
  - `kc.sh start --optimized`, `KC_HOSTNAME=https://kc.localtest.me/keycloak`, hostname strict, `KC_PROXY_HEADERS=xforwarded`, TLS at ingress (CA + cert from `scripts/certs.sh`, openssl).
  - Per pod: requests 1 CPU / 1.5Gi, limit 2Gi. Anti-affinity + topologySpread across zones. PDB `minAvailable: 2` (mirrors prod: 3 AZs, 2 guaranteed replicas).
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
  `k8s/edge/{kc-active.yaml,ingress.yaml}`, `helm/values-common.yaml` (no per-color file: the chart tpl-renders
  extraEnvVars, so the cluster name is `{{ .Release.Name }}`), `scripts/check-cluster.sh`, `scripts/smoke.sh`, `scripts/test-lib.sh`
- **Contract**:
  - `scripts/up.sh`: idempotent. Creates cluster `kc`, installs ingress-nginx, CNPG, certs, `pg-1`, and builds +
    `kind load`s `kc-demo:<ver>-p<provider>`.
  - `scripts/lib/kc.sh deploy_color <color> <version> <db>`: helm upgrade --install with `--wait`.
  - `kc.sh set_active <color>`: patches the `kc-active` selector and writes the `kc-state` ConfigMap.
  - Example: `deploy_color blue 26.7.5 pg-1 && set_active blue` -> `scripts/smoke.sh` (in-cluster, TLS verified against the demo CA) gets `"issuer":"https://kc.localtest.me/keycloak/realms/master"` and an admin token.
- **Tests**: `scripts/check-cluster.sh blue` asserts: 3 Ready pods on 3 distinct zones; the JGroups view
  has size 3 and contains only kc-blue pods (grep pod logs for `ISPN000094`); `kc-state.activeColor=blue`.
- **Regression scope**: none (pure create)
- **Done**: `docker compose up launcher` on a clean box ends with exit 0 and the check passes. A browser on the host reaches the admin console via TLS.
- **Don't touch**: providers/, config/, load/
- **Depends on**: none

## Slice 1b: legacy IdP (Spring Authorization Server)
- **Files**: create `legacy-idp/pom.xml`, `legacy-idp/src/main/java/demo/legacy/{LegacyIdpApplication,SecurityConfig,Users}.java`,
  `legacy-idp/src/main/resources/application.yaml`, `legacy-idp/src/test/java/demo/legacy/*Test.java`,
  `images/legacy-idp/Dockerfile`, `k8s/legacy/{deployment.yaml,ingress.yaml}`; edit `scripts/up.sh` (build, load, apply)
- **DONE 3f81fa8** (two hosts, see "Two networks"; Boot auto-config from application.yaml + users and claims beans).
- **Contract**: issuer follows the host, `https://legacy-netN.localtest.me`. Users `user0001`..`user5000`, password from env
  `LEGACY_USER_PASSWORD`, encoded ONCE at startup and shared by all users. Claim `sub` = username,
  attribute claim `tenant` = `t<n % 10>`. Registered client `keycloak-broker` (confidential, auth code + PKCE,
  redirect `https://kc.localtest.me/keycloak/realms/demo/broker/legacy/endpoint`). Form login, SSO session 8h.
  Use the latest Spring Boot / Spring Authorization Server line; check versions at build.
  Example: `curl https://legacy.localtest.me/.well-known/openid-configuration` -> `"issuer":"https://legacy.localtest.me"`.
- **Tests**: Spring Boot test: auth-code flow for `user0042` yields an id_token with `sub=user0042` and `tenant=t2`.
- **Regression scope**: none (pure create)
- **Done**: tests green; discovery reachable from host and from a pod (CoreDNS rewrite works).
- **Don't touch**: keycloak image, config/
- **Depends on**: 1

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
  `seed-users.sh 4000` -> `GET /admin/realms/demo/users/count` = 4000, each linked to `legacy-net1`.
  A login as `user0042` via `kc_idp_hint=legacy-net1` lands without first-broker-login. The same user via net2 ends up
  as the same user id with 2 federated links. `user4500` goes through creation.
  Keycloak trusts the demo CA for the broker back channel: chart `trustedCertsExistingSecret: demo-ca`.
  Config-cli Job pods carry label `kc-<color>-keycloak-client: "true"` (NetworkPolicy).
- **Regression scope**: Slice 1 check-cluster
- **Done**: bootstrap -> online -> maintenance on blue, all checks green; the bootstrap admin is no longer needed by later stages.
- **Don't touch**: providers/, images/
- **Depends on**: 1, 1b

## Slice 3: provider JAR + theme
- **Files**: create `providers/pom.xml`, `providers/src/main/java/demo/kc/{TenantMapper,LoginContextAuthenticator,
  LoginContextAuthenticatorFactory,LoginContextMapper,ReplayEventListener,ReplayEventListenerFactory}.java`,
  `providers/src/main/resources/META-INF/services/*`, `providers/src/test/java/demo/kc/*Test.java`,
  `themes/demo/login/{theme.properties,login.ftl,logout-confirm.ftl,error.ftl,resources/css/demo.css}`. Edit `images/keycloak/Dockerfile` (COPY jar + theme before `kc.sh build`).
- **Contract**: `PROVIDER_VERSION` (maven property, default `1`) is baked into the authenticator's note value.
  Flows (config lives in Slice 2): `browser-demo` = cookie -> identity-provider-redirector (no default; the client
  passes `kc_idp_hint=legacy-netN` matching the host it is on);
  `post-broker-demo` = `LoginContextAuthenticator` (the IdP's post-broker-login flow). The authenticator
  sets USER SESSION note `login_ctx=v<PROVIDER_VERSION>` (survives refresh); `LoginContextMapper` emits it.
  Example: a broker login with provider v1 -> the access token has `"login_ctx":"v1"` and `"tenant":"t2"` for
  `user0042` (when scope `tenant` is requested).
- **Tests** (JUnit, public behaviour only): mapper with attribute `tenant=acme` -> claim `acme`; no attribute -> no claim.
  The listener turns a LOGOUT event into exactly one JSON line with `replay:true,type,time,realmId,userId,sessionId`;
  a non-replayed event type (e.g. `CODE_TO_TOKEN`) -> no line.
- **Regression scope**: none (pure create); the image rebuild must keep Slice 1's check green.
- **Done**: `mvn -P kc26 verify` green (and `-P kc25` compiles + tests green; it is used from Slice 6b). An image with the jar boots; the claims appear in a manual auth-code login.
- **Don't touch**: config/ (Slice 2 owns it; Slice 3 only names `browser-demo`, `tenant`, `demo` to match)
- **Depends on**: 1 (image); runtime check needs 2

## Slice 4: load + gate
- **Files**: create `load/k6/flows.js`, `k8s/k6-job.yaml.tpl`, `scripts/load.sh`, `scripts/gate.sh`
- **Contract**:
  - k6 scenarios (constant arrival rate, 10 min max, stopped by `load.sh stop`):
    - `login`: full brokered auth-code flow with manual redirects (redirects: 0), each hop logged:
      1. KC `/auth`
      2. legacy `/oauth2/authorize`
      3. legacy login form: GET, think time 0-20 s, POST
      4. KC `/broker/legacy/endpoint`
      5. first-broker-login form if any (auto-submit with the profile prefilled)
      6. `Location` code
      7. KC `/token`

      Each VU picks network net1|net2 (50/50) for its whole session: base `https://kc-netN.localtest.me/keycloak`,
      `kc_idp_hint=legacy-netN`, and `Accept: text/html` on browser hops.
      80% of logins use users 1-4000 (linked), 20% use 4001-5000 (new on first login). Each VU keeps
      its cookie jar, so a re-login after a lost session is silent via the legacy SSO (counted as `relogin`).
    - `refresh`: hold a refresh token, refresh every 5 s. On `invalid_grant`, do a silent re-login and count it.
    - `logout`: RP-initiated logout with `id_token_hint`. KEEP that session's refresh token and probe it every 5 s for the rest of the run (`logout_probe`).
    - `reads`: discovery + JWKS every 1 s.
  - Each request logs one JSON line: `{t_start,t_end,scenario,step,status,login_id,user,sub,claims:{login_ctx,tenant}}`.
  - `gate.sh <path>` reads the k6 lines + `out/events.jsonl` and prints a table. It exits non-zero on any failed rule:
    - **both paths**: every token's `iss` equals `https://kc-netN.localtest.me/keycloak/realms/demo` for the network it was requested on, before and after the switch (issuer stable to the outside world); 0 responses >= 500 or status 0 outside the declared 503 paths/window; reads 0 errors; claims present; per `user`, `sub` never changes over the run (catches lost first-broker-login creations).
    - **shared** (patch case): >= 1 login with a hop before `switch` and the next hop after it, all succeeded; every refresh token issued before `switch` refreshes OK after it; 0 `invalid_grant` in total.
    - **minor (lossy)**: refresh tokens issued before `copy_point` refresh OK after `switch`. `invalid_grant` happens only to sessions created in `[copy_point, switch]`, and each of those re-logins OK. After `replay_done`, every `logout_probe` gets `invalid_grant` (logged out stays logged out). 503 only on `/admin` + `/account` in the window. Prints `lossy_seconds`, `sessions_lost`, `relogins`, `logouts_replayed`, `users_replayed`, `resurrection_seconds` (time between `switch` and `replay_done` during which a logged-out session could still refresh on green; reported, not gated).
  - Example: a synthetic file where one 502 lands 2 s after `switch` -> `gate.sh shared` exit 1, printing that line.
- **Tests**: `scripts/test-gate.sh` feeds synthetic fixtures (`load/fixtures/*.jsonl`) -> expected exits:
  - pass-shared -> 0
  - 5xx -> 1
  - broken in-flight login -> 1
  - pass-lossy -> 0
  - logout probe succeeds after `replay_done` -> 1
  - `sub` changes for a user -> 1
  - `invalid_grant` on a pre-copy-point session -> 1
- **Regression scope**: none
- **Done**: fixtures green. A 5-minute run against blue with no switch -> `gate.sh shared` reports 0 errors (the switch-crossing rule is skipped when there is no `switch` event).
  The load rate is set from this baseline: Keycloak CPU must stay below ~60% of its limit (record rate + CPU in `load/RATE.md`),
  so an overload 5xx cannot pose as a switch failure.
- **Don't touch**: providers/, config/
- **Depends on**: 2, 3

## Slice 5: patch case (shared-DB switch)
- **Files**: create `scripts/switch-shared.sh`, `scripts/demo.sh`, `scripts/reset.sh`, `cases.env`; edit `scripts/lib/kc.sh` (add `drain_color`, `kill_one`)
- **Contract**: `switch-shared.sh <target_version> <provider_version>`; `demo.sh patch` = reset -> bootstrap blue 26.8.0 provider v1 -> load -> `switch-shared.sh 26.8.1 2` -> gate.
  0. Pre-flight: `kc.sh update-compatibility metadata` on the active color, then `check` with the target
     image (`--features=rolling-updates:v2`). A non-zero exit aborts: the change is not shared-DB-safe and must use the lossy path.
  1. Deploy the idle color with the target image on `activeDb`, own cluster-name, `--wait`.
  2. `check-cluster.sh <idle>`: two separate JGroups views exist, each of size 3.
  3. Smoke on the idle color via its internal Service: login and claims show the new `login_ctx`.
  4. `config.sh online <idle>`. Thanks to stateless invalidation, the active color sees the change within 1 s (asserted).
  5. `event switch`, then `set_active <idle>`.
  6. Graceful-delete one pod of each color, wait for Ready again (event `kill`).
  6z. Optional `ZONE_LOSS=1|primary` (reported, NOT gated). `docker stop` one KinD worker mid-switch (event `zone_down`),
      and restart it after 120 s (event `zone_up`).
      - Each color drops to exactly its 2 guaranteed replicas. The replacement stays Pending because topologySpread
        DoNotSchedule + hard anti-affinity forbid doubling up. Assert that, plus PDB `minAvailable: 2` holding.
      - `1` = the worker WITHOUT the CNPG primary: isolates Keycloak's behaviour on zone loss.
      - `primary` = the worker WITH it: adds a CNPG failover.
      - Report 5xx count, window and the pod that answered (edge access log).
      - Not gated: an abruptly lost node kills in-flight non-idempotent POSTs (502), and no edge can hide that.
  7. Keep the old color for `DRAIN_SECONDS=60`, then scale it to 0 (event `drained`).
  8. Optional `RUN_MAINTENANCE=true` (Jenkins boolean param; also accept `1`): freeze -> `config.sh maintenance` -> unfreeze, measured like the minor path.
- **Tests**: `demo.sh patch` -> `gate.sh shared` exit 0. Negative control (run once and record in the README): the same switch WITHOUT `--features=stateless` must fail the in-flight-login rule. This proves the gate can tell the two apart.
- **Regression scope**: Slices 1-4 checks
- **Done**: gate green twice in a row (blue->green, green->blue).
- **Don't touch**: providers/, load/k6 (bugs found there go back to Slice 4)
- **Depends on**: 4

## Slice 6: minor case (per-color DB, lossy overlap + replay)
- **Files**: create `scripts/switch-lossy.sh`, `scripts/replay.sh`, `k8s/postgres/pg-replica.yaml.tpl`,
  `k8s/edge/{kc-maint.yaml,kc-gate.yaml}`; edit `scripts/lib/kc.sh` (`freeze`,
  `unfreeze`, `wait_replica_lsn`, `promote_db`)
- **Contract**: `switch-lossy.sh <target_version>` (shared by minor + major); `demo.sh minor` = reset -> bootstrap blue 26.7.5 -> load -> `switch-lossy.sh 26.8.1` -> `gate.sh lossy`.
  1. Create `pg-<n+1>` as a CNPG replica cluster of `activeDb` (streaming) and wait for it to be streaming.
     `externalClusters` must reference the source's `<db>-replication` (client cert) and `<db>-ca`
     secrets. That's the usual first failure; verify it against the CNPG replica-cluster docs.
  2. Pre-pull and `kind load` the target image (keeps the window short).
  3. `freeze` the lossy paths only, for both realms `demo` + `master`: `/admin`, `/realms/<r>/account`.
     Login, token, logout and broker stay up on blue.
  4. Copy point: sample `pg_current_wal_lsn()` on the primary, `event copy_point`, then wait until the replica's
     `pg_last_wal_replay_lsn() >=` that sample. Not strict equality: blue keeps writing, so equality is never stable.
  5. Promote (`spec.replica.enabled=false`) and wait until the primary is writable. From here, blue's writes are lost unless replayed.
  6. Deploy the idle color on the target version against `pg-<n+1>`: 1 replica first, so the migration runs once
     (record the `DATABASECHANGELOG` count before/after, event `migration`); then scale to 3.
  7. `config.sh maintenance <idle>` (if any), then smoke internally.
  8. `replay.sh <old> <idle> <copy_point - 5s>` (pass 1).
  9. `event switch`, then `set_active <idle>`.
  10. Drain 15 s (in-flight requests on blue finish), then `replay.sh` again with the same start (pass 2) and `event replay_done`.
  11. `unfreeze`, `event window_end`.
  12. Keep the old color + old DB for `ROLLBACK_HOLD=10m`, with no traffic. Rollback = `set_active` back, which loses green's writes since `copy_point` (documented).
- `replay.sh <from> <to> <since>` (its in-cluster calls carry label `kc-<to>-keycloak-client: "true"`):
  - Collect `kubectl logs --since-time` from EVERY `<from>` pod, keeping lines with `"replay":true`. If any `<from>` pod's
    restartCount changed since `<since>`, fail loudly (its logs are gone).
  - Apply on `<to>` via its internal Service as the `config-cli` client:
    - LOGOUT -> `DELETE /admin/realms/demo/sessions/{sessionId}` (404 = fine)
    - user creation = `REGISTER` with detail `identity_provider` (NOT `IDENTITY_PROVIDER_FIRST_LOGIN`, which also fires on
      auto-link; found in Slice 3) -> `partialImport` `{ifResourceExists: SKIP, users:[{id, username, email, attributes, federatedIdentities, enabled:true}]}`
    - `REVOKE_GRANT` (token revocation endpoint): on 26 it carries `sessionId` -> DELETE that session; on **25 it has
      none** (25 revokes the client from ALL the user's sessions) -> replay as `DELETE /users/{userId}/consents/{clientId}`
      plus logging out that user's sessions for the client (conservative superset).
    - The line's `realmId` is the realm UUID, not `demo`.
  - Idempotent: the window start is set early on purpose, and running it twice is a no-op.
  - Prints the counts.
  - Verify early in this slice: `partialImport` keeps the given user `id`. If it does not, the fallback is adding
    `/realms/demo/login-actions/first-broker-login` to the frozen paths for the window (brand-new users get
    ~1 min of 503 instead of a changed `sub`).
- **Tests**: `demo.sh minor` (26.7.5 -> 26.8.1) -> `gate.sh lossy` exit 0. The run prints `lossy_seconds`,
  `sessions_lost`, `relogins`, `logouts_replayed`, `users_replayed`, `resurrection_seconds`. If the changelog
  count does not change, the README says the mechanism ran with a no-op migration.
  `scripts/test-replay.sh`: feed `replay.sh` a fixture log (2 logouts, 1 creation, 1 duplicate) against a running
  color -> sessions deleted, user present with the given id, second run changes nothing.
- **Regression scope**: Slices 1-5
- **Done**: gate green; users 4001-5000 that first logged in during the window keep the same `sub` after the switch; `kc-state.activeDb=pg-2`.
- **Don't touch**: providers/, load/
- **Depends on**: 5 (shares kc.sh)

## Slice 6b: major case (25.0.6 -> 26.8.1)
- **Files**: edit `images/keycloak/Dockerfile` (build arg `KC_MAJOR`; the 25 build line is
  `kc.sh build --db=postgres --health-enabled=true --metrics-enabled=true --http-relative-path=/keycloak --features=persistent-user-sessions`.
  On 25.0.6 `--cache`/`--cache-stack` are RUNTIME options: `kc.sh build` rejects them with exit 2 (found in Slice 3),
  so they go in env (`KC_CACHE=ispn`, `KC_CACHE_STACK=kubernetes`)),
  `providers/pom.xml` (profile `kc25`), `scripts/lib/kc.sh` (`deploy_color` picks `helm/values-kc25.yaml` + config-cli tag by major);
  create `helm/values-kc25.yaml` (env `KEYCLOAK_ADMIN*`, `KC_CACHE_STACK=kubernetes`, `JAVA_OPTS_APPEND=-Djgroups.dns.query=<release>-headless.<ns>.svc.cluster.local`
  pointing at the chart's ispn headless Service, no stateless/cluster-name env); edit `cases.env`
- **Contract**: `demo.sh major` = reset -> bootstrap blue 25.0.6 (provider `-kc25`, config-cli `6.5.1-25`) -> load -> `switch-lossy.sh 26.8.1` -> `gate.sh lossy`.
  Unchanged `switch-lossy.sh`: it must not branch on the major. Version differences live in values, the image and the config-cli tag only.
  Example: `cases.env` line `major FROM=25.0.6 TO=26.8.1`.
- **Tests**:
  - `demo.sh major` -> `gate.sh lossy`.
  - On 25 BEFORE the switch: a session survives a rolling restart of blue (proves `persistent-user-sessions` is really on; otherwise the copy carries no sessions).
  - `config-cli 6.5.1-25` bootstrap + online pass `check-config.sh` on 25.0.6.
- **Cross-major refresh tokens**: the lossy gate requires pre-copy-point sessions to refresh OK on green. If 26
  rejects 25-issued refresh tokens, the gate fails. Do NOT relax the rule silently. Record the raw `invalid_grant`
  response body, report it to the user and decide together (it would mean one silent mass re-login per major
  upgrade: a property of Keycloak, not of this setup).
- **Regression scope**: `demo.sh patch` and `demo.sh minor` still green (shared image/values code)
- **Done**: gate green, or the cross-major token result documented with evidence and a decision.
- **Don't touch**: `scripts/switch-lossy.sh`, `scripts/replay.sh`, load/
- **Depends on**: 6

## Slice 6r: rollback drills (user, 2026-11-03)
- **Files**: `scripts/rollback.sh`, `KEEP_OLD=true` in both switch scripts (old color stays up for the hold),
  `kc-state.previous{Color,Db,Version}` (set_active), cases `patch-rollback` / `minor-rollback` in cases.env,
  gate modes `shared-rollback` / `lossy-rollback` (subagent, branch gate-rollback).
- **shared**: flip back, same DB, nothing lost. Same zero-downtime gate as forward, across BOTH flips.
- **lossy**: back to the old color AND its old DB (old schema; a migrated schema cannot be downgraded). Green's writes
  since the switch are lost, except logouts + user creations, which are reverse-replayed green -> blue before and
  after the flip (else a logout on green resurrects the session on blue, and a user created on green comes back with a
  new id). Admin/account frozen during the rollback window.
- Past the hold, the old color is gone and (lossy) its DB is stale: rollback = fix forward with a new switch.
  rollback.sh refuses when the old color isn't running.
- Events: rollback_start, rollback (the flip), lossy: rollback_window_start, reverse `replay` (from=new),
  rollback_replay_done, rollback_window_end; then drained.

## Slice 7: Jenkins in compose
- **Files**: fill `images/jenkins/Dockerfile` (FROM jenkins/jenkins:lts-jdk21, plugins via
  `jenkins-plugin-cli`: configuration-as-code, job-dsl, workflow-aggregator, git, timestamper; installs docker
  CLI, kind, kubectl, helm, jq, maven), `jenkins/casc.yaml`, `jenkins/jobs.groovy`, `Jenkinsfile`; edit `compose.yaml`
- **Contract**:
  - The pipeline checks out `file:///repo` (`-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true`) and runs on the built-in node. ponytail: no agents; add k8s/docker agents when builds need isolation.
  - Stages: build providers (both profiles) + images for the case's FROM/TO -> `kind load` -> reset -> bootstrap FROM ->
    start load -> switch script for the case -> stop load -> gate -> archive `out/` (gate table, events, k6 summary).
    The pipeline only calls `demo.sh`'s functions; no logic lives in the Jenkinsfile.
  - Example: build with `CASE=patch` -> SUCCESS, with artifact `out/gate.txt` showing 0 errors.
- **Tests**: on a clean box, `docker compose up -d` lets `scripts/demo.sh all --via-jenkins` trigger the 3 builds through the Jenkins REST API. All 3 succeed.
- **Regression scope**: Slices 1-6 via the pipeline
- **Done**: as Tests. Jenkins has no manual setup (JCasC only), and the admin password is generated into a compose secret.
- **Don't touch**: scripts/ logic (Jenkins only orchestrates)
- **Depends on**: 6b

## Slice 8: README + publish
- **Files**: create `README.md` (narrative, architecture diagram, measured results table from a real run, the negative control, known limits), `LICENSE` (Apache-2.0)
- **Done**: README numbers come from a real `out/` and none are invented. Push to a public GitHub repo `keycloak-bluegreen` only after the user confirms.
- **Depends on**: 7

## Parallelism
The live cluster is one shared resource, so every slice that runs the cluster is serial: 1 -> 1b -> 2 -> 4 -> 5 -> 6 -> 6b -> 7 -> 8.
Slice 3's Java + theme work (mvn verify, no cluster) can run in parallel with Slice 2. Slice 1b's Spring app
and tests (no cluster) can run in parallel with Slice 1. The Slice 4
fixtures and `gate.sh` (no cluster) can run in parallel with 2 and 3. Slice 7's Dockerfile/casc can be drafted in parallel with 5 and 6.

## Integration tests (owned by no slice; final review writes + runs)
- Patch case, provider v1 on blue and v2 on green: every login whose broker callback lands after `switch` has `login_ctx=v2`. Logins whose KC `/auth` hop was on blue and whose callback hop was on green also end with `v2` (the auth session continues on green).
- An online config change applied via green is visible on blue within 1 s (stateless invalidation across clusters).
- After the minor path: the user count on green = the count on blue at `switch` (copy + replayed creations, nothing lost), and the same ids.
- Per case: the refresh token from the first login of the warm-up (issued on FROM) still refreshes on TO after the switch (major: see the Slice 6b decision rule).
- `demo.sh all`: the three gates pass in one run with resets in between (no state leaks from one case into the next).
- `kubectl get pods -A`: no pod of either color has a JGroups view containing the other color.

## Known limits (state in README, don't build around)
- Minor/major upgrades are lossy, not lossless. Sessions created in `[copy_point, switch]` are lost (silent re-login via
  legacy SSO). Admin and account-console writes are blocked for the window. Only logouts and first-broker-login creations are replayed.
  Anything else blue writes in the window is dropped by design: IdP-synced attribute updates (re-synced on next login),
  session last-access/refresh state, brute-force counters, events in the DB event store (the stdout copy remains).
- Between `switch` and `replay_done` (~drain time), a session logged out on blue in the window can still refresh on green.
  Measured as `resurrection_seconds`.
- Lossy only works because Keycloak holds no credentials. A realm with local passwords would lose password changes; use a strict freeze there.
- `stateless` is GA since 26.8.0 (preview in 26.7), and it roughly doubles DB load.
- The major demo is 25 -> 26 because 27 does not exist yet. Swap `cases.env` to 26 -> 27 when it ships.
  On 25, sessions survive the copy only because `persistent-user-sessions` (preview in 25) is on from the first start.
  A real 25 deployment that never enabled it would lose ALL online sessions in a major upgrade (silent re-login for everyone).
- Single host: all KinD "zones" are one machine, and clock skew between clusters (stateless needs < 10 s) cannot occur here.
- Legacy IdP is 1 replica with in-memory sessions (stand-in; it is not what's under test).
- Writes on the old color after a rollback flip are lost (no reverse replication).
- Back-/front-channel logout is measured only through the two test apps (testclient-bc/-fc); k6's direct flows cover
  RP-initiated logout + the event listener.
- Replay reads the demo-replay listener's lines from blue's stdout. A crash between commit and println, log rotation
  or a lost node drops lines silently; a container restart or pod recreation inside the window is detected and fails
  the replay, nothing else is. Production: a transactional outbox (same DB transaction) shipped to the new DB.
- After the second replay, blue still runs (drain; `KEEP_OLD` for the rollback hold). Writes that reach it then (only
  pods labelled `kc-blue-keycloak-client=true` can, through blue's own Service) are not replayed.
- Rollback to the old DB: green's session expiry/cleanup is not reverse-replayed, so sessions blue still holds can work
  again after the flip back (`window_sessions_back`).
- The replay window starts at the launcher's wall clock (copy point - 5 s) and is read with kubelet log timestamps:
  one host here; production needs synced clocks or an event-time cursor.
- Upgrade trap (found live, build #13): since Keycloak 26.6, token introspection answers 200 `{"active":false}` unless
  the introspecting client is in the token's `aud` (azp is not enough). A resource server that introspects without an
  Audience mapper works on 25 and silently fails after the upgrade. The demo's test clients carry an Audience mapper
  for `testresource` (config/online/70-test-apps.json); bypass options exist (`allow-token-introspection-without-
  audience-check`, per-client compatibility mode) but the mapper is the correct fix.
- Upgrade trap the other way (found live, build #16): Keycloak 25 ignores IdP JWKS keys without `use`
  (26 accepts them), so a 25 broker needs the IdP to publish `use: sig`. The legacy IdP stand-in does so now.
- In-flight admin/account writes: the freeze waits until the ingress answers 503 on both hosts plus a 2 s settle before
  the copy point, a fixed settle rather than request tracking.
