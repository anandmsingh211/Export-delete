<<<<<<< HEAD
set serveroutput on size unlimited
spool c:\temp\exp_del_val_TE.LOG
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
-- SQL Script File Name: exp_del_val_TE.SQL
-- **********************************************************************
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
--   COMMIT if SELECT count = DELETE rowcount
-- **********************************************************************
-- Note: RUN AS SYSADM
-- HISTORY:
-- 2025-12-25  Anandmohan Singh  SQL*Plus refactor; test-mode rollbacks
-- 2026-01-06  Linux-friendly; runtime prompts; no default target DB
-- **********************************************************************

-- =========[ Runtime Parameters via command line ]=========
-- Usage:
--   sqlplus sysadm/*******@SERVICE @exp_del_val_TE.SQL <DB_NAME> <START_DATE> <END_DATE>
-- Example:
--   sqlplus sysadm/*******@FSSNDX    @exp_del_val_TE.SQL TESNDX 2025-12-01 2025-12-31
-- Notes:
--   Dates must be YYYY-MM-DD. End date is inclusive.
--   Parameter positions: &1=DB_NAME, &2=START_DATE, &3=END_DATE

define p_target_db = '&1'
define p_start_date = '&2'
define p_end_date   = '&3'

-- =========[ Variable Block ]=========
declare
  v_current_db   varchar2(30);
  v_target_db    varchar2(30) := '&p_target_db';

  v_start_ts     timestamp := to_timestamp('&p_start_date','YYYY-MM-DD');
  v_end_ts       timestamp := to_timestamp('&p_end_date','YYYY-MM-DD') + interval '1' day;

  v_sql          varchar2(2000);
  v_rows         pls_integer;
  v_row_select   pls_integer;
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
  select sys_context('USERENV','DB_NAME')
    into v_current_db
    from dual;

  if v_current_db <> v_target_db then
    raise_application_error(
      -20001,
      'ABORT: Connected to '||v_current_db||' but target is '||v_target_db
    );
  end if;

  if v_end_ts <= v_start_ts then
    raise_application_error(-20002,'Invalid date window');
  end if;

  dbms_output.put_line('Execution DB      : '||v_current_db);
  dbms_output.put_line('Date range        : '||
                       to_char(v_start_ts,'YYYY-MM-DD')||' .. '||
                       to_char(v_end_ts - interval '1' day,'YYYY-MM-DD'));

  -- Optional cache flush (requires privileges). Comment out if not granted.
  begin
    execute immediate 'alter system flush buffer_cache';
    execute immediate 'alter system flush shared_pool';
  exception
    when others then
      dbms_output.put_line('Note: alter system flush skipped: '||sqlerrm);
  end;

  for r in (
    select distinct
           a.hist_recname,
           b.psarch_id,
           b.psarch_batchnum
      from psarchbatch b
      join psarchtempobj t on b.psarch_id = t.psarch_id
      join psarchobjrec  a on t.psarch_object = a.psarch_object
     where b.psarch_dttm >= v_start_ts
       and b.psarch_dttm <  v_end_ts
  )
  loop
    declare
      v_tbl varchar2(128) := safe_tbl(r.hist_recname);
    begin
      savepoint one_row;

      ----------------------------------------------------------
      -- SELECT COUNT VALIDATION
      ----------------------------------------------------------
      v_sql := 'select count(*) from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';

      execute immediate v_sql
        into v_row_select
        using r.psarch_id, r.psarch_batchnum;

      ----------------------------------------------------------
      -- DELETE
      ----------------------------------------------------------
      v_sql := 'delete from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';

      execute immediate v_sql
        using r.psarch_id, r.psarch_batchnum;

      v_rows := sql%rowcount;
      v_total_rows := v_total_rows + nvl(v_rows,0);

      ----------------------------------------------------------
      -- COMMIT / ROLLBACK DECISION
      ----------------------------------------------------------
      if v_row_select = v_rows then
        dbms_output.put_line(
          'COMMIT | table='||v_tbl||
          ' | deleted='||v_rows||
          ' | PSARCH_ID='||r.psarch_id||
          ' | BATCH='||r.psarch_batchnum
        );
        rollback to savepoint one_row;
      else
        dbms_output.put_line(
          'ROLLBACK | MISMATCH | table='||v_tbl||
          ' | expected='||v_row_select||
          ' | deleted='||v_rows||
          ' | PSARCH_ID='||r.psarch_id||
          ' | BATCH='||r.psarch_batchnum
        );
        rollback to savepoint one_row;

        if c_stop_on_first_error then
          raise_application_error(
            -20003,
            'Row count validation failed for '||v_tbl
          );
        end if;
      end if;

    exception
      when others then
        rollback to savepoint one_row;
        log_error(v_tbl, r.psarch_id, r.psarch_batchnum);
        if c_stop_on_first_error then
          raise;
        end if;
    end;
  end loop;

  dbms_output.put_line('TOTAL deleted rows committed: '||v_total_rows);

end;
/
spool off
=======
set serveroutput on size unlimited
spool c:\temp\exp_del_val_TE.LOG
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
-- SQL Script File Name: exp_del_val_TE.SQL
-- **********************************************************************
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
--   COMMIT if SELECT count = DELETE rowcount
-- **********************************************************************
-- Note: RUN AS SYSADM
-- HISTORY:
-- 2025-12-25  Anandmohan Singh  SQL*Plus refactor; test-mode rollbacks
-- 2026-01-06  Linux-friendly; runtime prompts; no default target DB
-- **********************************************************************

-- =========[ Runtime Parameters via command line ]=========
-- Usage:
--   sqlplus sysadm/*******@SERVICE @exp_del_val_TE.SQL <DB_NAME> <START_DATE> <END_DATE>
-- Example:
--   sqlplus sysadm/*******@FSSNDX    @exp_del_val_TE.SQL TESNDX 2025-12-01 2025-12-31
-- Notes:
--   Dates must be YYYY-MM-DD. End date is inclusive.
--   Parameter positions: &1=DB_NAME, &2=START_DATE, &3=END_DATE

define p_target_db = '&1'
define p_start_date = '&2'
define p_end_date   = '&3'

-- =========[ Variable Block ]=========
declare
  v_current_db   varchar2(30);
  v_target_db    varchar2(30) := '&p_target_db';

  v_start_ts     timestamp := to_timestamp('&p_start_date','YYYY-MM-DD');
  v_end_ts       timestamp := to_timestamp('&p_end_date','YYYY-MM-DD') + interval '1' day;

  v_sql          varchar2(2000);
  v_rows         pls_integer;
  v_row_select   pls_integer;
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
  select sys_context('USERENV','DB_NAME')
    into v_current_db
    from dual;

  if v_current_db <> v_target_db then
    raise_application_error(
      -20001,
      'ABORT: Connected to '||v_current_db||' but target is '||v_target_db
    );
  end if;

  if v_end_ts <= v_start_ts then
    raise_application_error(-20002,'Invalid date window');
  end if;

  dbms_output.put_line('Execution DB      : '||v_current_db);
  dbms_output.put_line('Date range        : '||
                       to_char(v_start_ts,'YYYY-MM-DD')||' .. '||
                       to_char(v_end_ts - interval '1' day,'YYYY-MM-DD'));

  -- Optional cache flush (requires privileges). Comment out if not granted.
  begin
    execute immediate 'alter system flush buffer_cache';
    execute immediate 'alter system flush shared_pool';
  exception
    when others then
      dbms_output.put_line('Note: alter system flush skipped: '||sqlerrm);
  end;

  for r in (
    select distinct
           a.hist_recname,
           b.psarch_id,
           b.psarch_batchnum
      from psarchbatch b
      join psarchtempobj t on b.psarch_id = t.psarch_id
      join psarchobjrec  a on t.psarch_object = a.psarch_object
     where b.psarch_dttm >= v_start_ts
       and b.psarch_dttm <  v_end_ts
  )
  loop
    declare
      v_tbl varchar2(128) := safe_tbl(r.hist_recname);
    begin
      savepoint one_row;

      ----------------------------------------------------------
      -- SELECT COUNT VALIDATION
      ----------------------------------------------------------
      v_sql := 'select count(*) from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';

      execute immediate v_sql
        into v_row_select
        using r.psarch_id, r.psarch_batchnum;

      ----------------------------------------------------------
      -- DELETE
      ----------------------------------------------------------
      v_sql := 'delete from '||v_tbl||
               ' where psarch_id = :1 and psarch_batchnum = :2';

      execute immediate v_sql
        using r.psarch_id, r.psarch_batchnum;

      v_rows := sql%rowcount;
      v_total_rows := v_total_rows + nvl(v_rows,0);

      ----------------------------------------------------------
      -- COMMIT / ROLLBACK DECISION
      ----------------------------------------------------------
      if v_row_select = v_rows then
        dbms_output.put_line(
          'COMMIT | table='||v_tbl||
          ' | deleted='||v_rows||
          ' | PSARCH_ID='||r.psarch_id||
          ' | BATCH='||r.psarch_batchnum
        );
        rollback to savepoint one_row;
      else
        dbms_output.put_line(
          'ROLLBACK | MISMATCH | table='||v_tbl||
          ' | expected='||v_row_select||
          ' | deleted='||v_rows||
          ' | PSARCH_ID='||r.psarch_id||
          ' | BATCH='||r.psarch_batchnum
        );
        rollback to savepoint one_row;

        if c_stop_on_first_error then
          raise_application_error(
            -20003,
            'Row count validation failed for '||v_tbl
          );
        end if;
      end if;

    exception
      when others then
        rollback to savepoint one_row;
        log_error(v_tbl, r.psarch_id, r.psarch_batchnum);
        if c_stop_on_first_error then
          raise;
        end if;
    end;
  end loop;

  dbms_output.put_line('TOTAL deleted rows committed: '||v_total_rows);

end;
/
spool off
>>>>>>> 265edc523feaf4d8783975ade72c0286a1d86212
