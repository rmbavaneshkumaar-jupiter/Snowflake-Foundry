---
name: de-dbt-project-setup
description: Phase 4 V2 (Transform Setup with dbt). Reads the approved Silver design and DQ rules from the design tables and writes a dbt project (config, dbt_project.yml, profiles.yml, schema macro, Bronze sources, one silver_ and one quarantine_ model plus a yml with tests per Silver table). Deploys it as a Snowflake dbt Project and only compiles it. Loads no data. Use after the design (Skill 2) is APPROVED and before de-dbt-load-validate.
---

# de-dbt-project-setup (Skill 4, Version 2)

Version 1 of this phase (de-deep-transform-setup) created one stored procedure per Silver table.
Version 2 writes the same logic as plain dbt files kept in Git, run inside Snowflake (Snowflake dbt Projects). Nothing is installed on a laptop.

This skill is generic. It works for any domain. It never contains a source table name or a column name: every name comes from the design tables at run time. The file shapes are in `references/templates.md`, with placeholders only.

## When to Use

- The design tables written by the schema design skill are all APPROVED.
- Bronze tables exist and hold at least one batch.
- A new Silver table or a changed rule was approved, and the dbt files must be written again.

## When Not to Use

- To build or load Silver: use de-dbt-load-validate.
- To build Gold: use the Gold skill.
- To change a rule, a column name or a type: go back to the schema design skill. This skill never invents or edits a rule.
- The design is not approved, or a design table is missing: STOP and go back.

## Inputs (ask the human if missing, never assume)

1. Config file path (default `config/foundry_config.yml` inside the dbt project folder). It holds database, warehouse, role, schema names, `quarantine_warn_pct`, `quarantine_stop_pct`, `credit_limit`, `gold_mode`, `gold_target_lag`, `load_mode`. Optional: `masking` (on or off, default off) and `pii_reader_role`.
2. Design schema (where the design tables live).
3. dbt project folder in the Git-connected workspace, and the Git repository object name in Snowflake.
4. dbt project object name in Snowflake (to create or to add a version to).
5. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: use only the pipeline role named in the config (one least-privilege role). Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. Run USE SECONDARY ROLES NONE.
- **No role work**: this skill never designs, creates or grants roles. If a privilege is missing, STOP and show the admin the missing privilege in a code block. The admin runs it, not this skill.
- **Names come from data only**: source table, Silver table, column names, types, renames, business keys and rules come only from the design tables. Read each design table's columns first (DESCRIBE), never guess them.
- **Rules are not changed**: every APPROVED rule is used exactly once. No rule is added, dropped or reworded. If a rule cannot be written as SQL, STOP and ask.
- **CLEAN or QUARANTINE is decided by the rule's ACTION column only**. CLEAN = change the value (example: trim, upper case, blank to NULL). QUARANTINE = reject the row with a reason. If ACTION is empty or another value, STOP and ask. Never decide it yourself.
- **Clean first, then check**: quarantine checks look at the cleaned value. The quarantine table stores the raw Bronze value. The CLEAN expression must be identical in the silver_ model and the quarantine_ model.
- **Thresholds are never written in this skill or in a model**. They live only in the config (`quarantine_warn_pct`, `quarantine_stop_pct`) and are copied to the `vars:` block of dbt_project.yml.
- **No var() inside dbt_project.yml models block**: dbt reads that file before its own vars exist. Schema names there are literals copied from the config. var() is allowed in model files and sources.yml.
- **No database, schema or warehouse name inside a model file**: use source(), ref(), target.database, target.warehouse, var().
- **Model names**: `silver_<silver_table>` and `quarantine_<silver_table>`, lower case. dbt creates the Snowflake tables in UPPER case. These names must not clash with any table that dbt does not own.
- **This skill never builds or loads**: only `dbt compile` (or `dbt parse`) runs. No `build`, `run`, `seed` or `test`.
- **No DROP, DELETE, TRUNCATE, OR REPLACE** written by hand. (dbt itself replaces its own tables on every build; see Gotchas.)
- Never put a PII value or a sample value into any file, message or report.
- Two human STOP gates: after the PLAN and after the VERIFY report. Never skip or merge them.

## Step 0: Checks (read only)

a. Read the config file. Show database, warehouse, role, schema names, thresholds, gold_mode, load_mode. If any key is missing, STOP.
b. `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE();` Role must equal the config role, secondary roles empty.
c. Design tables exist and every row has STATUS APPROVED: table design, column design, DQ rules. If any row is not APPROVED, STOP.
d. Bronze: every source table in the table design exists and has rows. Show rows per table and per `_BATCH_ID`.
e. Bronze columns: every source column named in the column design exists in Bronze (DESCRIBE TABLE). List any missing column and STOP.
f. Target names: for each planned Silver and quarantine table, check if a table with that name already exists in the Silver schema and who owns it (SHOW TABLES). If it exists and its owner is not the pipeline role, STOP: dbt would replace a table it does not own.
g. Privileges of the pipeline role (SHOW GRANTS TO ROLE): USAGE on database, warehouse and schemas; SELECT on Bronze and design tables; CREATE TABLE on the Silver schema; read on the Git repository; CREATE DBT PROJECT on the schema of the dbt project object. List what is missing and STOP. Do not grant it.
h. Workspace: does the dbt project folder already have files? If yes, list them. The human chooses at STOP 1: keep and add, or write a new folder. Never overwrite a file silently.

If any check fails, STOP and name the check.

## Step 1: Plan (STOP GATE 1)

Show, per Silver table, in dependency order (parents first, from the parent rules):

a. Source Bronze table, Silver table, business key, load mode from the design.
b. Column mapping: Bronze column, Silver column (renames shown), target type, cast expression. Mark every cast that can fail.
c. CLEAN rules: column and SQL expression.
d. QUARANTINE rules: rule id, column, rule type, SQL condition that means "failed", and the REJECT_REASON text taken from REJECT_REASON_TEXT in the rules table (for PARENT_EXISTS: one reason for a missing parent and, when PARENT_OUTCOME is MISSING_AND_QUARANTINED, a second one for a quarantined parent). Only APPROVED rows; RETIRED rows are ignored.
e. dbt tests per Silver column, made from the same rules (NOT_NULL -> not_null, UNIQUE_KEY -> unique, ALLOWED_VALUES -> accepted_values, PARENT_EXISTS -> relationships). Severity error on Silver, warn on quarantine.
f. File list with paths (see the list below), and which files already exist.
g. Counts: Silver tables, rules per table (CLEAN / QUARANTINE), files to write.
h. What this skill will NOT do: no build, no data, no grants, no roles.
i. Rollback: delete the new files from the workspace folder before commit. No Snowflake data object is created in this skill.

Wait for explicit approval. Do not write any file before it.

### Files written (shapes in references/templates.md)

```
<dbt_project_folder>/
  config/foundry_config.yml        (only if missing; never overwrite)
  dbt_project.yml
  profiles.yml
  macros/generate_schema_name.sql
  models/bronze/sources.yml
  models/silver/silver_<table>.sql        one per Silver table
  models/silver/quarantine_<table>.sql    one per Silver table
  models/silver/silver_<table>.yml        one per Silver table (both models + tests)
```

Quarantine models live in `models/silver/`, so dbt_project.yml has no separate quarantine folder block.

## Step 2: Write the files

a. Copy each template from `references/templates.md` and fill the placeholders from the design tables and the config. Nothing else.
b. dbt_project.yml: schema literals and the `vars:` block must equal the config values. profiles.yml: role, database, warehouse, Silver schema must equal the config.
c. In every quarantine_ model: one TRUE/FALSE flag per QUARANTINE rule, REJECT_REASON lists every failed rule joined with ' | ', the raw Bronze columns, QUARANTINED_AT and the Bronze audit columns.
d. In every silver_ model: Bronze rows that are NOT in the quarantine model (matched on the Bronze audit columns `_BATCH_ID`, `_SOURCE_FILE`, `_SOURCE_ROW_NUMBER`), CLEAN rules applied, TRY_ casts to the design types, Silver names.
e. Parent rules: the child quarantine_ model reads ref() of the parent silver_ model (and the parent quarantine_ model when the rule separates PARENT_QUARANTINED from PARENT_MISSING). Check that the ref() graph has no loop.
f. Masking (only if `masking` is on in the config): add the masking post-hook from templates section 9 to the silver_ AND quarantine_ model of every table that has a PII column. The masking policies must already exist (made by de-dbt-schema-setup); if one is missing, STOP.
g. Each file starts with a short comment: what it does, and where its rules came from (design table name and rule ids). No sample data values.

## Step 3: Human commits to Git (STOP, short)

Ask the human to commit and push the dbt project folder to the Git repository (workspace Git panel). Wait until the human says it is pushed.

## Step 4: Deploy and compile (no data)

```sql
ALTER GIT REPOSITORY <git_repo_object> FETCH;
-- first time:
CREATE DBT PROJECT <dbt_project_object>
  FROM '@<git_repo_object>/branches/<branch>/<dbt_project_folder>/';
-- later times:
ALTER DBT PROJECT <dbt_project_object>
  ADD VERSION FROM '@<git_repo_object>/branches/<branch>/<dbt_project_folder>/';

EXECUTE DBT PROJECT <dbt_project_object> ARGS = 'compile';
```

Ask before the CREATE (it creates a Snowflake object). If compile fails, stop at once (see Failure Handling).

## Step 5: Verify (read only)

a. Compile result: success, and no error lines. Report any WARNING line in full.
b. Every APPROVED rule id appears in exactly one model file (CLEAN in both silver_ and quarantine_ of its table, QUARANTINE in the quarantine_ model). List rule ids not found, and ids found twice.
c. Every Silver column in the column design is in its silver_ model. Every Bronze column is in its quarantine_ model.
d. No model file contains a database name, schema name, warehouse name or a threshold number (search the files).
e. dbt_project.yml schema literals, `vars:` block and profiles.yml equal the config (show them side by side).
f. Masking (only if on): every PII column from the column design has a post-hook line in its silver_ and quarantine_ model, and every policy named there exists (SHOW MASKING POLICIES).
g. Silver and quarantine row counts: unchanged from Step 0 (proof that nothing was built).

## Step 6: Report (STOP GATE 2)

One table: check, expected, actual, PASS/FAIL/WARN for every Step 5 item. Plus the file list with line counts, the rule count per table, and open items. Wait for approval before de-dbt-load-validate.

## Gotchas

- `materialized: table` means every dbt build rebuilds the whole table from all Bronze batches (CREATE OR REPLACE by dbt). This is safe to run again, but it also removes grants, masking policies and tags set on that table by hand. That is why masking is attached by a dbt post-hook after every build, never by hand. Tags are not re-applied yet (open item). `load_mode` in the config is not used by these models yet (open item).
- dbt_project.yml is read before its vars exist: a var() in the models block fails with "Required var ... not found".
- A WARNING "Configuration paths exist in your dbt_project.yml file which do not apply to any resources" means a folder block points to a folder with no models. Harmless, but remove the block next time.
- Clean before check: checking the raw value wrongly rejects a value that only had extra spaces.
- An empty text '' is not NULL. Apply the design's blank-to-NULL CLEAN rule before NOT_NULL checks.
- A duplicate business key inside one batch: every copy fails UNIQUE_KEY. Never pick a winner.
- Snowflake dbt Projects needs profiles.yml in the project root. Account and user can be dummy text. No password in the file.
- Moving to another account or database means changing 4 places by hand: the config, the `vars:` block, the schema literals in dbt_project.yml, profiles.yml.

## Failure Handling

- Stop at the first failed check or statement. Do not retry, do not work around it, do not switch role.
- Privilege error: report the statement, the error text and the missing privilege for the admin.
- Compile error: report the file and line. Fix only the file this skill wrote, and only to match the approved design; then go back to Step 3.
- A rule that cannot be written as SQL: STOP and send it back to the schema design skill.

## Output

The dbt project files in the workspace and Git, the dbt project object in Snowflake (compiled, never built), and the Step 6 report.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 5. Otherwise skip this step.

- File: `pipeline-reports/de-dbt-project-setup_<batch-id>_report.md` (latest Bronze batch id). Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, Quarantine (rules per table, no rows yet), Warnings and open items, Handed to the next skill.
- Numbers only from queries in this session; else "not measured". No PII values, no secrets.
- The next skill reads Snowflake and the dbt project, never this file.
