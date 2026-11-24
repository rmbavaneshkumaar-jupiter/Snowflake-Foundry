-- Foundry dbt pipeline - SILVER PAYMENTS (models/silver/silver_payments.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze PAYMENTS row that is NOT in quarantine_payments,
-- applies the 1 CLEAN rule and gives each column its real type.
-- Batch B001 (paper check, not run yet): 183 rows.
--
-- THE CLEAN RULE (from Skill 2, unchanged)
--   PAYMENT_METHOD  UPPER(TRIM())
--
-- BEFORE / AFTER example (payment 5001 in batch B001)
--   Before, Bronze (all text):  AMOUNT '2025.00', PAYMENT_DATE '2026-01-03'
--   After,  Silver (typed):     PAYMENT_AMOUNT 2025.00 (NUMBER), PAYMENT_DATE 2026-01-03 (DATE)
--   (If a file ever sends ' upi', the clean rule turns it into 'UPI'.)
--
-- TYPES AND NAMES
--   PAYMENT_ID, ORDER_ID -> NUMBER; Bronze AMOUNT -> Silver PAYMENT_AMOUNT NUMBER(12,2);
--   PAYMENT_DATE -> DATE; PAYMENT_METHOD text.
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged.
-- MATCH TO QUARANTINE: _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
-- NOT YET HANDLED: full rebuild over all batches (same note as silver_customers.sql).

with bronze as (

    select * from {{ source('bronze', 'PAYMENTS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_payments') }}

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

-- CLEAN rule + types.
-- KEEP IN SYNC: PAYMENT_METHOD expression must match quarantine_payments.sql.
select
    try_to_number(PAYMENT_ID)::number(38, 0)      as PAYMENT_ID,
    try_to_number(ORDER_ID)::number(38, 0)        as ORDER_ID,
    upper(trim(PAYMENT_METHOD))::varchar          as PAYMENT_METHOD,
    try_to_decimal(AMOUNT, 12, 2)::number(12, 2)  as PAYMENT_AMOUNT,
    try_to_date(PAYMENT_DATE, 'YYYY-MM-DD')       as PAYMENT_DATE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
