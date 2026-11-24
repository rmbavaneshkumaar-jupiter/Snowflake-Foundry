---
name: de-profile-classify
description: Phase 1 V2 (Profile and classify PII). Profiles the Bronze tables into TABLE_INVENTORY and COLUMN_PROFILE, finds PII columns with one generic stored procedure that tests the column values against human-editable patterns inside Snowflake (counts only, never values) plus column-name hints and an AI proposal from names and types, stops for the human to approve the PII flags, then applies Snowflake tags to the approved columns and records the in-scope decision. Use at the start of a pipeline build when the source sits in Bronze tables.
---

# de-profile-classify (Skill 1, Version 2)

Version 1 (de-deep-profile) decided PII from the column NAME only. A column named CONTACT that holds phone numbers was missed, and nothing was tagged.
Version 2 adds three things:

1. **Pattern detection inside Snowflake.** One generic procedure, `SP_DETECT_PII_PATTERNS`, counts how many values of each column match each pattern (email, phone, ID formats, name-like words). Only counts and percentages come out. No value leaves Snowflake.
2. **A human gate before tags.** Pattern signal, name signal and AI signal are shown side by side as PROPOSED rows. The human approves, edits or rejects. Only APPROVED rows get tags.
3. **Snowflake tags** on the approved columns (`PII_CLASS`, `PII_SENSITIVITY`, `MASKING_NEEDED`). Skill 2 reads the approved flags to set masking_needed; Skill 3 attaches the masking policy.

This skill is generic. It never contains a source table name, a column name or a threshold number. Patterns, PII classes, thresholds and tag names live in config tables that the human edits.

Reference files:
- `references/pii_config_ddl.sql`: config tables, result tables, decision log, tag DDL.
- `references/pii_procedures.sql`: `SP_DETECT_PII_PATTERNS` and `SP_APPLY_APPROVED_PII_TAGS`.

## When to Use

- New Bronze tables landed and no profile exists.
- Source tables changed shape, or a new batch arrived and a re-profile is wanted.
- The pattern list was changed and the PII review must be done again (new run id).

## When Not to Use

- Daily loads (Tasks do a light check instead).
- Data still in files on a stage: load it into Bronze tables first.
- To create or change masking policies: that is Skill 3.
- To grant privileges or create roles: an admin does that, never this skill.

## Inputs (ask the human if missing, never assume)

1. Config file path. From it: database, warehouse, role, schemas (bronze, monitoring).
2. Business input: Gold goal, required outputs, not-needed items, table-selection rule. Always ask; never assume a goal.
3. Optional PII answer key: for a test run, the expected class per column (planted-defect test). If none, say so at STOP 1.
4. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role from the config. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. `USE SECONDARY ROLES NONE`. Never switch role to get past an error. No role creation, no GRANT statements. A missing privilege = STOP and show it for the admin.
- **The AI never reads a data value of a candidate PII column.** No `SELECT <column>` from Bronze, no LIMIT 1 sample, no MIN/MAX, no `SELECT *` on a Bronze table. All value work on PII candidates happens inside the procedure, which returns numbers only.
  Honest note: this is a rule of the skill, not a technical lock. The pipeline role has SELECT on Bronze, so a careless prompt could still read values. The reviewer must check the session's queries (Quality Gate item 7).
- **Thresholds only from config** (`PROFILE_SETTINGS`, `PII_PATTERN_CONFIG`). Never a number written in a prompt. Missing setting = STOP.
- **Bronze data is never changed.** Tags are metadata on Bronze columns; they do not change rows. Setting them is a step the human approves at STOP 1.
- **Nothing is tagged without approval.** `SP_APPLY_APPROVED_PII_TAGS` reads only STATUS = 'APPROVED' rows. Never set STATUS = 'APPROVED' without the human's explicit answer for that column (or an explicit "approve all HIGH" from the human).
- **Never overwrite a human edit** in a config table. Config DDL uses CREATE IF NOT EXISTS and seeds only empty tables.
- **Existing objects**: if TABLE_INVENTORY, COLUMN_PROFILE or a procedure already exists, STOP and ask: reuse or replace. Never drop on your own.
- Every number shown comes from a query run in this session.
- Two human STOP gates: STOP 1 (PII review) and STOP 2 (scope). Never skip or merge them.

## Step 0: Pre-checks (read only)

1. Read the config. Show role, warehouse, database, Bronze schema, monitoring schema.
2. `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE();` must match the config.
3. Check privileges of the pipeline role: USAGE on database and schemas, SELECT on Bronze tables, CREATE TABLE and CREATE PROCEDURE on the monitoring schema, CREATE TAG on the monitoring schema, and the right to set a tag on Bronze columns (APPLY TAG on the account, or APPLY on each tag plus OWNERSHIP of the Bronze tables). List what is missing and STOP.
4. Check which objects already exist in the monitoring schema: the 6 tables of `pii_config_ddl.sql`, the 2 procedures, the 3 tags, TABLE_INVENTORY, COLUMN_PROFILE. Show the list.
5. If the config tables already exist, show their content (settings, classes, patterns). The human may edit them before the run.

## Step 1: Set up config and procedures

1. If the config tables are missing, run `references/pii_config_ddl.sql` (with the config values in place of the placeholders). Show the seeded settings, classes and patterns.
2. If the procedures are missing, or the human chose "replace" in Step 0, run `references/pii_procedures.sql`.
3. Ask the human: "Patterns and thresholds OK, or edit first?" Edits are done with UPDATE or INSERT on the config tables, shown to the human before running.

## Step 2: Inventory (read only on Bronze)

Create TABLE_INVENTORY as in V1: table_name, column_count, row_count, batch_count, latest_batch_id, first_loaded_at, last_loaded_at, profilable (Y/N), profilable_reason, status = 'NEW', in_scope = NULL, scope_reason = NULL.
Counts only (COUNT, COUNT DISTINCT on audit columns, MIN/MAX on audit timestamps). No source column values.

## Step 3: Detect PII (inside Snowflake)

1. Run id: `PII_<latest_batch_id>_<UTC yyyymmddThhmm>`. Show it.
2. `USE SCHEMA <database>.<monitoring schema>;` (the procedures use the config tables of the current schema), then
   `CALL SP_DETECT_PII_PATTERNS('<database>', '<bronze schema>', '<run id>');`
3. Show the returned summary: tables, columns, rows by confidence, sampled Y/N.
4. If any table was skipped, list it with the reason.

## Step 4: AI proposal (names and numbers only)

For each row of `PII_COLUMN_CLASSIFICATION` for this run, the AI reads only TABLE_NAME, COLUMN_NAME, DATA_TYPE, NON_NULL_COUNT, DISTINCT_PCT, PATTERN_CLASS, PATTERN_MATCH_PCT and NAME_HINT_CLASS, and writes AI_PROPOSED_CLASS (a class from PII_CLASS_CONFIG, or NONE) and a one-line AI_REASON with an UPDATE.
The AI never changes PROPOSED_CLASS or CONFIDENCE. Those are computed by SQL.

## Step 5: PII review (STOP GATE 1)

Show one table, sorted: SIGNAL_CONFLICT = 'Y' first, then rows where AI_PROPOSED_CLASS differs from PROPOSED_CLASS, then HIGH, MEDIUM, LOW. Rows with PROPOSED_CLASS = 'NONE' and AI_PROPOSED_CLASS = 'NONE' are shown as a count, with the list on request.

Columns: table, column, pattern class + match %, name hint class, AI class + reason, proposed class, confidence, masking_needed.

Also show:
- What the three signals mean: pattern = values checked inside Snowflake; name = column name only; AI = guess from name and numbers.
- The answer key compared with the proposals (MATCH / MISMATCH), or "no answer key".
- What happens after approval: three tags on each approved column, nothing on rejected ones.

The human answers per column: approve, change class (and masking_needed), or reject (class NONE). "Approve all HIGH" is allowed only if the human says it.
Write each answer with UPDATE (STATUS, APPROVED_CLASS, MASKING_NEEDED, DECIDED_BY = CURRENT_USER(), DECIDED_AT, DECISION_REASON) and one INSERT into PII_DECISION_LOG. Do not write anything before the human answers. Columns still PROPOSED stay untagged; list them.

## Step 6: Apply tags (only APPROVED rows)

1. If the tags are missing, create them (`CREATE TAG IF NOT EXISTS`, see the end of `pii_config_ddl.sql`), with ALLOWED_VALUES built from PII_CLASS_CONFIG.
2. `CALL SP_APPLY_APPROVED_PII_TAGS('<run id>');` Show tagged count, failures, still-proposed count.
3. Verify with `SELECT * FROM TABLE(<database>.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('<database>.<bronze schema>.<table>', 'table'))` per table. Tagged columns must equal the APPROVED, non-NONE rows. Do not use ACCOUNT_USAGE.TAG_REFERENCES here: it can lag up to about two hours.
4. Any failure (for example a missing APPLY privilege): STOP, show the statement error, do not switch role.

## Step 7: Column profile

Create COLUMN_PROFILE as in V1 for every source column (skip audit columns): table_name, column_position, column_name, inferred_type, row_count, null_count, null_pct, distinct_count, unique_pct, min_value, max_value, pii_flag, pii_class, masking_needed, invalid_count, notes.

- inferred_type: most specific type (TRY_TO_NUMBER, TRY_TO_DATE, TRY_TO_TIMESTAMP) that fits at least `PROFILE_TYPE_FIT_PCT` percent of non-null values, else VARCHAR. Counting with TRY_ functions inside an aggregate is allowed; it returns numbers only.
- pii_flag = 'Y' when the column is APPROVED with a class other than NONE, or is still PROPOSED with a class other than NONE (safe side). pii_class and masking_needed from the approved row.
- For pii_flag = 'Y' columns: min_value and max_value stay NULL, notes never quote a value. Counts, nulls, distinct and type are fine.
- For the others: MIN and MAX as in V1.

## Step 8: Scope (STOP GATE 2)

Recommend in_scope Y/N per table against the business input, with reason and confidence (high/medium/low). Show TABLE_INVENTORY, COLUMN_PROFILE and the PII summary (approved classes per table). STOP. After the human answers per table, write in_scope and scope_reason with UPDATE and show the final table.

## Standalone Quality Gate

1. TABLE_INVENTORY has one row per Bronze base table; every non-profilable table has a reason.
2. COLUMN_PROFILE column count per table = number of source columns.
3. PII_COLUMN_CLASSIFICATION has one row per source column for this run.
4. Every APPROVED or REJECTED row has DECIDED_BY, DECIDED_AT and a matching PII_DECISION_LOG row.
5. Tagged columns (TAG_REFERENCES_ALL_COLUMNS) = APPROVED rows with class not NONE. No tag on a PROPOSED or REJECTED column.
6. Zero min_value / max_value for pii_flag = 'Y' columns (run the check query).
7. No query of this session selected a candidate PII column's values outside the procedures. Check with `QUERY_HISTORY_BY_SESSION` and list the Bronze queries.
8. in_scope stays NULL until the human answers.
9. If an answer key was given: every planted PII column is APPROVED with the expected class.

## Gotchas

- Patterns are generic starting points. A 10-digit numeric key can look like a phone; a 12-digit key can look like an ID number. That is why some patterns need a name hint for HIGH, and why the human decides.
- Name-like values (words) also match city or product columns. `MIN_DISTINCT_PCT` filters low-variety columns, not all of them. Expect some LOW rows to reject.
- A column with real names but low variety (many repeated names) may not pass `MIN_DISTINCT_PCT`; then only the name hint catches it.
- With `PII_SAMPLE_ROWS` above 0 the sample is random: match % moves a little between runs.
- Card numbers are matched by format only (no Luhn check).
- Free-text columns (comments, notes) with PII inside a sentence are not found by whole-value patterns.
- Snowflake `REGEXP_LIKE` matches the whole value, so name-hint patterns need `.*` at both ends.
- The procedures read the config tables of the CURRENT schema. Run `USE SCHEMA` first.
- A dbt rebuild of Silver does not carry Bronze tags to Silver. Skill 2 and Skill 3 read the approved flags from the classification table, not from Bronze tags.
- Each run needs a new run id; the procedure refuses a used one.

## Failure Handling

- Procedure error: STOP, show the error text (it never contains values). Do not run ad-hoc SELECTs on the column to "check".
- Privilege error: STOP, show statement and missing privilege for the admin.
- Missing setting or pattern: STOP, the human adds it in the config table.
- Plan vs result mismatch (answer key): report it. Never change the key or a pattern to make it pass without the human.

## Output

TABLE_INVENTORY, COLUMN_PROFILE, PII_COLUMN_CLASSIFICATION (APPROVED rows), PII_DECISION_LOG, tags on approved Bronze columns. Read next by the schema design skill (Skill 2).

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 4. Otherwise skip.

- File: `pipeline-reports/de-profile-classify_<batch-id>_report.md`. Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, PII review (column names, classes and decisions only), Warnings and open items, Handed to the next skill.
- Numbers only from queries in this session; else "not measured". No PII values, no samples, no secrets.
- The next skill reads Snowflake, never this file.
