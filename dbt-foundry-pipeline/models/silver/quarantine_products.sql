-- Foundry dbt pipeline - QUARANTINE PRODUCTS (models/silver/quarantine_products.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze PRODUCTS row and checks it against the 8 QUARANTINE rules.
-- A row that fails at least one rule lands here with its ORIGINAL raw values
-- and a REJECT_REASON that lists EVERY rule it failed.
-- silver_products.sql takes all Bronze rows that are NOT in this table.
-- Batch B001 (paper check): 30 Bronze = 28 Silver + 2 quarantine.
--
-- WHERE THE RULES COME FROM
-- The 10 PRODUCTS rules made by Skill 2 in the old run (account VI79381,
-- DE_TEST.MONITORING.SILVER_DQ_RULES): 8 QUARANTINE (here), 2 CLEAN
-- (CATEGORY INITCAP(TRIM()), PRODUCT_NAME TRIM()). No rule added or changed.
--
-- COLUMN NAME NOTE
-- The rules call the price LIST_PRICE (that is the Silver name), but the
-- Bronze column is UNIT_PRICE. The rule text "TRY_TO_DECIMAL(UNIT_PRICE,12,2)"
-- therefore reads Bronze UNIT_PRICE. Silver renames it to LIST_PRICE.
--
-- BEFORE / AFTER example (product 7 in batch B001)
--   Before (Bronze CATEGORY): 'books '   (small b, space behind)
--   CLEAN rule INITCAP(TRIM()) -> 'Books'
--   ALLOWED_VALUES check on 'Books' -> passes, product 7 goes to Silver.
--   Product 30 has UNIT_PRICE 'abc' -> TRY_TO_DECIMAL gives NULL ->
--   REJECT_REASON 'LIST_PRICE-TYPE_CAST', product 30 stays here.
--
-- NAMES: no database or schema written here (source() fills them in).

with bronze as (

    select * from {{ source('bronze', 'PRODUCTS') }}

),

-- Step 1: cleaned values used ONLY for checking.
-- KEEP IN SYNC: these CLEAN expressions must be the same as in silver_products.sql.
cleaned as (

    select
        bronze.*,
        initcap(trim(CATEGORY))                 as CATEGORY_CLEAN,      -- CATEGORY FORMAT (CLEAN)
        trim(PRODUCT_NAME)                      as PRODUCT_NAME_CLEAN,  -- PRODUCT_NAME FORMAT (CLEAN)
        try_to_decimal(UNIT_PRICE, 12, 2)       as LIST_PRICE_NUM,
        -- UNIQUE_KEY: how many rows share this PRODUCT_ID in the same batch
        count(*) over (partition by _BATCH_ID, PRODUCT_ID) as KEY_COUNT_IN_BATCH
    from bronze

),

-- Step 2: one TRUE/FALSE flag per QUARANTINE rule. TRUE = rule failed.
checked as (

    select
        cleaned.*,

        -- CATEGORY NOT_NULL (checked on the cleaned value)
        (CATEGORY_CLEAN is null)                                          as F_CATEGORY_NOT_NULL,

        -- CATEGORY ALLOWED_VALUES (cleaned value must be one of the 5 categories)
        not coalesce(CATEGORY_CLEAN in ('Home', 'Toys', 'Electronics', 'Books', 'Sports'), false)
                                                                          as F_CATEGORY_ALLOWED_VALUES,

        -- LIST_PRICE TYPE_CAST: TRY_TO_DECIMAL(UNIT_PRICE,12,2) IS NOT NULL
        (LIST_PRICE_NUM is null)                                          as F_LIST_PRICE_TYPE_CAST,

        -- LIST_PRICE RANGE: >= 0 (only checked when the number is readable)
        (LIST_PRICE_NUM is not null and LIST_PRICE_NUM < 0)               as F_LIST_PRICE_RANGE,

        -- PRODUCT_ID NOT_NULL
        (PRODUCT_ID is null)                                              as F_PRODUCT_ID_NOT_NULL,

        -- PRODUCT_ID TYPE_CAST: TRY_TO_NUMBER(PRODUCT_ID) IS NOT NULL
        (try_to_number(PRODUCT_ID) is null)                               as F_PRODUCT_ID_TYPE_CAST,

        -- PRODUCT_ID UNIQUE_KEY: duplicates in a batch -> ALL copies fail
        (PRODUCT_ID is not null and KEY_COUNT_IN_BATCH > 1)               as F_PRODUCT_ID_UNIQUE_KEY,

        -- PRODUCT_NAME NOT_NULL: TRIM(PRODUCT_NAME) <> ''  (NULL also fails)
        not coalesce(PRODUCT_NAME_CLEAN <> '', false)                     as F_PRODUCT_NAME_NOT_NULL

    from cleaned

),

-- Step 3: REJECT_REASON = every failed rule name, joined with ' | '.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_CATEGORY_NOT_NULL,       'CATEGORY-NOT_NULL', null),
            iff(F_CATEGORY_ALLOWED_VALUES, 'CATEGORY-ALLOWED_VALUES', null),
            iff(F_LIST_PRICE_TYPE_CAST,    'LIST_PRICE-TYPE_CAST', null),
            iff(F_LIST_PRICE_RANGE,        'LIST_PRICE-RANGE', null),
            iff(F_PRODUCT_ID_NOT_NULL,     'PRODUCT_ID-NOT_NULL', null),
            iff(F_PRODUCT_ID_TYPE_CAST,    'PRODUCT_ID-TYPE_CAST', null),
            iff(F_PRODUCT_ID_UNIQUE_KEY,   'PRODUCT_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_PRODUCT_NAME_NOT_NULL,   'PRODUCT_NAME-NOT_NULL', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    PRODUCT_ID,
    PRODUCT_NAME,
    CATEGORY,
    UNIT_PRICE,
    REJECT_REASON,
    current_timestamp()   as QUARANTINED_AT,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
