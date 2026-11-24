-- Foundry dbt pipeline - SILVER PRODUCTS (models/silver/silver_products.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze PRODUCTS row that is NOT in quarantine_products,
-- applies the 2 CLEAN rules and gives each column its real type.
-- Batch B001 (paper check, not run yet): 28 rows.
--
-- THE 2 CLEAN RULES (from Skill 2, unchanged)
--   CATEGORY      INITCAP(TRIM())
--   PRODUCT_NAME  TRIM()
--
-- BEFORE / AFTER example (product 7 in batch B001)
--   Before, Bronze CATEGORY: 'books '
--   After,  Silver CATEGORY: 'Books'
--   So in Gold its order lines count under Books, not as a separate 'books ' row.
--
-- TYPES AND NAMES
--   PRODUCT_ID -> NUMBER. Bronze UNIT_PRICE -> Silver LIST_PRICE NUMBER(12,2)
--   (the rules name this column LIST_PRICE). Other columns stay text.
--   Every row here already passed the TYPE_CAST rules, so the casts cannot fail.
--
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged.
-- MATCH TO QUARANTINE: _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
-- NOT YET HANDLED: full rebuild over all batches (same note as silver_customers.sql).

with bronze as (

    select * from {{ source('bronze', 'PRODUCTS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_products') }}

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
-- KEEP IN SYNC: CATEGORY and PRODUCT_NAME expressions must match quarantine_products.sql.
select
    try_to_number(PRODUCT_ID)::number(38, 0)          as PRODUCT_ID,
    trim(PRODUCT_NAME)::varchar                       as PRODUCT_NAME,
    initcap(trim(CATEGORY))::varchar                  as CATEGORY,
    try_to_decimal(UNIT_PRICE, 12, 2)::number(12, 2)  as LIST_PRICE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
