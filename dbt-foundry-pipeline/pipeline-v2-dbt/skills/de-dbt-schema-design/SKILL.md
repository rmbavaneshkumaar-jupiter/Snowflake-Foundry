---
name: de-dbt-schema-design
description: Phase 2 V2 (Design). Reads the profile and the human-approved PII classification from Skill 1 V2 and proposes the Silver table design, the Silver column design, the rules table (one row per data quality rule, with CLEAN or QUARANTINE and parent checks) and the Gold design. The human approves every row. Creates design tables only; no Silver, Gold or role object. Use after de-profile-classify and before de-dbt-schema-setup.
---

# de-dbt-schema-design (Skill 2, Version 2)

Version 1 (de-deep-schema-design) also designed roles (ROLE_DESIGN), guessed PII from column names, and its output was read as "7 notes" in one place and "73 rules" in another.
Version 2 changes:

1. **One word: rules table.** Every data quality rule is one row in the rules table (SILVER_DQ_RULES). There are no separate "notes". Free text goes in the REASON column of the rule it belongs to.
2. **PII comes from Skill 1 V2 only.** pii_flag and masking_needed are copied from the APPROVED rows of PII_COLUMN_CLASSIFICATION. This skill never decides PII itself.
3. **No role design.** The pipeline uses one least-privilege role from the config. People get their roles from the admin.
4. **The rules table is shaped for dbt.** de-dbt-project-setup (Skill 4 V2) turns each row into SQL, so every row must be exact: rule type, detail, action, parent, reject reason text.
5. **Rule maintenance.** A rule that the Skill 5 V2 quarantine review calls wrong comes back here and gets a new version; the old row is RETIRED, never deleted.

This skill is generic. It never contains a source table name, a column name, a value list or a threshold number. They come from the profile, the classification and the human.

## When to Use

- Skill 1 V2 is done: TABLE_INVENTORY has in_scope answered, and PII_COLUMN_CLASSIFICATION has APPROVED rows for the latest run.
- A rule must change after a quarantine review (Step 6, rule maintenance).
- A new in-scope table or a new Gold goal was added.

## When Not to Use

- Profile or PII review missing: run de-profile-classify first.
- To create tables, masking policies or dbt files: Skills 3 and 4 V2.
- To create roles or grants: the admin does that.

## Inputs (ask the human if missing, never assume)

1. Config file path. From it: database, warehouse, role, schemas.
2. Business goal for Gold: measures, grouping, grain, time period, and which date decides the month for each measure. Always ask. No default goal.
3. Optional notes step: ask once, "Write the result notes file at the end? (yes/no)". Default no.

## Rules

- **Role**: only the pipeline role from the config. Never ACCOUNTADMIN, SYSADMIN, SECURITYADMIN or ALL PRIVILEGES. USE SECONDARY ROLES NONE. No role creation, no GRANT.
- **Design tables only**, in the monitoring schema. No Silver, quarantine or Gold object, not even empty.
- **Never invent a business rule.** Propose from the profile numbers; the human approves.
- **PII**: never decide or change a PII class. Read only APPROVED rows of the latest classification run. A column still PROPOSED there = STOP, go back to Skill 1 V2.
- Never put a PII value or a sample value into any table, message or report. Allowed-value lists are only proposed for columns with pii_flag = N.
- **Thresholds and table type are not design**: quarantine thresholds, credit limit, gold_mode and target lag live in the config only.
- Plain CREATE for new design tables. Existing design tables: STOP and ask (reuse, new version, or stop). Never DROP or OR REPLACE.
- Two human STOP gates: STOP 1 (review the proposal) and STOP 2 (approvals recorded and checked).

## Step 0: Checks (read only)

1. Config read; role, secondary roles and warehouse match.
2. TABLE_INVENTORY: list tables with in_scope = Y. If any in_scope is NULL, STOP.
3. COLUMN_PROFILE exists for every in-scope table.
4. PII_COLUMN_CLASSIFICATION, latest run id: every row of an in-scope table is APPROVED or REJECTED. Show the APPROVED classes per table (names and classes only).
5. Design tables already present? List them with row counts and status.

## Step 1: SILVER_TABLE_DESIGN

Columns: SOURCE_TABLE, SILVER_TABLE, BUSINESS_KEY, PARENT_TABLES, LOAD_MODE, REASON, STATUS, DECIDED_BY, DECIDED_AT.

- BUSINESS_KEY: propose from the profile (unique_pct = 100 and no NULL). If none qualifies, or the key repeats inside a batch, flag it for the human. Never guess.
- PARENT_TABLES: the Silver tables this table refers to (from key names and the human). Used for the build order.
- LOAD_MODE: INCREMENTAL_MERGE (default) or FULL_RELOAD with a written reason. (Open item: the dbt models rebuild fully today.)

## Step 2: SILVER_COLUMN_DESIGN

Columns: SILVER_TABLE, COLUMN_POSITION, COLUMN_NAME, SOURCE_COLUMN, TARGET_TYPE, PII_FLAG, PII_CLASS, MASKING_NEEDED, NOTES, STATUS.

- TARGET_TYPE from COLUMN_PROFILE inferred_type. Bronze is text, every cast is explicit.
- A rename (SOURCE_COLUMN differs from COLUMN_NAME) is written in NOTES.
- PII_FLAG, PII_CLASS, MASKING_NEEDED: copied from the APPROVED classification row of the source column. Never edited here.
- A column that is NULL in every row: propose to drop it; the human decides.

## Step 3: The rules table (SILVER_DQ_RULES)

Columns:

| column | meaning |
|---|---|
| RULE_ID | stable id, `<SILVER_TABLE>-<COLUMN>-<RULE_TYPE>-<n>` |
| RULE_VERSION | 1 for a new rule, +1 after maintenance |
| SILVER_TABLE, COLUMN_NAME | where the rule applies (Silver column name) |
| RULE_TYPE | NOT_NULL, TYPE_CAST, ALLOWED_VALUES, FORMAT, RANGE, UNIQUE_KEY, PARENT_EXISTS |
| RULE_DETAIL | exact detail Skill 4 V2 writes as SQL: value list, regex, range condition, date format, or clean expression |
| ACTION | CLEAN or QUARANTINE |
| APPLY_ORDER | CLEAN rules first (1), checks after (2) |
| PARENT_TABLE, PARENT_COLUMN | only for PARENT_EXISTS |
| PARENT_OUTCOME | only for PARENT_EXISTS: MISSING_ONLY, or MISSING_AND_QUARANTINED (two different reasons) |
| REJECT_REASON_TEXT | the exact text written to REJECT_REASON when the rule fails |
| ALLOWS_NULL | Y or N: is an empty value a pass for this rule |
| REASON | why this rule exists, plain words, no data values for PII columns |
| STATUS | PROPOSED, APPROVED, RETIRED |
| DECIDED_BY, DECIDED_AT | who approved, when |

How to choose CLEAN or QUARANTINE (write the choice in REASON):

- **CLEAN** when the change keeps the meaning: remove spaces, change case, empty text to NULL, one standard format.
- **QUARANTINE** when the value is missing, wrong, not convertible, outside the list or range, a duplicate key, or its parent is missing.
- When in doubt, QUARANTINE and ask. Never CLEAN a value into a different value.

Coverage rules:

- Every Silver column has at least one rule.
- A text column with a small set of values gets ALLOWED_VALUES or FORMAT proposed (non-PII only). A type check alone does not catch bad text.
- Numeric columns get RANGE proposed from the profile (for example not negative); the human sets the real limits.
- Every column that refers to a parent table gets PARENT_EXISTS.
- An ALLOWED_VALUES rule says in REASON that a real new value will be quarantined until the list is updated (Step 6).

## Step 4: GOLD_TABLE_DESIGN

Columns: GOLD_TABLE, GRAIN, MEASURES, MEASURE_DATE_RULE, DIMENSIONS, SOURCE_SILVER_TABLES, UNKNOWN_RULE, SPLIT_RULE, REASON, STATUS.

- Only from the business goal in Inputs item 2.
- GRAIN in one sentence. MEASURE_DATE_RULE: which date sets the month for each measure.
- UNKNOWN_RULE: a fact whose dimension is missing in Silver stays, under the value UNKNOWN.
- SPLIT_RULE: only if one amount is shared over several Gold rows; say how and how it is rounded.
- No DIMENSIONS or MEASURES from a column with PII_FLAG = Y.
- No build type or target lag here: gold_mode in the config decides (Skill 6 V2).

## Step 5: Consistency check and review (STOP GATE 1)

Check and show:

- every in-scope table has one Silver design row with a business key;
- every Silver column has at least one rule; every rule has RULE_TYPE, ACTION, REJECT_REASON_TEXT;
- every PARENT_EXISTS rule points to a Silver table that exists in the design, and the parent graph has no loop;
- PII columns in the column design = APPROVED classes from Skill 1 V2 (count both);
- no Gold measure or dimension uses a PII column;
- counts: rules per table, split CLEAN / QUARANTINE, and per RULE_TYPE. Say this number as "rules in the rules table", nothing else.

Show the four design tables, all rows PROPOSED. The human approves, edits or rejects per row or per table. Write nothing as APPROVED without the human's answer.

## Step 6: Rule maintenance (only when a rule changes)

Used when the Skill 5 V2 quarantine review chose "the rule is wrong" (for example a real new value outside an allowed list).

1. Show the current rule row and the quarantine count per reason it caused (counts only).
2. Propose the new RULE_DETAIL or ACTION. The human approves.
3. Insert the new row with RULE_VERSION + 1, STATUS APPROVED. Set the old row STATUS RETIRED. Never delete or overwrite the old row.
4. Tell the human: Skill 4 V2 must write the dbt files again, then Skill 5 V2 rebuilds and the quarantined rows are checked again.

## Step 7: Record approvals and verify (STOP GATE 2)

Write STATUS, DECIDED_BY = CURRENT_USER(), DECIDED_AT per row. Then re-run the Step 5 checks on the APPROVED rows only and show PASS / FAIL. Wait for the human before Skill 3 V2.

## Gotchas

- A business key that repeats inside one batch is a question for the human, never a silent choice.
- Clean first, then check: a check on the raw value rejects a value that only had extra spaces. APPLY_ORDER makes this explicit.
- An empty text is not NULL. Decide with ALLOWS_NULL and a CLEAN rule (empty to NULL).
- A fixed allowed-value list will reject a real new value. That is expected; Step 6 is the way to change it.
- Snowflake tags on Bronze are not copied to Silver by dbt. The column design is where Silver PII lives.

## Failure Handling

- Missing or unapproved input (profile, scope, PII review): STOP and name it.
- A rule that cannot be written exactly (no clear list, regex or range): leave it PROPOSED and ask.
- Privilege error: STOP, show the missing privilege for the admin.

## Output

SILVER_TABLE_DESIGN, SILVER_COLUMN_DESIGN, the rules table SILVER_DQ_RULES and GOLD_TABLE_DESIGN, all APPROVED, read next by de-dbt-schema-setup, de-dbt-project-setup and de-dbt-gold.

## Optional Final Step: notes file (.md)

Only if the human said yes in Inputs item 3. Otherwise skip.

- File: `pipeline-reports/de-dbt-schema-design_<batch-id>_report.md`. Never overwrite: add `_v2`, `_v3`.
- Headings: Summary, What was done, Row counts (rules in the rules table per table and type), Checks, Quarantine (planned reasons), Warnings and open items, Handed to the next skill.
- No PII values, no secrets. Numbers only from queries in this session.
