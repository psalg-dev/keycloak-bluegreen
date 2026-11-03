# Load-rate baseline

Target: **at least 100 000 k6 requests per case** on the default profile, so the p95s and failure-mode rates in the
report rest on a stable sample. Windows, thresholds and bounds are in [docs/failure-modes.md](../docs/failure-modes.md).

The rate is the same for every case on purpose: patch, the rollbacks and the lossy cases must be comparable.

## Rates

Set in `scripts/lib/kc.sh` (per `PROFILE`), `scripts/load.sh` and `load/k6/flows.js`.

| scenario | default | laptop | executor |
|---|---|---|---|
| `login` | 18/s | 6/s | constant arrival, preAllocated VUs = rate x 25 |
| `refresh` | 36 VUs, one refresh per 5 s | 36 VUs | constant VUs |
| `logout` | 14 VUs, one logout per ~45 s | 14 VUs | constant VUs |
| `app` | 22 VUs | 8 VUs | constant VUs |
| `reads` | 1/s per network | same | constant arrival |

## Measured request counts

Old baseline (5 logins/s, 10/4/6 VUs), builds #33-#37 at commit `f3d94e3`: 68-71 k6 requests/s, per case 29 059
(`patch`), 32 199 (`patch-rollback`), 53 352 (`minor`), 69 258 (`minor-rollback`), 56 763 (`major`).

Current baseline: see the Results table in [README.md](../README.md).

## CPU headroom

Slice 4's bar: Keycloak CPU stays below ~60% of its limit at this rate, so an overload 5xx cannot pose as a switch
failure. Measured per pod with `scripts/mem-sample.sh` (`mcpu` field, kubelet summary API, every 15 s) during the
2026-11-03 runs.
