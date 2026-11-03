#!/usr/bin/env bash
# report.sh [out-dir]: every <out-dir>/<case>/ (cases.env order) -> <out-dir>/report.html, ONE self-contained page:
# Chart.js inlined (report/vendor, checksum-verified), the data as one embedded JSON blob, no fetches at view time.
# Aggregation in jq (report/report.jq: buckets, percentiles, histograms, failure modes), drawing in the browser.
# Per case dir: k6.jsonl (required; schema at the top of load/k6/flows.js), events.jsonl, gate.txt, apps.jsonl
# (testclient/testresource lines, docs/test-apps-contract.md), meta.json ({build, commit, url}), SYNTHETIC (its text
# is shown as a warning: the data is generated, not measured). Needs bash, jq, coreutils (launcher/Jenkins image).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source-path=SCRIPTDIR/..
. scripts/lib/kc.sh
TAG=report
out=${1:-out}
V=report/vendor
(cd "$V" && sha256sum -c chart.umd.min.js.sha256 >/dev/null) || die "$V/chart.umd.min.js does not match its checksum"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# One jq program: the gate's own definitions first (same rules, excuses, windows), then the report's aggregation.
cat scripts/gate/prelude.jq scripts/gate/apps.jq report/report.jq > "$tmp/report.jq"
n=0
while read -r c from to fp tp mech; do
  d=$out/$c
  [[ -f $d/k6.jsonl ]] || continue
  opt() { if [[ -f $d/$1 ]]; then echo "$d/$1"; else echo /dev/null; fi; }
  # apps logs may carry non-JSON lines (startup banner): keep only the contract's JSON lines
  jq -cR 'fromjson? | select(type == "object" and has("app"))' "$(opt apps.jsonl)" > "$tmp/apps.jsonl"
  syn=""; [[ ! -f $d/SYNTHETIC ]] || syn=$(cat "$d/SYNTHETIC")
  n=$((n + 1))
  jq -nc -f "$tmp/report.jq" --slurpfile k "$d/k6.jsonl" --slurpfile e "$(opt events.jsonl)" --slurpfile a "$tmp/apps.jsonl" \
    --arg mode "$mech" --argjson grace "${GATE_GRACE_SECONDS:-1}" \
    --slurpfile meta "$(opt meta.json)" --rawfile gate "$(opt gate.txt)" --arg case "$c" --arg from "$from" --arg to "$to" \
    --arg fp "$fp" --arg tp "$tp" --arg mech "$mech" --arg synthetic "$syn" > "$tmp/$(printf %03d $n).json"
  log "$c: $(wc -l < "$d/k6.jsonl") k6 lines${syn:+ (SYNTHETIC)}"
done < <(awk '!/^#/ && NF' cases.env)
((n)) || die "no <case>/k6.jsonl under '$out' for any case in cases.env"

# Markers sit alone on their template lines. `<` is escaped so no string in the data can close the <script>.
jq -sc --arg generated "$(date -u +%FT%TZ)" '{generated: $generated, cases: .}' "$tmp"/[0-9]*.json | sed 's/</\\u003c/g' > "$tmp/data"
while IFS= read -r line; do
  case $line in
    *'<!--CHARTJS-->'*) grep -v '^//# sourceMappingURL=' "$V/chart.umd.min.js" ;;
    *'<!--DATA-->'*) cat "$tmp/data" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < report/template.html > "$out/report.html"
log "$out/report.html: $n case(s), $(wc -c < "$out/report.html") bytes"
