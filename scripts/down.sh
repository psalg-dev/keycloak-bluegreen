#!/usr/bin/env bash
# Delete the KinD cluster. Then `docker compose down -v` removes the network and kubeconfig volume.
set -euo pipefail
kind delete cluster --name kc
