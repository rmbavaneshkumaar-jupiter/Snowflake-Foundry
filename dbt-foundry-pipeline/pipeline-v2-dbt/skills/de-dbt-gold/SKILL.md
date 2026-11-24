---
name: de-dbt-gold
description: Phase 6 V2 (Gold with dbt). Reads the approved Gold design and writes one dbt Gold model per Gold table (dynamic table or table, chosen by gold_mode in the config), a yml with tests and one Gold-vs-Silver totals test. Builds only the Gold folder, then checks totals, grain, UNKNOWN rows, no PII and refresh state. Use after de-dbt-load-validate is approved. Does not change Silver.
---

# de-dbt-gold (Skill 6, Version 2)

Version 1 of this phase (de-deep-transform) created Gold Dynamic Tables with hand-written CREATE statements.
Version 2 writes the same logic as dbt model files in the same dbt project as Silver, so Gold is under dbt control and is rebuilt the same way every time.

This skill is generic. It never contains a source table name, a column name, a category list or a threshold number. Everything comes from the design tables, the Silver models and the config file. File shapes are in `references/templates.md`, with placeholders only.

## When to Use

- de-dbt-load-validate is approved for the latest batch: Silver models are built and their tests pass.
- The Gold design is APPROVED.
- A Gold table was added or its approved logic changed.

## When Not to Use

- Silver is not built or the last Skill 5 V2 report was not approved: run it first.
- To change Silver models, rules or quarantine: go back to Skill 4 V2.
- To change what Gold measures or groups by: go back to the schema design skill.

## Inputs (ask the human if missing, never assume)

1. Config file path (same as Skills 4 and 5 V2). From it: role, warehouse, schemas, `gold_mode`, `gold_target_lag`. Optional key `gold_reader_role` (a role made by the admin that may read Gold).
2. Design schema, dbt project folder, Git repository object, dbt project object (same as Skill 4 V2).
3. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role from the config. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. USE SECONDARY ROLES NONE. No role creation, no grant by hand. A missing privilege = STOP and show it for the admin.
- **Table type comes from the config only**: `gold_mode` = `dynamic_table` uses `gold_target_lag` and the warehouse from profiles.yml; `gold_mode` = `table` has no target lag at all. If the Gold design table has its own build type or lag that differs from the config, show the difference at STOP 1; the human decides. Never mix silently.
- **Gold reads only Silver models** with ref(). Never source(), never a quarantine model.
- **No PII in Gold**: never select a Silver column whose column design has the PII flag set. Check this before writing and again after the build.
- **Logic only from the approved design**: grain, measures, dimensions, which date decides the month for each measure, how amounts are split over rows. If the design does not say it, ask at STOP 1. Never invent business logic.
- **Nothing is hidden**: a fact row whose dimension is missing in Silver stays in Gold under the value `UNKNOWN` (left join + coalesce), and is reported.
- **Model names**: `gold_<gold_table>`, lower case. They must not clash with a table the pipeline role does not own.
- No hand-written CREATE, DROP, DELETE or OR REPLACE. dbt builds; this skill only writes files and runs `EXECUTE DBT PROJECT`.
- Never mark a check PASS without the numbers next to it. Never change an expected value to match.
- Two human STOP gates: after the PLAN and after the REPORT.

## Step 0: Checks (read only)

1. Read the config and show role, warehouse, Gold schema, `gold_mode`, and `gold_target_lag` (only if `gold_mode` is `dynamic_table`).
2. `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE();` must match the config.
3. Gold design: every row APPROVED. Show gold table, grain, measures, dimensions, source Silver tables.
4. Silver: every Silver table the design needs exists and has rows. Show the counts.
5. PII list: Silver columns with the PII flag in the column design. These must never appear in Gold.
6. Target names: does a table named like each planned Gold model already exist in the Gold schema? If yes and the owner is not the pipeline role, STOP.
7. Privileges of the pipeline role: USAGE on the Gold schema, CREATE DYNAMIC TABLE (if `dynamic_table`) or CREATE TABLE (if `table`) on it, SELECT on Silver. List missing ones for the admin and STOP.

## Step 1: Plan (STOP GATE 1)

For each Gold table show:

- Model name, grain in one sentence, table type and lag from the config.
- The full SELECT, with each join and its type, and which date sets the month for each measure.
- How a missing dimension becomes `UNKNOWN`.
- How amounts are split when one fact belongs to several Gold rows (only if the design says so), and the rounding rule.
- Columns of the Gold table. Confirm none is a PII column (list the PII columns next to it).
- Tests: not_null on the grain columns and measures; one row per grain; Gold totals = Silver totals (singular test).
- Expected values computed now from Silver with plain read-only queries: row count, and the sum of each measure.
- Grants: SELECT to `gold_reader_role` through the dbt grants config, only if that key is in the config. Otherwise "no grants".
- Rollback: Gold holds no source data; a rebuild recreates it from Silver.

Wait for explicit approval. Do not write files before it.

## Step 2: Write the files

```
<dbt_project_folder>/
  models/gold/gold_<gold_table>.sql       one per Gold table
  models/gold/gold_models.yml             descriptions and tests for all Gold models
  tests/assert_gold_matches_silver.sql    Gold totals = Silver totals, one row per grain
```

Copy the shapes from `references/templates.md` and fill the placeholders from the approved plan. Each file starts with a short comment: what it does, grain, which design row it came from. No sample data values.

## Step 3: Human commits to Git (STOP, short)

Ask the human to commit and push. Wait until the human says it is pushed.

## Step 4: Deploy and build Gold only

```sql
ALTER GIT REPOSITORY <git_repo_object> FETCH;
ALTER DBT PROJECT <dbt_project_object>
  ADD VERSION FROM '@<git_repo_object>/branches/<branch>/<dbt_project_folder>/';
EXECUTE DBT PROJECT <dbt_project_object> ARGS = 'build --select path:models/gold';
```

Read SUCCESS and the summary line (PASS, WARN, ERROR, SKIP, TOTAL). If the log does not show in the grid, read it with RESULT_SCAN and keep only the Done, Finished, WARN and ERROR lines. ERROR > 0 = STOP.

## Step 5: Verify (read only)

1. Table type: `SHOW DYNAMIC TABLES` (or `SHOW TABLES` when `gold_mode` is `table`) in the Gold schema. Show owner, target lag, refresh mode, rows.
2. First refresh done (dynamic tables only): refresh history state SUCCEEDED for each.
3. Totals: sum of each measure in Gold vs the expected values from Step 1 and vs Silver. Show all numbers.
4. Grain: rows = distinct grain keys.
5. UNKNOWN rows: count and amount per Gold table, with the reason.
6. No PII: Gold columns (INFORMATION_SCHEMA.COLUMNS) compared with the PII list. Must be none.
7. Grants (only if `gold_reader_role` is set): SHOW GRANTS ON each Gold table shows SELECT to that role and nothing more.
8. Silver unchanged: Silver row counts equal Step 0.

## Step 6: Report (STOP GATE 2)

One table: check, expected, actual, PASS / FAIL / WARN. Mismatches first, with the cause if known. Then the Gold tables with type, lag, rows, last refresh, and the top 5 rows of each. Wait for approval before the share and monitor skill.

## Gotchas

- A dbt `dynamic_table` model needs `snowflake_warehouse` and `target_lag`. A `table` model must not get a target lag.
- `gold_mode` is read with var() inside each model file, never in dbt_project.yml.
- Snowflake may choose refresh mode FULL instead of INCREMENTAL for a complex query. This is allowed; report it.
- Changing the SQL of an existing dynamic table model may need a full refresh run. Report it; do not run `--full-refresh` without asking.
- When a new Gold table is compared with an older table of a different shape, compare only the columns both have, and say which column could not be compared.
- An amount can belong to a different month than the fact it relates to (for example a reversal booked later). Follow the approved date rule per measure.
- A bad Silver load reaches Gold at the next refresh. Gold is only as good as the last approved Skill 5 V2 run.

## Failure Handling

- Privilege error: STOP, report statement, error and missing privilege. Never switch role.
- dbt or test error: STOP, report the model or test and its message. Fix only the file this skill wrote, and only to match the approved plan; then go back to Step 3.
- Plan vs result mismatch: STOP and report. Never change the expected value.

## Output

Gold models in the dbt project and in Git, Gold tables built by dbt, and the Step 6 report.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 3. Otherwise skip this step.

- File: `pipeline-reports/de-dbt-gold_<batch-id>_report.md` (latest batch in Silver). Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, Quarantine (UNKNOWN rows in Gold), Warnings and open items, Handed to the next skill.
- Numbers only from queries in this session; else "not measured". No PII values, no secrets.
