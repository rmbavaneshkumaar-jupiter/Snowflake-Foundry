-- Foundry dbt pipeline - QUARANTINE RETURNS (models/silver/quarantine_returns.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze RETURNS row and checks it against the 11 QUARANTINE rules.
-- A row that fails at least one rule lands here with its ORIGINAL raw values
-- and a REJECT_REASON listing EVERY failed rule.
-- silver_returns.sql takes all Bronze rows that are NOT in this table.
-- Batch B001 (paper check): 30 Bronze = 27 Silver + 3 quarantine.
--
-- WHERE THE RULES COME FROM
-- The 12 RETURNS rules made by Skill 2 in the old run (account VI79381,
-- DE_TEST.MONITORING.SILVER_DQ_RULES): 11 QUARANTINE (here), 1 CLEAN
-- (RETURN_REASON UPPER(TRIM())). No rule added or changed.
--
-- COLUMN NAME NOTE
-- The rules call the reason RETURN_REASON (Silver name); Bronze calls it REASON.
--
-- PARENT CHECK: ORDER_ID must be in Silver ORDERS, else PARENT_QUARANTINED
-- (order is in quarantine) or PARENT_MISSING (order exists nowhere).
--
-- BEFORE / AFTER example (batch B001)
--   Return 8005: REFUND_AMOUNT '-10.00' -> RANGE rule (> 0) fails -> 'REFUND_AMOUNT-RANGE'.
--   Return 8012: REASON 'CHANGED_MIND' -> it IS in the 4 allowed values -> goes to Silver.
--
-- NAMES: no database or schema written here (source() and ref() fill them in).

with bronze as (

    select * from {{ source('bronze', 'RETURNS') }}

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
-- KEEP IN SYNC: the RETURN_REASON CLEAN expression must match silver_returns.sql.
cleaned as (

    select
        bronze.*,
        upper(trim(REASON))                  as RETURN_REASON_CLEAN,   -- RETURN_REASON FORMAT (CLEAN)
        try_to_decimal(REFUND_AMOUNT, 12, 2) as REFUND_AMOUNT_NUM,
        count(*) over (partition by _BATCH_ID, RETURN_ID) as KEY_COUNT_IN_BATCH,
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

        -- REFUND_AMOUNT NOT_NULL, TYPE_CAST TRY_TO_DECIMAL(REFUND_AMOUNT,12,2), RANGE > 0
        (REFUND_AMOUNT is null)                                                    as F_REFUND_AMOUNT_NOT_NULL,
        (REFUND_AMOUNT is not null and REFUND_AMOUNT_NUM is null)                  as F_REFUND_AMOUNT_TYPE_CAST,
        (REFUND_AMOUNT_NUM is not null and REFUND_AMOUNT_NUM <= 0)                 as F_REFUND_AMOUNT_RANGE,

        -- RETURN_DATE NOT_NULL, TYPE_CAST TRY_TO_DATE(RETURN_DATE,'YYYY-MM-DD')
        (RETURN_DATE is null)                                                      as F_RETURN_DATE_NOT_NULL,
        (RETURN_DATE is not null and try_to_date(RETURN_DATE, 'YYYY-MM-DD') is null)
                                                                                   as F_RETURN_DATE_TYPE_CAST,

        -- RETURN_ID NOT_NULL, TYPE_CAST, UNIQUE_KEY (duplicates -> ALL copies fail)
        (RETURN_ID is null)                                                        as F_RETURN_ID_NOT_NULL,
        (try_to_number(RETURN_ID) is null)                                         as F_RETURN_ID_TYPE_CAST,
        (RETURN_ID is not null and KEY_COUNT_IN_BATCH > 1)                         as F_RETURN_ID_UNIQUE_KEY,

        -- RETURN_REASON ALLOWED_VALUES (cleaned value)
        not coalesce(RETURN_REASON_CLEAN in ('NOT_NEEDED', 'WRONG_ITEM', 'DAMAGED', 'CHANGED_MIND'), false)
                                                                                   as F_RETURN_REASON_ALLOWED_VALUES

    from cleaned

),

-- Step 3: REJECT_REASON = every failed rule name, joined with ' | '.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_ORDER_ID_NOT_NULL,             'ORDER_ID-NOT_NULL', null),
            iff(F_ORDER_ID_PARENT_MISSING,       'ORDER_ID-RANGE: PARENT_MISSING', null),
            iff(F_ORDER_ID_PARENT_QUARANTINED,   'ORDER_ID-RANGE: PARENT_QUARANTINED', null),
            iff(F_REFUND_AMOUNT_NOT_NULL,        'REFUND_AMOUNT-NOT_NULL', null),
            iff(F_REFUND_AMOUNT_TYPE_CAST,       'REFUND_AMOUNT-TYPE_CAST', null),
            iff(F_REFUND_AMOUNT_RANGE,           'REFUND_AMOUNT-RANGE', null),
            iff(F_RETURN_DATE_NOT_NULL,          'RETURN_DATE-NOT_NULL', null),
            iff(F_RETURN_DATE_TYPE_CAST,         'RETURN_DATE-TYPE_CAST', null),
            iff(F_RETURN_ID_NOT_NULL,            'RETURN_ID-NOT_NULL', null),
            iff(F_RETURN_ID_TYPE_CAST,           'RETURN_ID-TYPE_CAST', null),
            iff(F_RETURN_ID_UNIQUE_KEY,          'RETURN_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_RETURN_REASON_ALLOWED_VALUES,  'RETURN_REASON-ALLOWED_VALUES', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    RETURN_ID,
    ORDER_ID,
    REASON,
    REFUND_AMOUNT,
    RETURN_DATE,
    REJECT_REASON,
    current_timestamp()   as QUARANTINED_AT,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
