# Oracle 19.3 instead of Postgres: route, tools, zero-downtime analysis

Branch `oracle-19c`. This replaces the demo's database engine; the Keycloak blue/green
contract, load, gate and report stay. The short version:

- **The default is Oracle 19.3 EE** from the Docker Hub image
  `mohammedesafi/oracle-database:19.3.0-ee` (community build of Oracle's official 19.3
  Dockerfiles, OTN Developer License), with `ORACLE_MEMORY=6Gi` and `ORACLE_PDB=FREEPDB1`;
  the full five-case validation ran on it and every gate passed. `gvenzl/oracle-free:23.26.3-slim`
  is the faster, smaller alternative and passed the same five cases.
- Oracle 19c has no free Express Edition (18c and 21c XE exist; 19c does not), and the
  official 19.3 EE image is on Oracle Container Registry behind an Oracle SSO login. The
  Docker Hub 19.3 image used here is a community build, not an Oracle-supported production
  image; the SQL, JDBC driver, schema handling and Data Pump cutover are the same.
- **Zero downtime is preserved the same way it is on Postgres**: a shared schema for patch
  upgrades, and a lossy overlap for minor/major. Oracle changes the *copy tool*, not the
  app-level contract.
- **A live Postgres→Oracle migration is not made zero-downtime here.** That is a one-time
  data migration, not an upgrade; stock Oracle tools cannot replicate from Postgres.
  See "If you are migrating an existing Postgres" below.

## What changed

| Postgres / CNPG (main) | Oracle (`oracle-19c`) |
|---|---|
| CloudNativePG operator + `pg-1`/`pg-2` clusters | one Oracle StatefulSet (`k8s/oracle/oracle.yaml.tpl`) with a PVC |
| one database per color (minor/major) | one schema per color in `FREEPDB1`: `KC1`, `KC2` |
| `psql_db` via `psql` | `sql_admin`/`sql_db` via SQL*Plus as SYSDBA (no password in argv) |
| CNPG replica cluster + promote | Oracle Data Pump export at `FLASHBACK_SCN`, import with `REMAP_SCHEMA` |
| LSN copy point (`pg_current_wal_lsn`) | SCN copy point (`DBMS_FLASHBACK.GET_SYSTEM_CHANGE_NUMBER`) |
| `--db=postgres` image | `--db=oracle` image + `ojdbc17` and `orai18n` in `providers/` |
| `databasechangelog` count via psql | `DATABASECHANGELOG` count via SQL*Plus |
| CNPG metrics (not collected) | `scripts/check-db.sh` + SCN events; AWR/Statspack available for production |

The Keycloak image is still the official image re-laid into the Bitnami layout. The only
image change is the Oracle driver and `--db=oracle`:
`images/keycloak/Dockerfile`, `scripts/lib/kc.sh` (`build_opts`).

Keycloak facts used here:

- Keycloak 26 documents Oracle 19c (19.3+) and 23.x as supported; Oracle RAC is supported
  at the same engine version ([database guide](https://www.keycloak.org/server/db)).
- The Oracle JDBC driver is the one driver Keycloak does not ship; the documented install is
  `ojdbc17` + `orai18n` 23.26.2.0.0 in `providers/` before `kc.sh build`.
- Keycloak's default `jdbc-ping` discovery used to fail on Oracle because it quoted the
  lower-case default schema while Oracle stores it unquoted and upper-case; PR
  [#40999](https://github.com/keycloak/keycloak/pull/40999) fixed that (merged 2025-07).
  26.7.5/26.8.1 include the fix. Keycloak 25 uses the `kubernetes` cache stack, not jdbc-ping.
- Oracle stores unquoted identifiers in upper case, so the schemas are `KC1`/`KC2`. Keycloak
  gets `KC_DB_SCHEMA=KC1`/`KC2` (the chart's `externalDatabase.schema`).

## The cutover, step by step

### Patch (same Keycloak major.minor): shared schema, zero loss

1. Both colors use the same Oracle schema (`kc1`) and their own Infinispan cluster name.
2. Deploy green, run online config, flip the `kc-active` Service, drain blue.
3. Nothing is copied and nothing is lost; the gate's shared-DB rules are unchanged.

This is the same mechanism as `main`; only the JDBC URL/schema changed.

### Minor/major: lossy overlap with a Data Pump copy

Two Keycloak major/minor versions cannot share a schema, so green gets `kc2`:

1. `create_db kc2` creates the Oracle user/schema (seconds).
2. Freeze only `/admin` and the account console (503), as on Postgres.
3. Record `copy_scn` and export `KC1` at that SCN:
   `expdp ... SCHEMAS=KC1 FLASHBACK_SCN=<scn> ...` run as `SYSTEM` inside the Oracle pod.
   Blue keeps serving login/token/logout while the export runs.
4. `create_db kc2` already created the target; import with
   `impdp ... REMAP_SCHEMA=KC1:KC2`. The target is now the copy at the copy point.
5. Deploy green on `kc2`; Keycloak's Liquibase migrates it. Record the
   `DATABASECHANGELOG` count before/after.
6. Replay blue's logouts and first-broker-login user creations from the window; flip; replay
   again after the drain. Unfreeze.

The lost set is the same as on Postgres: sessions created on blue in
`[copy_point, switch]`; those users re-login silently through the legacy IdP's SSO. Admin and
the account console are 503 for the window. Login, token, refresh, logout, discovery and
JWKS never stop. The gate's `refresh_pre_copy`, `invalid_grant_in_window`, `logout_after_replay`
and `window_exercised` rules are unchanged. `db_copy_matches_source` checks the copy itself: after the import,
`switch-lossy.sh` counts users + persisted sessions in the source `AS OF SCN <copy_scn>` and in the copy, aborts on
a mismatch and records both counts on the `promoted` event for the gate.

### Why Data Pump and not something else

| Route | Works with 19.3? | Zero login/token downtime? | Why not the default here |
|---|---|---|---|
| **Data Pump at SCN + replay** | yes (EE/SE2 and Free) | yes, lossy window as above | portable, one instance, uses the demo's existing replay; chosen |
| Refreshable PDB clone | yes (19c EE, same CDB) | yes, same lossy window | faster copy, but same-CDB/PDB prerequisites and a second PDB (Free allows one); a production optimisation, not the portable default |
| Oracle Data Guard physical standby | yes (19c EE) | standby is read-only; cannot run green's Liquibase migration | switchover + migration = write freeze; not a blue/green app upgrade tool |
| Data Guard **snapshot standby** | yes (19c EE, needs a standby + flashback logging) | yes, same lossy window: convert the standby to read-write at the copy point, green migrates it | the closest Oracle analogue of the old replica-promote recipe and no copy time; but green then lives on the standby (convert back = discard green), so it needs a second standby to stay protected |
| PDB hot clone (non-refreshable) | yes (19c EE, local undo + archivelog) | yes, same lossy window; copy point = clone SCN | block-level copy, faster than Data Pump for a large realm; one PDB per color instead of one schema (Free allows few PDBs) |
| Debezium Oracle LogMiner → Kafka → green | yes (19c EE, LogMiner) | keeps a *second Oracle* warm at schema N; still migrates at cutover | Kafka/Connect/connector grants and lag; overkill for this DB size; does not remove the migration window |
| GoldenGate Postgres→Oracle | licensed | yes, CDC with a short cutover | only route for a *live engine migration*; not an app-upgrade copy |

The important correction to the 2026-07 research: Debezium's Oracle connector captures
**Oracle**, not Postgres. It is a good way to keep a second Oracle warm for a big
Oracle→Oracle upgrade. It is not a Postgres→Oracle migration tool.

## If you are migrating an existing Postgres

This branch starts the demo on Oracle; it does not perform a live data migration. For an
existing Postgres installation, the honest options are:

1. **One-time migration with a short write freeze** (recommended for most): convert schema and
   data with `ora2pg` (or a reviewed `pg_dump` → Oracle loader), run it against a clone, then
   cut over. The freeze covers the final delta. This is not zero-downtime, but it is bounded
   and testable.
2. **GoldenGate for PostgreSQL → Oracle** if a freeze is not allowed: initial load plus CDC,
   then a short cutover. Licensed, and the only stock route for a true zero-downtime engine
   migration.
3. **Dual-write at the application layer** only if you own the application writes; Keycloak
   does not expose a supported dual-write mode.

Once on Oracle, the blue/green mechanisms in this branch apply to Keycloak upgrades.

## Tools and instrumentation

- `scripts/lib/kc.sh`: `sql_admin`, `sql_db`, `sql_scalar`, `create_db`, `delete_dbs`,
  `oracle_ready`, Oracle-aware `deploy_color`.
- `scripts/check-db.sh <db>`: the schema has tables and `DATABASECHANGELOG` rows; called by
  `deploy_color` after Helm reports Ready. "Pod Ready" is not proof Keycloak used the schema.
- `scripts/switch-lossy.sh`: SCN copy point, Data Pump export/import, `copy_ready` and
  `promoted` events carry `scn`; `copy_point` carries `scn`.
- Gate: `db_copy_matches_source` (row counts, source AS OF the copy SCN vs the copy) + the existing lossy rules;
  `sessions_lost` counts every session born in the window, `sessions_lost_observed` the ones k6 came back to.
- `out/events.jsonl` retains the same event names the report consumes (`copy_point`,
  `promoted`, `migration`, `switch`, `replay*`), so the report and gate do not fork.
- For production Oracle: AWR/Statspack, `V$SESSION`, `V$SYSTEM_EVENT`, Data Guard broker,
  RMAN backups. The demo does not collect these; `docs/production-readiness.md` describes
  the gap.

## Running it

### Default: 19.3 EE from Docker Hub (validated)

```bash
bash scripts/jenkins-secret.sh
docker compose run --rm launcher          # creates KinD + Oracle 19.3 + kc1 + blue
docker compose up -d jenkins
# Jenkins: CASE=patch|minor|major, as on main
```

`ORACLE_IMAGE` defaults to `mohammedesafi/oracle-database:19.3.0-ee`, `ORACLE_SID=ORCLCDB`,
`ORACLE_MEMORY=6Gi`. This is a community build of Oracle's official 19.3 Dockerfiles under the OTN Developer
License: development/test only, not an Oracle-supported production image. The first `up.sh` creates `ORCLCDB` and
`FREEPDB1`; it takes ~15-20 min. `reset.sh` only drops/recreates schemas, so later cases are fast.

### gvenzl Free (faster, smaller, no login)

```bash
export ORACLE_IMAGE=gvenzl/oracle-free:23.26.3-slim
export ORACLE_MEMORY=4Gi
docker compose run --rm launcher
```

Leave `ORACLE_SID` unset: `scripts/lib/kc.sh` picks `FREE` for an `oracle-free` image. (Between `ab3b167` and this
fix compose defaulted it to `ORCLCDB`, which the gvenzl entrypoint and `sqlplus` would have followed; the Free run
below predates that commit and has not been repeated since.)

The Free image starts in a few minutes and passed the same five cases. Give Docker 15 GiB (13 GiB for
`PROFILE=laptop`, which is Free-sized; 19.3 does not fit the laptop profile).

### Official Oracle 19.3 EE (optional, needs Oracle SSO)

If you have Oracle Container Registry access, the official image is a drop-in replacement:

```bash
docker login container-registry.oracle.com   # Oracle SSO account
export ORACLE_IMAGE=container-registry.oracle.com/database/enterprise:19.3.0.0
export ORACLE_SID=ORCLCDB
export ORACLE_MEMORY=6Gi
export ORACLE_PULL_SECRET=oracle-regcred
export ORACLE_PULL_SECRET_FILE=/tmp/docker-config.json # path INSIDE the launcher
docker compose run --rm -v "$HOME/.docker/config.json:/tmp/docker-config.json:ro" launcher
```

The launcher is a container, so mount the Docker config at the path `ORACLE_PULL_SECRET_FILE`
names; `up.sh` turns it into the Kubernetes pull secret.

If the cluster already exists and you prefer to create the secret yourself:

```bash
kubectl -n keycloak create secret docker-registry oracle-regcred \
  --docker-server=container-registry.oracle.com --docker-username='<email>' \
  --docker-password='<token>' --docker-email='<email>'
export ORACLE_IMAGE=container-registry.oracle.com/database/enterprise:19.3.0.0
export ORACLE_SID=ORCLCDB
export ORACLE_MEMORY=6Gi
export ORACLE_PULL_SECRET=oracle-regcred
docker compose run --rm launcher
```

The template sets `ORACLE_SID=ORCLCDB`, `ORACLE_PDB=FREEPDB1`, and both `ORACLE_PWD` and
`ORACLE_PASSWORD`; the official image and the gvenzl Free image each read their own name.
The bootstrap script is mounted at both `/container-entrypoint-initdb.d` (gvenzl) and
`/opt/oracle/scripts/setup` (official). `ORACLE_IMAGE` also selects the SID: `FREE` when the image name contains
`oracle-free`, else `ORCLCDB`; set `ORACLE_SID` explicitly for anything else (e.g. an XE image).

## Validation done on this branch (2026-11-04/05)

**Full five-case Jenkins/KinD run on Oracle 19.3 EE from Docker Hub, all gates PASS:**

| Jenkins build | case | gate |
|---|---|---|
| #1 | `patch` (26.8.0 -> 26.8.1, shared) | `GATE PASS (shared)` |
| #3 | `minor` (26.7.5 -> 26.8.1, Data Pump) | `GATE PASS (lossy)` |
| #4 | `major` (25.0.6 -> 26.8.1, Data Pump) | `GATE PASS (lossy)` |
| #5 | `patch-rollback` | `GATE PASS (shared-rollback)` |
| #6 | `minor-rollback` | `GATE PASS (lossy-rollback)` |

Image: `mohammedesafi/oracle-database:19.3.0-ee` — a community build of Oracle's official 19.3 Dockerfiles, OTN
Developer License, not an Oracle-supported production image. Env: `ORACLE_SID=ORCLCDB`, `ORACLE_PDB=FREEPDB1`,
`ORACLE_MEMORY=6Gi`. First DB creation took ~15-20 min; the startup probe and `oracle_ready` allow 30 min. The report
is `out/oracle19c-run/report.html` (gitignored; Jenkins archives it). Headline: 0 5xx in every case; `minor` 3
sessions lost with 3 silent re-logins; `major` 5/5 (the sessions k6 came back to; 320 and 354 sessions were born in the window and are not in the copy,
see README Results); changesets
211 -> 238 (minor) and 134 -> 238 (major).

The **gvenzl Oracle Free** path also passed all five cases (Jenkins builds #2/#4/#6/#7/#9, report
`out/oracle-run/report.html`), with its 4 GiB profile and a much faster first start.

Component checks behind it:

- `docker build` of `images/keycloak/Dockerfile` with `KC_VERSION=26.8.1` and the Oracle JDBC jars:
  `Installed features: [... jdbc-oracle ...]`, `kc.sh build --db=oracle` succeeded. The same build with
  `KC_VERSION=25.0.6` (`--features=persistent-user-sessions`) also succeeded and created 134 changesets on
  Oracle with Keycloak 25.0.6.
- Keycloak 26.8.1 started against `gvenzl/oracle-free:23.26.3-slim` and against the 19.3 image with
  `KC_DB_SCHEMA=KC1`: Liquibase created 102 tables and 237 changesets; JGroups `jdbc-ping` formed a cluster;
  `/realms/master` answered 200.
- Data Pump: `expdp SCHEMAS=KC1 FLASHBACK_SCN=<scn>` exported the full Keycloak schema; `impdp
  REMAP_SCHEMA=KC1:KC2 EXCLUDE=USER EXCLUDE=STATISTICS` imported it; green migrated it. On 19c the three
  function-based index statistics fail with ORA-20000 even though every table/index/constraint imports; excluding
  statistics avoids a false failure.
- The gvenzl Free container starts standalone under 2 GiB, but the in-cluster first start is OOMKilled at 2/3 GiB:
  the 3.0 GiB 7-Zip extraction plus the 1 GiB memory-backed `/dev/shm` needs 4 GiB. The 19.3 run used 6 GiB.
- A plain `sqlplus / as sysdba` succeeds while 19c DBCA is still building the PDB, so the pod went Ready too early and
  `create_db` failed with exit 243. The probes and `oracle_ready` now require `V$PDBS` to show FREEPDB1 open
  read-write; the first-start budget is 30 min.
- Other fixes found by the full runs: `kc2` not `kc-2` as the next schema name, the Keycloak 25 overlay must repeat
  `KC_DB`/`KC_DB_URL` (Helm replaces `extraEnvVars`), SQL*Plus needs a statement terminator before `exit`, schema
  drop must kill sessions and retry, the readiness probe needs a 5 s timeout, and the launcher's BusyBox `sed` has no
  `-u`.

Out of scope for this branch: the Oracle Container Registry 19.3 image (needs an Oracle SSO login), Data Guard/RAC,
RMAN/PITR, and a refreshable-PDB path. The `helm template` render was checked for
`KC_DB_URL`/`KC_DB`/`KC_DB_SCHEMA`.

## Limits

- **One Oracle instance in KinD.** No Data Guard, RAC cluster or zone-redundant DB. A DB
  instance failure is a demo outage; the upgrade cases do not exercise it. Production Oracle
  should use Data Guard/RAC and backups; the app-level blue/green mechanism is independent
  of that.
- **Data Pump is a logical copy.** It needs undo retention for the SCN export and time
  proportional to schema size. The demo's schema is small; a large production realm should
  use a refreshable PDB clone (same CDB) or a pre-created copy.
- **The default 19.3 image is a community Docker Hub build**, not an Oracle-supported production image. The SQL,
  JDBC and Data Pump path is the real 19.3 EE path; for production use the official Oracle Container Registry image
  (needs Oracle SSO) or your licensed 19.3 installation. The gvenzl Free alternative is 23ai Free, not 19c; its
  compatibility claim is about the Keycloak/Liquibase/Data Pump path.
- **Oracle Free data cap**: 23ai Free is limited (12 GB user data); the demo's 4000 users are
  far below it. 19c EE has no such cap.
- **Keycloak 25**: Oracle support is via `--db=oracle`, `persistent-user-sessions`; the
  `jdbc-ping` Oracle fix is a 26.x change, so 25 keeps `cache-stack=kubernetes`.
- **Oracle memory.** The default 19.3 container is 6 GiB. Its first DBCA run takes ~15-20 minutes and the probes
  allow 30. gvenzl Free defaults to 4 GiB: a standalone container starts at 2 GiB, but in Kubernetes the 3.0 GiB
  7-Zip extraction plus the 1 GiB memory-backed `/dev/shm` was OOMKilled at 2 and 3 GiB.
- **Laptop profile**: still 2 workers/2 pods, sized for gvenzl Free (13 GiB Docker VM). The 19.3 image does not fit
  that profile; use the default profile on a machine with ~16 GB+ for Docker.
- **Not measured on Oracle**: memory (both runs were on a 47 GiB Docker VM without sampling; the preflight
  thresholds are estimates) and the row-count copy check (added after the runs). The README's Results table is the
  19.3 run.
- **Undo retention** is set in CDB$ROOT and again inside the PDB (`k8s/oracle/bootstrap.sh`): from RU 19.9 a PDB
  does not inherit it. The bootstrap runs once, at database creation; an existing cluster keeps its old setting.
- **Optimizer statistics**: the import excludes them (19c fails on three function-based index statistics), so the
  copy runs on dynamic sampling until Oracle's nightly job; a production copy should run
  `DBMS_STATS.GATHER_SCHEMA_STATS` before the flip.
- **Data Pump credentials**: `expdp`/`impdp` get `system/<password>` on their command line inside the Oracle pod
  (visible in its process list); production: a parfile or an Oracle wallet.
