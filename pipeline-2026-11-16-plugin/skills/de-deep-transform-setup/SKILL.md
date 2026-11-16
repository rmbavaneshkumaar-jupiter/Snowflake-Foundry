---
name: de-deep-transform-setup
description: Phase 4 (Transform Setup). Reads the approved Silver design and DQ rules and creates one load procedure per Silver table, plus batch log tables and loader grants. Procedures are created but never called. Use after de-deep-schema-setup and before de-deep-load-validate.
---

# de-deep-transform-setup

## When to Use

After de-deep-schema-setup is complete: Silver and quarantine tables exist and are empty, and the design tables in MONITORING are all APPROVED.

## When Not to Use

* To load data or run any procedure: use de-deep-load-validate.
* To build Gold: use de-deep-transform.
* If the design is not approved or a Silver table is missing: go back to the earlier skill.

## Inputs (ask the human if missing)

Database, Bronze schema, design schema, Silver schema, warehouse, role.

## Rules

* Create procedures and log tables only. NEVER call a procedure. No data is loaded.
* Use only the design tables (SILVER_TABLE_DESIGN, SILVER_COLUMN_DESIGN, SILVER_DQ_RULES, ROLE_DESIGN) and the real table definitions. Never infer columns, rules or modes. Read each design table's columns first.
* Run as SYSADMIN with secondary roles off. Never ACCOUNTADMIN, never ALL PRIVILEGES.
* Plain CREATE only: no OR REPLACE, no DROP, no ownership changes.
* Two human stopping points: after the PLAN and after the VERIFY report.
* Source is the Bronze table. Bronze columns are VARCHAR and are cast to the Silver types.

## Step 0: Checks (read-only)

a. All design table rows are APPROVED.
b. Role is not ACCOUNTADMIN and CURRENT_SECONDARY_ROLES() is empty. If not, STOP and ask the human to allow USE SECONDARY ROLES NONE for this chat.
c. Warehouse is usable. Silver and quarantine tables exist, with 0 rows.
d. DE_ roles from ROLE_DESIGN exist. No load procedure or batch log table exists yet. If any exists, report it and let the human choose reuse or rebuild.

If any check fails, STOP and name it.

## Step 1: Plan (STOPPING POINT 1)

For each Silver table write a mapping: Bronze source, Bronze column, Silver column, cast, cleaning rule, DQ rule ids. Then show:

a. The mapping summary and any cast that can fail.
b. One load procedure per Silver table, named LOAD_<TABLE>, taking a batch id.
c. The load mode per table from the design: INCREMENTAL_MERGE on the business key, or FULL_RELOAD (DELETE then INSERT).
d. Batch log tables in the design schema: one row per batch and table (rows read, loaded, quarantined, status) and one row per DQ rule per batch (rule id, failed rows).
e. Grants: DE_LOADER USAGE on the procedures, plus read and write on the log tables.
f. Statement count, target environment, affected objects, rollback plan (DROP of only the objects created here).

Procedures run as the caller, so the caller privileges apply. State this in the plan.

Do NOT build until the human approves.

## Step 2: Build

For each table, in order:

a. Read Bronze rows for the batch id. Cast with TRY_ casts so one bad value never aborts the load.
b. Evaluate every DQ rule for that table from SILVER_DQ_RULES. A row that fails any rule goes to the quarantine table with the reason, rule id and batch id, and is not written to Silver.
c. Parent rule: when an order is quarantined its lines, payments and returns are quarantined with reason PARENT_QUARANTINED. A quarantined product does not quarantine its lines.
d. Write passing rows to Silver with _SOURCE_BATCH_ID, _LOADED_AT and _UPDATED_AT set.
e. Write counts to the batch log tables. The procedure returns a summary and never stops the batch itself (thresholds belong to de-deep-load-validate).

Then create the log tables, then apply the grants. Do NOT call any procedure.

## Step 3: Verify

a. SHOW PROCEDURES: every planned procedure exists.
b. Every DQ rule id in SILVER_DQ_RULES is used by exactly one procedure.
c. Every Silver column has a mapping.
d. All Silver and quarantine tables still have 0 rows (proof nothing was called).
e. SHOW GRANTS: DE_LOADER has only what was planned. No extra grants.
f. Write every action to SETUP_LOG.

## Step 4: Report (STOPPING POINT 2)

Show: procedures created, log tables, grants, mapping file, row counts (all 0), deferred items. Wait for approval before de-deep-load-validate.

## Gotchas

* A procedure that compiles can still fail at run time. The first real test is Phase 5.
* FULL_RELOAD needs DELETE on that table, already granted to DE_LOADER on SILVER.PRODUCTS only.
* Masked PII columns return masked text to roles other than DE_PII_READER. Procedures must not read Silver PII to make decisions.
* Duplicate business keys inside one batch: record the rule as an open case; do not guess a winner.

## Failure Handling

Stop at the first failed statement. Do not retry, clean up or work around a privilege error. Report what was already created; the human decides rebuild or reuse at the next Step 0.

## Output

Load procedures, batch log tables, grants and SETUP_LOG rows in Snowflake, plus the mapping report.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-transform-setup_<batch-id>_report.md`, for example `de-deep-transform-setup_B001_report.md`.
- Batch ID: the latest batch ID in the Bronze tables (no batch is loaded by this skill).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: load procedures created (name and load mode per table), batch log tables, grants to DE_LOADER, the mapping summary and casts that can fail.
3. **Row counts**: row count of every Silver and quarantine table (must still be 0, proof that no procedure was called); number of DQ rule ids used per procedure.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every Step 3 verification (a to f).
5. **Quarantine**: no rows yet. List the DQ rule ids per procedure and the PARENT_QUARANTINED rule.
6. **Warnings and open items**: open cases (for example duplicate business keys), casts that can fail, deferred items.
7. **Handed to the next skill**: the LOAD_<TABLE> procedures, LOAD_BATCH_LOG and LOAD_DQ_LOG, used next by de-deep-load-validate.

After saving, show the file path and its line count. Do not start the next skill.
