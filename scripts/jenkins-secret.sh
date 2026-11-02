#!/usr/bin/env bash
# Generate the Jenkins admin password once (out/ is gitignored). Run before `docker compose up jenkins`.
set -euo pipefail
cd "$(dirname "$0")/.."
f=out/jenkins-admin-password
if [ ! -s "$f" ]; then
  mkdir -p out
  # no trailing newline in the secret; \r too, since Git Bash's openssl prints CRLF
  (umask 077; openssl rand -hex 16 | tr -d '\r\n' > "$f")
fi
echo "Jenkins: http://localhost:8081  user: admin  password: in $f"
