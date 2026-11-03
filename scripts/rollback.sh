#!/usr/bin/env bash
# rollback.sh: flip back to the previous color while it is still running (switch-*.sh with KEEP_OLD=true keeps it up
# for the hold period). After the hold the old color is gone and, for minor/major, its DB is stale: fix forward.
#   shared DB (patch): just the flip back, nothing is lost.
#   own DB (minor/major): back to the old color AND its old DB (old schema; a migrated schema can't be downgraded).
#     Green's writes since the switch are lost, except logouts + user creations, which are reverse-replayed onto
#     blue (else a logout done on green comes back to life on blue). Admin/account are frozen meanwhile.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="deployment"
cur=$(state activeColor) curdb=$(state activeDb) curv=$(state version)
old=$(state previousColor) olddb=$(state previousDb) oldv=$(state previousVersion)
[[ -n $old ]] || die "no previous state in kc-state: nothing to roll back to"
ready=$(kubectl -n "$NS" get sts "kc-$old-keycloak" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
[[ ${ready:-0} -ge 2 ]] || die "kc-$old is not running (hold expired?): roll back = fix forward with a new switch"
event rollback_start reason="${REASON:-drill}" from="$cur" to="$old"

if [[ $curdb == "$olddb" ]]; then
  event rollback from="$cur" to="$old"
  set_active "$old" "$olddb" "$oldv"
  event flipped to="$old"
else
  # green had no traffic before the forward switch, so its replay lines start there
  since=$(jq -r 'select(.event == "switch") | .t' out/events.jsonl 2>/dev/null | tail -1)
  since=$(date -u -d "@$(( $(date -u -d "${since:-1 hour ago}" +%s) - 5 ))" +%FT%TZ)
  freeze
  event rollback_window_start
  scripts/replay.sh "$cur" "$old" "$since"
  event rollback from="$cur" to="$old"
  set_active "$old" "$olddb" "$oldv"
  event flipped to="$old"
  sleep "${DRAIN_SECONDS:-15}"
  scripts/replay.sh "$cur" "$old" "$since"
  event rollback_replay_done
  unfreeze
  event rollback_window_end
fi

sleep "${DRAIN_SECONDS:-15}"
save_logs "$cur"
kubectl -n "$NS" scale sts "kc-$cur-keycloak" --replicas=0 >/dev/null
event drained color="$cur"
log "rolled back $cur -> $old ($curv on $curdb -> $oldv on $olddb)"
