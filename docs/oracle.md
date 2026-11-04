# Oracle 19c instead of Postgres: route, tools, zero-downtime analysis

Branch `oracle-19c`. This replaces the demo's database engine; the Keycloak blue/green
contract, load, gate and report stay. The short version:

- **The runnable demo uses Oracle Database 23ai Free by default**, because Oracle 19c has
  no free Express Edition (18c and 21c XE exist; 19c does not) and the 19.3 EE image is on
  Oracle Container Registry behind an Oracle SSO login. The SQL, JDBC driver, schema
  handling and Data Pump cutover are 19.3-compatible; set `ORACLE_IMAGE` to the 19.3 image
  for the production target. This is the one factor adjusted to keep the demo runnable.
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
and `window_exercised` rules are unchanged, and `db_copy_caught_up` now checks that the
green copy's SCN is at least the declared copy point.

### Why Data Pump and not something else

| Route | Works with 19.3? | Zero login/token downtime? | Why not the default here |
|---|---|---|---|
| **Data Pump at SCN + replay** | yes (EE/SE2 and Free) | yes, lossy window as above | portable, one instance, uses the demo's existing replay; chosen |
| Refreshable PDB clone | yes (19c EE, same CDB) | yes, same lossy window | faster copy, but same-CDB/PDB prerequisites and a second PDB (Free allows one); a production optimisation, not the portable default |
| Oracle Data Guard physical standby | yes (19c EE) | standby is read-only; cannot run green's Liquibase migration | switchover + migration = write freeze; not a blue/green app upgrade tool |
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
- Gate: `db_copy_caught_up` (new) + the existing lossy rules.
- `out/events.jsonl` retains the same event names the report consumes (`copy_point`,
  `promoted`, `migration`, `switch`, `replay*`), so the report and gate do not fork.
- For production Oracle: AWR/Statspack, `V$SESSION`, `V$SYSTEM_EVENT`, Data Guard broker,
  RMAN backups. The demo does not collect these; `docs/production-readiness.md` describes
  the gap.

## Running it

### Default: 23ai Free, no registry login

```bash
bash scripts/jenkins-secret.sh
docker compose run --rm launcher          # creates KinD + Oracle + kc1 + blue
docker compose up -d jenkins
# Jenkins: CASE=patch|minor|major, as on main
```

The first `up.sh` creates the Oracle database; it takes a few minutes (19c EE can take ~10).
`reset.sh` only drops/recreates schemas, so later cases are fast. Oracle is a 4 GiB instance;
give Docker 15 GiB (13 GiB for `PROFILE=laptop`).

### 19.3 EE (the production target)

```bash
docker login container-registry.oracle.com   # Oracle SSO account
export ORACLE_IMAGE=container-registry.oracle.com/database/enterprise:19.3.0.0
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
export ORACLE_PULL_SECRET=oracle-regcred
docker compose run --rm launcher
```

The template sets `ORACLE_SID=ORCLCDB`, `ORACLE_PDB=FREEPDB1`, and both `ORACLE_PWD` and
`ORACLE_PASSWORD`; the official image and the gvenzl Free image each read their own name.
The bootstrap script is mounted at both `/container-entrypoint-initdb.d` (gvenzl) and
`/opt/oracle/scripts/setup` (official). `ORACLE_IMAGE` also selects the SID if you use a
different image name; set `ORACLE_SID` explicitly if the image does not contain
`oracle-free`/`oracle-xe` but is not a CDB with `ORCLCDB`.

## Validation done on this branch (2026-11-04)

**Full five-case Jenkins/KinD run on Oracle 23ai Free, all gates PASS:**

| Jenkins build | case | gate |
|---|---|---|
| #2 | `patch` (26.8.0 -> 26.8.1, shared) | `GATE PASS (shared)` |
| #4 | `minor` (26.7.5 -> 26.8.1, Data Pump) | `GATE PASS (lossy)` |
| #6 | `major` (25.0.6 -> 26.8.1, Data Pump) | `GATE PASS (lossy)` |
| #7 | `patch-rollback` | `GATE PASS (shared-rollback)` |
| #9 | `minor-rollback` | `GATE PASS (lossy-rollback)` |

The run used the Bitnami chart in KinD, `kc.sh start --optimized`, the 4 GiB Oracle StatefulSet, 3 Keycloak pods per
color, and the same k6/apps/gate/report path as `main`. The report is `out/oracle-run/report.html` (gitignored; Jenkins
archives it). Headline: 0 5xx in every case; `minor` 4 sessions lost with 4 silent re-logins; `major` 5/5; both Data
Pump copies caught up to the declared SCN; changesets 211 -> 238 (minor) and 134 -> 238 (major).

Component checks behind it:

- `docker build` of `images/keycloak/Dockerfile` with `KC_VERSION=26.8.1` and the Oracle JDBC jars:
  `Installed features: [... jdbc-oracle ...]`, `kc.sh build --db=oracle` succeeded. The same build with
  `KC_VERSION=25.0.6` (`--features=persistent-user-sessions`) also succeeded and created 134 changesets on
  Oracle with Keycloak 25.0.6.
- Keycloak 26.8.1 started against `gvenzl/oracle-free:23.26.3-slim` (Oracle AI Database
  26ai Free 23.26.3, the 23.x line) with `KC_DB_SCHEMA=KC1`: Liquibase created 102 tables and 237
  changesets; JGroups `jdbc-ping` formed a cluster on Oracle; `/realms/master` answered 200.
- Data Pump: `expdp SCHEMAS=KC1 FLASHBACK_SCN=<scn>` exported the full Keycloak schema; `impdp
  REMAP_SCHEMA=KC1:KC2 EXCLUDE=USER` imported it; green migrated it. The full-run copy took ~40-60 s
  for the export and ~20-90 s for the import on this machine.
- The Oracle Free container starts standalone under 2 GiB, but the in-cluster first start is OOMKilled
  at 2 GiB and 3 GiB: the 3.0 GiB 7-Zip extraction plus the 1 GiB memory-backed `/dev/shm` needs 4 GiB.
  4 GiB is the default `ORACLE_MEMORY`; `oracle-7z` completed at 4 GiB.
- Fixes found by the full run: `EXCLUDE=USER` on the import (target user is pre-created), `kc2` not `kc-2`
  as the next schema name, the Keycloak 25 overlay must repeat `KC_DB`/`KC_DB_URL` (Helm replaces
  `extraEnvVars`), SQL*Plus needs a statement terminator before `exit`, schema drop must kill sessions and
  retry, and the readiness probe needs a 5 s timeout (the 1 s default removed all endpoints during a
  337-session purge).

Not validated: 19.3 EE image startup (the Oracle registry returned `unauthorized`; no Oracle SSO
credentials were available on this machine), Data Guard/RAC, RMAN/PITR, and a 19.3-specific
refreshable-PDB path. The `helm template` render was checked for `KC_DB_URL`/`KC_DB`/`KC_DB_SCHEMA`.

## Limits

- **One Oracle instance in KinD.** No Data Guard, RAC cluster or zone-redundant DB. A DB
  instance failure is a demo outage; the upgrade cases do not exercise it. Production 19c
  should use Data Guard/RAC and backups; the app-level blue/green mechanism is independent
  of that.
- **Data Pump is a logical copy.** It needs undo retention for the SCN export and time
  proportional to schema size. The demo's schema is small; a large production realm should
  use a refreshable PDB clone (same CDB) or a pre-created copy.
- **`ORACLE_IMAGE` default is 23ai Free**, not 19.3, for the reason at the top. The
  compatibility claim is about the Keycloak/Liquibase/Data Pump path, not a claim that the
  Free image is 19c.
- **Oracle Free data cap**: 23ai Free is limited (12 GB user data); the demo's 4000 users are
  far below it. 19c EE has no such cap.
- **Keycloak 25**: Oracle support is via `--db=oracle`, `persistent-user-sessions`; the
  `jdbc-ping` Oracle fix is a 26.x change, so 25 keeps `cache-stack=kubernetes`.
- **Oracle memory.** The default is a 4 GiB container. A standalone container starts at 2 GiB, but in
  Kubernetes the first-start 7-Zip extraction of the 3.0 GiB database archive plus the 1 GiB memory-backed
  `/dev/shm` was OOMKilled at 2 GiB and 3 GiB; 4 GiB is the tested in-cluster default. 19.3 EE has a
  larger footprint; if it fails to start, set `ORACLE_MEMORY=5Gi` and (for 19c) `ORACLE_SGA_MB=1536` /
  `ORACLE_PGA_MB=768`. The preflight memory requirement goes up accordingly.
- **Laptop profile**: still 2 workers/2 pods, but Oracle needs 4 GiB; give Docker 13 GiB, not
  the 10 GiB used by the Postgres laptop profile.
- **No measured Oracle results yet.** The README's Results table is the Postgres baseline
  from `main`; do not quote it as Oracle numbers. Run the five cases on this branch to
  produce the Oracle table.
