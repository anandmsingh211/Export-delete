/* -------------------------------------------------------------------- */
/* BLOCK 1: SESSION CONFIGURATION & SETUP                               */
/* -------------------------------------------------------------------- */
SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET AUTOCOMMIT OFF
SET FEEDBACK OFF
SET TIME ON
SET TIMING ON
SET TRIMSPOOL ON
SET PAGESIZE 0
SET LINESIZE 32767
SET DEFINE ON
TTITLE OFF
BTITLE OFF

-- Unify date formatting in outputs and dynamic SQL.
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

-- Fail fast: if OS or SQL errors occur, exit with FAILURE and rollback.
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- **********************************************************************
-- SQL Script File Name: export_delete_final1.sql
-- **********************************************************************
-- Purpose / Flow:
--   1) Parse Data Pump Log to extract expected row counts per Template+Table.
--   2) Sum actual deletes across all batches that match the template & date window.
--   3) Reconcile (expected from log vs. actual deleted rows).
--   4) Print summary if they match; error out if they don't.
--   5) Perform post-delete maintenance (TABLE MOVE + INDEX REBUILD) ONLY for
--      tables that had deletes in this run (tracked in an in-memory set).
-- Notes:
--   - The delete loop is guarded by before/after counts per-batch; it rolls back
--     the single batch if counts mismatch (via SAVEPOINT).
--   - The outer block ends with a ROLLBACK (TEST MODE). Change to COMMIT for prod.
--   - DDL (MOVE/REBUILD) COMMITs regardless (Oracle behavior).
-- **********************************************************************

/* -------------------------------------------------------------------- */
/* BLOCK 2: PARAMETER DEFINITIONS & PROCESSING                          */
/* -------------------------------------------------------------------- */
-- Usage (SQL*Plus):  @export_delete_final1.sql <TARGET_DB> <START> <END> <LOG_DIR> <LOG_FILE> <TEMPLATE_CLAUSE>
-- Example TEMPLATE_CLAUSE inputs:
--   '__ALL__'                → means "no filter", i.e., all templates
--   "IN ('TEMPLATE_A','B')"  → explicit IN list
--   "= 'SOME_TEMPLATE'"      → equality
DEFINE P_TARGET_DB = '&1'
DEFINE P_START_DATE = '&2'   -- MM/DD/YYYY
DEFINE P_END_DATE   = '&3'   -- MM/DD/YYYY
DEFINE P_LOG_DIR    = '&4'   -- Oracle DIRECTORY object name
DEFINE P_LOG_FILE   = '&5'   -- File name within that DIRECTORY
DEFINE P_TEMPLATE_CLAUSE = '&6' 
----------------------------------------------------------------------

-- Build a reusable clause for filtering template IDs.
-- If user passes __ALL__, we expand to a tautology (IS NOT NULL).
-- Else, we trust the user-provided full clause (e.g., IN ('A','B')).
COLUMN tmpl_clause NEW_VALUE tmpl_clause NOPRINT
SELECT CASE
         WHEN q'[&P_TEMPLATE_CLAUSE]' = '__ALL__' THEN 'IS NOT NULL'
         ELSE q'[&P_TEMPLATE_CLAUSE]'
       END AS tmpl_clause
  FROM dual;

/* -------------------------------------------------------------------- */
/* BLOCK 3: SPOOL FILE CONFIGURATION                                    */
/* -------------------------------------------------------------------- */
-- Useful for deterministic logging: SPOOL file depends only on inputs.
COLUMN G_STARTDATE NEW_VALUE G_STARTDATE
COLUMN G_ENDDATE   NEW_VALUE G_ENDDATE

-- Strip slashes from dates to make them filename-friendly (MMDDYYYY style).
SELECT REPLACE('&P_START_DATE','/','') AS G_STARTDATE FROM DUAL;
SELECT REPLACE('&P_END_DATE','/','')   AS G_ENDDATE   FROM DUAL;

-- Central log file for the entire run; adjust directory if needed.
SPOOL /backup/exa_ps/dba/PS_ARCHIVAL/LOG/EXPORT_DELETE_&P_TARGET_DB._&G_STARTDATE._&G_ENDDATE..LOG

/* -------------------------------------------------------------------- */
/* BLOCK 4: MAIN DECLARATION & VARIABLE INITIALIZATION                  */
/* -------------------------------------------------------------------- */
DECLARE
  /* 1) CONTEXT VARIABLES */
  V_CURRENT_DB VARCHAR2(30);                     -- DB we are connected to
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';   -- DB expected by operator

  -- Convert input dates to timestamps; end date is exclusive (add +1 day).
  V_START_TS   TIMESTAMP := TO_TIMESTAMP('&P_START_DATE', 'MM/DD/YYYY');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP('&P_END_DATE',   'MM/DD/YYYY') + INTERVAL '1' DAY;

  /* 2) RECONCILIATION MAPS */
  -- Map key = 'TEMPLATE|TABLE', value = expected rows from Data Pump log.
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  V_EXPECTED_LOG  T_COUNT_MAP; 
  
  /* 2b) TABLES THAT ACTUALLY HAD DELETES (for maintenance) */
  -- Acts like a set: keys are bare table names (without 'PS_' prefix), value ignored.
  TYPE T_STR_SET IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(128);
  V_DELETED_TABLES  T_STR_SET;

  /* 3) OUTPUT BUFFERING (currently not persisted; placeholder for extensions) */
  TYPE T_OUT_BUFFER IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  V_BATCH_MSGS    T_OUT_BUFFER;

  /* 4) COUNTERS AND HELPERS */
  V_TOTAL_ROWS    PLS_INTEGER := 0;    -- global deleted row count (for summary)
  V_CUR_TEMPLATE  VARCHAR2(64);        -- template currently parsed from log file
  V_LINES_READ    PLS_INTEGER := 0;    -- number of log lines read
  V_TPL_FOUND     PLS_INTEGER := 0;    -- reserved (unused)
  V_EXPORT_LINES  PLS_INTEGER := 0;    -- reserved (unused)
  
  -- Validation helper used with dynamic template filter.
  V_IS_IN_SCOPE   NUMBER;

  -- Utility: builds a composite key "TEMPLATE|TABLE".
  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

BEGIN
  /* -------------------------------------------------------------------- */
  /* BLOCK 5: DATABASE CONTEXT AND INPUT SAFETY CHECKS                    */
  /* -------------------------------------------------------------------- */
  -- Ensure we are connected to the intended DB.
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  -- Validate temporal window: end must be after start.
  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  -- Display the effective template filter safely (q'[]' avoids quote conflicts).
  DBMS_OUTPUT.PUT_LINE('Templates selected ' || q'[&tmpl_clause]');

  /* -------------------------------------------------------------------- */
  /* BLOCK 6: LOG FILE PARSING (LOADS EXPECTED COUNTS)                    */
  /* -------------------------------------------------------------------- */
  -- Reads the Data Pump log via UTL_FILE, extracts:
  --   - Current Template (lines: "Beginning export of Template : <TEMPLATE>")
  --   - Table names (pattern: "SYSADM"."PS_...") and row counts ("<n> rows")
  -- Accumulates expected rows per (Template|Table) in V_EXPECTED_LOG.
  DECLARE
    F_LOG         UTL_FILE.FILE_TYPE;
    V_LINE        VARCHAR2(32767);
    V_TBL         VARCHAR2(128);    -- captured table name with prefix PS_...
    V_ROWS        PLS_INTEGER;      -- captured row count from "<n> rows"
    V_KEY         VARCHAR2(400);    -- "TEMPLATE|TABLE"
    V_EXISTS      BOOLEAN;          -- for FGETATTR presence check
    V_FILE_LEN    NUMBER;           -- file size (bytes; informational)
    V_BLKSIZE     NUMBER;           -- file block size (informational)
    V_DIR_PATH    VARCHAR2(1000);   -- resolved path of DIRECTORY object
  BEGIN
    -- Resolve DIRECTORY object path; try ALL_DIRECTORIES (low-privileged) first,
    -- then DBA_DIRECTORIES for privileged accounts.
    BEGIN
      SELECT directory_path INTO V_DIR_PATH
      FROM   ALL_DIRECTORIES
      WHERE  directory_name = UPPER('&P_LOG_DIR');
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        SELECT directory_path INTO V_DIR_PATH
        FROM   DBA_DIRECTORIES
        WHERE  directory_name = UPPER('&P_LOG_DIR');
    END;

    -- Check if file exists before opening; raises -20012 if not found.
    UTL_FILE.FGETATTR(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), V_EXISTS, V_FILE_LEN, V_BLKSIZE);
    IF NOT V_EXISTS THEN
      RAISE_APPLICATION_ERROR(-20012, 'Log file not found: '||'&P_LOG_DIR'||'/'||'&P_LOG_FILE');
    END IF;

    -- Open the log file in read mode, large line size to avoid truncation.
    F_LOG := UTL_FILE.FOPEN(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), 'R', 32767);

    <<READ_LOOP>>
    LOOP
      -- Read one line, count it; handle EOF and unexpected errors.
      BEGIN
        UTL_FILE.GET_LINE(F_LOG, V_LINE);
        V_LINES_READ := V_LINES_READ + 1;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          UTL_FILE.FCLOSE(F_LOG);
          EXIT READ_LOOP;
        WHEN OTHERS THEN
          UTL_FILE.FCLOSE(F_LOG);
          RAISE_APPLICATION_ERROR(-20014, 'Read error in log file');
      END;

      /* Detect template banner:
         Matches lines like: "Beginning export of Template : TEMPLATE_X".
         Captures the template token (\S+ equals non-space sequence). */
      IF REGEXP_LIKE(V_LINE, '^Beginning export of Template\s*:') THEN
        V_CUR_TEMPLATE := REGEXP_SUBSTR(V_LINE, 'Beginning export of Template\s*:\s*(\S+)', 1, 1, NULL, 1);
        CONTINUE;
      END IF;

      /* Extract "SYSADM"."PS_TABLE..." from the current line, if present. */
      V_TBL := REGEXP_SUBSTR(V_LINE, '"SYSADM"\."(PS_[^"]+)"', 1, 1, NULL, 1);

      /* Extract "<n> rows" count from the same line. */
      IF REGEXP_LIKE(V_LINE, '\s(\d+)\s+rows') THEN
        V_ROWS := TO_NUMBER(REGEXP_SUBSTR(V_LINE, '\s(\d+)\s+rows', 1, 1, NULL, 1));
      ELSE
        V_ROWS := NULL;
      END IF;

      /* If we have a current template, a table name, and a row count, accumulate. */
      IF V_CUR_TEMPLATE IS NOT NULL AND V_TBL IS NOT NULL AND V_ROWS IS NOT NULL THEN
        V_KEY := MK_KEY(V_CUR_TEMPLATE, V_TBL);
        IF V_EXPECTED_LOG.EXISTS(V_KEY) THEN
            V_EXPECTED_LOG(V_KEY) := V_EXPECTED_LOG(V_KEY) + V_ROWS;  -- multiple log lines per table
        ELSE
            V_EXPECTED_LOG(V_KEY) := V_ROWS;
        END IF;
      END IF;
    END LOOP READ_LOOP;
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 7: PROCESS BY UNIT OF WORK (TEMPLATE + TABLE)                  */
  /* -------------------------------------------------------------------- */
  -- Iterate over each (Template|Table) pair extracted from the log,
  -- filter by the user-provided template clause, then:
  --   1) Find PeopleSoft Archive batches for that Template & record (table)
  --      within the given datetime window [start, end).
  --   2) For each batch: validate expected vs. deleted rows via pre/post counts.
  --   3) On perfect reconciliation, add to grand totals and mark the table
  --      for post-maintenance.
  DECLARE
    K VARCHAR2(400);            -- iteration key over V_EXPECTED_LOG
    V_TPL_KEY VARCHAR2(64);     -- parsed template from K
    V_TBL_KEY VARCHAR2(128);    -- parsed table from K (e.g., PS_SOMETHING)
    V_PURE_TBL VARCHAR2(128);   -- table without 'PS_' prefix (e.g., SOMETHING)
    V_EXPECTED_TOTAL PLS_INTEGER; -- expected from log
    V_ACTUAL_TOTAL   PLS_INTEGER; -- sum of per-batch deletes actually done
    
    V_EXP_CNT  PLS_INTEGER;     -- pre-delete rowcount for batch
    V_DEL_CNT  PLS_INTEGER;     -- rows deleted by the DELETE statement
    V_POST_CNT PLS_INTEGER;     -- post-delete rowcount (should be 0)

    -- NEW: Track last printed template name
    V_LAST_TPL_PRINTED VARCHAR2(64) := NULL;
    
  BEGIN
    K := V_EXPECTED_LOG.FIRST;
    
    WHILE K IS NOT NULL LOOP
      /* ---------------------------------------------------------------- */
      /* BLOCK 7.1: FILTER APPLICATION & INITIALIZATION                   */
      /* ---------------------------------------------------------------- */
      -- A. Parse Key → TEMPLATE and full table name.
      V_TPL_KEY := SUBSTR(K, 1, INSTR(K, '|') - 1);
      V_TBL_KEY := SUBSTR(K, INSTR(K, '|') + 1);
      V_PURE_TBL := SUBSTR(V_TBL_KEY, 4);  -- strip 'PS_' prefix for PeopleSoft metadata joins

      -- B. USER FILTER CHECK:
      -- Apply the caller-provided template filter safely via dynamic SQL.
      -- We evaluate a predicate like ":1 IN ('A','B')" or ":1 = 'X'" over DUAL.
      BEGIN
        EXECUTE IMMEDIATE q'[SELECT 1 FROM DUAL WHERE :1 &tmpl_clause]'
        INTO V_IS_IN_SCOPE
        USING V_TPL_KEY;-- binds template as :1

      EXCEPTION 
        WHEN NO_DATA_FOUND THEN
          V_IS_IN_SCOPE := 0;  -- filtered out
      END;

      IF V_IS_IN_SCOPE = 0 THEN
         K := V_EXPECTED_LOG.NEXT(K);
         CONTINUE;  -- skip keys not in scope
      END IF;
      -------------------------------------------------------------------
      --PRINT TEMPLATE NAME ONLY ONCE
      -------------------------------------------------------------------
      IF V_LAST_TPL_PRINTED IS NULL OR V_LAST_TPL_PRINTED <> V_TPL_KEY THEN
          DBMS_OUTPUT.PUT_LINE(' ');
          DBMS_OUTPUT.PUT_LINE('======================================================');
          DBMS_OUTPUT.PUT_LINE('Starting Template : ' || V_TPL_KEY);
          DBMS_OUTPUT.PUT_LINE('======================================================');
          V_LAST_TPL_PRINTED := V_TPL_KEY;  -- remember printed template
      END IF;
      -------------------------------------------------------------------

      V_EXPECTED_TOTAL := V_EXPECTED_LOG(K);  -- expected total from log
      V_ACTUAL_TOTAL := 0;                    -- will sum deletions across batches
      V_BATCH_MSGS.DELETE;

      /* ---------------------------------------------------------------- */
      /* BLOCK 7.2: BATCH IDENTIFICATION (METADATA LOOKUP)                */
      /* ---------------------------------------------------------------- */
      -- C. Find Batches for this Template & Record (PeopleSoft archive metadata).
      --   PSARCHBATCH: contains batch-level info with PSARCH_DTTM timestamp.
      --   PSARCHTEMPOBJ: links template (PSARCH_ID) to objects
      --   PSARCHOBJREC: defines record/table names (HIST_RECNAME stores PS_* without owner)
      FOR BATCH_REC IN (
        SELECT DISTINCT B.PSARCH_BATCHNUM, B.PSARCH_ID
        FROM   PSARCHBATCH B
               JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
               JOIN PSARCHOBJREC  A ON T.PSARCH_OBJECT = A.PSARCH_OBJECT
        WHERE  B.PSARCH_ID = V_TPL_KEY
        AND    A.HIST_RECNAME = V_PURE_TBL
        AND    B.PSARCH_DTTM >= V_START_TS
        AND    B.PSARCH_DTTM <  V_END_TS
        ORDER BY B.PSARCH_BATCHNUM
      )
      LOOP
        /* -------------------------------------------------------------- */
        /* BLOCK 7.3: ATOMIC BATCH EXECUTION (DELETE & VALIDATION)        */
        /* -------------------------------------------------------------- */
        -- D. Execute Delete (Iterative Summation per batch)
        -- Use a SAVEPOINT so we can roll back this one batch if validation fails.
        BEGIN
          SAVEPOINT ONE_BATCH;
          
          -- Pre-delete count for this batch.
          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_EXP_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          -- Perform the delete for exactly this batch.
          EXECUTE IMMEDIATE 'DELETE FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;
          
          V_DEL_CNT := SQL%ROWCOUNT;  -- rows actually removed

          -- Post-delete validation: the same criteria should now return 0 rows.
          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_POST_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          -- Strict local validation: 
          --   - Pre count must equal deleted count
          --   - Post count must be zero
          IF V_EXP_CNT = V_DEL_CNT AND V_POST_CNT = 0 THEN
             V_ACTUAL_TOTAL := V_ACTUAL_TOTAL + V_DEL_CNT;
          ELSE
             ROLLBACK TO SAVEPOINT ONE_BATCH;
             RAISE_APPLICATION_ERROR(-20020, 'Local Validation failed for '||V_TBL_KEY||' Batch '||BATCH_REC.PSARCH_BATCHNUM);
          END IF;
        END;
      END LOOP;

      /* ---------------------------------------------------------------- */
      /* BLOCK 7.4: FINAL RECONCILIATION & SUMMARY                        */
      /* ---------------------------------------------------------------- */
      -- E. TOTAL VALIDATION (Compare Summed Batches vs Single Log Entry)
      -- If mismatch, we treat as critical and abort.
      IF V_ACTUAL_TOTAL = V_EXPECTED_TOTAL THEN
         -- Print consolidated summary for this Template+Table.
         DBMS_OUTPUT.PUT_LINE(V_ACTUAL_TOTAL || '|rows deleted from |' || V_TBL_KEY || '| record of |' || V_TPL_KEY || '| template.');
         V_TOTAL_ROWS := V_TOTAL_ROWS + V_ACTUAL_TOTAL;

         -- Record this table for maintenance:
         -- key stored as the bare name (without PS_) because that aligns with PeopleSoft metadata.
         V_DELETED_TABLES(V_PURE_TBL) := 1;
      ELSE
         RAISE_APPLICATION_ERROR(-20031, 
           'EXPORT/DELETE MISMATCH for '||K||
           ' Expected='||V_EXPECTED_TOTAL||
           ' Deleted='||V_ACTUAL_TOTAL);
      END IF;

      -- Move to next key in the expected map.
      K := V_EXPECTED_LOG.NEXT(K);
    END LOOP;
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 8: FINAL TRANSACTION MODE (COMMIT/ROLLBACK)                    */
  /* -------------------------------------------------------------------- */
  -- Summary is printed; then we *ROLLBACK* the DML (TEST MODE).
  -- For PROD, replace ROLLBACK with COMMIT. Note: DDL below is auto-commit anyway.
  DBMS_OUTPUT.PUT_LINE('SUMMARY: Total rows processed='||V_TOTAL_ROWS||' (TEST MODE: ROLLED BACK)');
  ROLLBACK; -- TEST MODE
  -- ; -- PRODUCTION MODE

/* -------------------------------------------------------------------- */
/* BLOCK 9: POST-DELETE MAINTENANCE (MOVE & REBUILD)                    */
/* -------------------------------------------------------------------- */
-- POST-DELETE TABLE MOVE + INDEX REBUILD (ONLY TABLES WITH DELETES)
-- Drives from V_DELETED_TABLES (built during the delete loop)
-- NOTE: DDL (MOVE/REBUILD) commits and will NOT roll back, even in TEST MODE.
-- Added: Size snapshot (MB) before and after maintenance per table
------------------------------------------------------------------------------
DECLARE
  TBL_KEY   VARCHAR2(128);   -- iteration key across V_DELETED_TABLES
  TBL       VARCHAR2(128);   -- bare name like 'SOMETHING' (without 'PS_')
  PRE_MB    NUMBER;          -- size (MB) before MOVE
  POST_MB   NUMBER;          -- size (MB) after MOVE + REBUILD
  SEG_TNAME VARCHAR2(128);   -- full table name with PS_ prefix
BEGIN
  TBL_KEY := V_DELETED_TABLES.FIRST;

  IF TBL_KEY IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('Maintenance skipped: no tables had deletes in this run.');
  END IF;

  WHILE TBL_KEY IS NOT NULL LOOP
    TBL := TBL_KEY;                -- bare table name from the set
    SEG_TNAME := 'PS_' || TBL;     -- actual segment/table name with prefix
    DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('Starting maintenance for table: ' || SEG_TNAME);

    /* ---------------------------------------------------------------- */
    /* BLOCK 9.1: PRE-MAINTENANCE SIZE SNAPSHOT                         */
    /* ---------------------------------------------------------------- */
    -- SIZE SNAPSHOT: BEFORE
    -- Uses DBA_SEGMENTS; SUM(BYTES) to handle partitions/subsegments.
    -- Restricts to TABLE segments owned by SYSADM.
    ------------------------------------------------------------------
    BEGIN
      SELECT NVL(SUM(BYTES),0)/1024/1024
      INTO   PRE_MB
      FROM   DBA_SEGMENTS
      WHERE  OWNER        = 'SYSADM'
      AND    SEGMENT_NAME = SEG_TNAME
      AND    SEGMENT_TYPE = 'TABLE';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        PRE_MB := 0;
    END;

    DBMS_OUTPUT.PUT_LINE('Size before Shrink of '|| SEG_TNAME|| ' : '  || TO_CHAR(ROUND(PRE_MB,2)) || ' MB');

    /* ---------------------------------------------------------------- */
    /* BLOCK 9.2: TABLE MOVE (SEGMENT COMPACTION)                       */
    /* ---------------------------------------------------------------- */
    -- TABLE MOVE (compacts segment and can reclaim space)
    -- - Enable row movement temporarily (required for ALTER TABLE ... MOVE).
    -- - Move in parallel (tune degree as needed).
    -- - Disable row movement afterward to restore default semantics.
    ------------------------------------------------------------------
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || SEG_TNAME || ' ENABLE ROW MOVEMENT';
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || SEG_TNAME || ' MOVE PARALLEL 4';
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || SEG_TNAME || ' DISABLE ROW MOVEMENT';
      DBMS_OUTPUT.PUT_LINE('  Table shrink successful: ' || SEG_TNAME);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  WARNING: Table move failed for ' || SEG_TNAME || ' — ' || SQLERRM);
    END;

    /* ---------------------------------------------------------------- */
    /* BLOCK 9.3: INDEX REBUILD                                         */
    /* ---------------------------------------------------------------- */
    -- INDEX REBUILD LOOP FOR THIS TABLE
    -- Rebuild all indexes belonging to this table (owner SYSADM).
    -- Use ONLINE where possible to reduce blocking; reset PARALLEL afterward.
    ------------------------------------------------------------------
    FOR IDX IN (
      SELECT INDEX_NAME
      FROM   DBA_INDEXES
      WHERE  TABLE_OWNER = 'SYSADM'
      AND    TABLE_NAME  = SEG_TNAME
    )
    LOOP
      BEGIN
        EXECUTE IMMEDIATE 'ALTER INDEX SYSADM.' || IDX.INDEX_NAME || ' REBUILD ONLINE PARALLEL 4';
        EXECUTE IMMEDIATE 'ALTER INDEX SYSADM.' || IDX.INDEX_NAME || ' NOPARALLEL';
        DBMS_OUTPUT.PUT_LINE('  Rebuilt index: ' || IDX.INDEX_NAME);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('  WARNING: Failed rebuilding index ' || IDX.INDEX_NAME || ' — ' || SQLERRM);
      END;
    END LOOP;

    /* ---------------------------------------------------------------- */
    /* BLOCK 9.4: POST-MAINTENANCE SIZE SNAPSHOT                        */
    /* ---------------------------------------------------------------- */
    -- SIZE SNAPSHOT: AFTER
    ------------------------------------------------------------------
    BEGIN
      SELECT NVL(SUM(BYTES),0)/1024/1024
      INTO   POST_MB
      FROM   DBA_SEGMENTS
      WHERE  OWNER        = 'SYSADM'
      AND    SEGMENT_NAME = SEG_TNAME
      AND    SEGMENT_TYPE = 'TABLE';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        POST_MB := 0;
    END;

    DBMS_OUTPUT.PUT_LINE('Size after Shrink of '|| SEG_TNAME|| ' : ' || TO_CHAR(ROUND(POST_MB,2)) || ' MB');
    DBMS_OUTPUT.PUT_LINE('  Delta (MB)      : ' || TO_CHAR(ROUND(POST_MB - PRE_MB,2)));

    -- Next table in the set.
    TBL_KEY := V_DELETED_TABLES.NEXT(TBL_KEY);
  END LOOP;
END;

/* -------------------------------------------------------------------- */
/* BLOCK 10: GLOBAL EXCEPTION HANDLING                                  */
/* -------------------------------------------------------------------- */
-- Top-level exception handler: prints error and stack, then re-raises to honor WHENEVER SQLERROR.
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/