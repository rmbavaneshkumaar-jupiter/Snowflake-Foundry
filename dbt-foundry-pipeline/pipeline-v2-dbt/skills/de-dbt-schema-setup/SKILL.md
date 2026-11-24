---
name: de-dbt-schema-setup
description: Phase 3 V2 (Setup for the dbt pipeline). Checks that the database, schemas, warehouse, pipeline role privileges and Git/dbt prerequisites are ready, creates the SETUP_LOG table and, only if masking is switched on in the config, one masking policy per PII data type. Creates no Silver, quarantine or Gold table (dbt does that) and no role. Use after the design (Skill 2) is APPROVED and before de-dbt-project-setup.
---

# de-dbt-schema-setup (Skill 3, Version 2)

Version 1 of this phase (de-deep-schema-setup) created roles, Silver tables, quarantine tables, masking policies and grants.
In Version 2:

- Silver and quarantine tables are created by dbt (Skills 4 and 5 V2). This skill must not create them, or two tools would own the same table.
- Roles are made by the admin, not by any skill. The pipeline uses one least-privilege role, named in the config.
- What stays here: readiness checks, the SETUP_LOG table, and the optional masking policies.

This skill is generic. It never contains a source table name, a column name, a role name or a threshold number. They come from the config and the design tables.

## When to Use

- The design tables are APPROVED and the dbt pipeline is being set up in an environment for the first time.
- Masking was switched on in the config and the policies do not exist yet.
- Re-checking an environment before a run (Step 0 and Step 3 only).

## When Not to Use

- To create Silver, quarantine or Gold tables: dbt does it (Skills 4, 5, 6 V2).
- To create roles or grant privileges: the admin does it.
- To change the design: go back to the schema design skill.

## Inputs (ask the human if missing, never assume)

1. Config file path. From it: database, warehouse, role, schemas, thresholds.
   Optional keys used by this skill: `masking` (on or off, default off), `pii_reader_role` (a role made by the admin that may see clear PII values).
2. Design schema.
3. Git repository object and dbt project object names (they may not exist yet).
4. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role from the config. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. USE SECONDARY ROLES NONE.
- **No role work**: never CREATE ROLE, GRANT or REVOKE. A missing privilege = STOP and show, in a code block, what the admin must grant. The admin runs it.
- **No table for dbt**: never create a Silver, quarantine or Gold table. If one exists that the pipeline role does not own and its name matches a planned dbt model, report it.
- Never create a database, schema or warehouse. They must exist.
- Plain CREATE only: no OR REPLACE, no IF NOT EXISTS, no DROP, no ALTER of existing objects.
- Never SELECT a PII column value. Use metadata and counts only.
- Two human STOP gates: after the PLAN and after the LOG.

## Step 0: Checks (read only)

Show each check as PASS or FAIL:

1. Config: every required key present. Show the values (no secrets in this file).
2. `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE();` Role = config role, secondary roles empty, role not ACCOUNTADMIN.
3. Database, Bronze, Silver, Gold and monitoring schemas exist. Warehouse exists and can run a query.
4. Design tables exist and every row is APPROVED.
5. Pipeline role privileges (SHOW GRANTS TO ROLE): USAGE on database, schemas, warehouse; SELECT on Bronze and design tables; CREATE TABLE on Silver; CREATE TABLE and CREATE DYNAMIC TABLE on Gold; CREATE TABLE on the monitoring schema; read on the Git repository; CREATE DBT PROJECT where the dbt project object will live. If `masking` is on: CREATE MASKING POLICY on the monitoring schema.
6. Git repository object exists and FETCH works. If not, STOP: the admin creates the API integration and the repository object.
7. If `masking` is on: `pii_reader_role` is set in the config and that role exists (SHOW ROLES). The list of PII columns and their Silver data types from the column design (names and types only).
8. SETUP_LOG and the planned masking policies do not exist yet. If any exists, STOP and ask: reuse or stop.

If a privilege is missing, list it for the admin and STOP. Do not try another role.

## Step 1: Plan (STOP GATE 1)

Show the exact statements, in order. Execute nothing.

a. SETUP_LOG table in the monitoring schema: OBJECT_TYPE, OBJECT_NAME, ACTION, STATUS, DETAIL, RUN_AT.
b. Only if `masking` is on: one masking policy per data type found in Step 0 item 7, in the monitoring schema, named `PII_<DATA_TYPE>_MASK`. Clear value only when `IS_ROLE_IN_SESSION('<pii_reader_role>')` is true; else a fixed mask value of the same type. Each policy gets a COMMENT.
c. What is NOT done here: the policies are attached to columns by dbt after every build (see Skill 4 V2, masking post-hook), because a dbt rebuild removes anything attached by hand.
d. Counts per object type, and the rollback: the admin drops the new objects (this skill never drops).

Wait for explicit approval.

Masking policy shape:

```sql
CREATE MASKING POLICY <DATABASE>.<MONITORING_SCHEMA>.PII_VARCHAR_MASK
  AS (VAL VARCHAR) RETURNS VARCHAR ->
  CASE WHEN IS_ROLE_IN_SESSION('<PII_READER_ROLE>') THEN VAL ELSE '***MASKED***' END
  COMMENT = 'Foundry V2: clear PII only for the PII reader role';
```

For other types use a mask of that type (number: NULL, date: NULL), never a value that looks real.

## Step 2: Build

Run the approved statements one by one. After each, write one row to SETUP_LOG (OK or the error). On the first error STOP: report the statement, the error and what was already created. Do not retry, do not clean up.

## Step 3: Verify (read only)

1. SETUP_LOG exists and has one row per statement.
2. If masking is on: SHOW MASKING POLICIES in the monitoring schema shows each planned policy, owner = pipeline role.
3. No Silver, quarantine or Gold table was created by this skill (compare SHOW TABLES with Step 0).
4. Every Step 0 check still PASS.

## Step 4: Log and report (STOP GATE 2)

Write the verify results to SETUP_LOG. Show: objects created, every check with PASS or FAIL, missing privileges for the admin, and the PII columns that dbt will mask after each build. Wait for approval before de-dbt-project-setup.

## Gotchas

- A masking policy works only on columns of its own data type: one policy per type.
- Quarantine tables also hold raw PII values (as text). The masking post-hook must cover them too.
- Bronze also holds raw PII. Masking Bronze is not part of this skill (open item).
- IS_ROLE_IN_SESSION is true also when the PII reader role is inherited by the current role. The pipeline role must not inherit it.
- The masking post-hook in dbt needs the pipeline role to own the table (dbt builds it, so it does) and the policy.
- Masking on a table that a dynamic table reads: check that the Gold dynamic tables still refresh after masking is switched on (untested).

## Failure Handling

- Privilege error: STOP, show the missing privilege for the admin. Never switch role.
- Object already exists: STOP and ask.
- Partial build: report what exists; the human decides at the next Step 0.

## Output

A ready environment (all checks PASS), SETUP_LOG, and, if masking is on, one masking policy per PII data type, handed to de-dbt-project-setup.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 4. Otherwise skip this step.

- File: `pipeline-reports/de-dbt-schema-setup_<batch-id>_report.md`. Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, Quarantine (none here), Warnings and open items, Handed to the next skill.
- No PII values, no secrets. Numbers only from queries in this session.
