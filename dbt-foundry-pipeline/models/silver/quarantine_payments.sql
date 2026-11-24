-- Foundry dbt pipeline - QUARANTINE PAYMENTS (models/silver/quarantine_payments.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze PAYMENTS row and checks it against the 11 QUARANTINE rules.
-- A row that fails at least one rule lands here with its ORIGINAL raw values
-- and a REJECT_REASON listing EVERY failed rule.
-- silver_payments.sql takes all Bronze rows that are NOT in this table.
-- Batch B001 (paper check): 190 Bronze = 183 Silver + 7 quarantine.
--
-- WHERE THE RULES COME FROM
-- The 12 PAYMENTS rules made by Skill 2 in the old run (account VI79381,
-- DE_TEST.MONITORING.SILVER_DQ_RULES): 11 QUARANTINE (here), 1 CLEAN
-- (PAYMENT_METHOD UPPER(TRIM())). No rule added or changed.
--
-- COLUMN NAME NOTE
-- The rules name the amount PAYMENT_AMOUNT (Silver name) and their text says
-- AMOUNT. The Bronze column really is AMOUNT, so the checks read AMOUNT and
-- Silver renames it to PAYMENT_AMOUNT.
--
-- PARENT CHECK: ORDER_ID must be in Silver ORDERS, else PARENT_QUARANTINED
-- (order is in quarantine) or PARENT_MISSING (order exists nowhere).
--
-- BEFORE / AFTER example (batch B001)
--   Payment 5063 appears twice (orders 1067 and 1068). UNIQUE_KEY rule ->
--   BOTH copies come here with 'PAYMENT_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH',
--   because we cannot know which copy is the true one.
--   Payment 5042 has PAYMENT_METHOD 'BITCOIN' -> 'PAYMENT_METHOD-ALLOWED_VALUES'.
--
-- NAMES: no database or schema written here (source() and ref() fill them in).

with bronze as (

    select * from {{ source('bronze', 'PAYMENTS') }}

),

silver_order_keys as (
    select distinct ORDER_ID from {{ ref('silver_orders') }}
),
quarantine_order_keys as (
    select distinct try_to_number(ORDER_ID) as ORDER_ID
    from {{ ref('quarantine_orders') }}
    where try_to_number(ORDER_ID) is not null
),

-- Step 1: cleaned / helper values used ONLY for checking.
-- KEEP IN SYNC: the PAYMENT_METHOD CLEAN expression must match silver_payments.sql.
cleaned as (

    select
        bronze.*,
        upper(trim(PAYMENT_METHOD))          as PAYMENT_METHOD_CLEAN,  -- PAYMENT_METHOD FORMAT (CLEAN)
        try_to_decimal(AMOUNT, 12, 2)        as PAYMENT_AMOUNT_NUM,
        count(*) over (partition by _BATCH_ID, PAYMENT_ID) as KEY_COUNT_IN_BATCH,
        (so.ORDER_ID is not null)            as ORDER_IN_SILVER,
        (qo.ORDER_ID is not null)            as ORDER_IN_QUARANTINE
    from bronze
    left join silver_order_keys     so on try_to_number(bronze.ORDER_ID) = so.ORDER_ID
    left join quarantine_order_keys qo on try_to_number(bronze.ORDER_ID) = qo.ORDER_ID

),

-- Step 2: one TRUE/FALSE flag per QUARANTINE rule. TRUE = rule failed.
checked as (

    select
        cleaned.*,

        -- ORDER_ID NOT_NULL and RANGE: parent order
        (ORDER_ID is null)                                                         as F_ORDER_ID_NOT_NULL,
        (ORDER_ID is not null and not ORDER_IN_SILVER and not ORDER_IN_QUARANTINE)  as F_ORDER_ID_PARENT_MISSING,
        (ORDER_ID is not null and not ORDER_IN_SILVER and ORDER_IN_QUARANTINE)      as F_ORDER_ID_PARENT_QUARANTINED,

        -- PAYMENT_AMOUNT NOT_NULL, TYPE_CAST TRY_TO_DECIMAL(AMOUNT,12,2), RANGE > 0
        (AMOUNT is null)                                                           as F_PAYMENT_AMOUNT_NOT_NULL,
        (AMOUNT is not null and PAYMENT_AMOUNT_NUM is null)                        as F_PAYMENT_AMOUNT_TYPE_CAST,
        (PAYMENT_AMOUNT_NUM is not null and PAYMENT_AMOUNT_NUM <= 0)               as F_PAYMENT_AMOUNT_RANGE,

        -- PAYMENT_DATE NOT_NULL, TYPE_CAST TRY_TO_DATE(PAYMENT_DATE,'YYYY-MM-DD')
        (PAYMENT_DATE is null)                                                     as F_PAYMENT_DATE_NOT_NULL,
        (PAYMENT_DATE is not null and try_to_date(PAYMENT_DATE, 'YYYY-MM-DD') is null)
                                                                                   as F_PAYMENT_DATE_TYPE_CAST,

        -- PAYMENT_ID NOT_NULL, TYPE_CAST, UNIQUE_KEY (duplicates -> ALL copies fail)
        (PAYMENT_ID is null)                                                       as F_PAYMENT_ID_NOT_NULL,
        (try_to_number(PAYMENT_ID) is null)                                        as F_PAYMENT_ID_TYPE_CAST,
        (PAYMENT_ID is not null and KEY_COUNT_IN_BATCH > 1)                        as F_PAYMENT_ID_UNIQUE_KEY,

        -- PAYMENT_METHOD ALLOWED_VALUES (cleaned value)
        not coalesce(PAYMENT_METHOD_CLEAN in ('UPI', 'CASH', 'CARD'), false)       as F_PAYMENT_METHOD_ALLOWED_VALUES

    from cleaned

),

-- Step 3: REJECT_REASON = every failed rule name, joined with ' | '.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_ORDER_ID_NOT_NULL,              'ORDER_ID-NOT_NULL', null),
            iff(F_ORDER_ID_PARENT_MISSING,        'ORDER_ID-RANGE: PARENT_MISSING', null),
            iff(F_ORDER_ID_PARENT_QUARANTINED,    'ORDER_ID-RANGE: PARENT_QUARANTINED', null),
            iff(F_PAYMENT_AMOUNT_NOT_NULL,        'PAYMENT_AMOUNT-NOT_NULL', null),
            iff(F_PAYMENT_AMOUNT_TYPE_CAST,       'PAYMENT_AMOUNT-TYPE_CAST', null),
            iff(F_PAYMENT_AMOUNT_RANGE,           'PAYMENT_AMOUNT-RANGE', null),
            iff(F_PAYMENT_DATE_NOT_NULL,          'PAYMENT_DATE-NOT_NULL', null),
            iff(F_PAYMENT_DATE_TYPE_CAST,         'PAYMENT_DATE-TYPE_CAST', null),
            iff(F_PAYMENT_ID_NOT_NULL,            'PAYMENT_ID-NOT_NULL', null),
            iff(F_PAYMENT_ID_TYPE_CAST,           'PAYMENT_ID-TYPE_CAST', null),
            iff(F_PAYMENT_ID_UNIQUE_KEY,          'PAYMENT_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_PAYMENT_METHOD_ALLOWED_VALUES,  'PAYMENT_METHOD-ALLOWED_VALUES', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    PAYMENT_ID,
    ORDER_ID,
    PAYMENT_METHOD,
    AMOUNT,
    PAYMENT_DATE,
    REJECT_REASON,
    current_timestamp()   as QUARANTINED_AT,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
