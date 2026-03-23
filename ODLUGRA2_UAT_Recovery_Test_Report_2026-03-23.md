# ODLUGRA2 UAT – DB2 11.5 AIX Tablespace Recovery Test Report

Date: 2026-03-23  
Host: `a31lah001`  
Instance: `odadm`  
Database: `ODLUGRA2`  
DB2 level: `11.5.9.0`

## 1. Objective

The goal of this UAT exercise was to validate a recovery workflow for a single tablespace while keeping the source database available, and to compare the outcome with the earlier LAB, where tablespace-level recovery into a staging environment worked as planned.

The intended target pattern was:

1. stop CMOD activity for the database,
2. collect current database details,
3. enable archive logging and incremental-backup prerequisites,
4. take an online FULL backup,
5. delete one existing tablespace,
6. create a new test tablespace with data,
7. take an online INCREMENTAL backup,
8. recover the deleted tablespace in STAGING,
9. export recovered data and logically reintroduce it to SOURCE.

## 2. Executive summary

What worked in UAT:

- CMOD was stopped and the database was quiesced.
- Recovery logging was enabled successfully.
- Baseline OFFLINE backup succeeded.
- ONLINE FULL backup before the drop succeeded.
- Existing tablespace `ARSCABT` was dropped successfully.
- New test tablespace `ODLUAT1` and table `ODADM.UAT_ARSCAB_REC` were created successfully.
- ONLINE INCREMENTAL backup eventually succeeded.

What failed in UAT:

- A direct attempt to restore only tablespace `ARSCABT` into a separately created STAGING database (`ODL2STG`) failed with `SQL2560N`, because the target database was not identical to the source database.

Main design conclusion:

- In this UAT setup, **native Db2 tablespace restore into an independently created small STAGING database did not work**.
- Therefore, this test did **not** prove that a small dropped tablespace from a very large production database can be recovered into a small STAGING database without first creating a restore-based copy of the source database.

## 3. Comparison with the earlier LAB

In the earlier LAB, the scenario succeeded because the workflow used a recovery pattern that was compatible with the lab layout and database identity expectations. In this UAT, the direct command:

```bash
db2 "restore db ODLUGRA2 tablespace (ARSCABT) from /ars/backup/ODLUGRA2/full_online taken at 20260323132008 into ODL2STG redirect"
```

failed with `SQL2560N` because `ODL2STG` had been created as an independent database, not as a restore-based copy of `ODLUGRA2`.

That is the key difference between the successful LAB pattern and today’s UAT outcome.

## 4. Initial state observed in UAT

### 4.1 CMOD / process state

CMOD activity for `ODLUGRA2` was observed initially via `arssockd-ODLUGRA2`, then stopped.

Verification used:

```bash
arssockd -T -I ODLUGRA2
ps -ef | grep arssockd | grep ODLUGRA2
db2 list applications for db ODLUGRA2
```

Result after stop:

- no active DB applications,
- `SQL1611W No data was returned by Database System Monitor.`

### 4.2 DB configuration before changes

Observed earlier in UAT:

```text
LOGARCHMETH1 = OFF
TRACKMOD     = NO
NEWLOGPATH   =
LOGFILSIZ    = 4096
LOGPRIMARY   = 224
LOGSECOND    = 31
```

### 4.3 Tablespace selected for destructive test

Chosen tablespace:

- Tablespace ID: `12`
- Tablespace name: `ARSCABT`
- Table in tablespace: `ODADM.ARSCAB`
- Indexes seen for the table:
  - `ARSCAB_CID_IDX`
  - `ARSCAB_NAME_IDX`

Containers for `ARSCABT`:

```text
/ars/data/db1/odadm/NODE0000/ODLUGRA2/T0000012/C0000000.LRG
/ars/data/db2/odadm/NODE0000/ODLUGRA2/T0000012/C0000001.LRG
```

## 5. Step-by-step execution log

### Step 1 – Connect and collect metadata

Commands used:

```bash
db2 connect to ODLUGRA2

db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspaceid = 12"
db2 "select tabschema, tabname, type from syscat.tables where tbspaceid = 12 order by tabschema, tabname"
db2 "select indschema, indname, tabschema, tabname from syscat.indexes where tabschema||'.'||tabname in (select tabschema||'.'||tabname from syscat.tables where tbspaceid = 12) order by indschema, indname"
db2 list tablespace containers for 12 show detail
db2 list history backup all for ODLUGRA2
db2 get db cfg for ODLUGRA2 | egrep 'LOGARCHMETH1|NEWLOGPATH|TRACKMOD|LOGFILSIZ|LOGPRIMARY|LOGSECOND'
db2 "select distinct t.tbspaceid, s.tbspace from syscat.tables t, syscat.tablespaces s where t.tbspaceid = s.tbspaceid order by t.tbspaceid"
```

Key outputs observed:

- `ARSCABT` confirmed as tablespace `12`
- table `ODADM.ARSCAB` confirmed in that tablespace
- no backup history yet
- DB not yet recoverable (`LOGARCHMETH1=OFF`, `TRACKMOD=NO`)

### Step 2 – Enable archive logging and recovery prerequisites

Commands used:

```bash
mkdir -p /ars/logarch/ODLUGRA2/archive
mkdir -p /ars/logarch/ODLUGRA2/active
mkdir -p /ars/backup/ODLUGRA2/full
mkdir -p /ars/backup/ODLUGRA2/inc
mkdir -p /ars/export/ODLUGRA2
mkdir -p /ars/stage/ODL2STG

db2 update db cfg for ODLUGRA2 using LOGARCHMETH1 DISK:/ars/logarch/ODLUGRA2/archive
db2 update db cfg for ODLUGRA2 using NEWLOGPATH /ars/logarch/ODLUGRA2/active
db2 update db cfg for ODLUGRA2 using TRACKMOD YES

db2 get db cfg for ODLUGRA2 | egrep 'LOGARCHMETH1|NEWLOGPATH|TRACKMOD|LOGFILSIZ|LOGPRIMARY|LOGSECOND'
```

Observed output:

```text
TRACKMOD     = YES
NEWLOGPATH   = /ars/logarch/ODLUGRA2/active/NODE0000/LOGSTREAM0000/
LOGARCHMETH1 = DISK:/ars/logarch/ODLUGRA2/archive/
```

### Step 3 – Reset connection state and clear BACKUP PENDING with baseline OFFLINE backup

Commands used:

```bash
db2 force applications all
db2 connect reset
db2 terminate
db2 deactivate db ODLUGRA2
db2 activate db ODLUGRA2
db2 connect to ODLUGRA2
db2 backup db ODLUGRA2 to /ars/backup/ODLUGRA2/full compress
db2 list history backup all for ODLUGRA2
```

Observed behavior:

- `deactivate` initially failed because the current CLP session was still connected,
- after `connect reset` and `terminate`, deactivation succeeded,
- `activate/connect` reported backup pending until the first backup was taken,
- OFFLINE backup succeeded.

Observed backup timestamp:

- **OFFLINE baseline backup:** `20260323130621`

History excerpt:

```text
Comment: DB2 BACKUP ODLUGRA2 OFFLINE
Start Time: 20260323130621
End Time:   20260323130707
Status:     A
Location:   /ars/backup/ODLUGRA2/full
```

### Step 4 – ONLINE FULL backup before destructive action

Commands used:

```bash
mkdir -p /ars/backup/ODLUGRA2/full_online
mkdir -p /ars/data/db1/odadm/ODLUGRA2/UATTS1
mkdir -p /ars/data/db2/odadm/ODLUGRA2/UATTS1

db2 connect to ODLUGRA2
db2 "select count(*) as ARSCAB_ROWS from ODADM.ARSCAB"
db2 "select bpname, pagesize, npages from syscat.bufferpools order by bpname"
db2 backup db ODLUGRA2 online to /ars/backup/ODLUGRA2/full_online compress include logs
db2 list history backup all for ODLUGRA2
```

Observed output:

- `ODADM.ARSCAB` row count returned `0`
- only `IBMDEFAULTBP` was used
- ONLINE FULL backup succeeded.

Observed backup timestamp:

- **ONLINE FULL before drop:** `20260323132008`

History excerpt:

```text
Comment: DB2 BACKUP ODLUGRA2 ONLINE
Start Time: 20260323132008
End Time:   20260323132057
Status:     A
Location:   /ars/backup/ODLUGRA2/full_online
```

### Step 5 – Drop existing tablespace `ARSCABT`

Commands used:

```bash
db2 connect to ODLUGRA2
db2 "drop tablespace ARSCABT"
db2 "select tbspaceid, tbspace from syscat.tablespaces where tbspace = 'ARSCABT'"
```

Observed output:

```text
DB20000I The SQL command completed successfully.
0 record(s) selected.
```

Result:

- `ARSCABT` was successfully dropped from SOURCE.

### Step 6 – Create new test tablespace and data

Commands used:

```bash
db2 "create regular tablespace ODLUAT1 pagesize 4k managed by database using (file '/ars/data/db1/odadm/ODLUGRA2/UATTS1/odluat1_01.cont' 20000, file '/ars/data/db2/odadm/ODLUGRA2/UATTS1/odluat1_02.cont' 20000) bufferpool IBMDEFAULTBP"

db2 "create table ODADM.UAT_ARSCAB_REC (ID int not null, NAME varchar(100), CRTS timestamp default current timestamp) in ODLUAT1"

db2 "insert into ODADM.UAT_ARSCAB_REC (ID, NAME) values (1,'ROW-1'),(2,'ROW-2'),(3,'ROW-3')"
db2 commit

db2 "select * from ODADM.UAT_ARSCAB_REC order by id"
```

Observed output:

- `ODLUAT1` created successfully
- `ODADM.UAT_ARSCAB_REC` created successfully
- rows `1..3` inserted successfully

### Step 7 – First INCREMENTAL attempt failed

Command used:

```bash
db2 backup db ODLUGRA2 online incremental to /ars/backup/ODLUGRA2/inc compress include logs
```

Observed output:

```text
SQL2426N The database has not been configured to allow the incremental backup operation. Reason code = "2".
```

Interpretation:

- a new ONLINE FULL backup was required to establish a valid incremental chain after the changes.

### Step 8 – New ONLINE FULL after structural change

Commands used:

```bash
mkdir -p /ars/backup/ODLUGRA2/full_after_change

db2 connect to ODLUGRA2
db2 backup db ODLUGRA2 online to /ars/backup/ODLUGRA2/full_after_change compress include logs
```

Observed backup timestamp:

- **ONLINE FULL after change:** `20260323132722`

History excerpt:

```text
Comment: DB2 BACKUP ODLUGRA2 ONLINE
Start Time: 20260323132722
End Time:   20260323132806
Status:     A
Location:   /ars/backup/ODLUGRA2/full_after_change
```

### Step 9 – Add one more row and retry INCREMENTAL

Commands used:

```bash
db2 connect to ODLUGRA2
db2 "insert into ODADM.UAT_ARSCAB_REC (ID, NAME) values (4,'ROW-4')"
db2 commit
db2 "select * from ODADM.UAT_ARSCAB_REC order by id"
db2 backup db ODLUGRA2 online incremental to /ars/backup/ODLUGRA2/inc compress include logs
db2 list history backup all for ODLUGRA2
```

Observed output:

- row `4` inserted successfully
- ONLINE INCREMENTAL succeeded.

Observed backup timestamp:

- **ONLINE INCREMENTAL:** `20260323133001`

History excerpt:

```text
Comment: DB2 BACKUP ODLUGRA2 ONLINE
Start Time: 20260323133001
End Time:   20260323133002
Status:     A
Location:   /ars/backup/ODLUGRA2/inc
```

### Step 10 – First STAGING attempt using independently created database

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

Observed output:

- `ODL2STG` created successfully
- baseline backup of `ODL2STG` succeeded
- timestamp: `20260323133434`

Then attempted restore:

```bash
db2 "restore db ODLUGRA2 tablespace (ARSCABT) from /ars/backup/ODLUGRA2/full_online taken at 20260323132008 into ODL2STG redirect"
```

Observed failure:

```text
SQL2560N The table space restore operation failed because the target database is not identical to the source database.
```

## 6. Final technical findings from today’s UAT

### 6.1 What succeeded

The following recovery chain was validated successfully:

- CMOD shutdown for the target DB
- enabling recoverability (`LOGARCHMETH1`, `NEWLOGPATH`, `TRACKMOD`)
- OFFLINE baseline backup
- ONLINE FULL backup
- destructive drop of an existing tablespace
- creation of a new test tablespace and table
- ONLINE FULL after change
- ONLINE INCREMENTAL after additional DML

### 6.2 What did not work

This specific method did not work:

- restoring a single tablespace from SOURCE into a separately created STAGING database created with `CREATE DB`.

The direct evidence was the `SQL2560N` error returned by Db2.

### 6.3 Why this matters for a 400 TB production design

Today’s UAT indicates that native Db2 tablespace restore, in this pattern, does **not** support the hoped-for design of:

- `SOURCE` > 400 TB,
- no spare space for another full copy,
- quick recovery of only one small dropped tablespace into a small independent STAGING database.

Instead, the evidence points to this limitation:

- a direct native tablespace restore into a small, independently created STAGING database cannot be assumed to work.

That means a production design for a 400 TB database should not rely on this path as the primary recovery strategy.

## 7. IBM documentation relevance

IBM states that `RESTORE DATABASE` can restore a full database, restore a tablespace-level backup, restore to a new database, and that after restoring from an online backup a rollforward is required. citeturn274796view0

IBM also documents dropped-table recovery as a tablespace-level restore and rollforward workflow, which is faster than full database recovery and can keep the database available. citeturn274796view1turn274796view2

However, in today’s UAT, the attempt to apply that concept to an independently created STAGING database failed with `SQL2560N`, which is the practical constraint discovered in this environment.

## 8. Answer to the final design question

### Question

Is it possible to restore the deleted tablespace directly back into the SOURCE database, since that tablespace no longer exists there?

### Answer

It is **possible in principle to consider tablespace-level restore back into SOURCE**, because Db2 supports tablespace restore operations on recoverable databases and requires rollforward afterward for online backups. citeturn274796view0turn274796view2

But based on today’s UAT, this was **not executed or proven**, so it must be treated as an **untested scenario**.

The main risks are:

- restoring directly into SOURCE can put the source database and affected tablespace into recovery-related states,
- rollforward requirements must be handled correctly,
- current post-drop object layout must be checked carefully,
- the operational risk is much higher than side recovery.

So the correct conclusion from today is:

- **not ruled out**,
- **not yet validated**,
- **must be tested separately as its own scenario**.

## 9. Recommended next scenarios

### Scenario A – Test direct tablespace restore into SOURCE

Goal:

- verify whether the missing `ARSCABT` can be restored back into `ODLUGRA2` directly.

This should be tested separately and documented with its own rollback plan.

### Scenario B – Document production limitation clearly

For the 400 TB design, document that:

- native Db2 restore of one small dropped tablespace into a small independent STAGING database was **not validated**,
- UAT instead exposed a likely requirement for a restore-based copy rather than a lightweight independent STAGING database,
- other architectural options may be required for large-scale production recovery.

## 10. Key command timeline

```text
OFFLINE baseline backup     20260323130621
ONLINE full before drop     20260323132008
DROP tablespace             ARSCABT
ONLINE full after changes   20260323132722
ONLINE incremental          20260323133001
ODL2STG baseline backup     20260323133434
STAGING TS restore          FAILED with SQL2560N
```

## 11. Bottom line

Today’s UAT was successful as a recovery-design validation exercise, even though the last technical step failed.

It proved two important things at once:

1. the backup/recovery chain in `ODLUGRA2` can be prepared and exercised successfully, and
2. the desired large-production pattern of “recover one small tablespace quickly into a small independent STAGING database” cannot be assumed to work with native Db2 restore in this form.