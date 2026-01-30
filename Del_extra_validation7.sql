/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
SET SERVEROUTPUT ON SIZE UNLIMITED
spool /backup/exa_ps/dba/PS_Archival/LOG/Del_extra_validation7.LOG
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
-- SQL Script File Name: Del_extra_validation7.SQL
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
--   VALIDATION LOGIC:
--   This script parses the export log first. It then performs deletions
--   table-by-table. It calculates the TOTAL deleted rows across all 
--   batches for a specific table and compares it to the export log 
--   TOTAL *before* printing the "Deleted" confirmation message.
--
-- **********************************************************************
-- Note: RUN AS SYSADM USER!
-- *******************************************************************************
-- HISTORY:
-- Date         Name                    Purpose
-- 09/01/2026   Anandmohan Singh        Delete Script with Pre-Validation Logic
-- *******************************************************************************

/* --------------------[ PARAMETERS ]-------------------- */
DEFINE P_TARGET_DB = '&1'
DEFINE P_START_DATE = '&2'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_END_DATE   = '&3'   -- YYYY-MM-DD or YYYY/MM/DD
DEFINE P_LOG_DIR    = '&4'
DEFINE P_LOG_FILE   = '&5'

/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* 1) CONTEXT VARIABLES */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';

  V_START_TS   TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_START_DATE','/','-'), 'YYYY-MM-DD');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_END_DATE',  '/','-'), 'YYYY-MM-DD') + INTERVAL '1' DAY;

  /* 2) RECONCILIATION MAPS */
  /* Maps "TEMPLATE|TABLE" -> Total Row Count from Log */
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);
  V_EXPECTED_LOG  T_COUNT_MAP; 
  
  /* 3) OUTPUT BUFFERING */
  /* Stores success messages temporarily until totals are validated */
  TYPE T_OUT_BUFFER IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  V_BATCH_MSGS    T_OUT_BUFFER;

  /* 4) COUNTERS & HELPERS */
  V_TOTAL_ROWS    PLS_INTEGER := 0;
  V_CUR_TEMPLATE  VARCHAR2(64);
  V_LINES_READ    PLS_INTEGER := 0;
  V_TPL_FOUND     PLS_INTEGER := 0;
  V_EXPORT_LINES  PLS_INTEGER := 0;

  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

BEGIN
  /* -------------------------------------------------------------------- */
  /* BLOCK 5: DATABASE & INPUT SAFETY CHECKS                              */
  /* Purpose: Ensures we are running against the correct DB and dates.    */
  /* -------------------------------------------------------------------- */
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  /* -------------------------------------------------------------------- */
  /* BLOCK 6: LOG FILE PARSING                                            */
  /* Purpose: Reads the external DataMover log file line-by-line to       */
  /* populate V_EXPECTED_LOG with the "Source of Truth" counts.           */
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
        IF V_CUR_TEMPLATE IS NOT NULL THEN
          V_TPL_FOUND := V_TPL_FOUND + 1;
        END IF;
        CONTINUE;
      END IF;

      /* Extract table and rows */
      V_TBL := REGEXP_SUBSTR(V_LINE, '"SYSADM"\."(PS_[^"]+)"', 1, 1, NULL, 1);

      IF REGEXP_LIKE(V_LINE, '\s(\d+)\s+rows') THEN
        V_ROWS := TO_NUMBER(REGEXP_SUBSTR(V_LINE, '\s(\d+)\s+rows', 1, 1, NULL, 1));
      ELSE
        V_ROWS := NULL;
      END IF;

      /* Aggregate counts into map */
      IF V_CUR_TEMPLATE IS NOT NULL AND V_TBL IS NOT NULL AND V_ROWS IS NOT NULL THEN
        V_KEY := MK_KEY(V_CUR_TEMPLATE, V_TBL);
        
        -- Safe Map Population (Avoid ORA-01403)
        IF V_EXPECTED_LOG.EXISTS(V_KEY) THEN
            V_EXPECTED_LOG(V_KEY) := V_EXPECTED_LOG(V_KEY) + V_ROWS;
        ELSE
            V_EXPECTED_LOG(V_KEY) := V_ROWS;
        END IF;
        
        V_EXPORT_LINES := V_EXPORT_LINES + 1;
      END IF;
    END LOOP READ_LOOP;

    DBMS_OUTPUT.PUT_LINE('Parse summary: lines='||V_LINES_READ||', templates='||V_TPL_FOUND||', export_entries='||V_EXPORT_LINES);
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 7: PROCESS BY UNIT OF WORK (TEMPLATE + TABLE)                  */
  /* Logic:                                                               */
  /* 1. Iterate through every item found in the Export Log.               */
  /* 2. Find ALL associated batches in the database for that item.        */
  /* 3. Perform deletes and buffer the output messages.                   */
  /* 4. compare TOTAL ACTUAL DELETE vs TOTAL EXPECTED LOG.                */
  /* 5. Only print buffered messages if totals match.                     */
  /* -------------------------------------------------------------------- */
  DECLARE
    K VARCHAR2(400);
    V_TPL_KEY VARCHAR2(64);
    V_TBL_KEY VARCHAR2(128);
    V_PURE_TBL VARCHAR2(128);
    V_EXPECTED_TOTAL PLS_INTEGER;
    V_ACTUAL_TOTAL   PLS_INTEGER;
    
    -- Per-Batch vars
    V_EXP_CNT  PLS_INTEGER;
    V_DEL_CNT  PLS_INTEGER;
    V_POST_CNT PLS_INTEGER;
    
  BEGIN
    K := V_EXPECTED_LOG.FIRST;
    
    WHILE K IS NOT NULL LOOP
      -- A. Parse Key (Format: TEMPLATE|PS_TABLE)
      V_TPL_KEY := SUBSTR(K, 1, INSTR(K, '|') - 1);
      V_TBL_KEY := SUBSTR(K, INSTR(K, '|') + 1);
      -- Extract table name without PS_ prefix for HIST_RECNAME lookup
      V_PURE_TBL := SUBSTR(V_TBL_KEY, 4); 

      V_EXPECTED_TOTAL := V_EXPECTED_LOG(K);
      V_ACTUAL_TOTAL := 0;
      V_BATCH_MSGS.DELETE; -- Clear output buffer for this table

      -- B. Find ALL Batches for this specific Template/Table combination
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
        -- C. Execute Delete for this specific Batch
        BEGIN
          SAVEPOINT ONE_BATCH;
          
          -- Pre-Check: Count before delete
          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_EXP_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          -- Execute Delete
          EXECUTE IMMEDIATE 'DELETE FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;
          
          V_DEL_CNT := SQL%ROWCOUNT;

          -- Post-Check: Verify 0 rows remain
          EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM '||V_TBL_KEY||' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
          INTO V_POST_CNT USING BATCH_REC.PSARCH_ID, BATCH_REC.PSARCH_BATCHNUM;

          -- Local Integrity Check
          IF V_EXP_CNT = V_DEL_CNT AND V_POST_CNT = 0 THEN
             -- BUFFER THE MESSAGE (Do not print yet)
             V_BATCH_MSGS(V_BATCH_MSGS.COUNT+1) := 
               'Deleted |'||V_DEL_CNT||'| rows from |'||V_TBL_KEY||'| for (PSARCH_ID= |'||BATCH_REC.PSARCH_ID||',| PSARCH_BATCHNUM= |'||BATCH_REC.PSARCH_BATCHNUM||'|).';
             
             V_ACTUAL_TOTAL := V_ACTUAL_TOTAL + V_DEL_CNT;
          ELSE
             ROLLBACK TO SAVEPOINT ONE_BATCH;
             RAISE_APPLICATION_ERROR(-20020, 'Local Validation failed for '||V_TBL_KEY||' Batch '||BATCH_REC.PSARCH_BATCHNUM);
          END IF;
        END;
      END LOOP; -- End Batch Loop

      -- D. TOTAL VALIDATION (THE GATEKEEPER)
      -- Check if Sum of all batches equals the Log Expected count
      IF V_ACTUAL_TOTAL = V_EXPECTED_TOTAL THEN
         -- SUCCESS: Print all buffered messages for this table
         IF V_BATCH_MSGS.COUNT > 0 THEN
           FOR i IN V_BATCH_MSGS.FIRST .. V_BATCH_MSGS.LAST LOOP
             DBMS_OUTPUT.PUT_LINE(V_BATCH_MSGS(i));
           END LOOP;
         END IF;
         V_TOTAL_ROWS := V_TOTAL_ROWS + V_ACTUAL_TOTAL;
         
         -- NOTE: To commit table-by-table, uncomment the line below.
         -- COMMIT; 
      ELSE
         -- FAILURE: Mismatch found. Stop everything.
         RAISE_APPLICATION_ERROR(-20031, 
           'EXPORT/DELETE MISMATCH '||K||
           ' Expected='||V_EXPECTED_TOTAL||
           ' Deleted='||V_ACTUAL_TOTAL);
      END IF;

      K := V_EXPECTED_LOG.NEXT(K);
    END LOOP; -- End Table Loop
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 8: FINAL COMMIT / ROLLBACK                                     */
  /* Purpose: Finalizes the transaction.                                  */
  /* Note: Currently set to ROLLBACK for Test Mode. Change to COMMIT      */
  /* when ready for production execution.                                 */
  /* -------------------------------------------------------------------- */
  DBMS_OUTPUT.PUT_LINE('TEST SUMMARY: total rows touched='||V_TOTAL_ROWS||' (all changes rolled back)');
  ROLLBACK; 
  -- COMMIT; -- Switch to this when ready for Production

EXCEPTION
  WHEN OTHERS THEN
    -- Final net to print precise failing statement (with line)
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/