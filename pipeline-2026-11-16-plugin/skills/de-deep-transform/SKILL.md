---
name: de-deep-transform
description: Builds the Gold layer as Dynamic Tables from the approved GOLD_TABLE_DESIGN, reading only clean Silver data, then verifies the Gold numbers against Silver and tests analyst access. Use after Silver is loaded and validated (Skill 5). Does not load or change Silver.
---

# DE Deep Transform (Gold)

## When to Use

- Silver is loaded and validated, and GOLD_TABLE_DESIGN is approved.
- Adding or rebuilding Gold tables from the design.

## When Not to Use

- Silver is empty or the last load was not approved (run Skill 5 first).
- Changing Silver tables, rules or load procedures (Skills 2 to 4).
- Changing Gold design (go back to Skill 2).

## Inputs (ask if missing)

- Database, Silver schema, Gold schema, design schema, warehouse.
- Role: DE_TRANSFORMER to build. DE_ANALYST for the access test only. Run USE SECONDARY ROLES NONE.

## Rules

- Build only the tables listed in GOLD_TABLE_DESIGN with STATUS APPROVED. Take the target lag and warehouse from the design.
- Gold is Dynamic Tables only. Read from Silver only, never from Bronze or quarantine tables.
- Plain CREATE only. No OR REPLACE, no DROP, no ALTER on existing objects.
- Quarantined products: order lines stay, category shows as UNKNOWN (COALESCE on a LEFT JOIN to PRODUCTS).
- Never select PII columns (CUSTOMER_NAME, EMAIL, PHONE) into Gold.
- Grant DE_ANALYST SELECT on the Gold tables only. No other grants. Never ACCOUNTADMIN, ALL PRIVILEGES or OWNERSHIP.
- Never skip a STOP gate. Never mark a check PASS without showing numbers.
- Report numbers from queries, never from memory.

## Step 0: Pre-checks (read only)

1. Confirm role, USE SECONDARY ROLES NONE, warehouse.
2. Read GOLD_TABLE_DESIGN: list each table, STATUS, lag, warehouse, business question. If any row is not APPROVED, stop.
3. Confirm Silver tables have rows, and show the row count of each.
4. Confirm DE_TRANSFORMER has: SELECT on Silver tables, CREATE DYNAMIC TABLE on Gold, USAGE on the warehouse. If any privilege is missing, stop and report. Do not grant it yourself or switch role.
5. Confirm the Gold tables do not already exist.

## Step 1: Plan (STOP 1)

Show:

- Target environment (the database) and role.
- For each Gold table: name, the full SELECT definition, grain (one row per month and category or city), lag, warehouse, join logic.
- How quarantined products (UNKNOWN category) and customers missing from Silver are handled in each table.
- Expected values per table, computed from Silver with plain queries: row count, total sales, total refunds.
- Grants to DE_ANALYST.
- Rollback: drop of the new Gold tables by SYSADMIN, since Gold holds no source data.

Wait for explicit approval before creating anything.

## Step 2: Build

1. Create each Dynamic Table with the approved definition, one statement each.
2. Grant SELECT on each to DE_ANALYST.
3. Trigger the first refresh and wait until each table has a refresh with state SUCCEEDED.
4. If any statement fails, stop at once. Do not retry or work around it.

## Step 3: Verify (read only)

1. Row counts of each Gold table vs the expected values.
2. Total sales and total refunds in Gold vs the same totals from Silver. Show both numbers.
3. A category UNKNOWN row exists, with the sales of lines whose product is quarantined. Show it.
4. No NULL month, category or city in Gold. List any NULL city and why.
5. No PII columns exist in Gold.
6. As DE_ANALYST: SELECT from each Gold table works; SELECT from a Silver table is denied. Show both results. Switch back after.
7. Refresh history: last refresh state, time and lag per table.

## Step 4: Report (STOP 2)

One table: check, expected, actual, PASS/FAIL. Include:

- Gold tables created, row counts, lag, last refresh.
- Any mismatch first, with the cause if known.
- Sample rows (top 5) of each Gold table.
- Confirm that Silver and design tables were not changed.

Wait for approval.

## Gotchas

- Dynamic Tables refresh on a schedule. Check the refresh state before comparing numbers.
- Returns can reach Gold through their order. Follow the join logic approved at STOP 1.
- Orders for customers missing in Silver have no city. Report the count, never hide it.
- A bad Silver load flows into Gold at the next refresh.
- Pasted long text may lose line breaks. Re-read it before acting.

## Failure Handling

- Privilege error: stop, report statement and error, no other role.
- Plan vs result mismatch: stop and report. Never change the expected value to match.
- Object already exists: stop and ask.

## Output

- Gold Dynamic Tables built, refreshed and readable by DE_ANALYST.
- Verification report at STOP 2 with PASS/FAIL per check.
- Open items and recommended next actions.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-transform_<batch-id>_report.md`, for example `de-deep-transform_B001_report.md`.
- Batch ID: the latest batch ID in LOAD_BATCH_LOG (the newest Silver data that Gold reads).
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: Gold Dynamic Tables created (name, grain, lag, warehouse), grants to DE_ANALYST, first refresh state.
3. **Row counts**: row count of each Gold table, and total sales and total refunds in Gold next to the same totals from Silver.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every Step 3 verification, including the DE_ANALYST access test.
5. **Quarantine**: rows that show category UNKNOWN or city UNKNOWN in Gold, with their sales amount and the reason (quarantined product or customer missing in Silver).
6. **Warnings and open items**: mismatches with their cause, NULL values found, refresh problems.
7. **Handed to the next skill**: the Gold Dynamic Tables, readable by DE_ANALYST, audited next by de-deep-share-monitor.

After saving, show the file path and its line count. Do not start the next skill.
