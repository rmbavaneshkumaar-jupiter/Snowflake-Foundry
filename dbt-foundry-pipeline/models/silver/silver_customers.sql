-- Foundry dbt pipeline - SILVER CUSTOMERS (models/silver/silver_customers.sql)
--
-- WHAT THIS MODEL DOES
-- Takes every Bronze CUSTOMERS row that is NOT in quarantine_customers
-- (that model holds the 9 QUARANTINE rules), applies the 5 CLEAN rules,
-- and gives each column its real type. Result for batch B001: 97 rows.
--
-- THE 5 CLEAN RULES (from Skill 2, unchanged)
--   CITY        INITCAP(TRIM())
--   EMAIL       LOWER(TRIM()); blank -> NULL
--   FIRST_NAME  TRIM()
--   LAST_NAME   TRIM()
--   PHONE       TRIM()
--
-- BEFORE / AFTER example (customer 5 in batch B001)
--   Before, Bronze CITY: '  pune '   (two spaces in front, one behind, small p)
--   After,  Silver CITY: 'Pune'
--   So in Gold this customer counts under Pune, not as a separate 'pune' city.
--
-- TYPES
--   CUSTOMER_ID -> NUMBER, SIGNUP_DATE -> DATE, all other columns stay text.
--   Every row here already passed the TYPE_CAST rules, so the casts cannot fail.
--
-- AUDIT COLUMNS: the 5 Bronze audit columns are carried over unchanged
--   (_LOADED_AT, _SOURCE_FILE, _BATCH_ID, _SOURCE_SYSTEM, _SOURCE_ROW_NUMBER).
--
-- HOW A ROW IS MATCHED TO QUARANTINE
--   One Bronze row = one line of one file in one batch, so the key is
--   _BATCH_ID + _SOURCE_FILE + _SOURCE_ROW_NUMBER.
--
-- NOT YET HANDLED (honest note)
--   This model rebuilds from ALL Bronze rows each run (materialized table).
--   With only B001 in Bronze that is correct. When B002 arrives with a
--   customer that already exists in B001, Silver would get two rows for that
--   CUSTOMER_ID (the unique test will then fail). Picking the latest row per
--   key (load_mode incremental_merge) is a later step.
--
-- NAMES: no database or schema written here (source() and ref() fill them in).

with bronze as (

    select * from {{ source('bronze', 'CUSTOMERS') }}

),

quarantined as (

    select _BATCH_ID, _SOURCE_FILE, _SOURCE_ROW_NUMBER
    from {{ ref('quarantine_customers') }}

),

-- Only rows with no failed QUARANTINE rule
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
-- KEEP IN SYNC: CITY and EMAIL expressions must match quarantine_customers.sql.
select
    try_to_number(CUSTOMER_ID)::number(38, 0)   as CUSTOMER_ID,
    trim(FIRST_NAME)::varchar                   as FIRST_NAME,
    trim(LAST_NAME)::varchar                    as LAST_NAME,
    nullif(lower(trim(EMAIL)), '')::varchar     as EMAIL,
    trim(PHONE)::varchar                        as PHONE,
    initcap(trim(CITY))::varchar                as CITY,
    try_to_date(SIGNUP_DATE)                    as SIGNUP_DATE,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from passed
