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
  export GATE_MAX_GAP_SECONDS=60 # sparse fixtures, as in test-gate.sh
  # case | gate mode | fragments (<f>.k6.jsonl and/or <f>.apps.jsonl, as in test-gate.sh) | events
  # patch: app- and Keycloak-initiated logouts, all PASS (app-initiated fc with found_session false is no failure);
  # minor: lossy excuses (lossok) for app- and Keycloak-initiated logouts; major: gate FAILs (probe after replay, bc
  # logout missing, app login across the switch event without a flipped event) the report must show as over bound.
  while IFS='|' read -r c mode frags events; do
    mkdir -p "$dir/$c"
    for f in $frags; do [[ ! -f $F/$f.k6.jsonl ]] || cat "$F/$f.k6.jsonl"; done > "$dir/$c/k6.jsonl"
    for f in $frags; do [[ ! -f $F/$f.apps.jsonl ]] || cat "$F/$f.apps.jsonl"; done > "$dir/$c/apps.jsonl"
    cp "$F/$events.events.jsonl" "$dir/$c/events.jsonl"
    scripts/gate.sh "$mode" "$dir/$c/k6.jsonl" "$dir/$c/events.jsonl" "$dir/$c/apps.jsonl" > "$dir/$c/gate.txt" 2>/dev/null || true
  done <<'EOF'
patch|shared|shared-base shared-inflight-ok app-shared app-shared-log app-bc app-fc app-fc-event app-kc app-kc-bc-ok app-kc-fc-ok|shared
patch-rollback|shared-rollback|shared-rb-base shared-rb-inflight|shared-rollback
minor|lossy|lossy-base app-lossy app-lossy-bc app-lossy-kc|lossy
major|lossy|lossy-base lossy-probe-ok app-lossy app-lossy-flip|lossy
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
check "every failure-mode id has a one-line explainer (report/modes.tsv)" data '(([.cases[].modes[].id] | unique) - [.modes[] | select(.why != null and (.why | length) > 15) | .id]) | length == 0'
check "no data -> 'nodata' verdict, never a 0 rate" data '[.cases[].modes[] | (.attempts // 0) > 0 or (.verdict == "nodata" and .rate == null)] | all'
check "every case has a gate verdict and time series" data '[.cases[] | .gate.verdict != null and .series != null] | all'
# Report and gate never disagree: the report recomputes each gate rule a mode names with the gate's own defs.
# (1) every named rule is a row of the case's gate.txt with the same state; (2) a mode is "over bound" only if a rule it
# names FAILed; (3) every FAILed rule makes a mode naming it "over bound" (or "not measured": nothing to judge).
check "every rule a mode names is a gate row with the same state" data '[.cases[] | (.gate.rules | map({key: .rule, value: .state}) | from_entries) as $g
  | .modes[].own[] | $g[.rule] == .state] | all'
check "a mode is over bound only if a gate rule it names FAILed" data '[.cases[].modes[] | select(.verdict == "fail") | any(.own[]; .state == "FAIL")] | all'
check "every FAILed rule a mode names puts such a mode over bound" data '[.cases[] | .modes as $m | ([$m[].own[].rule] | unique) as $named
  | .gate.rules[] | select(.state == "FAIL" and (.rule | IN($named[]))) | .rule as $r | any($m[]; (.rules | index($r)) != null and (.verdict == "fail" or .verdict == "nodata"))] | all'
check "latency_regression: the report's count = the classes the gate's INFO row lists (one definition, apps.jq)" data '[.cases[]
  | ([.gate.rules[] | select(.rule == "latency_regression" and .state == "INFO") | .detail] | .[0]) as $d
  | ([.modes[] | select(.id == "latency_regression") | .count] | .[0]) as $c
  | $d == null or (if ($d | startswith("none")) then $c == 0 else ($d | capture("\\((?<k>[0-9]+) of ").k | tonumber) == $c end)] | all'
[[ -n ${1:-} ]] || check "fixtures exercise it: the major case has over-bound modes" data '[.cases[] | select(.case == "major") | .modes[] | select(.verdict == "fail")] | length >= 3'
check "found_session false on app-initiated fc logouts is no failure (patch)" data '.cases[] | select(.case == "patch") | .modes[] | select(.id == "frontchannel_failed") | .verdict == "ok"'
check "excused lossy logouts are expected, not over bound (minor)" data '.cases[] | select(.case == "minor") | [.modes[] | select(.id == "backchannel_missing" or .id == "frontchannel_failed" or .id == "logout_not_effective") | .verdict] | all(. == "expected")'
}

((bad == 0)) || die "$bad check(s) failed"
log "all checks passed ($(wc -c < "$html") bytes, $(jq '.cases | length' <<<"$json") cases)"
