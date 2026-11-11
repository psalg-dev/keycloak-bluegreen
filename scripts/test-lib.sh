#!/usr/bin/env bash
# Self-check for scripts/lib/kc.sh helpers that need no cluster.
set -euo pipefail
lib="$(cd "$(dirname "$0")" && pwd)/lib/kc.sh"
cd "$(mktemp -d)"
# shellcheck source=SCRIPTDIR/lib/kc.sh
. "$lib"

event switch from=blue to=green
event copy_point scn=2290580
jq -s -e 'length == 2
  and .[0] == (.[0] | {t, event, from, to}) and .[0].from == "blue" and .[0].to == "green"
  and .[1].scn == "2290580" and (.[1].t | test("^\\d{4}-\\d\\d-\\d\\dT[\\d:.]+Z$"))' out/events.jsonl >/dev/null \
  || { cat out/events.jsonl; echo "FAIL event()"; exit 1; }

[[ $(image_tag 26.8.1) == 26.8.1-p1 && $(image_tag 25.0.6 2) == 25.0.6-p2 ]] || { echo "FAIL image_tag"; exit 1; }
# profiles: default unchanged shape, laptop smaller, a typo dies when kc.sh is sourced (subshells: sourcing sets globals)
[[ $(PROFILE='' bash -c ". '$lib'; echo \$KC_REPLICAS \$PG_INSTANCES \$KIND_CONFIG \$LOGIN_RATE_DEFAULT")  == "3 3 kind/cluster.yaml 2" ]] \
  || { echo "FAIL default profile"; exit 1; }
[[ $(PROFILE=laptop bash -c ". '$lib'; echo \$KC_REPLICAS \$PG_INSTANCES \$KIND_CONFIG \$LOGIN_RATE_DEFAULT") == "2 2 kind/cluster-laptop.yaml 2" ]] \
  || { echo "FAIL laptop profile"; exit 1; }
if PROFILE=bogus bash -c ". '$lib'" 2>/dev/null; then echo "FAIL unknown PROFILE accepted"; exit 1; fi
# engines: postgres is the default; each names its first/next DB, build option and image tag; a typo dies
[[ $DB_ENGINE == postgres && $(db_first) == pg-1 && $(db_next pg-1) == pg-2 && $(build_opts 26) == *"--db=postgres"* ]] \
  || { echo "FAIL postgres engine"; exit 1; }
ora() { DB_ENGINE=oracle bash -c ". '$lib'; $1"; }
# shellcheck disable=SC2016 # the single-quoted snippets expand in ora's shell, on purpose
{
[[ $(ora 'echo $(db_first) $(db_next kc1) $(image_tag 26.8.1) $(db_schema kc12) $ORACLE_SID $ORACLE_MEMORY') == "kc1 kc2 26.8.1-p1-ora KC12 ORCLCDB 6Gi" ]] \
  || { echo "FAIL oracle engine"; exit 1; }
[[ $(ORACLE_IMAGE=gvenzl/oracle-free:23.26.3-slim ORACLE_SID='' ORACLE_MEMORY='' ora 'echo $ORACLE_SID $ORACLE_MEMORY') == "FREE 4Gi" ]] \
  || { echo "FAIL oracle-free defaults (empty env from compose must not win)"; exit 1; }
[[ $(ora 'build_opts 25') == *"--db=oracle"* ]] || { echo "FAIL oracle build_opts"; exit 1; }
if ora "db_schema 'kc1;drop'" 2>/dev/null; then echo "FAIL db_schema accepted injection"; exit 1; fi
[[ -n $(PROFILE=laptop ora db_preflight) && -z $(PROFILE=laptop ORACLE_IMAGE=gvenzl/oracle-free:23.26.3-slim ora db_preflight) ]] \
  || { echo "FAIL oracle laptop preflight"; exit 1; }
}
if DB_ENGINE=bogus bash -c ". '$lib'" 2>/dev/null; then echo "FAIL unknown DB_ENGINE accepted"; exit 1; fi
# every script outside lib/ runs as a command (Jenkins, other scripts): committed 100755. Windows checkouts don't record
# chmod, so a new script lands 100644 and fails with exit 126 at its first call (purge-sessions.sh, laptop build #31)
noexec=$(git -C "$(dirname "$lib")/../.." ls-files -s 'scripts/*.sh' 'oracle/*.sh' \
  | awk '$1 != "100755" && $4 !~ /\/lib(\/|\.sh$)/ && $4 != "oracle/db.sh" {print $4}')
[[ -z $noexec ]] || { echo "FAIL not executable in git (git update-index --chmod=+x): $noexec"; exit 1; }
echo "OK test-lib"
