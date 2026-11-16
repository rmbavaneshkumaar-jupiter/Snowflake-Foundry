---
name: de-deep-profile
description: Profile the Bronze TABLES of a pipeline (all source columns are VARCHAR) into TABLE_INVENTORY and COLUMN_PROFILE, recommend in_scope per table, then stop for the human decision and record it. Use at the start of a data-engineering pipeline build when the source is Bronze tables.
parent_skill: de-workflow
tools: [snowflake_sql, Write]
---

# de-deep-profile

## Domain Context

Source data already sits in Bronze TABLES (raw text columns plus audit columns that start with an underscore). Before any design, measure them. Profile MEASURES; the human DECIDES scope. Build time only; daily runs use Tasks, not this skill. This skill never loads, changes or deletes source data.

## Inputs (stop if missing)

* Database and Bronze schema (ask if not given)
* Schema for the two profile tables (default: the MONITORING schema of the same database)
* Business input: Gold goal and required outputs, not-needed items, key table-selection rule. Always ask; never assume a goal.
* Role must not be ACCOUNTADMIN

## When to Use

* New Bronze tables landed and no profile exists
* Source tables changed shape (new columns, new feed) or a new batch arrived and a re-profile is wanted

## When NOT to Use

* Daily loads (Tasks do a light check instead)
* Data is still in files on a stage (load it into Bronze tables first)
* Tables already profiled and unchanged

## Steps

0. If TABLE_INVENTORY or COLUMN_PROFILE already exists, STOP and ask the human: rebuild or reuse. Never drop or overwrite on your own.
1. List the base tables of the Bronze schema (from INFORMATION_SCHEMA). Create TABLE_INVENTORY: table_name, column_count, row_count, batch_count, latest_batch_id, first_loaded_at, last_loaded_at, profilable (Y/N), profilable_reason, status='NEW', in_scope=NULL, scope_reason=NULL. profilable = Y only if the table has rows and its columns can be read.
2. For each profilable table, create COLUMN_PROFILE rows for every source column (skip audit columns that start with an underscore, but confirm they exist): table_name, column_position, column_name, inferred_type, row_count, null_count, null_pct, distinct_count, unique_pct, min_value, max_value, pii_flag, invalid_count, notes.
   * Source columns are VARCHAR, so infer the type with TRY_TO_NUMBER, TRY_TO_DATE and TRY_TO_TIMESTAMP: inferred_type is the most specific type that fits at least 95 percent of the non-null values, otherwise VARCHAR.
   * invalid_count = non-null values that do not fit the inferred type. notes: first column not unique, numeric values below zero, mixed formats.
3. PII safety: decide pii_flag from the verified column name BEFORE computing min and max. Never show sample values, min or max of a PII column. Before showing any output, confirm the column labels line up with the table definition.
4. Do NOT create Silver or Gold. Do NOT modify Bronze.
5. Recommend in_scope Y/N per table against the business input, with reason and confidence (high/medium/low).
6. After the human answers per table, write in_scope and scope_reason with UPDATE, show the final table, then stop. Write nothing before the human answers.

## MANDATORY STOPPING POINT

After step 5 show both tables and the recommendation. STOP. Do not write in_scope until the human answers per table (Y/N + reason).

## Gotchas

* profilable is a technical check; reliable is data quality. Do not mix them.
* Bronze columns are all text, so type problems show up as invalid_count, not as load errors.
* Several batches in one table mean row_count covers all batches; use batch_count and latest_batch_id to see them.
* Relationship problems (orphan keys) are NOT found here; they belong to schema design.
* Check column labels before showing output so PII is never exposed.

## Standalone Quality Gate

Both tables exist; every Bronze table has a row; every non-profilable table has a reason; COLUMN_PROFILE column count per table equals the number of source columns; zero unmasked PII values in stored output (run a check query); in_scope stays NULL until the human answers.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-profile_<batch-id>_report.md`, for example `de-deep-profile_B001_report.md`.
- Batch ID: the latest_batch_id in TABLE_INVENTORY (if tables differ, use the highest one).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: Bronze tables listed and profiled, profilable Y/N with reasons, in_scope decision and reason per table.
3. **Row counts**: per Bronze table: row_count, column_count, batch_count, latest_batch_id; COLUMN_PROFILE rows per table.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every item of the Standalone Quality Gate.
5. **Quarantine**: not applicable in this skill (nothing is loaded). Instead list every column with invalid_count above 0, negative numbers or a non-unique first column, with the count.
6. **Warnings and open items**: PII columns found (names only), low-confidence scope decisions, anything the human must decide later.
7. **Handed to the next skill**: TABLE_INVENTORY and COLUMN_PROFILE (with their schema), read next by de-deep-schema-design.

After saving, show the file path and its line count. Do not start the next skill.
