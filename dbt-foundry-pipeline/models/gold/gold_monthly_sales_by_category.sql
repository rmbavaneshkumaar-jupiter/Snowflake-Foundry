-- Foundry dbt pipeline - GOLD MONTHLY SALES BY CATEGORY
-- (models/gold/gold_monthly_sales_by_category.sql)
--
-- WHAT THIS MODEL DOES
-- One row per month and product category: gross sales, refunds, net sales
-- and number of returns. Same logic as the old Skill 6 Gold Dynamic Table
-- GOLD.MONTHLY_SALES_BY_CATEGORY (account VI79381, run 2026-11-15).
-- Reads ONLY Silver models (ref). Never Bronze, never quarantine, no PII.
--
-- THE BUSINESS RULES (unchanged from the old Gold)
--   1. Sales month  = month of ORDER_DATE.  All order statuses count as sales.
--   2. Line amount  = QUANTITY x UNIT_PRICE.
--   3. Refund month = month of RETURN_DATE (not the order month).
--   4. A refund is for a whole order, but an order can have lines in two
--      categories. So the refund is split over the order's lines by their
--      share of the order amount, then rounded to 2 decimals per row.
--   5. RETURN_COUNT counts a return once in each category of its order.
--   6. Product missing in Silver -> category 'UNKNOWN' (the sales stay).
--
-- BEFORE / AFTER example (rule 4, made-up numbers to show the split)
--   Order 1 has two lines: Books 300.00 and Toys 100.00 (order total 400.00).
--   Return of 80.00 on that order.
--   Before (one refund row):  80.00 for order 1
--   After (in this table):    Books 80 x 300/400 = 60.00, Toys 80 x 100/400 = 20.00
--   Both categories get RETURN_COUNT 1.
--
-- TABLE TYPE: comes from var('gold_mode') in dbt_project.yml vars.
--   dynamic_table -> Snowflake refreshes it by itself, every gold_target_lag.
--   table         -> refreshed only when dbt runs. NO target lag is set then.
-- var() works here (model file); it does NOT work inside dbt_project.yml.
--
-- NAME: GOLD_MONTHLY_SALES_BY_CATEGORY, so the old Gold table
--   GOLD.MONTHLY_SALES_BY_CATEGORY is never replaced and both can be compared.
--
-- EXPECTED for batch B001 (paper check from the CSVs, not yet run):
--   30 rows (6 months x 5 categories), gross 441,950.00, refunds 15,845.00,
--   net 426,105.00, 0 UNKNOWN rows, SUM(RETURN_COUNT) 56.

{% if var('gold_mode') == 'dynamic_table' %}
{{ config(
    materialized = 'dynamic_table',
    target_lag = var('gold_target_lag'),
    snowflake_warehouse = target.warehouse
) }}
{% else %}
{{ config(materialized = 'table') }}
{% endif %}

with lines as (

    select
        i.ORDER_ID,
        o.ORDER_DATE,
        coalesce(p.CATEGORY, 'UNKNOWN')  as CATEGORY,
        i.QUANTITY * i.UNIT_PRICE        as LINE_AMOUNT
    from {{ ref('silver_order_items') }} i
    join {{ ref('silver_orders') }} o
        on i.ORDER_ID = o.ORDER_ID
    left join {{ ref('silver_products') }} p
        on i.PRODUCT_ID = p.PRODUCT_ID

),

sales as (

    select
        date_trunc('month', ORDER_DATE)::date  as SALES_MONTH,
        CATEGORY,
        sum(LINE_AMOUNT)                       as GROSS_SALES
    from lines
    group by 1, 2

),

order_totals as (

    select ORDER_ID, sum(LINE_AMOUNT) as ORDER_AMOUNT
    from lines
    group by 1

),

refund_shares as (

    select
        date_trunc('month', r.RETURN_DATE)::date                       as SALES_MONTH,
        l.CATEGORY,
        r.RETURN_ID,
        r.REFUND_AMOUNT * l.LINE_AMOUNT / nullif(t.ORDER_AMOUNT, 0)    as REFUND_SHARE
    from {{ ref('silver_returns') }} r
    join lines l
        on r.ORDER_ID = l.ORDER_ID
    join order_totals t
        on r.ORDER_ID = t.ORDER_ID

),

refunds as (

    select
        SALES_MONTH,
        CATEGORY,
        round(sum(REFUND_SHARE), 2)  as REFUND_AMOUNT,
        count(distinct RETURN_ID)    as RETURN_COUNT
    from refund_shares
    group by 1, 2

)

-- Full outer join: a month can have refunds in a category with no sales that month.
select
    coalesce(s.SALES_MONTH, f.SALES_MONTH)                                as SALES_MONTH,
    coalesce(s.CATEGORY, f.CATEGORY)                                      as CATEGORY,
    coalesce(s.GROSS_SALES, 0)::number(18, 2)                             as GROSS_SALES,
    coalesce(f.REFUND_AMOUNT, 0)::number(18, 2)                           as REFUND_AMOUNT,
    (coalesce(s.GROSS_SALES, 0) - coalesce(f.REFUND_AMOUNT, 0))::number(18, 2) as NET_SALES,
    coalesce(f.RETURN_COUNT, 0)::number(38, 0)                            as RETURN_COUNT
from sales s
full outer join refunds f
    on  s.SALES_MONTH = f.SALES_MONTH
    and s.CATEGORY    = f.CATEGORY
