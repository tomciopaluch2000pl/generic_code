#!/usr/bin/ksh
###############################################################################
# NAME:        odllab1_setup.sh
# PURPOSE:     Create and configure a small DB2 lab database for backup/restore
#              testing (offline, online full, incremental, rollforward).
# PLATFORM:    AIX 7.2, DB2 11.5
#
# AUTHOR:      Krzysztof Stefaniak
# TEAM:        TahD
#
# SAFETY:
# - This script only creates/changes DB config for the database defined in DBNAME
# - It does NOT change DBM (instance) configuration
# - It does NOT modify or delete any other database
# - It does NOT prune/delete logs or backups
###############################################################################

set -e

###############################################################################
# Variables (adjust if needed)
###############################################################################
DBNAME="${DBNAME:-ODLLAB1}"

# Keep consistent with your environment
DATA_PATH="${DATA_PATH:-/ars/data/db1}"

# Separate directories for ODLLAB1 only
ACTIVELOG_PATH="${ACTIVELOG_PATH:-/ars/data/plog/${DBNAME}}"
ARCHLOG_PATH="${ARCHLOG_PATH:-/ars/data/alog/${DBNAME}}"
BACKUP_PATH="${BACKUP_PATH:-/ars/data/backup/${DBNAME}}"

# Optional: set codeset/territory
CODESET="${CODESET:-UTF-8}"
TERRITORY="${TERRITORY:-PL}"

###############################################################################
# Helpers
###############################################################################
die() { print -- "ERROR: $*" >&2; exit 1; }

run_db2() {
  # Use -tv to show statements; adjust if you prefer quieter output
  db2 -tv <<EOF
$1
EOF
}

###############################################################################
# 0) Ensure we are in the right instance environment
###############################################################################
print "==> Checking DB2 environment"

if [ -z "${DB2INSTANCE}" ]; then
  die "DB2INSTANCE is not set. Please run: export DB2INSTANCE=odadm; . ~odadm/sqllib/db2profile"
fi

print "DB2INSTANCE=${DB2INSTANCE}"
db2level | head -n 20

###############################################################################
# 1) Safety: ensure DBNAME does not already exist
###############################################################################
print "==> Checking whether database ${DBNAME} already exists in db directory"

# If grep finds it, exit to avoid accidental overwrite / confusion
if db2 list db directory | grep -qi "Database name[[:space:]]*=[[:space:]]*${DBNAME}\b"; then
  die "Database ${DBNAME} already exists in the system database directory. Aborting."
fi

###############################################################################
# 2) Create directories (ODLLAB1-specific)
###############################################################################
print "==> Creating directories (ODLLAB1-only)"

mkdir -p "${ACTIVELOG_PATH}" "${ARCHLOG_PATH}" "${BACKUP_PATH}"

ls -ld "${ACTIVELOG_PATH}" "${ARCHLOG_PATH}" "${BACKUP_PATH}"

###############################################################################
# 3) Create database
###############################################################################
print "==> Creating database ${DBNAME} on ${DATA_PATH}"

db2 "CREATE DATABASE ${DBNAME} ON ${DATA_PATH} USING CODESET ${CODESET} TERRITORY ${TERRITORY} COLLATE USING SYSTEM"

###############################################################################
# 4) Configure logs for online backup/rollforward + incremental
###############################################################################
print "==> Configuring DB CFG for ${DBNAME} (only this DB)"

db2 "CONNECT TO ${DBNAME}"

# Active logs on a DB-specific path
db2 "UPDATE DB CFG FOR ${DBNAME} USING NEWLOGPATH ${ACTIVELOG_PATH}"

# Enable archive logging (required for online recovery / rollforward)
db2 "UPDATE DB CFG FOR ${DBNAME} USING LOGARCHMETH1 DISK:${ARCHLOG_PATH}"

# Enable changed-page tracking (required for incremental backups)
db2 "UPDATE DB CFG FOR ${DBNAME} USING TRACKMOD ON"

db2 "TERMINATE"

# Apply NEWLOGPATH (requires deactivate/activate)
print "==> Applying NEWLOGPATH (deactivate/activate ${DBNAME})"
db2 "DEACTIVATE DB ${DBNAME}" || true
db2 "ACTIVATE DB ${DBNAME}"

db2 "CONNECT TO ${DBNAME}"

print "==> Verifying key DB CFG settings"
db2 "GET DB CFG FOR ${DBNAME}" | egrep -i "NEWLOGPATH|LOGARCHMETH1|TRACKMOD|LOGFILSIZ|LOGPRIMARY|LOGSECOND"

###############################################################################
# 5) Create tablespace, schema, table, and sample data
###############################################################################
print "==> Creating tablespace, schema, table, sample data"

# Tablespace (AUTO storage, simplest for lab)
db2 "CREATE TABLESPACE TS_DATA"

# Schema
db2 "CREATE SCHEMA APP"

# Table in TS_DATA
db2 "CREATE TABLE APP.TEST1 (
  ID BIGINT NOT NULL PRIMARY KEY,
  TXT VARCHAR(200),
  CREATED_TS TIMESTAMP NOT NULL WITH DEFAULT CURRENT TIMESTAMP
) IN TS_DATA"

# Sample inserts
db2 "INSERT INTO APP.TEST1(ID, TXT) VALUES (1, 'hello')"
db2 "INSERT INTO APP.TEST1(ID, TXT) VALUES (2, 'db2 lab')"
db2 "COMMIT"

# Validate
db2 "SELECT * FROM APP.TEST1 ORDER BY ID"

###############################################################################
# 6) Optional: force some log activity and (optionally) archive current log
###############################################################################
print "==> Generating a bit of log activity (optional but useful)"
db2 "INSERT INTO APP.TEST1(ID, TXT) VALUES (3, 'log activity marker')"
db2 "COMMIT"

# Optional: force log archiving to populate ARCHLOG_PATH
# Uncomment if you want to see archive logs appear immediately.
# db2 "ARCHIVE LOG FOR DATABASE ${DBNAME}"

db2 "TERMINATE"

print "==> DONE. Database ${DBNAME} created and configured for backup/restore tests."
print "    DATA_PATH:      ${DATA_PATH}"
print "    ACTIVELOG_PATH: ${ACTIVELOG_PATH}"
print "    ARCHLOG_PATH:   ${ARCHLOG_PATH}"
print "    BACKUP_PATH:    ${BACKUP_PATH}"