# Skill 1: From Bronze to a trusted profile

![Skill 1: Bronze tables, profile steps, output](img/skill-1-flow.png)

## What we feed in first

Skill 1 always starts by asking for the business logic, and it never guesses it.
In the B001 test run the logic was: **monthly sales and returns, by product category and by city**.
The measures are gross sales, refunds, net sales and return count. Sales are counted by order month and refunds by return month.
This one input decides which tables and columns we keep, and what the Gold tables will be.

## Where the data starts

Raw data is already in Snowflake as 6 **Bronze tables** with 1,000 rows in batch B001.
Every column is plain text, so nothing has been checked yet. Skill 1 is the first look at this data.

## What Skill 1 does

Skill 1 measures the data and the person decides. It only reads and never changes Bronze.

- **Safety first.** If a profile already exists, the skill stops and asks. It never overwrites one on its own.
- **Inventory.** For each table it records rows, batches and the latest batch, and marks whether the table can be read.
- **Real data type.** A column counts as a number or a date only if at least 95% of its values fit. Values that don't fit are counted as invalid, so bad data is visible before any design starts.
- **Personal data.** PII columns are flagged before min and max are calculated, and their values are never shown.
- **Human stop.** The skill recommends which tables are in scope, with a reason and a confidence level. Nothing is saved until a person says yes or no for each table.

## Result (B001 test run)

All 6 tables were profiled, and the person approved the scope table by table. The report was saved and approved.
**Next:** Skill 2 uses this profile to design Silver and Gold.

*Sample test data only.*

---

# Skill 2: Design Silver and Gold

![Skill 2 flow: profile and business logic to 5 design tables](img/skill-2-flow.png)

## What we feed in

Skill 2 reads the approved profile from Skill 1: the table inventory (6 tables, in scope yes or no) and the column profile (32 columns with type and PII flag).
It also uses the business goal from Skill 1, which decides what Gold must answer.

## What Skill 2 does

Skill 2 only designs. It creates no objects in Snowflake. The design is written into 5 design tables.

- **Safety first.** If design tables already exist, the skill stops and asks.
- **Silver tables.** One Silver table per in-scope table, with a business key and a load mode: incremental merge, or full reload with a reason.
- **Silver columns.** The type comes from the profile. A PII column is marked for masking.
- **Quality rules.** Every column gets at least one rule. A bad row goes to quarantine, or the value is cleaned (for example trimmed).
- **Gold design.** Only from the business goal: which Gold tables, their grain and the refresh lag.
- **Roles.** One role per job with exact privileges. Never ACCOUNTADMIN.
- **Consistency check.** Every key, rule and Gold measure is traced back. Gaps are reported, not hidden.
- **Human stop.** A person approves keys, rules, Gold and roles. Nothing is created here.

## Result (B001 test run)

5 design tables were saved and approved: Silver table design (6 tables), Silver column design (types and PII flags), 73 quality rules, Gold table design (2 tables, lag 1 hour) and role design (4 roles).
**Next:** Skill 3 builds the empty Silver tables, roles and masking from this design.

---

# Skill 3: Build empty tables and security

![Skill 3 flow: approved design to empty Silver tables, roles and masking](img/skill-3-flow.png)

## What we feed in

The 5 approved design tables from Skill 2: Silver tables, Silver columns, quality rules, Gold design and role design.

## What Skill 3 does

Skill 3 turns the approved design into real Snowflake objects. It runs DDL only and loads no data.

- **Safety check.** If a table, role or masking policy from the design already exists, the skill stops and asks. It never drops or overwrites anything.
- **Plan.** It lists every statement before running anything. A person approves the plan.
- **Build.** It creates the 6 Silver tables, one quarantine table for each, the 4 roles, the masking policy and the grants. If one statement fails, it stops at once.
- **Safety rule.** No ACCOUNTADMIN and no ALL PRIVILEGES. PII values are never shown.
- **Verify.** It compares what was built with the design: names, types, masking on every PII column, roles and privileges, and that every table is empty.
- **Log.** The result is written to a setup log table. A person checks the report.

## Result (B001 test run)

12 empty tables (6 Silver and 6 quarantine), 4 roles, a masking policy on the PII columns, and a setup log. All tables have 0 rows.
**Next:** Skill 4 builds the load procedures.


---

# Skill 4: Build the load procedures

![Skill 4 flow: design and empty tables to load procedures and logs](img/skill-4-flow.png)

## What we feed in

The approved design (keys and load mode, column mapping, 73 quality rules, loader grants) and the empty Silver and quarantine tables from Skill 3.

## What Skill 4 does

Skill 4 writes the load procedures and runs none of them. No data moves in this skill.

- **Check.** The design is approved, tables exist and are empty, and no load procedure exists yet.
- **Plan.** For each table: which Bronze columns go to which Silver columns, the cast, the rules, and the load mode. A person approves the plan.
- **Build.** One load procedure per Silver table (6 in total), plus two log tables and the loader grants.
- **Inside each procedure.** Safe casts (a bad value becomes NULL, not an error). Every rule for that table is checked. A failed row goes to quarantine with the reason.
- **Parent rule.** If an order is quarantined, its items, payments and returns are quarantined too.
- **Verify.** Every rule is used once, every column is mapped, tables still have 0 rows, and the grants are exact.

## Result (B001 test run)

6 load procedures, a batch log table (rows read, loaded, quarantined) and a rule log table (failed rows per rule). Silver is still empty.
**Next:** Skill 5 loads batch B001.


---

# Skill 5: Load and check one batch

![Skill 5 flow: Bronze batch loaded into Silver with quarantine](img/skill-5-flow.png)

## What we feed in

Bronze batch B001 (6 tables, 1,000 rows), the 6 load procedures from Skill 4, an answer key with the planted defects, and the thresholds: warn at 1% quarantine, stop at 20%.

## What Skill 5 does

Skill 5 loads one batch and proves the result.

- **Pre-check.** The procedures exist and Bronze has rows. If the batch was already loaded, the skill stops and asks.
- **Plan.** Call order, answer key, expected values and thresholds. There is no rollback, and the plan says so. A person approves before any load.
- **Load.** One call per table. Quarantine at 1% or more is a warning. At 20% or more the skill stops loading. Any error stops it at once.
- **Reconcile.** For each table, Bronze rows equal loaded rows plus quarantined rows.
- **Value checks.** Sums, null rates and duplicate keys are compared. Row counts alone are not a pass.
- **Defects and masking.** Every planted defect is marked MATCH or MISMATCH against the answer key. PII is checked as masked for each role.
- **Human stop.** A person checks the PASS, FAIL and WARN report.

## Result (B001 test run)

Silver loaded 973 rows: customers 97, products 28, orders 198, order items 440, payments 183, returns 27. 27 rows (2.70%) went to quarantine.
**Next:** Skill 6 builds the Gold tables.


---

# Skill 6: Build the Gold tables

![Skill 6 flow: loaded Silver and Gold design to Gold Dynamic Tables](img/skill-6-flow.png)

## What we feed in

The 6 loaded Silver tables from Skill 5 and the approved Gold design from Skill 2 (2 tables, refresh lag 1 hour).

## What Skill 6 does

Skill 6 builds Gold from the approved design and never changes Silver.

- **Pre-check.** The Gold design is approved, Silver has rows, the transformer role has the rights it needs, and the Gold tables do not exist yet.
- **Plan.** The full SELECT for each Gold table, its grain, the lag and the expected row count, sales and refunds taken from Silver. A person approves.
- **Build.** Dynamic Tables only, read from Silver only. The first refresh must succeed.
- **Gold rules.** No PII in Gold. If a product is quarantined, its sales are kept and the category shows as UNKNOWN.
- **Verify.** Rows and totals in Gold are compared with Silver. There is no NULL month, category or city.
- **Access test.** The analyst role can read Gold and is denied on Silver.
- **Human stop.** A person checks the PASS or FAIL report.

## Result (B001 test run)

2 Gold Dynamic Tables with a 1 hour lag: monthly sales by category (30 rows) and monthly sales by city (36 rows).
Totals: gross sales 441,950, refunds 15,845, net sales 426,105.
**Next:** Skill 7 audits access and tracks cost.


---

# Skill 7: Audit access and track cost

![Skill 7 flow: roles, logs and Gold to audit, cost and health views](img/skill-7-flow.png)

## What we feed in

The role design from Skill 2, the load logs from Skill 5, the 2 Gold tables from Skill 6, and a credit limit per run (5.0 in this test).

## What Skill 7 does

Skill 7 has two jobs: audit access, and track cost and health. It only reads Skills 1 to 6 and writes only to the monitoring schema.

- **Pre-check.** The logs and Gold exist, usage data can be read, and the alert right is available. Usage data can lag about 3 hours.
- **Plan.** The audit checks, the monitor objects, the credit limit and what is skipped. A person approves before anything is created.
- **Access audit.** Each role is tested: the analyst reads Gold only, the loader runs the procedures, and only the PII reader sees PII.
- **Cost and health.** Views for cost per skill, cost per 1,000 rows, and health per batch against the limit. Credit figures are estimates.
- **Alerts.** Two alerts: quarantine too high, and credits over the limit. They are created SUSPENDED and are never switched on without a person's OK.
- **Verify.** No FAIL in the audit, and phase credits do not exceed the metered credits.
- **Human stop.** A person checks the audit and cost report.

## Result (B001 test run)

Audit result: 30 PASS, 1 FINDING, 0 FAIL. Cost for B001: 0.81 credits of the 5.0 limit. 2 alerts created, both SUSPENDED.

