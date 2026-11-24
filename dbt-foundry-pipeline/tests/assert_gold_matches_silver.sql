-- Foundry dbt pipeline - Gold vs Silver check (tests/assert_gold_matches_silver.sql)
--
-- WHAT THIS TEST DOES
-- A dbt "singular test": dbt runs this SELECT after the Gold models are built.
-- Every row it returns is a FAILURE. Zero rows = PASS.
-- It checks 2 things for each Gold table:
--   A. Totals: Gold gross sales and refunds = the same totals computed from Silver.
--      (Nothing lost, nothing counted twice in the joins.)
--   B. Grain: only one row per month and category (or city).
--
-- BEFORE / AFTER example (check A)
--   Silver: SUM(QUANTITY x UNIT_PRICE) = 441,950.00, SUM(REFUND_AMOUNT) = 15,845.00
--   Gold OK:     gross 441,950.00, refunds 15,845.00  -> no row returned -> PASS
--   Gold broken: gross 443,675.00 (a line joined twice) -> 1 row returned -> FAIL
--
-- TOLERANCE: the category table rounds each refund share to 2 decimals per row,
-- so its refund total may differ by up to 0.01 per row. B001 paper check: 0.00.
-- severity error: Gold must not be wrong quietly.

with silver as (

    select
        (select sum(QUANTITY * UNIT_PRICE) from {{ ref('silver_order_items') }}) as GROSS_SALES,
        (select sum(REFUND_AMOUNT)         from {{ ref('silver_returns') }})     as REFUND_AMOUNT

),

gold_category as (

    select
        sum(GROSS_SALES)    as GROSS_SALES,
        sum(REFUND_AMOUNT)  as REFUND_AMOUNT,
        count(*)            as ROW_COUNT,
        count(distinct SALES_MONTH, CATEGORY) as KEY_COUNT
    from {{ ref('gold_monthly_sales_by_category') }}

),

gold_city as (

    select
        sum(GROSS_SALES)    as GROSS_SALES,
        sum(REFUND_AMOUNT)  as REFUND_AMOUNT,
        count(*)            as ROW_COUNT,
        count(distinct SALES_MONTH, CITY) as KEY_COUNT
    from {{ ref('gold_monthly_sales_by_city') }}

),

checks as (

    select 'CATEGORY gross sales = Silver' as CHECK_NAME, g.GROSS_SALES as GOLD_VALUE, s.GROSS_SALES as EXPECTED_VALUE,
           g.GROSS_SALES = s.GROSS_SALES as PASSED
    from gold_category g, silver s
    union all
    select 'CATEGORY refunds = Silver (0.01 per row)', g.REFUND_AMOUNT, s.REFUND_AMOUNT,
           abs(g.REFUND_AMOUNT - s.REFUND_AMOUNT) <= 0.01 * g.ROW_COUNT
    from gold_category g, silver s
    union all
    select 'CATEGORY one row per month and category', g.ROW_COUNT, g.KEY_COUNT,
           g.ROW_COUNT = g.KEY_COUNT
    from gold_category g
    union all
    select 'CITY gross sales = Silver', g.GROSS_SALES, s.GROSS_SALES,
           g.GROSS_SALES = s.GROSS_SALES
    from gold_city g, silver s
    union all
    select 'CITY refunds = Silver', g.REFUND_AMOUNT, s.REFUND_AMOUNT,
           g.REFUND_AMOUNT = s.REFUND_AMOUNT
    from gold_city g, silver s
    union all
    select 'CITY one row per month and city', g.ROW_COUNT, g.KEY_COUNT,
           g.ROW_COUNT = g.KEY_COUNT
    from gold_city g

)

select CHECK_NAME, GOLD_VALUE, EXPECTED_VALUE
from checks
where not coalesce(PASSED, false)
