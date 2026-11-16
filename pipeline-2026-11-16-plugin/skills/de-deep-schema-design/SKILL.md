---
name: de-deep-schema-design
description: "Designs Silver and Gold layers from profiled Bronze tables. Use after de-deep-profile. Produces design tables only, creates no objects."
parent_skill: de-workflow
tools:
  - snowflake_sql
  - Write
---

# Schema Design

## Purpose
Turn the profile of the Bronze tables into a reviewed design for Silver and Gold. This skill only writes design tables. It never creates Silver or Gold objects. The next skill builds them from the approved design.

## When to Use
After de-deep-profile has finished and in_scope is set (Y or N) for every table.

## When Not to Use
- Profile tables are missing, or in_scope is empty: run de-deep-profile first.
- To create Silver or Gold objects, load data or run transforms: those are later skills.
- To change Bronze: Bronze is never changed by this skill.

## Inputs (ask the user, never assume)
1. Database, Bronze schema, profile schema (default MONITORING).
2. Silver schema and Gold schema names.
3. Business goal for Gold: which measures, which grouping (dimensions), which grain, which time period. Always ask. There is no default goal.
4. Warehouse for Dynamic Tables and procedures (the project warehouse, never a serverless option).
5. Role must not be ACCOUNTADMIN and must not use ALL PRIVILEGES.

## Design principles
- Bronze is append-only. Every row has _BATCH_ID, so Silver loads incrementally by batch. No source "changed at" column is needed.
- Silver = normal tables loaded by stored procedures. Every Silver table has its own quarantine table.
- Gold = per Gold table, either a stored-procedure-loaded normal table or a Dynamic Table. Choose early, here.
- Never invent business rules. Propose them from the profile and let the user approve.
- Never put real values of PII columns in any table, output or message.

## Steps

### Step 0: Safety check
Stop if the design tables below already exist. Ask the user whether to keep or replace them.

### Step 1: Read the profile
Read TABLE_INVENTORY and COLUMN_PROFILE. Use only tables with in_scope = Y. List them back to the user in one line.

### Step 2: SILVER_TABLE_DESIGN
Columns: source_table, silver_table, business_key (comma-separated columns), load_mode, reason, status.
- load_mode is INCREMENTAL_MERGE or FULL_RELOAD.
- Default INCREMENTAL_MERGE: each run takes Bronze rows whose _BATCH_ID is not yet processed, validates them, and MERGEs into Silver on the business key (new key inserts, existing key updates, only when a business column changed).
- Use FULL_RELOAD only for small reference tables, with a written reason.
- Business key: propose from the profile (unique_pct = 100 and not null). If no column qualifies, or the key repeats within a batch, flag it and ask the user. Do not guess.
- Silver audit columns on every table: _SOURCE_BATCH_ID, _LOADED_AT, _UPDATED_AT.

### Step 3: SILVER_COLUMN_DESIGN
Columns: silver_table, column_name, source_column, target_type, pii_flag, masking_needed, notes.
- Use inferred_type from COLUMN_PROFILE as target_type. Bronze columns are all VARCHAR, so every cast is explicit.
- Propose clear business names where useful (for example FIRST_NAME and LAST_NAME combined into CUSTOMER_NAME). Record each rename and combination in notes.
- Columns that are 100% null: drop from Silver and say so in notes.
- PII columns: masking_needed = Y. Never store sample values.

### Step 4: SILVER_DQ_RULES
Columns: silver_table, column_name, rule_type, rule_detail, action, reason.
- rule_type: NOT_NULL, TYPE_CAST, ALLOWED_VALUES, FORMAT, RANGE, UNIQUE_KEY.
- action: QUARANTINE (reject the row to quarantine with the reason) or CLEAN (standardize the value, for example trim or upper-case).
- Every column gets at least one explicit rule.
- A type check alone does not catch bad text values. For text columns, propose ALLOWED_VALUES or FORMAT from the profile (for example an order status list, an email pattern).
- Numeric columns: propose RANGE (for example quantity greater than 0, prices not negative). Bad numeric text such as non-numeric amounts is a TYPE_CAST failure.
- Quarantine table per Silver table: all source columns as text, plus _SOURCE_BATCH_ID, REJECT_REASON, QUARANTINED_AT.

### Step 5: GOLD_TABLE_DESIGN
Columns: gold_table, grain, measures, dimensions, source_silver_tables, build_type, target_lag, reason.
- Derive Gold tables only from the business goal given by the user.
- build_type DYNAMIC_TABLE: aggregations and joins that Snowflake can refresh by target lag. Ask the user for target_lag. The Dynamic Table uses the project warehouse.
- build_type PROCEDURE: logic a Dynamic Table cannot express, or when the user wants full control of the run time.
- State the grain in one sentence for every Gold table.

### Step 5b: Design roles (ROLE_DESIGN)
- Create the table <design_schema>.ROLE_DESIGN with columns: role_name, schema_name, privileges, purpose, status.
- Design roles from the schemas and the PII flags, one role per job. Typical set: a loader role (writes Bronze, Silver and quarantine tables through procedures), a transformer role (writes Gold), an analyst role (reads Gold only, sees masked PII), and a PII reader role (sees unmasked PII, only where masking_needed = Y exists).
- List explicit privileges per role. Never use ACCOUNTADMIN or ALL PRIVILEGES. Give each role only what its job needs. Analyst roles get no access to Bronze or quarantine tables.
- Only design the roles here. The roles are created in the schema setup skill.

### Step 6: Consistency checks
Before showing, check and report:
- every in_scope table has exactly one Silver design row,
- every Silver table has a business key and a load_mode,
- every Silver column has at least one DQ rule,
- every Gold measure traces to a Silver column;
- every schema has at least one role with a clear purpose, and no role has ACCOUNTADMIN or ALL PRIVILEGES.
Report any gap. Do not hide it.

### Step 7: Show the design
Show the five design tables and a short summary in plain language.

## MANDATORY STOPPING POINT
Do not create any object. Ask the user to approve or change: business keys, load modes, column names, DQ rules, Gold build types and lags, role names and privileges. Record the approval in the status column. Never continue to the next skill without an explicit approval.

## Gotchas
- A repeating business key inside one batch is a design question for the user, not a silent choice.
- Do not drop PII columns without asking. Mask, do not delete.
- Do not create objects in Silver or Gold, not even empty ones.
- All object names UPPER_SNAKE_CASE.
- No secrets, no ACCOUNTADMIN.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-schema-design_<batch-id>_report.md`, for example `de-deep-schema-design_B001_report.md`.
- Batch ID: the latest_batch_id in TABLE_INVENTORY (the batch the design was based on).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: the five design tables written, their status (PROPOSED or APPROVED), and every change the human asked for at the stopping point.
3. **Row counts**: rows in SILVER_TABLE_DESIGN, SILVER_COLUMN_DESIGN, SILVER_DQ_RULES, GOLD_TABLE_DESIGN and ROLE_DESIGN; DQ rules per Silver table.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every Step 6 consistency check.
5. **Quarantine**: no rows yet. List the planned quarantine table per Silver table and the dependent-row rule (for example PARENT_QUARANTINED).
6. **Warnings and open items**: gaps from Step 6, open design questions (for example repeating business keys), PII columns marked for masking.
7. **Handed to the next skill**: the five design tables (with their schema) and their approval status, read next by de-deep-schema-setup.

After saving, show the file path and its line count. Do not start the next skill.
