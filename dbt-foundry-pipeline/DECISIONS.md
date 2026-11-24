# Foundry dbt upgrade - Decisions (reference)

Written: 24 Nov 2026. Folder: `D:\Claude\dbt-foundry-pipeline\`
Purpose: one place for all decisions on the dbt upgrade. Show this file to any new assistant before starting work.

---

## 1. Goal

- Demo: tech day on **4 Dec 2026**. Dry run in Chennai on **2 Dec 2026** (Balaji).
- The demo shows our **7 skills with STOP gates**, now producing a **dbt project**.
- Anupama Gangadhar: **Verity** and **PII masking** are downprioritized for the demo. **dbt is the focus** (dbt is also needed for the Everangle project).
- Verity study is closed. Notes: `D:\Claude\verity\Verity_how_it_works_notes.md`.

## 2. Decisions

- **dbt only** for the demo. The old stored-procedure path stays as **Version 1**. No switch between the two.
- The dbt project is **plain files kept in Git**, and runs **inside Snowflake** (Snowflake dbt Projects).
- **Nothing is installed on the laptop.**
- **Pipeline role = `DE_PIPELINE_ROLE`** (meeting, 24 Nov 2026): custom least-privilege role, no SYSADMIN or ACCOUNTADMIN. Created by an admin, not by our skills. Privileges: still to be defined.
- Which skills change:
  - Skills 4 and 5: change a lot.
  - Skill 3: changes a little.
  - Skills 1 and 2: no change.
  - Gold (skill 6) must be under dbt control.
- Gold option in config, `gold_mode`:
  - `dynamic_table` = Snowflake refreshes Gold; uses `gold_target_lag` (now `1 hour`).
  - `table` = refreshed only when dbt runs; **no target lag**.
- Account and database names live only in `config\foundry_config.yml`, as far as possible (see caveats in section 4).
- **Run account** = second trial account **FHETVJI-TK85409**:
  - Git repo FOUNDRY_REPO connected, skills uploaded, B001 loaded in Bronze.
  - No pipeline run yet. Credits left: unknown.
- **First trial account VI79381** has the full old 7-skill run.
  - The 14 CUSTOMERS rules live there: `DE_TEST.MONITORING.SILVER_DQ_RULES`.
- Plan, in order:
  1. Write the dbt files on D drive.
  2. User uploads them to the personal GitHub repo.
  3. Connect the repo to account FHETVJI-TK85409.
  4. Run the dbt project.
  5. Compare Silver CUSTOMERS with the old result (**97 rows in Silver, 3 quarantined**).
  6. Rewrite the skills so they produce the same shape of dbt files.
  7. Move to the company repo and company account when access comes.

## 3. Files done so far

| File | Lines |
|---|---|
| `config\foundry_config.yml` | 29 |
| `dbt_project.yml` | 59 |
| `DECISIONS.md` (this file) | - |

Values in `config\foundry_config.yml` today:
- database `DE_TEST`, warehouse `DE_TEST_WH`
- schemas `BRONZE`, `SILVER`, `GOLD`, `MONITORING`
- `quarantine_warn_pct: 1`, `quarantine_stop_pct: 20`
- `credit_limit: 5.0`
- `gold_mode: dynamic_table`, `gold_target_lag: 1 hour`
- `load_mode: incremental_merge` (or `full_reload`)

What `dbt_project.yml` does:
- Project and profile name: `foundry_pipeline`.
- Silver models and quarantine models: `table`, schema SILVER.
- Gold models: type comes from `gold_mode`; uses `gold_target_lag` and `target.warehouse`.
- `vars:` block = a copy of the config values (no database or warehouse; those come from profiles.yml).

## 4. Known facts and caveats

- dbt **cannot read our config file by itself**. So the values are repeated in the `vars:` block of `dbt_project.yml`. **Keep the two identical by hand.**
- Snowflake dbt Projects **requires `profiles.yml`** in the project root:
  - It holds warehouse, database, schema, role.
  - Account and user can be dummy text. No password. `env_var()` is not supported.
  - So moving to another account means changing **3 places**: `foundry_config.yml`, the `vars:` in `dbt_project.yml`, and `profiles.yml`.
  - Note: the comment at the top of `foundry_config.yml` says "change only this file". Because of profiles.yml this is not fully true. Not changed yet; only noted.
- **UNTESTED:**
  - Choosing `dynamic_table` from a var (`+materialized: "{{ var('gold_mode') }}"`).
  - Schema names may become `SILVER_SILVER` (dbt default behavior). Fix: a `generate_schema_name` macro.
- Correction (Snowflake docs re-checked 24 Nov 2026): `env_var()` IS now supported through a separate `env.yml` file (keys UPPERCASE, prefix `DBT_`). We do not use it yet; profiles.yml keeps plain values.

## 5. Next files, in order

1. `profiles.yml`
2. `macros\generate_schema_name.sql`
3. Bronze sources yml
4. Silver CUSTOMERS model, with tests
   - Needs the 14 rules text. Run in account VI79381:
     `SELECT * FROM DE_TEST.MONITORING.SILVER_DQ_RULES WHERE TABLE_NAME = 'CUSTOMERS';`
5. Quarantine model
6. Gold models

## 6. Working rules (set by the user)

- One small step at a time. Discuss first, then write.
- Do not change existing files without asking.
- Skills must stay **generic**: no source table or column names inside skills.
- Verify every file by reading it back from D drive.
