#!/usr/bin/env bash
# ==============================================================================
# DB2 11.5 (AIX 7.2) - Performance + Tablespace-level restore strategy (via STAGING)
# ------------------------------------------------------------------------------
# Test case: recover an accidentally DELETED row that lives in one tablespace
#           WITHOUT restoring the whole PROD database.
#
# Strategy (operationally realistic for very large DBs, e.g. ~400TB):
#   1) Keep PROD online and untouched.
#   2) Restore PROD backups into a separate STAGING database (redirected restore).
#   3) Rollforward STAGING to a point-in-time (PIT) just BEFORE the DELETE.
#   4) Export recovered row(s) from STAGING and INSERT/IMPORT into PROD.
#
# This script is designed to run on AIX 7.2 (ksh/bash compatible). It uses:
#   - db2 CLP commands
#   - awk/sed/grep from base OS (/usr/bin/*)
#
# You can run the whole flow or run individual steps (subcommands).
#
# AUTHOR: Krzysztof Stefaniak
# TEAM: TahD
# ==============================================================================

set -euo pipefail

# -----------------------------
# Configuration (EDIT IF NEEDED)
# -----------------------------
SRCDB="${SRCDB:-LABSRC}"
STGDB="${STGDB:-LABSTG}"

# Backup roots (separate FS recommended for performance)
BACKUPROOT="${BACKUPROOT:-/backup/db2lab}"
BKPFULL="${BKPFULL:-${BACKUPROOT}/full}"
BKPINC="${BKPINC:-${BACKUPROOT}/inc}"

# Multiple backup targets (parallel I/O)
BKP_TGT1="${BKP_TGT1:-${BKPFULL}/tgt1}"
BKP_TGT2="${BKP_TGT2:-${BKPFULL}/tgt2}"
BKP_TGT3="${BKP_TGT3:-${BKPINC}/tgt1}"
BKP_TGT4="${BKP_TGT4:-${BKPINC}/tgt2}"

# Archive log roots (ONLINE backup prerequisite)
ARCHROOT="${ARCHROOT:-/db2arch}"

# Tablespace container roots
TSROOT="${TSROOT:-/db2data/${SRCDB}}"
TS1PATH="${TS1PATH:-${TSROOT}/ts1}"
TS2PATH="${TS2PATH:-${TSROOT}/ts2}"
TS3PATH="${TS3PATH:-${TSROOT}/ts3}"

# STAGING container roots
STGROOT="${STGROOT:-/db2data/${STGDB}}"
STGTS1="${STGTS1:-${STGROOT}/ts1}"
STGTS2="${STGTS2:-${STGROOT}/ts2}"
STGTS3="${STGTS3:-${STGROOT}/ts3}"

# Backup performance knobs (tune per environment)
PARALLELISM="${PARALLELISM:-4}"
NUMBUFFERS="${NUMBUFFERS:-4}"
BUFFERPAGES="${BUFFERPAGES:-2048}"     # 2048 * 4KB = 8MB per buffer (default 4K pages)

# Workdir for artifacts (timestamps, recovered data)
WORKDIR="${WORKDIR:-/tmp/db2_ts_recover}"
PIT_FILE="${WORKDIR}/pit_timestamp.txt"
RECOVER_DEL="${WORKDIR}/recovered_ts2_id11.del"

# If you want a different "lost row" key:
LOST_ID="${LOST_ID:-11}"

# -------------
# Small helpers
# -------------
log() { print -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { print -- "ERROR: $*" >&2; exit 1; }

need_db2() {
  command -v db2 >/dev/null 2>&1 || die "db2 command not found in PATH (source db2profile?)."
}

mkpaths() {
  mkdir -p "${BKP_TGT1}" "${BKP_TGT2}" "${BKP_TGT3}" "${BKP_TGT4}"
  mkdir -p "${WORKDIR}"
  mkdir -p "${TS1PATH}" "${TS2PATH}" "${TS3PATH}"
  mkdir -p "${STGTS1}" "${STGTS2}" "${STGTS3}"
  mkdir -p "${ARCHROOT}/${SRCDB}/active" "${ARCHROOT}/${SRCDB}/archive"
}

db2q() { # quiet-ish wrapper for DB2 CLP
  db2 -v "$@"
}

db2x() { # returns scalar output (trimmed)
  db2 -x "$@" | tr -d ' \t\r'
}

# Extract "taken at" timestamps automatically from LIST HISTORY.
# Expected DB2 format:
# Op  Obj  Timestamp+Sequence  Type  Dev ...
# B   D    20260217121000      F     D   ...
get_full_bkp_ts() {
  db2 "list history backup all for ${SRCDB}" | /usr/bin/awk '($1=="B" && $2=="D" && $4=="F"){print $3; exit}'
}

get_last_inc_bkp_ts() {
  db2 "list history backup all for ${SRCDB}" | /usr/bin/awk '($1=="B" && $2=="D" && $4=="I"){ts=$3} END{print ts}'
}

# Tablespace IDs are needed for redirected restore "SET TABLESPACE CONTAINERS"
get_tbsp_id() {
  typeset name="$1"
  db2x "connect to ${SRCDB}; select tbsp_id from syscat.tablespaces where tbsp_name='${name}'; connect reset;"
}

# ---------------
# Step functions
# ---------------
step_drop_dbs() {
  log "Dropping existing DBs (ignore errors if they don't exist)"
  db2 "deactivate db ${SRCDB}" >/dev/null 2>&1 || true
  db2 "deactivate db ${STGDB}" >/dev/null 2>&1 || true
  db2 "drop db ${SRCDB}" >/dev/null 2>&1 || true
  db2 "drop db ${STGDB}" >/dev/null 2>&1 || true
}

step_create_src_db() {
  log "Creating source DB ${SRCDB} and enabling ARCHIVE logging"
  db2q "create db ${SRCDB} using codeset UTF-8 territory US"

  # Enable archive logging (ONLINE backup prerequisite)
  db2q "connect to ${SRCDB}"
  db2q "update db cfg for ${SRCDB} using LOGARCHMETH1 DISK:${ARCHROOT}/${SRCDB}/archive"
  db2q "update db cfg for ${SRCDB} using NEWLOGPATH ${ARCHROOT}/${SRCDB}/active"

  # Log sizing (lab defaults; tune for your env)
  db2q "update db cfg for ${SRCDB} using LOGFILSIZ 8192"
  db2q "update db cfg for ${SRCDB} using LOGPRIMARY 20"
  db2q "update db cfg for ${SRCDB} using LOGSECOND 40"

  # Incremental backup support
  db2q "update db cfg for ${SRCDB} using TRACKMOD YES"

  db2q "connect reset"
  db2stop
  db2start
  log "SRCDB ${SRCDB} created and configured"
}

step_create_tablespaces_and_tables() {
  log "Creating 3 DMS tablespaces and 3 tables (one per TS)"
  db2q "connect to ${SRCDB}"

  db2 -tv <<SQL
CREATE TABLESPACE TS1 MANAGED BY DATABASE
  USING (FILE '${TS1PATH}/ts1.cont' 2000M)
  EXTENTSIZE 32
  PREFETCHSIZE 64
  BUFFERPOOL IBMDEFAULTBP;

CREATE TABLESPACE TS2 MANAGED BY DATABASE
  USING (FILE '${TS2PATH}/ts2.cont' 2000M)
  EXTENTSIZE 32
  PREFETCHSIZE 64
  BUFFERPOOL IBMDEFAULTBP;

CREATE TABLESPACE TS3 MANAGED BY DATABASE
  USING (FILE '${TS3PATH}/ts3.cont' 2000M)
  EXTENTSIZE 32
  PREFETCHSIZE 64
  BUFFERPOOL IBMDEFAULTBP;

CREATE TABLE T_TS1 (ID INT NOT NULL PRIMARY KEY, VAL VARCHAR(100), TS TIMESTAMP) IN TS1;
CREATE TABLE T_TS2 (ID INT NOT NULL PRIMARY KEY, VAL VARCHAR(100), TS TIMESTAMP) IN TS2;
CREATE TABLE T_TS3 (ID INT NOT NULL PRIMARY KEY, VAL VARCHAR(100), TS TIMESTAMP) IN TS3;
SQL

  db2q "connect reset"
  log "Tablespaces created"
}

step_seed_rows_baseline() {
  log "Seeding baseline rows into each tablespace"
  db2q "connect to ${SRCDB}"

  db2 -tv <<SQL
INSERT INTO T_TS1 VALUES (1, 'ts1-row-1', CURRENT TIMESTAMP);
INSERT INTO T_TS1 VALUES (2, 'ts1-row-2', CURRENT TIMESTAMP);

INSERT INTO T_TS2 VALUES (10, 'ts2-row-10', CURRENT TIMESTAMP);
INSERT INTO T_TS2 VALUES (${LOST_ID}, 'ts2-row-${LOST_ID}', CURRENT TIMESTAMP);

INSERT INTO T_TS3 VALUES (20, 'ts3-row-20', CURRENT TIMESTAMP);
INSERT INTO T_TS3 VALUES (21, 'ts3-row-21', CURRENT TIMESTAMP);

COMMIT;

SELECT 'TS1' AS TS, COUNT(*) AS CNT FROM T_TS1
UNION ALL SELECT 'TS2', COUNT(*) FROM T_TS2
UNION ALL SELECT 'TS3', COUNT(*) FROM T_TS3;
SQL

  db2q "connect reset"
}

step_full_backup_online() {
  log "ONLINE FULL backup (COMPRESS + INCLUDE LOGS) to multiple targets for throughput"
  db2q "backup db ${SRCDB} online to ${BKP_TGT1}, ${BKP_TGT2} compress include logs parallelism ${PARALLELISM} num_buffers ${NUMBUFFERS} buffer ${BUFFERPAGES}"

  typeset fullts
  fullts="$(get_full_bkp_ts)"
  [[ -n "${fullts}" ]] || die "Could not auto-detect FULL backup timestamp from list history."
  log "Detected FULL backup taken at: ${fullts}"
}

step_insert_after_full() {
  log "Insert rows after FULL backup"
  db2q "connect to ${SRCDB}"
  db2 -tv <<SQL
INSERT INTO T_TS1 VALUES (3, 'ts1-row-3-afterfull', CURRENT TIMESTAMP);
INSERT INTO T_TS2 VALUES (12, 'ts2-row-12-afterfull', CURRENT TIMESTAMP);
INSERT INTO T_TS3 VALUES (22, 'ts3-row-22-afterfull', CURRENT TIMESTAMP);
COMMIT;
SQL
  db2q "connect reset"
}

step_incremental_backup_online() {
  log "ONLINE INCREMENTAL backup (COMPRESS + INCLUDE LOGS)"
  db2q "backup db ${SRCDB} online incremental to ${BKP_TGT3}, ${BKP_TGT4} compress include logs parallelism ${PARALLELISM} num_buffers ${NUMBUFFERS} buffer ${BUFFERPAGES}"

  typeset incts
  incts="$(get_last_inc_bkp_ts)"
  [[ -n "${incts}" ]] || die "Could not auto-detect INCREMENTAL backup timestamp from list history."
  log "Detected INCREMENTAL backup taken at: ${incts}"
}

step_capture_pit_marker() {
  log "Capture PIT timestamp (BEFORE the delete). We'll rollforward STAGING to this time."
  db2q "connect to ${SRCDB}"
  # AIX DB2 supports VARCHAR_FORMAT (LUW). We store local time string.
  typeset pit
  pit="$(db2x "values varchar_format(current timestamp, 'YYYY-MM-DD-HH24.MI.SS')")"
  db2q "connect reset"

  [[ -n "${pit}" ]] || die "Failed to capture PIT timestamp."
  print -- "${pit}" > "${PIT_FILE}"
  log "PIT timestamp written to ${PIT_FILE}: ${pit}"
}

step_post_inc_changes_and_delete() {
  log "Post-increment changes: insert into TS1/TS3 and DELETE row in TS2 (incident)"
  db2q "connect to ${SRCDB}"

  db2 -tv <<SQL
INSERT INTO T_TS1 VALUES (4, 'ts1-row-4-afterinc', CURRENT TIMESTAMP);
INSERT INTO T_TS3 VALUES (23, 'ts3-row-23-afterinc', CURRENT TIMESTAMP);
COMMIT;

-- INCIDENT: delete the target row
DELETE FROM T_TS2 WHERE ID = ${LOST_ID};
COMMIT;

-- Verify it's gone in PROD
SELECT * FROM T_TS2 ORDER BY ID;
SQL

  db2q "connect reset"
  log "Incident simulated: row ${LOST_ID} deleted from PROD table in TS2"
}

step_restore_to_staging_redirected() {
  log "Restoring into STAGING with redirected containers (no manual editing)"
  mkpaths

  typeset fullts
  fullts="$(get_full_bkp_ts)"
  [[ -n "${fullts}" ]] || die "FULL backup timestamp not found. Did you run full backup?"

  # Need TS IDs from SRCDB catalog (still exists)
  typeset id1 id2 id3
  id1="$(get_tbsp_id TS1)"
  id2="$(get_tbsp_id TS2)"
  id3="$(get_tbsp_id TS3)"
  [[ -n "${id1}" && -n "${id2}" && -n "${id3}" ]] || die "Failed to read tablespace IDs from SYSCAT.TABLESPACES."

  log "Tablespace IDs: TS1=${id1}, TS2=${id2}, TS3=${id3}"
  log "Running redirected restore from FULL backup ts=${fullts}"

  # Start redirected restore
  db2q "restore db ${SRCDB} from ${BKP_TGT1} taken at ${fullts} into ${STGDB} redirect"

  # Redirect containers to STAGING paths
  # NOTE: Use same container sizes as created (2000M).
  db2q "set tablespace containers for ${id1} using (file '${STGTS1}/ts1.cont' 2000M)"
  db2q "set tablespace containers for ${id2} using (file '${STGTS2}/ts2.cont' 2000M)"
  db2q "set tablespace containers for ${id3} using (file '${STGTS3}/ts3.cont' 2000M)"

  # Continue the restore
  db2q "restore db ${STGDB} continue"
  log "FULL restore into STAGING completed (rollforward pending expected)"
}

step_restore_incremental_to_staging() {
  log "Applying INCREMENTAL backup to STAGING"
  typeset incts
  incts="$(get_last_inc_bkp_ts)"
  [[ -n "${incts}" ]] || die "INCREMENTAL backup timestamp not found. Did you run incremental backup?"

  # Apply incremental restore to STAGING
  db2q "restore db ${STGDB} incremental from ${BKP_TGT3} taken at ${incts} into ${STGDB}"
  log "Incremental restore applied to STAGING (rollforward pending expected)"
}

step_rollforward_staging_to_pit() {
  [[ -f "${PIT_FILE}" ]] || die "PIT file not found: ${PIT_FILE}. Run capture_pit first."
  typeset pit
  pit="$(cat "${PIT_FILE}" | tr -d ' \t\r')"
  [[ -n "${pit}" ]] || die "PIT timestamp is empty."

  log "Rolling forward STAGING to PIT=${pit} (stop)"
  db2q "rollforward db ${STGDB} to ${pit} using local time and stop"

  log "Verifying recovered row exists in STAGING (ID=${LOST_ID})"
  db2q "connect to ${STGDB}"
  db2q "select * from T_TS2 where ID=${LOST_ID}"
  db2q "connect reset"
}

step_export_from_staging() {
  log "Exporting recovered row from STAGING to ${RECOVER_DEL}"
  db2q "connect to ${STGDB}"
  db2q "export to ${RECOVER_DEL} of del select * from T_TS2 where ID=${LOST_ID}"
  db2q "connect reset"

  [[ -s "${RECOVER_DEL}" ]] || die "Export file not created or empty: ${RECOVER_DEL}"
}

step_import_into_prod() {
  log "Importing recovered row back into PROD ${SRCDB} from ${RECOVER_DEL}"
  [[ -s "${RECOVER_DEL}" ]] || die "Missing export file: ${RECOVER_DEL}"

  db2q "connect to ${SRCDB}"
  # INSERT mode will fail if the row already exists; that's usually what we want.
  db2q "import from ${RECOVER_DEL} of del insert into T_TS2"
  db2q "commit"
  db2q "select * from T_TS2 order by ID"
  db2q "connect reset"
}

step_status_and_history() {
  log "Backup history for ${SRCDB}"
  db2 "list history backup all for ${SRCDB}" || true

  log "Rollforward status for ${STGDB}"
  db2 "rollforward db ${STGDB} query status" || true
}

step_cleanup_workdir() {
  log "Cleaning workdir ${WORKDIR}"
  rm -rf "${WORKDIR}" || true
}

# --------------------
# Composite workflows
# --------------------
run_all() {
  need_db2
  mkpaths
  step_drop_dbs
  step_create_src_db
  step_create_tablespaces_and_tables
  step_seed_rows_baseline
  step_full_backup_online
  step_insert_after_full
  step_incremental_backup_online
  step_capture_pit_marker
  step_post_inc_changes_and_delete

  # STAGING recovery
  step_restore_to_staging_redirected
  step_restore_incremental_to_staging
  step_rollforward_staging_to_pit
  step_export_from_staging
  step_import_into_prod

  step_status_and_history
  log "ALL DONE"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands (run individually):
  drop_dbs                       Drop LABSRC/LABSTG if they exist (lab only)
  create_src_db                  Create SRCDB and enable ARCHIVE logging + TRACKMOD
  create_ts_and_tables           Create TS1/TS2/TS3 and tables T_TS1/T_TS2/T_TS3
  seed_baseline                  Insert baseline rows (includes the row that will be deleted later)
  full_backup                    ONLINE FULL backup (compress + include logs)
  insert_after_full              Insert rows after FULL backup
  inc_backup                     ONLINE INCREMENTAL backup (compress + include logs)
  capture_pit                    Capture PIT timestamp BEFORE delete (saved to ${PIT_FILE})
  post_inc_delete                Insert rows after incremental + delete ID=${LOST_ID} from TS2 table

STAGING restore / recovery steps:
  restore_stg_full_redirect      Redirected FULL restore into STGDB with container remap
  restore_stg_incremental        Restore INCREMENTAL into STGDB
  rollforward_stg_to_pit         Rollforward STGDB to PIT (stop) and verify recovered row exists
  export_recovered               Export recovered row from STGDB into ${RECOVER_DEL}
  import_to_prod                 Import recovered row back into SRCDB

Diagnostics / misc:
  status                         Show backup history and STGDB rollforward status
  cleanup                        Remove ${WORKDIR}

Composite:
  all                            Run the complete scenario end-to-end

Environment overrides (examples):
  SRCDB=PROD1 STGDB=STAGE1 BACKUPROOT=/backup/mytest $(basename "$0") all
  LOST_ID=999 $(basename "$0") post_inc_delete

EOF
}

main() {
  need_db2
  mkpaths

  case "${1:-}" in
    drop_dbs) step_drop_dbs ;;
    create_src_db) step_create_src_db ;;
    create_ts_and_tables) step_create_tablespaces_and_tables ;;
    seed_baseline) step_seed_rows_baseline ;;
    full_backup) step_full_backup_online ;;
    insert_after_full) step_insert_after_full ;;
    inc_backup) step_incremental_backup_online ;;
    capture_pit) step_capture_pit_marker ;;
    post_inc_delete) step_post_inc_changes_and_delete ;;

    restore_stg_full_redirect) step_restore_to_staging_redirected ;;
    restore_stg_incremental) step_restore_incremental_to_staging ;;
    rollforward_stg_to_pit) step_rollforward_staging_to_pit ;;
    export_recovered) step_export_from_staging ;;
    import_to_prod) step_import_into_prod ;;

    status) step_status_and_history ;;
    cleanup) step_cleanup_workdir ;;

    all) run_all ;;
    ""|-h|--help|help) usage ;;
    *) die "Unknown command: $1 (use --help)" ;;
  esac
}

main "$@"
