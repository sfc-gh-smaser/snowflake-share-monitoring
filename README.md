# Share Monitoring Solution

Automated monitoring for Snowflake shared tables and views with email alerts when data changes.

## Quick Start

### Prerequisites
- Snowflake account with ACCOUNTADMIN access (for initial setup)
- **All email recipients must be verified** before they can receive alerts
  - [How to verify email addresses in Snowflake](https://docs.snowflake.com/en/user-guide/email-stored-procedures#verifying-email-addresses)
  - Unverified addresses will cause email delivery to fail silently
- **Data provider must enable Change Tracking** on shared tables/views
  - Streams require change tracking to detect data modifications
  - [How to enable Change Tracking](https://docs.snowflake.com/en/user-guide/streams-manage#enabling-change-tracking-on-views-and-underlying-tables)
  - For tables: `ALTER TABLE <table_name> SET CHANGE_TRACKING = TRUE;`
  - For views: `ALTER VIEW <view_name> SET CHANGE_TRACKING = TRUE;`
  - **Note:** You may need to request your data provider to enable this. Ideally, providers should proactively enable change tracking on all objects included in their data shares.

### Deployment Steps

1. **Run `00_email_integration_setup.sql`** (as ACCOUNTADMIN)
   - Edit the `ALLOWED_RECIPIENTS` list with your email addresses
   - Run the script

2. **Run `01_setup_database.sql`**
   - Creates UTILITIES database and configuration table

3. **Run `02_task_dag.sql`**
   - Creates and starts the monitoring task DAG

4. **Add tables to monitor**
   ```sql
   INSERT INTO UTILITIES.PUBLIC.SHARE_MONITORING 
       (SHARE_DB_NAME, SCHEMA_NAME, TABLE_VIEW_NAME, EMAIL_ADDRESSES)
   VALUES 
       ('MY_DATABASE', 'MY_SCHEMA', 'MY_TABLE', 'user@company.com,admin@company.com');
   ```

That's it! The system will automatically create a stream and task to monitor your table.

---

## How It Works

```
┌────────────────────────────────────────────────────────────────────┐
│  1. Add record to SHARE_MONITORING table                           │
│     (specify database, schema, table, and email recipients)        │
└────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌────────────────────────────────────────────────────────────────────┐
│  2. System automatically, via task, to create:                     │
│     • Stream on your share's view/table (to detect changes)        │
│     • Task (to send email alerts when changes occur)               │
└────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌────────────────────────────────────────────────────────────────────┐
│  3. When data changes in your table:                               │
│     • Task detects changes via stream                              │
│     • Email alert sent to configured recipients                    │
│     • Respects cooldown period to prevent sending multiple emails  │
└────────────────────────────────────────────────────────────────────┘
```

---

## Configuration Options

### Adding a Table to Monitor

```sql
INSERT INTO UTILITIES.PUBLIC.SHARE_MONITORING 
    (SHARE_DB_NAME, SCHEMA_NAME, TABLE_VIEW_NAME, EMAIL_ADDRESSES, ALERT_COOLDOWN_MINUTES)
VALUES 
    ('DATABASE_NAME', 'SCHEMA_NAME', 'TABLE_NAME', 'email1@co.com,email2@co.com', 60);
```

| Column | Required | Default | Description |
|--------|----------|---------|-------------|
| SHARE_DB_NAME          | Yes | -  | Database containing the table to monitor |
| SCHEMA_NAME            | Yes | -  | Schema containing the table to monitor |
| TABLE_VIEW_NAME        | Yes | -  | Table or view name to monitor |
| EMAIL_ADDRESSES.       | Yes | -  | Comma-separated list of email recipients |
| ALERT_COOLDOWN_MINUTES | No  | 60 | Minimum minutes between email alerts |

### Alert Cooldown

The `ALERT_COOLDOWN_MINUTES` setting controls:
1. **Email frequency** - Prevents multiple emails during bulk data loads
2. **Task trigger interval** - Task won't run more often than this value

**Example:** With a 60-minute cooldown:
- Data loaded at 10:00 AM → Email sent at 10:00 AM
- More data loaded at 10:15 AM → No email (cooldown active)
- More data loaded at 10:45 AM → No email (cooldown active)
- Data loaded at 11:05 AM → Email sent (cooldown expired)

---

## Managing Monitored Tables

### View All Monitored Tables
```sql
SELECT 
    SHARE_DB_NAME || '.' || SCHEMA_NAME || '.' || TABLE_VIEW_NAME AS MONITORED_TABLE,
    EMAIL_ADDRESSES,
    ALERT_COOLDOWN_MINUTES,
    ACTIVE,
    LAST_ALERT_SENT_AT,
    LAST_ERROR
FROM UTILITIES.PUBLIC.SHARE_MONITORING;
```

### Pause Monitoring (keeps configuration)
```sql
UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
SET ACTIVE = FALSE
WHERE SHARE_DB_NAME = 'MY_DATABASE' 
  AND SCHEMA_NAME = 'MY_SCHEMA' 
  AND TABLE_VIEW_NAME = 'MY_TABLE';
```

### Resume Monitoring
```sql
UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
SET ACTIVE = TRUE
WHERE SHARE_DB_NAME = 'MY_DATABASE' 
  AND SCHEMA_NAME = 'MY_SCHEMA' 
  AND TABLE_VIEW_NAME = 'MY_TABLE';
```

### Remove Monitoring Completely
```sql
-- First pause to clean up stream/task
UPDATE UTILITIES.PUBLIC.SHARE_MONITORING SET ACTIVE = FALSE WHERE ID = <id>;

-- Then delete the configuration
DELETE FROM UTILITIES.PUBLIC.SHARE_MONITORING WHERE ID = <id>;
```

### Change Email Recipients
```sql
UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
SET EMAIL_ADDRESSES = 'new_user@company.com,another@company.com'
WHERE ID = <id>;
```

### Change Cooldown Period
```sql
UPDATE UTILITIES.PUBLIC.SHARE_MONITORING
SET ALERT_COOLDOWN_MINUTES = 120  -- 2 hours
WHERE ID = <id>;
```

---

## Troubleshooting

### Check Task Execution History
```sql
-- View main DAG task history
SELECT NAME, STATE, SCHEDULED_TIME, RETURN_VALUE, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
WHERE NAME LIKE 'TASK_PROCESS_%'
ORDER BY SCHEDULED_TIME DESC
LIMIT 20;

-- View monitoring task history (per-table tasks)
SELECT NAME, STATE, SCHEDULED_TIME, RETURN_VALUE, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
WHERE NAME LIKE 'TASK_%_%_%'
  AND NAME NOT LIKE 'TASK_PROCESS_%'
ORDER BY SCHEDULED_TIME DESC
LIMIT 20;
```

### Common Return Values

| Return Value | Meaning |
|--------------|---------|
| `SUCCESS: Sent alert for X changes...` | Email sent successfully |
| `SKIPPED: Cooldown active (X min remaining)...` | Email suppressed due to cooldown |
| `SUCCESS: Created X new monitoring streams/tasks` | New monitoring configuration processed |
| `ERROR: ...` | Check the error message for details |

### Check for Configuration Errors
```sql
SELECT * FROM UTILITIES.PUBLIC.SHARE_MONITORING WHERE LAST_ERROR IS NOT NULL;
```

### Verify Tasks Are Running
```sql
SHOW TASKS IN SCHEMA UTILITIES.PUBLIC;
```

---

## Technical Details

### Architecture

- **Serverless tasks** - No warehouse management required
- **Stream-triggered** - Tasks only run when data changes (using `USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS`)
- **Task DAG** - Configuration changes processed by a 3-task DAG:
  - `TASK_PROCESS_NEW_MONITORS` - Creates streams/tasks for new entries
  - `TASK_PROCESS_DEACTIVATIONS` - Cleans up when ACTIVE=FALSE
  - `TASK_PROCESS_REACTIVATIONS` - Recreates when ACTIVE=TRUE

### Naming Convention

For a monitored table `MY_DB.MY_SCHEMA.MY_TABLE`:
- Stream: `STREAM_MY_DB_MY_SCHEMA_MY_TABLE`
- Task: `TASK_MY_DB_MY_SCHEMA_MY_TABLE`

### Full Table Schema

| Column | Type | Description |
|--------|------|-------------|
| ID | NUMBER | Auto-generated unique identifier |
| SHARE_DB_NAME | VARCHAR | Database name |
| SCHEMA_NAME | VARCHAR | Schema name |
| TABLE_VIEW_NAME | VARCHAR | Table or view name |
| EMAIL_ADDRESSES | VARCHAR | Comma-delimited email list |
| ALERT_COOLDOWN_MINUTES | NUMBER | Minutes between alerts (default: 60) |
| ACTIVE | BOOLEAN | Monitoring status |
| STREAM_NAME | VARCHAR | Auto-generated stream name |
| TASK_NAME | VARCHAR | Auto-generated task name |
| LAST_ALERT_SENT_AT | TIMESTAMP | When last email was sent |
| CREATED_AT | TIMESTAMP | Record creation time |
| UPDATED_AT | TIMESTAMP | Last modification time |
| LAST_ERROR | VARCHAR | Last error message (if any) |

---

## Files Included

| File | Purpose |
|------|---------|
| `00_email_integration_setup.sql` | Creates email notification integration (run first) |
| `01_setup_database.sql` | Creates database and configuration table |
| `02_task_dag.sql` | Creates the monitoring task DAG |
| `03_example_usage.sql` | Example queries and operations |

---

## Support

For issues or questions, check:
1. Task history for error messages
2. `LAST_ERROR` column in SHARE_MONITORING table
3. Ensure email addresses are verified ([verification instructions](https://docs.snowflake.com/en/user-guide/email-stored-procedures#verifying-email-addresses))
4. Ensure email addresses are in the ALLOWED_RECIPIENTS list in the notification integration
