# Results at a glance (2026-11-11)

Both engines, default profile, one machine, five cases each through Jenkins. Full detail:
[report-postgres.html](report-postgres.html), [report-oracle.html](report-oracle.html) (self-contained pages: download
and open), and the complete tables in [README.md](README.md#results).

**All ten gates PASS. 0 5xx / network errors in every case.**

| | Postgres (CloudNativePG) | Oracle 19.3 |
|---|---|---|
| builds | #16-#20, all on `f159cbe` | #9-#12 on `df36c1b`, #15 on `f505a83` |
| memory peak, KinD nodes / with Jenkins | 12.23 / 13.16 GiB | 13.19 / 14.71 GiB |

## Patch on a shared DB (`patch`, `patch-rollback`)

| | Postgres | Oracle |
|---|---|---|
| errors | 0 | 0 |
| sessions lost | 0 | 0 |
| users impacted (slow request only) | 0 of 847, 4 of 854 | 5 of 905, 4 of 892 |
| pod kill -> recovered | 43.1 s, 42.9 s | 43.8 s, 43.3 s |
| rollback | 0 s (Service flip) | 0 s (Service flip) |
| worst step-class p95 during the pod kill | introspection 2.2x | introspection 32.7x (`patch`), 5.6x (`patch-rollback`) |

Nothing is lost and nobody sees an error. This is the case to use whenever the schema does not change.

## Minor / major on a copied DB (`minor`, `major`, `minor-rollback`)

Ranges over the three lossy cases per engine.

| | Postgres | Oracle |
|---|---|---|
| lossy window (copy point -> switch) | 110-115 s | 124-142 s |
| sessions lost in the window | 254-265 | 286-315 |
| error rate, whole run | 0.17-0.35 % | 0.30-0.46 % |
| error rate, cutover window | 0.57-0.96 % | 0.68-0.91 % |
| users potentially impacted | 1.9-4.5 % | 3.6-4.8 % |
| resurrection window (switch -> replay done) | 39-40 s | 42-45 s |
| logouts / new users replayed (forward) | 14-16 / 40-50 | 18-21 / 54-71 |
| lossy rollback (start -> traffic on the old color) | 39.3 s | 40.4 s |
| extra sessions lost by the rollback (green-born) | 358 | 360 |
| users repaired (post-flip duplicate) | 1 (on the rollback) | 1 (on the rollback), 6 excused in `minor` |
| schema changesets | 211 -> 238 (minor), 134 -> 238 (major) | same |
| copy proven against the source | replica LSN >= copy LSN, 3 of 3 | row counts equal AS OF the copy SCN, 3 of 3 |

What the numbers mean:

- **Sessions lost is the price.** Every session created on the old color between the copy point and the flip does not
  exist on the new one. Each of those users logs in again the next time they come back: silently here (legacy SSO),
  visibly if their IdP session had expired. A lossy rollback throws away every session born on the new color on top.
- **What is not lost**: no session born before the copy point, on either engine; no logged-out session came back
  after the replay; no user's `sub` changed (repaired duplicates excepted, for seconds).
- **Login, token, refresh, logout, discovery, JWKS never stop.** Admin and account console answer 503 for the cutover
  window (about 155-190 s).
- The window is dominated by green's start and migration, not by the copy.

## Since these runs: replay from the database (branch `replay-db-diff`)

The numbers above were measured with the replay reading the event listener's log lines. On the branch
`replay-db-diff` the replay reads the old color's database instead (no log to lose). Postgres builds #21-#24:
`minor`, `major`, `minor-rollback` PASS, plus a run with planted sessions (logout and token revocation on each
color: 15 of 15 checks). Lossy window 115-135 s; the first replay pass took 15-21 s for 29-44 new users, the same
order as the log replay (15 s for 34). The lossy rollback took 56 s (39 s before); why was not investigated.
Oracle 19.3 builds #26-#28: `minor-rollback` (with the planted sessions, 15 of 15, twice) and `major` PASS. After
cutting the replay's round trips (#28): lossy window 128 s, lossy rollback 41 s, a replay pass 5 s for 53 users.
Postgres #30 with the admin token kept as well: lossy window 105 s, lossy rollback 20 s (39 s before), 15 of 15.
Details: [docs/production-readiness.md](docs/production-readiness.md) section 2.3.

## Caveats

- **One run per case.** Run-to-run spread is real: an earlier Postgres run the same day had lossy windows of
  119-170 s and a 65.5 s lossy rollback. Read ranges, not decimals.
- **A demo, not a production verdict.** Synthetic k6 load (2 logins/s), one machine, KinD. The lossy mechanism is
  demo-verified and **NO-GO for production** as it stands: [docs/production-readiness.md](docs/production-readiness.md).
- **The gate judges a sample.** k6 comes back to about ten sessions, so it observes 3-9 of the 250-315 lost ones.
  The loss count itself is from the event log, not from k6.
- **Not all engines ran the same commit.** Postgres ran the final code. Oracle `patch`, `minor`, `major`,
  `patch-rollback` ran before the k6 phase fix (`53ed6f1`) and the replay fix (`f505a83`); only Oracle
  `minor-rollback` (#15) ran with both.
- **The replay fix has one live exercise.** The path it repairs (a duplicate user repaired by the forward replay, then
  a rollback) occurred in Oracle #15 only; it did not occur on Postgres. There is no offline test for it or for the
  k6 phase fix.
- **`window_exercised` can still come up empty** if no rotating session is refreshed between the flip and
  switch + 5 s; the phase fix makes that unlikely, not impossible.
- **Oracle introspection latency during the pod kill** (32.7x pre-cutover p95 in `patch`, no errors, overall p95
  unchanged) was not investigated.
- **Oracle image**: `mohammedesafi/oracle-database:19.3.0-ee`, a community build of Oracle's official Dockerfiles, not
  an Oracle-supported production image. The gvenzl Free route and the laptop profile were not run on this tree.
- **Replayed users**: the same id, attributes and federated identity are checked; realm roles and groups carried by
  the replay were not verified in these runs.
- **Memory** is the peak of `docker stats` sampled every 15 s: short spikes can be higher.
