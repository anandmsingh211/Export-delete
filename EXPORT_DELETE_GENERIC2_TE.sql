/* --------------------[ SQL*PLUS SESSION SETUP ]-------------------- */
/* TURN ON PL/SQL OUTPUT BUFFER TO PRINT LINES TO CONSOLE */
SET SERVEROUTPUT ON SIZE UNLIMITED
/* Start spooling all script output (including DBMS_OUTPUT) to a log file.*/
spool c:\temp\EXPORT_DELETE_GENERIC2_TE.LOG
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
-- SQL Script File Name: EXPORT_DELETE_GENERIC2_TE.SQL
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


/* --------------------[ PARAMETERS ]------------------------------ */
/* &1: EXPECTED DATABASE NAME (SAFETY CHECK) */
DEFINE P_TARGET_DB  = '&1'
/* &2: INCLUSIVE START DATE (YYYY-MM-DD) */
DEFINE P_START_DATE = '&2'
/* &3: INCLUSIVE END DATE (YYYY-MM-DD) */
DEFINE P_END_DATE   = '&3'

/* --------------------[ MAIN LOGIC BLOCK ]------------------------ */
DECLARE
  /* CURRENT DATABASE NAME (FROM SESSION CONTEXT) */
  V_CURRENT_DB   VARCHAR2(30);
  /* EXPECTED TARGET DATABASE NAME (FROM PARAMETER) */
  V_TARGET_DB    VARCHAR2(30) := '&P_TARGET_DB';

  /* COMPUTE INCLUSIVE DATE WINDOW:
     START_TS INCLUSIVE; END_TS IS (END_DATE + 1 DAY) SO WE CAN USE "< END_TS" */
  V_START_TS     TIMESTAMP := TO_TIMESTAMP('&P_START_DATE','YYYY-MM-DD');
  V_END_TS       TIMESTAMP := TO_TIMESTAMP('&P_END_DATE','YYYY-MM-DD') + INTERVAL '1' DAY;

  /* REUSABLE DYNAMIC SQL BUFFER */
  V_SQL          VARCHAR2(2000);
  /* COUNTS FOR VALIDATION PER BATCH */
  V_EXP_CNT      PLS_INTEGER;  -- SELECT COUNT(*) BEFORE DELETE
  V_DEL_CNT      PLS_INTEGER;  -- ROWS AFFECTED BY DELETE
  V_ROW_VALIDATE PLS_INTEGER;  -- POST-DELETE VALIDATION COUNT (SHOULD BE 0)
  /* ACCUMULATOR ACROSS ALL BATCHES (FOR A SUMMARY LINE) */
  V_TOTAL_ROWS   PLS_INTEGER := 0;

  /* STOP IMMEDIATELY ON FIRST MISMATCH OR ERROR (SAFETY-FIRST) */
  C_STOP_ON_FIRST_ERROR CONSTANT BOOLEAN := TRUE;

  /* ENSURE TABLE NAME IS SAFE, AND CONSISTENTLY PREFIXED WITH PS_ */
  FUNCTION SAFE_TBL(P_REC IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    /* DBMS_ASSERT.SIMPLE_SQL_NAME VALIDATES IDENTIFIER (PREVENTS INJECTION) */
    RETURN 'PS_' || DBMS_ASSERT.SIMPLE_SQL_NAME(P_REC);
  END;

BEGIN
  /* DETERMINE CURRENT DB NAME FOR SAFETY CHECK AND OUTPUT CONTEXT */
  SELECT SYS_CONTEXT('USERENV','DB_NAME')
    INTO V_CURRENT_DB
    FROM DUAL;

  /* SAFETY: EXIT IF CONNECTED TO A DIFFERENT DB THAN INTENDED */
  IF V_CURRENT_DB <> V_TARGET_DB THEN
    RAISE_APPLICATION_ERROR(
      -20001,
      'CONNECTED TO '||V_CURRENT_DB||' BUT TARGET IS '||V_TARGET_DB
    );
  END IF;

  /* VALIDATE DATE WINDOW (MUST BE NON-EMPTY) */
  IF V_END_TS <= V_START_TS THEN
    RAISE_APPLICATION_ERROR(-20002,'INVALID DATE RANGE');
  END IF;

  /* SIMPLE RUN CONTEXT OUTPUTS (REPLACED HEADER/PRINT_ROW) */
  DBMS_OUTPUT.PUT_LINE('TEST MODE: ROLLBACK enabled, stop_on_first_error='||
                       CASE WHEN C_STOP_ON_FIRST_ERROR THEN 'TRUE' ELSE 'FALSE' END);
  DBMS_OUTPUT.PUT_LINE('Window (inclusive dates): '||
                       TO_CHAR(V_START_TS,'YYYY-MM-DD')||' .. '||
                       TO_CHAR(V_END_TS - INTERVAL '1' DAY,'YYYY-MM-DD'));
  DBMS_OUTPUT.PUT_LINE('DB check: current_db='||V_CURRENT_DB||', target_db='||V_TARGET_DB);

  /* ---------------[ DRIVER CURSOR:
       PULL DISTINCT (HIST_RECNAME, PSARCH_ID, BATCHNUM) IN WINDOW ]--------------- */
  FOR R IN (
    SELECT DISTINCT
           A.HIST_RECNAME,        -- PEOPLESOFT HISTORY RECORD SHORT NAME
           B.PSARCH_ID,           -- ARCHIVE ID
           B.PSARCH_BATCHNUM      -- ARCHIVE BATCH NUMBER
      FROM PSARCHBATCH B
      JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
      JOIN PSARCHOBJREC  A ON T.PSARCH_OBJECT = A.PSARCH_OBJECT
     WHERE B.PSARCH_DTTM >= V_START_TS        -- WINDOW START (INCLUSIVE)
       AND B.PSARCH_DTTM <  V_END_TS          -- WINDOW END (EXCLUSIVE -> INCLUSIVE OF &P_END_DATE)
  )
  LOOP
    DECLARE
      /* CONSTRUCT SECURE, FULLY QUALIFIED TABLE NAME: PS_<HIST_RECNAME> */
      V_TBL VARCHAR2(128) := SAFE_TBL(R.HIST_RECNAME);
      V_ROWS PLS_INTEGER;
    BEGIN
      /* CREATE A SAVEPOINT SO WE CAN SAFELY UNDO PER-BATCH CHANGES */
      SAVEPOINT ONE_BATCH;

      /* ----- PHASE 1: PRE-DELETE EXPECTED COUNT FOR VALIDATION ----- */
      V_SQL := 'SELECT COUNT(*) FROM '||V_TBL||
               ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE V_SQL
        INTO V_EXP_CNT
        USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      /* ----- PHASE 2: ATTEMPT DELETE (WILL BE ROLLED BACK) ----- */
      V_SQL := 'DELETE FROM '||V_TBL||
               ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE V_SQL
        USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      /* CAPTURE IMPACTED ROW COUNT FROM THE DELETE FOR COMPARISON */
      V_DEL_CNT := SQL%ROWCOUNT;
      V_ROWS    := V_DEL_CNT;

      /* ----- ADDITIONAL CHECK AFTER PHASE 2 (AS REQUESTED) -----
         Run a SELECT COUNT(*) over the same filter, ensuring post-delete rows = 0.
         Since we rollback later, this is safe and only for validation. */
      V_SQL := 'SELECT COUNT(*) FROM '||V_TBL||
               ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE V_SQL
        INTO V_ROW_VALIDATE
        USING R.PSARCH_ID, R.PSARCH_BATCHNUM;

      /* TRACK TOTAL ROWS PROCESSED ACROSS ALL BATCHES (FOR SUMMARY) */
      V_TOTAL_ROWS := V_TOTAL_ROWS + NVL(V_DEL_CNT,0);

      /* ----- PHASE 3 & 4: EMIT RESULT AND ROLLBACK PER BRANCH ----- */
      IF V_EXP_CNT = V_DEL_CNT AND V_ROW_VALIDATE = 0 THEN
        /* PERFECT MATCH AND VALIDATION PASSED */
        DBMS_OUTPUT.PUT_LINE('Deleted |'||V_ROWS||'| rows from |'||V_TBL||
                             '| for (PSARCH_ID= |'||R.PSARCH_ID||
                             ',| PSARCH_BATCHNUM= |'||R.PSARCH_BATCHNUM||'|).');
        /* PER-BATCH UNDO: ROLLBACK TO THE SAVEPOINT (INSIDE IF) */
        ROLLBACK TO SAVEPOINT ONE_BATCH;
      ELSE
        /* MISMATCH FOUND: ALERT AND OPTIONALLY STOP RUN */
        DBMS_OUTPUT.PUT_LINE('Deleted |'||V_ROWS||'| rows from |'||V_TBL||
                             '| for (PSARCH_ID= |'||R.PSARCH_ID||
                             ',| PSARCH_BATCHNUM= |'||R.PSARCH_BATCHNUM||
                             '|) BUT validation failed (expected='||NVL(V_EXP_CNT,0)||
                             ', deleted='||NVL(V_DEL_CNT,0)||
                             ', post_delete_count='||NVL(V_ROW_VALIDATE,0)||').');
        /* PER-BATCH UNDO: ROLLBACK TO SAVEPOINT */
        ROLLBACK TO SAVEPOINT ONE_BATCH;

        IF C_STOP_ON_FIRST_ERROR THEN
          /* RAISE A CONTROLLED ERROR TO EXIT THE BLOCK (SQL*PLUS WILL ROLLBACK) */
          RAISE_APPLICATION_ERROR(-20003,'ROWCOUNT/VALIDATION MISMATCH ON '||V_TBL);
        END IF;
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        /* ANY UNEXPECTED ERROR: ENSURE UNDO AND EMIT AN ERROR LINE */
        ROLLBACK TO SAVEPOINT ONE_BATCH;

        DBMS_OUTPUT.PUT_LINE('ERROR while processing table |'||V_TBL||
                             '| for (PSARCH_ID= |'||R.PSARCH_ID||
                             ',| PSARCH_BATCHNUM= |'||R.PSARCH_BATCHNUM||
                             '|): '||SQLERRM);

        IF C_STOP_ON_FIRST_ERROR THEN
          /* RETHROW TO STOP FURTHER PROCESSING */
          RAISE;
        END IF;
    END;
  END LOOP;

  /* FINAL SUMMARY LINE FOR THE ENTIRE RUN (NO DB CHANGES PERSISTED) */
  DBMS_OUTPUT.PUT_LINE('TEST SUMMARY: total rows touched='||NVL(V_TOTAL_ROWS,0)||
                       ' (validation complete; all changes rolled back).');

  /* FINAL FULL-SESSION ROLLBACK (AFTER THE WHOLE RUN COMPLETES) */
  ROLLBACK;

END;
/
