-- Foundry dbt pipeline - SILVER RETURNS (models/silver/silver_returns.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze RETURNS row that is NOT in quarantine_returns,
-- applies the 1 CLEAN rule and gives each column its real type.
-- Batch B001 (paper check, not run yet): 27 rows.
--
-- THE CLEAN RULE (from Skill 2, unchanged)
--   RETURN_REASON  UPPER(TRIM())
--
-- BEFORE / AFTER example (return 8001 in batch B001)
--   Before, Bronze (all text):  REASON 'NOT_NEEDED', REFUND_AMOUNT '762.50', RETURN_DATE '2026-01-20'
--   After,  Silver (typed):     RETURN_REASON 'NOT_NEEDED', REFUND_AMOUNT 762.50, RETURN_DATE 2026-01-20
--   (If a file ever sends ' damaged', the clean rule turns it into 'DAMAGED'.)
--
-- TYPES AND NAMES
--   RETURN_ID, ORDER_ID -> NUMBER; REFUND_AMOUNT -> NUMBER(12,2); RETURN_DATE -> DATE.
--   Bronze REASON -> Silver RETURN_REASON (the rules use that name).
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged.
-- MATCH TO QUARANTINE: _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
-- NOT YET HANDLED: full rebuild over all batches (same note as silver_customers.sql).

with bronze as (

    select * from {{ source('bronze', 'RETURNS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_returns') }}

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
-- KEEP IN SYNC: RETURN_REASON expression must match quarantine_returns.sql.
select
    try_to_number(RETURN_ID)::number(38, 0)              as RETURN_ID,
    try_to_number(ORDER_ID)::number(38, 0)               as ORDER_ID,
    upper(trim(REASON))::varchar                         as RETURN_REASON,
    try_to_decimal(REFUND_AMOUNT, 12, 2)::number(12, 2)  as REFUND_AMOUNT,
    try_to_date(RETURN_DATE, 'YYYY-MM-DD')               as RETURN_DATE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
