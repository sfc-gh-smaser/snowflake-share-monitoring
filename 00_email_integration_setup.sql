-- =============================================================================
-- Monitor Shares: Email Integration Setup
-- =============================================================================
-- PREREQUISITE: You must create an email notification integration before using this solution
-- Run this ONCE as an ACCOUNTADMIN

USE ROLE ACCOUNTADMIN;

-- Create the email notification integration
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS share_monitoring_integration
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('user1@company.com', 'user2@company.com')  -- Add allowed email addresses
    COMMENT = 'Email integration for share monitoring alerts';

-- Grant usage to the role that will run the tasks
GRANT USAGE ON INTEGRATION share_monitoring_integration TO ROLE SYSADMIN;

-- =============================================================================
-- IMPORTANT NOTES:
-- =============================================================================
-- 1. Update ALLOWED_RECIPIENTS with all email addresses that will receive alerts
-- 2. Update the GRANT statement to grant to the appropriate role
-- 3. Update WAREHOUSE name in tasks if you use a different warehouse than COMPUTE_WH
-- 4. The warehouse must be running or set to auto-resume for tasks to execute
