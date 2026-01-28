-- =============================================================================
-- Monitor Shares: Task DAG for Processing Configuration Changes
-- =============================================================================
-- DAG Structure:
--   TASK_PROCESS_NEW_MONITORS (root - stream-triggered)
--       └── TASK_PROCESS_DEACTIVATIONS (runs after parent)
--               └── TASK_PROCESS_REACTIVATIONS (runs after parent)
--
-- No stored procedures required - all logic embedded in tasks
-- Alert throttling: emails only sent if cooldown period has passed
-- Uses USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS instead of SCHEDULE
-- =============================================================================

USE DATABASE UTILITIES;
USE SCHEMA PUBLIC;

-- =============================================================================
-- ROOT TASK: Process new monitor records (INSERTs)
-- Creates streams and tasks for newly added monitoring configurations
-- =============================================================================
CREATE OR REPLACE TASK TASK_PROCESS_NEW_MONITORS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 60
    WHEN SYSTEM$STREAM_HAS_DATA('UTILITIES.PUBLIC.SHARE_MONITORING_STREAM')
AS
DECLARE
    V_STREAM_NAME VARCHAR;
    V_TASK_NAME VARCHAR;
    V_FULL_TABLE_NAME VARCHAR;
    V_SQL VARCHAR;
    V_PROCESSED_COUNT NUMBER DEFAULT 0;
    V_ERROR_COUNT NUMBER DEFAULT 0;
    V_ERRORS VARCHAR DEFAULT '';
BEGIN
    FOR rec IN (
        SELECT ID, SHARE_DB_NAME, SCHEMA_NAME, TABLE_VIEW_NAME, EMAIL_ADDRESSES, ALERT_COOLDOWN_MINUTES
        FROM UTILITIES.PUBLIC.SHARE_MONITORING_STREAM
        WHERE METADATA$ACTION = 'INSERT'
          AND METADATA$ISUPDATE = FALSE
    ) DO
        BEGIN
            V_STREAM_NAME := 'STREAM_' || rec.SHARE_DB_NAME || '_' || rec.SCHEMA_NAME || '_' || rec.TABLE_VIEW_NAME;
            V_TASK_NAME := 'TASK_' || rec.SHARE_DB_NAME || '_' || rec.SCHEMA_NAME || '_' || rec.TABLE_VIEW_NAME;
            V_FULL_TABLE_NAME := rec.SHARE_DB_NAME || '.' || rec.SCHEMA_NAME || '.' || rec.TABLE_VIEW_NAME;
            
            V_SQL := 'CREATE STREAM IF NOT EXISTS UTILITIES.PUBLIC.' || V_STREAM_NAME || 
                     ' ON TABLE ' || V_FULL_TABLE_NAME || ' SHOW_INITIAL_ROWS = FALSE';
            EXECUTE IMMEDIATE V_SQL;
            
            V_SQL := 'CREATE OR REPLACE TASK UTILITIES.PUBLIC.' || V_TASK_NAME || '
                USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = ''XSMALL''
                USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = ' || COALESCE(rec.ALERT_COOLDOWN_MINUTES, 60) * 60 || '
                WHEN SYSTEM$STREAM_HAS_DATA(''UTILITIES.PUBLIC.' || V_STREAM_NAME || ''')
                AS
                DECLARE
                    V_ROW_COUNT NUMBER;
                    V_SUBJECT VARCHAR;
                    V_BODY VARCHAR;
                    V_LAST_ALERT TIMESTAMP_NTZ;
                    V_COOLDOWN NUMBER;
                    V_MINUTES_SINCE_LAST NUMBER;
                BEGIN
                    SELECT COUNT(*) INTO V_ROW_COUNT FROM UTILITIES.PUBLIC.' || V_STREAM_NAME || ';
                    
                    IF (V_ROW_COUNT > 0) THEN
                        SELECT LAST_ALERT_SENT_AT, ALERT_COOLDOWN_MINUTES 
                        INTO V_LAST_ALERT, V_COOLDOWN
                        FROM UTILITIES.PUBLIC.SHARE_MONITORING 
                        WHERE ID = ' || rec.ID || ';
                        
                        V_MINUTES_SINCE_LAST := COALESCE(DATEDIFF(''minute'', V_LAST_ALERT, CURRENT_TIMESTAMP()), V_COOLDOWN + 1);
                        
                        IF (V_MINUTES_SINCE_LAST >= V_COOLDOWN) THEN
                            V_SUBJECT := ''Data Change Alert: ' || V_FULL_TABLE_NAME || ''';
                            V_BODY := ''New or updated data detected in shared table/view: ' || V_FULL_TABLE_NAME || ''' ||
                                      char(10) || char(10) || ''Number of changes: '' || V_ROW_COUNT::VARCHAR ||
                                      char(10) || char(10) || ''Timestamp: '' || CURRENT_TIMESTAMP()::VARCHAR ||
                                      char(10) || char(10) || ''---'' || char(10) || ''Automated alert from Share Monitoring system.'';
                            
                            CALL SYSTEM$SEND_EMAIL(
                                ''share_monitoring_integration'',
                                ''' || rec.EMAIL_ADDRESSES || ''',
                                V_SUBJECT,
                                V_BODY
                            );
                            
                            UPDATE UTILITIES.PUBLIC.SHARE_MONITORING 
                            SET LAST_ALERT_SENT_AT = CURRENT_TIMESTAMP() 
                            WHERE ID = ' || rec.ID || ';
                            
                            SYSTEM$SET_RETURN_VALUE(''SUCCESS: Sent alert for '' || V_ROW_COUNT || '' changes in ' || V_FULL_TABLE_NAME || ''');
                        ELSE
                            SYSTEM$SET_RETURN_VALUE(''SKIPPED: Cooldown active ('' || (V_COOLDOWN - V_MINUTES_SINCE_LAST) || '' min remaining). '' || V_ROW_COUNT || '' changes pending for ' || V_FULL_TABLE_NAME || ''');
                        END IF;
                        
                        CREATE OR REPLACE TEMPORARY TABLE TEMP_CONSUME_' || V_STREAM_NAME || ' AS 
                            SELECT * FROM UTILITIES.PUBLIC.' || V_STREAM_NAME || ';
                    ELSE
                        SYSTEM$SET_RETURN_VALUE(''SUCCESS: No changes to process for ' || V_FULL_TABLE_NAME || ''');
                    END IF;
                EXCEPTION
                    WHEN OTHER THEN
                        SYSTEM$SET_RETURN_VALUE(''ERROR: '' || SQLERRM);
                END';
            EXECUTE IMMEDIATE V_SQL;
            
            V_SQL := 'ALTER TASK UTILITIES.PUBLIC.' || V_TASK_NAME || ' RESUME';
            EXECUTE IMMEDIATE V_SQL;
            
            UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
            SET STREAM_NAME = V_STREAM_NAME,
                TASK_NAME = V_TASK_NAME,
                ACTIVE = TRUE,
                UPDATED_AT = CURRENT_TIMESTAMP(),
                LAST_ERROR = NULL
            WHERE ID = rec.ID;
            
            V_PROCESSED_COUNT := V_PROCESSED_COUNT + 1;
        EXCEPTION
            WHEN OTHER THEN
                V_ERROR_COUNT := V_ERROR_COUNT + 1;
                V_ERRORS := V_ERRORS || 'ID ' || rec.ID || ': ' || SQLERRM || '; ';
                UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
                SET LAST_ERROR = SQLERRM,
                    UPDATED_AT = CURRENT_TIMESTAMP()
                WHERE ID = rec.ID;
        END;
    END FOR;
    
    IF (V_ERROR_COUNT > 0) THEN
        SYSTEM$SET_RETURN_VALUE('COMPLETED WITH ERRORS: Processed=' || V_PROCESSED_COUNT || ', Errors=' || V_ERROR_COUNT || ' | ' || V_ERRORS);
    ELSE
        SYSTEM$SET_RETURN_VALUE('SUCCESS: Created ' || V_PROCESSED_COUNT || ' new monitoring streams/tasks');
    END IF;
END;

-- =============================================================================
-- CHILD TASK 1: Process deactivations (ACTIVE changed to FALSE)
-- Deletes streams and tasks when monitoring is disabled
-- =============================================================================
CREATE OR REPLACE TASK TASK_PROCESS_DEACTIVATIONS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    AFTER UTILITIES.PUBLIC.TASK_PROCESS_NEW_MONITORS
AS
DECLARE
    V_SQL VARCHAR;
    V_PROCESSED_COUNT NUMBER DEFAULT 0;
    V_ERROR_COUNT NUMBER DEFAULT 0;
    V_ERRORS VARCHAR DEFAULT '';
BEGIN
    FOR rec IN (
        SELECT s.ID, m.STREAM_NAME, m.TASK_NAME
        FROM UTILITIES.PUBLIC.SHARE_MONITORING_STREAM s
        JOIN UTILITIES.PUBLIC.SHARE_MONITORING m ON s.ID = m.ID
        WHERE s.METADATA$ACTION = 'INSERT'
          AND s.METADATA$ISUPDATE = TRUE
          AND s.ACTIVE = FALSE
          AND m.STREAM_NAME IS NOT NULL
    ) DO
        BEGIN
            IF (rec.TASK_NAME IS NOT NULL) THEN
                V_SQL := 'ALTER TASK IF EXISTS UTILITIES.PUBLIC.' || rec.TASK_NAME || ' SUSPEND';
                EXECUTE IMMEDIATE V_SQL;
                V_SQL := 'DROP TASK IF EXISTS UTILITIES.PUBLIC.' || rec.TASK_NAME;
                EXECUTE IMMEDIATE V_SQL;
            END IF;
            
            IF (rec.STREAM_NAME IS NOT NULL) THEN
                V_SQL := 'DROP STREAM IF EXISTS UTILITIES.PUBLIC.' || rec.STREAM_NAME;
                EXECUTE IMMEDIATE V_SQL;
            END IF;
            
            UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
            SET STREAM_NAME = NULL,
                TASK_NAME = NULL,
                UPDATED_AT = CURRENT_TIMESTAMP(),
                LAST_ERROR = NULL
            WHERE ID = rec.ID;
            
            V_PROCESSED_COUNT := V_PROCESSED_COUNT + 1;
        EXCEPTION
            WHEN OTHER THEN
                V_ERROR_COUNT := V_ERROR_COUNT + 1;
                V_ERRORS := V_ERRORS || 'ID ' || rec.ID || ': ' || SQLERRM || '; ';
                UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
                SET LAST_ERROR = SQLERRM,
                    UPDATED_AT = CURRENT_TIMESTAMP()
                WHERE ID = rec.ID;
        END;
    END FOR;
    
    IF (V_ERROR_COUNT > 0) THEN
        SYSTEM$SET_RETURN_VALUE('COMPLETED WITH ERRORS: Deactivated=' || V_PROCESSED_COUNT || ', Errors=' || V_ERROR_COUNT || ' | ' || V_ERRORS);
    ELSE
        SYSTEM$SET_RETURN_VALUE('SUCCESS: Deactivated ' || V_PROCESSED_COUNT || ' monitoring streams/tasks');
    END IF;
END;

-- =============================================================================
-- CHILD TASK 2: Process reactivations (ACTIVE changed back to TRUE)
-- Recreates streams and tasks when monitoring is re-enabled
-- =============================================================================
CREATE OR REPLACE TASK TASK_PROCESS_REACTIVATIONS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    AFTER UTILITIES.PUBLIC.TASK_PROCESS_DEACTIVATIONS
AS
DECLARE
    V_STREAM_NAME VARCHAR;
    V_TASK_NAME VARCHAR;
    V_FULL_TABLE_NAME VARCHAR;
    V_SQL VARCHAR;
    V_PROCESSED_COUNT NUMBER DEFAULT 0;
    V_ERROR_COUNT NUMBER DEFAULT 0;
    V_ERRORS VARCHAR DEFAULT '';
BEGIN
    FOR rec IN (
        SELECT s.ID, s.SHARE_DB_NAME, s.SCHEMA_NAME, s.TABLE_VIEW_NAME, s.EMAIL_ADDRESSES, 
               COALESCE(m.ALERT_COOLDOWN_MINUTES, 60) AS ALERT_COOLDOWN_MINUTES
        FROM UTILITIES.PUBLIC.SHARE_MONITORING_STREAM s
        JOIN UTILITIES.PUBLIC.SHARE_MONITORING m ON s.ID = m.ID
        WHERE s.METADATA$ACTION = 'INSERT'
          AND s.METADATA$ISUPDATE = TRUE
          AND s.ACTIVE = TRUE
          AND m.STREAM_NAME IS NULL
    ) DO
        BEGIN
            V_STREAM_NAME := 'STREAM_' || rec.SHARE_DB_NAME || '_' || rec.SCHEMA_NAME || '_' || rec.TABLE_VIEW_NAME;
            V_TASK_NAME := 'TASK_' || rec.SHARE_DB_NAME || '_' || rec.SCHEMA_NAME || '_' || rec.TABLE_VIEW_NAME;
            V_FULL_TABLE_NAME := rec.SHARE_DB_NAME || '.' || rec.SCHEMA_NAME || '.' || rec.TABLE_VIEW_NAME;
            
            V_SQL := 'CREATE STREAM IF NOT EXISTS UTILITIES.PUBLIC.' || V_STREAM_NAME || 
                     ' ON TABLE ' || V_FULL_TABLE_NAME || ' SHOW_INITIAL_ROWS = FALSE';
            EXECUTE IMMEDIATE V_SQL;
            
            V_SQL := 'CREATE OR REPLACE TASK UTILITIES.PUBLIC.' || V_TASK_NAME || '
                USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = ''XSMALL''
                USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = ' || COALESCE(rec.ALERT_COOLDOWN_MINUTES, 60) * 60 || '
                WHEN SYSTEM$STREAM_HAS_DATA(''UTILITIES.PUBLIC.' || V_STREAM_NAME || ''')
                AS
                DECLARE
                    V_ROW_COUNT NUMBER;
                    V_SUBJECT VARCHAR;
                    V_BODY VARCHAR;
                    V_LAST_ALERT TIMESTAMP_NTZ;
                    V_COOLDOWN NUMBER;
                    V_MINUTES_SINCE_LAST NUMBER;
                BEGIN
                    SELECT COUNT(*) INTO V_ROW_COUNT FROM UTILITIES.PUBLIC.' || V_STREAM_NAME || ';
                    
                    IF (V_ROW_COUNT > 0) THEN
                        SELECT LAST_ALERT_SENT_AT, ALERT_COOLDOWN_MINUTES 
                        INTO V_LAST_ALERT, V_COOLDOWN
                        FROM UTILITIES.PUBLIC.SHARE_MONITORING 
                        WHERE ID = ' || rec.ID || ';
                        
                        V_MINUTES_SINCE_LAST := COALESCE(DATEDIFF(''minute'', V_LAST_ALERT, CURRENT_TIMESTAMP()), V_COOLDOWN + 1);
                        
                        IF (V_MINUTES_SINCE_LAST >= V_COOLDOWN) THEN
                            V_SUBJECT := ''Data Change Alert: ' || V_FULL_TABLE_NAME || ''';
                            V_BODY := ''New or updated data detected in shared table/view: ' || V_FULL_TABLE_NAME || ''' ||
                                      char(10) || char(10) || ''Number of changes: '' || V_ROW_COUNT::VARCHAR ||
                                      char(10) || char(10) || ''Timestamp: '' || CURRENT_TIMESTAMP()::VARCHAR ||
                                      char(10) || char(10) || ''---'' || char(10) || ''Automated alert from Share Monitoring system.'';
                            
                            CALL SYSTEM$SEND_EMAIL(
                                ''share_monitoring_integration'',
                                ''' || rec.EMAIL_ADDRESSES || ''',
                                V_SUBJECT,
                                V_BODY
                            );
                            
                            UPDATE UTILITIES.PUBLIC.SHARE_MONITORING 
                            SET LAST_ALERT_SENT_AT = CURRENT_TIMESTAMP() 
                            WHERE ID = ' || rec.ID || ';
                            
                            SYSTEM$SET_RETURN_VALUE(''SUCCESS: Sent alert for '' || V_ROW_COUNT || '' changes in ' || V_FULL_TABLE_NAME || ''');
                        ELSE
                            SYSTEM$SET_RETURN_VALUE(''SKIPPED: Cooldown active ('' || (V_COOLDOWN - V_MINUTES_SINCE_LAST) || '' min remaining). '' || V_ROW_COUNT || '' changes pending for ' || V_FULL_TABLE_NAME || ''');
                        END IF;
                        
                        CREATE OR REPLACE TEMPORARY TABLE TEMP_CONSUME_' || V_STREAM_NAME || ' AS 
                            SELECT * FROM UTILITIES.PUBLIC.' || V_STREAM_NAME || ';
                    ELSE
                        SYSTEM$SET_RETURN_VALUE(''SUCCESS: No changes to process for ' || V_FULL_TABLE_NAME || ''');
                    END IF;
                EXCEPTION
                    WHEN OTHER THEN
                        SYSTEM$SET_RETURN_VALUE(''ERROR: '' || SQLERRM);
                END';
            EXECUTE IMMEDIATE V_SQL;
            
            V_SQL := 'ALTER TASK UTILITIES.PUBLIC.' || V_TASK_NAME || ' RESUME';
            EXECUTE IMMEDIATE V_SQL;
            
            UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
            SET STREAM_NAME = V_STREAM_NAME,
                TASK_NAME = V_TASK_NAME,
                UPDATED_AT = CURRENT_TIMESTAMP(),
                LAST_ERROR = NULL
            WHERE ID = rec.ID;
            
            V_PROCESSED_COUNT := V_PROCESSED_COUNT + 1;
        EXCEPTION
            WHEN OTHER THEN
                V_ERROR_COUNT := V_ERROR_COUNT + 1;
                V_ERRORS := V_ERRORS || 'ID ' || rec.ID || ': ' || SQLERRM || '; ';
                UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
                SET LAST_ERROR = SQLERRM,
                    UPDATED_AT = CURRENT_TIMESTAMP()
                WHERE ID = rec.ID;
        END;
    END FOR;
    
    IF (V_ERROR_COUNT > 0) THEN
        SYSTEM$SET_RETURN_VALUE('COMPLETED WITH ERRORS: Reactivated=' || V_PROCESSED_COUNT || ', Errors=' || V_ERROR_COUNT || ' | ' || V_ERRORS);
    ELSE
        SYSTEM$SET_RETURN_VALUE('SUCCESS: Reactivated ' || V_PROCESSED_COUNT || ' monitoring streams/tasks');
    END IF;
END;

-- =============================================================================
-- Resume the DAG (resume from leaf to root)
-- =============================================================================
ALTER TASK TASK_PROCESS_REACTIVATIONS RESUME;
ALTER TASK TASK_PROCESS_DEACTIVATIONS RESUME;
ALTER TASK TASK_PROCESS_NEW_MONITORS RESUME;
