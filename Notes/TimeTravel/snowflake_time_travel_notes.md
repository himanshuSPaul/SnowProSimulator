# Snowflake Time Travel - Comprehensive Notes
### Based on: https://docs.snowflake.com/en/user-guide/data-time-travel (and all related pages)

---

## Page: Understanding & Using Time Travel
### URL: docs.snowflake.com/en/user-guide/data-time-travel

Time Travel enables accessing historical data that has been changed or deleted, at any point within a defined retention period.

**Three main use cases (as stated in docs):**
- Restoring objects accidentally or intentionally deleted — individual tables or entire schemas/databases
- Duplicating and backing up data from key points in the past
- Analyzing data usage/manipulation over specified time periods

---

### Section: Introduction to Time Travel

**What you can do with Time Travel:**
- Query data that has been updated or deleted (using AT | BEFORE in SELECT)
- Clone entire tables, schemas, or databases at or before a specific point in the past
- Restore dropped tables, schemas, databases, and some other object types

**Important note about schema when querying historical data:**
When querying historical data in a table or non-materialized view, the **current table or view schema is used** — not the schema at the historical point. So if you added a column after the historical timestamp, querying that timestamp will still show the new column (with NULL for old rows). This is easy to misunderstand.

**After the retention period ends:**
- Historical data moves into Fail-safe
- No more querying of historical data
- No more cloning past objects
- No more restoring dropped objects

**Note about long-running queries:**
A long-running Time Travel query will **delay moving data into Fail-safe** for the entire account until the query completes.

---

### Section: Time Travel SQL Extensions

Two SQL extensions added to support Time Travel:

**1. AT | BEFORE clause**
Used in SELECT statements and CREATE ... CLONE commands, placed immediately after the object name.

Three parameters to specify historical point:
- `TIMESTAMP` — exact date and time
- `OFFSET` — time difference in seconds from present (always negative, e.g., -3600 for 1 hour ago)
- `STATEMENT` — query ID of a specific DML statement

**2. UNDROP command**
Restores dropped objects:
- UNDROP TABLE
- UNDROP SCHEMA
- UNDROP DATABASE
- UNDROP NOTEBOOK
- UNDROP ICEBERG TABLE
- UNDROP DYNAMIC TABLE
- UNDROP EXTERNAL VOLUME
- UNDROP TAG
- UNDROP ACCOUNT

---

### Section: Data Retention Period

The core of Time Travel. When data is modified (including deletion or object drop), Snowflake preserves the prior state for the retention period.

**Default:** 1 day (24 hours), automatically enabled for all accounts.

**By edition:**

| Edition | Permanent Tables | Transient/Temporary Tables |
|---|---|---|
| Standard | 0 or 1 day | 0 or 1 day |
| Enterprise (and above) | 0 to 90 days | 0 or 1 day |

Setting DATA_RETENTION_TIME_IN_DAYS = 0 effectively disables Time Travel for that object.

**Relevant parameters:**

`DATA_RETENTION_TIME_IN_DAYS`
- Object-level parameter
- Can be set at account, database, schema, or table level
- ACCOUNTADMIN required to set at account level
- Inherited by child objects that don't have explicit settings

`MIN_DATA_RETENTION_TIME_IN_DAYS`
- Account-level only, ACCOUNTADMIN role required
- Sets a floor (minimum) for the retention period
- Does NOT replace or alter DATA_RETENTION_TIME_IN_DAYS
- Effective retention = MAX(DATA_RETENTION_TIME_IN_DAYS, MIN_DATA_RETENTION_TIME_IN_DAYS)
- Useful for compliance or when you want to ensure no one can accidentally set retention too low

---

### Section: Limitations (What is NOT cloned via Time Travel)

When cloning with AT | BEFORE, these are skipped or not supported:
- **External tables** — not cloned at all
- **Internal (Snowflake) stages** — internal stages are cloned in their current state, regardless of Time Travel point; if the AT/BEFORE point is before the stage existed, stage won't be cloned
- **Hybrid tables** — can be cloned at database level but NOT at schema level
- **User tasks** — tasks are NOT cloned when using CREATE SCHEMA ... CLONE with a timestamp (AT | BEFORE). They ARE cloned when cloning without a timestamp.

Example from docs:
```sql
CREATE SCHEMA S2 CLONE S1 AT(TIMESTAMP => '2025-04-01 12:00:00');
-- Tasks in S1 are NOT included in S2

CREATE SCHEMA S3 CLONE S1;
-- Tasks in S1 ARE included in S3
```

---

### Section: Enabling and Deactivating Time Travel

**Enabling:** Nothing to do. Time Travel is automatically enabled with 1-day retention for all accounts.

**Upgrading retention beyond 1 day:** Requires Enterprise Edition or higher.

**You CANNOT deactivate Time Travel for an entire account.** ACCOUNTADMIN can set account-level DATA_RETENTION_TIME_IN_DAYS = 0 which makes 0 the default for new objects, but individual objects can still override this.

**Deactivating for individual objects:** Set DATA_RETENTION_TIME_IN_DAYS = 0 on that database, schema, or table. However, if MIN_DATA_RETENTION_TIME_IN_DAYS is set at account level and > 0, that minimum wins.

**Warning from docs:**
Before setting retention to 0 for any object, think carefully — if that object is dropped, you won't be able to restore it. Snowflake recommends keeping at least 1 day.

**Background process note:**
When retention is set to 0, modified/deleted data is moved to Fail-safe (permanent tables) or deleted (transient tables) by a background process. This is not immediate. During transition, TIME_TRAVEL_BYTES in storage metrics may temporarily show non-zero even at 0-day retention.

---

### Section: Specifying the Data Retention Period for an Object

Enterprise Edition feature for retention > 1 day.

Setting retention at different levels:
```sql
-- At table creation
CREATE TABLE mytable (col1 NUMBER, col2 DATE) DATA_RETENTION_TIME_IN_DAYS = 90;

-- Alter existing table
ALTER TABLE mytable SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- At database level
CREATE DATABASE mydb DATA_RETENTION_TIME_IN_DAYS = 14;
ALTER DATABASE mydb SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- At schema level
CREATE SCHEMA myschema DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER SCHEMA myschema SET DATA_RETENTION_TIME_IN_DAYS = 3;
```

**Inheritance:** If retention is set at database or schema level, child objects created inside inherit that value unless overridden explicitly.

---

### Section: Checking the Data Retention Period for an Object

Use SHOW commands and look at the `retention_time` column:

```sql
-- Check specific tables
SHOW TABLES
  ->> SELECT "name", "retention_time"
        FROM $1
        WHERE "name" IN ('MY_TABLE1', 'MY_TABLE2');

-- Find schemas with Time Travel turned off
SHOW SCHEMAS
  ->> SELECT "name", "retention_time"
        FROM $1
        WHERE "retention_time" = 0;

-- Find databases with retention > default, including dropped ones
SHOW DATABASES HISTORY
  ->> SELECT "name", "retention_time", "dropped_on"
        FROM $1
        WHERE "retention_time" > 1;
```

For streams, check the `stale_after` column in SHOW STREAMS output.

For derived objects like materialized views, examine the parent table/schema/database retention.

---

### Section: Changing the Data Retention Period for an Object

**Increasing retention:**
- Data currently in Time Travel is kept for the longer period
- Example: 10-day → 20-day means data that would have expired at day 10 is now retained until day 20
- Does NOT apply to data that already moved into Fail-safe

**Decreasing retention:**
- For active data modified after the change: new shorter period applies
- For data currently in Time Travel:
  - If still within new shorter period: stays in Time Travel
  - If outside new shorter period: moves into Fail-safe
- Important: This move to Fail-safe is done by a background process. It is NOT immediate. Until it completes, data is still accessible via Time Travel.
- Example: 10-day → 1-day means days 2–10 move to Fail-safe, only day 1 remains in Time Travel

**Changing database/schema retention only affects active (not dropped) child objects:**
- If you drop a table and it's in Time Travel with 90-day retention, then you change the schema to 1 day — the dropped table's retention does NOT change. It stays at 90 days.
- To change a dropped object's retention: UNDROP it first, ALTER it, then drop again if needed.

**Important inheritance warning:**
Changing retention at account level changes ALL databases/schemas/tables that don't have explicit settings. This can have unintended consequences. Snowflake specifically warns against setting account-level retention to 0.

---

### Section: Dropped Containers and Object Retention Inheritance

This is a caveat/gotcha:

When a **database is dropped**, child schemas or tables have their explicit retention settings IGNORED. They are retained for the same period as the database.

When a **schema is dropped**, child tables have their explicit retention settings IGNORED. They are retained for the same period as the schema.

**Workaround:** If you need child objects to honor their own retention periods, explicitly drop the child objects BEFORE dropping the parent schema or database.

---

### Section: Querying Historical Data

Any DML operation on a table causes Snowflake to retain previous versions. You query them using AT | BEFORE in the FROM clause.

**Full syntax:**
```sql
SELECT ... FROM <table_name>
  { AT | BEFORE }
  ( { TIMESTAMP => <timestamp_expr>
    | OFFSET => <time_difference_in_seconds>
    | STATEMENT => <query_id>
    | STREAM => '<stream_name>'
    } )
```

**AT vs BEFORE:**
- `AT` — inclusive. Returns data at (or including changes from) the specified point.
- `BEFORE` — exclusive. Returns data as it was just BEFORE the specified point. Only STATEMENT is valid with BEFORE (BEFORE with TIMESTAMP or OFFSET is technically supported too but STATEMENT is the main use case).

**Examples from docs:**

Query using timestamp:
```sql
SELECT * FROM my_table AT(TIMESTAMP => 'Wed, 26 Jun 2024 09:20:00 -0700'::timestamp_tz);
```

Query as of 5 minutes ago using offset:
```sql
SELECT * FROM my_table AT(OFFSET => -60*5);
```

Query before a specific statement ran (e.g., to undo a bad DELETE):
```sql
SELECT * FROM my_table BEFORE(STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726');
```

Query using a Unix timestamp (milliseconds):
```sql
SELECT * FROM my_table AT(TIMESTAMP => TO_TIMESTAMP(1432669154242, 3));
```

Filter historical results:
```sql
SELECT * FROM my_table AT(OFFSET => -60*5) AS T WHERE T.flag = 'valid';
```

See what changed by a specific statement (before vs after FULL OUTER JOIN):
```sql
SELECT oldt.*, newt.*
FROM my_table BEFORE(STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726') AS oldt
FULL OUTER JOIN my_table AT(STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726') AS newt
  ON oldt.id = newt.id
WHERE oldt.id IS NULL OR newt.id IS NULL;
```

**Error handling:** If TIMESTAMP, OFFSET, or STATEMENT is outside the retention period, the query fails with an error.

---

### Section: AT | BEFORE — Timestamp Timezone Caveats

**From: docs.snowflake.com/en/sql-reference/constructs/at-before**

Important timestamp behavior:
- If no explicit cast is given, the timestamp in AT clause is treated as TIMESTAMP_NTZ (UTC)
- The choice of cast type (TIMESTAMP_LTZ, TIMESTAMP_NTZ, TIMESTAMP_TZ) affects how the value is interpreted relative to the session's time zone and TIMESTAMP_TYPE_MAPPING parameter
- Best practice: always explicitly cast with the intended type (::TIMESTAMP_LTZ or ::TIMESTAMP_TZ) to avoid surprises in non-UTC sessions

**STREAM parameter in AT:**
You can use an existing stream's offset as the historical reference point:
```sql
SELECT * FROM my_table AT(STREAM => 'my_stream_name');
```
This uses the current offset in the stream as the AT point.

**AT | BEFORE does NOT support CTEs:**
This does NOT work:
```sql
-- This is NOT supported
WITH mycte AS (SELECT mytable.* FROM mytable)
SELECT * FROM mycte AT(TIMESTAMP => '2024-03-13 13:56:09.553 +0100'::TIMESTAMP_TZ);
```

**Additional unsupported scenarios for BEFORE clause:**
- BEFORE clause is not supported with CREATE DATABASE/SCHEMA ... CLONE that use the STATEMENT parameter if hybrid tables exist (workaround: use IGNORE HYBRID TABLES)

**Access control:**
Historical data has the same access control requirements as current data. If you can SELECT current data, you can SELECT historical data.

---

### Section: Cloning Historical Objects

The AT | BEFORE clause works with CLONE in CREATE commands for tables, schemas, and databases. Creates a zero-copy clone at that historical point.

**Syntax for each object type:**

Table clone at a specific timestamp:
```sql
CREATE TABLE restored_table CLONE my_table
  AT(TIMESTAMP => 'Wed, 26 Jun 2024 01:01:00 +0300'::timestamp_tz);
```

Schema clone 1 hour ago:
```sql
CREATE SCHEMA restored_schema CLONE my_schema AT(OFFSET => -3600);
```

Database clone before a specific statement completed:
```sql
CREATE DATABASE restored_db CLONE my_db
  BEFORE(STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726');
```

Database clone 4 days ago, skipping tables with insufficient retention:
```sql
CREATE DATABASE restored_db CLONE my_db
  AT(TIMESTAMP => DATEADD(days, -4, current_timestamp)::timestamp_tz)
  IGNORE TABLES WITH INSUFFICIENT DATA RETENTION;
```

**When cloning a database/schema fails:**
- If the specified Time Travel time is beyond the retention time of ANY current child object
- If the specified time is at or before when the object was created

**Workaround:** Use `IGNORE TABLES WITH INSUFFICIENT DATA RETENTION` to skip tables that have been purged from Time Travel, allowing the rest of the clone to succeed.

**IGNORE HYBRID TABLES parameter:**
If database/schema has hybrid tables and you use STATEMENT parameter cloning, you must add IGNORE HYBRID TABLES to avoid an error.

**Important: Clone Time Travel history starts at clone creation time.** A clone does NOT inherit the source table's historical Time Travel data. Historical data for the clone begins from when the clone was created.

**Internal stages in clones:**
Internal stages are cloned in their current state regardless of whether AT | BEFORE is used. Cloning internal stages uses the COPY FILES service, which incurs compute and file transfer charges.

---

### Section: Dropping and Restoring Objects

### Dropping Objects

When you drop a table, schema, or database, it is NOT immediately removed. It is retained for its retention period, during which it can be restored. Once it moves to Fail-safe, it cannot be restored by users.

Relevant drop commands:
- DROP NOTEBOOK
- DROP TABLE
- DROP SCHEMA
- DROP DATABASE

**Important:** Creating a new object with the same name as a dropped object does NOT restore the original. It creates a new object. The dropped version still exists separately in Time Travel.

---

### Listing Dropped Objects

Use SHOW commands with the HISTORY keyword:

```sql
SHOW TABLES HISTORY LIKE 'load%' IN mytestdb.myschema;
SHOW SCHEMAS HISTORY IN mytestdb;
SHOW DATABASES HISTORY;
```

Output includes a `dropped_on` column. If an object was dropped multiple times, each dropped version appears as a separate row.

Note: Once retention period passes and the object is purged, it disappears from SHOW ... HISTORY output.

---

### Restoring Objects (UNDROP)

Any object shown in SHOW ... HISTORY output can be restored:

```sql
UNDROP TABLE mytable;
UNDROP SCHEMA myschema;
UNDROP DATABASE mydatabase;
UNDROP NOTEBOOK mynotebook;
UNDROP ICEBERG TABLE my_iceberg_table;
UNDROP DYNAMIC TABLE my_dynamic_table;
UNDROP EXTERNAL VOLUME my_ext_vol;
UNDROP TAG my_tag;
UNDROP ACCOUNT my_account;
```

UNDROP restores the object to its most recent state before the DROP was issued.

**Name conflict:** If an object with the same name already exists, UNDROP fails. You must rename the existing object first, then UNDROP.

**UNDROP is in-place:** It restores the object without creating a new version. It does not create a new object.

---

### Access Control Requirements and Name Resolution

- User must have **OWNERSHIP privileges** on the object type to restore it
- User must also have **CREATE privileges** on the object type for the database or schema where the dropped object will be restored
- Restoring tables and schemas is only supported in the current schema or current database, even if a fully-qualified name is specified

---

### Example: Dropping and Restoring a Table Multiple Times

This is the worked example from the docs. Worth understanding the pattern:

Scenario: loaddata1 is dropped and recreated twice, creating 3 versions. To restore the oldest version:

1. Rename the current table: `ALTER TABLE loaddata1 RENAME TO loaddata3;`
2. UNDROP to get most recent dropped version: `UNDROP TABLE loaddata1;` — this restores version 2
3. Rename it: `ALTER TABLE loaddata1 RENAME TO loaddata2;`
4. UNDROP again: `UNDROP TABLE loaddata1;` — this restores version 1 (oldest)

The pattern: UNDROP always restores the **most recently dropped version** with that name. To get older versions, you have to clear the name by renaming what was just restored, then UNDROP again.

---

## Page: AT | BEFORE Clause
### URL: docs.snowflake.com/en/sql-reference/constructs/at-before

Full syntax:
```sql
SELECT ... FROM ... { AT | BEFORE }
  ( { TIMESTAMP => <timestamp>
    | OFFSET => <time_difference>
    | STATEMENT => <id>
    | STREAM => '<name>'
    } )
[ ... ]
```

**AT:** Inclusive of changes made by a statement/transaction with timestamp equal to the specified parameter.

**BEFORE:** Refers to a point immediately preceding the specified parameter.

**OFFSET parameter:**
- Value in seconds, negative integer or arithmetic expression
- -120 means 120 seconds (2 minutes) ago
- -30*60 means 30 minutes ago (arithmetic expression works)

**STATEMENT parameter:**
- Accepts query ID of a completed DML statement (INSERT, UPDATE, DELETE, MERGE, etc.)
- Can also accept SELECT query IDs (though the practical use is with DML)
- BEFORE (STATEMENT => ...) is the go-to way to undo a specific bad DML — it gives you the state just before that statement ran

**STREAM parameter (only in AT):**
- Accepts name of an existing stream
- Uses the stream's current offset as the AT reference point
- Useful for "bootstrapping" or creating a new stream at the same position as an existing one

**Smallest time resolution for TIMESTAMP:** Milliseconds

---

## Page: CHANGES Clause
### URL: docs.snowflake.com/en/sql-reference/constructs/changes

The CHANGES clause is a read-only alternative to Streams for querying change tracking metadata.

**Full syntax:**
```sql
SELECT ... FROM ...
  CHANGES( INFORMATION => { DEFAULT | APPEND_ONLY } )
  AT ( { TIMESTAMP => <timestamp>
       | OFFSET => <time_difference>
       | STATEMENT => <id>
       | STREAM => '<name>'
       } )
  | BEFORE ( STATEMENT => <id> )
  [ END( { TIMESTAMP => <timestamp>
         | OFFSET => <time_difference>
         | STATEMENT => <id>
         } ) ]
```

**Key difference from Streams:** CHANGES does not maintain a durable offset. It does not advance/consume anything. Multiple queries can read the same change interval repeatedly.

**Prerequisites for CHANGES:**
At least one must be true before change tracking metadata is recorded:
- `CHANGE_TRACKING = TRUE` is enabled on the table/view
- A stream exists on the table

Enable change tracking:
```sql
ALTER TABLE my_table SET CHANGE_TRACKING = TRUE;
```

**INFORMATION => DEFAULT:**
Returns all DML changes: inserts, updates, and deletes (including TRUNCATE). Compares inserted and deleted rows to give a row-level delta. A row inserted and then deleted in the same interval is removed from the net delta (net effect = nothing).

**INFORMATION => APPEND_ONLY:**
Returns only net-new inserts — rows inserted and NOT subsequently deleted or updated in the interval.

**Metadata columns returned:**

| Column | Description |
|---|---|
| METADATA$ACTION | INSERT or DELETE |
| METADATA$ISUPDATE | TRUE if this row is part of an UPDATE (UPDATE shows as DELETE old + INSERT new, both with ISUPDATE = TRUE) |
| METADATA$ROW_ID | Unique immutable internal identifier for the row, stable across DML operations |

**END clause:**
Specifies the end of the change interval. Valid only with CHANGES (not with regular AT | BEFORE). Results are inclusive of the END marker.
- END value must be a constant expression
- Cannot be combined with AT | BEFORE when doing regular Time Travel (only valid with CHANGES)

**Limitations:**
- CHANGES is not supported for directory tables or external tables
- If requested data is beyond the Time Travel retention period, the statement fails
- If data is within retention but no historical data is available (e.g., retention was recently extended), statement also fails

**Example:**
```sql
-- Enable change tracking
ALTER TABLE t1 SET CHANGE_TRACKING = TRUE;

-- Query append-only changes since a specific timestamp
SELECT * FROM t1 CHANGES(INFORMATION => APPEND_ONLY)
  AT(TIMESTAMP => $ts1);

-- Query all changes in a window
SELECT * FROM t1 CHANGES(INFORMATION => DEFAULT)
  AT(OFFSET => -3600)
  END(OFFSET => 0);
```

---

## Page: CREATE … CLONE (with Time Travel)
### URL: docs.snowflake.com/en/sql-reference/sql/create-clone

**Syntax for database/schema clone with Time Travel:**
```sql
CREATE [ OR REPLACE ] { DATABASE | SCHEMA } [ IF NOT EXISTS ] <object_name>
  CLONE <source_object_name>
  [ { AT | BEFORE }
    ( { TIMESTAMP => <timestamp>
      | OFFSET => <time_difference>
      | STATEMENT => <id>
      } )
  ]
  [ IGNORE TABLES WITH INSUFFICIENT DATA RETENTION ]
  [ IGNORE HYBRID TABLES ]
  [ INCLUDE INTERNAL STAGES ]
```

**Syntax for table clone with Time Travel:**
```sql
CREATE [ OR REPLACE ] TABLE [ IF NOT EXISTS ] <object_name>
  CLONE <source_object_name>
  [ { AT | BEFORE }
    ( { TIMESTAMP => <timestamp>
      | OFFSET => <time_difference>
      | STATEMENT => <id>
      } )
  ]
```

**Notes on clone behavior:**
- If no AT | BEFORE is specified, clone defaults to CURRENT_TIMESTAMP (clones current state)
- Cloning a database/schema takes a snapshot of all contained tables at that historical point
- OR REPLACE and IF NOT EXISTS are mutually exclusive
- CREATE OR REPLACE is atomic — the old is deleted and new created in a single transaction

**Object references in clones (views, streams, tasks):**
- Views: the stored query including table references is inherited as-is by the clone
- Streams: the clone of a stream points to the same source as the original
- Tasks: tasks in clones execute SQL that references the original objects (not the cloned ones), unless the objects are fully qualified within the same cloned database/schema

**Why clone operations can fail:**
- The AT | BEFORE time is before the object was created
- Historical data for any child object has been purged from Time Travel
- Hybrid tables exist and you didn't specify IGNORE HYBRID TABLES (for STATEMENT-based clones)

**Internal stages in clones:**
- Always cloned in current state regardless of AT | BEFORE
- Uses COPY FILES service — incurs compute and file transfer charges
- Monitor usage via COPY_FILES_HISTORY view

---

## Page: Working with Temporary and Transient Tables
### URL: docs.snowflake.com/en/user-guide/tables-temp-transient

**Comparison of table types for Time Travel:**

| Feature | Permanent | Transient | Temporary |
|---|---|---|---|
| Max Time Travel retention | 90 days (Enterprise) / 1 day (Standard) | 1 day | 1 day |
| Fail-safe period | 7 days | None | None |
| Survives session | Yes | Yes | No |
| Use case | Production data | ETL staging, short-lived | Session-specific data |

**Transient tables:**
- Exist until explicitly dropped, accessible to all users with privileges
- Time Travel retention: 0 or 1 day only
- NO Fail-safe period — zero additional cost beyond the retention window
- Cannot be recovered by Snowflake after Time Travel expires (unlike permanent tables with 7-day Fail-safe)
- Good for large staging tables where Fail-safe cost isn't justified

Creating a transient table:
```sql
CREATE TRANSIENT TABLE mytranstable (id INT, creation_date TIMESTAMP_TZ);
```

Creating a transient schema (all tables in it are transient):
```sql
CREATE TRANSIENT SCHEMA myschema;
```

Creating a transient database (all schemas/tables within are transient):
```sql
CREATE TRANSIENT DATABASE mydb;
```

**Temporary tables:**
- Exist only for the lifetime of the session
- NOT accessible outside the creating session
- Time Travel: 0 or 1 day only
- No Fail-safe
- Data purged and unrecoverable when session ends
- Do NOT require CREATE TABLE privilege on the schema

```sql
CREATE TEMPORARY TABLE mytemptable (id INT, creation_date TIMESTAMP_TZ);
-- or
CREATE TEMP TABLE mytemptable (id INT, creation_date TIMESTAMP_TZ);
```

**Warning for long sessions:** If you create large temporary tables in sessions maintained for > 24 hours, you can accumulate unexpected storage charges. Drop them explicitly when done.

**Converting permanent tables to transient to save costs:**
1. CREATE TABLE ... AS SELECT (transient version)
2. Apply all grants from original table
3. DROP TABLE the original permanent table
4. Optionally ALTER TABLE RENAME the transient table to original name

**Caveat when cloning transient from permanent:**
When a permanent table is dropped, it enters Fail-safe for 7 days. If a transient clone shares micro-partitions with that permanent table and the clone is still alive when the permanent is dropped, those shared micro-partitions won't enter Fail-safe until the transient clone is also dropped.

---

## Page: Storage Costs for Time Travel and Fail-safe
### URL: docs.snowflake.com/en/user-guide/data-cdp-storage-costs

**How fees are calculated:**
- Calculated for each 24-hour period from the time data changed
- Based on table type and Time Travel retention period
- Snowflake only maintains the information needed to restore individual rows (not full table copies), except when tables are dropped or truncated — full copies maintained then
- Storage usage = percentage of the table that changed

**By table type:**

| Table Type | Time Travel Max | Fail-safe | Max Additional Storage Cost |
|---|---|---|---|
| Permanent (Standard) | 1 day | 7 days | 8 days total |
| Permanent (Enterprise) | 90 days | 7 days | 97 days total |
| Transient | 1 day | 0 days | 1 day |
| Temporary | 1 day | 0 days | 1 day |

**Insert, COPY, Snowpipe note:**
Loading data using INSERT, COPY INTO, or Snowpipe can generate TIME_TRAVEL_BYTES and FAILSAFE_BYTES even for inserts. This is because micro-partition defragmentation occurs — small micro-partitions are deleted and new ones created with the same data. The deleted micro-partitions contribute to the historical data counts.

**High-churn dimension tables:**
For tables with frequent updates, CDP (Time Travel + Fail-safe) storage can be much larger than the active table storage. Calculate the ratio of FAILSAFE_BYTES / ACTIVE_BYTES in TABLE_STORAGE_METRICS to identify these tables.

**Managing storage costs:**
- Use transient/temporary tables for ETL staging data
- Keep short-lived tables as transient to eliminate Fail-safe costs
- Long-lived tables (fact tables) should be permanent for full protection
- Set DATA_RETENTION_TIME_IN_DAYS to match actual business need, not always maximum

**Internal stages and storage:**
Data in Snowflake internal stages is NOT subject to Time Travel or Fail-safe costs but does incur standard storage costs. Recommendation: purge staged files after loading.

**Zero-copy clones and storage:**
When a clone is created, it initially shares all micro-partitions with the source. New micro-partitions are only created when rows are modified in the clone. If table T2 and T3 share micro-partitions and T2 is dropped, those shared micro-partitions transfer ownership to T3 when T2's Time Travel expires (right before entering Fail-safe).

**Monitoring storage costs:**
View via Snowsight: Admin → Cost Management → Consumption → Storage
Or query:
```sql
-- TABLE_STORAGE_METRICS view for per-table breakdown
SELECT table_name,
       active_bytes,
       time_travel_bytes,
       failsafe_bytes,
       retained_for_clone_bytes
FROM snowflake.account_usage.table_storage_metrics;
```

**Backup costs (separate from Time Travel):**
Monitor via RETAINED_FOR_CLONE_BYTES in TABLE_STORAGE_METRICS and BACKUP_STORAGE_USAGE view.

---

## Page: Understanding and Viewing Fail-safe
### URL: docs.snowflake.com/en/user-guide/data-failsafe

**What Fail-safe is:**
A 7-day period after Time Travel expires during which Snowflake internally retains historical data for disaster recovery. This is NOT self-service — users cannot access Fail-safe data directly.

**Key distinction from Time Travel:**
- Time Travel = self-service, user-controlled recovery
- Fail-safe = Snowflake-managed disaster recovery, Snowflake Support intervention required

**Duration:**
- Permanent tables: 7 days (fixed, not configurable)
- Transient tables: 0 days (no Fail-safe)
- Temporary tables: 0 days (no Fail-safe)

**Accessing Fail-safe data:**
Only Snowflake can access Fail-safe data. Users must contact Snowflake Support. Recovery may take several hours to several days.

**Fail-safe uses Snowflake-managed serverless compute** for data recovery. Standard serverless compute billing applies. To view related credit consumption, filter METERING_HISTORY for FAILSAFE_RECOVERY service type.

**Limitation:**
Fail-safe doesn't support tables that contain data ingested by Snowpipe Streaming Classic.

**Total data lifecycle for a permanent table row:**
Active → Time Travel (0 to 90 days) → Fail-safe (7 days) → Permanently deleted

---

## Page: TABLE_STORAGE_METRICS View
### URL: docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics

Account Usage view that shows table-level storage utilization, including dropped tables still incurring storage costs.

**Key columns:**

| Column | What it means |
|---|---|
| ACTIVE_BYTES | Current queryable table data |
| TIME_TRAVEL_BYTES | Historical versions within Time Travel retention window |
| FAILSAFE_BYTES | Data past Time Travel but within Fail-safe window (permanent tables only) |
| RETAINED_FOR_CLONE_BYTES | Micro-partitions kept alive because a clone still references them |

**Multiple rows per table name:**
If TABLE_NAME shows multiple rows, multiple versions of the table exist. A new version is created each time a table is dropped and a new table with the same name is created (including CREATE OR REPLACE). The current version has NULL in TABLE_DROPPED; older versions have a timestamp.

**Each version incurs Time Travel (and Fail-safe for permanent) costs separately.**

**Latency:** Up to 90 minutes.

**Hybrid tables:** Storage metrics for hybrid tables are NOT tracked in this view.

**Note on dropped columns:**
When a column is dropped from a table using ALTER TABLE, the physical data in that column is not immediately deleted. Dropped column bytes are included in ACTIVE_BYTES until physically removed. The table size shown may be larger than what a full table scan would read.

---

## Page: Introduction to Streams (Time Travel Relationship)
### URL: docs.snowflake.com/en/user-guide/streams-intro

**Streams use Time Travel internally.** A stream maintains an offset (pointer) into the source table's Time Travel history. When you query a stream, it returns changes committed after that offset.

**Stream staleness:**
If the source table's Time Travel data at the stream's offset is purged, the stream becomes **stale** and unreadable.

**Automatic retention extension to prevent staleness:**
If the data retention period for a table is less than 14 days AND a stream hasn't been consumed, Snowflake temporarily extends the retention to prevent staleness. Extended up to the stream's offset, max 14 days by default.

This extension is controlled by `MAX_DATA_EXTENSION_TIME_IN_DAYS` parameter (0 to 90 days, default 14).

```sql
-- Set max extension at table level
ALTER TABLE my_table SET MAX_DATA_EXTENSION_TIME_IN_DAYS = 7;
```

**STALE_AFTER column in SHOW STREAMS:**
Shows when the stream is predicted to become stale:
STALE_AFTER = last_consumption_time + MAX(DATA_RETENTION_TIME_IN_DAYS, MAX_DATA_EXTENSION_TIME_IN_DAYS)

**Streams have NO Time Travel or Fail-safe of their own.** The stream metadata (offset) cannot be recovered if the stream is dropped.

**Stream offset and cloning:**
When a database/schema containing a stream and its source table is cloned, unconsumed records in the stream clone are inaccessible. This is consistent with Time Travel — clone history starts at clone creation time, not before.

**Creating a stream at a historical point:**
```sql
-- Create stream at a specific past timestamp
CREATE STREAM mystream ON TABLE mytable
  BEFORE(TIMESTAMP => TO_TIMESTAMP(40*365*86400));

-- Create stream at the same offset as an existing stream
CREATE STREAM mystream ON TABLE mytable AT(STREAM => 'oldstream');

-- Create stream at specific timestamp
CREATE STREAM mystream ON TABLE mytable
  AT(TIMESTAMP => TO_TIMESTAMP_TZ('02/02/2019 01:02:03', 'mm/dd/yyyy hh24:mi:ss'));
```

**Streams on shared tables:**
Streams on shared tables do NOT extend the data retention for the shared table. The provider must set the table retention long enough for the consumer to consume the stream. If a provider shares a table with 7-day retention and 14-day MAX_DATA_EXTENSION, the stream is stale after 14 days in provider account but after 7 days in consumer account.

---

## Page: Parameters Reference (Time Travel Related Parameters)
### URL: docs.snowflake.com/en/sql-reference/parameters

### DATA_RETENTION_TIME_IN_DAYS

- Type: Object parameter
- Scope: Account, Database, Schema, Table
- Default: 1 (for all editions)
- Range: 0 to 1 (Standard Edition); 0 to 90 (Enterprise Edition and above)
- Effect: Specifies days for Time Travel (SELECT, CLONE, UNDROP) on historical data
- 0 effectively disables Time Travel for that object

### MIN_DATA_RETENTION_TIME_IN_DAYS

- Type: Account parameter
- Scope: Account only
- Set by: ACCOUNTADMIN (or roles granted ACCOUNTADMIN)
- Effect: Enforces a minimum retention across all databases/schemas/tables
- Effective retention = MAX(DATA_RETENTION_TIME_IN_DAYS, MIN_DATA_RETENTION_TIME_IN_DAYS)
- Setting this does NOT change existing DATA_RETENTION_TIME_IN_DAYS values
- Important for compliance: ensures nobody accidentally sets retention below a threshold

### MAX_DATA_EXTENSION_TIME_IN_DAYS

- Type: Object parameter
- Scope: Account, Database, Schema, Table
- Default: 14
- Range: 0 to 90 (contact Snowflake Support to increase beyond 90)
- Effect: Sets the maximum number of days Snowflake can extend the data retention period for tables to prevent streams from becoming stale
- 0 disables the automatic extension
- Only relevant when streams exist on the table
- Not applicable to databases created from shares (read-only)
- Caveat: Can cause data to be retained longer than the default — check compliance requirements before increasing

---

## Key Scenarios and Patterns

### Scenario 1: Recover rows from an accidental DELETE

```sql
-- Find the query ID of the bad DELETE (use Snowsight Query History or QUERY_HISTORY view)
SELECT query_id, query_text, start_time
FROM snowflake.account_usage.query_history
WHERE query_text ILIKE '%DELETE%my_table%'
ORDER BY start_time DESC
LIMIT 10;

-- See what was deleted
SELECT * FROM my_table BEFORE(STATEMENT => '<query_id>');

-- Restore the deleted rows
INSERT INTO my_table
  SELECT * FROM my_table BEFORE(STATEMENT => '<query_id>')
  WHERE <condition for deleted rows>;
```

### Scenario 2: Recover from accidental TRUNCATE

```sql
-- TRUNCATE is recoverable via Time Travel (unlike some other DBs)
INSERT INTO my_table
  SELECT * FROM my_table BEFORE(STATEMENT => '<truncate_query_id>');
-- or using timestamp if you know when it happened
INSERT INTO my_table
  SELECT * FROM my_table AT(OFFSET => -3600);  -- 1 hour ago
```

### Scenario 3: Full table rollback using clone + swap

```sql
-- 1. Create clean clone at good historical point (zero-copy, instant)
CREATE TABLE my_table_clean CLONE my_table
  AT(TIMESTAMP => '<good_timestamp>'::TIMESTAMP_TZ);

-- 2. Validate
SELECT COUNT(*) FROM my_table_clean;

-- 3. Atomically swap (zero downtime)
ALTER TABLE my_table SWAP WITH my_table_clean;

-- 4. Clean up (my_table_clean now has the bad data)
DROP TABLE my_table_clean;
```

### Scenario 4: Restore a dropped table

```sql
-- Check if it's restorable
SHOW TABLES HISTORY LIKE 'my_table%';

-- If name conflict exists, rename current table first
ALTER TABLE my_table RENAME TO my_table_temp;

-- Restore
UNDROP TABLE my_table;
```

### Scenario 5: Audit what changed between two points in time

```sql
-- Enable change tracking first
ALTER TABLE orders SET CHANGE_TRACKING = TRUE;

-- See all changes in last 6 hours
SELECT * FROM orders CHANGES(INFORMATION => DEFAULT)
  AT(OFFSET => -21600);

-- Only new inserts
SELECT * FROM orders CHANGES(INFORMATION => APPEND_ONLY)
  AT(OFFSET => -21600);
```

### Scenario 6: Compare current vs yesterday

```sql
SELECT 
  cur.id,
  cur.amount AS current_amount,
  hist.amount AS yesterday_amount,
  cur.amount - hist.amount AS change
FROM orders cur
JOIN orders AT(OFFSET => -86400) hist ON cur.id = hist.id
WHERE cur.amount <> hist.amount;
```

### Scenario 7: GDPR right-to-erasure with Time Travel

Deleting a row with DELETE removes it from active data, but it remains in Time Travel. To fully purge:

```sql
-- Step 1: Delete from active table
DELETE FROM customer_data WHERE customer_id = 12345;

-- Step 2: Immediately set retention to 0 to purge Time Travel
ALTER TABLE customer_data SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Note: For permanent tables, data still exists in Fail-safe for 7 days.
-- For true immediate erasure, use TRANSIENT tables (no Fail-safe).
-- Fail-safe data requires contacting Snowflake Support.
```

### Scenario 8: Cost optimization for high-DML tables

```sql
-- Check which tables have high Time Travel storage
SELECT table_name,
       active_bytes,
       time_travel_bytes,
       failsafe_bytes,
       ROUND(time_travel_bytes / NULLIF(active_bytes, 0), 2) AS tt_ratio,
       ROUND(failsafe_bytes / NULLIF(active_bytes, 0), 2) AS fs_ratio
FROM snowflake.account_usage.table_storage_metrics
WHERE active_bytes > 0
ORDER BY time_travel_bytes DESC;

-- For high-churn staging tables, use transient
CREATE TRANSIENT TABLE stg_orders AS SELECT * FROM raw_orders;

-- Or reduce retention on specific tables
ALTER TABLE high_churn_table SET DATA_RETENTION_TIME_IN_DAYS = 1;
```

---

## Advantages of Time Travel

- Self-service data recovery — no need to call support for most scenarios
- Zero-copy historical cloning — no data movement, no extra storage for the clone itself
- Point-in-time auditing — query data as it was at any past moment within retention window
- Statement-level precision — undo a specific DML without knowing the timestamp
- Works across all object levels — table, schema, database
- No performance overhead during normal DML — uses Snowflake's immutable micro-partition architecture
- Combined with Fail-safe gives up to 97 days of total data protection on Enterprise Edition
- Automatic — no setup or configuration required for basic 1-day protection

---

## Disadvantages and Caveats

- **Storage cost increases with long retention** — especially for high-churn tables. Time Travel data billed at same rate as active storage.
- **Automatic clustering increases Time Travel storage** — reclustering is DML-like; old micro-partitions are retained in Time Travel.
- **Fail-safe adds unavoidable 7 days of extra cost** for permanent tables (not configurable).
- **Reducing retention purges data** — not immediate (background process) but data becomes inaccessible quickly.
- **Cannot deactivate for the entire account** — only per-object.
- **Setting retention to 0 makes dropped objects unrecoverable** — a common mistake.
- **Dropped schema/database ignores child retention** — child objects follow the parent's retention period when dropped together.
- **Schema changes apply retroactively** — historical queries use current schema, which can cause confusion (new column appears as NULL in old data).
- **AT | BEFORE not supported on CTEs** — must apply directly to base tables.
- **Views don't support AT | BEFORE** — must query the underlying base tables.
- **External tables have no Time Travel** — data outside Snowflake storage is not tracked.
- **Streams have no Time Travel of their own** — stream metadata cannot be recovered if dropped.
- **Time Travel data lives in same storage region** — a regional cloud disaster could affect both active and Time Travel data. Not a substitute for cross-region backup.
- **Standard Edition capped at 1 day** — meaningful protection requires Enterprise Edition.
- **Long-running Time Travel queries delay Fail-safe transitions** for the whole account.
- **Tasks not included in timestamp-based schema clones** — a specific limitation worth noting for infrastructure cloning.
- **Transient tables have no Fail-safe** — once Time Travel expires, data is gone forever from Snowflake's perspective.

---

## Summary Reference Table

| Object | Max Time Travel | Fail-safe | UNDROP Supported |
|---|---|---|---|
| Permanent Table (Enterprise) | 90 days | 7 days | Yes |
| Permanent Table (Standard) | 1 day | 7 days | Yes |
| Transient Table | 1 day | 0 days | Yes (within 1 day) |
| Temporary Table | 1 day | 0 days | Yes (within session/1 day) |
| External Table | None | None | No |
| View | None | None | No |
| Materialized View | None | None | No |
| Schema | Inherits from objects | Inherits | Yes |
| Database | Inherits from objects | Inherits | Yes |
| Stream | None (no TT of its own) | None | No |

---

## Quick Reference: All Time Travel SQL

```sql
-- Query historical data
SELECT * FROM t AT(TIMESTAMP => '2024-06-01 09:00:00'::TIMESTAMP_TZ);
SELECT * FROM t AT(OFFSET => -3600);           -- 1 hour ago
SELECT * FROM t AT(OFFSET => -86400);          -- 24 hours ago
SELECT * FROM t BEFORE(STATEMENT => '<id>');    -- before specific DML
SELECT * FROM t AT(STREAM => 'mystream');       -- at stream's current offset

-- Clone at historical point
CREATE TABLE t_backup CLONE t AT(OFFSET => -3600);
CREATE SCHEMA s_backup CLONE s AT(TIMESTAMP => '2024-06-01'::TIMESTAMP_TZ);
CREATE DATABASE db_backup CLONE db BEFORE(STATEMENT => '<id>');
CREATE DATABASE db_backup CLONE db AT(OFFSET => -86400)
  IGNORE TABLES WITH INSUFFICIENT DATA RETENTION;

-- Set retention
CREATE TABLE t (id INT) DATA_RETENTION_TIME_IN_DAYS = 30;
ALTER TABLE t SET DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE t UNSET DATA_RETENTION_TIME_IN_DAYS;  -- revert to inherited
ALTER DATABASE db SET DATA_RETENTION_TIME_IN_DAYS = 14;
ALTER SCHEMA s SET DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 1;  -- requires ACCOUNTADMIN

-- Check retention
SHOW TABLES HISTORY;
SHOW SCHEMAS HISTORY IN mydb;
SHOW DATABASES HISTORY;
SHOW STREAMS;  -- check stale_after column

-- Drop and restore
DROP TABLE t;
UNDROP TABLE t;
DROP SCHEMA s;
UNDROP SCHEMA s;
DROP DATABASE db;
UNDROP DATABASE db;

-- Change tracking for CHANGES clause
ALTER TABLE t SET CHANGE_TRACKING = TRUE;
SELECT * FROM t CHANGES(INFORMATION => DEFAULT) AT(OFFSET => -3600);
SELECT * FROM t CHANGES(INFORMATION => APPEND_ONLY) AT(OFFSET => -3600);
SELECT * FROM t CHANGES(INFORMATION => DEFAULT)
  AT(OFFSET => -7200) END(OFFSET => -3600);  -- windowed change query

-- Storage monitoring
SELECT table_name, active_bytes, time_travel_bytes, failsafe_bytes
FROM snowflake.account_usage.table_storage_metrics
ORDER BY time_travel_bytes DESC;
```

---

*Notes compiled from:*
- *https://docs.snowflake.com/en/user-guide/data-time-travel*
- *https://docs.snowflake.com/en/sql-reference/constructs/at-before*
- *https://docs.snowflake.com/en/sql-reference/constructs/changes*
- *https://docs.snowflake.com/en/sql-reference/sql/create-clone*
- *https://docs.snowflake.com/en/user-guide/tables-temp-transient*
- *https://docs.snowflake.com/en/user-guide/data-cdp-storage-costs*
- *https://docs.snowflake.com/en/user-guide/data-failsafe*
- *https://docs.snowflake.com/en/user-guide/tables-storage-considerations*
- *https://docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics*
- *https://docs.snowflake.com/en/user-guide/streams-intro*
- *https://docs.snowflake.com/en/sql-reference/parameters*
