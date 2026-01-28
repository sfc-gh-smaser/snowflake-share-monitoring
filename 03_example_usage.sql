-- =============================================================================
-- Monitor Shares: Example Usage
-- =============================================================================

USE DATABASE UTILITIES;
USE SCHEMA PUBLIC;

-- Example 1: Add a new table/view to monitor
INSERT INTO SHARE_MONITORING (SHARE_DB_NAME, SCHEMA_NAME, TABLE_VIEW_NAME, EMAIL_ADDRESSES)
VALUES ('SHARED_DATA', 'PUBLIC', 'CUSTOMER_ORDERS', 'admin@company.com,analyst@company.com');

-- The Task DAG will automatically:
-- 1. TASK_PROCESS_NEW_MONITORS detects INSERT via stream
-- 2. Creates stream: STREAM_SHARED_DATA_PUBLIC_CUSTOMER_ORDERS
-- 3. Creates serverless task: TASK_SHARED_DATA_PUBLIC_CUSTOMER_ORDERS
-- 4. Sets ACTIVE = TRUE

-- Example 2: Check the status of monitored objects
SELECT 
    ID,
    SHARE_DB_NAME || '.' || SCHEMA_NAME || '.' || TABLE_VIEW_NAME AS MONITORED_OBJECT,
    EMAIL_ADDRESSES,
    ACTIVE,
    STREAM_NAME,
    TASK_NAME,
    LAST_ERROR,
    UPDATED_AT
FROM SHARE_MONITORING
ORDER BY ID;

-- Example 3: Deactivate monitoring (deletes the stream and task)
UPDATE SHARE_MONITORING
SET ACTIVE = FALSE
WHERE SHARE_DB_NAME = 'SHARED_DATA' 
  AND SCHEMA_NAME = 'PUBLIC' 
  AND TABLE_VIEW_NAME = 'CUSTOMER_ORDERS';

-- Example 4: Reactivate monitoring (recreates the stream and task)
UPDATE SHARE_MONITORING
SET ACTIVE = TRUE
WHERE SHARE_DB_NAME = 'SHARED_DATA' 
  AND SCHEMA_NAME = 'PUBLIC' 
  AND TABLE_VIEW_NAME = 'CUSTOMER_ORDERS';

-- Example 5: Check DAG task execution history with return values
SELECT 
    NAME,
    STATE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    RETURN_VALUE,
    ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
WHERE NAME IN ('TASK_PROCESS_NEW_MONITORS', 'TASK_PROCESS_DEACTIVATIONS', 'TASK_PROCESS_REACTIVATIONS')
ORDER BY SCHEDULED_TIME DESC
LIMIT 20;

-- Example 6: Check dynamically created monitoring task history
SELECT 
    NAME,
    STATE,
    SCHEDULED_TIME,
    RETURN_VALUE,
    ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
WHERE NAME LIKE 'TASK_%_%_%'
  AND NAME NOT IN ('TASK_PROCESS_NEW_MONITORS', 'TASK_PROCESS_DEACTIVATIONS', 'TASK_PROCESS_REACTIVATIONS')
ORDER BY SCHEDULED_TIME DESC
LIMIT 20;

-- Example 7: View the DAG structure
SHOW TASKS IN SCHEMA UTILITIES.PUBLIC;
