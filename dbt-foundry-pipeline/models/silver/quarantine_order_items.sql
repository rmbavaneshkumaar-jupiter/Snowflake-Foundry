-- Foundry dbt pipeline - QUARANTINE ORDER_ITEMS (models/silver/quarantine_order_items.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze ORDER_ITEMS row and checks it against the 13 QUARANTINE rules
-- (ORDER_ITEMS has no CLEAN rule). A row that fails at least one rule lands
-- here with its ORIGINAL raw values and a REJECT_REASON listing EVERY failed rule.
-- silver_order_items.sql takes all Bronze rows that are NOT in this table.
-- Batch B001 (paper check): 450 Bronze = 440 Silver + 10 quarantine.
--
-- WHERE THE RULES COME FROM
-- The 13 ORDER_ITEMS rules made by Skill 2 in the old run (account VI79381,
-- DE_TEST.MONITORING.SILVER_DQ_RULES). No rule added or changed.
--
-- PARENT CHECKS (two parents: ORDERS and PRODUCTS)
--   Parent key found in Silver            -> passes
--   not in Silver, but in quarantine      -> PARENT_QUARANTINED
--   in neither                            -> PARENT_MISSING
-- The 4 ref() calls make dbt build ORDERS and PRODUCTS first. No loop:
-- the parent models never read ORDER_ITEMS.
--
-- BEFORE / AFTER example (batch B001)
--   Line 111 belongs to order 1050. Order 1050 was quarantined (STATUS 'WRONG').
--   So line 111 -> REJECT_REASON 'ORDER_ID-RANGE: PARENT_QUARANTINED', stays here.
--   Line 450 has ORDER_ID 9999, which exists nowhere ->
--   REJECT_REASON 'ORDER_ID-RANGE: PARENT_MISSING'.
--   Without this check Gold would count sales for an order that is not in Silver.
--
-- NAMES: no database or schema written here (source() and ref() fill them in).

with bronze as (

    select * from {{ source('bronze', 'ORDER_ITEMS') }}

),

-- Parent keys: in Silver, and in quarantine (raw text turned into a number)
silver_order_keys as (
    select distinct ORDER_ID from {{ ref('silver_orders') }}
),
quarantine_order_keys as (
    select distinct try_to_number(ORDER_ID) as ORDER_ID
    from {{ ref('quarantine_orders') }}
    where try_to_number(ORDER_ID) is not null
),
silver_product_keys as (
    select distinct PRODUCT_ID from {{ ref('silver_products') }}
),
quarantine_product_keys as (
    select distinct try_to_number(PRODUCT_ID) as PRODUCT_ID
    from {{ ref('quarantine_products') }}
    where try_to_number(PRODUCT_ID) is not null
),

-- Step 1: helper values used ONLY for checking.
prepared as (

    select
        bronze.*,
        try_to_number(QUANTITY)              as QUANTITY_NUM,
        try_to_decimal(UNIT_PRICE, 12, 2)    as UNIT_PRICE_NUM,
        -- UNIQUE_KEY: how many rows share this ORDER_ITEM_ID in the same batch
        count(*) over (partition by _BATCH_ID, ORDER_ITEM_ID) as KEY_COUNT_IN_BATCH,
        (so.ORDER_ID is not null)            as ORDER_IN_SILVER,
        (qo.ORDER_ID is not null)            as ORDER_IN_QUARANTINE,
        (sp.PRODUCT_ID is not null)          as PRODUCT_IN_SILVER,
        (qp.PRODUCT_ID is not null)          as PRODUCT_IN_QUARANTINE
    from bronze
    left join silver_order_keys       so on try_to_number(bronze.ORDER_ID)   = so.ORDER_ID
    left join quarantine_order_keys   qo on try_to_number(bronze.ORDER_ID)   = qo.ORDER_ID
    left join silver_product_keys     sp on try_to_number(bronze.PRODUCT_ID) = sp.PRODUCT_ID
    left join quarantine_product_keys qp on try_to_number(bronze.PRODUCT_ID) = qp.PRODUCT_ID

),

-- Step 2: one TRUE/FALSE flag per QUARANTINE rule. TRUE = rule failed.
checked as (

    select
        prepared.*,

        -- ORDER_ID NOT_NULL
        (ORDER_ID is null)                                                        as F_ORDER_ID_NOT_NULL,
        -- ORDER_ID RANGE: parent order (only checked when a value is given)
        (ORDER_ID is not null and not ORDER_IN_SILVER and not ORDER_IN_QUARANTINE) as F_ORDER_ID_PARENT_MISSING,
        (ORDER_ID is not null and not ORDER_IN_SILVER and ORDER_IN_QUARANTINE)     as F_ORDER_ID_PARENT_QUARANTINED,

        -- ORDER_ITEM_ID NOT_NULL, TYPE_CAST, UNIQUE_KEY (duplicates -> ALL copies fail)
        (ORDER_ITEM_ID is null)                                                   as F_ORDER_ITEM_ID_NOT_NULL,
        (try_to_number(ORDER_ITEM_ID) is null)                                    as F_ORDER_ITEM_ID_TYPE_CAST,
        (ORDER_ITEM_ID is not null and KEY_COUNT_IN_BATCH > 1)                    as F_ORDER_ITEM_ID_UNIQUE_KEY,

        -- PRODUCT_ID NOT_NULL and RANGE: parent product
        (PRODUCT_ID is null)                                                      as F_PRODUCT_ID_NOT_NULL,
        (PRODUCT_ID is not null and not PRODUCT_IN_SILVER and not PRODUCT_IN_QUARANTINE) as F_PRODUCT_ID_PARENT_MISSING,
        (PRODUCT_ID is not null and not PRODUCT_IN_SILVER and PRODUCT_IN_QUARANTINE)     as F_PRODUCT_ID_PARENT_QUARANTINED,

        -- QUANTITY NOT_NULL, TYPE_CAST (only when a value is given), RANGE > 0 (only when readable)
        (QUANTITY is null)                                                        as F_QUANTITY_NOT_NULL,
        (QUANTITY is not null and QUANTITY_NUM is null)                           as F_QUANTITY_TYPE_CAST,
        (QUANTITY_NUM is not null and QUANTITY_NUM <= 0)                          as F_QUANTITY_RANGE,

        -- UNIT_PRICE NOT_NULL, TYPE_CAST TRY_TO_DECIMAL(UNIT_PRICE,12,2), RANGE >= 0
        (UNIT_PRICE is null)                                                      as F_UNIT_PRICE_NOT_NULL,
        (UNIT_PRICE is not null and UNIT_PRICE_NUM is null)                       as F_UNIT_PRICE_TYPE_CAST,
        (UNIT_PRICE_NUM is not null and UNIT_PRICE_NUM < 0)                       as F_UNIT_PRICE_RANGE

    from prepared

),

-- Step 3: REJECT_REASON = every failed rule name, joined with ' | '.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_ORDER_ID_NOT_NULL,             'ORDER_ID-NOT_NULL', null),
            iff(F_ORDER_ID_PARENT_MISSING,       'ORDER_ID-RANGE: PARENT_MISSING', null),
            iff(F_ORDER_ID_PARENT_QUARANTINED,   'ORDER_ID-RANGE: PARENT_QUARANTINED', null),
            iff(F_ORDER_ITEM_ID_NOT_NULL,        'ORDER_ITEM_ID-NOT_NULL', null),
            iff(F_ORDER_ITEM_ID_TYPE_CAST,       'ORDER_ITEM_ID-TYPE_CAST', null),
            iff(F_ORDER_ITEM_ID_UNIQUE_KEY,      'ORDER_ITEM_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_PRODUCT_ID_NOT_NULL,           'PRODUCT_ID-NOT_NULL', null),
            iff(F_PRODUCT_ID_PARENT_MISSING,     'PRODUCT_ID-RANGE: PARENT_MISSING', null),
            iff(F_PRODUCT_ID_PARENT_QUARANTINED, 'PRODUCT_ID-RANGE: PARENT_QUARANTINED', null),
            iff(F_QUANTITY_NOT_NULL,             'QUANTITY-NOT_NULL', null),
            iff(F_QUANTITY_TYPE_CAST,            'QUANTITY-TYPE_CAST', null),
            iff(F_QUANTITY_RANGE,                'QUANTITY-RANGE', null),
            iff(F_UNIT_PRICE_NOT_NULL,           'UNIT_PRICE-NOT_NULL', null),
            iff(F_UNIT_PRICE_TYPE_CAST,          'UNIT_PRICE-TYPE_CAST', null),
            iff(F_UNIT_PRICE_RANGE,              'UNIT_PRICE-RANGE', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    ORDER_ITEM_ID,
    ORDER_ID,
    PRODUCT_ID,
    QUANTITY,
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
