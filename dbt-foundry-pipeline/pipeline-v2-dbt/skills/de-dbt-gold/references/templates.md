# Templates for de-dbt-gold

Placeholders are in angle brackets. Fill them only from the approved Gold design, the Silver models and the config. Lines marked "repeat" are written once per item.

These shapes were proven on 2026-11-24 in a trial account: 2 Gold dynamic tables built by dbt, PASS=17, and totals equal to the Version 1 Gold tables.

---

## 1. models/gold/gold_<gold_table>.sql

```sql
-- gold_<gold_table>: <grain in one sentence>.
-- From Gold design row <GOLD_TABLE>. Reads Silver models only. No PII column.
-- Table type from var('gold_mode'): dynamic_table uses gold_target_lag; table has no lag.

{% if var('gold_mode') == 'dynamic_table' %}
{{ config(
    materialized = 'dynamic_table',
    target_lag = var('gold_target_lag'),
    snowflake_warehouse = target.warehouse
) }}
{% else %}
{{ config(materialized = 'table') }}
{% endif %}

with facts as (
    select
        f.<FACT_KEY>,
        <DATE_EXPRESSION>                       as <DATE_COLUMN>,
        coalesce(d.<DIMENSION_COLUMN>, 'UNKNOWN') as <DIMENSION_COLUMN>,   -- missing dimension is kept
        <MEASURE_EXPRESSION>                    as <MEASURE_BASE>
    from {{ ref('silver_<fact_table>') }} f
    join {{ ref('silver_<header_table>') }} h            -- only if the design needs a header join
        on f.<HEADER_KEY> = h.<HEADER_KEY>
    left join {{ ref('silver_<dimension_table>') }} d
        on f.<DIMENSION_KEY> = d.<DIMENSION_KEY>
),

measure_<n> as (                                          -- repeat per measure with its own date rule
    select
        date_trunc('month', <DATE_COLUMN>)::date as <MONTH_COLUMN>,
        <DIMENSION_COLUMN>,
        sum(<MEASURE_BASE>)                      as <MEASURE_NAME>
    from facts
    group by 1, 2
)

-- full outer join: a month can have one measure and not another
select
    coalesce(m1.<MONTH_COLUMN>, m2.<MONTH_COLUMN>)         as <MONTH_COLUMN>,
    coalesce(m1.<DIMENSION_COLUMN>, m2.<DIMENSION_COLUMN>) as <DIMENSION_COLUMN>,
    coalesce(m1.<MEASURE_1>, 0)::number(18, 2)             as <MEASURE_1>,
    coalesce(m2.<MEASURE_2>, 0)::number(18, 2)             as <MEASURE_2>,
    (coalesce(m1.<MEASURE_1>, 0) - coalesce(m2.<MEASURE_2>, 0))::number(18, 2) as <DERIVED_MEASURE>  -- only if designed
from measure_1 m1
full outer join measure_2 m2
    on  m1.<MONTH_COLUMN>     = m2.<MONTH_COLUMN>
    and m1.<DIMENSION_COLUMN> = m2.<DIMENSION_COLUMN>
```

### Split pattern (only when the design says one amount is shared over several Gold rows)

```sql
share as (
    select
        date_trunc('month', a.<AMOUNT_DATE>)::date                           as <MONTH_COLUMN>,
        l.<DIMENSION_COLUMN>,
        a.<AMOUNT_ID>,
        a.<AMOUNT> * l.<MEASURE_BASE> / nullif(t.<PARENT_TOTAL>, 0)          as <AMOUNT>_SHARE
    from {{ ref('silver_<amount_table>') }} a
    join facts l       on a.<PARENT_KEY> = l.<PARENT_KEY>
    join parent_totals t on a.<PARENT_KEY> = t.<PARENT_KEY>
)
-- then: round(sum(<AMOUNT>_SHARE), 2), count(distinct <AMOUNT_ID>)
```

Rounding per Gold row can make the Gold total differ from Silver by up to 0.01 per row. The totals test allows exactly that and nothing more.

## 2. models/gold/gold_models.yml

```yaml
version: 2
models:
  - name: gold_<gold_table>                 # repeat per Gold table
    description: "<grain in one sentence>"
    columns:
      - name: <MONTH_COLUMN>
        tests: [not_null]
      - name: <DIMENSION_COLUMN>
        tests:
          - not_null
          - accepted_values:                # only if the design lists the allowed values
              values: [<VALUE_LIST>, 'UNKNOWN']
              config:
                severity: warn              # UNKNOWN must be looked at, not hidden
      - name: <MEASURE>                     # repeat per measure
        tests: [not_null]
```

Optional grants, only when `gold_reader_role` is in the config. dbt applies them again after every build:

```sql
{{ config(grants = {'select': [var('gold_reader_role')]}) }}
```

(`gold_reader_role` must then also be copied into the `vars:` block of dbt_project.yml.)

## 3. tests/assert_gold_matches_silver.sql

A singular test: every returned row is a failure. 0 rows = PASS.

```sql
with silver as (
    select
        (select sum(<MEASURE_BASE_EXPRESSION>) from {{ ref('silver_<fact_table>') }})   as <MEASURE_1>,
        (select sum(<AMOUNT>)                  from {{ ref('silver_<amount_table>') }}) as <MEASURE_2>
),
gold_<n> as (                               -- repeat per Gold table
    select
        sum(<MEASURE_1>) as <MEASURE_1>,
        sum(<MEASURE_2>) as <MEASURE_2>,
        count(*)         as ROW_COUNT,
        count(distinct <MONTH_COLUMN>, <DIMENSION_COLUMN>) as KEY_COUNT
    from {{ ref('gold_<gold_table>') }}
),
checks as (
    select '<gold_table> <MEASURE_1> = Silver' as CHECK_NAME, g.<MEASURE_1> as GOLD_VALUE, s.<MEASURE_1> as EXPECTED_VALUE,
           g.<MEASURE_1> = s.<MEASURE_1> as PASSED
    from gold_<n> g, silver s
    union all
    select '<gold_table> <MEASURE_2> = Silver', g.<MEASURE_2>, s.<MEASURE_2>,
           abs(g.<MEASURE_2> - s.<MEASURE_2>) <= 0.01 * g.ROW_COUNT          -- 0 tolerance if not split
    from gold_<n> g, silver s
    union all
    select '<gold_table> one row per grain', g.ROW_COUNT, g.KEY_COUNT,
           g.ROW_COUNT = g.KEY_COUNT
    from gold_<n> g
)
select CHECK_NAME, GOLD_VALUE, EXPECTED_VALUE
from checks
where not coalesce(PASSED, false)
```
