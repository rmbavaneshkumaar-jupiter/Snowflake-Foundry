---
name: de-dbt-load-validate
description: Phase 5 V2 (Load and Validate with dbt). Builds the Silver and quarantine tables for one Bronze batch by running the dbt project from de-dbt-project-setup, one Silver table at a time in parent-first order, and stops on the quarantine thresholds from the config. Then validates row reconciliation, values, planted defects and quarantine reasons. Use after Skill 4 V2 is approved and a Bronze batch exists. Creates no object outside dbt.
---

# de-dbt-load-validate (Skill 5, Version 2)

Version 1 of this phase (de-deep-load-validate) called one stored procedure per table.
Version 2 runs `EXECUTE DBT PROJECT ... build` per Silver table. dbt builds the quarantine model, then the Silver model, then runs their tests.

This skill is generic. It never contains a source table name, a column name or a threshold number. Table names come from the dbt project and the design tables. Thresholds come only from the config file.

## When to Use

- de-dbt-project-setup is approved: the dbt project compiles and the dbt project object exists in Snowflake.
- A new Bronze batch is ready, or the same batch must be checked again.

## When Not to Use

- The dbt project does not compile, or a design table is not APPROVED: go back to Skill 4 V2 or Skill 2.
- To build Gold: use the Gold skill.
- To change rules, files or grants: go back to the skill that owns them.

## Inputs (ask the human if missing, never assume)

1. Config file path (same as Skill 4 V2). From it: database, warehouse, role, schemas, `quarantine_warn_pct`, `quarantine_stop_pct`, `credit_limit`, and the optional `masking` and `pii_reader_role`.
2. dbt project object name in Snowflake.
3. Batch ID to check (example format: B001).
4. Answer key: the planted defects with expected outcome (table, business key, expected: loaded or quarantined, and expected REJECT_REASON). If none exists, say so at STOP 1; the human decides to continue without it or to provide one.
5. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role from the config. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. USE SECONDARY ROLES NONE. Never switch to another role to get past an error.
- **No role or grant work**. A missing privilege = STOP and show it for the admin.
- **Thresholds only from the config**. Read `quarantine_warn_pct` and `quarantine_stop_pct` at Step 0 and show them. Never use a number written anywhere else. If a key is missing, STOP.
- **Build only through dbt**: `EXECUTE DBT PROJECT`. No hand-written CREATE, INSERT, UPDATE, MERGE, DELETE, DROP or TRUNCATE.
- **One Silver table per build**, parents first, so a STOP can happen before the children are built.
- **Never change a file, rule or expected value to make a check pass.**
- Never mark a check PASS without the numbers next to it. Every number from a query run in this session.
- Never show PII values. For PII columns compare counts and null rates only (open item: no value compare).
- Two human STOP gates: after the PLAN and after the REPORT. Never skip or merge them.

## Step 0: Pre-checks (read only)

1. Read the config. Show role, warehouse, database, schemas, and the two thresholds.
2. `SELECT CURRENT_ROLE(), CURRENT_SECONDARY_ROLES(), CURRENT_WAREHOUSE();` must match the config.
3. dbt project object exists (SHOW DBT PROJECTS) and its latest version compiled in Skill 4 V2.
4. Silver table list and build order: from the design tables and the parent rules (parents first). Show it.
5. Bronze rows for the batch ID, per table. If a table has 0 rows for the batch, say so.
6. Existing Silver and quarantine tables: rows per table and per `_BATCH_ID` before the build. If the batch was already built, say so: a rebuild gives the same result, it does not add rows twice.
7. Privileges of the pipeline role: SELECT on Bronze, CREATE TABLE on the Silver schema, USAGE on the dbt project and warehouse. List missing ones and STOP.

## Step 1: Plan (STOP GATE 1)

Show:

- Batch ID, role, warehouse, database, build order.
- Bronze rows per table for the batch.
- Thresholds from the config: WARN at `quarantine_warn_pct` %, STOP at `quarantine_stop_pct` %.
- The build command per table:
  `EXECUTE DBT PROJECT <dbt_project_object> ARGS = 'build --select quarantine_<table> silver_<table>';`
- The answer key rows (or "no answer key").
- The checks of Step 3 and the expected value of each.
- What a STOP means: tables already built stay built. Nothing is undone. The human decides the next action.
- Rollback: none by design. A rebuild after a fix replaces the dbt tables. State this plainly.

Wait for explicit approval. Do not build before it.

## Step 2: Build, one table at a time

For each Silver table in order:

1. Run the build command for that table.
2. Read the result: SUCCESS, and the dbt summary line (PASS, WARN, ERROR, SKIP, TOTAL). If the output grid cannot show the log, read the summary lines with RESULT_SCAN of the last query.
3. If ERROR > 0 or SUCCESS is false: STOP at once. Report the failed model or test and its message. Do not build the next table.
4. Quarantine percent for this batch:
   quarantined rows with `_BATCH_ID` = batch / Bronze rows with `_BATCH_ID` = batch x 100, rounded to 2 decimals.
5. Compare with the config thresholds:
   - percent >= `quarantine_stop_pct`: STOP. Do not build the next table. Go to Step 4 and report.
   - percent >= `quarantine_warn_pct`: WARN. Note it and continue.
   - else OK.
6. Show one line per table: Bronze, Silver, quarantine, percent, status (OK / WARN / STOP), dbt PASS/WARN/ERROR.

## Step 3: Validate (read only)

1. **Reconciliation**: per table, for the batch, Bronze rows = Silver rows + quarantine rows. Show all three numbers.
2. **Keys**: no duplicate business key in Silver (count distinct key = count rows). Silver key never NULL.
3. **Values** (Bronze is the source of truth): for each numeric Silver column, SUM in Silver = SUM of the same cast over the Bronze rows that are not in quarantine. Show both sums and the difference.
4. **Null rates**: per Silver column, null count in Silver vs the matching Bronze rows. A higher null count in Silver means a cast or CLEAN rule turned values into NULL: list it.
5. **Casts that lost data**: per cast column, count rows where Bronze has a value but Silver is NULL.
6. **Planted defects**: for each answer-key row, show expected outcome and REJECT_REASON next to the actual one. MATCH or MISMATCH. Never edit the key to match.
7. **Quarantine reasons**: count rows per REJECT_REASON per table. Every reason must be a rule id or parent reason from the approved rules. List any reason that is not.
8. **Parent effect**: rows quarantined with a PARENT reason vs quarantined parent keys.
9. **dbt tests**: list every test with WARN or ERROR from Step 2.
10. **Masking** (only if `masking` is on in the config). No PII value is ever shown, only counts:
   - Metadata: for every PII column of every Silver and quarantine table, POLICY_REFERENCES shows the planned policy. A missing one = FAIL (the post-hook did not run).
   - As the pipeline role: count rows where the PII column is not NULL and not equal to the mask value. Expected 0 (the pipeline role sees masked values).
   - Clear-value test: ask the human who holds `pii_reader_role` to run one count query: rows where the column equals the mask value. Expected 0 (clear values). The human reports only the number. This skill never switches to that role itself.
11. **Credits** (only if the role can read metering views): warehouse credits for this run vs `credit_limit` from the config. If not readable, write "not measured".

## Step 4: Report (STOP GATE 2)

One table: check, expected, actual, PASS / FAIL / WARN. MISMATCH and FAIL rows first. Include:

- Per table: Bronze, Silver, quarantine, percent, WARN / STOP against the config thresholds.
- Every Step 3 result.
- **Quarantine review**: per table, the top reasons with counts. For each reason, the human picks one: (a) fix at the source and send a new batch, (b) the rule is wrong, change it in the schema design skill (then Skill 4 V2 again), (c) accept as rejected. This skill does not change anything; it records the human's choice in the report.
- Confirm: no file, rule or grant changed; only dbt builds ran.

Wait for approval before the Gold skill.

## Gotchas

- Each build rebuilds the whole Silver table from all Bronze batches (`materialized: table`). Running again is safe and gives the same rows; it does not add duplicates like Version 1 procedures did.
- A rebuild removes grants, masking policies and tags put on the table by hand. Masking comes back through the dbt post-hook; check it in Step 3 item 10 after every build. Tags are not re-applied (open item).
- A STOP does not undo tables already built. Parents first keeps the damage small.
- A high parent quarantine raises the child quarantine with PARENT reasons. Read the parent first.
- Row counts alone are not a pass. Values and planted defects decide.
- `dbt build --select` on one table still checks tests that refer to other tables (relationships). Build parents first or those tests fail.
- Long log text may not show in the result grid. Use RESULT_SCAN and filter lines with Done, Finished, WARN, ERROR.

## Failure Handling

- dbt error or test error: STOP, report model or test name and message. Do not edit files here; go back to Skill 4 V2.
- Privilege error: STOP, report statement, error and missing privilege. Do not switch role.
- Threshold STOP: report, do not continue to the next table.
- Plan vs result mismatch: report it. Never change the expected value.

## Output

Silver and quarantine tables built by dbt for the batch, the dbt run results, and the Step 4 validation report with the human's quarantine review choices.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 5. Otherwise skip this step.

- File: `pipeline-reports/de-dbt-load-validate_<batch-id>_report.md`. Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, Quarantine, Warnings and open items, Handed to the next skill.
- Numbers only from queries in this session; else "not measured". No PII values, no secrets.
- The next skill reads Snowflake, never this file.
