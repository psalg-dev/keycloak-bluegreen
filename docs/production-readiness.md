# Production readiness: blue/green Keycloak (keycloak-bluegreen)

Status: assessment of the demo at commit `0665ed4` (2026-11-03), updated after the final run (builds #33-#37, all
five cases, every gate PASS) and the 2026-11-03 decisions (security items and three unbuilt PLAN promises accepted;
sections 10 and 13). Web sources checked 2026-11-03.
Scope: what it would take to run this repo's approach in an enterprise environment: managed Kubernetes across 3 AZs,
Bitnami chart, Jenkins, ingress-nginx, keycloak-config-cli, a custom provider JAR, brokering to a legacy Spring
auth server, `hostname-strict=false` behind several ingresses.

> **Two engines.** The DB-specific sections below (notably 4.1, the copy step, backups/PITR and DB metrics) describe
> the default engine, Postgres/CNPG. For `DB_ENGINE=oracle` the route and its production gaps (Data Guard/RAC, RMAN,
> AWR, refreshable PDB clone) are in [oracle/README.md](../oracle/README.md); the app-level findings are the same.

- KinD on one host (zones are labels on one machine, `kind/cluster.yaml`), `kind load` images, no registry.
- Jenkins in compose, running as root with `docker.sock` (`compose.yaml:17-37`).
- A demo CA and random k8s Secrets (`scripts/certs.sh`, `scripts/lib/kc.sh:72-76`).
- CNPG with 2 Gi volumes and no backups; Oracle: one 20 Gi PVC and no backups (`oracle/oracle.yaml.tpl`).
- The replay source was `kubectl logs` of pod stdout until 2026-11-11; now the old color's DB (section 2.3).

**Biggest gaps (ranked)**
1. **The replay source: fixed (2026-11-11).** The replay used to read the event listener's lines from pod stdout
   (silent loss: log rotation, a crash between commit and `println`). It now reads the old color's database and diffs
   it against the new one (`scripts/replay.sh`, section 2.3). Verified live on Postgres and Oracle 19.3.
2. **The DB is the single point of the design** and is under-specified for production. The demo has no backups or
   PITR. The `stateless` requirements apply: synchronous HA replication, commit latency under 10 ms, roughly 2x DB
   load. The replica-and-promote step must be re-engineered for a managed DB (section 4).
3. **The edge is EOL.** ingress-nginx stopped receiving security fixes in March 2026. The Host guard is an nginx
   `server-snippet` (`scripts/up.sh:29-32`) with no 1:1 equivalent elsewhere (section 3).
4. **Change control is partly missing.** The dropped-field check *is* wired now: `config.sh:65` calls
   `check-config.sh <stage> <color>` after every stage, so a field config-cli silently drops fails the run. Still
   missing: images are not digest-pinned or signed, Jenkins plugins are unpinned, and no CI runs the config checks on
   the public repo (GitHub Actions runs the offline gate/report/lib tests only, `.github/workflows/checks.yml`).
5. **Accepted risks (2026-11-03, user decision).** The security findings, the rollback hold, the zone-loss drill and
   the cross-cluster integration tests are accepted as-is or not built; the list with reasons is in section 10 and
   section 13. Nothing here blocks the demo; each stays a production item.

**Go / no-go per mechanism**

| Mechanism | Verdict | Evidence | Condition to flip to GO |
|---|---|---|---|
| Shared-DB switch (patch) | **GO for staging; GO for prod after the platform work in Phase 1-2** | builds #33/#34: `GATE PASS (shared)`, 0 of 29 030 responses >= 500, in-flight logins across the switch with 0 failures, 0 `invalid_grant`, logout probes with 0 refreshed (`README.md` Results). | Same gate on prod-like infra (real AZs, real LB, managed DB) at prod login rate. The negative control (no `stateless`) is still not run (accepted). |
| Lossy overlap + replay (minor/major) | **Demo-verified by a live gate PASS; NO-GO for production** | builds #35-#37: `minor`, `minor-rollback`, `major` all PASS; sessions lost = silent re-logins 4 / 9 / 5; no pre-copy-point session lost, no logged-out session resurrected; 82 / 90 / 68 users replayed (`README.md` Results). | Refresh-token rotation confirmed off in every realm (section 2.3). Offline tokens: not used in the target production (stated 2026-11-11). The platform and DB work of sections 3-4. |
| Rollback, shared DB | **Demo-verified** | build #34 `patch-rollback` PASS: flip back, 0 5xx/network errors, 0 `invalid_grant`, 0 logged-out refreshes. | The same gate on prod-like infra. |
| Rollback, lossy | **Demo-verified; NO-GO for production** | build #36 `minor-rollback` PASS, forward and reverse replay (2 green-born sessions, 30 logouts + 90 users back). | As for lossy, plus a hold shorter than the SSO idle timeout (section 2.4). |
| Rollback window in the default path | **Accepted, not built** (2026-11-03) | No hold timer in the code (`ROLLBACK_HOLD` only in PLAN.md). Without `KEEP_OLD=true` the old color is scaled to 0 after the drain (`switch-shared.sh:51-57`, `switch-lossy.sh:67-70`). | Build the hold when a real deployment needs a post-switch window. |

Also note: the security fixes (`2018bd5`) are verified live now: kc-security #2 (2026-11-03) runs 14 probes on the
hardened cluster, 1 FAIL (trivy: guava CVE in the Keycloak 26.8.1 distribution) and 3 WARN (admin console public, two
ZAP findings). All are accepted, with reasons, in section 10.

**Correction to the brief (verified 2026-11-03).** `stateless` is **no longer a preview feature** on the version
the demo targets. Keycloak 26.8.0 release notes: "multi-cluster v2 and the `stateless` feature are promoted from
preview to supported" ([release notes](https://www.keycloak.org/docs/latest/release_notes/index.html),
[features page](https://www.keycloak.org/server/features): `stateless:v1` under supported, disabled by default).
PLAN.md:105 and PLAN.md:477 ("preview") were true for 26.7.x only. The minor case's FROM version (26.7.5) still
runs it as preview.

---

## 2. Mechanism-by-mechanism readiness

### 2.1 The `stateless` feature

**Facts**
- It moves auth sessions, action tokens and brute-force counters to the DB. Cross-cluster cache invalidation runs
  through a DB outbox polled every 100 ms. The sender waits up to 5x the poll interval, and realm writes may be
  delayed by up to 100 ms. Messages are queued for 60 s.
  ([concepts](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/concepts)). The page warns that
  "this internal implementation might change between minor or patch releases".
- Requirements ([introduction](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/introduction)):
  - an HA DB with synchronous replication
  - commit latency "less than 5 ms is suggested, and below 10 ms is required"
  - NTP; a clock skew over 10 s can drop invalidations
- Cost: DB CPU/IOPS "can increase by roughly a factor of two", plus about 8-10 ms per authentication interaction
  ([26.7 blog](https://www.keycloak.org/2026/07/multi-cluster-v2-and-stateless-mode)).
- Since 26.8.0, brute-force data is persisted in the DB by default (release notes).
- Ephemeral data may use an async commit. On a DB crash, a sub-second window of session data can be lost. Disable
  with `--spi-connections-jpa--quarkus--async-commit=false` (concepts page).
- Docs vs reality: the docs show `--spi-cache-embedded--default--cluster-name`. On 26.8.1 that form is ignored and
  `cache-embedded-cluster-name` is required with `stateless` [verified: wl:slice1-platform, up-1 bisect].
- `stateless` is a build-time option. Turning it off needs a second image (PLAN.md:122-127).

**Support.** On 26.8.x it is supported upstream. Whether a commercial support channel covers it depends on the
build: Red Hat build of Keycloak lags upstream. **Open**: if the team buys support, check that the subscribed
version lists `stateless` as supported. On community Keycloak, "support" means it is no longer expected to change
or vanish without notice.

**Production risks**
- The DB-commit-latency requirement is a hard constraint on where the primary and the sync standby live (section 4.2).
- At 2x DB load, DB sizing from the Keycloak sizing guide must be doubled for the auth-session/brute-force share
  (section 4.5).
- The demo never runs a clock-skew test: KinD is one host (PLAN.md:481).

**Rec**
- Pin `stateless` to 26.8+ in production. Do not run it on 26.7.x.
- Alert on NTP offset (node exporter `node_timex_offset_seconds`) well below 10 s, for example at 1 s.
- Decide explicitly on `async-commit`. Leave it on only if losing in-flight logins on a DB crash is acceptable. That
  is the same failure class as a pod kill.

### 2.2 Shared-DB switch (patch)

**Facts**
- Flow (`scripts/switch-shared.sh`):
  1. Deploy the idle color on the same DB and check isolation (lines 20-23).
  2. Run online config through the idle color (26).
  3. Flip the selector (29-30).
  4. Gracefully kill one pod per color (33-45).
  5. Drain for 60 s and scale the old color to 0 (52-54).
- The guard is "same major.minor" only (line 17). The `kc.sh update-compatibility` pre-flight was dropped: it
  compares the full config, and running it inside a live pod re-augmented the pod's build (wl:slice5-6, INCIDENT).
- The maintenance stage is **not run on this path** (deliberate, accepted): `switch-shared.sh` never calls
  `config.sh maintenance`; only the lossy path does (`switch-lossy.sh:61`, behind `RUN_MAINTENANCE`). A patch release
  should carry only online-stage config (section 7, rec 5).
- The gate passed on the final run (builds #33/#34). The negative control (same switch without `stateless`,
  PLAN.md:342) is not built: no `-nostateless` image exists; accepted (section 10).

**Is the outbox safe under real write rates?**
- Realm/client/role config writes are rare (config-cli runs). The outbox handles them easily. The 100 ms delay per
  realm write is irrelevant for a CI job.
- The open part is **user-entity invalidations**. The IdP configs use sync mode `FORCE`
  (`config/online/30-identity-providers.json`), so every brokered login may rewrite user attributes. If each write
  emits a cross-cluster invalidation, the outbox insert rate scales with the login rate, and each write may wait up
  to 500 ms for consumption. [assumed: Keycloak writes/invalidates on FORCE sync even when values are unchanged; not
  measured in this repo.]
- Outbox correctness depends on clock skew under 10 s and on both colors reaching the same primary. A DB failover
  mid-switch is untested (the zone-loss step 6z in PLAN.md:332-339 is not implemented: no `ZONE_LOSS` in `scripts/`;
  accepted 2026-11-03, section 10).

**Rec**
- Measure, in staging at prod login rate, during a switch:
  - outbox table growth and lag (row count, oldest row age)
  - p99 of admin writes and of the first broker-callback hop
  - DB commit latency
  Gate the switch on outbox lag < 1 s.
- Implement the maintenance freeze on the shared path, or forbid maintenance changes in patch releases (simplest:
  a patch release carries only online-stage config).
- Keep the drain. Make the old color's scale-to-0 conditional on 0 5xx in the edge log for the drain period.

### 2.3 Lossy overlap + replay (minor/major)

**Facts** (`scripts/switch-lossy.sh`)
1. Create a CNPG replica cluster of the active DB (lines 18-20).
2. Freeze `/admin` and the account console only (24).
3. Sample `pg_current_wal_lsn()` on the primary and wait for replay to reach it, by `>=`, never equality (28-34).
4. Promote (37-40).
5. Green migrates its copy, with changeset counts recorded (45-48).
6. Online config (+ maintenance) on green (52-53).
7. Replay (56), switch (57-58), drain 15 s (59), replay again (60), unfreeze (65).

Blue serves login/token throughout.

**Assumptions that hold only in the demo**
- *Users hold no credentials in Keycloak.* A lost write costs one silent redirect through the legacy SSO
  (PLAN.md:24-29). The user's production has the same property (brokering), so this holds. It does not hold for any
  realm with local passwords, OTP or WebAuthn registrations (PLAN.md:476).
- *Only logout, REVOKE_GRANT and brokered creation matter.* Other writes in `[copy_point, switch]` are lost by
  design. In production that list is longer:

| Write in the window | Effect on green | Silent? | Notes |
|---|---|---|---|
| New browser SSO session | Lost; re-login via legacy SSO | Yes, if the legacy SSO session is alive | Gate rule `invalid_grant_in_window` |
| **Offline session / offline token** (mobile, native, `offline_access`) | Lost; `invalid_grant` on green | **No**: the app re-prompts the user | Not replayed. **Open**: do RPs request `offline_access`? |
| Refresh of a pre-copy session, realm with **refresh-token rotation** (`revokeRefreshToken=true`) | Green's client session still expects the pre-copy token id; the newer token from blue is "stale" -> `invalid_grant` | No | [assumed from Keycloak's token-reuse check; not tested: demo realms leave rotation off]. If prod uses rotation, every session refreshed during the window breaks. **Must test.** |
| Consent grant/update | Lost; user re-prompted | No (one extra click) | |
| Required actions during login (T&C, VERIFY_PROFILE, review profile) | Lost; asked again | No | |
| Brute-force counters (DB-backed since 26.8) | Reset at switch | Yes | An attacker gains up to `failureFactor` extra attempts once per upgrade. N/A for brokered-only realms |
| IdP-synced attributes (sync `FORCE`) | Lost; re-synced on next login | Yes | |
| Admin changes | Blocked at the edge (503) | n/a | **Not blocked** for in-cluster clients that hit a color's Service directly (labelled pods, automation, operators) |
| Events in the DB event store | Lost; stdout copy remains | Yes | Realms do not set `eventsEnabled`, so nothing is stored anyway |
| Admin-initiated / backchannel logouts | Admin is frozen. Backchannel logout from the upstream IdP: **Open** whether it emits a `LOGOUT` user event | ? | PLAN.md:484: no backchannel receiver |

**Replay source: the old color's database (since 2026-11-11)**

`replay.sh <from> <to> <from-db> <to-db> <limit>` no longer reads events. Blue's DB stays readable after the promote,
and what blue committed is in it, whatever happened to its pods:
- **Users**: ids in `user_entity` on `<from>` that `<to>` does not have -> fetched from `<from>` (user, federated
  links, realm roles, groups) and imported with the same id.
- **Sessions**: a session `<to>` holds from the copy (created before `limit`, a moment after the copy and before the
  new color existed) is deleted when `<from>` no longer has it (logout) or no longer has one of its client sessions
  (token revocation removes only that row: measured on 26.8.1; the whole session goes, as before).
- **Fails closed** (`replay_session_diff`, `scripts/lib/kc.sh`, tested in `scripts/test-lib.sh`): an empty source
  listing, or a delete set over 50 % of the copied sessions, stops the replay instead of logging everyone out.

What this closes, of the old stdout source's loss paths: log rotation, pod replacement, commit-then-crash (there is no
second write any more), and the silent precondition (no listener to be missing from the realm config). Errors were
already no longer swallowed (`apply`: 2xx or 404, else fail).

Evidence (Postgres, builds #21-#24 on `3d8c8d6`): `minor`, `major`, `minor-rollback` gates PASS. On `major` (old color
25.0.6), 0 of the 61 sessions the listener saw logged out on blue remained in green's DB. Build #24 ran with planted
sessions: logout on blue in the window, token revocation on blue in the window (two clients), logout on green, token
revocation on green (two clients), one control; 15 of 15 checks (refresh result and DB row, after the forward replay
and after the rollback) as expected.

Evidence (Oracle 19.3, builds #26-#27 on `6eda4a5`): `minor-rollback` and `major` gates PASS; #26 ran with the same
planted sessions, 15 of 15 checks as expected. Build #28 (`d2a42a3`, the faster pass below): `minor-rollback` PASS,
15 of 15 again. Postgres `minor` #25 (`4eb2fc3`) re-ran after the service-account and
`enabled`/`emailVerified` changes: PASS, 38 users replayed.

What stays open:
- **Cost of a pass** (measured, builds #26 and #28, Oracle `minor-rollback`): first written with three reads per
  database and one import per user, a pass took 37 s for 58 new users (six `sqlplus` sessions at 1.1 s, and every
  admin call re-fetching its token), and the lossy window grew to 180-187 s. Now one tagged read per database, in
  parallel, one `partialImport` per 200 users and one token per color: 5 s for 53 users and 5 sessions forward, 5 s for
  65 users on the rollback. Lossy window 128 s, lossy rollback 41 s: back to what the log replay had (124-142 s, 40 s).
  Postgres `minor-rollback` #30 (`428fe77`, planted sessions 15 of 15): lossy window 105 s, lossy rollback 20 s. The
  rollback's cost had been the purge (64 s for 287 sessions in #29; 22-26 s in earlier runs). Every admin call
  fetched a new token, which is fixed (one per port-forward, renewed after 30 s: 7 s for 223 sessions); why #29 took
  64 s rather than the usual 22-26 s is not explained. `428fe77` has not run on
  Oracle (the change is in the shared admin helper, not in engine code).
- **A late forward run logs live users out.** Once blue is idle its sessions expire on their idle timeout while they
  live on on green; the diff would read that as logouts. `replay.sh` refuses a forward run more than
  `REPLAY_MAX_AGE` (1800 s) after the copy. Set it below the realm's SSO idle timeout.
- **The listener** (`ReplayEventListener`) still ships and still prints; nothing reads it. Remove it, or keep it as an audit trail.
- **The repair of a post-flip duplicate through the batched import has not occurred in a run** since the batching
  (0 repairs in #28-#30). The response it relies on was read live (26.7.5), and a skip it cannot name fails the replay.
- k6 barely exercises the session diff (3-4 sessions forward, 0 on the rollback per run): the planted-session check
  was a one-off manual script (not in the repo), not part of the gate.
- Token revocation with two clients was measured on 26.8.1 only, not on 26.7.5 or 25.0.6 as the old color.
- Service-account users are not replayed (clients are not either).
- Only realm `demo` is replayed. Offline sessions (`offline_flag = 1`) are not.

**Window length on a large DB**
- The *lossy window* is `copy_point -> switch`. It contains:
  - promote (seconds)
  - green's first start with the schema migration
  - scale to 3 pods
  - check-cluster
  - config-cli online (+ maintenance)
  - replay pass 1
- The pg_basebackup itself runs *before* the freeze (`switch-lossy.sh:18-19`), so DB size does not lengthen the
  window. It lengthens the preparation.
- What grows with data size is the **Liquibase migration**. Keycloak migrations sometimes rewrite large tables (user
  attributes, sessions, events). A minor upgrade on a DB with millions of users or offline sessions can run for many
  minutes.
- **Rec**: in staging, restore a prod-sized copy and time `deploy_color` on it (the `migration` event already records
  the changeset counts, `switch-lossy.sh:48`). Budget the window from that measurement. Consider Keycloak's manual
  migration strategy to pre-run the SQL on the promoted copy before green starts.

**Rec (verdict)**: before any production use:
- ~~a live minor gate PASS and a major gate PASS~~ **done 2026-11-03** (builds #35, #37)
- ~~the cross-major refresh-token result recorded (PLAN.md:411-414 decision rule)~~ **done** (build #37)
- ~~the durable sink~~ **done on Postgres 2026-11-11** (DB diff, above); Oracle run open
- offline tokens: not used in the target production (stated 2026-11-11); refresh-token rotation: believed off, to be
  confirmed per realm (`revokeRefreshToken`)

If refresh-token rotation is on in prod, consider the strict write-freeze variant (PLAN.md:30, designed, not
built) instead of lossy. A short 503 on login/token is honest. A wave of `invalid_grant` is not.

### 2.4 Rollback

**Facts** (`scripts/rollback.sh`)
- Shared DB: flip back, nothing lost (lines 19-21).
- Lossy: back to the old color *and* the old DB (a migrated schema cannot be downgraded). Green's logouts and
  creations are reverse-replayed. Everything else green wrote since the switch is lost (lines 22-35).
- It refuses when the old color has fewer than 2 Ready pods (line 16). Past that point: fix forward.
- **There is no hold in the code, and that is accepted (2026-11-03).** PLAN.md:102 and PLAN.md:368 describe
  `ROLLBACK_HOLD` (10 min in Jenkins), but no script reads it (`grep ROLLBACK_HOLD scripts/`: no hits).
  - Default path: the old color is scaled to 0 right after the drain, 60 s shared (`switch-shared.sh:51-57`) or 15 s
    lossy (`switch-lossy.sh:59,70`). After that, `rollback.sh` refuses: the default path has **no rollback window**.
  - With `KEEP_OLD=true` (`switch-shared.sh:51-52`, `switch-lossy.sh:67-69`; only the `*-rollback` drill cases set
    it, `scripts/demo.sh:79-80`), the old color stays up until someone runs `rollback.sh`. Nothing scales it down.
- **Decision**: accepted, not built. A deployment that needs a window uses `KEEP_OLD=true` and treats the scale-down
  as its own logged runbook step; the demo's default path deliberately has no window, and the drill cases hold the
  old color explicitly.

**Data-loss semantics in production (lossy rollback)**
- Everything in the table in 2.3 applies again, now for the whole hold period, not a minute-long window.
- **Stale session state.** Sessions refreshed on green during the hold have an old `lastSessionRefresh` in blue's
  DB. If the hold exceeds the realm's SSO idle timeout, those sessions are expired on rollback (wl:gate-rollback:
  "assume blue's stale lastSessionRefresh stays inside SSO idle timeout [assumed]"). The demo uses 2 h idle
  (`config/bootstrap/10-demo-realm.json:4`). Production realms often use 30 min.
- The reverse replay reads green's DB the same way (section 2.3).

**Rec**
- Hold period = min(time to detect a bad release from SLOs, SSO idle timeout - margin). In practice 15-30 min.
- Treat lossy rollback as a break-glass action with a named owner, not an automated SLO reaction. Automate only
  the shared-DB flip-back.
- Keep the old DB (stopped, not deleted) for days as a forensic copy. `switch-lossy.sh:63-64` already keeps it
  ("last-resort copy"). Add a retention rule.

---

## 3. Platform

### 3.1 Managed Kubernetes (3 AZs) vs KinD

| Aspect | Demo | Production | Transfers? |
|---|---|---|---|
| Zones | Labels `a/b/c` on 3 KinD workers on one host (`kind/cluster.yaml:13-24`) | Real `topology.kubernetes.io/zone` from the cloud | Yes, values unchanged |
| Spread | Hard anti-affinity + topologySpread `DoNotSchedule` (`helm/values-common.yaml:73-80`) | Same | Yes. With 3 replicas and 3 zones, a zone loss leaves the 3rd pod Pending by design (PLAN.md:334-335) |
| PDB | `minAvailable: 2` | Same | Yes. It covers node drains, not the deletes in the demo |
| Node capacity during a switch | 6 Keycloak pods (2 colors) + 2 DBs on a lossy switch | Must fit 2x Keycloak **per zone** | Rec: reserve per-zone headroom for a second color, or use a node pool with surge capacity |
| Images | `kind load`, `pullPolicy: Never` | Registry pull | Change (section 5) |
| Clock | One host | NTP per node; `stateless` needs skew < 10 s | New monitoring |

### 3.2 Real load balancers and the selector flip

- **Fact**: the flip patches the selector of `kc-active` (`scripts/lib/kc.sh:107-108`). ingress-nginx watches the
  EndpointSlices and swaps upstreams without a reload (`k8s/edge/kc-active.yaml:1-2`). The cloud LB (in front of the
  ingress controller) is not involved, so the flip is fast and local.
- **Measured lag**: after a flip from *zero* endpoints the first request about 1 s later failed and the retry
  passed. This is ingress endpoint propagation; a blue->green flip keeps old endpoints serving meanwhile
  (wl:slice1-platform).
- **When the cloud LB targets pods directly** (GKE container-native NEGs, AWS ALB IP mode):
  - The selector change becomes an endpoint-programming operation in the cloud LB, plus health-check convergence.
  - GKE gates pod readiness on NEG programming ("The NEG controller will mark the Pod's readiness gate value to
    True when its corresponding endpoint is programmed in NEG",
    [GKE docs](https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing)).
  - That gate protects rollouts, not a selector flip. Old endpoints are deregistered when the selector moves, while
    new ones may not be healthy in the LB yet.
  - [assumed: no measured numbers for selector-flip convergence on NEGs/ALB; the docs give none.]
- **Rec**:
  - Keep an in-cluster proxy layer (ingress controller or Gateway data plane) as the cloud LB's target, so the flip
    stays an in-cluster EndpointSlice change.
  - If pods must be LB targets, use two Services/target groups and switch at the LB (weighted) instead of
    flipping a selector.
  - Use Keycloak's `/lb-check` for site-level LB health, not `/health/ready`
    ([concepts](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/concepts)).
- **Multiple ingresses** (prod has more than one): each must route to the same `kc-active` Service, or the flip
  must be applied per ingress. **Open**: do all ingress classes in prod point at one Service?

### 3.3 ingress-nginx EOL and migration

- **Fact**: "In March 2026, Ingress NGINX maintenance will be halted" with "no further releases ... no bugfixes ...
  no updates to resolve any security vulnerabilities"
  ([kubernetes.io blog, 2025-11-11](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)).
  - The blog names snippet annotations as "serious security flaws".
  - The demo pins `controller-v1.15.1`, the final release (`scripts/up.sh:9`).
  - ingress2gateway 1.0 shipped 2026-03-20 (secondary sources, e.g.
    [collabnix](https://collabnix.com/ingress-nginx-is-retired-a-hands-on-migration-to-gateway-api-with-ingress2gateway-1-0/)).
- **Does the switch carry over?** Yes. An `HTTPRoute` with `backendRefs: [{name: kc-active}]` keeps the selector
  flip unchanged. Gateway API adds a second option: weighted `backendRefs` to `kc-blue-keycloak` /
  `kc-green-keycloak`, which gives canary steps (1% -> 10% -> 100%) as a native feature. The freeze also maps
  directly: a longer path match in an HTTPRoute to the `kc-maint` Service.
- **Implementation choice** (Gateway API v1.6 conformance per
  [implementations page](https://gateway-api.sigs.k8s.io/implementations/), checked 2026-11-03):

| Implementation | v1.6 status | Fit for this team |
|---|---|---|
| NGINX Gateway Fabric | Conformant | Closest to current nginx behaviour; supported by ingress2gateway |
| Envoy Gateway | Conformant | Strong default for a shared edge; rich policy CRDs (rate limit, ext auth) |
| Cilium | Conformant | If Cilium is already the CNI |
| Istio | Conformant | Only if a mesh is wanted anyway |
| Traefik, Kong | Conformant | If already in the org |
| GKE Gateway | Conformant | Managed, cloud LB is the data plane: see 3.2 |
| AWS LB Controller | Partially conformant | Same caveat as 3.2 |

- **Rec**: migrate the edge as a separate project *before* productionizing the switch, so the switch is not tied to
  an EOL component. The selector-flip design means the switch scripts barely change. The edge hardening must be
  redone (3.4).

### 3.4 The Host guard elsewhere

**What it does today.**
- A controller-wide `server-snippet: if ($http_host != $host) { return 421; }` (`scripts/up.sh:29-32`). Any Host
  that is not the exact lower-case host without port or trailing dot gets 421 before routing.
- Plus `proxy-set-headers` that blank `Forwarded`, `X-Forwarded-Prefix/-Ssl/-Server`, `X-Original-Host`, `X-Host`
  (`k8s/edge/ingress-nginx.yaml:11-22`).
- Root cause: nginx forwards the *raw* Host as X-Forwarded-Host (wl:security-fixes, section 1).

**Equivalent goals on any edge (the test is `scripts/security/probe-issuer.sh`, not the config):**
1. X-Forwarded-Host sent to Keycloak equals one of the canonical hosts, byte for byte, or the request is rejected.
2. Client-supplied `Forwarded`/`X-Forwarded-*` never reach Keycloak.

- On Envoy-based gateways: Host normalization and header removal are route/listener filters (`requestHeaderModifier`
  can remove headers). Rejecting non-canonical Host needs an implementation-specific policy.
- **Open**: verify per implementation that the probe passes; do not assume.

**Defense in depth inside Keycloak** (not used by the demo; grep for `trusted` finds nothing in values):
`proxy-trusted-addresses` restricts which peers' proxy headers are honoured. "By default all addresses are trusted"
([reverse proxy guide](https://www.keycloak.org/server/reverseproxy)). Set it to the gateway data-plane pod CIDR
or IPs. The guide calls it weak alone (IPs can be spoofed), so it complements the NetworkPolicy and does not replace it.

---

## 4. Database

### 4.1 Managed Postgres vs CNPG in-cluster

| | CNPG in-cluster (demo) | Managed (Aurora/RDS/Cloud SQL/Azure Flexible) |
|---|---|---|
| Sync replication across AZs | Postgres baseline used `synchronous: any 1, dataDurability: required` (`k8s/postgres/pg.yaml.tpl`, historical); the Oracle demo uses one instance and no Data Guard | Aurora: storage-level quorum across 3 AZs. RDS Multi-AZ: synchronous standby |
| Replica-and-promote copy for the lossy path | Native (replica cluster + `replica.enabled=false`) | Not the same primitive: see 4.4 |
| Backups/PITR | **None configured** | Built in |
| Team skills | Requires Postgres-on-k8s operations (operator upgrades, PVC/storage, failover drills) | DBA/cloud team |
| Commit latency | You control placement | Vendor-defined; measure |

**Rec**: if the org already runs managed Postgres, use it and rebuild the copy step (4.4). Keep CNPG only if there
is an existing CNPG practice. The demo's CNPG work (the replica cluster recipe, the `delete_dbs` GC race,
wl:slice5-6) is valuable but specific.

### 4.2 Synchronous replication across AZs and the latency budget

- Keycloak requires commit latency under 10 ms (5 ms suggested). Synchronous commit to another AZ adds one
  inter-AZ RTT per commit (typically about 1-2 ms within a region on major clouds [assumed: provider-typical, not
  measured here]).
- `stateless` adds DB round-trips per login (+8-10 ms per auth interaction, 2.1).
- `dataDurability: required` with `ANY 1` blocks writes if no standby is reachable. That is the right choice for
  Keycloak's consistency model ("consistency over availability", concepts page). It means losing 2 of 3 DB zones
  stops writes, i.e. stops logins.
- **Rec**:
  - Measure p99 commit latency in staging under the gate's load and alert at 5 ms.
  - Keep primary and Keycloak pods in the same region.
  - Multi-cluster v2 is single-region by design (26.7 blog: "Single-region only").

### 4.3 Backups, PITR, restore drills

- **Fact**: no `backup`/`plugins` section in either CNPG template.
- CNPG 1.30 still ships in-tree Barman Cloud but "will now be removed in CloudNativePG 1.31.0"
  ([1.30 release notes](https://cloudnative-pg.io/docs/1.30/release_notes/v1.30/), 1.30.1 released 2026-09-23).
  The forward path is the Barman Cloud Plugin (CNPG-I), with object-storage base backups + WAL archive and PITR
  ([plugin docs](https://cloudnative-pg.io/plugin-barman-cloud/)). Volume snapshots are the other option.
- **Rec**:
  - Plugin-based backups to object storage in another failure domain. WAL archiving on.
  - A scheduled base backup, and retention at least as long as the longest offline-token lifetime the business
    cares about.
  - **Quarterly restore drill**: restore to a new cluster, start a Keycloak color against it, run `check-config.sh`
    and a login smoke. The lossy switch is itself a "restore from replica" exercise, so wire the drill into staging
    runs.
  - Snapshot the DB immediately before every minor/major switch (cheap insurance against a failed migration).

### 4.4 The copy step against a managed DB

The demo's model is **clone, then diverge**: copy at an LSN, promote, let the new Keycloak migrate the copy, never
sync back (`switch-lossy.sh:28-40`).

| Option | Matches "clone then diverge"? | Notes |
|---|---|---|
| **Aurora fast clone** (copy-on-write) | **Yes** | Clone time is the copy point; no streaming catch-up step. Minutes even for large volumes (Lyft reports 30 TB in about 20 min, [secondary](https://eng.lyft.com/postgres-aurora-db-major-version-upgrade-with-minimal-downtime-4e26178f07a0); [AWS blog](https://aws.amazon.com/blogs/database/amazon-aurora-postgresql-blue-green-deployment-using-fast-database-cloning)). Record the clone's timestamp/LSN as `copy_point` |
| Snapshot restore (RDS, Cloud SQL, Azure) | Yes, slow | Restore time sits *before* the window if you snapshot before freezing; the copy point is then the snapshot time, so the replay window grows by the restore duration. Acceptable only with the durable outbox replay |
| Read replica + promote (RDS, Cloud SQL) | Yes | Closest to the CNPG recipe: catch up, record the LSN/timestamp, promote |
| **RDS Blue/Green deployments** | **No** | Keeps green in sync via logical replication and blocks switchover on DDL on blue; green is meant to stay a replica until switchover ([AWS considerations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-considerations.html)). Keycloak's Liquibase migration on green is DDL that breaks the replication. RDS B/G is for **Postgres engine** upgrades, not Keycloak schema upgrades. Do not confuse the two |
| Logical replication blue->green | No | Schema differs after migration; the earlier `research_keycloak_bluegreen*` work (wl:research-design-questions) reached the same conclusion for CDC |

**Rec**: on Aurora, implement `copy_point` as a fast clone; on RDS, as replica + promote. In both cases, read the
replay outbox from the *old* DB, which stays writable and readable.

### 4.5 Connection pooling and DB sizing

- **Fact**: `KC_DB_POOL_MAX_SIZE=30` per pod, `max_connections 300`. 6 pods x 30 = 180 worst case with both colors
  on one DB (`helm/values-common.yaml:53-54`; ai-memory 0061a8a7).
- Sizing guide ([Keycloak](https://www.keycloak.org/high-availability/single-cluster/concepts-memory-and-cpu-sizing)):
  - 0.35-0.7 vCPU per 100 login/logout/refresh per second
  - 1400 write IOPS per 100 of those per second
  - double the auth-session share for `stateless` (2.1)
- **Rec**:
  - Size `max_connections` for **two full colors** plus config-cli, replay and monitoring.
  - Keep the per-pod pool fixed (min = max) to avoid connection storms on a switch.
  - A transaction-mode PgBouncer in front of Keycloak is not recommended without testing (Keycloak relies on
    session-level JDBC behaviour in places) [assumed]. Prefer right-sized pools.

---

## 5. Supply chain and images

### 5.1 Chart and image

**Facts**
- Bitnami chart 25.2.0 is frozen at appVersion 26.3.3 (wl:research-design-questions, chart pulled 2026-11-02).
- The demo runs the official `quay.io/keycloak/keycloak` image re-laid into `/opt/bitnami/keycloak`, with a
  `liblog.sh` stub (`images/keycloak/Dockerfile:27-31`, `images/keycloak/liblog.sh`). It needs
  `allowInsecureImages: true` plus overrides for command/args/probes (`helm/values-common.yaml:3-15,85-102`) and an
  extra init container because the chart's own init container does not copy `conf/` (`values-common.yaml:58-66`).
- Broadcom moved the public Bitnami images to `bitnamilegacy` (no updates) from late August 2025. Hardened
  "Bitnami Secure Images" are paid. The chart sources remain Apache-2.0 on GitHub
  ([bitnami/containers#83267](https://github.com/bitnami/containers/issues/83267),
  [bare.id, secondary](https://www.bare.id/en/blog/bitnami-umstellung-was-keycloak-nutzer-jetzt-wissen-und-tun-mussen)).

**Options**

| Option | Effort | Pros | Cons |
|---|---|---|---|
| Keep Bitnami chart 25.2.0 + own image (demo) | S | Matches today's prod | Frozen chart; every Keycloak change that touches chart assumptions needs a workaround; a re-layout hack in the image |
| Fork the Bitnami chart (Apache-2.0) and own it | M | Same values shape as prod; can drop the `/opt/bitnami` coupling | You maintain it |
| codecentric `keycloakx` | M | Built for the official image; actively released (the latest release the search surfaced was 7.2.2 with Keycloak 26.6.4, [release](https://github.com/codecentric/helm-charts/releases/tag/keycloakx-7.2.2); verify on the releases page) | Values migration; lags Keycloak releases |
| Own minimal chart (StatefulSet, 2 Services, PDB, NetPol) | M | Smallest surface; the demo already overrides most of the chart | You maintain it |
| Bitnami Secure Images (paid) | S (money) | Continuity with the Bitnami layout | Vendor lock-in; the demo's whole point is the official image |

**Keycloak Operator (the team does not use it).** What it would give anyway:
- A `Keycloak` CR that owns the StatefulSet, Services and Ingress.
- The `Auto` update strategy, which runs a feasibility Job and does a rolling update when the version is the same or
  a newer patch in the same major.minor ([operator rolling updates](https://www.keycloak.org/operator/rolling-updates)).
- Pod-name node names (26.8).
- `KeycloakRealmImport` for one-shot realm imports.

It does **not** give blue/green across minors, a lossy-window replay, or config-cli-style incremental config. For
patches, the Operator's rolling update would replace the shared-DB switch with less machinery. For minors/majors
the team would still need this repo's approach.

### 5.2 Registry, pinning, signing, SBOM, admission

**Facts**
- Base images are pinned by tag:
  - `quay.io/keycloak/keycloak:${KC_VERSION}`
  - `maven:3.9.16-eclipse-temurin-25` (`images/keycloak/Dockerfile:7,20`)
  - `nginxinc/nginx-unprivileged:1.31.7-alpine` (`k8s/edge/kc-maint.yaml:32`)
  - `adorsys/keycloak-config-cli:6.5.1-*` (`scripts/lib/kc.sh:118`)
  The digest shows in build logs (`out/jenkins-run.log`) but is not pinned in files.
- Only the KinD node image and testssl are digest-pinned (`kind/cluster.yaml:6`, `security/tools.env:9`).
- Tool binaries (kind, kubectl, helm) are downloaded with curl and no checksum (`images/*/Dockerfile`).
- The image tag `-p<provider>` is reused across rebuilds. A rebuilt tag does not roll pods (wl:slice1-platform),
  and the image ID changed under an unchanged tag [unexplained, wl:slice1b-2].
- trivy: `guava 33.6.0-jre CVE-2026-102554 HIGH (fix 33.7.2)` inside Keycloak's own libs (wl:security-pipelines).
  You cannot fix that without patching Keycloak. Track the upstream release and record a time-boxed exception.

**Rec**
- Push to the org registry. Tag = Keycloak version + provider git SHA, immutable tags.
- Deploy by **digest** (`image.digest` in the chart).
- Sign with cosign in the Jenkins build and generate an SBOM (syft or trivy `--format cyclonedx`).
- Enforce with an admission policy (Kyverno `verifyImages` or Sigstore policy-controller): only signed images from
  the org registry in namespace `keycloak`.
- Verify checksums of downloaded binaries.
- Run the trivy probe on every image build and keep a CVE exception file with an expiry, like `kcwarden-ignore.yaml`.
- **Open**: whether `quay.io/keycloak` images are signed upstream (not checked).

### 5.3 Jenkins plugins

- **Fact**: `jenkins-plugin-cli --plugins configuration-as-code job-dsl workflow-aggregator git timestamper junit
  pipeline-graph-view` with no versions (`images/jenkins/Dockerfile:34`; wl:slice7-jenkins, "Plugins unpinned").
- **Rec**: not relevant if the org Jenkins is used (section 8). If this image survives anywhere, pin with a
  `plugins.txt` (`name:version`) and rebuild on purpose.

---

## 6. Secrets and identity

| Secret | Demo | Production rec | Rotation notes |
|---|---|---|---|
| `kc-bootstrap-admin` (temp-admin) | random, k8s Secret, kept forever (`scripts/up.sh:52`, `values-common.yaml:17-20`) | Use only for bootstrap; delete the `temp-admin` user once `config-cli` exists; break-glass via a sealed, audited procedure (below) | One-time |
| `kc-config-cli` client secret | random, k8s Secret; the client has realm role `admin` in master (`config/bootstrap/00-master-config-cli.json:11-27`) | External Secrets Operator (or Vault Agent) from Vault/cloud secret manager; **least privilege**: realm-management roles on the managed realms, not master `admin` | **Chicken-and-egg**: `config.sh` authenticates with `KEYCLOAK_CLIENTSECRET` and sets the client's secret from `KC_CONFIG_CLI_SECRET`, both from the **same** Secret (`scripts/config.sh:25-26,52`). Rotate in two phases: (1) run online with old auth + new value, (2) switch the auth Secret. Or switch config-cli to `private_key_jwt` and rotate keys instead |
| `legacy-broker` (IdP client secret) | copied from ns `legacy` at `up` (`scripts/up.sh:60-62`) | One source of truth (secret manager) synced to both the legacy IdP and Keycloak | The legacy IdP must accept old and new secrets during the overlap; Keycloak IdP config gets the new one via the online stage |
| DB credentials | CNPG-generated `<db>-app`, copied to the new DB (`switch-lossy.sh:43-44`) | Managed DB IAM auth or secret manager with rotation | Keycloak reads the DB password at start: rotation = rolling restart, or dual users |
| Realm signing keys | in the DB; shared by both colors (shared DB) or copied (lossy) | Keep in DB; use Keycloak's key rotation (add new active key, keep old passive until the max token lifetime passes, then disable) | Works across colors because keys live in the DB, not in the image. Never rotate during a lossy window (admin is frozen anyway); the copy carries the key set |
| TLS (demo CA) | openssl CA (`scripts/certs.sh`), leaf for `*.localtest.me` | cert-manager with the org PKI or ACME for public hosts; trust bundle via trust-manager for the broker back channel (`trustedCertsExistingSecret`) | wl:security-fixes "Apply hazards": a CA change needs a Keycloak restart (truststore read at start) |

**Break-glass.**
- Keep one emergency admin path that does not depend on config-cli: Keycloak's `kc.sh bootstrap-admin` against a
  stopped color, or a sealed-envelope user in master with OTP. Store it in the secret manager under dual control.
- Never run `kc.sh` subcommands inside a live pod (wl:slice5-6 INCIDENT: it re-augmented the build into the pod's
  writable dir).

---

## 7. Configuration management

**Facts**
- Three stages, config as JSON (`config/{bootstrap,online,maintenance}`), one Job per run (`scripts/config.sh`).
  Online sets `no-delete` for every managed type (`config.sh:28-32`).
- **Checksums per file**: with the default, files of the same realm overwrite each other's checksum, so every run
  rewrote the realm (16 UPDATE admin events per no-op run). `IMPORT_BEHAVIORS_CHECKSUMWITHCACHEKEY=false` fixed it
  [verified: 4076 -> 4076 admin events on re-run] (wl:slice1b-2; `config.sh:49-51`). This matters on a shared DB:
  every rewrite is a cross-cluster invalidation under traffic.
- **`userProfileEnabled` gotcha**: config-cli 6.5.1 silently skips `userProfile` unless the realm attribute
  `userProfileEnabled: true` is set [verified] (wl:slice1b-2; `config/online/10-user-profile.json:4`).
- **Version skew**: config-cli for 26 is built against Keycloak 26.5.5 (`scripts/lib/kc.sh:118`) and runs against
  26.8.1. Fields it does not know are dropped silently (PLAN.md:128-130).
- **The dropped-field check is a gate.** `scripts/check-config.sh` caught the userProfile bug, and `config.sh:65` runs
  it after every stage (`check-config.sh <stage> <color>`, straight to the color's own Service), so a field
  config-cli silently drops fails the run. The pipeline inherits it through `config.sh`.

**Rec**
1. **Done**: `check-config.sh` runs after every `config.sh` stage (`config.sh:65`). The remaining piece is a
   negative-control fixture that proves it fails on a dropped field (the slice6b worklog shows one); not built,
   accepted.
2. **Change process**: config PRs reviewed like code. CI runs, against an ephemeral Keycloak of the *target*
   version:
   - config-cli `import.validate`
   - the dropped-field check
   - kcwarden
   - a diff of the realm export before/after
   Production apply only from the main branch, with an approval gate.
3. **Drift detection**: nightly job exports each realm and runs `check-config.sh online` against prod. Any
   difference = drift (manual console change). Alert, do not auto-revert. kcwarden on the same schedule exists
   already (`jenkins/jobs.groovy:21-37`).
4. **Promotion**: the same config files for dev -> staging -> prod, with environment differences only in
   `$(env:...)` substitutions (hostnames, secrets). Promote a git SHA, not a re-edited file.
5. **Maintenance on a shared DB needs a freeze.**
   - Breaking changes (flow rebinding, deletes) affect both colors at once.
   - The freeze must cover the affected *paths*, not just admin. For a browser-flow rebind that means
     `/realms/<r>/protocol/openid-connect/auth` and `/login-actions`, i.e. a short login outage.
   - Keep these out of patch releases. Apply them on the lossy path, where they run against green's own DB before
     the switch (`switch-lossy.sh:53`).
   - Replaces the current practice: today's prod pattern (ingress whitelist `127.0.0.1/32` during config-cli)
     blocks *all* traffic. The `kc-gate` Ingress + Service (`k8s/edge/kc-gate.yaml`) blocks only the admin/account Prefix paths
     and returns `503 + Retry-After`; the freeze flips the Service selector, so nginx never reloads (an Ingress
     create/delete reload dropped Keycloak's pooled IdP connections: broker callbacks got 500, build #12). It is an improvement and maps to a Gateway HTTPRoute (3.3).
6. Track a config-cli build for the target Keycloak minor. If none exists, the dropped-field gate is the only
   protection.

---

## 8. CI/CD and change management

**Facts**
- Jenkins in compose:
  - root, `docker.sock` mounted (`compose.yaml:17-37`)
  - built-in node only, "ponytail: no agents" (PLAN.md:439)
  - checks out `file:///repo` (`jenkins/jobs.groovy:11`)
  - admin password from a compose secret
- One stage per phase, logic in `scripts/` (`Jenkinsfile`). `post.failure` stops k6 (`Jenkinsfile:43-49`).

**Rec**
- **Use the org's Jenkins** with Kubernetes agents (pod templates) in a dedicated namespace and a ServiceAccount
  scoped to:
  - `keycloak` namespace RBAC
  - helm releases `kc-blue`/`kc-green`
  - Service `kc-active` patch
  - ConfigMap `kc-state`
  - CNPG clusters (or the cloud DB API via workload identity)
- No `docker.sock`. Build images with BuildKit/Kaniko in an agent; push to the registry.
- Credentials via the Jenkins credentials store backed by the secret manager. The scripts already read secrets only
  from k8s Secrets via `secretKeyRef` and stdin (wl:security-fixes, smoke.sh note). Keep that rule.
- **GitOps (Argo CD / Flux)** as a complement, not a replacement:
  - Argo owns the steady state: both color releases, edge, NetworkPolicies, DB CRs.
  - Jenkins owns the *transition*: the ordered, gated steps (deploy idle, gate, flip, drain).
  - Model the flip as a Git commit of `kc-active`'s selector (or the HTTPRoute weight), applied by Argo and verified
    by Jenkins, so the active color is always in Git.
  - Avoid Argo self-heal fighting `kubectl patch` during a switch (exclude `kc-active` or make Jenkins write to Git).
  - Argo Rollouts' blue/green strategy does not fit: it assumes one Deployment and cannot express the DB copy.
- **Approvals and gates** per phase:

| Phase | Gate |
|---|---|
| Idle color deployed | `check-cluster.sh` (isolation, zones, NetworkPolicy), smoke, `check-config.sh` |
| Before the flip | Manual approval for minor/major; automatic for patch after the staging gate passed for the same artifact |
| After the flip | SLO watch (section 9) for N minutes; **auto flip-back** on burn-rate breach for the shared path only |
| Before drain / scale-down | Edge log: 0 5xx on the old color for the drain period |
| Lossy rollback | Human decision (2.4) |

- **The k6 gate against production.** Do not run synthetic brokered-login load against the real legacy IdP in prod
  (it creates sessions and users there).
  - Run the full gate in **staging** at the measured prod rate, on prod-like infrastructure, for every artifact.
  - In prod, use canary analysis on real traffic:
    - weighted HTTPRoute or a header canary (ai-memory ff26aeb8: a canary-by-header Ingress for dark-launch checks)
    - SLO comparison between colors
  - Add a low-rate synthetic probe with dedicated test users in a dedicated test client: login, refresh, logout,
    logout-probe. That keeps the "logged out stays logged out" signal in prod.
- **Release cadence**:
  - **patch**: every Keycloak patch within 1-2 weeks (security fixes); shared-DB switch, automatable end to end.
  - **minor**: Keycloak ships a minor about every 3 months (26.7 in July, 26.8 in October 2026); plan a lossy window
    per minor with a change ticket.
  - **major**: yearly-ish; a project, with a rehearsal on a prod-sized copy.

---

## 9. Observability and SLOs

**Signals during a switch**

| Source | Signal | Demo status |
|---|---|---|
| Keycloak `:9000/keycloak/metrics` | HTTP server request rate/latency/status per endpoint, `process_cpu_usage`, JVM heap/GC, DB pool active/pending | Exposed, not scraped (ai-memory 0061a8a7: `/keycloak/metrics` = 200) |
| Keycloak event metrics | login/refresh/logout success/error counts | Not enabled. **Rec**: enable Keycloak's user-event metrics |
| Edge | per-request status + upstream pod (switch moment, drain curve) | ingress-nginx :10254 exposes only Go/promhttp metrics, **no `nginx_ingress_controller_requests`** in this build (ai-memory 0061a8a7, ee8d9d2d; not in the worklogs). Truth comes from the access log: `scripts/edge-log.sh` (parses it into a per-request switch timeline; not used by the gate) |
| DB | commit latency, replication lag (sync standby), connections, lock waits, outbox table size/oldest row | Nothing collected. CNPG exports Prometheus metrics; enable a PodMonitor |
| JGroups/Infinispan | cluster view size per color (`ISPN000094` log lines, `scripts/check-cluster.sh:18-29`) | Checked once at deploy. **Rec**: alert when a view size differs from replicas, or a foreign member appears |
| Replay | lines read per pod, applied, failed | Counts only in the `replay` event (`replay.sh:44`) |
| Clock | NTP offset per node | None |

**SLOs (proposal, to calibrate on 4 weeks of prod data)**

| SLI | Definition | Objective |
|---|---|---|
| Login success | successful `/token` (authorization_code) / all, excluding 4xx caused by the client | 99.9% / 30 d |
| Refresh success | successful refresh / all refreshes of non-revoked sessions | 99.95% |
| Token latency | p99 `/token` (token endpoint only; the broker hop to the legacy IdP is a separate SLI) | < 500 ms |
| Logout integrity | refresh after logout succeeds | 0 (correctness alarm, not a budget) |
| Issuer integrity | tokens with an issuer outside the allowlist | 0 (correctness alarm) |

- **Alerting**: multi-window burn rate (e.g. 14.4x over 1 h and 5 m) for login/refresh. During a switch, the
  pipeline watches the same burn rate and triggers the shared-path flip-back.
- **Dashboards**: one "switch" dashboard with per-color request rate, 5xx by upstream color, DB commit p99, outbox
  lag, view sizes, and event annotations from `out/events.jsonl` (ship them as Grafana annotations).
- **Tracing**: Keycloak supports OpenTelemetry tracing (`--tracing-enabled=true`; the `opentelemetry:v1` feature is
  supported and enabled by default, [features page](https://www.keycloak.org/server/features); OTLP gRPC :4317 by
  default, [Red Hat 26.4 observability guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.4/html/observability_guide/tracing-)).
  Trace the broker hop to the legacy IdP: the one 502 in build #2 was a legacy-IdP CME (wl:slice5-6). Sample at
  1-5%, and at 100% for the synthetic probe users.

---

## 10. Security

Findings and fixes come from the security pipeline (wl:security-pipelines, wl:security-fixes).

**Decisions (accepted 2026-11-03)**

The user accepted the items below as-is for the demo on 2026-11-03: each stays a production blocker to schedule, none
blocks the demo. They are recorded here so the security pipeline's FAIL/WARN is an explained state, not an open
question.

| Item | State | Rec |
|---|---|---|
| Admin console + REST public on the login hosts | WARN by design (`scripts/security/probe-admin.sh:90-104`, `EXPECT_ADMIN_PUBLIC=true`) — **accepted** | Do not expose `/admin/` and `/realms/master/` publicly ([reverse proxy guide](https://www.keycloak.org/server/reverseproxy)). Use `hostname-admin` on an internal-only host/gateway; then flip `EXPECT_ADMIN_PUBLIC=false` |
| CSP without `default-src` | ZAP WARN (wl:security-pipelines) — **accepted** | Set the realm's CSP header (realm security defenses) with `default-src 'self'` plus what the theme needs; test the login and account pages |
| guava CVE in Keycloak libs | trivy FAIL (CVE-2026-102554, guava 33.6.0, fix 33.7.2) — **accepted** | Time-boxed exception; upgrade on the Keycloak patch that bumps it; confirm reachability with upstream advisories |
| Brute force | fixed (on in master + demo) | Keep; note the reset across lossy windows (2.3) |

**`hostname-strict=false` and issuer forgery**
- **Fact**: with dynamic hostnames the issuer follows `X-Forwarded-Host`. Going around the ingress forged it
  [verified: issuer `https://evil.example/...`] (wl:slice1b-2).
- Through the ingress, Host case and trailing dot varied it [verified] until the 421 guard (wl:security-fixes). The
  legacy IdP honoured `Forwarded` until `forward-headers-strategy: native` + `internal-proxies`
  (`legacy-idp/src/main/resources/application.yaml:6-11`).
- **What the guards cover**:
  - requests via the edge with a non-canonical Host (421)
  - client-supplied proxy headers (stripped)
  - unlabelled pods and pods in other namespaces (NetworkPolicy, `helm/values-common.yaml:119-126`; probe-netpol)
- **What they do not cover**:
  - Any pod in ns `keycloak` labelled `kc-<color>-keycloak-client=true` reaches Keycloak directly and *can* forge
    the issuer ("the label is the trust boundary", `scripts/security/probe-netpol.sh:79`). In prod, whoever can
    create pods in that namespace can mint that label. Rec: restrict pod creation in ns `keycloak` via RBAC, and
    add an admission policy that allows the label only on known Job templates/ServiceAccounts.
  - Kubelet port-forward (used by `admin_direct_start`, `scripts/lib/kc.sh:181-189`) bypasses NetworkPolicy by
    design. RBAC on `pods/portforward` is the control.
  - Other ingresses in prod that might forward the raw Host. Each one needs the same guard and must pass
    `probe-issuer.sh`.
  - The legacy namespace has **no NetworkPolicy** (wl:security-fixes section 2, "Not done").
- **Can hostnames be pinned per network?** Not for one realm on two hosts:
  - Keycloak's hostname v2 takes one `hostname`. The only per-realm pin is the realm frontend URL, one value per
    realm ([hostname guide](https://www.keycloak.org/server/hostname)).
  - The guide says hostname-strict "Should always be set to true in production, unless your reverse proxy
    overwrites the Host header".
  - Options:
    1. One realm per network, each with its frontend URL. Changes `iss` per realm and splits users: probably not
       acceptable, since auto-linking across networks is a requirement.
    2. Keep `hostname-strict=false` and the guards: edge canonical-Host check, header stripping,
       `proxy-trusted-addresses`, NetworkPolicy, and probe-issuer in CI and nightly.
  - **Rec: (2)**, with `proxy-trusted-addresses` added.
  - **Open**: do the prod networks map to separate realms already?

**WAF and rate limiting**: the demo has none.
- Rec: at the gateway, per-IP and per-client rate limits on `/token`, `/login-actions/authenticate`, `/broker/*`,
  and dynamic client registration.
- Use the org WAF in front for L7 basics. Make sure WAF rules allow Keycloak's large cookies/headers (the demo
  needed `proxy-buffer-size 128k`, `k8s/edge/ingress.yaml:7`).

**Multi-tenancy across networks**
- `tenant` is a claim from the legacy IdP (`providers/.../TenantMapper.java`). Both networks share realm `demo` and
  auto-link users across networks (PLAN.md:47-51).
- A token from net1 is rejected at net2 (issuer differs; probe-tokens). Users are shared by design.
- **Open**: confirm that cross-network auto-link (`first-broker-auto-link`) is the intended trust model in prod. It
  lets the legacy IdP on either network assert the same identity.

**Audit and event retention**
- The demo realm enables admin events (`config/bootstrap/10-demo-realm.json:6`) but no stored user events, and logs
  events via `jboss-logging`.
- Rec: ship Keycloak events (and admin events) to the SIEM through the log pipeline or an event-listener SPI. Set
  DB event expiration if events are stored. Define retention per the org's audit policy.

**Pod security**
- Keycloak runs as uid 1001 (`images/keycloak/Dockerfile:38`). kc-maint uses `nginx-unprivileged`.
- Rec: Pod Security Admission `restricted` on ns `keycloak` and `legacy` (verify the chart's securityContext
  passes); default-deny NetworkPolicies in every namespace (`legacy`, `load`, `cnpg-system`, edge).

**Run the security pipeline continuously**
- It is already nightly (`H 2 * * *`, `jenkins/jobs.groovy:23-25,43-45`).
- Rec: also run `kc-security` as a gate after every switch (the probes are read-only or self-cleaning,
  `security/README.md:3-5`). Run kcwarden on every config PR. Point it at staging and prod with read-only creds.

---

## 11. Operational readiness

**Runbooks** (one per case; the `demo.sh` phase headers, `scripts/demo.sh:24-45`, are a good skeleton). Each needs:
- preconditions (versions, DB health, SLO budget left, change ticket)
- steps with expected outputs
- abort criteria per step
- the rollback route
- who decides

| Runbook | Abort/rollback rule |
|---|---|
| Patch (shared DB) | Any 5xx burst or SLO burn after flip -> `rollback.sh` within the hold |
| Minor/major (lossy) | Abort before `promote` = free. After `promote` and before `switch` = discard green + its DB, unfreeze (nothing lost). After `switch` = lossy rollback, human decision |
| Rollback | Refuses past the hold (`rollback.sh:15-16`); then fix forward |
| Stuck freeze | `unfreeze` (`scripts/lib/kc.sh:170`) is idempotent; alert if Service `kc-gate` selects kc-maint for longer than the planned window |
| Interrupted helm release | Pending release needs `helm uninstall` / rollback before rerun (wl:slice1-platform) |

**On-call**: the switch should run in business hours with the IdP team on call. Lossy windows need someone who can
judge the replay counts. Page on: SLO burn, view-size mismatch, NTP offset, DB commit latency, outbox lag, freeze
older than X.

**DR scenarios**

| Scenario | Demo | Production |
|---|---|---|
| Pod kill (graceful) | Gated in the patch case (`switch-shared.sh:33-45`) | Same |
| AZ loss | Planned as step 6z "reported, not gated" (PLAN.md:332-339), **not implemented — accepted 2026-11-03** | Expect: Keycloak keeps 2 of 3 pods (PDB); CNPG with `ANY 1` keeps quorum; in-flight POSTs on the lost zone fail (502). Drill it in staging with a real zone failure (cordon + node stop) |
| DB primary loss | Not run — accepted 2026-11-03 | CNPG/managed failover; Keycloak reconnects; `stateless` clears local caches after reconnect (concepts page). Drill |
| Region loss | Out of scope | Multi-cluster v2 is single-region. Region DR = restore from backups in another region + DNS failover; RPO = WAL archive lag, RTO = restore + start. Decide whether that is acceptable for the org IdP |

**Chaos testing**: start with the drills above in staging, scheduled monthly:
- pod kill during a switch (exists)
- zone loss during a switch
- DB failover during a switch
- clock skew injection on one node (> 10 s, expect stale invalidations)
- legacy IdP outage (expect Keycloak 502 on broker hops; check the error page and alerting)

**Capacity planning**
- **Measured** (`out/mem-patch.jsonl`, 23:36-00:52 on 2026-11-02/03, patch run at LOGIN_RATE 5/s, 10 refresh VUs,
  4 logout VUs, `load/k6/flows.js:24-36`):

| Component | Peak working set |
|---|---|
| Keycloak pods | 982-1189 MiB (request 1.5 Gi, limit 2 Gi) |
| ingress-nginx | 459 MiB |
| pg-1 primary | 346 MiB |
| legacy IdP | 308 MiB |

- The CPU baseline (`load/RATE.md`, "Keycloak CPU < 60%") was never recorded (wl:slice4-load-gate, Open).
- Sizing guide: 1250 MB per pod base; 1 vCPU per 15 password logins/s; per 120 refresh/s; leave "150% extra
  head-room"; DB 1400 write IOPS per 100 login/logout/refresh/s ([sizing](https://www.keycloak.org/high-availability/single-cluster/concepts-memory-and-cpu-sizing)).
  Brokered logins are not password logins in Keycloak, but they include a back-channel call; measure.
- **Rec**:
  - Run the gate at 1x, 2x and 4x prod peak login rate in staging; record CPU, memory, DB IOPS and commit p99.
  - Size each color for 100% of the load: the flip moves all traffic at once.
  - Size the DB for two colors' connections and roughly 2x the non-stateless IOPS.

**Cost**
- Steady state: one color (3 pods) + DB.
- During a switch: 2x Keycloak for the overlap and hold.
- Lossy only: a second DB of full size for the hold plus the retention of the old copy.
- With a managed DB: clone/replica cost per minor upgrade (Aurora clones are copy-on-write: cost grows with
  divergence).
- The `stateless` DB load roughly doubles DB cost versus classic sessions-in-Infinispan sizing.
- Per-zone headroom for a second color is the largest fixed cost. Alternative: a surge node pool that autoscales
  for the switch.

---

## 12. Custom code risk

**Provider JAR** (`providers/`): TenantMapper, LoginContextAuthenticator/Mapper, ReplayEventListener.
- Builds against `keycloak-server-spi`, `keycloak-server-spi-private` **and `keycloak-services`**
  (`providers/pom.xml:30-48`). `kc.sh build` printed **KC-SERVICES0047** for all 4 provider ids: they implement
  internal SPIs (wl:slice3-providers-theme). Internal SPIs carry no compatibility promise across minors.
- One jar per major, compiled against the *lowest* minor deployed (26.7.5 for all of 26.x, `pom.xml:22`), run on
  26.8.1. Binary compatibility across minors is assumed, not tested beyond the demo's flows.
- Event semantics differ per version, read from source: REVOKE_GRANT has no sessionId on 25; creation =
  `REGISTER` + `identity_provider`, not `IDENTITY_PROVIDER_FIRST_LOGIN` (wl:slice3). These are exactly the kind of
  details that change silently.
- Mappers ignore the `access.token.claim` toggles on purpose (wl:slice3, Decisions). That surprises anyone who
  configures them in the console.

**Rec**
- Build the jar against the **exact** target Keycloak version for each image. The image build already runs `mvn
  verify` (`images/keycloak/Dockerfile:14-15`): make `keycloak.version` = `KC_VERSION`.
- Add an integration test stage that boots the target image with the jar and runs the brokered login + logout +
  revoke flow. The scratch `e2e.sh` from Slice 3 did this (wl:slice3, "Live check"): commit it.
- Inventory internal-SPI use; prefer public SPIs where one exists.

**The replay listener as production code**: it becomes part of the IdP's security posture (missed logout =
resurrected session). Needed:
- move to the durable sink (2.3)
- metrics (lines written, failures)
- a contract test per Keycloak minor for the event types it relies on
- an owner

---

## 13. Phased roadmap

T-shirt sizes: S <= 1 week, M 2-4 weeks, L 1-2 months, XL > 2 months, for one engineer familiar with the repo.
"Team has" = likely already present in the user's environment, per the brief: map it, do not rebuild it.

### Phase 0: close the demo's own evidence gaps (on KinD)

| Item | Size | Proves |
|---|---|---|
| Live `minor`, `major`, `minor-rollback` gate runs; record `lossy_seconds`, `sessions_lost`, `resurrection_seconds` and the cross-major refresh result | M | Lossy mechanism works at all — **done 2026-11-03** (builds #35-#37 PASS) |
| Finish the `patch-rollback` gate run | S | Shared rollback — **done** (build #34 PASS) |
| Implement `ROLLBACK_HOLD` (keep the old color N minutes, then scale down in its own logged step) | S | A rollback window exists on the default path — **accepted, not built** (section 2.4; `KEEP_OLD=true` is the operator path) |
| Wire `check-config.sh` after every `config.sh` | S | Config drop protection — **done** (`config.sh:65`) |
| `replay.sh`: fail on non-404 errors, detect pod replacement (pod `creationTimestamp > since`), check listener enabled | S | Replay honesty |
| Negative control (no `stateless`) and zone-loss step 6z | S-M | Gate can tell failure apart; zone behaviour |
| Test realm with `revokeRefreshToken=true` and an `offline_access` client through a lossy switch | S | The two biggest Opens |
| Apply and verify the security fixes live (`2018bd5`) | S | Guards work on the running edge |

### Phase 1: staging-grade

| Item | Size | Team has? | Depends on | Proves |
|---|---|---|---|---|
| Managed k8s, 3 real AZs, org registry, digest-pinned signed images, admission policy | M | k8s + registry: yes; signing/admission: maybe | - | Platform parity |
| Org Jenkins with k8s agents, scoped ServiceAccount, credentials from secret manager | M | Jenkins: **yes** | registry | No docker.sock, least privilege |
| DB decision (managed vs CNPG) + backups/PITR + first restore drill | L | managed Postgres: likely | - | RPO/RTO |
| Copy step re-implemented for the chosen DB (Aurora clone / replica promote) | M | - | DB decision | Lossy path off CNPG |
| Durable replay sink (outbox table) + listener tests per minor | M | - | Phase 0 | No silent replay loss |
| Edge: Gateway API implementation, HTTPRoute to `kc-active`, Host guard equivalent, `proxy-trusted-addresses`, probe-issuer green | L | ingress-nginx: **yes (EOL)** | - | Edge off EOL; issuer integrity |
| Chart decision (fork Bitnami / keycloakx / own) | M | Bitnami chart: **yes** | - | Chart off a frozen artifact |
| Observability: scrape Keycloak + DB + edge, switch dashboard, SLOs | M | Prometheus/Grafana: likely | edge | Switch visible |
| Gate at 1x/2x/4x prod rate on a prod-sized DB copy; migration timing per minor | M | - | all above | Window length, capacity |

### Phase 2: production-grade

| Item | Size | Depends on | Proves |
|---|---|---|---|
| GitOps steady state + Jenkins transition pipeline with approvals, auto flip-back for patch | M | Phase 1 | Change control |
| Secrets in Vault/ESO, two-phase rotation runbooks (config-cli, broker, DB, realm keys), temp-admin removed, break-glass | M | Phase 1 | Rotation without outage |
| config-cli change process: PR CI against target version, drift detection nightly, promotion by SHA | M | check-config gate | No silent config drift |
| Admin console internal-only (`hostname-admin`), CSP, WAF/rate limits, PSA restricted, NetworkPolicies everywhere, security pipeline post-switch | M | edge | Security decisions closed |
| DR drills: AZ loss and DB failover during a switch, region restore; chaos schedule | M | Phase 1 | Failure behaviour known |
| Synthetic prod probe users + canary analysis; runbooks; on-call training | S-M | observability | Prod verification without synthetic load |
| First real patch through the pipeline, then the first minor in a planned window | S each | all | It works with real traffic |

**Critical path**: Phase 0 lossy runs -> durable replay sink -> DB copy step for the real DB -> staging gate at prod
rate -> first prod patch -> first prod minor. The edge migration runs in parallel but must land before production
go-live.

**Total**: roughly 3-5 months for one to two engineers, assuming the org platform pieces (registry, managed
Postgres, Prometheus, Vault/ESO, Jenkins) exist. [assumed: estimate, not measured.]

---

## Appendix: open questions for the team

1. Do RPs use `offline_access` / offline tokens? (decides whether lossy is silent)
2. Is refresh-token rotation (`revokeRefreshToken`) on in prod realms? (may break every session refreshed in a lossy window)
3. Do all prod ingresses route to one Service per Keycloak deployment? Does any forward a raw Host?
4. Do the prod networks map to one realm (as in the demo) or to several?
5. Does the upstream legacy IdP send backchannel logouts to Keycloak, and do they emit a `LOGOUT` event?
6. Managed Postgres or CNPG? Which vendor (decides the copy step)?
7. Is commercial Keycloak support (Red Hat build) in play? Which version is supported there?
8. What are the prod login/refresh peak rates and the SSO idle timeout? (capacity, hold period)
9. Is a short login outage acceptable for maintenance-stage changes, or must those always ride a minor upgrade?

## Appendix: sources (checked 2026-11-03)

- Keycloak:
  - [26.8 release notes](https://www.keycloak.org/docs/latest/release_notes/index.html)
  - [features](https://www.keycloak.org/server/features)
  - [26.7 multi-cluster v2 / stateless blog](https://www.keycloak.org/2026/07/multi-cluster-v2-and-stateless-mode)
  - multi-cluster v2 [introduction](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/introduction), [concepts](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/concepts), [upgrades](https://www.keycloak.org/nightly/high-availability/multi-cluster-v2/upgrades) (nightly docs)
  - [hostname](https://www.keycloak.org/server/hostname)
  - [reverse proxy](https://www.keycloak.org/server/reverseproxy)
  - [sizing](https://www.keycloak.org/high-availability/single-cluster/concepts-memory-and-cpu-sizing)
  - [operator rolling updates](https://www.keycloak.org/operator/rolling-updates)
- [ingress-nginx retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Gateway API implementations](https://gateway-api.sigs.k8s.io/implementations/)
- CNPG:
  - [1.30 release notes](https://cloudnative-pg.io/docs/1.30/release_notes/v1.30/)
  - [Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/)
- AWS:
  - [RDS Blue/Green considerations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-considerations.html)
  - [Aurora fast-clone blue/green](https://aws.amazon.com/blogs/database/amazon-aurora-postgresql-blue-green-deployment-using-fast-database-cloning)
- [GKE container-native LB](https://cloud.google.com/kubernetes-engine/docs/concepts/container-native-load-balancing)
- Secondary sources (treat with care):
  - [bare.id on Bitnami](https://www.bare.id/en/blog/bitnami-umstellung-was-keycloak-nutzer-jetzt-wissen-und-tun-mussen)
  - [bitnami/containers#83267](https://github.com/bitnami/containers/issues/83267)
  - [codecentric keycloakx 7.2.2](https://github.com/codecentric/helm-charts/releases/tag/keycloakx-7.2.2)
  - [Lyft Aurora upgrade](https://eng.lyft.com/postgres-aurora-db-major-version-upgrade-with-minimal-downtime-4e26178f07a0)
  - [collabnix ingress2gateway](https://collabnix.com/ingress-nginx-is-retired-a-hands-on-migration-to-gateway-api-with-ingress2gateway-1-0/)
