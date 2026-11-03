#!/usr/bin/env bash
# test-demo.sh: renders every phase header of every case under `set -euo pipefail`, without a cluster.
# Build #9 died in a header (a false [[ ]] inside $(...) failed the assignment) only for non-rollback cases.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/lib/kc.sh
. scripts/lib/kc.sh
phases=(reset install warmup switch rollback cooldown gate)
eval "$(sed -n '/^phase_tag() {/,/^}/p;/^explain() {/,/^}/p' scripts/demo.sh)"
mapfile -t cases < <(awk '!/^#/ && NF {print $1}' cases.env)
for what in "${cases[@]}"; do
  read -r _ from to fp tp mech < <(awk -v c="$what" '$1 == c' cases.env)
  for p in "${phases[@]}"; do phase_tag "$p"; explain "$p" >/dev/null 2>&1; done
done
# shellcheck disable=SC2034 # from/to/fp/tp/mech are read by the eval'd explain()
echo "OK test-demo: ${#phases[@]} headers x ${#cases[@]} cases"
