#!/usr/bin/env bash
# Every launcher command starts connected to the kind cluster (if it exists yet).
set -e
cd /repo
. scripts/lib/kc.sh
kube_connect
exec "$@"
