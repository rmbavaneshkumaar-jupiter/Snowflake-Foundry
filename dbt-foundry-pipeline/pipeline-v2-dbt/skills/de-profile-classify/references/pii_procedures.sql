-- =====================================================================
-- de-profile-classify (Skill 1, Version 2) - the two generic procedures
-- =====================================================================
-- Placeholders: <DB> and <MONITORING_SCHEMA> from the pipeline config.
-- Create them with the pipeline role from the config. No role is created.
-- Both run EXECUTE AS CALLER: they can do only what the caller's role can do.
-- (Snowflake rule seen in our runs: COMMENT must come BEFORE EXECUTE AS.)
--
-- SP_DETECT_PII_PATTERNS     : reads Bronze inside Snowflake, writes COUNTS only.
-- SP_APPLY_APPROVED_PII_TAGS : sets tags ONLY on rows the human APPROVED.
--
-- Neither procedure ever returns, logs or stores a data value.
-- Neither procedure contains a source table name or column name.
-- =====================================================================

USE SCHEMA <DB>.<MONITORING_SCHEMA>;

-- ---------------------------------------------------------------------
-- 1. SP_DETECT_PII_PATTERNS
--    CALL SP_DETECT_PII_PATTERNS('<DB>', '<BRONZE_SCHEMA>', 'PII_B001_20261124T0930');
--    For every base table of the source schema and every column that does
--    not start with '_' (audit columns), it counts how many non-null values
--    match each enabled VALUE_REGEX pattern of PII_PATTERN_CONFIG.
--    Then it builds one PROPOSED row per column in PII_COLUMN_CLASSIFICATION
--    by combining the best value pattern with the column-name hint.
--    Returns a small JSON summary: tables, columns, proposed counts. No values.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DETECT_PII_PATTERNS(
    SOURCE_DB      VARCHAR,
    SOURCE_SCHEMA  VARCHAR,
    RUN_ID         VARCHAR
)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Foundry Skill 1 V2: generic PII pattern detection. Counts only, never values.'
EXECUTE AS CALLER
AS
$$
// ---------- helpers ----------
function run(sql, binds) {
  return snowflake.createStatement({ sqlText: sql, binds: binds || [] }).execute();
}
function ident(name) {
  // Only plain identifiers are accepted. Anything else stops the run.
  if (name === null || name === undefined || !/^[A-Za-z_][A-Za-z0-9_$]*$/.test(name)) {
    throw new Error('Unsafe or empty identifier: ' + name);
  }
  return '"' + name.toUpperCase() + '"';
}
function setting(name) {
  var rs = run('SELECT SETTING_VALUE FROM PROFILE_SETTINGS WHERE SETTING_NAME = ?', [name]);
  if (!rs.next()) { throw new Error('Missing setting in PROFILE_SETTINGS: ' + name); }
  return rs.getColumnValue(1);
}

var db     = ident(SOURCE_DB);
var schema = ident(SOURCE_SCHEMA);
var dbRaw     = SOURCE_DB.toUpperCase();
var schemaRaw = SOURCE_SCHEMA.toUpperCase();

if (!RUN_ID) { throw new Error('RUN_ID is required'); }

// A run id is used once. A new run needs a new id.
var dup = run('SELECT COUNT(*) FROM PII_COLUMN_CLASSIFICATION WHERE RUN_ID = ?', [RUN_ID]);
dup.next();
if (dup.getColumnValue(1) > 0) { throw new Error('RUN_ID already used: ' + RUN_ID); }
dup = run('SELECT COUNT(*) FROM PII_PATTERN_RESULT WHERE RUN_ID = ?', [RUN_ID]);
dup.next();
if (dup.getColumnValue(1) > 0) { throw new Error('RUN_ID already used: ' + RUN_ID); }

// ---------- settings (thresholds only from config) ----------
var sampleRows = parseInt(setting('PII_SAMPLE_ROWS'), 10);
var highPct    = parseFloat(setting('PII_HIGH_MATCH_PCT'));
if (isNaN(sampleRows) || sampleRows < 0) { throw new Error('PII_SAMPLE_ROWS must be 0 or more'); }
if (isNaN(highPct))                      { throw new Error('PII_HIGH_MATCH_PCT must be a number'); }

// ---------- value patterns ----------
var patterns = [];
var prs = run("SELECT PATTERN_ID, PII_CLASS, PATTERN FROM PII_PATTERN_CONFIG " +
              "WHERE ENABLED AND DETECT_METHOD = 'VALUE_REGEX' ORDER BY PRIORITY, PATTERN_ID");
while (prs.next()) {
  patterns.push({ id: prs.getColumnValue(1), cls: prs.getColumnValue(2), re: prs.getColumnValue(3) });
}
if (patterns.length === 0) { throw new Error('No enabled VALUE_REGEX pattern in PII_PATTERN_CONFIG'); }

// ---------- tables of the source schema ----------
var tables = [];
var trs = run('SELECT TABLE_NAME FROM ' + db + '.INFORMATION_SCHEMA.TABLES ' +
              "WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME", [schemaRaw]);
while (trs.next()) { tables.push(trs.getColumnValue(1)); }

var summary = { run_id: RUN_ID, tables: 0, columns: 0, pattern_rows: 0, skipped_tables: [] };

for (var t = 0; t < tables.length; t++) {
  var tbl = tables[t];
  var tblId;
  try { tblId = ident(tbl); } catch (e) { summary.skipped_tables.push(tbl + ' (name not a plain identifier)'); continue; }

  // columns, without audit columns that start with '_'
  var cols = [];
  var crs = run('SELECT COLUMN_NAME, DATA_TYPE FROM ' + db + '.INFORMATION_SCHEMA.COLUMNS ' +
                "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND LEFT(COLUMN_NAME, 1) <> '_' " +
                'ORDER BY ORDINAL_POSITION', [schemaRaw, tbl]);
  while (crs.next()) {
    var cn = crs.getColumnValue(1);
    if (!/^[A-Za-z_][A-Za-z0-9_$]*$/.test(cn)) { continue; }   // odd names are listed by the skill, not scanned
    cols.push({ name: cn, type: crs.getColumnValue(2) });
  }
  if (cols.length === 0) { summary.skipped_tables.push(tbl + ' (no source columns)'); continue; }

  // ONE aggregate query per table. Patterns go in as bind variables.
  // Output = numbers only: total rows, and per column non-null, approx distinct, match counts.
  var selectParts = ['COUNT(*)'];
  var binds = [];
  for (var c = 0; c < cols.length; c++) {
    var v = 'TRIM(TO_VARCHAR(' + ident(cols[c].name) + '))';
    selectParts.push('COUNT(' + ident(cols[c].name) + ')');
    selectParts.push('APPROX_COUNT_DISTINCT(' + ident(cols[c].name) + ')');
    for (var p = 0; p < patterns.length; p++) {
      selectParts.push('COUNT_IF(REGEXP_LIKE(' + v + ", ?, 'i'))");
      binds.push(patterns[p].re);
    }
  }
  var from = db + '.' + schema + '.' + tblId + (sampleRows > 0 ? ' SAMPLE (' + sampleRows + ' ROWS)' : '');
  var agg = run('SELECT ' + selectParts.join(', ') + ' FROM ' + from, binds);
  agg.next();

  var k = 1;
  var rowsScanned = agg.getColumnValue(k++);
  for (var c2 = 0; c2 < cols.length; c2++) {
    var nonNull  = agg.getColumnValue(k++);
    var distinct = agg.getColumnValue(k++);
    var distinctPct = nonNull > 0 ? Math.round(Math.min(distinct, nonNull) * 10000 / nonNull) / 100 : null;
    for (var p2 = 0; p2 < patterns.length; p2++) {
      var m = agg.getColumnValue(k++);
      var pct = nonNull > 0 ? Math.round(m * 10000 / nonNull) / 100 : null;
      run('INSERT INTO PII_PATTERN_RESULT (RUN_ID, TABLE_NAME, COLUMN_NAME, DATA_TYPE, ROWS_SCANNED, ' +
          'NON_NULL_COUNT, DISTINCT_PCT, PATTERN_ID, PII_CLASS, MATCH_COUNT, MATCH_PCT, SAMPLED) ' +
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [RUN_ID, tbl, cols[c2].name, cols[c2].type, rowsScanned, nonNull, distinctPct,
           patterns[p2].id, patterns[p2].cls, m, pct, sampleRows > 0 ? 'Y' : 'N']);
      summary.pattern_rows++;
    }
    summary.columns++;
  }
  summary.tables++;
}

// ---------- combine signals into one PROPOSED row per column (pure SQL) ----------
run(
  "INSERT INTO PII_COLUMN_CLASSIFICATION ( " +
  "  RUN_ID, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, DATA_TYPE, NON_NULL_COUNT, DISTINCT_PCT, " +
  "  PATTERN_CLASS, PATTERN_ID, PATTERN_MATCH_PCT, NAME_HINT_CLASS, NAME_HINT_ID, " +
  "  PROPOSED_CLASS, CONFIDENCE, SIGNAL_CONFLICT, STATUS, MASKING_NEEDED) " +
  "WITH cols AS ( " +
  "  SELECT DISTINCT TABLE_NAME, COLUMN_NAME, DATA_TYPE, NON_NULL_COUNT, DISTINCT_PCT " +
  "  FROM PII_PATTERN_RESULT WHERE RUN_ID = ? ), " +
  "best_value AS ( " +
  "  SELECT r.TABLE_NAME, r.COLUMN_NAME, r.PII_CLASS, r.PATTERN_ID, r.MATCH_PCT, c.NEEDS_NAME_HINT " +
  "  FROM PII_PATTERN_RESULT r " +
  "  JOIN PII_PATTERN_CONFIG c ON c.PATTERN_ID = r.PATTERN_ID " +
  "  WHERE r.RUN_ID = ? " +
  "    AND r.MATCH_PCT >= c.MIN_MATCH_PCT " +
  "    AND (c.MIN_DISTINCT_PCT IS NULL OR r.DISTINCT_PCT >= c.MIN_DISTINCT_PCT) " +
  "  QUALIFY ROW_NUMBER() OVER (PARTITION BY r.TABLE_NAME, r.COLUMN_NAME " +
  "                             ORDER BY r.MATCH_PCT DESC, c.PRIORITY, c.PATTERN_ID) = 1 ), " +
  "name_hint AS ( " +
  "  SELECT k.TABLE_NAME, k.COLUMN_NAME, c.PII_CLASS, c.PATTERN_ID " +
  "  FROM cols k " +
  "  JOIN PII_PATTERN_CONFIG c " +
  "    ON c.ENABLED AND c.DETECT_METHOD = 'NAME_HINT' AND REGEXP_LIKE(k.COLUMN_NAME, c.PATTERN, 'i') " +
  "  QUALIFY ROW_NUMBER() OVER (PARTITION BY k.TABLE_NAME, k.COLUMN_NAME " +
  "                             ORDER BY c.PRIORITY, c.PATTERN_ID) = 1 ) " +
  "SELECT ?, ?, ?, k.TABLE_NAME, k.COLUMN_NAME, k.DATA_TYPE, k.NON_NULL_COUNT, k.DISTINCT_PCT, " +
  "  v.PII_CLASS, v.PATTERN_ID, v.MATCH_PCT, n.PII_CLASS, n.PATTERN_ID, " +
  "  COALESCE(v.PII_CLASS, n.PII_CLASS, 'NONE') AS PROPOSED_CLASS, " +
  "  CASE " +
  "    WHEN v.PII_CLASS IS NOT NULL AND v.MATCH_PCT >= ? " +
  "         AND (v.NEEDS_NAME_HINT = 'N' OR n.PII_CLASS = v.PII_CLASS) THEN 'HIGH' " +
  "    WHEN v.PII_CLASS IS NOT NULL AND v.NEEDS_NAME_HINT = 'Y' AND n.PII_CLASS IS NULL THEN 'LOW' " +
  "    WHEN v.PII_CLASS IS NOT NULL OR n.PII_CLASS IS NOT NULL THEN 'MEDIUM' " +
  "    ELSE 'NONE' END AS CONFIDENCE, " +
  "  CASE WHEN v.PII_CLASS IS NOT NULL AND n.PII_CLASS IS NOT NULL AND v.PII_CLASS <> n.PII_CLASS " +
  "       THEN 'Y' ELSE 'N' END AS SIGNAL_CONFLICT, " +
  "  'PROPOSED', " +
  "  COALESCE(pc.MASKING_NEEDED, 'N') " +
  "FROM cols k " +
  "LEFT JOIN best_value v ON v.TABLE_NAME = k.TABLE_NAME AND v.COLUMN_NAME = k.COLUMN_NAME " +
  "LEFT JOIN name_hint  n ON n.TABLE_NAME = k.TABLE_NAME AND n.COLUMN_NAME = k.COLUMN_NAME " +
  "LEFT JOIN PII_CLASS_CONFIG pc ON pc.PII_CLASS = COALESCE(v.PII_CLASS, n.PII_CLASS, 'NONE') AND pc.ENABLED",
  [RUN_ID, RUN_ID, RUN_ID, dbRaw, schemaRaw, highPct]
);

var cnt = run("SELECT CONFIDENCE, COUNT(*) FROM PII_COLUMN_CLASSIFICATION WHERE RUN_ID = ? GROUP BY CONFIDENCE", [RUN_ID]);
summary.by_confidence = {};
while (cnt.next()) { summary.by_confidence[cnt.getColumnValue(1)] = cnt.getColumnValue(2); }
summary.sampled = sampleRows > 0 ? ('Y, ' + sampleRows + ' rows per table') : 'N, all rows';
return summary;
$$;


-- ---------------------------------------------------------------------
-- 2. SP_APPLY_APPROVED_PII_TAGS
--    CALL SP_APPLY_APPROVED_PII_TAGS('PII_B001_20261124T0930');
--    Sets the three tags ONLY on rows with STATUS = 'APPROVED' and
--    APPROVED_CLASS <> 'NONE' and TAG_APPLIED = 'N'. PROPOSED rows are never
--    touched, so a skipped human gate means nothing gets tagged.
--    Tag names and tag location come from PROFILE_SETTINGS.
--    Tag values come from PII_CLASS_CONFIG and the human's MASKING_NEEDED.
--    Returns counts and the list of failures (statement errors only, no values).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_APPLY_APPROVED_PII_TAGS(
    RUN_ID VARCHAR
)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Foundry Skill 1 V2: apply PII tags to human-APPROVED columns only.'
EXECUTE AS CALLER
AS
$$
function run(sql, binds) {
  return snowflake.createStatement({ sqlText: sql, binds: binds || [] }).execute();
}
function ident(name) {
  if (name === null || name === undefined || !/^[A-Za-z_][A-Za-z0-9_$]*$/.test(name)) {
    throw new Error('Unsafe or empty identifier: ' + name);
  }
  return '"' + name.toUpperCase() + '"';
}
function lit(v) {   // tag values come from config tables; still quote safely
  return "'" + String(v).replace(/\\/g, '\\\\').replace(/'/g, "''") + "'";
}
function setting(name) {
  var rs = run('SELECT SETTING_VALUE FROM PROFILE_SETTINGS WHERE SETTING_NAME = ?', [name]);
  if (!rs.next()) { throw new Error('Missing setting in PROFILE_SETTINGS: ' + name); }
  return rs.getColumnValue(1);
}

if (!RUN_ID) { throw new Error('RUN_ID is required'); }

var tagLoc   = ident(setting('TAG_DATABASE')) + '.' + ident(setting('TAG_SCHEMA')) + '.';
var tagClass = tagLoc + ident(setting('TAG_PII_CLASS'));
var tagSens  = tagLoc + ident(setting('TAG_SENSITIVITY'));
var tagMask  = tagLoc + ident(setting('TAG_MASKING_NEEDED'));

var rows = run(
  "SELECT c.DATABASE_NAME, c.SCHEMA_NAME, c.TABLE_NAME, c.COLUMN_NAME, c.APPROVED_CLASS, " +
  "       pc.SENSITIVITY_LEVEL, c.MASKING_NEEDED " +
  "FROM PII_COLUMN_CLASSIFICATION c " +
  "LEFT JOIN PII_CLASS_CONFIG pc ON pc.PII_CLASS = c.APPROVED_CLASS " +
  "WHERE c.RUN_ID = ? AND c.STATUS = 'APPROVED' AND c.APPROVED_CLASS <> 'NONE' AND c.TAG_APPLIED = 'N' " +
  "ORDER BY c.TABLE_NAME, c.COLUMN_NAME", [RUN_ID]);

var result = { run_id: RUN_ID, tagged: 0, failed: [] };
while (rows.next()) {
  var d = rows.getColumnValue(1), s = rows.getColumnValue(2), t = rows.getColumnValue(3),
      col = rows.getColumnValue(4), cls = rows.getColumnValue(5), sens = rows.getColumnValue(6),
      mask = rows.getColumnValue(7);
  if (sens === null) { result.failed.push(t + '.' + col + ': class ' + cls + ' not in PII_CLASS_CONFIG'); continue; }
  if (mask !== 'Y' && mask !== 'N') { result.failed.push(t + '.' + col + ': MASKING_NEEDED must be Y or N'); continue; }
  try {
    run('ALTER TABLE ' + ident(d) + '.' + ident(s) + '.' + ident(t) +
        ' MODIFY COLUMN ' + ident(col) +
        ' SET TAG ' + tagClass + ' = ' + lit(cls) + ', ' +
                      tagSens  + ' = ' + lit(sens) + ', ' +
                      tagMask  + ' = ' + lit(mask));
    run("UPDATE PII_COLUMN_CLASSIFICATION SET TAG_APPLIED = 'Y', TAG_APPLIED_AT = CURRENT_TIMESTAMP() " +
        "WHERE RUN_ID = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?", [RUN_ID, t, col]);
    result.tagged++;
  } catch (e) {
    result.failed.push(t + '.' + col + ': ' + e.message);
  }
}
var left = run("SELECT COUNT(*) FROM PII_COLUMN_CLASSIFICATION WHERE RUN_ID = ? AND STATUS = 'PROPOSED'", [RUN_ID]);
left.next();
result.still_proposed_not_tagged = left.getColumnValue(1);
return result;
$$;
