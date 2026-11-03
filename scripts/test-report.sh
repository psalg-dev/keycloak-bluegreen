#!/usr/bin/env bash
# test-report.sh [out-dir]: runs scripts/report.sh and checks the page: it exists, embeds valid JSON with one case
# (= one tab) per <out-dir>/<case>/k6.jsonl in cases.env order, references no external src/href URL, and every case's
# failure-mode table lists exactly the contract ids (docs/test-apps-contract.md), in contract order.
# Without an argument it builds its input from the gate fixtures (load/fixtures) in a temp dir, so it runs anywhere;
# with one (e.g. out/samples) it judges that dir's real/synthetic runs.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="test"

if [[ -n ${1:-} ]]; then
  dir=$1
else
  dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
  F=load/fixtures
  # case | gate mode | k6 fragments | events
  while IFS='|' read -r c mode frags events; do
    mkdir -p "$dir/$c"
    for f in $frags; do cat "$F/$f.k6.jsonl"; done > "$dir/$c/k6.jsonl"
    cp "$F/$events.events.jsonl" "$dir/$c/events.jsonl"
    scripts/gate.sh "$mode" "$dir/$c/k6.jsonl" "$dir/$c/events.jsonl" > "$dir/$c/gate.txt" 2>/dev/null || true
  done <<'EOF'
patch|shared|shared-base shared-inflight-ok|shared
patch-rollback|shared-rollback|shared-rb-base shared-rb-inflight|shared-rollback
minor|lossy|lossy-base|lossy
minor-rollback|lossy-rollback|lossy-rb-base|lossy-rollback
EOF
fi

bad=0
# check <name> <command...>: one ok/FAIL line per assertion
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; bad=$((bad + 1)); fi; }
data() { jq -e "$@" <<<"$json" >/dev/null; } # data <jq filter> [jq args]: true when the filter yields true
no_url() { ! grep -Eiq "$1" "$html"; }

scripts/report.sh "$dir"
html=$dir/report.html
json=$(sed -n '/<script id="data" type="application\/json">/{n;p;q;}' "$html")
want=$(awk '!/^#/ && NF {print $1}' cases.env | while read -r c; do [[ ! -f $dir/$c/k6.jsonl ]] || echo "$c"; done | jq -Rsc 'split("\n") | map(select(. != ""))')
ids=$(awk '/^## Failure modes/ {on = 1} on && /^\| `[a-z0-9_]+` \|/ {gsub(/[|` ]/, "", $2); print $2}' docs/test-apps-contract.md | jq -Rsc 'split("\n") | map(select(. != ""))')

# shellcheck disable=SC2016 # jq variables
{
check "report.html exists and is not empty" test -s "$html"
check "embedded data is valid JSON" data .cases
check "one tab (case) per case dir, cases.env order: $want" data --argjson w "$want" '[.cases[].case] == $w'
check "no external src=/href= URL" no_url "(src|href)=[\"']?(https?:)?//"
check "no external @import/url()" no_url "@import|url\([\"']?(https?:)?//"
check "Chart.js inlined" grep -q "Chart.js v4" "$html"
check "contract has 16 failure-mode ids" jq -e 'length == 16' <<<"$ids"
check "every case: failure-mode table = contract ids, in order" data --argjson ids "$ids" '[.cases[] | [.modes[].id] == $ids] | all'
check "no data -> 'nodata' verdict, never a 0 rate" data '[.cases[].modes[] | (.attempts // 0) > 0 or (.verdict == "nodata" and .rate == null)] | all'
check "every case has a gate verdict and time series" data '[.cases[] | .gate.verdict != null and .series != null] | all'
}

((bad == 0)) || die "$bad check(s) failed"
log "all checks passed ($(wc -c < "$html") bytes, $(jq '.cases | length' <<<"$json") cases)"
