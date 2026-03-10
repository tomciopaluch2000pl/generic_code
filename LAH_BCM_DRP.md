# LAH Business Continuity Management (BCM) and Disaster Recovery Plan (DRP)

## 1. Document Control

| Field | Value |
|---|---|
| Document Title | LAH Business Continuity Management (BCM) and Disaster Recovery Plan (DRP) |
| Document Owner | [To be completed] |
| Reviewers | [To be completed] |
| Approvers | [To be completed] |
| Version | [To be completed] |
| Status | [To be completed] |
| Last Review Date | [To be completed] |
| Next Review Date | [To be completed] |

---

## 2. Executive Summary

This document defines the Business Continuity Management (BCM) and Disaster Recovery Plan (DRP) for the LAH solution.

LAH is an archiving solution running on AIX 7.2 and based on IBM DB2 and IBM Content Manager OnDemand (CMOD) 10.5. The solution is used for archiving banking documents and therefore supports legal and compliance-related retention and recoverability requirements.

This document covers unplanned recovery events only. It describes the recovery model, ownership boundaries, key dependencies, backup and restore scope, recovery scenarios, validation criteria, and operational runbooks required to restore LAH service capability and, where needed, recover archived data access.

LAH is classified as a Tier 3 service with an agreed recovery target of up to 72 hours.

The recovery model distinguishes clearly between:
- infrastructure recovery performed by supporting platform teams,
- application recovery performed by the LAH team,
- and data/feed recovery paths depending on the failure scenario.

This document applies to the LAH production environments P1, P3, and P6. The recovery architecture and process are materially the same across all three environments, with environment-specific values documented separately.

---

## 3. Purpose and Scope

### 3.1 Purpose

The purpose of this document is to provide a formal and operationally usable BCM/DRP reference for the LAH solution. It is intended to support:
- governance and architecture review,
- audit and control review,
- technical recovery execution,
- operational recovery coordination across involved teams.

### 3.2 In Scope

This document covers the LAH application stack and its recovery model, including:
- IBM CMOD 10.5
- DB2 instance and CMOD databases
- application scripts
- configuration files
- crontab/scheduler configuration
- SSL certificates used for HCP S3 communication
- IBM Storage Protect client configuration
- inbound feed handling via MFT and dropbox
- local backup folder used to retain archived feeds for 30 days
- DB2 restore and recovery procedures, including tablespace-level recovery where applicable

This document applies to the following production environments:
- P1
- P3
- P6

### 3.3 Out of Scope

The following items are outside the direct ownership scope of the LAH team, although they remain dependencies for successful recovery:
- infrastructure failover or LPAR relocation performed by Midrange Team
- host/platform backup infrastructure operated by Backup Team
- upstream application internal recovery procedures
- network/firewall/DNS platform recovery outside the LAH application scope
- enterprise-level communication processes outside local incident coordination

### 3.4 Scope Boundary Note

Infrastructure recovery is outside the direct execution scope of LAH. However, LAH remains responsible for validating application readiness and restoring application functionality once the required target infrastructure is made available.

---

## 4. Solution Overview

LAH is an archiving solution hosted on AIX 7.2. It uses IBM DB2 as the database engine for IBM Content Manager OnDemand (CMOD) 10.5. The solution receives inbound feeds through MFT into a dropbox area and archives them through CMOD into HCP S3 object storage.

For older archived content retrieval scenarios, the solution also depends on IBM Storage Protect client connectivity to a Storage Protect server managed within the LAH support model.

The solution includes:
- AIX 7.2 host
- DB2 instance
- one or more DB2 databases used by CMOD
- IBM CMOD 10.5 binaries and configuration
- application scripts
- crontab scheduler for feed pickup and processing
- SSL certificates for HCP S3 communication
- Storage Protect client configuration
- MFT inbound flow into dropbox
- separate local filesystem for retained backup feeds

### P3 Environment Note

P3 follows the same recovery model as P1 and P6. However, P3 has higher operational complexity because it hosts four CMOD instances / four DB2 databases under one DB2 instance. This does not change the recovery design, but it may increase execution effort and validation scope.

---

## 5. Recovery Objectives

### 5.1 Service Tier

LAH is classified as a **Tier 3** service.

### 5.2 Recovery Time Objective (RTO)

The target recovery time objective is:

**RTO: up to 72 hours**

### 5.3 Recovery Point Objective (RPO) Interpretation

LAH is a legal/compliance-oriented archiving solution. A traditional time-based RPO is not the primary recovery measure.

Instead, recoverability is based on the following principles:
- if currently transferred inbound feeds are lost before archival completion, they may be recovered through replay or resend mechanisms,
- if archived historical data or DB2 metadata is impacted, recovery is performed through DB2 backup, restore, rollforward, and where necessary tablespace-level recovery,
- if required, recently archived feeds can be replayed from the retained local backup area.

As a result, recovery is governed by recoverability and restoration capability rather than by a fixed acceptable data loss window.

---

## 6. Assumptions and Prerequisites

Recovery under this document assumes the following:

- a target LPAR/host is made available by Midrange Team,
- the target environment supports the required AIX version,
- compatible DB2, CMOD, and Storage Protect client versions are available,
- IBM Storage Protect client version is 8.1.25 or later,
- backup data required for restore is available and accessible,
- required application files, configuration files, and credentials are recoverable,
- required SSL certificates are available,
- connectivity to HCP S3 is restored,
- connectivity to MFT/dropbox path is restored,
- connectivity to Storage Protect services is restored where retrieval validation is required,
- required privileged access and service accounts are available to the recovery teams.

---

## 7. Roles and Responsibilities

### 7.1 LAH Team

The LAH Team is responsible for:
- defining application backup scope,
- identifying critical recovery assets,
- performing application-level restore and recovery,
- restoring DB2, CMOD, scripts, configuration, scheduler, and certificates,
- validating application functionality after recovery,
- replaying retained inbound feeds where applicable,
- executing DB2 recovery procedures for historical data recovery cases.

### 7.2 Midrange Team

The Midrange Team is responsible for:
- restoring or re-hosting the required AIX infrastructure,
- making target LPAR capacity available,
- enabling the underlying host platform for LAH recovery.

### 7.3 Backup Team

The Backup Team is responsible for:
- operating the host backup platform,
- maintaining backup data stored on their Storage Protect infrastructure,
- supporting Storage Protect client configuration as it relates to platform backup/recovery.

The Backup Team is not responsible for deciding which LAH application assets must be protected. That scope is defined by the LAH Team.

### 7.4 MFT Team

The MFT Team is responsible for:
- maintaining the MFT service and transfer path used to deliver inbound data into LAH dropbox,
- supporting restoration of transfer capability where MFT is part of the failure scenario.

### 7.5 AppStreams / Upstream Applications

Upstream applications are responsible for:
- resending data when required and when original inbound data was lost before archive completion,
- observing the process in which source-side cleanup should only happen after confirmation that archival to CMOD has completed successfully.

---

## 8. RACI Matrix

| Activity | LAH Team | Midrange Team | Backup Team | MFT Team | AppStreams |
|---|---|---|---|---|---|
| Declare LAH recovery need | R/A | C | C | C | C |
| Provide target AIX/LPAR | C | R/A | I | I | I |
| Restore host backup platform data | C | C | R/A | I | I |
| Define application recovery scope | R/A | I | C | I | I |
| Restore DB2 / CMOD / config / scripts | R/A | C | C | I | I |
| Support SP client configuration | C | I | R/A | I | I |
| Restore MFT transfer capability | I | I | I | R/A | C |
| Replay retained inbound feeds | R/A | I | C | C | I |
| Resend lost inbound feeds | I | I | I | C | R/A |
| Validate service recovery | R/A | C | C | C | C |
| Perform historical DB2 recovery | R/A | I | C | I | I |

Legend:  
**R** = Responsible  
**A** = Accountable  
**C** = Consulted  
**I** = Informed

---

## 9. Dependencies

LAH depends on the following key internal and external components:

- AIX 7.2 host / LPAR availability
- DB2
- IBM CMOD 10.5
- HCP S3 object storage
- IBM Storage Protect client 8.1.25 or later
- Storage Protect services used for retrieval of older archived objects
- MFT transfer path
- SSL certificates
- AppStreams / upstream feed providers
- network, DNS, firewall rules, service accounts, and access controls

This section is intentionally brief. Detailed environment values are maintained in the environment inventory section.

---

## 10. Backup Policy and Recovery Assets

### 10.1 Backup Domains

The LAH recovery model distinguishes the following backup and recovery domains:
- AIX host / filesystem backup
- DB2 database backup and recovery
- application flat files backup
- 30-day inbound feed retention area
- HCP archived content (high-level only)
- Storage Protect retrieval dependency for older archived objects

### 10.2 Backup Ownership Model

- The **Backup Team** operates the backup platform and is responsible for data backed up to their Storage Protect infrastructure.
- The **LAH Team** is responsible for defining which LAH application components must be included in backup scope.
- The **LAH Team** performs application-level restore activities.
- The **Backup Team** supports recovery of protected host/filesystem backup data when required.

### 10.3 Recovery Assets Required

The following items are considered critical recovery assets:
- DB2 instance configuration
- DB2 databases
- CMOD binaries and configuration
- application scripts
- crontab entries
- SSL certificates
- Storage Protect client configuration
- MFT/dropbox-related files and directories
- application directories and flat files needed for restore

### 10.4 30-Day Inbound Feed Retention

Feeds that have been archived are retained for 30 days in a separate local filesystem. This retention area is backed up through the host backup platform under Backup Team operation.

This retained area supports replay-based recovery for recent inbound data.

### 10.5 HCP Archived Content

Archived content stored in HCP is part of the end-state archival model. Detailed content policy is maintained separately and is not expanded in this document beyond recovery dependency context.

---

## 11. BCM and DR Invocation Triggers

BCM and/or DRP may be invoked in the following unplanned situations:

- AIX host or LPAR is unavailable
- entire pSeries hosting location becomes unavailable
- LAH archiving capability is unavailable
- DB2 or CMOD becomes corrupted or unusable
- application/configuration layer is lost or damaged
- inbound feed area is lost before archive completion
- historical data recovery is required following accidental disposal or logical data loss
- DB2 recovery is required to re-establish access to historical content or metadata

---

## 12. Recovery Scenario Classification

### Scenario 1 â Loss of Archiving Capability

LAH application cannot perform archiving, but the primary issue is service availability rather than historical content recovery.

### Scenario 2 â Loss of Inbound Feeds Before Archive Completion

Data in dropbox or inbound flow is lost before successful archival to CMOD.

### Scenario 3 â Loss or Corruption of Application / Configuration Layer

DB2, CMOD, application scripts, scheduler configuration, certificates, or related technical assets are lost or corrupted.

### Scenario 4 â Historical Data Issue / Accidental Disposal / DB2 Recovery Case

Recovery is required for historical archived content access, metadata consistency, accidental disposal, or DB2-level data recovery, including tablespace-level procedures.

---

## 13. Official Inbound Feed Recovery Model

LAH supports three approved inbound data recovery paths:

### 13.1 Replay from 30-Day Local Backup Folder

If inbound data had already been archived and retained in the local backup area, the LAH Team may replay the feed by moving it again into the dropbox area.

### 13.2 Restore from Host / Filesystem Backup

If the local retained feed area is lost, data may be restored from the host/filesystem backup platform operated by the Backup Team.

### 13.3 Resend from AppStreams

If inbound data was lost before archival completion and is no longer available locally, AppStreams may resend the data. In principle, upstream applications should only remove data after confirmation that archival into CMOD was completed successfully.

---

## 14. High-Level Recovery Process

1. Identify the failure scenario.
2. Determine whether infrastructure recovery by Midrange Team is required.
3. Ensure required host/LPAR capacity is made available.
4. Confirm availability of recovery assets and backups.
5. Restore the LAH application layer as required:
   - DB2
   - CMOD
   - scripts
   - configuration
   - certificates
   - scheduler
   - connectivity
6. Recover inbound feed handling if required.
7. Perform scenario-specific validation.
8. Confirm acceptance criteria for restored service.
9. Return solution to operational state.

---

## 15. Detailed Runbook

### 15.1 Infrastructure Readiness Checks

1. Confirm with Midrange Team that target AIX host/LPAR is available.
2. Confirm OS version:

```sh
oslevel -s
```

3. Confirm filesystem layout:

```sh
df -g
mount
```

4. Confirm required application users/groups:

```sh
lsuser ALL
lsgroup ALL
```

5. Confirm network basics:

```sh
hostname
netstat -rn
nslookup <hcp-endpoint>
ping <hcp-endpoint>
```

### 15.2 DB2 Recovery Steps

#### 15.2.1 Confirm DB2 Environment

```sh
su - <db2_instance_owner>
db2level
db2ilist
db2 get dbm cfg
```

#### 15.2.2 List Databases

```sh
db2 list db directory
```

#### 15.2.3 Activate Database

```sh
db2 activate db <DB_NAME>
```

#### 15.2.4 Database Backup Examples

```sh
db2 backup database <DB_NAME> online to <BACKUP_PATH> include logs compress
```

Incremental example:

```sh
db2 backup database <DB_NAME> online incremental to <BACKUP_PATH> include logs compress
```

#### 15.2.5 Full Database Restore Example

```sh
db2 restore db <DB_NAME> from <BACKUP_PATH> taken at <TIMESTAMP> replace existing without prompting
```

#### 15.2.6 Rollforward Example

```sh
db2 rollforward db <DB_NAME> to end of logs and complete
```

Point-in-time example:

```sh
db2 rollforward db <DB_NAME> to <YYYY-MM-DD-HH.MM.SS> using local time and complete
```

#### 15.2.7 Check Rollforward State

```sh
db2 rollforward db <DB_NAME> query status
```

#### 15.2.8 Tablespace-Level Restore Example

```sh
db2 restore db <SRC_DB> tablespace (<TBSP_NAME>) from <BACKUP_PATH> taken at <TIMESTAMP> into <STAGING_DB> redirect without prompting
```

If redirected restore is used:

```sh
db2 set tablespace containers for <TBSP_ID> using (file '<PATH1>' <SIZE>, file '<PATH2>' <SIZE>)
db2 restore db <SRC_DB> continue
```

Then rollforward:

```sh
db2 rollforward db <STAGING_DB> to <YYYY-MM-DD-HH.MM.SS> using local time and complete overflow log path (<LOGPATH>)
```

Data extraction after recovery example:

```sh
db2 connect to <STAGING_DB>
db2 "export to /tmp/recovered_rows.ixf of ixf select * from <SCHEMA>.<TABLE> where <CONDITION>"
```

Optional import back to source database:

```sh
db2 connect to <SOURCE_DB>
db2 "import from /tmp/recovered_rows.ixf of ixf insert into <SCHEMA>.<TABLE>"
```

#### 15.2.9 Validation Commands

```sh
db2 list active databases
db2 connect to <DB_NAME>
db2 "select current server from sysibm.sysdummy1"
db2 "list tablespaces show detail"
```

### 15.3 CMOD Recovery Steps

1. Confirm CMOD binaries are present:

```sh
lslpp -L | grep -i ondemand
```

2. Confirm CMOD environment configuration files are restored:

```sh
ls -l <CMOD_CONFIG_PATH>
```

3. Confirm CMOD instance-specific settings:

```sh
grep -i -E "db|server|cache|archive" <CMOD_CONFIG_FILE>
```

4. Start required CMOD services according to local operating model:

```sh
[CMOD start command placeholder]
```

5. Validate CMOD process state:

```sh
ps -ef | grep -i ondemand
```

6. Perform application-level archive/retrieve validation using locally approved commands or administrative procedures:

```sh
[CMOD validation command placeholder]
```

Where exact CMOD commands are environment-specific, the local operational command set should be inserted into this runbook.

### 15.4 Application Scripts and Configuration Recovery

1. Restore scripts and configuration directories from backup if required.
2. Confirm presence and permissions:

```sh
ls -l <SCRIPT_PATH>
ls -l <CONFIG_PATH>
```

3. Compare key files against known baseline if available:

```sh
diff <restored_file> <baseline_file>
```

4. Ensure executable permissions:

```sh
chmod 750 <script_name>
```

5. Confirm ownership:

```sh
chown <owner>:<group> <file_or_dir>
```

### 15.5 Scheduler / Crontab Recovery

1. Review current crontab:

```sh
crontab -l
```

2. Restore crontab entries from backup/source record if needed:

```sh
crontab <crontab_file>
```

3. Confirm scheduler entries are present and correct:

```sh
crontab -l | grep -i <job_identifier>
```

4. Confirm expected scheduler-related logs:

```sh
ls -l <LOG_PATH>
tail -100 <SCHEDULER_LOG>
```

### 15.6 HCP / SSL Validation

1. Confirm certificate files:

```sh
ls -l <CERT_PATH>
```

2. Check certificate metadata:

```sh
openssl x509 -in <CERT_FILE> -text -noout
```

3. Validate endpoint connectivity:

```sh
openssl s_client -connect <HCP_ENDPOINT>:443
```

4. Validate application-level HCP access through LAH/CMOD-integrated procedure:

```sh
[HCP access validation placeholder]
```

### 15.7 Storage Protect Client Validation

1. Confirm installed client level:

```sh
dsmc q sess
```

2. Confirm configuration files:

```sh
ls -l <SP_CLIENT_CONFIG_PATH>
cat <dsm.sys>
cat <dsm.opt>
```

3. Validate connection:

```sh
dsmc q inclexcl
```

4. If required, perform test retrieval validation according to approved local procedure:

```sh
[Storage Protect retrieval validation placeholder]
```

### 15.8 MFT / Dropbox Validation

1. Confirm dropbox path availability:

```sh
ls -l <DROPBOX_PATH>
df -g <DROPBOX_PATH>
```

2. Confirm permissions:

```sh
ls -ld <DROPBOX_PATH>
```

3. Confirm recent file arrival or MFT flow recovery:

```sh
ls -ltr <DROPBOX_PATH> | tail
```

4. Coordinate with MFT Team if transport recovery is required.

### 15.9 Inbound Feed Replay / Resend Handling

#### Replay from Local 30-Day Backup Folder

```sh
ls -ltr <BACKUP_FEED_PATH>
cp <BACKUP_FEED_PATH>/<file> <DROPBOX_PATH>/
```

or, if move is the approved method:

```sh
mv <BACKUP_FEED_PATH>/<file> <DROPBOX_PATH>/
```

#### Restore from Backup Platform

Coordinate with Backup Team to restore required filesystems/directories, then validate:

```sh
ls -ltr <RESTORED_BACKUP_FEED_PATH>
```

#### Resend from AppStreams

Open recovery request with AppStreams for affected feeds and confirm replay into dropbox after transport is re-established.

### 15.10 Historical Data Recovery / DB2 Tablespace Recovery

This scenario applies where historical content access is affected, including accidental disposal or logical metadata loss.

Recommended method where applicable:
1. identify affected DB2 objects,
2. select correct backup image,
3. restore into staging DB if isolated recovery is needed,
4. roll forward to required point in time,
5. extract required rows/data,
6. reintroduce recovered data into source environment only through approved controlled procedure.

Example history inspection:

```sh
db2 list history backup all for <DB_NAME>
db2 list history rollforward all for <DB_NAME>
```

Example tablespace inspection:

```sh
db2 connect to <DB_NAME>
db2 "select tbsp_name, tbsp_id from sysibmadm.tbsp_utilization"
```

Example catalog query:

```sh
db2 "select tbspaceid, tbspace from syscat.tablespaces"
```

Any production recovery involving historical records must be executed carefully and documented according to the incident handling standard in place.

---

## 16. Post-Recovery Validation Checklists

### 16.1 Common Service Restored Acceptance Criteria

Recovery is considered complete only after functional validation, not only after technical restore.

The following criteria define minimum recovery acceptance:
- DB2 instance is available
- required DB2 databases are accessible
- CMOD services are operational
- required configuration files are present
- required scripts are present and executable
- scheduler is active and correct
- HCP S3 connectivity works
- SSL certificates are valid and usable
- Storage Protect client path works where required
- MFT/dropbox path is operational
- scenario-specific validation succeeds

### 16.2 Scenario 1 â Loss of Archiving Capability

Checklist:
- DB2 accessible
- CMOD operational
- dropbox reachable
- scheduler active
- test archive succeeds

### 16.3 Scenario 2 â Loss of Inbound Feeds Before Archive Completion

Checklist:
- affected feed window identified
- recovery path selected: replay / restore / resend
- dropbox restored
- reprocessing completed
- archival confirmation re-established

### 16.4 Scenario 3 â Loss/Corruption of Application Layer

Checklist:
- configuration restored
- DB2 restored/recovered
- CMOD configuration correct
- certificates restored
- SP client config restored
- scripts and crontab restored
- application flow validated end to end

### 16.5 Scenario 4 â Historical Data Recovery

Checklist:
- correct point-in-time defined
- correct backup source identified
- staging recovery or direct recovery completed
- recovered data validated
- business/technical acceptance obtained where required

---

## 17. Risks and Limitations

- recovery depends on Midrange Team making a suitable target LPAR available,
- host/filesystem recovery depends on backup platform availability managed by Backup Team,
- replay of recent inbound feeds is limited by the 30-day retained feed window,
- resend from AppStreams depends on source-side data still being available,
- environment-specific values are not embedded in this core document and must be maintained in the environment inventory,
- P3 recovery may require more time and coordination due to its multiple CMOD/DB2 database structure,
- historical data recovery may require advanced DB2 point-in-time or tablespace-level procedures and should be handled carefully.

---

## 18. Combined Environment Inventory Table

| Attribute | P1 | P3 | P6 |
|---|---|---|---|
| Hostname | [To be completed] | [To be completed] | [To be completed] |
| LPAR Name | [To be completed] | [To be completed] | [To be completed] |
| AIX Version | [To be completed] | [To be completed] | [To be completed] |
| DB2 Instance Name | [To be completed] | [To be completed] | [To be completed] |
| DB2 Instance Owner | [To be completed] | [To be completed] | [To be completed] |
| Database Name(s) | [To be completed] | [To be completed] | [To be completed] |
| Number of CMOD Instances | [To be completed] | [To be completed] | [To be completed] |
| CMOD Config Path | [To be completed] | [To be completed] | [To be completed] |
| Script Path | [To be completed] | [To be completed] | [To be completed] |
| Scheduler / Crontab Owner | [To be completed] | [To be completed] | [To be completed] |
| Dropbox Path | [To be completed] | [To be completed] | [To be completed] |
| 30-Day Backup Feed Path | [To be completed] | [To be completed] | [To be completed] |
| HCP Endpoint | [To be completed] | [To be completed] | [To be completed] |
| HCP Namespace | [To be completed] | [To be completed] | [To be completed] |
| Certificate Path | [To be completed] | [To be completed] | [To be completed] |
| SP Client Config Path | [To be completed] | [To be completed] | [To be completed] |
| MFT Dependency Notes | [To be completed] | [To be completed] | [To be completed] |
| Recovery Notes | [To be completed] | [To be completed] | [To be completed] |

---

## 19. Contacts and Escalation Placeholders

| Team | Primary Contact | Secondary Contact | Distribution List | Escalation |
|---|---|---|---|---|
| LAH Team | [To be completed] | [To be completed] | [To be completed] | [To be completed] |
| Midrange Team | [To be completed] | [To be completed] | [To be completed] | [To be completed] |
| Backup Team | [To be completed] | [To be completed] | [To be completed] | [To be completed] |
| MFT Team | [To be completed] | [To be completed] | [To be completed] | [To be completed] |
| AppStreams | [To be completed] | [To be completed] | [To be completed] | [To be completed] |

---

## 20. Glossary and Abbreviations

| Term | Meaning |
|---|---|
| BCM | Business Continuity Management |
| DRP | Disaster Recovery Plan |
| RTO | Recovery Time Objective |
| RPO | Recovery Point Objective |
| AIX | IBM UNIX operating system |
| DB2 | IBM DB2 database platform |
| CMOD | IBM Content Manager OnDemand |
| HCP | Hitachi Content Platform |
| MFT | Managed File Transfer |
| LPAR | Logical Partition |
| SP | IBM Storage Protect |
