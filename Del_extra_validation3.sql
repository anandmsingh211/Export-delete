/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
/* TURN ON PL/SQL OUTPUT BUFFER TO PRINT LINES TO CONSOLE */
SET SERVEROUTPUT ON SIZE UNLIMITED
/* Start spooling all script output (including DBMS_OUTPUT) to a log file.*/
spool c:\temp\Del_extra_validation3.LOG
/* HIDE SQL STATEMENTS (WE ONLY WANT CLEAN OUTPUT ROWS) */
SET ECHO OFF
/* NEVER AUTO-COMMIT (WE CONTROL TX EXPLICITLY IN PL/SQL) */
SET AUTOCOMMIT OFF
/* HIDE "XX ROWS SELECTED" MESSAGES FOR CLEANER OUTPUT */
SET FEEDBACK OFF
/* USEFUL TIMESTAMPS IN SQL*PLUS CONSOLE (OPTIONAL) */
SET TIME ON
SET TIMING ON
/* AVOID PADDED SPACES IN SPOOLED/OUTPUT LINES */
SET TRIMSPOOL ON
/* NO PAGE BREAKS OR HEADINGS; ONE LINE PER DBMS_OUTPUT ROW */
SET PAGESIZE 0
/* MAXIMIZE LINE WIDTH TO AVOID WRAPPING */
SET LINESIZE 32767
/* ENABLE &-SUBSTITUTION VARIABLES */
SET DEFINE ON
/* DISABLE DEFAULT TITLES/FOOTERS */
TTITLE OFF
BTITLE OFF

/* NORMALIZE DATE FORMATTING IN ANY IMPLICIT DATE OUTPUT */
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

/* EXIT SQL*PLUS ON OS OR SQL ERRORS; ROLLBACK SAFETY */
WHENEVER OSERROR EXIT FAILURE ROLLBACK
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- **********************************************************************
-- SQL Script File Name: Del_extra_validation3.SQL
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
-- /01/2026   Anandmohan Singh        Delete Script to remove Exported data from All Env
-- *******************************************************************************

/* --------------------[ PARAMETERS ]-------------------- */

/* &1: EXPECTED DATABASE NAME (SAFETY CHECK) */
DEFINE P_TARGET_DB = '&1'

/* &2: INCLUSIVE START DATE (YYYY-MM-DD or YYYY/MM/DD) */
DEFINE P_START_DATE = '&2'

/* &3: INCLUSIVE END DATE (YYYY-MM-DD or YYYY/MM/DD) */
DEFINE P_END_DATE = '&3'

/* &4: DIRECTORY OBJECT CONTAINING EXPORT LOG */
DEFINE P_LOG_DIR = '&4'

/* &5: EXPORT LOG FILE NAME */
DEFINE P_LOG_FILE = '&5'


/* --------------------[ MAIN LOGIC BLOCK ]-------------------- */
DECLARE
  /* =======================================================================
     1. RUNTIME CONTEXT AND SAFETY VARIABLES
     ======================================================================= */
  V_CURRENT_DB VARCHAR2(30);
  V_TARGET_DB  VARCHAR2(30) := '&P_TARGET_DB';

  -- Accept '/' or '-' by normalizing to '-'
  V_START_TS   TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_START_DATE','/','-'), 'YYYY-MM-DD');
  V_END_TS     TIMESTAMP := TO_TIMESTAMP(REPLACE('&P_END_DATE',  '/','-'), 'YYYY-MM-DD')
                            + INTERVAL '1' DAY;

  /* =======================================================================
     2. DELETE VALIDATION COUNTERS (PER BATCH)
     ======================================================================= */
  V_SQL          VARCHAR2(2000);
  V_EXP_CNT      PLS_INTEGER;
  V_DEL_CNT      PLS_INTEGER;
  V_POST_CNT     PLS_INTEGER;
  V_TOTAL_ROWS   PLS_INTEGER := 0;

  /* =======================================================================
     3. EXPORT vs DELETE RECONCILIATION STRUCTURES
        - Key = <PSARCH_ID>|<TABLE_NAME>
        - Batch number is intentionally excluded
     ======================================================================= */
  TYPE T_COUNT_MAP IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(400);

  V_EXPECTED_LOG  T_COUNT_MAP;   -- from export log
  V_DELETED_SUM   T_COUNT_MAP;   -- aggregated deletes

  V_CUR_TEMPLATE  VARCHAR2(64);

  FUNCTION MK_KEY(P_TEMPLATE VARCHAR2, P_TABLE VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN P_TEMPLATE || '|' || P_TABLE;
  END;

  /* =======================================================================
     4. SAFE TABLE NAME CONSTRUCTION
     ======================================================================= */
  FUNCTION SAFE_TBL(P_REC VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'PS_' || DBMS_ASSERT.SIMPLE_SQL_NAME(P_REC);
  END;

BEGIN
  /* =======================================================================
     5. DATABASE NAME SAFETY CHECK
     ======================================================================= */
  SELECT SYS_CONTEXT('USERENV','DB_NAME')
  INTO   V_CURRENT_DB
  FROM   DUAL;

  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(
      -20001,
      'Connected to ' || V_CURRENT_DB ||
      ' but script expects ' || V_TARGET_DB
    );
  END IF;

  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002,'Invalid date range');
  END IF;

  /* =======================================================================
     6. EXPORT LOG PARSING (TEMPLATE-LEVEL AGGREGATION) — HARDENED
     ======================================================================= */
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
    -- 6.a: Resolve directory path (ALL_DIRECTORIES; fallback to DBA_DIRECTORIES)
    BEGIN
      SELECT directory_path
      INTO   V_DIR_PATH
      FROM   ALL_DIRECTORIES
      WHERE  directory_name = UPPER('&P_LOG_DIR');
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        SELECT directory_path
        INTO   V_DIR_PATH
        FROM   DBA_DIRECTORIES
        WHERE  directory_name = UPPER('&P_LOG_DIR');
    END;
    DBMS_OUTPUT.PUT_LINE('LOG DIR PATH=' || V_DIR_PATH);

    -- 6.b: Check file existence and size via UTL_FILE.FGETATTR
    UTL_FILE.FGETATTR(
      UPPER('&P_LOG_DIR'),           -- directory name
      TRIM('&P_LOG_FILE'),           -- file name
      V_EXISTS,
      V_FILE_LEN,
      V_BLKSIZE
    );

    IF NOT V_EXISTS THEN
      RAISE_APPLICATION_ERROR(-20012,
        'Log file not found in directory: ' || '&P_LOG_DIR' || '/' || '&P_LOG_FILE');
    END IF;

    IF NVL(V_FILE_LEN,0) = 0 THEN
      RAISE_APPLICATION_ERROR(-20013,
        'Log file is empty: ' || '&P_LOG_FILE');
    END IF;

    -- 6.c: Open the file
    F_LOG := UTL_FILE.FOPEN(UPPER('&P_LOG_DIR'), TRIM('&P_LOG_FILE'), 'R', 32767);

    -- 6.d: Read lines safely
    <<READ_LOOP>>
    LOOP
      BEGIN
        UTL_FILE.GET_LINE(F_LOG, V_LINE);
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          BEGIN
            UTL_FILE.FCLOSE(F_LOG);
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
          EXIT READ_LOOP;
        WHEN UTL_FILE.INVALID_OPERATION OR UTL_FILE.READ_ERROR THEN
          BEGIN
            UTL_FILE.FCLOSE(F_LOG);
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
          RAISE_APPLICATION_ERROR(-20014,
            'Read error or line too long in log file: ' || '&P_LOG_FILE');
      END;

      /* Detect template start (per your log format) */
      IF REGEXP_LIKE(V_LINE,'^Beginning export of Template\s*:') THEN
        V_CUR_TEMPLATE :=
          REGEXP_SUBSTR(
            V_LINE,
            'Beginning export of Template\s*:\s*(\S+)',
            1,1,NULL,1
          );
        CONTINUE;
      END IF;

      /* Extract PeopleSoft table name (per your log format) */
      V_TBL :=
        REGEXP_SUBSTR(
          V_LINE,
          '"SYSADM"\."(PS_[^"]+)"',
          1,1,NULL,1
        );

      /* Extract exported row count (guarded) */
      IF REGEXP_LIKE(V_LINE, '\s(\d+)\s+rows') THEN
        V_ROWS :=
          TO_NUMBER(
            REGEXP_SUBSTR(
              V_LINE,
              '\s(\d+)\s+rows',
              1,1,NULL,1
            )
          );
      ELSE
        V_ROWS := NULL;
      END IF;

      /* Aggregate expected rows by TEMPLATE + TABLE (including zero-row) */
      IF V_CUR_TEMPLATE IS NOT NULL
         AND V_TBL IS NOT NULL
         AND V_ROWS IS NOT NULL
      THEN
        V_KEY := MK_KEY(V_CUR_TEMPLATE, V_TBL);
        V_EXPECTED_LOG(V_KEY) := NVL(V_EXPECTED_LOG(V_KEY),0) + V_ROWS;
      END IF;

    END LOOP READ_LOOP;

    -- If nothing parsed, raise a clear error
    IF V_EXPECTED_LOG.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(
        -20010,
        'Export log parsed but no row counts detected (check format / file content)'
      );
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      BEGIN
        UTL_FILE.FCLOSE(F_LOG);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      RAISE;
  END;

  /* =======================================================================
     6B. PRE-INITIALIZE DELETE SUMS FOR **ALL** EXPECTED KEYS (INCL. 0 ROWS)
     ======================================================================= */
  DECLARE
    K0 VARCHAR2(400);
  BEGIN
    K0 := V_EXPECTED_LOG.FIRST;
    WHILE K0 IS NOT NULL LOOP
      V_DELETED_SUM(K0) := NVL(V_DELETED_SUM(K0), 0);
      K0 := V_EXPECTED_LOG.NEXT(K0);
    END LOOP;
  END;

  /* =======================================================================
     7. MAIN DELETE LOOP (PER TEMPLATE + BATCH)
     ======================================================================= */
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

      /* Pre-delete count */
      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM ' || V_TBL ||
        ' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      INTO V_EXP_CNT
      USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      /* Delete attempt */
      EXECUTE IMMEDIATE
        'DELETE FROM ' || V_TBL ||
        ' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      V_DEL_CNT := SQL%ROWCOUNT;

      /* Post-delete validation */
      EXECUTE IMMEDIATE
        'SELECT COUNT(*) FROM ' || V_TBL ||
        ' WHERE PSARCH_ID=:1 AND PSARCH_BATCHNUM=:2'
      INTO V_POST_CNT
      USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      V_TOTAL_ROWS := V_TOTAL_ROWS + NVL(V_DEL_CNT,0);

      /* Aggregate delete counts by TEMPLATE + TABLE */
      V_KEY := MK_KEY(R.PSARCH_ID, V_TBL);
      V_DELETED_SUM(V_KEY) := NVL(V_DELETED_SUM(V_KEY),0) + V_DEL_CNT;

      IF V_EXP_CNT = V_DEL_CNT AND V_POST_CNT = 0 THEN
        DBMS_OUTPUT.PUT_LINE(
          'Deleted ' || V_DEL_CNT || ' rows from ' || V_TBL ||
          ' (TEMPLATE=' || R.PSARCH_ID ||
          ', BATCH=' || R.PSARCH_BATCHNUM || ')'
        );
        ROLLBACK TO SAVEPOINT ONE_BATCH;  -- test-mode: do not persist
      ELSE
        ROLLBACK TO SAVEPOINT ONE_BATCH;
        RAISE_APPLICATION_ERROR(
          -20020,
          'Validation failed for ' || V_TBL ||
          ' TEMPLATE=' || R.PSARCH_ID ||
          ' BATCH=' || R.PSARCH_BATCHNUM
        );
      END IF;
    END;
  END LOOP;

  /* =======================================================================
     8. FINAL EXPORT vs DELETE RECONCILIATION (STRICT; NO SKIPS)
     ======================================================================= */
  DECLARE
    K VARCHAR2(400);
  BEGIN
    K := V_EXPECTED_LOG.FIRST;
    WHILE K IS NOT NULL LOOP
      IF NOT V_DELETED_SUM.EXISTS(K) THEN
        RAISE_APPLICATION_ERROR(
          -20030,
          'Exported object not deleted: ' || K
        );
      END IF;

      IF NVL(V_DELETED_SUM(K),0) <> NVL(V_EXPECTED_LOG(K),0) THEN
        RAISE_APPLICATION_ERROR(
          -20031,
          'EXPORT/DELETE MISMATCH ' || K ||
          ' expected=' || NVL(V_EXPECTED_LOG(K),0) ||
          ' deleted=' || NVL(V_DELETED_SUM(K),0)
        );
      END IF;

      DBMS_OUTPUT.PUT_LINE('VALIDATED ' || K || ' rows=' || V_DELETED_SUM(K));

      K := V_EXPECTED_LOG.NEXT(K);
    END LOOP;
  END;

  DBMS_OUTPUT.PUT_LINE(
    'TEST SUMMARY: total rows touched=' || V_TOTAL_ROWS || ' (all changes rolled back)'
  );

  ROLLBACK;
END;
/