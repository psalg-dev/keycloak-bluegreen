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
# replay_session_diff (limit 100): gone = logged out on the source; rev = its client session c2 revoked there;
# born = made by the target after the limit (never touched); newcs = target-made client session on a copied session
# (forward: ignored, reverse: counts); keep = same on both sides
printf '%s\n' 'gone|50' 'rev|60' 'born|150' 'newcs|70' 'keep|80' > to_us
printf '%s\n' 'rev|60' 'newcs|70' 'keep|80' > from_us
printf '%s\n' 'gone|c1|50' 'rev|c1|60' 'rev|c2|60' 'born|c1|150' 'newcs|c1|70' 'newcs|c2|120' 'keep|c1|90' > to_cs
printf '%s\n' 'rev|c1|60' 'newcs|c1|70' 'keep|c1|200' > from_cs
[[ $(replay_session_diff to_us from_us to_cs from_cs 100 0 | xargs) == "gone rev" ]] || { echo "FAIL replay_session_diff forward"; exit 1; }
[[ $(replay_session_diff to_us from_us to_cs from_cs 100 1 | xargs) == "gone newcs rev" ]] || { echo "FAIL replay_session_diff reverse"; exit 1; }
: > empty
if (replay_session_diff to_us empty to_cs empty 100 0) >/dev/null 2>&1; then echo "FAIL replay_session_diff accepted an empty source"; exit 1; fi
[[ -z $(replay_session_diff empty empty empty empty 100 0) ]] || { echo "FAIL replay_session_diff on nothing"; exit 1; }
seq 100 | sed 's/$/|50/' > many_us; head -30 many_us > part_us
if (replay_session_diff many_us part_us empty empty 100 0) >/dev/null 2>&1; then echo "FAIL replay_session_diff accepted 70 % deletes"; exit 1; fi
[[ $(REPLAY_MAX_DELETE_PCT=80 replay_session_diff many_us part_us empty empty 100 0 | wc -l) -eq 70 ]] || { echo "FAIL REPLAY_MAX_DELETE_PCT"; exit 1; }
# every script outside lib/ runs as a command (Jenkins, other scripts): committed 100755. Windows checkouts don't record
# chmod, so a new script lands 100644 and fails with exit 126 at its first call (purge-sessions.sh, laptop build #31)
noexec=$(git -C "$(dirname "$lib")/../.." ls-files -s 'scripts/*.sh' 'oracle/*.sh' \
  | awk '$1 != "100755" && $4 !~ /\/lib(\/|\.sh$)/ && $4 != "oracle/db.sh" {print $4}')
[[ -z $noexec ]] || { echo "FAIL not executable in git (git update-index --chmod=+x): $noexec"; exit 1; }
echo "OK test-lib"
