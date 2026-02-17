/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
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

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- **********************************************************************
-- SQL Script File Name: export_delete_final1.sql
-- **********************************************************************
-- 
-- Description:
--   1. Parses Data Pump Log to get TOTAL expected rows per Template+Table.
--   2. Sums up actual deletions across ALL batches for that Template+Table.
--   3. Compares the Grand Totals.
--   4. If they match, prints the summary message.
--   5. Post-delete maintenance (MOVE table + REBUILD indexes) is executed
--      ONLY for tables that actually had deletes in this run.
-- **********************************************************************

/* --------------------[ PARAMETERS ]-------------------- */
DEFINE P_TARGET_DB = '&1'
DEFINE P_START_DATE = '&2'   -- MM/DD/YYYY
DEFINE P_END_DATE   = '&3'   -- MM/DD/YYYY
DEFINE P_LOG_DIR    = '&4'
DEFINE P_LOG_FILE   = '&5'
DEFINE P_TEMPLATE_CLAUSE = '&6' 


/* ---------[ Dynamic SPOOL name based ONLY on input params ]--------- */
COLUMN G_STARTDATE NEW_VALUE G_STARTDATE
COLUMN G_ENDDATE   NEW_VALUE G_ENDDATE

SELECT REPLACE('&P_START_DATE','/','') AS G_STARTDATE FROM DUAL;
SELECT REPLACE('&P_END_DATE','/','')   AS G_ENDDATE   FROM DUAL;

SPOOL /backup/exa_ps/dba/PS_ARCHIVAL/LOG/export_delete_final1&P_TARGET_DB._&G_STARTDATE._&G_ENDDATE..LOG


/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* 1) CONTEXT VARIABLES */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';

  V_START_TS   TIMESTAMP := TO_TIMESTAMP('&P_START_DATE', 'MM/DD/YYYY');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP('&P_END_DATE',   'MM/DD/YYYY') + INTERVAL '1' DAY;

  /* 2) RECONCILIATION MAPS */
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  V_EXPECTED_LOG  T_COUNT_MAP; 
  
  /* 2b) TABLES THAT ACTUALLY HAD DELETES (NEW) */
  TYPE T_STR_SET IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(128);
  V_DELETED_TABLES  T_STR_SET;

  /* 3) OUTPUT BUFFERING */
  TYPE T_OUT_BUFFER IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  V_BATCH_MSGS    T_OUT_BUFFER;

  /* 4) COUNTERS AND HELPERS */
  V_TOTAL_ROWS    PLS_INTEGER := 0;
  V_CUR_TEMPLATE  VARCHAR2(64);
  V_LINES_READ    PLS_INTEGER := 0;
  V_TPL_FOUND     PLS_INTEGER := 0;
  V_EXPORT_LINES  PLS_INTEGER := 0;
  
  -- Validation helper
  V_IS_IN_SCOPE   NUMBER;

  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

BEGIN
  /* -------------------------------------------------------------------- */
  /* BLOCK 5: DATABASE AND INPUT SAFETY CHECKS                            */
  /* -------------------------------------------------------------------- */
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  -- FIX 1: Use q'[]' to handle quotes in the display message
  DBMS_OUTPUT.PUT_LINE('Templates selected ' || q'[&P_TEMPLATE_CLAUSE]');

  /* -------------------------------------------------------------------- */
  /* BLOCK 6: LOG FILE PARSING (Loads EVERYTHING from Log)                */
  /* -------------------------------------------------------------------- */
  DECLARE
    F_LOG         UTL_FILE.FILE_TYPE;
    V_LINE        VARCHAR2(32767);
    V_TBL         VARCHAR2(128);
    V_ROWS        PLS_INTEGER;
    V_KEY         VARCHAR2(400);
    V_EXISTS      BOOLEAN;
    V_FILE_LEN    NUMBER;
    V_BLKSIZE     NUMBER;
    V_DIR_PATH    VARCHAR2(1000);
  BEGIN
    -- Resolve directory path
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
    --DBMS_OUTPUT.PUT_LINE('LOG DIR PATH='||V_DIR_PATH);

    -- Check file presence
    UTL_FILE.FGETATTR(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), V_EXISTS, V_FILE_LEN, V_BLKSIZE);
    IF NOT V_EXISTS THEN
      RAISE_APPLICATION_ERROR(-20012, 'Log file not found: '||'&P_LOG_DIR'||'/'||'&P_LOG_FILE');
    END IF;

    F_LOG := UTL_FILE.FOPEN(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), 'R', 32767);

    <<READ_LOOP>>
    LOOP
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

      /* Detect template banner */
      IF REGEXP_LIKE(V_LINE, '^Beginning export of Template\s*:') THEN
        V_CUR_TEMPLATE := REGEXP_SUBSTR(V_LINE, 'Beginning export of Template\s*:\s*(\S+)', 1, 1, NULL, 1);
        CONTINUE;
      END IF;

      /* Extract table and rows */
      V_TBL := REGEXP_SUBSTR(V_LINE, '"SYSADM"\."(PS_[^"]+)"', 1, 1, NULL, 1);

      IF REGEXP_LIKE(V_LINE, '\s(\d+)\s+rows') THEN
        V_ROWS := TO_NUMBER(REGEXP_SUBSTR(V_LINE, '\s(\d+)\s+rows', 1, 1, NULL, 1));
      ELSE
        V_ROWS := NULL;
      END IF;

      IF V_CUR_TEMPLATE IS NOT NULL AND V_TBL IS NOT NULL AND V_ROWS IS NOT NULL THEN
        V_KEY := MK_KEY(V_CUR_TEMPLATE, V_TBL);
        IF V_EXPECTED_LOG.EXISTS(V_KEY) THEN
            V_EXPECTED_LOG(V_KEY) := V_EXPECTED_LOG(V_KEY) + V_ROWS;
        ELSE
            V_EXPECTED_LOG(V_KEY) := V_ROWS;
        END IF;
      END IF;
    END LOOP READ_LOOP;
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 7: PROCESS BY UNIT OF WORK (TEMPLATE + TABLE)                  */
  /* -------------------------------------------------------------------- */
  DECLARE
    K VARCHAR2(400);
    V_TPL_KEY VARCHAR2(64);
    V_TBL_KEY VARCHAR2(128);
    V_PURE_TBL VARCHAR2(128);
    V_EXPECTED_TOTAL PLS_INTEGER;
    V_ACTUAL_TOTAL   PLS_INTEGER;
    
    V_EXP_CNT  PLS_INTEGER;
    V_DEL_CNT  PLS_INTEGER;
    V_POST_CNT PLS_INTEGER;
    
  BEGIN
    K := V_EXPECTED_LOG.FIRST;
    
    WHILE K IS NOT NULL LOOP
      -- A. Parse Key
      V_TPL_KEY := SUBSTR(K, 1, INSTR(K, '|') - 1);
      V_TBL_KEY := SUBSTR(K, INSTR(K, '|') + 1);
      V_PURE_TBL := SUBSTR(V_TBL_KEY, 4); 

      -- B. USER FILTER CHECK
      BEGIN
        -- FIX 2: Use q'[]' to wrap the whole string, preventing quote conflicts
        EXECUTE IMMEDIATE q'[SELECT 1 FROM DUAL WHERE :1 &P_TEMPLATE_CLAUSE]'
        INTO V_IS_IN_SCOPE
        USING V_TPL_KEY;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        V_IS_IN_SCOPE := 0;
      END;

      IF V_IS_IN_SCOPE = 0 THEN
         K := V_EXPECTED_LOG.NEXT(K);
         CONTINUE;
      END IF;
	  
	  DBMS_OUTPUT.PUT_LINE("");
	  DBMS_OUTPUT.PUT_LINE('Starting : '||V_TPL_KEY|| ' ');

      V_EXPECTED_TOTAL := V_EXPECTED_LOG(K);
      V_ACTUAL_TOTAL := 0;
      V_BATCH_MSGS.DELETE;

      -- C. Find Batches (Summing logic)
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
        -- D. Execute Delete (Iterative Summation)
        BEGIN
          SAVEPOINT ONE_BATCH;
          
          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_EXP_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          EXECUTE IMMEDIATE 'DELETE FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;
          
          V_DEL_CNT := SQL%ROWCOUNT;

          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_POST_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          IF V_EXP_CNT = V_DEL_CNT AND V_POST_CNT = 0 THEN
             V_ACTUAL_TOTAL := V_ACTUAL_TOTAL + V_DEL_CNT;
          ELSE
             ROLLBACK TO SAVEPOINT ONE_BATCH;
             RAISE_APPLICATION_ERROR(-20020, 'Local Validation failed for '||V_TBL_KEY||' Batch '||BATCH_REC.PSARCH_BATCHNUM);
          END IF;
        END;
      END LOOP;

      -- E. TOTAL VALIDATION (Compare Summed Batches vs Single Log Entry)
      IF V_ACTUAL_TOTAL = V_EXPECTED_TOTAL THEN
         -- Print consolidated summary
         DBMS_OUTPUT.PUT_LINE(V_ACTUAL_TOTAL || '|rows deleted from |' || V_PURE_TBL || '| record of |' || V_TPL_KEY || '| template.');
         V_TOTAL_ROWS := V_TOTAL_ROWS + V_ACTUAL_TOTAL;

         -- NEW: Record all tables that are selected
        
        V_DELETED_TABLES(V_PURE_TBL) := 1;  -- key is bare PS_* table
        
      ELSE
         RAISE_APPLICATION_ERROR(-20031, 
           'EXPORT/DELETE MISMATCH for '||K||
           ' Expected='||V_EXPECTED_TOTAL||
           ' Deleted='||V_ACTUAL_TOTAL);
      END IF;

      K := V_EXPECTED_LOG.NEXT(K);
    END LOOP;
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 8: FINAL COMMIT / ROLLBACK                                     */
  /* -------------------------------------------------------------------- */
  DBMS_OUTPUT.PUT_LINE('SUMMARY: Total rows processed='||V_TOTAL_ROWS||' (TEST MODE: ROLLED BACK)');
  ROLLBACK; -- TEST MODE
  -- ; -- PRODUCTION MODE

------------------------------------------------------------------------------
-- BLOCK 9
-- POST-DELETE TABLE MOVE + INDEX REBUILD (ONLY TABLES WITH DELETES)
-- Drives from V_DELETED_TABLES (built during the delete loop)
-- NOTE: DDL (MOVE/REBUILD) commits and will NOT roll back, even in TEST MODE.
-- Added: Size snapshot (MB) before and after maintenance per table
------------------------------------------------------------------------------
DECLARE
  TBL_KEY   VARCHAR2(128);
  TBL       VARCHAR2(128);     -- value like 'SOMETHING' (without 'PS_')
  PRE_MB    NUMBER;            -- size (MB) before MOVE
  POST_MB   NUMBER;            -- size (MB) after MOVE + REBUILD
  SEG_TNAME VARCHAR2(128);     -- computed segment table name: 'PS_'||TBL
BEGIN
  TBL_KEY := V_DELETED_TABLES.FIRST;

  IF TBL_KEY IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('Maintenance skipped: no tables had deletes in this run.');
  END IF;

  WHILE TBL_KEY IS NOT NULL LOOP
    TBL := TBL_KEY;                -- bare name like 'SOMETHING'
    SEG_TNAME := 'PS_' || TBL;     -- actual segment/table name
	DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('Starting maintenance for table: ' || SEG_TNAME);

    ------------------------------------------------------------------
    -- SIZE SNAPSHOT: BEFORE
    -- Equivalent to:
    --   SELECT SEGMENT_NAME AS TABLE_NAME, BYTES/1024/1024 AS "SIZE(MB)"
    --   FROM   DBA_SEGMENTS
    --   WHERE  OWNER='SYSADM'
    --   AND    SEGMENT_NAME = <TABLE_NAME>
    --   AND    SEGMENT_TYPE='TABLE'
    --   ORDER BY 1;
    -- Here we SUM(BYTES) to safely cover partitioned tables.
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

    ------------------------------------------------------------------
    -- TABLE MOVE
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

    ------------------------------------------------------------------
    -- INDEX REBUILD LOOP FOR THIS TABLE
    -- NOTE: use TABLE_NAME = SEG_TNAME (e.g., 'PS_SOMETHING')
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

    ------------------------------------------------------------------
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

    TBL_KEY := V_DELETED_TABLES.NEXT(TBL_KEY);
  END LOOP;
END;

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/
