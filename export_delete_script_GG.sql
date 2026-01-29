SET SERVEROUTPUT ON SIZE UNLIMITED;
SET FEEDBACK OFF;

DECLARE
    v_count        NUMBER := 0;
    v_sql          VARCHAR2(1000);
    v_total_rows   NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('--- ARCHIVE DATA DELETION LOG ---');
    DBMS_OUTPUT.PUT_LINE('Range: 01-May-2023 to 01-Mar-2024');
    DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');

    -- We loop through EVERY record/batch combination found in the metadata
    FOR r IN (
        SELECT 
            R.HIST_RECNAME,
            B.PSARCH_BATCHNUM,
            B.PSARCH_ID,
            B.PSARCH_DTTM
        FROM PSARCHBATCH B
        JOIN PSARCHTEMPOBJ T ON B.PSARCH_ID = T.PSARCH_ID
        JOIN PSARCHOBJREC R  ON T.PSARCH_OBJECT = R.PSARCH_OBJECT
        WHERE B.PSARCH_DTTM >= TO_DATE('2023-05-01', 'YYYY-MM-DD')
          AND B.PSARCH_DTTM <= TO_DATE('2024-03-01', 'YYYY-MM-DD')
        ORDER BY B.PSARCH_DTTM, R.HIST_RECNAME
    ) LOOP

        -- 1. Construct the count query to see what we are about to touch
        v_sql := 'SELECT COUNT(*) FROM ' || r.HIST_RECNAME || 
                 ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
        
        EXECUTE IMMEDIATE v_sql INTO v_count USING r.PSARCH_ID, r.PSARCH_BATCHNUM;

        IF v_count > 0 THEN
            DBMS_OUTPUT.PUT_LINE('BATCH: ' || r.PSARCH_BATCHNUM || 
                                 ' | TABLE: ' || RPAD(r.HIST_RECNAME, 30) || 
                                 ' | ROWS: ' || v_count);
            
            v_total_rows := v_total_rows + v_count;

            /* PHASE 2: ACTUAL DELETION
               Uncomment the lines below only after verifying the counts above.
            */
            -- v_sql := 'DELETE FROM ' || r.HIST_RECNAME || ' WHERE PSARCH_ID = :1 AND PSARCH_BATCHNUM = :2';
            -- EXECUTE IMMEDIATE v_sql USING r.PSARCH_ID, r.PSARCH_BATCHNUM;
            -- COMMIT; -- Committing per table/batch to manage undo logs
        END IF;

    END LOOP;

    DBMS_OUTPUT.PUT_LINE('---------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('TOTAL ROWS PROCESSED: ' || v_total_rows);
    DBMS_OUTPUT.PUT_LINE('PROCESS COMPLETE.');
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR ENCOUNTERED: ' || SQLERRM);
        ROLLBACK;
END;
/