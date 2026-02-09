/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
SET SERVEROUTPUT ON SIZE UNLIMITED
spool /backup/exa_ps/dba/PS_Archival/LOG/Del_extra_validation8.LOG
SET ECHO OFF
SET AUTOCOMMIT OFF
SET FEEDBACK OFF
SET TIME ON
SET TIMING ON
SET TRIMSPOOL ON
SET PAGESIZE 0
SET LINESIZE 32767
SET DEFINE ON
SET VERIFY OFF
TTITLE OFF
BTITLE OFF

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- **********************************************************************
-- SQL Script File Name: Del_extra_validation8.SQL
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
--	 Addtitonal Logic added to parse the export log file and compare
--	 exported count with delete count.
--
-- **********************************************************************
-- Note: RUN AS SYSADM USER!
-- *******************************************************************************
-- HISTORY:
-- Date         Name                    Purpose
-- 02/09/2026   Anandmohan Singh        Delete Script with Pre, Post Validation and Log file compare Logic
-- *******************************************************************************

/* --------------------[ PART 1: USER INPUT PROMPTS ]-------------------- */
PROMPT
PROMPT =============================================================
PROMPT   ARCHIVAL DELETION - PARAMETER INPUT
PROMPT =============================================================
PROMPT

-- 1. Database Info
ACCEPT P_TARGET_DB CHAR PROMPT "Enter Oracle Database Name: "

-- 2. Date Range (Format MM/DD/YYYY as per request)
ACCEPT P_START_DATE_IN CHAR PROMPT "Enter Archival Execution- From Date (MM/DD/YYYY): "
ACCEPT P_END_DATE_IN   CHAR PROMPT "Enter Archival Execution- To Date (MM/DD/YYYY): "

-- 3. Archive Info
ACCEPT P_ARCHIVE_YEAR CHAR PROMPT "Enter Archival Year (YYYY/YYYY_YYYY): "
ACCEPT P_ARCHIVE_ENV  CHAR PROMPT "Enter Archival Environment (FS/HR/TE/SE{ALL CAPS}): "

-- 4. Log Directory Info (Must match Oracle Directory Object)
PROMPT
--PROMPT [SYSTEM INFO] Please specify the Oracle Directory Object and Log Filename.
ACCEPT P_LOG_DIR      CHAR PROMPT "Enter Oracle Directory Object Name (e.g., DATAMIN_LOG_DIR): "
ACCEPT P_LOG_FILE     CHAR PROMPT "Enter DataMover Log Filename (e.g., DataMinExports_FSLOG_20251211_230319.out): "

-- 5. Selection Logic
PROMPT
PROMPT Q. Export all &P_ARCHIVE_ENV Templates for &P_ARCHIVE_YEAR executed between &P_START_DATE_IN and &P_END_DATE_IN?
PROMPT
PROMPT 1) Yes
PROMPT 2) No
ACCEPT P_EXPORT_ALL CHAR PROMPT "Enter Selection: "

-- 6. Conditional Template Input
PROMPT
PROMPT * If you selected '2' (No), enter specific Template names separated by commas.
PROMPT * If you selected '1' (Yes), press Enter to skip.
ACCEPT P_TEMPLATE_LIST CHAR PROMPT "Enter Template Names (e.g., TMP1,TMP2): "

/* --------------------[ PART 2: DYNAMIC LOG GENERATION ]-------------------- */
-- Logic: Generate a timestamped log file name similar to the shell script:
-- OUTLOGFILE=$BASEDIR/LOGS/DataMinDelete_${ARCHIVE_ENV}LOG_${OUTLOGDTTM}.out

COLUMN DT_STAMP NEW_VALUE V_DT_STAMP
SELECT TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') AS DT_STAMP FROM DUAL;

COLUMN LOG_FILENAME NEW_VALUE V_LOG_FILENAME
SELECT 'DataMinDelete_' || '&P_ARCHIVE_ENV' || '_LOG_' || '&V_DT_STAMP' || '.log' AS LOG_FILENAME FROM DUAL;

PROMPT
PROMPT =============================================================
PROMPT Spooling output to: &V_LOG_FILENAME
PROMPT =============================================================

-- Start Spooling
SPOOL &V_LOG_FILENAME

/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* 1) CONTEXT VARIABLES */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';
  
  -- Date Conversion (MM/DD/YYYY -> TIMESTAMP)
  V_START_TS   TIMESTAMP := TO_TIMESTAMP('&P_START_DATE_IN', 'MM/DD/YYYY');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP('&P_END_DATE_IN',   'MM/DD/YYYY') + INTERVAL '1' DAY;

  /* Filter Variables for "Select Template" Logic */
  V_EXPORT_ALL_OPT CHAR(1)       := TRIM('&P_EXPORT_ALL');
  V_RAW_LIST       VARCHAR2(4000) := UPPER(TRIM('&P_TEMPLATE_LIST'));
  TYPE T_TEMPLATE_LIST IS TABLE OF BOOLEAN INDEX BY VARCHAR2(100);
  V_FILTER_MAP     T_TEMPLATE_LIST;

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
  
  -- Flag to skip reading rows if template is not in user list
  V_SKIP_TEMPLATE BOOLEAN := FALSE;

  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

  -- Helper Procedure: Parse CSV list into Collection
  PROCEDURE PARSE_TEMPLATE_LIST IS
    V_ITEM VARCHAR2(100);
    V_POS  NUMBER;
    V_TEMP VARCHAR2(4000) := V_RAW_LIST;
  BEGIN
    IF V_TEMP IS NULL THEN RETURN; END IF;
    -- Add trailing comma for easier parsing loop
    IF SUBSTR(V_TEMP, -1) != ',' THEN V_TEMP := V_TEMP || ','; END IF;
    
    LOOP
      V_POS := INSTR(V_TEMP, ',');
      EXIT WHEN V_POS = 0;
      V_ITEM := TRIM(SUBSTR(V_TEMP, 1, V_POS - 1));
      IF V_ITEM IS NOT NULL THEN
        V_FILTER_MAP(V_ITEM) := TRUE;
      END IF;
      V_TEMP := SUBSTR(V_TEMP, V_POS + 1);
    END LOOP;
  END PARSE_TEMPLATE_LIST;

BEGIN
  /* -------------------------------------------------------------------- */
  /* BLOCK 5: DATABASE & INPUT SAFETY CHECKS                              */
  /* Purpose: Ensures we are running against the correct DB and dates.    */
  /* -------------------------------------------------------------------- */
  
  -- A. Parse the filter list if "No" was selected
  IF V_EXPORT_ALL_OPT = '2' THEN
     PARSE_TEMPLATE_LIST;
     DBMS_OUTPUT.PUT_LINE('INFO: Filter Mode = SPECIFIC TEMPLATES ('||V_RAW_LIST||')');
  ELSE
     DBMS_OUTPUT.PUT_LINE('INFO: Filter Mode = ALL TEMPLATES');
  END IF;

  -- B. DB Check
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO V_CURRENT_DB FROM DUAL;
  -- Warning if case mismatch, but generally DB_NAME is usually uppercase
  IF UPPER(V_CURRENT_DB) <> UPPER(V_TARGET_DB) THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: Connected to '||V_CURRENT_DB||' but user input '||V_TARGET_DB);
    -- Uncomment below to enforce strict checking
    -- RAISE_APPLICATION_ERROR(-20001, 'Connected to '||V_CURRENT_DB||' but script expects '||V_TARGET_DB);
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002, 'Invalid date range');
  END IF;

  /* -------------------------------------------------------------------- */
  /* BLOCK 6: LOG FILE PARSING (WITH FILTERING LOGIC)                     */
  /* Purpose: Reads external DataMover log. Only loads counts for         */
  /* templates that match the User's selection.                  */
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
    -- Resolve directory path for display
    BEGIN
      SELECT directory_path INTO V_DIR_PATH
      FROM   ALL_DIRECTORIES
      WHERE  directory_name = UPPER('&P_LOG_DIR');
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
         V_DIR_PATH := 'UNKNOWN/INVALID DIRECTORY OBJECT';
    END;
    DBMS_OUTPUT.PUT_LINE('LOG DIR PATH='||V_DIR_PATH);

    -- Check file presence/size
    UTL_FILE.FGETATTR(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), V_EXISTS, V_FILE_LEN, V_BLKSIZE);
    IF NOT V_EXISTS THEN
      RAISE_APPLICATION_ERROR(-20012, 'Log file not found: '||'&P_LOG_DIR'||'/'||'&P_LOG_FILE');
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
        V_CUR_TEMPLATE := UPPER(TRIM(V_CUR_TEMPLATE));
        
        -- FILTER LOGIC: Decide whether to process this template or skip it
        V_SKIP_TEMPLATE := FALSE;
        IF V_EXPORT_ALL_OPT = '2' AND V_CUR_TEMPLATE IS NOT NULL THEN
            IF NOT V_FILTER_MAP.EXISTS(V_CUR_TEMPLATE) THEN
                V_SKIP_TEMPLATE := TRUE;
            END IF;
        END IF;

        IF V_CUR_TEMPLATE IS NOT NULL THEN
          V_TPL_FOUND := V_TPL_FOUND + 1;
        END IF;
        CONTINUE;
      END IF;

      -- If current template is filtered out, skip to next line
      IF V_SKIP_TEMPLATE THEN
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
        
        -- Safe Map Population
        IF V_EXPECTED_LOG.EXISTS(V_KEY) THEN
            V_EXPECTED_LOG(V_KEY) := V_EXPECTED_LOG(V_KEY) + V_ROWS;
        ELSE
            V_EXPECTED_LOG(V_KEY) := V_ROWS;
        END IF;
        
        V_EXPORT_LINES := V_EXPORT_LINES + 1;
      END IF;
    END LOOP READ_LOOP;

    DBMS_OUTPUT.PUT_LINE('Parse summary: lines='||V_LINES_READ||', templates_found='||V_TPL_FOUND||', export_entries_loaded='||V_EXPORT_LINES);
  END;

  /* -------------------------------------------------------------------- */
  /* BLOCK 7: PROCESS BY UNIT OF WORK (TEMPLATE + TABLE)                  */
  /* Logic: Iterate loaded map, Find Batches, Delete, Validate.           */
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
  DBMS_OUTPUT.PUT_LINE('SUMMARY: total rows deleted='||V_TOTAL_ROWS);
  
  -- !!! PRODUCTION SETTING CHECK !!!
  -- ROLLBACK;  -- Use for Test
  COMMIT;    -- Use for Production

EXCEPTION
  WHEN OTHERS THEN
    -- Final net to print precise failing statement (with line)
    DBMS_OUTPUT.PUT_LINE('MAIN ERROR: '||SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    ROLLBACK;
    RAISE;
END;
/

SPOOL OFF
EXIT