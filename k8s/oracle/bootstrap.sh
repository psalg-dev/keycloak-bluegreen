#!/bin/bash
# Runs once, after the database is created (gvenzl: /container-entrypoint-initdb.d; Oracle official:
# /opt/oracle/scripts/setup). No application schema is created here: scripts/lib/kc.sh create_db owns that, so a
# reset can drop/recreate schemas without recreating the database. This only creates the Data Pump directory and
# raises undo retention so FLASHBACK_SCN exports stay consistent while blue keeps writing.
set -euo pipefail

pdb=${ORACLE_PDB:-FREEPDB1}
mkdir -p /opt/oracle/oradata/dpdump

# A directory created in CDB$ROOT is not visible to a PDB session in this image; create it inside the PDB.
sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
ALTER SYSTEM SET undo_retention = 10800 SCOPE = BOTH;
ALTER SESSION SET CONTAINER = ${pdb};
CREATE OR REPLACE DIRECTORY KC_DUMP AS '/opt/oracle/oradata/dpdump';
GRANT READ, WRITE ON DIRECTORY KC_DUMP TO SYSTEM;
exit;
SQL
