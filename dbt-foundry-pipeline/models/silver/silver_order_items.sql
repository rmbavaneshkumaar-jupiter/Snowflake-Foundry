-- Foundry dbt pipeline - SILVER ORDER_ITEMS (models/silver/silver_order_items.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze ORDER_ITEMS row that is NOT in quarantine_order_items
-- and gives each column its real type. ORDER_ITEMS has no CLEAN rule.
-- Batch B001 (paper check, not run yet): 440 rows.
--
-- BEFORE / AFTER example (line 1 in batch B001)
--   Before, Bronze (all text):  ORDER_ITEM_ID '1', QUANTITY '3', UNIT_PRICE '575.00'
--   After,  Silver (typed):     ORDER_ITEM_ID 1,   QUANTITY 3,   UNIT_PRICE 575.00
--   Now Gold can multiply QUANTITY x UNIT_PRICE (3 x 575.00 = 1725.00).
--   Line 379 (QUANTITY 'two') never reaches here; it is in quarantine.
--
-- TYPES: ids and QUANTITY -> NUMBER, UNIT_PRICE -> NUMBER(12,2).
--   No LINE_AMOUNT column here (no rule asks for it); Gold computes it.
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged.
-- MATCH TO QUARANTINE: _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
-- NOT YET HANDLED: full rebuild over all batches (same note as silver_customers.sql).

with bronze as (

    select * from {{ source('bronze', 'ORDER_ITEMS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_order_items') }}

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
    try_to_number(ORDER_ITEM_ID)::number(38, 0)       as ORDER_ITEM_ID,
    try_to_number(ORDER_ID)::number(38, 0)            as ORDER_ID,
    try_to_number(PRODUCT_ID)::number(38, 0)          as PRODUCT_ID,
    try_to_number(QUANTITY)::number(38, 0)            as QUANTITY,
    try_to_decimal(UNIT_PRICE, 12, 2)::number(12, 2)  as UNIT_PRICE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
