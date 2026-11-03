#!/usr/bin/env bash
# jenkins-build.sh <job> [PARAM=value...]: trigger a build on the compose Jenkins (http://127.0.0.1:8081), stream its
# console, exit 0 only if the build result is SUCCESS. Runs on the host (needs curl + jq), not in the launcher.
# ATTACH=<build url>: stream an already running build instead of triggering one (e.g. after a lost stream).
set -euo pipefail
cd "$(dirname "$0")/.."
job=${1:?job}; shift
J=${JENKINS_URL:-http://127.0.0.1:8081}
jar=$(mktemp); trap 'rm -f "$jar"' EXIT
c=(curl -sf -u "admin:$(cat out/jenkins-admin-password)" -b "$jar" -c "$jar")

if [[ -n ${ATTACH:-} ]]; then build=${ATTACH%/}/; else
  crumb=$("${c[@]}" "$J/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb')
  args=(); for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  queue=$("${c[@]}" -X POST -H "$crumb" "${args[@]}" -D - -o /dev/null "$J/job/$job/buildWithParameters" \
    | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')
  [[ -n $queue ]] || { echo "trigger failed" >&2; exit 1; }

  build=
  for _ in $(seq 120); do
    build=$("${c[@]}" "${queue}api/json" | jq -r '.executable.url // empty') && [[ -n $build ]] && break
    sleep 2
  done
  [[ -n $build ]] || { echo "build never left the queue: $queue" >&2; exit 1; }
fi
echo "build: $build"

offset=0 fails=0
while :; do
  # one failed request must not end the stream (build #11: it did, mid-run, and the script died on the next curl)
  if ! out=$("${c[@]}" -D "$jar.h" "${build}logText/progressiveText?start=$offset"); then
    ((++fails < 60)) || { echo "lost Jenkins for 5 min: $build" >&2; exit 1; }
    sleep 5; continue
  fi
  fails=0
  printf '%s' "$out"
  offset=$(tr -d '\r' < "$jar.h" | awk 'tolower($1) == "x-text-size:" {print $2}')
  tr -d '\r' < "$jar.h" | grep -qi '^x-more-data: true' || break
  sleep 5
done
for _ in $(seq 30); do result=$("${c[@]}" "${build}api/json" | jq -r .result) && break; sleep 2; done
echo "result: $result"
[[ $result == SUCCESS ]]
