---
name: de-deep-share-monitor
description: Final phase of the Foundry pipeline. Part A audits roles, grants, masking and Gold-only access and writes a governance report. Part B builds cost and health views in MONITORING so every batch shows credits per skill and per 1,000 rows. Use after de-deep-transform has passed STOP 2.
---

# de-deep-share-monitor

## When Not to Use
- Before Skills 1-6 are complete and approved.
- To change roles, grants, Silver or Gold objects (this skill only reads them and writes MONITORING objects).

## Inputs (ask the user, do not assume)
Database, MONITORING schema name, warehouse, the batch IDs to report on, the time window (start/end) of each skill run if known, and the maximum credits allowed per run (suggest 5.0).

## Rules
- Run as SYSADMIN. Never use ACCOUNTADMIN, ALL PRIVILEGES or OWNERSHIP grants. USE SECONDARY ROLES NONE.
- Create only objects in MONITORING. Never modify Bronze, Silver, Gold, quarantine tables, procedures, or Skills 1-6 outputs. No DROP, no DELETE, no CREATE OR REPLACE on existing objects.
- Read-only on usage data. Credit figures are ESTIMATES: warehouse credits are metered per hour, so each hour is split across queries by elapsed time. Say this in the report.
- Two stopping points: STOP 1 (plan) and STOP 2 (report). Do nothing that creates objects before STOP 1 is approved.

## Step 0 - Pre-checks (read only)
1. Confirm ROLE_DESIGN, LOAD_BATCH_LOG, LOAD_DQ_LOG and both Gold Dynamic Tables exist. DESCRIBE LOAD_BATCH_LOG and LOAD_DQ_LOG and use their real column names.
2. Check SYSADMIN can read SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY and QUERY_HISTORY. If not, STOP and tell the user the exact grant an administrator must run (a usage-viewer database role on SNOWFLAKE for SYSADMIN). Do not try to grant it yourself.
3. Check whether SYSADMIN has EXECUTE ALERT. If not, Part B alerts will be skipped and reported as skipped.
4. Note: usage views lag up to about 3 hours. If the batch finished less than 3 hours ago, warn that costs may be incomplete.

## Step 1 - Plan (STOP 1)
Show: the checks Part A will run, the objects Part B will create (below), the credit limit per run, what will be skipped and why. Wait for approval.

## Step 2 - Part A: Share (governance audit)
Read ROLE_DESIGN and SHOW GRANTS for each design role. For each role test with USE ROLE and record expected vs actual:
- DE_ANALYST: can SELECT both Gold tables; cannot SELECT any Silver or Bronze table.
- DE_LOADER: can CALL the LOAD_ procedures; cannot SELECT Gold; no DELETE except SILVER.PRODUCTS.
- DE_TRANSFORMER: can read Silver, owns Gold Dynamic Tables.
- DE_PII_READER: sees real values in the 3 masked columns; every other role sees masked values.
- No role holds ACCOUNTADMIN, ALL PRIVILEGES or OWNERSHIP outside the design.
Write results to MONITORING.ACCESS_AUDIT_RESULT (CHECK_NAME, ROLE_NAME, EXPECTED, ACTUAL, STATUS, CHECKED_AT). Then USE ROLE SYSADMIN again.

## Step 3 - Part B: Monitor (create objects)
1. MONITORING.PIPELINE_PHASE_LOG (RUN_LABEL, PHASE, START_TIME, END_TIME, BATCH_ID): insert the phase windows the user gave. Leave unknown phases out; do not invent times.
2. MONITORING.PIPELINE_CREDIT_LIMIT (MAX_CREDITS_PER_RUN) with the approved value.
3. View MONITORING.VW_PIPELINE_COST: per phase and batch - start, end, minutes, estimated warehouse credits (hourly credits split by query elapsed time), cloud services credits, query count.
4. View MONITORING.VW_PIPELINE_COST_PER_ROW: credits per 1,000 rows loaded, from VW_PIPELINE_COST and LOAD_BATCH_LOG. This is the base for the credit estimation model.
5. View MONITORING.VW_PIPELINE_HEALTH: per batch - rows loaded, rows quarantined, quarantine rate, status, total credits, credits vs limit (OK / OVER).
6. If EXECUTE ALERT is available: create MONITORING.ALERT_LOG table and two alerts (quarantine rate above the threshold; run credits above the limit) whose action inserts a row into ALERT_LOG. Create them SUSPENDED. Never RESUME without explicit user approval.

## Step 4 - Verify
Query each view, show the rows. Check the sum of phase credits does not exceed total metered credits for the window. Check ACCESS_AUDIT_RESULT has no FAIL. Show any gaps (missing phase windows, lagging usage data).

## Step 5 - Report (STOP 2)
Give: audit table (PASS/FAIL per check), cost table per phase with credits and credits per 1,000 rows, health view output, objects created, alerts created or skipped, open items, and a one-line capability statement. Remind that figures are estimates. Wait for approval, then log completion only if the role you are using has permission; otherwise say it was not logged.

## Failure handling
Any check FAIL or missing access: stop, show the exact error and what is needed. Do not work around permissions.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-share-monitor_<batch-id>_report.md`, for example `de-deep-share-monitor_B001_report.md`.
- Batch ID: the batch IDs reported in this run, joined with a hyphen (for example B001-B002).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: access audit run per role, MONITORING objects created, alerts created or skipped and why.
3. **Row counts**: rows in ACCESS_AUDIT_RESULT (PASS and FAIL count), rows in PIPELINE_PHASE_LOG, and the rows of VW_PIPELINE_HEALTH per batch.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every audit check and the credits against the limit (OK or OVER).
5. **Quarantine**: quarantine rate per batch from VW_PIPELINE_HEALTH.
6. **Warnings and open items**: every FAIL in the audit, missing phase windows, usage data lag; say that credit figures are estimates.
7. **Handed to the next skill**: this is the last skill. Name the MONITORING views the team uses, and what the next batch or the orchestrator should check.

After saving, show the file path and its line count. Do not start the next skill.
