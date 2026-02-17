# DB2 11.5 (AIX 7.2) – Test Case Documentation  
## Row recovery via STAGING database using FULL + INCREMENTAL ONLINE backups (INCLUDE LOGS)

This document describes a **single lab test case** focused on:
- **Performance-minded** backup/restore design (multi-target backup, parallelism knobs)
- A **tablespace-oriented recovery strategy** for very large databases (e.g., 400TB):
  - Keep PROD online
  - Restore into a **separate STAGING DB**
  - Rollforward STAGING to a **point-in-time before an accidental DELETE**
  - Export recovered row(s) and import into PROD

> Why STAGING?  
> For very large databases, restoring the entire database just to recover a few objects is operationally expensive.  
> Using a STAGING restore is often the fastest *practical* option: you rebuild only what you need and move the data back.

---

## What you get

### 1) One script with subcommands (recommended)
**`db2_ts_restore_staging_lab_aix.sh`** supports:
- Database creation / drop
- Tablespace + table creation
- Inserts / delete incident
- Full + incremental online backup (with logs)
- Redirected restore into STAGING (container paths remapped automatically)
- Rollforward STAGING to PIT
- Export recovered row and import back to PROD

This approach is best for labs because:
- You can run **end-to-end** (`all`)
- Or run **one activity at a time** (like “only backups”, “only delete”, “only restore”)
- No manual timestamp selection: it parses **LIST HISTORY** automatically

---

## Prerequisites (AIX 7.2)

1. You are in a DB2 instance environment:
   - `db2level` works
   - `db2` command is in PATH (typically via `source ~db2inst1/sqllib/db2profile`)

2. You have filesystem paths (or adjust variables):
- Backup root: `/backup/db2lab`
- Data roots:
  - `/db2data/LABSRC/...`
  - `/db2data/LABSTG/...`
- Archive logs root: `/db2arch`

> You can override all paths via environment variables without editing the script.

---

## Quick start

### Run everything end-to-end
```sh
chmod +x db2_ts_restore_staging_lab_aix.sh
./db2_ts_restore_staging_lab_aix.sh all
```

### See help / list of activities
```sh
./db2_ts_restore_staging_lab_aix.sh --help
```

---

## Activities (subcommands)

The script is intentionally split into **atomic steps** you can run separately.

### Cleanup / reset
- Drop DBs (lab only):
```sh
./db2_ts_restore_staging_lab_aix.sh drop_dbs
```

### Create and configure source DB (PROD-like)
Creates `LABSRC`, enables archive logging and TRACKMOD:
```sh
./db2_ts_restore_staging_lab_aix.sh create_src_db
```

### Create tablespaces and tables
Creates TS1/TS2/TS3 (DMS file containers) and tables T_TS1/T_TS2/T_TS3:
```sh
./db2_ts_restore_staging_lab_aix.sh create_ts_and_tables
```

### Seed baseline data
Inserts initial rows, including the row that will later be deleted:
```sh
./db2_ts_restore_staging_lab_aix.sh seed_baseline
```

---

## Backup activities (performance aware)

### ONLINE FULL backup (compress + include logs)
Writes to multiple targets for throughput:
```sh
./db2_ts_restore_staging_lab_aix.sh full_backup
```

### Insert after FULL backup
```sh
./db2_ts_restore_staging_lab_aix.sh insert_after_full
```

### ONLINE INCREMENTAL backup (compress + include logs)
```sh
./db2_ts_restore_staging_lab_aix.sh inc_backup
```

---

## Incident simulation

### Capture PIT marker (before delete)
Stores a PIT timestamp to `/tmp/db2_ts_recover/pit_timestamp.txt`:
```sh
./db2_ts_restore_staging_lab_aix.sh capture_pit
```

### Post-increment changes + delete row in TS2 table
Deletes a specific key (`LOST_ID`, default 11) from `T_TS2`:
```sh
./db2_ts_restore_staging_lab_aix.sh post_inc_delete
```

To use a different key:
```sh
LOST_ID=999 ./db2_ts_restore_staging_lab_aix.sh post_inc_delete
```

---

## STAGING restore / recovery

### Redirected FULL restore into STAGING (automatic remap)
No manual editing. It:
- Detects FULL backup timestamp from `LIST HISTORY`
- Starts `RESTORE ... REDIRECT`
- Automatically runs `SET TABLESPACE CONTAINERS` for TS1/TS2/TS3 to STAGING paths
- Continues the restore

```sh
./db2_ts_restore_staging_lab_aix.sh restore_stg_full_redirect
```

### Apply INCREMENTAL restore into STAGING
Auto-detects incremental backup timestamp:
```sh
./db2_ts_restore_staging_lab_aix.sh restore_stg_incremental
```

### Rollforward STAGING to PIT (stop)
Applies logs up to the PIT time (before delete):
```sh
./db2_ts_restore_staging_lab_aix.sh rollforward_stg_to_pit
```

### Export recovered row from STAGING
```sh
./db2_ts_restore_staging_lab_aix.sh export_recovered
```

### Import recovered row back into PROD
```sh
./db2_ts_restore_staging_lab_aix.sh import_to_prod
```

---

## Diagnostics

Show backup history and rollforward status:
```sh
./db2_ts_restore_staging_lab_aix.sh status
```

Remove the work directory:
```sh
./db2_ts_restore_staging_lab_aix.sh cleanup
```

---

## Can this be a single script, or should it be split?

**Best practice for a lab:** a **single script with subcommands** (what I provided).  
Reasons:
- Copy/paste friendly
- Deterministic flow (you can rerun one step)
- Easy to track state (timestamps saved to workdir)

When to split into multiple small scripts:
- If you want strict separation for audit/change control (e.g., “backup-only” script vs “recovery-only” script)
- If different teams run different phases

If you want, I can also generate:
- `01_setup.sh`, `02_backup.sh`, `03_incident.sh`, `04_recovery.sh`
…built from the same logic, but usually the subcommand approach is simpler.

---

## Next step: performance + tablespace restore strategy (beyond this test)

After you validate this test case, the next “real” step is to adapt it to:
- **multiple tablespaces** and multiple “objects” per TS
- faster restore on STAGING via:
  - pre-provisioned storage
  - dedicated disk groups
  - log replay tuning (log arch / log location)
- and automation around “identify which TS is affected, restore only what’s needed into STAGING”