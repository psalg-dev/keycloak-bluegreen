#!/usr/bin/env bash
# run.sh [probe...]: run the named probes (default: every scripts/security/probe-*.sh). Writes out/security/summary.txt
# (all result lines), junit.xml (one test per probe) and <probe>.log (stderr). Exits 1 if any probe FAILs.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=out/security
mkdir -p "$out"

probes=("$@")
if ((${#probes[@]} == 0)); then
  for f in scripts/security/probe-*.sh; do f=${f##*/probe-}; probes+=("${f%.sh}"); done
fi

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
: > "$out/summary.txt"
cases=() failures=0
for p in "${probes[@]}"; do
  start=$(date +%s) rc=0
  if [[ -f scripts/security/probe-$p.sh ]]; then
    bash "scripts/security/probe-$p.sh" 2> "$out/$p.log" > "$out/$p.out" || rc=$?
  else
    echo "FAIL $p: no such probe (scripts/security/probe-$p.sh)" > "$out/$p.out"; rc=1
  fi
  # A probe that died (set -e, tool error) without saying why still fails, with a pointer to its log.
  [[ $rc == 0 ]] || grep -q '^FAIL' "$out/$p.out" || echo "FAIL $p: probe exited $rc, see $out/$p.log: $(tail -1 "$out/$p.log")" >> "$out/$p.out"
  [[ -s $out/$p.out ]] || echo "FAIL $p: probe printed no result, see $out/$p.log" > "$out/$p.out"
  tee -a "$out/summary.txt" < "$out/$p.out"
  lines=$(esc < "$out/$p.out")
  case="<testcase classname=\"kc-security\" name=\"$p\" time=\"$(($(date +%s) - start))\">"
  if grep -q '^FAIL' "$out/$p.out"; then
    failures=$((failures + 1))
    case+="<failure message=\"$(grep -m1 '^FAIL' "$out/$p.out" | esc)\">$lines</failure>"
  fi
  cases+=("$case<system-out>$lines</system-out></testcase>")
done

{ echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"kc-security\" tests=\"${#probes[@]}\" failures=\"$failures\">"
  printf '%s\n' "${cases[@]}"
  echo '</testsuite>'; } > "$out/junit.xml"
echo "security probes: ${#probes[@]} run, $failures failed, $(grep -c '^WARN' "$out/summary.txt" || true) warnings" >&2
((failures == 0))
