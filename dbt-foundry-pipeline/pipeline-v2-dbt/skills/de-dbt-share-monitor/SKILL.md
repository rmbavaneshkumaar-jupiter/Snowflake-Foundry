---
name: de-dbt-share-monitor
description: Phase 7 V2 (Share and Monitor). Part A audits access for the dbt pipeline (pipeline role privileges, Gold-only sharing, no PII in Gold, masking and tags when switched on) without switching role. Part B creates monitoring views in the monitoring schema for quarantine rate per batch and table, dbt run results, Gold refresh health and estimated cost against the credit limit, plus optional suspended alerts. Use after de-dbt-gold is approved.
---

# de-dbt-share-monitor (Skill 7, Version 2)

Version 1 (de-deep-share-monitor) ran as SYSADMIN, read V1 objects (ROLE_DESIGN, LOAD_BATCH_LOG, LOAD_DQ_LOG, LOAD_ procedures), tested three design roles with USE ROLE, and did not see a failed Gold refresh.
Version 2 changes:

1. **One pipeline role, no SYSADMIN.** Runs as the role in the config. Never switches role. Tests that need another role are run by a person who holds that role; they report counts only.
2. **Reads the dbt world**: the Silver and quarantine tables built by dbt, the dbt project executions, and the Gold tables.
3. **Gold refresh health** is a monitored item (failed, skipped or late refresh).
4. **All numbers from the config**: thresholds and the credit limit are copied from the config into a settings table, and the views read that table. No number is written in a view or in this skill.

This skill is generic. It never contains a source table name, a column name, a role name or a threshold number. Table lists come from the design tables; settings from the config.

## When to Use

- de-dbt-gold is approved for the latest batch.
- After every batch, to refresh the audit and read the monitoring views.

## When Not to Use

- Skills 1 to 6 V2 are not approved.
- To change grants, roles, masking, Silver or Gold: those belong to the admin or to the earlier skills. This skill only reads them and writes monitoring objects.

## Inputs (ask the human if missing, never assume)

1. Config file path. From it: database, warehouse, role, schemas, `quarantine_warn_pct`, `quarantine_stop_pct`, `credit_limit`, `gold_mode`, `gold_target_lag`, and the optional `masking`, `pii_reader_role`, `gold_reader_role`.
2. dbt project object name. Batch IDs to report on.
3. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. USE SECONDARY ROLES NONE. Never USE ROLE to another role.
- **No role or grant work.** Missing access = STOP and show what the admin must grant (for usage data: a SNOWFLAKE database role for usage viewing given to the pipeline role).
- **Create only in the monitoring schema**: one settings table, views, ALERT_LOG and alerts. Plain CREATE; never DROP, DELETE, OR REPLACE, or ALTER on Bronze, Silver, quarantine or Gold.
- **Settings from the config only**: thresholds and credit limit are inserted into PIPELINE_SETTINGS from the config (one new row set per change, with LOADED_AT). Views read the latest row. Never a number in a view.
- **Never select a PII value.** Masking checks use metadata and counts.
- Credit numbers are ESTIMATES. Say so every time.
- Two human STOP gates: STOP 1 (plan) and STOP 2 (report). Alerts are created SUSPENDED and resumed only with the human's explicit yes.

## Step 0: Checks (read only)

1. Config read; role, secondary roles and warehouse match.
2. Design tables APPROVED; list of Silver tables (from the table design) and Gold tables (from the Gold design).
3. Silver, quarantine and Gold tables exist (SHOW TABLES / SHOW DYNAMIC TABLES), owner = pipeline role.
4. Usage access: can the pipeline role read SNOWFLAKE.ACCOUNT_USAGE QUERY_HISTORY and WAREHOUSE_METERING_HISTORY? If not, tell the human the grant the admin must run. The human chooses: wait, or continue with cost "not measured".
5. EXECUTE ALERT available to the pipeline role? If not, alerts are skipped and reported as skipped.
6. Monitoring objects already present? List them. Existing ones are reused, never replaced.
7. Usage data can lag up to about 3 hours. If the batch finished less recently, warn that cost may be incomplete.

## Step 1: Plan (STOP GATE 1)

Show: the Part A checks, the Part B objects with their columns, the settings row that will be inserted (values from the config), what is skipped and why. Wait for approval.

## Step 2: Part A, access audit (read only)

Write each result to ACCESS_AUDIT_RESULT (CHECK_NAME, OBJECT_NAME, EXPECTED, ACTUAL, STATUS, CHECKED_AT).

1. Pipeline role: SHOW GRANTS TO ROLE and SHOW GRANTS OF ROLE. It has no ACCOUNTADMIN, SYSADMIN or SECURITYADMIN in its role tree, no ALL PRIVILEGES, and no privilege outside the pipeline database. It does not inherit `pii_reader_role`.
2. Gold sharing (only if `gold_reader_role` is set): SHOW GRANTS ON each Gold table shows SELECT to that role. SHOW GRANTS TO ROLE `gold_reader_role` shows no privilege on Bronze, Silver or quarantine tables.
3. No PII in Gold: Gold columns (INFORMATION_SCHEMA.COLUMNS) vs the PII columns of the column design. Must be none.
4. Masking (only if `masking` is on): POLICY_REFERENCES shows the policy on every PII column of every Silver and quarantine table. As the pipeline role, count non-NULL PII values not equal to the mask value: expected 0. Ask the person who holds `pii_reader_role` to run the matching count; expected 0 masked values. They report numbers only.
5. Bronze tags from Skill 1 V2: TAG_REFERENCES_ALL_COLUMNS per Bronze table = the APPROVED PII columns.

## Step 3: Part B, monitoring objects

All in the monitoring schema. Table lists are generated from the design tables (one UNION ALL branch per Silver table).

1. **PIPELINE_SETTINGS** (SETTING_NAME, SETTING_VALUE, LOADED_AT): insert the config values `quarantine_warn_pct`, `quarantine_stop_pct`, `credit_limit`, `gold_mode`, `gold_target_lag`.
2. **VW_QUARANTINE_RATE**: per batch and Silver table: Bronze rows, Silver rows, quarantine rows, quarantine percent, STATUS (OK / WARN / STOP from PIPELINE_SETTINGS), and Bronze = Silver + quarantine (Y/N).
3. **VW_QUARANTINE_REASONS**: per batch, table and REJECT_REASON: row count. (Counts only, never row values.)
4. **VW_DBT_RUNS**: from QUERY_HISTORY, every `EXECUTE DBT PROJECT` on the pipeline's dbt project: start, end, minutes, status, error message, warehouse, the dbt arguments. (Per-model results inside the dbt log are not read: open item.)
5. **VW_GOLD_REFRESH_HEALTH**: per Gold table.
   - `gold_mode` = dynamic_table: from INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY: last refresh state, last SUCCEEDED time, count of FAILED / UPSTREAM_FAILED / SKIPPED in the window, and lag now vs target lag. STATUS = FAIL when the last refresh failed, LATE when the lag is above the target.
   - `gold_mode` = table: the last successful dbt build that touched Gold, from VW_DBT_RUNS.
6. **VW_PIPELINE_COST**: per day and per dbt run: estimated warehouse credits (metered hourly credits split by query elapsed time), cloud services credits, total, credit limit from PIPELINE_SETTINGS, OK / OVER. Credits per 1,000 Silver rows.
7. **VW_PIPELINE_HEALTH**: one row per batch: worst quarantine status, Gold refresh status, last dbt run status, cost status. Overall = the worst of them.
8. Alerts (only if EXECUTE ALERT is available): ALERT_LOG table and three alerts, all created SUSPENDED: quarantine STOP reached; cost OVER the limit; Gold refresh FAIL or LATE. Each action inserts a row into ALERT_LOG. Sending email or chat needs a notification integration from the admin (open item).

## Step 4: Verify (read only)

1. Query every view and show the rows for the requested batches.
2. VW_QUARANTINE_RATE numbers equal the Skill 5 V2 report for the same batch.
3. VW_GOLD_REFRESH_HEALTH shows every Gold table.
4. Sum of estimated run credits is not above the metered credits for the window.
5. ACCESS_AUDIT_RESULT: list every FAIL first.

## Step 5: Report (STOP GATE 2)

Show: the access audit (PASS / FAIL per check), quarantine rate per batch and table, top quarantine reasons, dbt runs, Gold refresh health, cost against the limit (estimate), objects created, alerts created or skipped, open items. Ask before resuming any alert.

## Gotchas

- ACCOUNT_USAGE views lag; INFORMATION_SCHEMA refresh history is current but covers a limited time window.
- A dbt rebuild removes grants that dbt does not manage. Gold grants must come from the dbt grants config, not by hand, or this audit will fail after the next build.
- A dynamic table with refresh mode FULL costs more than INCREMENTAL. Report the mode next to the cost.
- Quarantine percent is per batch. A rebuild over all batches does not change old batch numbers.
- IS_ROLE_IN_SESSION also counts inherited roles: a role tree that includes the PII reader role sees clear values.

## Failure Handling

- Missing access: STOP, show what the admin must grant. Never switch role.
- An audit FAIL is reported, never fixed here.
- A view that does not compile: show the error; fix only the view text this skill wrote.

## Output

ACCESS_AUDIT_RESULT, PIPELINE_SETTINGS, the six monitoring views, ALERT_LOG and suspended alerts (if allowed), and the Step 5 report. This is the last skill of the build.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 3. Otherwise skip.

- File: `pipeline-reports/de-dbt-share-monitor_<batch-ids>_report.md`. Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts, Checks, Quarantine, Warnings and open items, Handed over (the views the team reads after each batch).
- Credit numbers marked as estimates. No PII values, no secrets.
