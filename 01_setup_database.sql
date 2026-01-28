-- =============================================================================
-- Monitor Shares: Setup Database and Schema
-- =============================================================================

CREATE DATABASE IF NOT EXISTS UTILITIES;
USE DATABASE UTILITIES;
USE SCHEMA PUBLIC;

-- Create the main monitoring configuration table
CREATE TABLE IF NOT EXISTS SHARE_MONITORING (
    ID NUMBER AUTOINCREMENT PRIMARY KEY,
    SHARE_DB_NAME VARCHAR(255) NOT NULL,
    SCHEMA_NAME VARCHAR(255) NOT NULL,
    TABLE_VIEW_NAME VARCHAR(255) NOT NULL,
    EMAIL_ADDRESSES VARCHAR(4000) NOT NULL COMMENT 'Comma-delimited list of email addresses',
    ALERT_COOLDOWN_MINUTES NUMBER DEFAULT 60 COMMENT 'Minimum minutes between alerts (prevents spam during bulk loads)',
    ACTIVE BOOLEAN DEFAULT FALSE,
    STREAM_NAME VARCHAR(255),
    TASK_NAME VARCHAR(255),
    LAST_ALERT_SENT_AT TIMESTAMP_NTZ COMMENT 'Timestamp of last email alert sent',
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    LAST_ERROR VARCHAR(4000),
    CONSTRAINT UK_MONITORED_OBJECT UNIQUE (SHARE_DB_NAME, SCHEMA_NAME, TABLE_VIEW_NAME)
);

-- Create a stream on the monitoring table to detect changes
CREATE STREAM IF NOT EXISTS SHARE_MONITORING_STREAM ON TABLE SHARE_MONITORING;
