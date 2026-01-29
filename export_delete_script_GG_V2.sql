<<<<<<< HEAD
SET SERVEROUTPUT ON SIZE UNLIMITED;

DECLARE
    -- Logic from Scripts 1-3: Environment Validation
    v_target_db    CONSTANT VARCHAR2(30) := 'FSSNDX'; -- SET YOUR DB NAME HERE
    v_current_db   VARCHAR2(30);
    
    -- Logic from Scripts 2-3: Row Tracking Variables
    v_row_select1  NUMBER := 0; -- Pre-DML Count
    v_row_actual   NUMBER := 0; -- SQL%ROWCOUNT
    v_row_select2  NUMBER := 0; -- Post-DML Validation
    
    v_sql          VARCHAR2(1000);
    v_total_del    NUMBER := 0;

BEGIN
    -- STEP 1: SCHEMA & DB CHECK (From your script descriptions)
    SELECT SYS_CONTEXT('USERENV', 'DB_NAME') INTO v_current_db FROM dual;
    IF v_current_db <> v_target_db THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Script executed on ' || v_current_db || '. Expected ' || v_target_db);
        RETURN; 
    END IF;

    DBMS_OUTPUT.PUT_LINE('Starting Purge: 01-May-2023 to 01-Mar-2024');
    DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');

    -- STEP 2: THE METADATA LOOP (Our specific logic)
    FOR r IN (
        SELECT R.HIST_RECNAME, B.PSARCH_BATCHNUM, B.PSARCH_ID
        FROM PSARCHBATCH B
        JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
        JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
        WHERE B.PSARCH_DTTM >= TO_DATE('2023-05-01', 'YYYY-MM-DD')
          AND B.PSARCH_DTTM <= TO_DATE('2024-03-01', 'YYYY-MM-DD')
    ) LOOP

        -- PRE-DML SELECT (Script 1 & 2 logic)
        v_sql := 'SELECT COUNT(*) FROM ' || r.HIST_RECNAME || 
                 ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
        EXECUTE IMMEDIATE v_sql INTO v_row_select1 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

        IF v_row_select1 > 0 THEN
            -- EXECUTE DELETE (Script 3 logic)
            v_sql := 'DELETE FROM ' || r.HIST_RECNAME || 
                     ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
            EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;
            
            -- CAPTURE AFFECTED ROWS (Script 2 & 3: SQL%ROWCOUNT)
            v_row_actual := SQL%ROWCOUNT;

            -- POST-DML VALIDATION (Script 3: v_row_select2)
            v_sql := 'SELECT COUNT(*) FROM ' || r.HIST_RECNAME || 
                     ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
            EXECUTE IMMEDIATE v_sql INTO v_row_select2 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

            -- STEP 3: CONTROLLED COMMIT (The logic from all 3 scripts)
            IF (v_row_select1 = v_row_actual) AND (v_row_select2 = 0) THEN
                COMMIT; 
                v_total_del := v_total_del + v_row_actual;
                DBMS_OUTPUT.PUT_LINE('[SUCCESS] ' || r.HIST_RECNAME || ' | Batch: ' || r.PSARCH_BATCHNUM || ' | Deleted: ' || v_row_actual);
            ELSE
                ROLLBACK; 
                DBMS_OUTPUT.PUT_LINE('[FAILURE] ' || r.HIST_RECNAME || ' | Mismatch detected. Rolling back.');
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
=======
SET SERVEROUTPUT ON SIZE UNLIMITED;

DECLARE
    -- Logic from Scripts 1-3: Environment Validation
    v_target_db    CONSTANT VARCHAR2(30) := 'FSSNDX'; -- SET YOUR DB NAME HERE
    v_current_db   VARCHAR2(30);
    
    -- Logic from Scripts 2-3: Row Tracking Variables
    v_row_select1  NUMBER := 0; -- Pre-DML Count
    v_row_actual   NUMBER := 0; -- SQL%ROWCOUNT
    v_row_select2  NUMBER := 0; -- Post-DML Validation
    
    v_sql          VARCHAR2(1000);
    v_total_del    NUMBER := 0;

BEGIN
    -- STEP 1: SCHEMA & DB CHECK (From your script descriptions)
    SELECT SYS_CONTEXT('USERENV', 'DB_NAME') INTO v_current_db FROM dual;
    IF v_current_db <> v_target_db THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: Script executed on ' || v_current_db || '. Expected ' || v_target_db);
        RETURN; 
    END IF;

    DBMS_OUTPUT.PUT_LINE('Starting Purge: 01-May-2023 to 01-Mar-2024');
    DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');

    -- STEP 2: THE METADATA LOOP (Our specific logic)
    FOR r IN (
        SELECT R.HIST_RECNAME, B.PSARCH_BATCHNUM, B.PSARCH_ID
        FROM PSARCHBATCH B
        JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
        JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
        WHERE B.PSARCH_DTTM >= TO_DATE('2023-05-01', 'YYYY-MM-DD')
          AND B.PSARCH_DTTM <= TO_DATE('2024-03-01', 'YYYY-MM-DD')
    ) LOOP

        -- PRE-DML SELECT (Script 1 & 2 logic)
        v_sql := 'SELECT COUNT(*) FROM ' || r.HIST_RECNAME || 
                 ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
        EXECUTE IMMEDIATE v_sql INTO v_row_select1 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

        IF v_row_select1 > 0 THEN
            -- EXECUTE DELETE (Script 3 logic)
            v_sql := 'DELETE FROM ' || r.HIST_RECNAME || 
                     ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
            EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;
            
            -- CAPTURE AFFECTED ROWS (Script 2 & 3: SQL%ROWCOUNT)
            v_row_actual := SQL%ROWCOUNT;

            -- POST-DML VALIDATION (Script 3: v_row_select2)
            v_sql := 'SELECT COUNT(*) FROM ' || r.HIST_RECNAME || 
                     ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
            EXECUTE IMMEDIATE v_sql INTO v_row_select2 USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

            -- STEP 3: CONTROLLED COMMIT (The logic from all 3 scripts)
            IF (v_row_select1 = v_row_actual) AND (v_row_select2 = 0) THEN
                COMMIT; 
                v_total_del := v_total_del + v_row_actual;
                DBMS_OUTPUT.PUT_LINE('[SUCCESS] ' || r.HIST_RECNAME || ' | Batch: ' || r.PSARCH_BATCHNUM || ' | Deleted: ' || v_row_actual);
            ELSE
                ROLLBACK; 
                DBMS_OUTPUT.PUT_LINE('[FAILURE] ' || r.HIST_RECNAME || ' | Mismatch detected. Rolling back.');
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
>>>>>>> 265edc523feaf4d8783975ade72c0286a1d86212
/