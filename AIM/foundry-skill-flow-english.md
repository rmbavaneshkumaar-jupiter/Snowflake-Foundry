# Foundry DE Plugin: Skill 1 to Skill 7 Flow

> **Never commit passwords, keys, tokens, customer data.**

Account PR00272, role SYSADMIN, database DE_TEST (BRONZE, SILVER, GOLD, MONITORING), warehouse DE_TEST_WH.
Every skill runs in Snowflake CoCo. Every skill has a STOP gate for human approval.
No ACCOUNTADMIN and no ALL PRIVILEGES are used.

The box below is the **DE Plugin scope** (right side).

```text
 ______________________________________________________________________________
 BRONZE LAYER  (start: 6 VARCHAR tables, batch B001)                          |
    |                                                                         |
    |--> Step 1: Read Bronze tables (read only)                               |
    |--> Step 2: Profile every column                                         |
    |--> Step 3: Find nulls, duplicates, bad dates, bad emails                |
    |--> Step 4: Match the planted defects                                    |
    v                                                                         |
 SKILL 1  de-deep-profile                                                     |
 (Output: profile report in chat. No table created.)                          |
    |                                                                         |
    |--> Step 1: Get input from business (human STOP)                         |
    |--> Step 2: Design Silver tables and columns                             |
    |--> Step 3: Write data quality (DQ) rules                                |
    |--> Step 4: Design Gold tables and roles                                 |
    |--> Step 5: Human approves the design (STOP)                             |
    v                                                                         |
 SKILL 2  de-deep-schema-design                                               |
 (Output in MONITORING: SILVER_TABLE_DESIGN 6, SILVER_COLUMN_DESIGN 32,       |
  SILVER_DQ_RULES 71, GOLD_TABLE_DESIGN 2, ROLE_DESIGN 8. STATUS = APPROVED)  |
    |                                                                         |
    |--> Step 1: Read the approved design                                     |
    |--> Step 2: Create Silver tables                                         |
    |--> Step 3: Create quarantine tables                                     |
    |--> Step 4: Add masking on PII columns                                   |
    |--> Step 5: Give grants to roles                                         |
    v                                                                         |
 SKILL 3  de-deep-schema-setup                                                |
 (Output: 6 Silver + 6 quarantine tables (empty), masking policy              D
  PII_VARCHAR_MASK on 7 columns, 49 grants)                                   E
    |                                                                          
    |--> Step 1: Read tables and DQ rules                                     P
    |--> Step 2: Write one load procedure per table                           l
    |--> Step 3: PRODUCTS = FULL_RELOAD, others = MERGE                       u
    |--> Step 4: Create load log tables                                       g
    |--> Step 5: Give grants (procedures are NOT called)                      i
    v                                                                         n
 SKILL 4  de-deep-transform-setup                                              
 (Output: 6 procedures SILVER.LOAD_<TABLE>(P_BATCH_ID), LOAD_BATCH_LOG,       s
  LOAD_DQ_LOG, 77 grants)                                                     c
    |                                                                         o
    |--> Step 1: Load batch B001 as DE_LOADER                                 p
    |--> Step 2: Good rows go to Silver                                       e
    |--> Step 3: Bad rows go to quarantine                                    |
    |--> Step 4: Check limits: WARN 1%, STOP 20%                              |
    |--> Step 5: Value checks, masking test, answer key                       |
    v                                                                         |
 SKILL 5  de-deep-load-validate                                               |
 (Output, loaded/quarantined: CUSTOMERS 28/2, PRODUCTS 9/1, ORDERS 59/1,      |
  ITEMS 118/2, PAYMENTS 59/1, RETURNS 5/1)                                    |
    |                                                                         |
    |--> Step 1: Read Gold design                                             |
    |--> Step 2: Build 2 Gold Dynamic Tables as DE_TRANSFORMER                |
    |--> Step 3: Verify Gold numbers against Silver                           |
    |--> Step 4: Give SELECT to DE_ANALYST                                    |
    v                                                                         |
 SKILL 6  de-deep-transform                                                   |
 (Output: MONTHLY_SALES_RETURNS_CATEGORY, MONTHLY_SALES_RETURNS_CITY,         |
  12 rows each. Sales 143,850, refunds 750, net 143,100)                      |
    |                                                                         |
    |--> Step 1: Audit who can access what (16 checks)                        |
    |--> Step 2: Log each phase                                               |
    |--> Step 3: Set credit limit 5.0                                         |
    |--> Step 4: Create cost and health views                                 |
    v                                                                         |
 SKILL 7  de-deep-share-monitor                                               |
 (Output: ACCESS_AUDIT_RESULT 14 PASS / 2 FAIL accepted, PIPELINE_PHASE_LOG,  |
  PIPELINE_CREDIT_LIMIT, VW_PIPELINE_COST, VW_PIPELINE_COST_PER_ROW,          |
  VW_PIPELINE_HEALTH. B001 cost 0.1696 credits)                               |
 ______________________________________________________________________________
```

## Notes on the results

- Skill 2 rule: if an order is quarantined, its items are marked PARENT_QUARANTINED.
- Skill 4 rule IDs look like `<TABLE>-<COLUMN>-<RULE_TYPE>-<n>`. A rejected row gets REJECT_REASON "RULE_ID: reason".
- Skill 5 limits WARN 1% / STOP 20% were our override. The skill default is STOP 5%.
- Skill 6 Gold tables refresh with lag 1 day. UNKNOWN category = 33,000. UNKNOWN city = 10,000 (temporary).
- Skill 7 two FAIL checks are accepted: DE_TRANSFORMER owns the Gold tables, and a ROLE_DESIGN gap.
- Skill 7 cost 0.1696 warehouse credits is an estimate (0.610 per 1,000 rows). It does not include CoCo AI credits.
- Alerts were skipped, because EXECUTE ALERT is not granted.

## Honest status (still pending)

- Orchestrator de-foundry-run is written, but not run live yet.
- Batch B002 is loaded in Bronze, but Skills 5 to 7 are not run on it yet.
- No hooks yet.
- CoCo returned HTTP 429 today, so there is no live run in this demo.
- Skill 1 output is in chat only. It is not saved as a table.
- UNKNOWN city 10,000 must be checked again after the B002 run.
