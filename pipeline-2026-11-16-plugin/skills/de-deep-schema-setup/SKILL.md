---
name: de-deep-schema-setup
description: Build the approved design as real Snowflake objects - Silver tables, quarantine tables, roles, masking policies and grants - read from the design tables, verify them against the design, log the result, then stop. DDL only; loads no data. Use after de-deep-schema-design is approved.
parent_skill: de-workflow
tools: [snowflake_sql, Write]
---

# de-deep-schema-setup

## Purpose

Step 3 of the pipeline. Schema design wrote a plan into design tables and the human approved it. This skill builds that plan exactly as written. It is DDL only: it loads no data, never reads or changes Bronze data, and never builds Gold. Build time only; daily runs use Tasks.

## When to Use

* All design tables are APPROVED and none of their objects exist yet
* A fresh environment needs the approved design built for the first time

## When Not to Use

* A design table is missing, empty or not APPROVED (run de-deep-schema-design first)
* To load, transform or fix data
* To change the design (revise it in de-deep-schema-design, get approval, then come back)
* To build Gold tables (Gold is built by the transform skill)

## Inputs (ask, never assume)

* Database
* Bronze schema, Silver schema, Gold schema
* Design schema (where the design tables live)
* Warehouse (must exist; never create one)
* Role to run as (must not be ACCOUNTADMIN, never ALL PRIVILEGES)

## Design tables read

* SILVER_TABLE_DESIGN: silver tables, business keys, load modes, status
* SILVER_COLUMN_DESIGN: column names, target types, PII and masking flags
* ROLE_DESIGN: roles, schemas, privileges, purpose, status
* GOLD_TABLE_DESIGN: read only to know which Gold schema objects will come later
* Profile table of source columns (column profile): source column names for quarantine tables

## Steps

0. CHECK. Show each result as PASS or FAIL:
   * SILVER_TABLE_DESIGN, ROLE_DESIGN and GOLD_TABLE_DESIGN exist, are not empty and every row has status APPROVED. Otherwise STOP.
   * CURRENT_ROLE() is not ACCOUNTADMIN. Otherwise STOP.
   * CURRENT_SECONDARY_ROLES() is empty. Secondary roles such as ALL bring hidden privileges. Otherwise STOP and tell the human to turn them off.
   * The warehouse exists and is usable. Otherwise STOP.
   * The database, Bronze, Silver, Gold and design schemas exist. This skill never creates a database or schema.
   * No Silver table, quarantine table, role or masking policy named in the design already exists (SHOW and INFORMATION_SCHEMA, read-only). If any exists, STOP and ask: rebuild or reuse. Never drop, replace or overwrite on your own.
1. PLAN. Translate the design into an ordered list of statements. Execute nothing. Order:
   a. Roles from ROLE_DESIGN (one CREATE ROLE per distinct role) and GRANT ROLE to the build role's parent as the design says (for example to SYSADMIN)
   b. Silver tables: names, column names, types, nullability, business key and audit columns exactly as in SILVER_TABLE_DESIGN and SILVER_COLUMN_DESIGN
   c. One quarantine table per Silver table: all source columns as VARCHAR, plus _SOURCE_BATCH_ID, REJECT_REASON, QUARANTINED_AT
   d. Masking policies for every column with masking_needed = Y (one policy per data type), showing unmasked values only to the role ROLE_DESIGN marks as the PII reader, then the statements that attach them
   e. Grants from ROLE_DESIGN, least privilege, translated into exact GRANT statements. Only for objects that exist now (schemas, Silver tables, quarantine tables, warehouse, database). Grants on objects built later (load procedures, Gold tables) are listed as DEFERRED with the skill that will grant them. If a privilege text is unclear, ask the human; never guess.
   Every statement is a plain CREATE or GRANT: no OR REPLACE, no IF NOT EXISTS, no DROP, no ALL PRIVILEGES, no OWNERSHIP transfer. Show the full list with a count per object type, the PII columns that get masking and the DEFERRED grants. Then MANDATORY STOPPING POINT 1.
2. BUILD. After the human says ok, run the statements in the planned order, one by one. Log each with OK or the error. On the FIRST error, STOP: report the statement, the error and what was already created. Do not continue, retry or drop anything to clean up.
3. VERIFY against the design (read-only): object counts per type; every column name, type and nullability in design order; audit columns on every Silver table and the quarantine columns on every quarantine table; masking policy attached to each PII column (POLICY_REFERENCES); every role exists with the privileges in ROLE_DESIGN and the analyst-type role has no access beyond its design; row count 0 for every table; no extra objects in the target schemas. Any difference is reported as DIFF, never fixed silently.
4. LOG. Write the result to a table SETUP_LOG in the design schema: object_type, object_name, ddl_status, verify_status, detail, run_at. Then MANDATORY STOPPING POINT 2.

## MANDATORY STOPPING POINT 1 (after PLAN)

Show the ordered statement list, count per object type, PII columns with masking, grants per role and the DEFERRED grants. STOP. Create nothing. Wait for the human to approve or change the plan.

## MANDATORY STOPPING POINT 2 (after LOG)

Show objects created per type, verification result (all MATCH or the list of DIFFs), masking attached yes or no per PII column, total data rows (must be 0) and where SETUP_LOG is. STOP. Do not load data and do not start the next step.

## Gotchas

* CREATE ROLE, CREATE MASKING POLICY and APPLY MASKING POLICY may be missing for the run role. If a statement fails for privileges, STOP and report the exact missing privilege and who must grant it. Never switch to ACCOUNTADMIN and never grant yourself privileges.
* Never show PII values. Verification uses metadata and counts only; never SELECT from a PII column.
* A masking policy works only on columns of its own data type, so create one policy per data type.
* A type that differs from the design is a failure, not a detail. Report it as DIFF.
* Primary and foreign keys in Snowflake are not enforced. Create them only as documentation if the design lists them; data quality rules do the real check in a later step.
* Bronze is read-only for this skill. Gold objects are not created here.
* Do not create a warehouse, database or schema.
* A partial build leaves objects behind. Report them; the human decides rebuild or reuse at the next step 0.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-schema-setup_<batch-id>_report.md`, for example `de-deep-schema-setup_B001_report.md`.
- Batch ID: the latest_batch_id in TABLE_INVENTORY (the batch the design was based on).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: objects created per type (roles, Silver tables, quarantine tables, masking policies, grants), PII columns with masking attached, DEFERRED grants and the skill that will grant them.
3. **Row counts**: row count of every Silver and quarantine table (must be 0); number of statements run and number OK.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every Step 3 verification (MATCH or DIFF).
5. **Quarantine**: quarantine tables created, one per Silver table, all with 0 rows.
6. **Warnings and open items**: every DIFF, any statement that failed, missing privileges, objects left behind by a partial build.
7. **Handed to the next skill**: Silver and quarantine tables, roles, masking policies and SETUP_LOG, used next by de-deep-transform-setup.

After saving, show the file path and its line count. Do not start the next skill.
