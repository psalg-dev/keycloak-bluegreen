# Load-rate baseline

Baseline: **about 10 000 k6 lines per case** on both profiles, so a five-case run stays short (collection, gate and
report all scale with the line count). Windows, thresholds and bounds are in
[docs/failure-modes.md](../docs/failure-modes.md).

The rate is the same for every case on purpose: patch, the rollbacks and the lossy cases must be comparable.

## Rates

Set in `scripts/lib/kc.sh` (per `PROFILE`), `scripts/load.sh` and `load/k6/flows.js`.

| scenario | default + laptop | executor |
|---|---|---|
| `login` | 2/s | constant arrival, preAllocated VUs = rate x 25 |
| `refresh` | 10 VUs, one refresh per 5 s | constant VUs |
| `logout` | 4 VUs, one logout per ~45 s | constant VUs |
| `app` | 3 VUs | constant VUs |
| `reads` | 1/s per network | constant arrival |

## Measured request counts

| rate | profile | per case | notes |
|---|---|---|---|
| 2 logins/s, 10/4/3 VUs | default + laptop | ~10 000-20 000 | this baseline |
| 5 logins/s, 10/4/6 VUs | default | 29 059-69 258 | earlier runs, builds #33-#37 |
| 18 logins/s, 36/14/22 VUs | default | 106 171 (`patch`) | build #41, passed after the legacy IdP got 1.5 GiB; too slow per run to keep |

The wall clock is dominated by the fixed phases (install ~4 min, switch 1-3 min, soak/cool-down), not by the rate:
cutting the rate mainly shrinks collection, the gate (`~1 min per 100 000 lines`) and the report.

## CPU headroom

Slice 4's bar: Keycloak CPU stays comfortably below its capacity at this rate, so an overload 5xx cannot pose as a
switch failure. Measured per pod with `scripts/mem-sample.sh` (`mcpu`, kubelet summary API, every 15 s).

At 18 logins/s (build #41) the busiest Keycloak pod used ~3.2 cores, the legacy IdP ~3.2 cores (it OOM-killed at
768Mi until the stand-in got 1.5 GiB and 65% heap); the pods have no CPU limit, the host has 32 cores. At 2 logins/s
the same pods stay around 0.3-0.6 cores, so this baseline leaves large headroom.
