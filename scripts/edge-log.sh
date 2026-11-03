#!/usr/bin/env bash
# edge-log.sh: what the EDGE saw, parsed from the ingress-nginx access log.
# The k6 client only knows the requests it sent; this knows every request, and which pod
# served it - so it gives the real switch moment, the drain curve and 5xx from all clients.
#
# usage: edge-log.sh [--since 10m|RFC3339] [--summary]
#   default  : one JSON line per request  {t,method,path,status,up,ust,rt,urt}
#   --summary: totals, 5xx list, per-upstream first/last (the switch timeline)
set -euo pipefail
cd "$(dirname "$0")/.."

SINCE=15m
SUMMARY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --since) SINCE=${2:?}; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    *) echo "usage: $0 [--since 10m|RFC3339] [--summary]" >&2; exit 2 ;;
  esac
done

if [[ $SINCE =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  logs=$(kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --since-time "$SINCE" 2>/dev/null)
else
  logs=$(kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --since "$SINCE" 2>/dev/null)
fi

parse() {
  # Combined log format: ... "REQUEST" STATUS BYTES "REFERER" "UA" $request_length $request_time
  #   [$proxy_upstream_name] [$alternative] $upstream_addr $upstream_response_length
  #   $upstream_response_time $upstream_status $req_id
  # Splitting on double quotes avoids every field-boundary ambiguity (paths may contain spaces' friends).
  awk '
    BEGIN { m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04"; m["May"]="05"; m["Jun"]="06";
            m["Jul"]="07"; m["Aug"]="08"; m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12" }
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function num(s) { return (s ~ /^[0-9.]+$/) ? s : "null" }
    {
      n = split($0, q, "\"")
      if (n < 7) next
      ts = q[1]; sub(/^.*\[/, "", ts); sub(/\].*$/, "", ts)   # 02/Nov/2026:21:55:10 +0000
      split(ts, t, /[\/: ]/)                                   # 02 Nov 2026 21 55 10 +0000
      if (!(t[2] in m)) next
      iso = t[3] "-" m[t[2]] "-" t[1] "T" t[4] ":" t[5] ":" t[6] "Z"
      split(q[2], r, " ")
      split(q[3], s, " ")
      split(q[7], f, " ")
      up = f[5]; sub(/,.*/, "", up)                            # retries: keep the pod that answered
      printf "{\"t\":\"%s\",\"method\":\"%s\",\"path\":\"%s\",\"status\":%d,\"up\":\"%s\",\"ust\":%s,\"rt\":%s,\"urt\":%s}\n",
        iso, r[1], jesc(r[2]), s[1], jesc(up), num(f[8]), num(f[2]), num(f[7])
    }'
}

if [[ $SUMMARY == 1 ]]; then
  json=$(parse <<<"$logs" | jq -s .)
  jq -r '
    "requests: \(length)",
    "by status: \(group_by(.status) | map("\(.[0].status)x\(length)") | join(" "))",
    "",
    "5xx (edge status or upstream status):",
    ( [ .[] | select(.status >= 500 or (.ust // 0) >= 500) | "  \(.t) \(.method) \(.path) -> \(.status) upstream=\(.up) \(.ust)" ] | if length == 0 then "  none" else .[] end ),
    "",
    "per upstream pod (first/last request it served):",
    ( group_by(.up) | sort_by(.[0].t) | .[] |
      "  \(.[0].up)  n=\(length)  first=\(.[0].t)  last=\(.[-1].t)" ),
    "",
    "last request: \(.[-1].t)",
    "first request: \(.[0].t)"
  ' <<<"$json"
  exit 0
fi

parse <<<"$logs"
