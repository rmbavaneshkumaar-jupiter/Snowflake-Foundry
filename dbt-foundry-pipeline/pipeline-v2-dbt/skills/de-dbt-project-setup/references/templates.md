# Templates for de-dbt-project-setup

Placeholders are in angle brackets, for example `<SILVER_TABLE>`. Fill them only from the design tables and the config file. Lower-case `<silver_table>` is the model name; UPPER `<SILVER_TABLE>` is the Snowflake name. Lines marked "repeat" are written once per column or per rule.

These shapes were proven on 2026-11-24 in a trial account: 6 Silver tables, 6 quarantine tables and 2 Gold tables built with dbt gave the same rows and totals as the Version 1 procedures.

---

## 1. config/foundry_config.yml (write only if missing)

```yaml
database: <DATABASE>
warehouse: <WAREHOUSE>
role: <PIPELINE_ROLE>
schemas:
  bronze: <BRONZE_SCHEMA>
  silver: <SILVER_SCHEMA>
  gold: <GOLD_SCHEMA>
  monitoring: <MONITORING_SCHEMA>
quarantine_warn_pct: <WARN_PCT>
quarantine_stop_pct: <STOP_PCT>
credit_limit: <CREDIT_LIMIT>
gold_mode: <dynamic_table | table>
gold_target_lag: <LAG>          # used only when gold_mode is dynamic_table
load_mode: <incremental_merge | full_reload>
```

## 2. dbt_project.yml

No var() and no curly braces anywhere in this file, not even in comments.

```yaml
name: <project_name>
version: "1.0.0"
config-version: 2
profile: <project_name>

model-paths: ["models"]
macro-paths: ["macros"]
test-paths: ["tests"]

models:
  <project_name>:
    silver:
      +materialized: table
      +schema: <SILVER_SCHEMA>     # literal, must equal config schemas.silver
    gold:
      +schema: <GOLD_SCHEMA>       # literal, must equal config schemas.gold

vars:                              # copy of the config; keep identical by hand
  schemas:
    bronze: <BRONZE_SCHEMA>
    silver: <SILVER_SCHEMA>
    gold: <GOLD_SCHEMA>
    monitoring: <MONITORING_SCHEMA>
  quarantine_warn_pct: <WARN_PCT>
  quarantine_stop_pct: <STOP_PCT>
  credit_limit: <CREDIT_LIMIT>
  gold_mode: <GOLD_MODE>
  gold_target_lag: <LAG>
  load_mode: <LOAD_MODE>
```

## 3. profiles.yml

```yaml
<project_name>:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: not_needed      # dummy, Snowflake ignores it
      user: not_needed         # dummy, Snowflake ignores it
      role: <PIPELINE_ROLE>
      database: <DATABASE>
      warehouse: <WAREHOUSE>
      schema: <SILVER_SCHEMA>
      threads: 4
```

## 4. macros/generate_schema_name.sql

Without this, dbt names the schema `<SILVER_SCHEMA>_<SILVER_SCHEMA>`.

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

## 5. models/bronze/sources.yml

```yaml
version: 2
sources:
  - name: bronze
    database: "{{ target.database }}"
    schema: "{{ var('schemas')['bronze'] }}"
    tables:
      - name: <BRONZE_TABLE>                 # repeat per Bronze table
        columns:
          - name: <BUSINESS_KEY_COLUMN>
            tests:
              - not_null:
                  config:
                    severity: warn          # Bronze never blocks the run
```

## 6. models/silver/quarantine_<silver_table>.sql

```sql
-- quarantine_<silver_table>: Bronze rows that fail at least one QUARANTINE rule.
-- Rules: <design schema>.<DQ rules table>, silver table <SILVER_TABLE>, rule ids <list>.
-- Raw Bronze values are kept. REJECT_REASON lists every failed rule.

with bronze as (
    select * from {{ source('bronze', '<BRONZE_TABLE>') }}
),

-- parent keys, one CTE per parent rule (omit if the table has no parent rule)
parent_<parent>_silver as (
    select distinct <PARENT_KEY> from {{ ref('silver_<parent_table>') }}
),
parent_<parent>_quarantine as (          -- only if the rule separates PARENT_QUARANTINED
    select distinct try_to_number(<PARENT_KEY>) as <PARENT_KEY> from {{ ref('quarantine_<parent_table>') }}
),

cleaned as (
    select
        bronze.*,
        <CLEAN_EXPRESSION> as <COLUMN>_CLEAN,                          -- repeat per CLEAN rule
        count(*) over (partition by _BATCH_ID, <BUSINESS_KEY>) as KEY_COUNT_IN_BATCH,
        (ps.<PARENT_KEY> is not null) as <PARENT>_IN_SILVER,          -- per parent
        (pq.<PARENT_KEY> is not null) as <PARENT>_IN_QUARANTINE       -- per parent, if used
    from bronze
    left join parent_<parent>_silver ps     on try_to_number(bronze.<CHILD_KEY>) = ps.<PARENT_KEY>
    left join parent_<parent>_quarantine pq on try_to_number(bronze.<CHILD_KEY>) = pq.<PARENT_KEY>
),

checked as (
    select
        cleaned.*,
        <FAILED_CONDITION> as F_<COLUMN>_<RULE_TYPE>                  -- repeat per QUARANTINE rule
    from cleaned
),

with_reason as (
    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_<COLUMN>_<RULE_TYPE>, '<COLUMN>-<RULE_TYPE>', null)  -- repeat per QUARANTINE rule
        ), ' | ') as REJECT_REASON
    from checked
)

select
    <BRONZE_COLUMN>,                                                  -- repeat, raw Bronze columns
    REJECT_REASON,
    current_timestamp() as QUARANTINED_AT,
    _LOADED_AT, _SOURCE_FILE, _BATCH_ID, _SOURCE_SYSTEM, _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
```

### Failed-condition patterns (TRUE = rule failed). Use the cleaned value when the column has a CLEAN rule.

| rule_type | failed condition |
|---|---|
| NOT_NULL | `not coalesce(trim(<COL>) <> '', false)` (NULL and blank both fail) |
| TYPE_CAST number | `(<COL> is not null and try_to_number(<COL>) is null)`; for a key column drop the `is not null` part |
| TYPE_CAST date | `(<COL> is not null and try_to_date(<COL>, '<FORMAT>') is null)` |
| ALLOWED_VALUES | `not coalesce(<COL>_CLEAN in (<VALUE_LIST>), false)` |
| FORMAT (pattern) | `not (<COL>_CLEAN is null or regexp_like(<COL>_CLEAN, '<PATTERN>'))` if NULL is allowed |
| RANGE (number) | `(try_to_number(<COL>, 38, <SCALE>) is not null and not (try_to_number(<COL>, 38, <SCALE>) <RANGE_CONDITION>))` |
| UNIQUE_KEY | `(<KEY> is not null and KEY_COUNT_IN_BATCH > 1)`; reason text `<KEY>-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH` |
| parent, missing | `(<CHILD_KEY> is not null and not <PARENT>_IN_SILVER and not <PARENT>_IN_QUARANTINE)`; reason `<CHILD_KEY>-<RULE_TYPE>: PARENT_MISSING` |
| parent, quarantined | `(<CHILD_KEY> is not null and not <PARENT>_IN_SILVER and <PARENT>_IN_QUARANTINE)`; reason `<CHILD_KEY>-<RULE_TYPE>: PARENT_QUARANTINED` |

Use the exact list, pattern, format and condition written in RULE_DETAIL, and the exact text in REJECT_REASON_TEXT, from the rules table (SILVER_DQ_RULES, APPROVED rows only). ALLOWS_NULL = Y means an empty value passes that rule. Parent rules have RULE_TYPE PARENT_EXISTS; PARENT_OUTCOME MISSING_ONLY means only the "parent, missing" row above is used. Never widen or narrow a rule.

## 7. models/silver/silver_<silver_table>.sql

```sql
-- silver_<silver_table>: Bronze rows NOT in quarantine_<silver_table>, CLEAN rules applied, real types.
-- KEEP IN SYNC: every CLEAN expression here equals the one in quarantine_<silver_table>.sql.

with bronze as (
    select * from {{ source('bronze', '<BRONZE_TABLE>') }}
),
quarantined as (
    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER from {{ ref('quarantine_<silver_table>') }}
),
passed as (
    select bronze.*
    from bronze
    left join quarantined q
        on  bronze._BATCH_ID          = q._BATCH_ID
        and bronze._SOURCE_FILE       = q._SOURCE_FILE
        and bronze._SOURCE_ROW_NUMBER = q._SOURCE_ROW_NUMBER
    where q._SOURCE_ROW_NUMBER is null
)
select
    <CAST_EXPRESSION>(<CLEAN_EXPRESSION or BRONZE_COLUMN>) as <SILVER_COLUMN>,   -- repeat per Silver column
    _LOADED_AT, _SOURCE_FILE, _BATCH_ID, _SOURCE_SYSTEM, _SOURCE_ROW_NUMBER
from passed
```

Cast patterns: number `try_to_number(<x>)::number(38, 0)`, decimal `try_to_number(<x>, 38, <SCALE>)::number(38, <SCALE>)`, date `try_to_date(<x>, '<FORMAT>')`, text `<x>::varchar`.

## 8. models/silver/silver_<silver_table>.yml

```yaml
version: 2
models:
  - name: silver_<silver_table>
    description: "<one line from the table design>"
    columns:
      - name: <SILVER_COLUMN>               # repeat per Silver column
        description: "<from the column design>"
        tests:                               # only tests that come from an approved rule
          - not_null                         # from NOT_NULL
          - unique                           # from UNIQUE_KEY
          - accepted_values:                 # from ALLOWED_VALUES
              values: [<VALUE_LIST>]
          - relationships:                   # from a parent rule
              to: ref('silver_<parent_table>')
              field: <PARENT_KEY>
      - name: _BATCH_ID
        tests:
          - not_null
  - name: quarantine_<silver_table>
    columns:
      - name: REJECT_REASON
        tests:
          - not_null:
              config:
                severity: warn
```

Silver tests: severity error (bad data must not pass quietly). Quarantine tests: severity warn.

## 9. Masking post-hook (only when `masking: on` in the config)

A dbt rebuild creates the table again, so a masking policy attached by hand is lost after every build. The post-hook attaches it again right after each build. Put this config at the top of BOTH `silver_<silver_table>.sql` and `quarantine_<silver_table>.sql`, one line per PII column of that table (PII flag in the column design). Quarantine columns are raw text, so they always use the VARCHAR policy.

```sql
{{ config(post_hook = [
    "alter table {{ this }} modify column <PII_COLUMN> set masking policy {{ target.database }}.{{ var('schemas')['monitoring'] }}.PII_<DATA_TYPE>_MASK"
]) }}
```

Then add to the `vars:` block of dbt_project.yml (copy of the config):

```yaml
  masking: on
  pii_reader_role: <PII_READER_ROLE>
```

The policies themselves are created once by de-dbt-schema-setup. This template only attaches them.
