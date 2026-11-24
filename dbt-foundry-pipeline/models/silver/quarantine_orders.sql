-- Foundry dbt pipeline - QUARANTINE ORDERS (models/silver/quarantine_orders.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze ORDERS row and checks it against the 10 QUARANTINE rules.
-- A row that fails at least one rule lands here with its ORIGINAL raw values
-- and a REJECT_REASON that lists EVERY rule it failed.
-- silver_orders.sql takes all Bronze rows that are NOT in this table.
-- Batch B001 (paper check): 200 Bronze = 198 Silver + 2 quarantine.
--
-- WHERE THE RULES COME FROM
-- The 12 ORDERS rules made by Skill 2 in the old run (account VI79381,
-- DE_TEST.MONITORING.SILVER_DQ_RULES): 10 QUARANTINE (here), 2 CLEAN
-- (ORDER_STATUS UPPER(TRIM()), STORE_ID blank -> NULL). No rule added or changed.
--
-- PARENT CHECK (CUSTOMER_ID must exist in Silver CUSTOMERS)
-- ref('silver_customers') tells dbt to build CUSTOMERS first. No loop:
-- silver_customers does not read anything from ORDERS.
--
-- COLUMN NAME NOTE
-- The rules call the status ORDER_STATUS (Silver name); Bronze calls it STATUS.
--
-- BEFORE / AFTER example (batch B001)
--   Order 1020: Bronze STATUS ' shipped' -> CLEAN UPPER(TRIM()) -> 'SHIPPED'
--               -> allowed -> goes to Silver.
--   Order 1100: Bronze STORE_ID '' (empty text) -> CLEAN blank -> NULL ->
--               TYPE_CAST rule checks only when not null -> passes, goes to Silver.
--   Order 1050: Bronze STATUS 'WRONG' -> not allowed ->
--               REJECT_REASON 'ORDER_STATUS-ALLOWED_VALUES', stays here.
--
-- NAMES: no database or schema written here (source() and ref() fill them in).

with bronze as (

    select * from {{ source('bronze', 'ORDERS') }}

),

-- Parent keys: customers that made it into Silver
parent_customers as (

    select distinct CUSTOMER_ID from {{ ref('silver_customers') }}

),

-- Step 1: cleaned values used ONLY for checking.
-- KEEP IN SYNC: these CLEAN expressions must be the same as in silver_orders.sql.
cleaned as (

    select
        bronze.*,
        upper(trim(STATUS))            as ORDER_STATUS_CLEAN,   -- ORDER_STATUS FORMAT (CLEAN)
        nullif(trim(STORE_ID), '')     as STORE_ID_CLEAN,       -- STORE_ID FORMAT (CLEAN): blank -> NULL
        -- UNIQUE_KEY: how many rows share this ORDER_ID in the same batch
        count(*) over (partition by _BATCH_ID, ORDER_ID) as KEY_COUNT_IN_BATCH,
        (pc.CUSTOMER_ID is not null)   as CUSTOMER_IN_SILVER
    from bronze
    left join parent_customers pc
        on try_to_number(bronze.CUSTOMER_ID) = pc.CUSTOMER_ID

),

-- Step 2: one TRUE/FALSE flag per QUARANTINE rule. TRUE = rule failed.
checked as (

    select
        cleaned.*,

        -- CUSTOMER_ID NOT_NULL
        (CUSTOMER_ID is null)                                             as F_CUSTOMER_ID_NOT_NULL,

        -- CUSTOMER_ID TYPE_CAST: TRY_TO_NUMBER(CUSTOMER_ID) IS NOT NULL
        (try_to_number(CUSTOMER_ID) is null)                              as F_CUSTOMER_ID_TYPE_CAST,

        -- CUSTOMER_ID RANGE: must exist in Silver CUSTOMERS, else PARENT_MISSING
        -- (only checked when a value is given; NULL is caught by NOT_NULL)
        (CUSTOMER_ID is not null and not CUSTOMER_IN_SILVER)              as F_CUSTOMER_ID_PARENT_MISSING,

        -- ORDER_DATE NOT_NULL
        (ORDER_DATE is null)                                              as F_ORDER_DATE_NOT_NULL,

        -- ORDER_DATE TYPE_CAST: TRY_TO_DATE(ORDER_DATE,'YYYY-MM-DD') IS NOT NULL
        (ORDER_DATE is not null and try_to_date(ORDER_DATE, 'YYYY-MM-DD') is null)
                                                                          as F_ORDER_DATE_TYPE_CAST,

        -- ORDER_ID NOT_NULL
        (ORDER_ID is null)                                                as F_ORDER_ID_NOT_NULL,

        -- ORDER_ID TYPE_CAST: TRY_TO_NUMBER(ORDER_ID) IS NOT NULL
        (try_to_number(ORDER_ID) is null)                                 as F_ORDER_ID_TYPE_CAST,

        -- ORDER_ID UNIQUE_KEY: duplicates in a batch -> ALL copies fail
        (ORDER_ID is not null and KEY_COUNT_IN_BATCH > 1)                 as F_ORDER_ID_UNIQUE_KEY,

        -- ORDER_STATUS ALLOWED_VALUES (cleaned value)
        not coalesce(ORDER_STATUS_CLEAN in ('PENDING', 'SHIPPED', 'COMPLETED'), false)
                                                                          as F_ORDER_STATUS_ALLOWED_VALUES,

        -- STORE_ID TYPE_CAST: TRY_TO_NUMBER(STORE_ID) IS NOT NULL when not null (cleaned value)
        (STORE_ID_CLEAN is not null and try_to_number(STORE_ID_CLEAN) is null)
                                                                          as F_STORE_ID_TYPE_CAST

    from cleaned

),

-- Step 3: REJECT_REASON = every failed rule name, joined with ' | '.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_CUSTOMER_ID_NOT_NULL,        'CUSTOMER_ID-NOT_NULL', null),
            iff(F_CUSTOMER_ID_TYPE_CAST,       'CUSTOMER_ID-TYPE_CAST', null),
            iff(F_CUSTOMER_ID_PARENT_MISSING,  'CUSTOMER_ID-RANGE: PARENT_MISSING', null),
            iff(F_ORDER_DATE_NOT_NULL,         'ORDER_DATE-NOT_NULL', null),
            iff(F_ORDER_DATE_TYPE_CAST,        'ORDER_DATE-TYPE_CAST', null),
            iff(F_ORDER_ID_NOT_NULL,           'ORDER_ID-NOT_NULL', null),
            iff(F_ORDER_ID_TYPE_CAST,          'ORDER_ID-TYPE_CAST', null),
            iff(F_ORDER_ID_UNIQUE_KEY,         'ORDER_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_ORDER_STATUS_ALLOWED_VALUES, 'ORDER_STATUS-ALLOWED_VALUES', null),
            iff(F_STORE_ID_TYPE_CAST,          'STORE_ID-TYPE_CAST', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    ORDER_ID,
    CUSTOMER_ID,
    STORE_ID,
    ORDER_DATE,
    STATUS,
    PROMO_CODE,
    REJECT_REASON,
    current_timestamp()   as QUARANTINED_AT,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
