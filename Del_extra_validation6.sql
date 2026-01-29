/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
SET SERVEROUTPUT ON SIZE UNLIMITED
spool /backup/exa_ps/dba/PS_Archival/LOG/Del_extra_validation6.LOG
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
-- SQL Script File Name: Del_extra_validation6.SQL
-- **********************************************************************
-- KEYWORD: ~XX
-- **********************************************************************
--
--               Confidentiality Information:
--
-- This module is the confidential and proprietary information of
-- Allegis Group, Inc.; it is not to be copied, reproduced, or transmitted
-- in any form, by any means, in whole or in part, nor is it to be used
-- for any purpose other than that for which it is expressly provided
-- without the written permission of Allegis Group, Inc.
--
-- Copyright (c) 2002 Allegis Group, Inc. All Rights Reserved
--
-- **********************************************************************
-- Description:
--
--   Generic script to delete exported PeopleSoft PS_* history data
--   using PSARCH control tables for a specified date range.
--
-- **********************************************************************
-- Note: RUN AS SYSADM USER!
-- *******************************************************************************
-- HISTORY:
-- Date         Name                    Purpose
-- 09/01/2026   Anandmohan Singh        Delete Script to remove Exported data from All Env
-- *******************************************************************************

/* --------------------[ PARAMETERS ]-------------------- */
DEFINE P_TARGET_DB = '&1'
DEFINE P_START_DATE = '&2'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_END_DATE   = '&3'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_LOG_DIR    = '&4'
DEFINE P_LOG_FILE   = '&5'

/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* 1) CONTEXT */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';

  V_START_TS   TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_START_DATE','/','-'), 'YYYY-MM-DD');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_END_DATE',  '/','-'), 'YYYY-MM-DD') + INTERVAL '1' DAY;

  /* 2) COUNTERS */
  V_EXP_CNT      PLS_INTEGER;
  V_DEL_CNT      PLS_INTEGER;
  V_POST_CNT     PLS_INTEGER;
  V_TOTAL_ROWS   PLS_INTEGER := 0;

  /* 3) RECONCILIATION MAPS */
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  V_EXPECTED_LOG  T_COUNT_MAP;   -- aggregated expected rows
  V_DELETED_SUM   T_COUNT_MAP;   -- aggregated deletes

  V_CUR_TEMPLATE  VARCHAR2(64);

  /* Diagnostics */
  V_LINES_READ    PLS_INTEGER := 0;
  V_TPL_FOUND     PLS_INTEGER := 0;
  V_EXPORT_LINES  PLS_INTEGER := 0;

  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

  FUNCTION SAFE_TBL(P_REC VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'PS_' || DBMS_ASSERT.SIMPLE_SQL_NAME(P_REC);
  END;

BEGIN
  /* 5) DB SAFETY */
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  /* 6) PARSE EXPORT LOG (HARDENED + INSTRUMENTED) */
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

    -- Check file presence/size
    UTL_FILE.FGETATTR(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), V_EXISTS, V_FILE_LEN, V_BLKSIZE);
    IF NOT V_EXISTS THEN
      RAISE_APPLICATION_ERROR(-20012, 'Log file not found: '||'&P_LOG_DIR'||'/'||'&P_LOG_FILE');
    END IF;
    IF NVL(V_FILE_LEN,0) = 0 THEN
      RAISE_APPLICATION_ERROR(-20013, 'Log file is empty: '||'&P_LOG_FILE');
    END IF;

    -- Open file
    F_LOG := UTL_FILE.FOPEN(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), 'R', 32767);

    -- Read loop
    <<READ_LOOP>>
    LOOP
      BEGIN
        UTL_FILE.GET_LINE(F_LOG, V_LINE);   -- may raise NO_DATA_FOUND at EOF
        V_LINES_READ := V_LINES_READ + 1;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          BEGIN
            UTL_FILE.FCLOSE(F_LOG);
          EXCEPTION WHEN OTHERS THEN NULL; END;
          EXIT READ_LOOP;

        WHEN UTL_FILE.INVALID_OPERATION OR UTL_FILE.READ_ERROR THEN
          BEGIN
            UTL_FILE.FCLOSE(F_LOG);
          EXCEPTION WHEN OTHERS THEN NULL; END;
          RAISE_APPLICATION_ERROR(-20014, 'Read error in log file: '||'&P_LOG_FILE');
      END;

      /* Detect template banner */
      IF REGEXP_LIKE(V_LINE, '^Beginning export of Template\s*:') THEN
        V_CUR_TEMPLATE := REGEXP_SUBSTR(V_LINE, 'Beginning export of Template\s*:\s*(\S+)', 1, 1, NULL, 1);
        IF V_CUR_TEMPLATE IS NOT NULL THEN
          V_TPL_FOUND := V_TPL_FOUND + 1;
        END IF;
        CONTINUE;
      END IF;

      /* Extract table and rows (guarded) */
      V_TBL := REGEXP_SUBSTR(V_LINE, '"SYSADM"\."(PS_[^"]+)"', 1, 1, NULL, 1);

      IF REGEXP_LIKE(V_LINE, '\s(\d+)\s+rows') THEN
        V_ROWS := TO_NUMBER(REGEXP_SUBSTR(V_LINE, '\s(\d+)\s+rows', 1, 1, NULL, 1));
      ELSE
        V_ROWS := NULL;
      END IF;

      /* Aggregate only when all parts exist */
      IF V_CUR_TEMPLATE IS NOT NULL
         AND V_TBL IS NOT NULL
         AND V_ROWS IS NOT NULL
      THEN
        V_KEY := MK_KEY(V_CUR_TEMPLATE, V_TBL);
        
        -- [FIX 1] Check existence before reading to avoid ORA-01403
        IF V_EXPECTED_LOG.EXISTS(V_KEY) THEN
            V_EXPECTED_LOG(V_KEY) := V_EXPECTED_LOG(V_KEY) + V_ROWS;
        ELSE
            V_EXPECTED_LOG(V_KEY) := V_ROWS;
        END IF;
        
        V_EXPORT_LINES := V_EXPORT_LINES + 1;
      END IF;
    END LOOP READ_LOOP;

    DBMS_OUTPUT.PUT_LINE('Parse summary: lines='||V_LINES_READ||', templates='||V_TPL_FOUND||', export_entries='||V_EXPORT_LINES);

    IF V_EXPECTED_LOG.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20010, 'Export log parsed but no row counts detected');
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        UTL_FILE.FCLOSE(F_LOG);
      EXCEPTION WHEN OTHERS THEN NULL; END;
      DBMS_OUTPUT.PUT_LINE('PARSE ERROR: '||SQLERRM);
      DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
      RAISE;
  END;

  /* 6B) PRE-INIT DELETE SUMS FOR ALL KEYS (incl. 0 rows) */
  DECLARE
    K0 VARCHAR2(400);
    INIT_COUNT PLS_INTEGER := 0;
  BEGIN
    K0 := V_EXPECTED_LOG.FIRST;
    WHILE K0 IS NOT NULL LOOP
      -- [FIX 2] Just assign 0. Do not read the key (NVL) because it doesn't exist yet.
      V_DELETED_SUM(K0) := 0;
      
      INIT_COUNT := INIT_COUNT + 1;
      K0 := V_EXPECTED_LOG.NEXT(K0);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Initialized delete-sum keys='||INIT_COUNT);
  END;

  /* 7) MAIN DELETE LOOP (TEST MODE) */
  FOR R IN (
    SELECT DISTINCT
           A.HIST_RECNAME,
           B.PSARCH_ID,
           B.PSARCH_BATCHNUM
    FROM   PSARCHBATCH B
           JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
           JOIN PSARCHOBJREC  A ON T.PSARCH_OBJECT = A.PSARCH_OBJECT
    WHERE  B.PSARCH_DTTM >= V_START_TS
    AND    B.PSARCH_DTTM <  V_END_TS
  )
  LOOP
    DECLARE
      V_TBL VARCHAR2(128) := SAFE_TBL(R.HIST_RECNAME);
      V_KEY VARCHAR2(400);
    BEGIN
      SAVEPOINT ONE_BATCH;

      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM '||V_TBL||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      INTO V_EXP_CNT USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      EXECUTE IMMEDIATE
        'DELETE FROM '||V_TBL||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      V_DEL_CNT := SQL%ROWCOUNT;

      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM '||V_TBL||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      INTO V_POST_CNT USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      V_TOTAL_ROWS := V_TOTAL_ROWS + NVL(V_DEL_CNT,0);

      V_KEY := MK_KEY(R.PSARCH_ID, V_TBL);
      V_DELETED_SUM(V_KEY) := NVL(V_DELETED_SUM(V_KEY),0) + V_DEL_CNT;

      IF V_EXP_CNT = V_DEL_CNT AND V_POST_CNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE('Deleted '||V_DEL_CNT||' rows from '||V_TBL||
                             ' (TEMPLATE='||R.PSARCH_ID||', BATCH='||R.PSARCH_BATCHNUM||')');
        ROLLBACK TO SAVEPOINT ONE_BATCH;  -- test-mode
      ELSE
        ROLLBACK TO SAVEPOINT ONE_BATCH;
        RAISE_APPLICATION_ERROR(-20020,
          'Validation failed for '||V_TBL||
          ' TEMPLATE='||R.PSARCH_ID||
          ' BATCH='||R.PSARCH_BATCHNUM);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('DELETE LOOP ERROR: '||SQLERRM);
        DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        RAISE;
    END;
  END LOOP;

  /* 8) FINAL RECONCILIATION (STRICT, incl. zero-row exports) */
  DECLARE
    K VARCHAR2(400);
    OK_COUNT PLS_INTEGER := 0;
  BEGIN
    K := V_EXPECTED_LOG.FIRST;
    WHILE K IS NOT NULL LOOP
      IF NOT V_DELETED_SUM.EXISTS(K) THEN
        RAISE_APPLICATION_ERROR(-20030, 'Exported object not deleted: '||K);
      END IF;

      IF NVL(V_DELETED_SUM(K),0) <> NVL(V_EXPECTED_LOG(K),0) THEN
        RAISE_APPLICATION_ERROR(-20031,
          'EXPORT/DELETE MISMATCH '||K||
          ' expected='||NVL(V_EXPECTED_LOG(K),0)||
          ' deleted='||NVL(V_DELETED_SUM(K),0));
      END IF;

      OK_COUNT := OK_COUNT + 1;
      DBMS_OUTPUT.PUT_LINE('VALIDATED '||K||' rows='||V_DELETED_SUM(K));
      K := V_EXPECTED_LOG.NEXT(K);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Reconciliation OK count='||OK_COUNT);
  END;

  DBMS_OUTPUT.PUT_LINE('TEST SUMMARY: total rows touched='||V_TOTAL_ROWS||' (all changes rolled back)');
  ROLLBACK;

EXCEPTION
  WHEN OTHERS THEN
    -- Final net to print precise failing statement (with line)
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/