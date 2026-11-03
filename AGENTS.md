# AGENTS.md - setting this demo up

This repo runs a blue/green Keycloak upgrade demo on one machine: KinD, Postgres, Jenkins, k6. Bring it up, run one
case, judge it. Do the steps in order; each ends with a check that tells you it is done. The design, the mechanisms
and the known limits are in README.md, PLAN.md and docs/failure-modes.md; this file only covers getting it running.

## 1. Check the machine

```bash
bash scripts/preflight.sh
```

Done when it prints `preflight passed`. On failure it names the problem and stops: a busy port 443 (kind) or 8081
(Jenkins), Docker's VM memory below the profile's peak, a missing host tool, or `*.localtest.me` not resolving to
127.0.0.1. Fix the machine; a workaround here fails later, deeper, and slower.

Windows: run everything from Git Bash. `bash` on PATH may be WSL's (`C:\Windows\system32\bash.exe`), which has no `jq`.

## 2. Bring the platform up (once per machine; the first run builds images, ~15 min)

```bash
bash scripts/jenkins-secret.sh
docker compose run --rm launcher
docker compose up -d jenkins
```

`up.sh` runs preflight, then creates the cluster (1 control plane + 3 workers), ingress-nginx, CloudNativePG, pg-1,
the legacy IdP, the two test apps and a first blue Keycloak. On a 16 GB machine use `PROFILE=laptop` on every command.

Done when `docker compose run --rm launcher bash scripts/check-cluster.sh blue` passes and http://localhost:8081
answers (user `admin`, password in `out/jenkins-admin-password`).

## 3. Run a case

Commit first: Jenkins checks out `file:///repo` at build start, so uncommitted edits do not run.

```bash
bash scripts/jenkins-build.sh kc-bluegreen CASE=patch      # streams the console; exit 0 = GATE PASS
bash scripts/jenkins-build.sh kc-bluegreen CASE=minor
```

Or all five back to back: `docker compose run --rm launcher bash scripts/demo.sh all`. One case takes ~12-15 min.
Done when the console ends with `GATE PASS (<mode>)`; a FAIL is a finding, not a flake - read `out/<case>/gate.txt`
against docs/failure-modes.md before touching a threshold.

Run one case at a time: the cluster is a single shared resource, and a second run resets the first one's state.

## 4. Read the result

- `out/report.html` (`bash scripts/report.sh`): one tab per case, the data baseline, users impacted, network latency
  and errors over the run, and the failure-mode table.
- `out/<case>/gate.txt`: the rule-by-rule verdict; `k6.jsonl`, `apps.jsonl`, `events.jsonl` are the raw measurements.

A Jenkins build archives the same directory and rebuilds the report in its post step.

## 5. Offline checks (no cluster)

```bash
bash scripts/test-lib.sh && bash scripts/test-demo.sh && bash scripts/test-gate.sh && bash scripts/test-report.sh
shellcheck -x scripts/*.sh scripts/lib/kc.sh scripts/security/*.sh
```

Done when every script prints `ok`/`passed` and shellcheck is silent. `test-gate.sh` takes ~4 min; the CI workflow
(`.github/workflows/checks.yml`) runs the same set.

## Rules that keep the demo honest

- `PROFILE` must match the cluster it runs against; `up.sh` refuses a mismatch instead of corrupting state.
- The kind kubeconfig lives in the compose `kube` volume (shared by the launcher and Jenkins), not in your host
  `~/.kube`: reach the cluster with `docker exec kc-bluegreen-jenkins-1 kubectl ...` or a launcher command.
- Never run `kc.sh` subcommands (or `update-compatibility`) inside a live Keycloak pod: it re-augments the pod's build.
- `out/` is gitignored (secrets, certs, runs). Commit with explicit paths.
- Where things are defined: README.md (run and results), PLAN.md (design and known limits), docs/failure-modes.md
  (every mode, window and bound), load/RATE.md (load baseline), docs/production-readiness.md (what production needs).
