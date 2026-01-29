ALTER SESSION SET CURRENT_SCHEMA=SYSADM;

SET SERVEROUTPUT ON SIZE UNLIMITED;

DECLARE
  v_target_db    CONSTANT VARCHAR2(30) := 'FSLODX'; -- your expected DB
  v_current_db   VARCHAR2(30);

  v_row_select1  NUMBER := 0;
  v_row_actual   NUMBER := 0;
  v_row_select2  NUMBER := 0;

  v_sql          VARCHAR2(1000);
  v_total_del    NUMBER := 0;

  -- safer half-open window
  v_start_ts     CONSTANT TIMESTAMP := TIMESTAMP '2023-05-01 00:00:00';
  v_end_ts       CONSTANT TIMESTAMP := TIMESTAMP '2024-03-02 00:00:00';
BEGIN
  SELECT SYS_CONTEXT('USERENV','DB_NAME') INTO v_current_db FROM dual;

  IF v_current_db <> v_target_db THEN
    DBMS_OUTPUT.PUT_LINE('ERROR: Script executed on ' || v_current_db || '. Expected ' || v_target_db);
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Starting Purge: 01-May-2023 to 01-Mar-2024 (inclusive) on DB '|| v_current_db);
  DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');

  -- pre-count
  DECLARE v_loop_rows NUMBER; BEGIN
    SELECT COUNT(*)
    INTO v_loop_rows
    FROM PSARCHBATCH B
    JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
    JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
    WHERE B.PSARCH_DTTM >= v_start_ts
      AND B.PSARCH_DTTM <  v_end_ts;

    DBMS_OUTPUT.PUT_LINE('Rows eligible for purge loop: ' || v_loop_rows);
  END;

  FOR r IN (
    SELECT R.HIST_RECNAME, B.PSARCH_BATCHNUM, B.PSARCH_ID
    FROM PSARCHBATCH B
    JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
    JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
    WHERE B.PSARCH_DTTM >= v_start_ts
      AND B.PSARCH_DTTM <  v_end_ts
  ) LOOP
  
    --DBMS_OUTPUT.PUT_LINE('Current Rec: ' || r.HIST_RECNAME);
    
    
       /* v_sql := 'SELECT COUNT(*) FROM PS_' || r.HIST_RECNAME ||
         ' WHERE PSARCH_ID=''' || NVL(TO_CHAR(r.PSARCH_ID) ,'[NULL]') ||''' AND '||
    'PSARCH_BATCHNUM=' || NVL(TO_CHAR(r.PSARCH_BATCHNUM), '[NULL]');*/

    
    v_sql := 'SELECT COUNT(*) FROM PS_' || r.HIST_RECNAME ||
             ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
    --DBMS_OUTPUT.PUT_LINE('Current SQL: ' || v_sql);
    
    EXECUTE IMMEDIATE v_sql INTO v_row_select1 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;
    --DBMS_OUTPUT.PUT_LINE('v-row_select1: ' || v_row_select1);
    IF v_row_select1 > 0 THEN
      v_sql := 'DELETE FROM PS_' || r.HIST_RECNAME ||
               ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
               DBMS_OUTPUT.PUT_LINE('Current SQL: ' || v_sql);
      EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;
        DBMS_OUTPUT.PUT_LINE('Next to delete statement');
      v_row_actual := SQL%ROWCOUNT;

      v_sql := 'SELECT COUNT(*) FROM PS_' || r.HIST_RECNAME ||
               ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
      EXECUTE IMMEDIATE v_sql INTO v_row_select2 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

      IF (v_row_select1 = v_row_actual) AND (v_row_select2 = 0) THEN
        ROLLBACK;
        --DBMS_OUTPUT.PUT_LINE('This worked: ');
        v_total_del := v_total_del + v_row_actual;
        DBMS_OUTPUT.PUT_LINE('[SUCCESS] ' || r.HIST_RECNAME ||
                             ' | Batch: ' || r.PSARCH_BATCHNUM ||
                             ' | Deleted: ' || v_row_actual);
      ELSE
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('[FAILURE] ' || r.HIST_RECNAME ||
                             ' | Mismatch detected. Rolling back.');
      END IF;
    END IF;

  END LOOP;

  DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('TOTAL RECORDS PURGED: ' || v_total_del);

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('FATAL SYSTEM ERROR: ' || SQLERRM);
END;
/
