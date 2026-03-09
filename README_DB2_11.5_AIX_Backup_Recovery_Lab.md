# DB2 11.5 AIX – Backup & Recovery Lab Documentation Pack

## Recommended file hierarchy

- `README_DB2_11.5_AIX_Backup_Recovery_Lab.md`  
  Entry point and navigation.
- `01_DB2_11.5_AIX_Backup_Recovery_Main_Document.md`  
  Main technical document for architecture, objectives, design assumptions, validated lab scope, and production considerations.
- `02_DB2_11.5_AIX_Backup_Recovery_Lab_Runbook.md`  
  Hands-on lab runbook with step-by-step commands, observed outputs, timestamps, and recovery workflow.
- `03_DB2_11.5_AIX_Backup_Recovery_Validated_Findings_and_Gaps.md`  
  Summary of what was fully validated, what was partially validated, known errors, syntax traps, and recommended next steps.

## Intended audience

Technical Lead / Solution Architect / Senior DB2 SME.

## Scope

The documents cover a DB2 11.5 backup and recovery lab on AIX 7.2, including:

- offline full backup baseline,
- online full backup,
- online incremental backup,
- archive logging configuration,
- point-in-time recovery concept,
- tablespace-level recovery using a separate staging database,
- error analysis and syntax pitfalls,
- design considerations for scaling toward large environments (including a future ~400 TB production target).

## Important note on validation status

The lab documentation clearly separates:

- **validated steps** – executed and confirmed in the lab,
- **derived recovery procedure** – technically correct sequence prepared from the validated lab state,
- **open item** – one recovery branch where the redirected tablespace restore into the staging database was not fully completed during the captured session.

