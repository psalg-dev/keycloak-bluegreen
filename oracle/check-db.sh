#!/usr/bin/env bash
# oracle/check-db.sh <db> (DB_ENGINE=oracle, called by db_verify): the Oracle schema exists and Keycloak actually created its schema there (not just "the pod is
# Ready"). Catches a Keycloak that started against the wrong schema or a migration that did not run.
set -euo pipefail
cd "$(dirname "$0")/.."
DB_ENGINE=oracle
. scripts/lib/kc.sh
TAG="verification"
db=${1:?db}
schema=$(db_schema "$db")

# A SQL*Plus SYSDBA session can fail transiently while three Keycloak pods are finishing Liquibase on a fresh
# Oracle schema (ORA-00020/ORA-12516/ORA-03113). Retry briefly; a real missing schema still fails below.
scalar_retry() {
  local v
  for _ in $(seq 12); do
    v=$(sql_scalar "$db" "$1" 2>/dev/null || true)
    [[ -n $v ]] && { printf '%s' "$v"; return 0; }
    sleep 5
  done
  return 1
}

tables=$(scalar_retry "SELECT COUNT(*) FROM ALL_TABLES WHERE OWNER = '$schema'") \
  || die "$db ($schema): could not query ALL_TABLES after 60 s"
[[ ${tables:-0} -gt 0 ]] || die "$db ($schema): no tables; Keycloak did not initialize this schema"
changelog=$(scalar_retry "SELECT COUNT(*) FROM DATABASECHANGELOG") \
  || die "$db ($schema): could not query DATABASECHANGELOG after 60 s"
[[ ${changelog:-0} -gt 0 ]] || die "$db ($schema): no DATABASECHANGELOG rows; Liquibase did not run"
log "OK $db ($schema): $tables tables, $changelog changesets"
