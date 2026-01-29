<<<<<<< HEAD
set serveroutput on size unlimited
spool c:\temp\export_delete_script_final6.LOG
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
set define on
ttitle off
btitle off
alter session set nls_date_format = 'YYYY-MM-DD HH24:MI:SS';
whenever oserror EXIT failure ROLLBACK
whenever sqlerror EXIT failure ROLLBACK

select instance_name from v$instance;

-- **********************************************************************
-- SQL Script File Name: export_delete_script_final6.SQL
-- **********************************************************************
-- TEST MODE: ROLLBACK instead of COMMIT (see comments)
-- Confidential - Allegis Group, Inc.
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
-- HISTORY:
-- 2025-12-25  Anandmohan Singh  SQL*Plus refactor; test-mode rollbacks
-- 2026-01-06  Linux-friendly; runtime prompts; no default target DB
-- **********************************************************************

-- =========[ Runtime Parameters via command line ]=========
-- Usage:
--   sqlplus sysadm/*******@SERVICE @export_delete_script_final6.SQL <DB_NAME> <START_DATE> <END_DATE>
-- Example:
--   sqlplus sysadm/*******@FSSNDX    @export_delete_script_final6.SQL FSSNDX 2025-12-01 2025-12-31
-- Notes:
--   Dates must be YYYY-MM-DD. End date is inclusive.
--   Parameter positions: &1=DB_NAME, &2=START_DATE, &3=END_DATE

-- Map positional parameters to named defines (so the rest of the block stays untouched)
define p_target_db = '&1'
define p_start_date = '&2'
define p_end_date   = '&3'

-- =========[ Variable Block ]=========
declare
  v_current_db   varchar2(30);
  v_target_db    varchar2(30) := '&p_target_db';

  -- Convert input dates to timestamps at midnight.
  -- End date is inclusive: add 1 day and use < v_end_ts comparison.
  v_start_ts     timestamp := to_timestamp('&p_start_date', 'YYYY-MM-DD');                  -- YYYY-MM-DD 00:00:00
  v_end_ts       timestamp := to_timestamp('&p_end_date',   'YYYY-MM-DD') + interval '1' day; -- (end + 1 day) 00:00:00

  v_sql          varchar2(2000);
  v_rows         pls_integer;
  v_total_rows   pls_integer := 0;

  -- Stop on first error? (kept TRUE as in your test mode)
  c_stop_on_first_error constant boolean := TRUE;

  function safe_tbl(rec_name in varchar2) return varchar2 is
  begin
    return 'PS_' || dbms_assert.simple_sql_name(rec_name);
  end;

  procedure log_error(p_tbl in varchar2, p_id in varchar2, p_batch in number) is
  begin
    dbms_output.put_line(
      'ERROR on '||p_tbl||
      ' (PSARCH_ID='||p_id||', PSARCH_BATCHNUM='||p_batch||'):'||
      chr(10)||'  SQLERRM: '||sqlerrm||
      chr(10)||'  BACKTRACE: '||dbms_utility.format_error_backtrace
    );
  end;
begin
  -- Derive current DB at runtime
  select sys_context('USERENV','DB_NAME') into v_current_db from dual;

  if v_target_db is null then
    raise_application_error(-20000, 'Target DB name is required. Aborting.');
  end if;

  if v_current_db <> v_target_db then
    dbms_output.put_line('ABORT: DB_NAME='||v_current_db||' != target='||v_target_db);
    return;
  end if;

  -- Validate date window (after inclusive adjustment)
  if v_end_ts <= v_start_ts then
    raise_application_error(-20001, 'End date must be the same or after start date.');
  end if;

  dbms_output.put_line('TEST MODE: ROLLBACK enabled, stop_on_first_error='||
                       case when c_stop_on_first_error then 'TRUE' else 'FALSE' end);
  dbms_output.put_line('Window (inclusive dates): '||
                       to_char(v_start_ts,'YYYY-MM-DD')||' .. '||
                       to_char(v_end_ts - interval '1' day,'YYYY-MM-DD'));
  dbms_output.put_line('DB check: current_db='||v_current_db||', target_db='||v_target_db);

  -- Optional cache flush (requires privileges). Comment out if not granted.
  begin
    execute immediate 'alter system flush buffer_cache';
    execute immediate 'alter system flush shared_pool';
  exception
    when others then
      dbms_output.put_line('Note: alter system flush skipped: '||sqlerrm);
  end;

  for r in (
    select /*+ ORDERED */
           distinct a.hist_recname, b.psarch_batchnum, b.psarch_id
      from psarchbatch b
      join psarchtempobj t on b.psarch_id = t.psarch_id
      join psarchobjrec a  on t.psarch_object = a.psarch_object
     where b.psarch_dttm >= v_start_ts
       and b.psarch_dttm <  v_end_ts
  ) loop
    declare
      v_tbl varchar2(128) := safe_tbl(r.hist_recname);
    begin
      savepoint one_row;

      v_sql := 'delete from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';
      execute immediate v_sql using r.psarch_id, r.psarch_batchnum;

      v_rows := sql%rowcount;
      v_total_rows := v_total_rows + nvl(v_rows,0);

      dbms_output.put_line('Deleted |'||v_rows||'| rows from |'||v_tbl||
                           '| for (PSARCH_ID= |'||r.psarch_id||
                           ',| PSARCH_BATCHNUM= |'||r.psarch_batchnum||'|).');

      -- TEST MODE: rollback this iteration
      rollback to savepoint one_row;

    exception
      when others then
        rollback to savepoint one_row;
        log_error(v_tbl, r.psarch_id, r.psarch_batchnum);

        if c_stop_on_first_error then
          raise;
        end if;
    end;
  end loop;

  dbms_output.put_line('TOTAL rows (attempted deletes, rolled back): '||v_total_rows);

  -- TEST MODE: rollback entire session
  rollback;

end;
/
spool off
=======
set serveroutput on size unlimited
spool c:\temp\export_delete_script_final6.LOG
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
set define on
ttitle off
btitle off
alter session set nls_date_format = 'YYYY-MM-DD HH24:MI:SS';
whenever oserror EXIT failure ROLLBACK
whenever sqlerror EXIT failure ROLLBACK

select instance_name from v$instance;

-- **********************************************************************
-- SQL Script File Name: export_delete_script_final6.SQL
-- **********************************************************************
-- TEST MODE: ROLLBACK instead of COMMIT (see comments)
-- Confidential - Allegis Group, Inc.
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
-- HISTORY:
-- 2025-12-25  Anandmohan Singh  SQL*Plus refactor; test-mode rollbacks
-- 2026-01-06  Linux-friendly; runtime prompts; no default target DB
-- **********************************************************************

-- =========[ Runtime Parameters via command line ]=========
-- Usage:
--   sqlplus sysadm/*******@SERVICE @export_delete_script_final6.SQL <DB_NAME> <START_DATE> <END_DATE>
-- Example:
--   sqlplus sysadm/*******@FSSNDX    @export_delete_script_final6.SQL FSSNDX 2025-12-01 2025-12-31
-- Notes:
--   Dates must be YYYY-MM-DD. End date is inclusive.
--   Parameter positions: &1=DB_NAME, &2=START_DATE, &3=END_DATE

-- Map positional parameters to named defines (so the rest of the block stays untouched)
define p_target_db = '&1'
define p_start_date = '&2'
define p_end_date   = '&3'

-- =========[ Variable Block ]=========
declare
  v_current_db   varchar2(30);
  v_target_db    varchar2(30) := '&p_target_db';

  -- Convert input dates to timestamps at midnight.
  -- End date is inclusive: add 1 day and use < v_end_ts comparison.
  v_start_ts     timestamp := to_timestamp('&p_start_date', 'YYYY-MM-DD');                  -- YYYY-MM-DD 00:00:00
  v_end_ts       timestamp := to_timestamp('&p_end_date',   'YYYY-MM-DD') + interval '1' day; -- (end + 1 day) 00:00:00

  v_sql          varchar2(2000);
  v_rows         pls_integer;
  v_total_rows   pls_integer := 0;

  -- Stop on first error? (kept TRUE as in your test mode)
  c_stop_on_first_error constant boolean := TRUE;

  function safe_tbl(rec_name in varchar2) return varchar2 is
  begin
    return 'PS_' || dbms_assert.simple_sql_name(rec_name);
  end;

  procedure log_error(p_tbl in varchar2, p_id in varchar2, p_batch in number) is
  begin
    dbms_output.put_line(
      'ERROR on '||p_tbl||
      ' (PSARCH_ID='||p_id||', PSARCH_BATCHNUM='||p_batch||'):'||
      chr(10)||'  SQLERRM: '||sqlerrm||
      chr(10)||'  BACKTRACE: '||dbms_utility.format_error_backtrace
    );
  end;
begin
  -- Derive current DB at runtime
  select sys_context('USERENV','DB_NAME') into v_current_db from dual;

  if v_target_db is null then
    raise_application_error(-20000, 'Target DB name is required. Aborting.');
  end if;

  if v_current_db <> v_target_db then
    dbms_output.put_line('ABORT: DB_NAME='||v_current_db||' != target='||v_target_db);
    return;
  end if;

  -- Validate date window (after inclusive adjustment)
  if v_end_ts <= v_start_ts then
    raise_application_error(-20001, 'End date must be the same or after start date.');
  end if;

  dbms_output.put_line('TEST MODE: ROLLBACK enabled, stop_on_first_error='||
                       case when c_stop_on_first_error then 'TRUE' else 'FALSE' end);
  dbms_output.put_line('Window (inclusive dates): '||
                       to_char(v_start_ts,'YYYY-MM-DD')||' .. '||
                       to_char(v_end_ts - interval '1' day,'YYYY-MM-DD'));
  dbms_output.put_line('DB check: current_db='||v_current_db||', target_db='||v_target_db);

  -- Optional cache flush (requires privileges). Comment out if not granted.
  begin
    execute immediate 'alter system flush buffer_cache';
    execute immediate 'alter system flush shared_pool';
  exception
    when others then
      dbms_output.put_line('Note: alter system flush skipped: '||sqlerrm);
  end;

  for r in (
    select /*+ ORDERED */
           distinct a.hist_recname, b.psarch_batchnum, b.psarch_id
      from psarchbatch b
      join psarchtempobj t on b.psarch_id = t.psarch_id
      join psarchobjrec a  on t.psarch_object = a.psarch_object
     where b.psarch_dttm >= v_start_ts
       and b.psarch_dttm <  v_end_ts
  ) loop
    declare
      v_tbl varchar2(128) := safe_tbl(r.hist_recname);
    begin
      savepoint one_row;

      v_sql := 'delete from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';
      execute immediate v_sql using r.psarch_id, r.psarch_batchnum;

      v_rows := sql%rowcount;
      v_total_rows := v_total_rows + nvl(v_rows,0);

      dbms_output.put_line('Deleted |'||v_rows||'| rows from |'||v_tbl||
                           '| for (PSARCH_ID= |'||r.psarch_id||
                           ',| PSARCH_BATCHNUM= |'||r.psarch_batchnum||'|).');

      -- TEST MODE: rollback this iteration
      rollback to savepoint one_row;

    exception
      when others then
        rollback to savepoint one_row;
        log_error(v_tbl, r.psarch_id, r.psarch_batchnum);

        if c_stop_on_first_error then
          raise;
        end if;
    end;
  end loop;

  dbms_output.put_line('TOTAL rows (attempted deletes, rolled back): '||v_total_rows);

  -- TEST MODE: rollback entire session
  rollback;

end;
/
spool off
>>>>>>> 265edc523feaf4d8783975ade72c0286a1d86212
