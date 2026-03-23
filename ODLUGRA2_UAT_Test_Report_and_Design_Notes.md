# ODLUGRA2 UAT Recovery Test Report and Design Notes

Date: 2026-03-23  
Host: `a31lah001`  
DB2 instance: `odadm`  
DB2 version: `11.5.9.0`  
Database: `ODLUGRA2`

---

## 1. Objective

The purpose of this UAT test was to verify whether a dropped tablespace could be recovered in a practical way on a DB2 11.5 database used by CMOD, while also keeping newer changes made after the backup.

The intended design question behind the UAT was larger:

- in production, `SOURCE` DB may exceed 400 TB,
- full restore may take multiple days,
- spare capacity for another full 400 TB copy may not exist,
- therefore the preferred recovery pattern would be to restore only one missing tablespace to a small `STAGING` DB or directly back to `SOURCE`.

This UAT was executed to test how far native DB2 backup/restore can support that requirement.

---

## 2. Initial state captured from environment

### 2.1 CMOD and activity

CMOD service for `ODLUGRA2` was stopped before recovery work started.

Observed earlier:

```bash
ps -ef | grep arssockd | grep ODLUGRA2
```

After stop, no active CMOD process remained for `ODLUGRA2`.

Database application activity check:

```bash
db2 list applications for db ODLUGRA2
```

Observed result:

```text
SQL1611W  No data was returned by Database System Monitor.
```

### 2.2 Database configuration before changes

Before recovery preparation, the database was not configured for the required scenario.

Observed values:

```text
TRACKMOD     = NO
LOGARCHMETH1 = OFF
NEWLOGPATH   =
LOGFILSIZ    = 4096
LOGPRIMARY   = 224
LOGSECOND    = 31
```

This meant that archive logging and modified-page tracking needed to be enabled before online recovery tests.

---

## 3. Tablespace selected for destructive test

The test was narrowed to one non-system tablespace only.

Selected tablespace:

- Tablespace ID: `12`
- Tablespace name: `ARSCABT`
- Table inside it: `ODADM.ARSCAB`
- Indexes observed on that table:
  - `ODADM.ARSCAB_CID_IDX`
  - `ODADM.ARSCAB_NAME_IDX`

Tablespace containers observed before drop:

```text
/ars/data/db1/odadm/NODE0000/ODLUGRA2/T0000012/C0000000.LRG
/ars/data/db2/odadm/NODE0000/ODLUGRA2/T0000012/C0000001.LRG
```

Row count before the drop test:

```bash
db2 "select count(*) as ARSCAB_ROWS from ODADM.ARSCAB"
```

Observed output:

```text
ARSCAB_ROWS
-----------
0
```

This was acceptable for the structural recovery test.

---

## 4. Recovery preparation performed in UAT

### 4.1 Directories created

```bash
mkdir -p /ars/logarch/ODLUGRA2/archive
mkdir -p /ars/logarch/ODLUGRA2/active
mkdir -p /ars/backup/ODLUGRA2/full
mkdir -p /ars/backup/ODLUGRA2/inc
mkdir -p /ars/export/ODLUGRA2
mkdir -p /ars/stage/ODL2STG
```

### 4.2 DB CFG changes

```bash
db2 update db cfg for ODLUGRA2 using LOGARCHMETH1 DISK:/ars/logarch/ODLUGRA2/archive
db2 update db cfg for ODLUGRA2 using NEWLOGPATH /ars/logarch/ODLUGRA2/active
db2 update db cfg for ODLUGRA2 using TRACKMOD YES
```

Observed final values:

```text
TRACKMOD     = YES
NEWLOGPATH   = /ars/logarch/ODLUGRA2/active/NODE0000/LOGSTREAM0000/
LOGARCHMETH1 = DISK:/ars/logarch/ODLUGRA2/archive/
```

### 4.3 Reactivation and clearing BACKUP PENDING

Because the database entered `BACKUP PENDING`, a baseline backup was required.

Commands used:

```bash
db2 connect reset
db2 terminate
db2 deactivate db ODLUGRA2
db2 activate db ODLUGRA2
```

After reactivation attempts, the database showed `BACKUP PENDING`, which was then cleared by a baseline backup.

---

## 5. Backups executed during the test

### 5.1 Offline baseline backup

Command:

```bash
db2 backup db ODLUGRA2 to /ars/backup/ODLUGRA2/full compress
```

Observed result:

```text
Backup successful. The timestamp for this backup image is : 20260323130621
```

History summary:

- Type: offline full
- Location: `/ars/backup/ODLUGRA2/full`
- Timestamp: `20260323130621`

### 5.2 Online full backup before drop

Command:

```bash
db2 backup db ODLUGRA2 online to /ars/backup/ODLUGRA2/full_online compress include logs
```

Observed result:

```text
Backup successful. The timestamp for this backup image is : 20260323132008
```

History summary:

- Type: online full
- Location: `/ars/backup/ODLUGRA2/full_online`
- Timestamp: `20260323132008`

This is the key backup image from before the destructive drop of `ARSCABT`.

### 5.3 Online full backup after new test tablespace creation

Command:

```bash
db2 backup db ODLUGRA2 online to /ars/backup/ODLUGRA2/full_after_change compress include logs
```

Observed result:

```text
Backup successful. The timestamp for this backup image is : 20260323132722
```

### 5.4 Online incremental backup

Initial incremental attempt failed with:

```text
SQL2426N The database has not been configured to allow the incremental backup operation. Reason code = "2".
```

After another online full backup and additional data change, the incremental backup succeeded.

Successful command:

```bash
db2 backup db ODLUGRA2 online incremental to /ars/backup/ODLUGRA2/inc compress include logs
```

Observed result:

```text
Backup successful. The timestamp for this backup image is : 20260323133001
```

History summary:

- Type: online incremental
- Location: `/ars/backup/ODLUGRA2/inc`
- Timestamp: `20260323133001`

---

## 6. Destructive and change scenarios executed

### 6.1 Dropping the selected existing tablespace

Command:

```bash
db2 connect to ODLUGRA2
db2 "drop tablespace ARSCABT"
```

Observed result:

```text
DB20000I  The SQL command completed successfully.
```

Verification:

```bash
db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspace = 'ARSCABT'"
```

Observed output:

```text
0 record(s) selected.
```

This confirmed that `ARSCABT` no longer existed in source.

### 6.2 Creating new test tablespace after the drop

Directories created:

```bash
mkdir -p /ars/data/db1/odadm/ODLUGRA2/UATTS1
mkdir -p /ars/data/db2/odadm/ODLUGRA2/UATTS1
```

Tablespace creation:

```bash
db2 "create regular tablespace ODLUAT1 pagesize 4k managed by database using (file '/ars/data/db1/odadm/ODLUGRA2/UATTS1/odluat1_01.cont' 20000, file '/ars/data/db2/odadm/ODLUGRA2/UATTS1/odluat1_02.cont' 20000) bufferpool IBMDEFAULTBP"
```

Table creation:

```bash
db2 "create table ODADM.UAT_ARSCAB_REC (ID int not null, NAME varchar(100), CRTS timestamp default current timestamp) in ODLUAT1"
```

Initial data:

```bash
db2 "insert into ODADM.UAT_ARSCAB_REC (ID, NAME) values (1,'ROW-1'),(2,'ROW-2'),(3,'ROW-3')"
db2 commit
```

Verification:

```bash
db2 "select * from ODADM.UAT_ARSCAB_REC order by id"
```

Observed rows:

```text
1  ROW-1
2  ROW-2
3  ROW-3
```

Additional row inserted later before successful incremental backup:

```bash
db2 "insert into ODADM.UAT_ARSCAB_REC (ID, NAME) values (4,'ROW-4')"
db2 commit
```

Observed final rows:

```text
1  ROW-1
2  ROW-2
3  ROW-3
4  ROW-4
```

---

## 7. Recovery scenarios tested and their outcomes

### 7.1 Scenario A: Restore dropped tablespace into small independently created STAGING DB

Objective:

- create a small separate database `ODL2STG`,
- restore only dropped tablespace `ARSCABT` into it,
- avoid full restore of source backup image.

#### 7.1.1 STAGING DB creation

Commands used:

```bash
mkdir -p /ars/logarch/ODL2STG/archive
mkdir -p /ars/logarch/ODL2STG/active
mkdir -p /ars/backup/ODL2STG/full
mkdir -p /ars/data/db1/odadm/NODE0000/ODL2STG
mkdir -p /ars/data/db2/odadm/NODE0000/ODL2STG
mkdir -p /ars/data/db1/odadm/NODE0000/ODL2STG/T0000012
mkdir -p /ars/data/db2/odadm/NODE0000/ODL2STG/T0000012

db2 "create db ODL2STG on /ars/data/db1"
db2 update db cfg for ODL2STG using LOGARCHMETH1 DISK:/ars/logarch/ODL2STG/archive
db2 update db cfg for ODL2STG using NEWLOGPATH /ars/logarch/ODL2STG/active
db2 update db cfg for ODL2STG using TRACKMOD YES
db2 backup db ODL2STG to /ars/backup/ODL2STG/full compress
```

Observed staging backup timestamp:

```text
20260323133434
```

#### 7.1.2 Attempted restore

Command attempted:

```bash
db2 "restore db ODLUGRA2 tablespace (ARSCABT) from /ars/backup/ODLUGRA2/full_online taken at 20260323132008 into ODL2STG redirect"
```

Observed result:

```text
SQL2560N The table space restore operation failed because the target database is not identical to the source database.
```

#### 7.1.3 Conclusion for Scenario A

This recovery pattern failed.

Meaning:

- DB2 did not allow restoring the single tablespace from `ODLUGRA2` backup into an independently created small target database.
- Therefore the hoped-for pattern
  - `SOURCE` very large,
  - `STAGING` small,
  - restore only one lost tablespace quickly,
  - no need for full source-sized staging copy,
  did **not** work in this UAT with native DB2 backup/restore.

### 7.2 Scenario B: Restore dropped tablespace directly back into SOURCE

Objective:

- after `ARSCABT` was dropped from source,
- restore it back directly to `ODLUGRA2` from the pre-drop online full backup.

Verification before restore attempt:

```bash
db2 connect to ODLUGRA2
db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspace = 'ARSCABT'"
```

Observed output:

```text
0 record(s) selected.
```

Restore attempt:

```bash
db2 "restore db ODLUGRA2 tablespace (ARSCABT) from /ars/backup/ODLUGRA2/full_online taken at 20260323132008"
```

Observed result:

```text
SQL2549N The database was not restored because either all of the table spaces in the backup image are inaccessible, or one or more table space names in list of table space names to restore are invalid.
```

#### 7.2.1 Conclusion for Scenario B

This direct restore pattern also failed.

In this UAT, once the tablespace had been dropped and disappeared from current source database metadata, native restore of that dropped tablespace directly back to source did not succeed using the tested command path.

---

## 8. Comparison with the LAB scenario

The earlier LAB work was valuable, but it was **not equivalent** to the UAT problem described here.

### 8.1 What worked in LAB

The LAB demonstrated:

- enabling archive logging and recoverable configuration,
- creating controlled test objects,
- taking offline and online backups,
- taking online incremental backup,
- capturing a PIT timestamp,
- performing recovery work through a staging path,
- recovering logical data and reinserting it back into source.

### 8.2 Why UAT behaved differently

The UAT tested a more difficult and more realistic production-like question:

- existing non-system tablespace was dropped,
- source DB continued to evolve after the drop,
- business requirement was to restore only one small lost tablespace,
- staging capacity for a full source-sized copy was not assumed to exist.

This UAT showed that the following two hoped-for shortcuts did not work:

1. restore dropped tablespace into a small independently created staging DB,  
2. restore dropped tablespace directly back into source after it no longer existed there.

Therefore LAB success should not be interpreted as proof that this 400 TB production requirement is covered by native DB2 tablespace-only restore.

---

## 9. What the UAT proved

### 9.1 Confirmed working

The following worked successfully:

- CMOD stop and recovery preparation,
- enabling archive logging,
- enabling `TRACKMOD YES`,
- offline baseline backup,
- online full backup,
- dropping an existing tablespace,
- creating a new tablespace and new table after the drop,
- online incremental backup after additional online full backup and data change.

### 9.2 Confirmed not working in this test

The following patterns failed:

- restoring dropped `ARSCABT` into a small independently created staging DB,
- restoring dropped `ARSCABT` directly back into source.

---

## 10. What this means for a 400 TB production design

This is the key architectural outcome of the UAT.

### 10.1 Requirement that was tested

Desired production behavior:

- source database > 400 TB,
- full restore may take multiple days,
- no spare storage for another full 400 TB copy,
- only one lost tablespace must be recovered quickly.

### 10.2 Native DB2 conclusion from UAT

Native DB2 backup/restore should **not** be assumed to provide a lightweight solution for this exact requirement.

The UAT did **not** confirm that DB2 can:

- restore one dropped tablespace into a tiny separate staging DB, or
- restore one dropped tablespace directly back to source after drop,

without needing a more expensive recovery path.

### 10.3 Design implication

For a real 400 TB production design, relying only on native DB2 backup/restore for fast, small-footprint dropped tablespace recovery is risky.

More realistic design directions are:

- storage snapshot / clone based recovery,
- split-mirror or storage-level copy technologies,
- logical protection of critical objects,
- additional unload/export/replication strategy for important data sets,
- or business acceptance that a restore-based copy of source may be required in a dedicated recovery environment.

---

## 11. Full restore back to pre-change state

The user also requested explicit guidance for restoring the full database back to the point before the destructive changes and before creation of the new tablespace `ODLUAT1`.

That restore point is the online full backup taken **before**:

- drop of `ARSCABT`,
- creation of `ODLUAT1`,
- insertion of rows into `ODADM.UAT_ARSCAB_REC`.

### 11.1 Chosen backup image

Use this backup image:

- Backup type: online full
- Backup timestamp: `20260323132008`
- Backup location: `/ars/backup/ODLUGRA2/full_online`

### 11.2 Important effect of this restore

If you restore `ODLUGRA2` from this image, the database will return to the state from before:

- `ARSCABT` drop,
- `ODLUAT1` creation,
- table `ODADM.UAT_ARSCAB_REC`,
- all post-backup changes.

So after this full restore:

- `ARSCABT` should exist again,
- `ODLUAT1` should be gone,
- `ODADM.UAT_ARSCAB_REC` should be gone.

### 11.3 Recommended procedure to restore SOURCE fully back to pre-change state

This is destructive to the current source state and should be treated as a separate recovery scenario.

#### 11.3.1 Stop application activity

```bash
arssockd -T -I ODLUGRA2
ps -ef | grep arssockd | grep ODLUGRA2
db2 force applications all
```

#### 11.3.2 Restore full database from pre-change online full backup

```bash
db2 restore db ODLUGRA2 from /ars/backup/ODLUGRA2/full_online taken at 20260323132008 replace existing
```

#### 11.3.3 Roll forward using archived logs from source

```bash
db2 rollforward db ODLUGRA2 to end of logs and complete overflow log path (/ars/logarch/ODLUGRA2/archive)
```

### 11.4 Verification after full restore

```bash
db2 connect to ODLUGRA2

db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspace = 'ARSCABT'"
db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspace = 'ODLUAT1'"
db2 "select tabschema, tabname from syscat.tables where tabname = 'UAT_ARSCAB_REC'"
db2 "select tabschema, tabname from syscat.tables where tbspaceid = 12 order by tabschema, tabname"
db2 "select count(*) from ODADM.ARSCAB"
```

Expected logical result:

- `ARSCABT` present,
- `ODLUAT1` absent,
- `UAT_ARSCAB_REC` absent,
- `ODADM.ARSCAB` visible again in recovered source state.

---

## 12. Final conclusion

Todayâs UAT successfully documented a realistic limitation of native DB2 recovery for large environments.

### Final technical conclusion

The following statement is supported by the UAT:

> Native DB2 backup/restore did not provide a proven lightweight path to recover one dropped tablespace into a small staging DB or directly back into source after drop, while avoiding a full source-sized recovery copy.

### Final operational conclusion

For the 400 TB production design, the recovery strategy for a dropped small tablespace should not rely only on the native DB2 shortcut that was hoped for.

A separate design decision is required, most likely involving one of the following:

- storage snapshot / clone recovery,
- logical protection of critical objects,
- dedicated large recovery copy infrastructure,
- or acceptance of full restore timelines when native restore is the only available method.

