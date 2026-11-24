-- Foundry dbt pipeline - QUARANTINE CUSTOMERS (models/silver/quarantine_customers.sql)
--
-- WHAT THIS MODEL DOES
-- Reads every Bronze CUSTOMERS row and checks it against the QUARANTINE rules.
-- A row that fails at least one rule lands here, with its ORIGINAL raw values
-- (exactly as in Bronze) and a REJECT_REASON that lists EVERY rule it failed.
-- silver_customers.sql then takes all Bronze rows that are NOT in this table.
-- So: Bronze rows = Silver rows + quarantine rows (100 = 97 + 3 for batch B001).
--
-- WHERE THE RULES COME FROM
-- The 14 CUSTOMERS rules made by Skill 2 in the old run (account VI79381,
-- table DE_TEST.MONITORING.SILVER_DQ_RULES). 9 are QUARANTINE rules (checked
-- here) and 5 are CLEAN rules (applied in silver_customers.sql). No new rule
-- was added and none was changed.
--
-- ORDER: CLEAN FIRST, THEN CHECK (same as the old pipeline)
-- The check looks at the cleaned value, not the raw one. Example:
--   Before (Bronze CITY): '  pune '
--   CLEAN rule INITCAP(TRIM()) -> 'Pune'
--   ALLOWED_VALUES check on 'Pune' -> in the list -> passes, row goes to Silver.
--   If we checked the raw '  pune ' it would wrongly be quarantined.
-- Same for EMAIL: '' (empty text) is cleaned to NULL, and the EMAIL rule
-- allows NULL, so customer 98 passes. Customer 97 (EMAIL NULL) also passes.
-- Only the cleaned value is used for the check; the raw value is what we store.
--
-- KNOWN GAP (kept on purpose, same as the old pipeline)
-- CITY ALLOWED_VALUES is a fixed list of 6 cities. A real, valid new city such
-- as 'Madurai' is NOT in the list, so that customer is quarantined even though
-- nothing is wrong with the data. We keep the rule exactly as Skill 2 made it.
-- Fix later (Version 2 idea, not decided): list miss -> warning, not quarantine,
-- or a human-maintained city list.
--
-- NAMES: no database or schema written here. source() gets them from
-- sources.yml; the output schema comes from dbt_project.yml (+schema SILVER).

with bronze as (

    select * from {{ source('bronze', 'CUSTOMERS') }}

),

-- Step 1: cleaned values used ONLY for checking.
-- KEEP IN SYNC: these CLEAN expressions must be the same as in silver_customers.sql.
cleaned as (

    select
        bronze.*,
        initcap(trim(CITY))              as CITY_CLEAN,     -- CITY FORMAT (CLEAN)
        nullif(lower(trim(EMAIL)), '')   as EMAIL_CLEAN,    -- EMAIL FORMAT (CLEAN): blank -> NULL
        -- UNIQUE_KEY: how many rows share this CUSTOMER_ID in the same batch
        count(*) over (partition by _BATCH_ID, CUSTOMER_ID) as KEY_COUNT_IN_BATCH
    from bronze

),

-- Step 2: one TRUE/FALSE flag per QUARANTINE rule. TRUE = rule failed.
-- coalesce(..., false) means: if the test gives NULL (unknown), count it as failed.
checked as (

    select
        cleaned.*,

        -- CITY NOT_NULL: CITY IS NOT NULL after trim
        (trim(CITY) is null)                                              as F_CITY_NOT_NULL,

        -- CITY ALLOWED_VALUES (cleaned value must be one of the 6 cities)
        not coalesce(CITY_CLEAN in ('Mumbai', 'Delhi', 'Pune', 'Bengaluru', 'Hyderabad', 'Chennai'), false)
                                                                          as F_CITY_ALLOWED_VALUES,

        -- CUSTOMER_ID NOT_NULL
        (CUSTOMER_ID is null)                                             as F_CUSTOMER_ID_NOT_NULL,

        -- CUSTOMER_ID TYPE_CAST: TRY_TO_NUMBER(CUSTOMER_ID) IS NOT NULL
        (try_to_number(CUSTOMER_ID) is null)                              as F_CUSTOMER_ID_TYPE_CAST,

        -- CUSTOMER_ID UNIQUE_KEY: duplicates in a batch -> ALL copies fail
        (CUSTOMER_ID is not null and KEY_COUNT_IN_BATCH > 1)              as F_CUSTOMER_ID_UNIQUE_KEY,

        -- EMAIL FORMAT: NULL is allowed, else must look like a@b.c
        not (EMAIL_CLEAN is null or regexp_like(EMAIL_CLEAN, '^[^@ ]+@[^@ ]+\\.[^@ ]+$'))
                                                                          as F_EMAIL_FORMAT,

        -- FIRST_NAME NOT_NULL: TRIM(FIRST_NAME) <> ''  (NULL also fails)
        not coalesce(trim(FIRST_NAME) <> '', false)                       as F_FIRST_NAME_NOT_NULL,

        -- LAST_NAME NOT_NULL: TRIM(LAST_NAME) <> ''  (NULL also fails)
        not coalesce(trim(LAST_NAME) <> '', false)                        as F_LAST_NAME_NOT_NULL,

        -- SIGNUP_DATE TYPE_CAST: must be a real date, only when a value is given
        (SIGNUP_DATE is not null and try_to_date(SIGNUP_DATE) is null)    as F_SIGNUP_DATE_TYPE_CAST

    from cleaned

),

-- Step 3: build REJECT_REASON = every failed rule name, joined with ' | '.
-- array_construct_compact drops the NULLs, so only failed rules remain.
with_reason as (

    select
        checked.*,
        array_to_string(array_construct_compact(
            iff(F_CITY_NOT_NULL,          'CITY-NOT_NULL', null),
            iff(F_CITY_ALLOWED_VALUES,    'CITY-ALLOWED_VALUES', null),
            iff(F_CUSTOMER_ID_NOT_NULL,   'CUSTOMER_ID-NOT_NULL', null),
            iff(F_CUSTOMER_ID_TYPE_CAST,  'CUSTOMER_ID-TYPE_CAST', null),
            iff(F_CUSTOMER_ID_UNIQUE_KEY, 'CUSTOMER_ID-UNIQUE_KEY: DUPLICATE_KEY_IN_BATCH', null),
            iff(F_EMAIL_FORMAT,           'EMAIL-FORMAT', null),
            iff(F_FIRST_NAME_NOT_NULL,    'FIRST_NAME-NOT_NULL', null),
            iff(F_LAST_NAME_NOT_NULL,     'LAST_NAME-NOT_NULL', null),
            iff(F_SIGNUP_DATE_TYPE_CAST,  'SIGNUP_DATE-TYPE_CAST', null)
        ), ' | ') as REJECT_REASON
    from checked

)

-- Step 4: keep only rows that failed something. Raw Bronze values, all text.
select
    CUSTOMER_ID,
    FIRST_NAME,
    LAST_NAME,
    EMAIL,
    PHONE,
    CITY,
    SIGNUP_DATE,
    REJECT_REASON,
    current_timestamp()   as QUARANTINED_AT,
    _LOADED_AT,
    _SOURCE_FILE,
    _BATCH_ID,
    _SOURCE_SYSTEM,
    _SOURCE_ROW_NUMBER
from with_reason
where REJECT_REASON <> ''
