-- Foundry dbt pipeline - GOLD MONTHLY SALES BY CITY
-- (models/gold/gold_monthly_sales_by_city.sql)
--
-- WHAT THIS MODEL DOES
-- One row per month and customer city: gross sales, refunds, net sales
-- and number of returns. Same logic as the old Skill 6 Gold Dynamic Table
-- GOLD.MONTHLY_SALES_BY_CITY (account VI79381, run 2026-11-15).
-- Reads ONLY Silver models (ref). Never Bronze, never quarantine.
-- PII: only CITY is read from customers. Name, email and phone never reach Gold.
--
-- THE BUSINESS RULES (unchanged from the old Gold)
--   1. Sales month  = month of ORDER_DATE.  All order statuses count as sales.
--   2. Line amount  = QUANTITY x UNIT_PRICE.
--   3. Refund month = month of RETURN_DATE.
--   4. City = city of the order's customer. One order = one city, so the
--      refund is NOT split (unlike the category table).
--   5. Customer missing in Silver -> city 'UNKNOWN' (the sales stay, never hidden).
--
-- BEFORE / AFTER example (rule 3, made-up numbers)
--   Order placed 2026-01-28 in Pune for 500.00, returned 2026-02-03, refund 500.00.
--   Before (Silver): one order row (January) and one return row (February).
--   After (this table): 2026-01 Pune gross 500.00, refund 0.00
--                       2026-02 Pune gross 0.00 (if no other sales), refund 500.00
--
-- TABLE TYPE: from var('gold_mode') (see gold_monthly_sales_by_category.sql).
-- NAME: GOLD_MONTHLY_SALES_BY_CITY, so the old GOLD.MONTHLY_SALES_BY_CITY stays.
--
-- EXPECTED for batch B001 (paper check from the CSVs, not yet run):
--   36 rows (6 months x 6 cities), gross 441,950.00, refunds 15,845.00,
--   net 426,105.00, 0 UNKNOWN rows, SUM(RETURN_COUNT) 27 (= 27 Silver returns).

{% if var('gold_mode') == 'dynamic_table' %}
{{ config(
    materialized = 'dynamic_table',
    target_lag = var('gold_target_lag'),
    snowflake_warehouse = target.warehouse
) }}
{% else %}
{{ config(materialized = 'table') }}
{% endif %}

with orders as (

    select
        o.ORDER_ID,
        o.ORDER_DATE,
        coalesce(c.CITY, 'UNKNOWN')  as CITY
    from {{ ref('silver_orders') }} o
    left join {{ ref('silver_customers') }} c
        on o.CUSTOMER_ID = c.CUSTOMER_ID

),

sales as (

    select
        date_trunc('month', o.ORDER_DATE)::date  as SALES_MONTH,
        o.CITY,
        sum(i.QUANTITY * i.UNIT_PRICE)           as GROSS_SALES
    from {{ ref('silver_order_items') }} i
    join orders o
        on i.ORDER_ID = o.ORDER_ID
    group by 1, 2

),

refunds as (

    select
        date_trunc('month', r.RETURN_DATE)::date  as SALES_MONTH,
        o.CITY,
        sum(r.REFUND_AMOUNT)                      as REFUND_AMOUNT,
        count(distinct r.RETURN_ID)               as RETURN_COUNT
    from {{ ref('silver_returns') }} r
    join orders o
        on r.ORDER_ID = o.ORDER_ID
    group by 1, 2

)

-- Full outer join: a month can have refunds in a city with no sales that month.
select
    coalesce(s.SALES_MONTH, f.SALES_MONTH)                                as SALES_MONTH,
    coalesce(s.CITY, f.CITY)                                              as CITY,
    coalesce(s.GROSS_SALES, 0)::number(18, 2)                             as GROSS_SALES,
    coalesce(f.REFUND_AMOUNT, 0)::number(18, 2)                           as REFUND_AMOUNT,
    (coalesce(s.GROSS_SALES, 0) - coalesce(f.REFUND_AMOUNT, 0))::number(18, 2) as NET_SALES,
    coalesce(f.RETURN_COUNT, 0)::number(38, 0)                            as RETURN_COUNT
from sales s
full outer join refunds f
    on  s.SALES_MONTH = f.SALES_MONTH
    and s.CITY        = f.CITY
