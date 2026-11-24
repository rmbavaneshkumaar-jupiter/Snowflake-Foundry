-- Foundry dbt pipeline - SILVER ORDERS (models/silver/silver_orders.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze ORDERS row that is NOT in quarantine_orders,
-- applies the 2 CLEAN rules and gives each column its real type.
-- Batch B001 (paper check, not run yet): 198 rows.
--
-- THE 2 CLEAN RULES (from Skill 2, unchanged)
--   ORDER_STATUS  UPPER(TRIM())
--   STORE_ID      blank -> NULL
--
-- BEFORE / AFTER example (order 1020 in batch B001)
--   Before, Bronze STATUS: ' shipped'
--   After,  Silver ORDER_STATUS: 'SHIPPED'
--   (Order 1100: Bronze STORE_ID '' -> Silver STORE_ID NULL.)
--
-- TYPES AND NAMES
--   ORDER_ID, CUSTOMER_ID, STORE_ID -> NUMBER; ORDER_DATE -> DATE.
--   Bronze STATUS -> Silver ORDER_STATUS (the rules use that name).
--   PROMO_CODE kept as text (no rule for it; it is NULL in every B001 row).
--
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged.
-- MATCH TO QUARANTINE: _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
-- NOT YET HANDLED: full rebuild over all batches (same note as silver_customers.sql).

with bronze as (

    select * from {{ source('bronze', 'ORDERS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_orders') }}

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

-- CLEAN rules + types.
-- KEEP IN SYNC: ORDER_STATUS and STORE_ID expressions must match quarantine_orders.sql.
select
    try_to_number(ORDER_ID)::number(38, 0)                  as ORDER_ID,
    try_to_number(CUSTOMER_ID)::number(38, 0)               as CUSTOMER_ID,
    try_to_number(nullif(trim(STORE_ID), ''))::number(38, 0) as STORE_ID,
    try_to_date(ORDER_DATE, 'YYYY-MM-DD')                   as ORDER_DATE,
    upper(trim(STATUS))::varchar                            as ORDER_STATUS,
    PROMO_CODE::varchar                                     as PROMO_CODE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
