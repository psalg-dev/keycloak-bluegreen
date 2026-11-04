#!/usr/bin/env bash
# check-db.sh <db>: the Oracle schema exists and Keycloak actually created its schema there (not just "the pod is
# Ready"). Catches a Keycloak that started against the wrong schema or a migration that did not run.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/kc.sh
TAG="verification"
db=${1:?db}
schema=$(db_schema "$db")
tables=$(sql_scalar "$db" "SELECT COUNT(*) FROM ALL_TABLES WHERE OWNER = '$schema'")
[[ ${tables:-0} -gt 0 ]] || die "$db ($schema): no tables; Keycloak did not initialize this schema"
changelog=$(sql_scalar "$db" "SELECT COUNT(*) FROM DATABASECHANGELOG")
[[ ${changelog:-0} -gt 0 ]] || die "$db ($schema): no DATABASECHANGELOG rows; Liquibase did not run"
log "OK $db ($schema): $tables tables, $changelog changesets"
