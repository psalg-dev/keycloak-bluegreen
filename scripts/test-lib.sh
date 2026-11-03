#!/usr/bin/env bash
# Self-check for scripts/lib/kc.sh helpers that need no cluster.
set -euo pipefail
lib="$(cd "$(dirname "$0")" && pwd)/lib/kc.sh"
cd "$(mktemp -d)"
# shellcheck source=SCRIPTDIR/lib/kc.sh
. "$lib"

event switch from=blue to=green
event copy_point lsn=0/3000060
jq -s -e 'length == 2
  and .[0] == (.[0] | {t, event, from, to}) and .[0].from == "blue" and .[0].to == "green"
  and .[1].lsn == "0/3000060" and (.[1].t | test("^\\d{4}-\\d\\d-\\d\\dT[\\d:.]+Z$"))' out/events.jsonl >/dev/null \
  || { cat out/events.jsonl; echo "FAIL event()"; exit 1; }

[[ $(image_tag 26.8.1) == 26.8.1-p1 && $(image_tag 25.0.6 2) == 25.0.6-p2 ]] || { echo "FAIL image_tag"; exit 1; }
# profiles: default unchanged, laptop smaller, a typo dies when kc.sh is sourced (subshells: sourcing sets globals)
[[ $(PROFILE='' bash -c ". '$lib'; echo \$KC_REPLICAS \$PG_INSTANCES \$KIND_CONFIG \$LOGIN_RATE_DEFAULT")  == "3 3 kind/cluster.yaml 5" ]] \
  || { echo "FAIL default profile"; exit 1; }
[[ $(PROFILE=laptop bash -c ". '$lib'; echo \$KC_REPLICAS \$PG_INSTANCES \$KIND_CONFIG \$LOGIN_RATE_DEFAULT") == "2 2 kind/cluster-laptop.yaml 2" ]] \
  || { echo "FAIL laptop profile"; exit 1; }
if PROFILE=bogus bash -c ". '$lib'" 2>/dev/null; then echo "FAIL unknown PROFILE accepted"; exit 1; fi
# every script outside lib/ runs as a command (Jenkins, other scripts): committed 100755. Windows checkouts don't record
# chmod, so a new script lands 100644 and fails with exit 126 at its first call (purge-sessions.sh, laptop build #31)
noexec=$(git -C "$(dirname "$lib")/../.." ls-files -s 'scripts/*.sh' \
  | awk '$1 != "100755" && $4 !~ /\/lib(\/|\.sh$)/ {print $4}')
[[ -z $noexec ]] || { echo "FAIL not executable in git (git update-index --chmod=+x): $noexec"; exit 1; }
echo "OK test-lib"
