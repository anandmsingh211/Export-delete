/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
SET SERVEROUTPUT ON SIZE UNLIMITED
spool /backup/exa_ps/dba/PS_Archival/LOG/Del_extra_validation11.LOG
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
-- SQL Script File Name: Del_extra_validation11.SQL
-- **********************************************************************
-- 
-- Description:
--   Generic script to delete exported PeopleSoft PS_* history data
--   using PSARCH control tables for a specified date range.
--   Now supports filtering by Specific Templates via Parameter &6.
-- **********************************************************************

/* --------------------[ PARAMETERS ]-------------------- */
DEFINE P_TARGET_DB = '&1'
DEFINE P_START_DATE = '&2'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_END_DATE   = '&3'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_LOG_DIR    = '&4'
DEFINE P_LOG_FILE   = '&5'
DEFINE P_TEMPLATE_CLAUSE = '&6' 

/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* 1) CONTEXT VARIABLES */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';

  V_START_TS   TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_START_DATE','/','-'), 'YYYY-MM-DD');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_END_DATE',  '/','-'), 'YYYY-MM-DD') + INTERVAL '1' DAY;

  /* 2) RECONCILIATION MAPS */
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  V_EXPECTED_LOG  T_COUNT_MAP; 
  
  /* 3) OUTPUT BUFFERING */
  TYPE T_OUT_BUFFER IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  V_BATCH_MSGS    T_OUT_BUFFER;

  /* 4) COUNTERS AND HELPERS */
  -- (Changed '&' to 'AND' above to prevent SQLPlus prompting)
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
  /* (Changed '&' to 'AND' above to prevent SQLPlus prompting)            */
  /* -------------------------------------------------------------------- */
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Filter Applied: PSARCH_ID ' || '&P_TEMPLATE_CLAUSE');

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
    DBMS_OUTPUT.PUT_LINE('LOG DIR PATH='||V_DIR_PATH);

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
      -- We check if V_TPL_KEY matches the user's input (Clause)
      BEGIN
        EXECUTE IMMEDIATE 'SELECT 1 FROM DUAL WHERE :1 ' || '&P_TEMPLATE_CLAUSE'
        INTO V_IS_IN_SCOPE
        USING V_TPL_KEY;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        V_IS_IN_SCOPE := 0;
      END;

      IF V_IS_IN_SCOPE = 0 THEN
         -- Skip this template as it wasn't selected by the user
         K := V_EXPECTED_LOG.NEXT(K);
         CONTINUE;
      END IF;

      -- If we are here, this Template IS in the scope. Proceed with Validation.
      V_EXPECTED_TOTAL := V_EXPECTED_LOG(K);
      V_ACTUAL_TOTAL := 0;
      V_BATCH_MSGS.DELETE;

      -- C. Find Batches (Also applies filter to be safe)
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
        -- D. Execute Delete
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
             V_BATCH_MSGS(V_BATCH_MSGS.COUNT+1) := 
               'Deleted |'||V_DEL_CNT||'| rows from |'||V_TBL_KEY||'| for (PSARCH_ID= |'||BATCH_REC.PSARCH_ID||',| PSARCH_BATCHNUM= |'||BATCH_REC.PSARCH_BATCHNUM||'|).';
             V_ACTUAL_TOTAL := V_ACTUAL_TOTAL + V_DEL_CNT;
          ELSE
             ROLLBACK TO SAVEPOINT ONE_BATCH;
             RAISE_APPLICATION_ERROR(-20020, 'Local Validation failed for '||V_TBL_KEY||' Batch '||BATCH_REC.PSARCH_BATCHNUM);
          END IF;
        END;
      END LOOP;

      -- E. TOTAL VALIDATION
      IF V_ACTUAL_TOTAL = V_EXPECTED_TOTAL THEN
         IF V_BATCH_MSGS.COUNT > 0 THEN
           FOR i IN V_BATCH_MSGS.FIRST .. V_BATCH_MSGS.LAST LOOP
             DBMS_OUTPUT.PUT_LINE(V_BATCH_MSGS(i));
           END LOOP;
         END IF;
         V_TOTAL_ROWS := V_TOTAL_ROWS + V_ACTUAL_TOTAL;
      ELSE
         RAISE_APPLICATION_ERROR(-20031, 
           'DELETE MISMATCH for '||K||
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

EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/