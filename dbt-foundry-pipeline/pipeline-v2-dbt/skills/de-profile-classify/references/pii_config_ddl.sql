-- =====================================================================
-- de-profile-classify (Skill 1, Version 2) - config and result tables
-- =====================================================================
-- Placeholders: replace <DB> and <MONITORING_SCHEMA> with the values from
-- the pipeline config file (database, schemas.monitoring).
-- Run as the pipeline role from the config. No role is created here.
--
-- Safe to run again:
--   * every table uses CREATE TABLE IF NOT EXISTS (never drops, never replaces)
--   * seed rows are inserted only when the table is still empty
-- The human edits these tables; the skill never overwrites a human edit.
--
-- DESIGN RULE: no table in this file has a column that holds a data value
-- from a source table. Only names, counts, percentages, flags and decisions.
-- =====================================================================

USE SCHEMA <DB>.<MONITORING_SCHEMA>;

-- ---------------------------------------------------------------------
-- 1. PROFILE_SETTINGS: every threshold the skill uses. Human-editable.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PROFILE_SETTINGS (
    SETTING_NAME   VARCHAR NOT NULL,
    SETTING_VALUE  VARCHAR NOT NULL,
    DESCRIPTION    VARCHAR,
    UPDATED_BY     VARCHAR DEFAULT CURRENT_USER(),
    UPDATED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO PROFILE_SETTINGS (SETTING_NAME, SETTING_VALUE, DESCRIPTION)
SELECT * FROM VALUES
    ('PII_SAMPLE_ROWS',      '0',   'Rows scanned per table for pattern detection. 0 = all rows. Above 0 = random SAMPLE of that many rows.'),
    ('PII_HIGH_MATCH_PCT',   '90',  'Pattern match percent at or above this = HIGH confidence (when the pattern does not need a name hint, or the name hint agrees).'),
    ('PROFILE_TYPE_FIT_PCT', '95',  'inferred_type = most specific type that fits at least this percent of non-null values.'),
    ('TAG_DATABASE',         '<DB>',                'Database that holds the governance tags.'),
    ('TAG_SCHEMA',           '<MONITORING_SCHEMA>', 'Schema that holds the governance tags.'),
    ('TAG_PII_CLASS',        'PII_CLASS',           'Tag name for the approved PII class.'),
    ('TAG_SENSITIVITY',      'PII_SENSITIVITY',     'Tag name for the sensitivity level of the class.'),
    ('TAG_MASKING_NEEDED',   'MASKING_NEEDED',      'Tag name that tells Skill 2 / Skill 3 whether masking is needed (Y/N).')
WHERE NOT EXISTS (SELECT 1 FROM PROFILE_SETTINGS);

-- ---------------------------------------------------------------------
-- 2. PII_CLASS_CONFIG: the list of PII classes. Human-editable.
--    The tag values come from here, so the tags never hold a free text.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PII_CLASS_CONFIG (
    PII_CLASS          VARCHAR NOT NULL,      -- e.g. EMAIL
    SENSITIVITY_LEVEL  VARCHAR NOT NULL,      -- HIGH / MEDIUM / LOW
    MASKING_NEEDED     VARCHAR NOT NULL,      -- Y / N (default proposal; the human can change it per column)
    DESCRIPTION        VARCHAR,
    ENABLED            BOOLEAN DEFAULT TRUE,
    UPDATED_BY         VARCHAR DEFAULT CURRENT_USER(),
    UPDATED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO PII_CLASS_CONFIG (PII_CLASS, SENSITIVITY_LEVEL, MASKING_NEEDED, DESCRIPTION)
SELECT * FROM VALUES
    ('EMAIL',        'HIGH',   'Y', 'E-mail address'),
    ('PHONE',        'HIGH',   'Y', 'Phone or mobile number'),
    ('PAYMENT_CARD', 'HIGH',   'Y', 'Payment card number'),
    ('NATIONAL_ID',  'HIGH',   'Y', 'Government ID number (for example a 12-digit ID or a tax ID format)'),
    ('PERSON_NAME',  'MEDIUM', 'Y', 'First, last or full name of a person'),
    ('ADDRESS',      'MEDIUM', 'Y', 'Street address or postal code'),
    ('BIRTH_DATE',   'MEDIUM', 'Y', 'Date of birth'),
    ('IP_ADDRESS',   'MEDIUM', 'Y', 'IPv4 address'),
    ('NONE',         'LOW',    'N', 'Not PII (used when the human rejects a proposal)')
WHERE NOT EXISTS (SELECT 1 FROM PII_CLASS_CONFIG);

-- ---------------------------------------------------------------------
-- 3. PII_PATTERN_CONFIG: the patterns. Human-editable.
--    DETECT_METHOD = VALUE_REGEX : regex tested on the column VALUES inside Snowflake
--    DETECT_METHOD = NAME_HINT   : regex tested on the column NAME only
--    Snowflake REGEXP_LIKE matches the WHOLE string, so NAME_HINT patterns use .* at both ends.
--    Matching is case-insensitive ('i').
--    NEEDS_NAME_HINT = Y : a value match alone is weak (example: words that look like names
--                          also look like cities). Then confidence is HIGH only if a NAME_HINT
--                          of the same class also matches.
--    MIN_DISTINCT_PCT     : optional. The column must also have at least this percent distinct
--                          values (names are mostly distinct, cities and statuses are not).
--    These are generic starting patterns, not tuned for any one source.
--    Dollar-quoted strings keep the backslashes exactly as written.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PII_PATTERN_CONFIG (
    PATTERN_ID        VARCHAR NOT NULL,
    PII_CLASS         VARCHAR NOT NULL,       -- must exist in PII_CLASS_CONFIG
    DETECT_METHOD     VARCHAR NOT NULL,       -- VALUE_REGEX / NAME_HINT
    PATTERN           VARCHAR NOT NULL,
    MIN_MATCH_PCT     NUMBER(5,2),            -- VALUE_REGEX only: percent of non-null values that must match
    MIN_DISTINCT_PCT  NUMBER(5,2),            -- VALUE_REGEX only, optional
    NEEDS_NAME_HINT   VARCHAR DEFAULT 'N',    -- Y / N
    PRIORITY          NUMBER DEFAULT 100,     -- lower wins when two patterns tie
    ENABLED           BOOLEAN DEFAULT TRUE,
    DESCRIPTION       VARCHAR,
    UPDATED_BY        VARCHAR DEFAULT CURRENT_USER(),
    UPDATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO PII_PATTERN_CONFIG
    (PATTERN_ID, PII_CLASS, DETECT_METHOD, PATTERN, MIN_MATCH_PCT, MIN_DISTINCT_PCT, NEEDS_NAME_HINT, PRIORITY, DESCRIPTION)
SELECT * FROM VALUES
    -- value patterns (run inside Snowflake on the data; only counts come out)
    ('V_EMAIL',       'EMAIL',        'VALUE_REGEX', $$[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$$,          80, NULL, 'N', 10, 'name@domain.tld'),
    ('V_PHONE_IN',    'PHONE',        'VALUE_REGEX', $$(\+?91[ -]?)?0?[6-9][0-9]{4}[ -]?[0-9]{5}$$,                 80, NULL, 'N', 20, '10-digit mobile starting 6-9, optional +91 / 0'),
    ('V_PHONE_INTL',  'PHONE',        'VALUE_REGEX', $$\+[0-9]{1,3}[ -]?[0-9][0-9 ()-]{6,14}[0-9]$$,               80, NULL, 'N', 21, 'International number starting with +'),
    ('V_CARD',        'PAYMENT_CARD', 'VALUE_REGEX', $$[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{1,7}$$,        80, NULL, 'Y', 30, '13-19 digits in groups. No Luhn check, so needs a name hint for HIGH'),
    ('V_NATID_12',    'NATIONAL_ID',  'VALUE_REGEX', $$[2-9][0-9]{3}[ -]?[0-9]{4}[ -]?[0-9]{4}$$,                  80, NULL, 'Y', 40, '12-digit ID format. Long numeric keys look the same, so needs a name hint for HIGH'),
    ('V_TAXID',       'NATIONAL_ID',  'VALUE_REGEX', $$[A-Z]{5}[0-9]{4}[A-Z]$$,                                    80, NULL, 'N', 41, '5 letters, 4 digits, 1 letter tax ID format'),
    ('V_IPV4',        'IP_ADDRESS',   'VALUE_REGEX', $$((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$$, 80, NULL, 'N', 50, 'IPv4 address'),
    ('V_PERSON_NAME', 'PERSON_NAME',  'VALUE_REGEX', $$[A-Za-z][A-Za-z.'-]+( [A-Za-z][A-Za-z.'-]+){0,3}$$,          90, 50,   'Y', 60, 'One to four words of letters. Weak alone, needs a name hint for HIGH'),
    ('V_POSTCODE_IN', 'ADDRESS',      'VALUE_REGEX', $$[1-9][0-9]{2} ?[0-9]{3}$$,                                  90, NULL, 'Y', 70, '6-digit postal code. Weak alone, needs a name hint for HIGH'),
    -- column-name hints (only the column NAME is tested)
    ('N_EMAIL',       'EMAIL',        'NAME_HINT',   $$.*(EMAIL|E_MAIL|MAIL_ID).*$$,                               NULL, NULL, 'N', 10, NULL),
    ('N_PHONE',       'PHONE',        'NAME_HINT',   $$.*(PHONE|MOBILE|CELL|MSISDN|TEL_NO|TELEPHONE).*$$,          NULL, NULL, 'N', 20, NULL),
    ('N_CARD',        'PAYMENT_CARD', 'NAME_HINT',   $$.*(CARD_NO|CARD_NUM|CC_NUM|PAN_NUMBER|CREDIT_CARD).*$$,     NULL, NULL, 'N', 30, NULL),
    ('N_NATID',       'NATIONAL_ID',  'NAME_HINT',   $$.*(AADHAAR|AADHAR|SSN|NATIONAL_ID|PASSPORT|TAX_ID|PAN_NO|VOTER_ID).*$$, NULL, NULL, 'N', 40, NULL),
    ('N_IP',          'IP_ADDRESS',   'NAME_HINT',   $$.*(IP_ADDR|IP_ADDRESS|CLIENT_IP).*$$,                       NULL, NULL, 'N', 50, NULL),
    ('N_NAME',        'PERSON_NAME',  'NAME_HINT',   $$.*(FIRST_NAME|LAST_NAME|FULL_NAME|FIRSTNAME|LASTNAME|SURNAME|PERSON_NAME|CUSTOMER_NAME|CONTACT_NAME).*$$, NULL, NULL, 'N', 60, NULL),
    ('N_ADDRESS',     'ADDRESS',      'NAME_HINT',   $$.*(ADDRESS|ADDR_LINE|STREET|PINCODE|PIN_CODE|ZIP|POSTAL).*$$, NULL, NULL, 'N', 70, NULL),
    ('N_BIRTH',       'BIRTH_DATE',   'NAME_HINT',   $$.*(DOB|BIRTH).*$$,                                          NULL, NULL, 'N', 80, NULL)
WHERE NOT EXISTS (SELECT 1 FROM PII_PATTERN_CONFIG);

-- ---------------------------------------------------------------------
-- 4. PII_PATTERN_RESULT: raw output of SP_DETECT_PII_PATTERNS.
--    One row per run x table x column x VALUE_REGEX pattern.
--    COUNTS ONLY. There is no column for a data value.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PII_PATTERN_RESULT (
    RUN_ID          VARCHAR NOT NULL,
    TABLE_NAME      VARCHAR NOT NULL,
    COLUMN_NAME     VARCHAR NOT NULL,
    DATA_TYPE       VARCHAR,
    ROWS_SCANNED    NUMBER,
    NON_NULL_COUNT  NUMBER,
    DISTINCT_PCT    NUMBER(6,2),             -- approximate distinct / non-null x 100
    PATTERN_ID      VARCHAR NOT NULL,
    PII_CLASS       VARCHAR NOT NULL,
    MATCH_COUNT     NUMBER,
    MATCH_PCT       NUMBER(6,2),             -- MATCH_COUNT / NON_NULL_COUNT x 100
    SAMPLED         VARCHAR,                 -- Y = random sample, N = all rows
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------
-- 5. PII_COLUMN_CLASSIFICATION: one row per run x column.
--    Pattern signal, name signal and AI signal side by side, then the
--    human decision. Status: PROPOSED -> APPROVED / REJECTED.
--    Skill 2 reads only STATUS = 'APPROVED' rows of the latest run.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PII_COLUMN_CLASSIFICATION (
    RUN_ID              VARCHAR NOT NULL,
    DATABASE_NAME       VARCHAR NOT NULL,
    SCHEMA_NAME         VARCHAR NOT NULL,
    TABLE_NAME          VARCHAR NOT NULL,
    COLUMN_NAME         VARCHAR NOT NULL,
    DATA_TYPE           VARCHAR,
    NON_NULL_COUNT      NUMBER,
    DISTINCT_PCT        NUMBER(6,2),
    -- signal 1: values (inside Snowflake, counts only)
    PATTERN_CLASS       VARCHAR,
    PATTERN_ID          VARCHAR,
    PATTERN_MATCH_PCT   NUMBER(6,2),
    -- signal 2: column name
    NAME_HINT_CLASS     VARCHAR,
    NAME_HINT_ID        VARCHAR,
    -- signal 3: AI, from column name + data type + the numbers above only
    AI_PROPOSED_CLASS   VARCHAR,
    AI_REASON           VARCHAR,
    -- combined proposal (computed by SQL, not by AI)
    PROPOSED_CLASS      VARCHAR,
    CONFIDENCE          VARCHAR,             -- HIGH / MEDIUM / LOW / NONE
    SIGNAL_CONFLICT     VARCHAR,             -- Y when pattern and name hint point to different classes
    -- human decision
    STATUS              VARCHAR DEFAULT 'PROPOSED',   -- PROPOSED / APPROVED / REJECTED
    APPROVED_CLASS      VARCHAR,             -- may differ from PROPOSED_CLASS when the human edits it
    MASKING_NEEDED      VARCHAR,             -- Y / N, from PII_CLASS_CONFIG unless the human changes it
    DECIDED_BY          VARCHAR,
    DECIDED_AT          TIMESTAMP_NTZ,
    DECISION_REASON     VARCHAR,
    -- tagging
    TAG_APPLIED         VARCHAR DEFAULT 'N', -- Y after SP_APPLY_APPROVED_PII_TAGS
    TAG_APPLIED_AT      TIMESTAMP_NTZ,
    CREATED_AT          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------
-- 6. PII_DECISION_LOG: append-only audit of every human decision
--    (idea taken from Verity: DRAFT rules + audit row).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PII_DECISION_LOG (
    LOG_ID          NUMBER AUTOINCREMENT,
    RUN_ID          VARCHAR NOT NULL,
    TABLE_NAME      VARCHAR NOT NULL,
    COLUMN_NAME     VARCHAR NOT NULL,
    OLD_STATUS      VARCHAR,
    NEW_STATUS      VARCHAR,
    PROPOSED_CLASS  VARCHAR,
    APPROVED_CLASS  VARCHAR,
    MASKING_NEEDED  VARCHAR,
    DECIDED_BY      VARCHAR DEFAULT CURRENT_USER(),
    DECIDED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    DECISION_REASON VARCHAR
);

-- ---------------------------------------------------------------------
-- 7. Tags (created once, after the human approves the first PII review).
--    Allowed values keep the tags clean. Update ALLOWED_VALUES by hand
--    when a class is added to PII_CLASS_CONFIG.
-- ---------------------------------------------------------------------
-- CREATE TAG IF NOT EXISTS <DB>.<MONITORING_SCHEMA>.PII_CLASS
--     ALLOWED_VALUES 'EMAIL','PHONE','PAYMENT_CARD','NATIONAL_ID','PERSON_NAME','ADDRESS','BIRTH_DATE','IP_ADDRESS'
--     COMMENT = 'Approved PII class (Foundry Skill 1 V2)';
-- CREATE TAG IF NOT EXISTS <DB>.<MONITORING_SCHEMA>.PII_SENSITIVITY
--     ALLOWED_VALUES 'HIGH','MEDIUM','LOW'
--     COMMENT = 'Sensitivity of the approved PII class (Foundry Skill 1 V2)';
-- CREATE TAG IF NOT EXISTS <DB>.<MONITORING_SCHEMA>.MASKING_NEEDED
--     ALLOWED_VALUES 'Y','N'
--     COMMENT = 'Masking needed for this column, read by Skill 2 and Skill 3 (Foundry Skill 1 V2)';
