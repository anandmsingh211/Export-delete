<<<<<<< HEAD

spool c:\temp\export_delete_script_final1.LOG
set echo on
set autocommit off
set feedback on
set time on
set timing on
set trimspool on
set pagesize 32767
set linesize 1000
set long 1000
set longchunksize 1000
set define off
ttitle off
btitle off
alter session set nls_date_format = 'YYYY-MM-DD HH24:MI:SS';
whenever oserror EXIT failure ROLLBACK
whenever sqlerror EXIT failure ROLLBACK

SELECT instance_name FROM v$instance;

-- **********************************************************************
-- SQL Script File Name: export_delete_script_final1.SQL
-- **********************************************************************
-- TEST MODE: ROLLBACK instead of COMMIT (see comments)
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
--   Purges PS_* history rows matched via PSARCH tables within a date window.
--   TEST MODE: Uses ROLLBACK in place of COMMIT (see inline comments).
-- **********************************************************************
-- Note: RUN AS SYSADM 
-- *******************************************************************************
-- HISTORY:
-- 12/25/2025    Anandmohan Singh  Reformatted purge script into SQL*Plus style;
--                                               kept ROLLBACKs for testing with commit markers.
-- *******************************************************************************


ALTER SYSTEM FLUSH BUFFER_CACHE;
ALTER SYSTEM FLUSH SHARED_POOL;

DECLARE
  v_target_db    CONSTANT VARCHAR2(30) := 'FSSNDX';
  v_current_db   VARCHAR2(30);

  v_sql          VARCHAR2(2000);

  v_start_ts     CONSTANT TIMESTAMP := TIMESTAMP '2023-05-01 00:00:00';
  v_end_ts       CONSTANT TIMESTAMP := TIMESTAMP '2024-03-02 00:00:00';

  FUNCTION safe_tbl(rec_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'PS_' || DBMS_ASSERT.SIMPLE_SQL_NAME(rec_name);
  END;
BEGIN
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO v_current_db FROM dual;
  IF v_current_db <> v_target_db THEN
    RETURN; -- Abort if wrong DB
  END IF;

  FOR r IN (
    SELECT R.HIST_RECNAME, B.PSARCH_BATCHNUM, B.PSARCH_ID
      FROM PSARCHBATCH B
      JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
      JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
     WHERE B.PSARCH_DTTM >= v_start_ts
       AND B.PSARCH_DTTM <  v_end_ts
  ) LOOP
    DECLARE
      v_tbl VARCHAR2(128) := safe_tbl(r.HIST_RECNAME);
    BEGIN
      SAVEPOINT one_row;

      v_sql := 'DELETE FROM ' || v_tbl || ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

      -- TEST MODE: rollback this iteration
      -- COMMIT; -- <-- In PROD, commit here
      ROLLBACK TO SAVEPOINT one_row;

    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO SAVEPOINT one_row;
    END;
  END LOOP;

  -- TEST MODE: rollback entire session
  -- COMMIT; -- <-- In PROD, final commit here
  ROLLBACK;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
END;
/

ALTER SYSTEM FLUSH BUFFER_CACHE;
ALTER SYSTEM FLUSH SHARED_POOL;

--spool off
=======

spool c:\temp\export_delete_script_final1.LOG
set echo on
set autocommit off
set feedback on
set time on
set timing on
set trimspool on
set pagesize 32767
set linesize 1000
set long 1000
set longchunksize 1000
set define off
ttitle off
btitle off
alter session set nls_date_format = 'YYYY-MM-DD HH24:MI:SS';
whenever oserror EXIT failure ROLLBACK
whenever sqlerror EXIT failure ROLLBACK

SELECT instance_name FROM v$instance;

-- **********************************************************************
-- SQL Script File Name: export_delete_script_final1.SQL
-- **********************************************************************
-- TEST MODE: ROLLBACK instead of COMMIT (see comments)
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
--   Purges PS_* history rows matched via PSARCH tables within a date window.
--   TEST MODE: Uses ROLLBACK in place of COMMIT (see inline comments).
-- **********************************************************************
-- Note: RUN AS SYSADM 
-- *******************************************************************************
-- HISTORY:
-- 12/25/2025    Anandmohan Singh  Reformatted purge script into SQL*Plus style;
--                                               kept ROLLBACKs for testing with commit markers.
-- *******************************************************************************


ALTER SYSTEM FLUSH BUFFER_CACHE;
ALTER SYSTEM FLUSH SHARED_POOL;

DECLARE
  v_target_db    CONSTANT VARCHAR2(30) := 'FSSNDX';
  v_current_db   VARCHAR2(30);

  v_sql          VARCHAR2(2000);

  v_start_ts     CONSTANT TIMESTAMP := TIMESTAMP '2023-05-01 00:00:00';
  v_end_ts       CONSTANT TIMESTAMP := TIMESTAMP '2024-03-02 00:00:00';

  FUNCTION safe_tbl(rec_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'PS_' || DBMS_ASSERT.SIMPLE_SQL_NAME(rec_name);
  END;
BEGIN
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO v_current_db FROM dual;
  IF v_current_db <> v_target_db THEN
    RETURN; -- Abort if wrong DB
  END IF;

  FOR r IN (
    SELECT R.HIST_RECNAME, B.PSARCH_BATCHNUM, B.PSARCH_ID
      FROM PSARCHBATCH B
      JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
      JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
     WHERE B.PSARCH_DTTM >= v_start_ts
       AND B.PSARCH_DTTM <  v_end_ts
  ) LOOP
    DECLARE
      v_tbl VARCHAR2(128) := safe_tbl(r.HIST_RECNAME);
    BEGIN
      SAVEPOINT one_row;

      v_sql := 'DELETE FROM ' || v_tbl || ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

      -- TEST MODE: rollback this iteration
      -- COMMIT; -- <-- In PROD, commit here
      ROLLBACK TO SAVEPOINT one_row;

    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO SAVEPOINT one_row;
    END;
  END LOOP;

  -- TEST MODE: rollback entire session
  -- COMMIT; -- <-- In PROD, final commit here
  ROLLBACK;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
END;
/

ALTER SYSTEM FLUSH BUFFER_CACHE;
ALTER SYSTEM FLUSH SHARED_POOL;

--spool off
>>>>>>> 265edc523feaf4d8783975ade72c0286a1d86212
