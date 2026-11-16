---
name: de-deep-load-validate
description: Loads one Bronze batch into Silver by calling the load procedures built by de-deep-transform-setup, then validates value-level results, quarantine thresholds and PII masking. Use after Skill 4 is approved and a Bronze batch exists. Does not create objects.
---

# DE Deep Load and Validate

## When to Use

- Skill 4 is approved and a new Bronze batch ID is ready to load.
- Re-validating a batch that was already loaded.

## When Not to Use

- Procedures, tables or grants are missing (run Skills 3 and 4 first).
- Building Gold or Dynamic Tables (Skill 6).
- Changing rules, tables or grants (go back to Skill 2, 3 or 4).

## Inputs (ask if missing)

- Database, Bronze schema, design schema, Silver schema, warehouse.
- Batch ID (example B001).
- Role: DE_LOADER for loading. DE_PII_READER and DE_ANALYST only for the masking test. Run USE SECONDARY ROLES NONE.
- Thresholds: WARN 1 percent, STOP 5 percent of rows read per table (user may override).
- Answer key: expected result per planted defect (table, key, expected outcome: loaded or quarantined and which RULE_ID). If none exists, build it from the profile in Step 1 and get it approved at STOP 1.

## Rules

- Call only the 6 LOAD_ procedures, in the order CUSTOMERS, PRODUCTS, ORDERS, then ORDER_ITEMS, PAYMENTS, RETURNS.
- Never create, alter, drop or delete any object. Never change rules or grants.
- Never call a procedure twice for the same batch ID (it duplicates quarantine and log rows).
- Never skip or merge STOP gates. Never mark a check PASS without showing the numbers.
- Use the least privileged role for each action. Never ACCOUNTADMIN.
- Report every number from queries, never from memory.

## Step 0: Pre-checks (read only)

1. Confirm role, USE SECONDARY ROLES NONE, warehouse.
2. Confirm the 6 procedures exist and DE_LOADER has USAGE on each.
3. Confirm Bronze rows exist for the batch ID, per table.
4. Confirm Silver, quarantine and log tables exist. If the batch ID already appears in LOAD_BATCH_LOG, STOP and ask.
5. Show a count of rows per Silver and quarantine table before loading.

## Step 1: Plan (STOP 1)

Show a plan with:

- Batch ID, role, warehouse, call order, target environment (the database).
- Bronze row count per table.
- The answer key: every planted defect with expected outcome.
- Value-level checks to run (see Step 3) with the expected value for each.
- Thresholds.
- What a failure means: no cleanup is possible without DELETE, so a bad load is reported and left for the user to decide.
- Rollback: none by design. State this plainly.

Wait for explicit approval. Do not load before it.

## Step 2: Load

1. For each table in order, call the procedure with the batch ID. One call per table.
2. After each call read LOAD_BATCH_LOG for that table: rows read, loaded, quarantined, status.
3. Quarantine percent = quarantined / read. At or above STOP threshold: stop loading further tables and go to Step 4. At or above WARN: note it and continue.
4. If a procedure errors, stop at once. Do not retry or work around it. Report the error text.

## Step 3: Validate (read only)

1. Reconciliation: per table, Bronze rows = loaded + quarantined (duplicates counted per D3). Show all three numbers.
2. Value-level checks, Bronze as source of truth:
   - Sum of numeric columns (UNIT_PRICE, QUANTITY, LINE_AMOUNT, payment amount) in Silver vs the same sum over Bronze rows that passed the rules.
   - Null rate per column in Silver vs Bronze.
   - Distinct key counts; no duplicate business keys in Silver.
   - PARENT_QUARANTINED row counts vs quarantined parents.
3. Planted defects: for each answer-key row show actual outcome and REJECT_REASON next to expected. Mark MATCH or MISMATCH.
4. Skill 4 open items, test and report each:
   - Blank '' vs NULL in Bronze: count of '' per column.
   - Orders whose customer is missing in Silver CUSTOMERS (no rule covers this).
   - Lines with NULL QUANTITY or UNIT_PRICE loaded with NULL LINE_AMOUNT.
5. LOAD_DQ_LOG: failed rows per RULE_ID add up to the quarantine counts.
6. Masking test: as DE_PII_READER select the 3 PII columns of SILVER.CUSTOMERS (expect clear values). As DE_LOADER and DE_ANALYST (if it has access) expect masked values. One sample row per role. Switch back to DE_LOADER after.

## Step 4: Report (STOP 2)

One table: check, expected, actual, PASS/FAIL/WARN. Include:

- Per-table read, loaded, quarantined, percent, status vs thresholds.
- All Step 3 results, every MISMATCH first.
- Open items found, with a recommendation each (do not fix them).
- Confirm no object was created or changed and each procedure was called once.

Wait for approval.

## Gotchas

- A WARN or STOP threshold does not undo a load. Procedures never abort on threshold.
- Child tables depend on parents: high ORDERS quarantine means high PARENT_QUARANTINED in lines, payments, returns.
- PRODUCTS is FULL_RELOAD: a second call replaces all rows.
- Row counts alone are not a pass. Value checks decide.
- Pasted long text may lose line breaks. Re-read it before acting.

## Failure Handling

- Privilege error: stop, report the statement and error, do not try another role or grant.
- Plan vs result mismatch: stop and report. Never adjust the expected value to match.
- Unclear answer key: ask at STOP 1.

## Output

- Silver and quarantine tables filled for the batch, log rows written.
- Validation report at STOP 2 with PASS/FAIL per check.
- Open items and recommended next actions.

## Final Step: Write the result report (.md)

Do this as the very last action of the skill, after the human has answered the final stopping point. Also do it when the skill stops early (failed check, error, privilege problem or threshold STOP): then the status is STOPPED or FAILED and the report says at which step and why.

- File name: `de-deep-load-validate_<batch-id>_report.md`, for example `de-deep-load-validate_B001_report.md`.
- Batch ID: the batch ID that was loaded in this run.
- Folder: `pipeline-reports/` in the workspace (create it if missing), unless the human names another folder. If a file with the same name already exists, do not overwrite it: save as `..._report_v2.md` (then v3, and so on).
- The report is for humans and Git only. The next skill still reads its input from the Snowflake tables, never from this file.
- Take every number from queries run in this session, never from memory. If a number was not measured, write "not measured".
- Never write PII values, sample values of PII columns, passwords, keys or tokens into the report.
- Writing the report creates no Snowflake object and changes no data.

Use these headings, in this order:

1. **Summary**: skill name, batch ID, database, role, warehouse, start and end time (UTC), final status (APPROVED, STOPPED or FAILED) and the approval given at each stopping point.
2. **What was done**: procedures called, in order, each called once; role used for loading and for the masking test.
3. **Row counts**: per table: Bronze rows read, loaded to Silver, quarantined, and Bronze = loaded + quarantined.
4. **Checks**: one table with check, expected, actual, PASS/FAIL/WARN. Include every row of the Step 4 table, every MISMATCH first, and the planted-defect answer key (expected vs actual, MATCH or MISMATCH).
5. **Quarantine**: per table: quarantined rows and percent against the WARN and STOP thresholds, failed rows per RULE_ID from LOAD_DQ_LOG, PARENT_QUARANTINED rows.
6. **Warnings and open items**: WARN results, open items from Step 3 with the recommendation for each, anything not tested.
7. **Handed to the next skill**: the Silver tables loaded for this batch, plus LOAD_BATCH_LOG and LOAD_DQ_LOG rows, read next by de-deep-transform.

After saving, show the file path and its line count. Do not start the next skill.
