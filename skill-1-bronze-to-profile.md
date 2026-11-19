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

## What we changed and why

| Before (Version 1) | Now (Version 2) | Why it matters |
|---|---|---|
| Read files from a stage, one load only | Reads Bronze tables and tracks every batch | Works for the next batch too, not only the first one |
| Data type taken from the file | Type must fit at least 95% of values | Bad values show up early, before tables are designed |

## Result (B001 test run)

All 6 tables were profiled, and the person approved the scope table by table. The report was saved and approved.
**Next:** Skill 2 uses this profile to design Silver and Gold.

*Sample test data only.*

---

# Skill 2: Design Silver and Gold

![Skill 2 flow: profile and business logic to 5 design tables](img/skill-2-flow.png)

---

# Skill 3: Build empty tables and security

![Skill 3 flow: approved design to empty Silver tables, roles and masking](img/skill-3-flow.png)

---

# Skill 4: Build the load procedures

![Skill 4 flow: design and empty tables to load procedures and logs](img/skill-4-flow.png)

---

# Skill 5: Load and check one batch

![Skill 5 flow: Bronze batch loaded into Silver with quarantine](img/skill-5-flow.png)

---

# Skill 6: Build the Gold tables

![Skill 6 flow: loaded Silver and Gold design to Gold Dynamic Tables](img/skill-6-flow.png)

---

# Skill 7: Audit access and track cost

![Skill 7 flow: roles, logs and Gold to audit, cost and health views](img/skill-7-flow.png)
