-- ============================================================
-- SNOWFLAKE TIME TRAVEL - COMPLETE HANDS-ON PRACTICE LAB
-- ============================================================
-- Run each section step by step.
-- Read every comment carefully before executing.
-- Each section is self-contained and builds progressively.
-- ============================================================

-- ============================================================
-- SECTION 0: SETUP - Create dedicated lab environment
-- ============================================================

-- Create a dedicated database for this lab
CREATE DATABASE IF NOT EXISTS TT_LAB;
USE DATABASE TT_LAB;

-- Create a schema for our lab
CREATE SCHEMA IF NOT EXISTS TT_SCHEMA;
USE SCHEMA TT_SCHEMA;

-- Confirm current context
SELECT CURRENT_DATABASE(), CURRENT_SCHEMA(), CURRENT_USER(), CURRENT_ROLE();


-- ============================================================
-- SECTION 1: UNDERSTANDING DATA RETENTION SETTINGS
-- ============================================================
-- Objective: Learn how DATA_RETENTION_TIME_IN_DAYS works
-- at account, database, schema, and table level.
-- ============================================================

-- 1.1 Check account-level default retention
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS';

-- 1.2 Check MIN retention (compliance floor)
SHOW PARAMETERS LIKE 'MIN_DATA_RETENTION_TIME_IN_DAYS';

-- 1.3 Create a table without specifying retention (inherits default)
CREATE OR REPLACE TABLE tbl_default_retention (
    id          INT,
    name        VARCHAR(50),
    created_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 1.4 Check the retention on this table (look at retention_time column)
SHOW TABLES LIKE 'tbl_default_retention';

-- 1.5 Create a table with explicit retention of 5 days
-- NOTE: This requires Enterprise Edition. If on Standard Edition, use 1.
CREATE OR REPLACE TABLE tbl_5day_retention (
    id     INT,
    value  NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 5;

SHOW TABLES LIKE 'tbl_5day_retention';

-- 1.6 Create a table with retention = 0 (Time Travel DISABLED)
CREATE OR REPLACE TABLE tbl_no_retention (
    id    INT,
    value VARCHAR(100)
) DATA_RETENTION_TIME_IN_DAYS = 0;

SHOW TABLES LIKE 'tbl_no_retention';

-- 1.7 Alter retention on existing table
ALTER TABLE tbl_default_retention SET DATA_RETENTION_TIME_IN_DAYS = 3;
SHOW TABLES LIKE 'tbl_default_retention';  -- verify change

-- 1.8 Unset table-level retention (reverts to schema/database/account inheritance)
ALTER TABLE tbl_default_retention UNSET DATA_RETENTION_TIME_IN_DAYS;
SHOW TABLES LIKE 'tbl_default_retention';  -- back to inherited value

-- 1.9 Set retention at SCHEMA level (all new tables inside inherit this)
ALTER SCHEMA TT_SCHEMA SET DATA_RETENTION_TIME_IN_DAYS = 7;
SHOW SCHEMAS LIKE 'TT_SCHEMA';  -- check retention_time column

-- 1.10 Create a new table - it should inherit schema-level 7 days
CREATE OR REPLACE TABLE tbl_inherits_schema (
    id INT
);
SHOW TABLES LIKE 'tbl_inherits_schema';  -- should show 7

-- 1.11 Table-level override wins over schema-level
CREATE OR REPLACE TABLE tbl_overrides_schema (
    id INT
) DATA_RETENTION_TIME_IN_DAYS = 1;
SHOW TABLES LIKE 'tbl_overrides_schema';  -- should show 1, not 7

-- 1.12 Query INFORMATION_SCHEMA to check retention of all tables
SELECT table_name, retention_time
FROM information_schema.tables
WHERE table_schema = 'TT_SCHEMA'
ORDER BY table_name;

-- Reset schema-level back to default for rest of lab
ALTER SCHEMA TT_SCHEMA SET DATA_RETENTION_TIME_IN_DAYS = 1;


-- ============================================================
-- SECTION 2: THE THREE AT | BEFORE PARAMETERS
-- ============================================================
-- Objective: Master TIMESTAMP, OFFSET, and STATEMENT
-- ============================================================

-- Setup: Create and populate a practice table
CREATE OR REPLACE TABLE orders (
    order_id    INT,
    customer    VARCHAR(50),
    amount      NUMBER(10,2),
    status      VARCHAR(20),
    updated_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 1;

-- Insert initial data
INSERT INTO orders (order_id, customer, amount, status) VALUES
    (1, 'Alice',   1500.00, 'PENDING'),
    (2, 'Bob',     2300.50, 'PENDING'),
    (3, 'Charlie', 800.75,  'PENDING'),
    (4, 'Diana',   3200.00, 'PENDING'),
    (5, 'Eve',     450.25,  'PENDING');

-- Verify initial data
SELECT * FROM orders ORDER BY order_id;

-- Save the current timestamp BEFORE making changes
-- This is the "clean state" timestamp we will travel back to
SET ts_initial = CURRENT_TIMESTAMP();
SELECT $ts_initial AS initial_state_timestamp;

-- Wait a moment then make changes
-- (In real scenarios the gap would be larger)
SELECT SYSTEM$WAIT(5);   -- wait 5 seconds

-- 2.1 Make some DML changes
UPDATE orders SET status = 'SHIPPED', amount = amount * 1.1
WHERE order_id IN (1, 2);

DELETE FROM orders WHERE order_id = 5;

INSERT INTO orders (order_id, customer, amount, status) VALUES
    (6, 'Frank', 999.99, 'NEW');

-- Current state after changes
SELECT * FROM orders ORDER BY order_id;

-- -------------------------------------------------------
-- 2.A: USING AT(TIMESTAMP => ...)
-- -------------------------------------------------------

-- Travel back to initial state using the timestamp we saved
SELECT * FROM orders
AT(TIMESTAMP => $ts_initial)
ORDER BY order_id;
-- Expected: All 5 original rows, all PENDING

-- You can also compute timestamps on the fly
SELECT * FROM orders
AT(TIMESTAMP => DATEADD(minutes, -1, CURRENT_TIMESTAMP()))
ORDER BY order_id;
-- Shows data from 1 minute ago

-- Using TIMESTAMP_LTZ with explicit timezone
SELECT * FROM orders
AT(TIMESTAMP => CONVERT_TIMEZONE('UTC', 'America/Los_Angeles', $ts_initial)::TIMESTAMP_LTZ)
ORDER BY order_id;

-- -------------------------------------------------------
-- 2.B: USING AT(OFFSET => ...)
-- -------------------------------------------------------

-- Offset is in SECONDS, always NEGATIVE for past
-- -60  = 1 minute ago
-- -3600  = 1 hour ago
-- -86400 = 24 hours ago (1 day)

SELECT * FROM orders AT(OFFSET => -60) ORDER BY order_id;
-- Note: This may show current state if < 60s have passed

-- Arithmetic expressions work in OFFSET
SELECT * FROM orders AT(OFFSET => -5 * 60) ORDER BY order_id;  -- 5 minutes ago
SELECT * FROM orders AT(OFFSET => -1 * 3600) ORDER BY order_id;  -- 1 hour ago
SELECT * FROM orders AT(OFFSET => -24 * 3600) ORDER BY order_id;  -- 1 day ago

-- -------------------------------------------------------
-- 2.C: USING AT | BEFORE (STATEMENT => ...)
-- -------------------------------------------------------

-- This is the most precise method -- uses exact query ID

-- Step 1: Do a specific DML and capture its query ID
UPDATE orders SET status = 'CANCELLED' WHERE order_id = 3;

-- Step 2: Get the query ID of the last statement
SET last_query_id = LAST_QUERY_ID();
SELECT $last_query_id;

-- Step 3: AT(STATEMENT) -- INCLUSIVE -- shows state AFTER the UPDATE ran
SELECT * FROM orders AT(STATEMENT => $last_query_id) ORDER BY order_id;
-- order_id=3 shows CANCELLED

-- Step 4: BEFORE(STATEMENT) -- EXCLUSIVE -- shows state JUST BEFORE the UPDATE
SELECT * FROM orders BEFORE(STATEMENT => $last_query_id) ORDER BY order_id;
-- order_id=3 still shows PENDING (or whatever it was before CANCELLED)

-- IMPORTANT DISTINCTION:
-- AT  = inclusive, shows data AFTER the statement
-- BEFORE = exclusive, shows data BEFORE the statement ran
-- Use BEFORE to "undo" a specific DML

-- -------------------------------------------------------
-- 2.D: USING AT(STREAM => '...') 
-- -------------------------------------------------------

-- Create a stream on orders
CREATE OR REPLACE STREAM orders_stream ON TABLE orders;

-- Show the stream's current offset details
SHOW STREAMS LIKE 'orders_stream';
-- Check stale_after column - tells you when stream will become stale

-- Use stream offset as Time Travel reference
SELECT * FROM orders AT(STREAM => 'orders_stream') ORDER BY order_id;
-- Returns data at the stream's current offset (when stream was created)


-- ============================================================
-- SECTION 3: RECOVERING FROM ACCIDENTAL DML
-- ============================================================
-- Objective: Practice the most common recovery patterns
-- ============================================================

-- 3.A: RECOVER FROM ACCIDENTAL DELETE
-- ------------------------------------

CREATE OR REPLACE TABLE employees (
    emp_id     INT,
    name       VARCHAR(100),
    dept       VARCHAR(50),
    salary     NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO employees VALUES
    (101, 'John Smith',    'Engineering', 95000),
    (102, 'Mary Johnson',  'Marketing',   72000),
    (103, 'Bob Davis',     'Engineering', 88000),
    (104, 'Sarah Wilson',  'HR',          65000),
    (105, 'Tom Brown',     'Finance',     78000),
    (106, 'Lisa Taylor',   'Engineering', 91000),
    (107, 'James Moore',   'Marketing',   68000),
    (108, 'Emma Anderson', 'Finance',     82000);

SELECT 'Before Delete - Row Count: ' || COUNT(*) AS status FROM employees;

-- *** SIMULATE ACCIDENT: Someone deletes entire Engineering dept ***
DELETE FROM employees WHERE dept = 'Engineering';

SELECT 'After Delete - Row Count: ' || COUNT(*) AS status FROM employees;
SELECT * FROM employees ORDER BY emp_id;  -- 3 rows gone

-- Save query ID of the bad delete
SET bad_delete_qid = LAST_QUERY_ID();

-- RECOVERY OPTION 1: Use BEFORE(STATEMENT) to see pre-delete state
SELECT 'Rows before the bad delete:' AS info;
SELECT * FROM employees
BEFORE(STATEMENT => $bad_delete_qid)
ORDER BY emp_id;

-- RECOVERY OPTION 2: Restore only the deleted rows
INSERT INTO employees
    SELECT * FROM employees
    BEFORE(STATEMENT => $bad_delete_qid)
    WHERE dept = 'Engineering';

-- Verify restoration
SELECT 'After Recovery - Row Count: ' || COUNT(*) AS status FROM employees;
SELECT * FROM employees ORDER BY emp_id;  -- All 8 back


-- 3.B: RECOVER FROM ACCIDENTAL UPDATE (WRONG VALUES)
-- ---------------------------------------------------

-- *** SIMULATE ACCIDENT: Someone doubles all salaries by mistake ***
UPDATE employees SET salary = salary * 2;

SELECT 'After bad UPDATE - Salaries doubled:' AS info;
SELECT * FROM employees ORDER BY emp_id;

SET bad_update_qid = LAST_QUERY_ID();

-- OPTION 1: Restore individual column values using BEFORE
-- See pre-update state
SELECT * FROM employees BEFORE(STATEMENT => $bad_update_qid) ORDER BY emp_id;

-- Restore salaries using UPDATE from historical data
UPDATE employees curr
SET curr.salary = hist.salary
FROM employees BEFORE(STATEMENT => $bad_update_qid) hist
WHERE curr.emp_id = hist.emp_id;

SELECT 'After salary restoration:' AS info;
SELECT * FROM employees ORDER BY emp_id;  -- Original salaries restored


-- 3.C: RECOVER FROM ACCIDENTAL TRUNCATE
-- ---------------------------------------

CREATE OR REPLACE TABLE transactions (
    txn_id   INT,
    account  VARCHAR(20),
    amount   NUMBER(10,2),
    txn_date DATE
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO transactions VALUES
    (1001, 'ACC-001', 5000.00,  '2024-01-15'),
    (1002, 'ACC-002', 12500.50, '2024-01-15'),
    (1003, 'ACC-001', 3200.00,  '2024-01-16'),
    (1004, 'ACC-003', 8750.25,  '2024-01-16'),
    (1005, 'ACC-002', 2100.00,  '2024-01-17');

SELECT COUNT(*) AS row_count_before_truncate FROM transactions;

-- *** SIMULATE ACCIDENT: Truncate the table ***
TRUNCATE TABLE transactions;

SELECT COUNT(*) AS row_count_after_truncate FROM transactions;  -- 0 rows

SET truncate_qid = LAST_QUERY_ID();

-- RECOVERY: TRUNCATE is recoverable via Time Travel (unlike some other databases!)
INSERT INTO transactions
    SELECT * FROM transactions BEFORE(STATEMENT => $truncate_qid);

SELECT COUNT(*) AS row_count_after_recovery FROM transactions;  -- 5 rows back
SELECT * FROM transactions ORDER BY txn_id;


-- 3.D: SELECTIVE ROW RECOVERY (Restore specific records)
-- -------------------------------------------------------

-- *** SIMULATE: Accidental delete of specific customer records ***
DELETE FROM orders WHERE customer IN ('Alice', 'Bob');

SET partial_delete_qid = LAST_QUERY_ID();

-- Recover ONLY the deleted customers (not all rows)
INSERT INTO orders
    SELECT * FROM orders
    BEFORE(STATEMENT => $partial_delete_qid)
    WHERE customer IN ('Alice', 'Bob');

SELECT * FROM orders ORDER BY order_id;


-- ============================================================
-- SECTION 4: FULL TABLE ROLLBACK USING CLONE + SWAP
-- ============================================================
-- Objective: The production-safe rollback pattern
-- ============================================================

-- Setup: Production table with data
CREATE OR REPLACE TABLE products (
    product_id   INT,
    name         VARCHAR(100),
    price        NUMBER(10,2),
    category     VARCHAR(50),
    stock        INT
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO products VALUES
    (1,  'Laptop Pro 15',   1299.99, 'Electronics',  150),
    (2,  'Wireless Mouse',    29.99, 'Electronics',  500),
    (3,  'Office Chair',    249.99,  'Furniture',    75),
    (4,  'USB-C Hub',        49.99,  'Electronics',  300),
    (5,  'Standing Desk',   599.99,  'Furniture',    40),
    (6,  'Webcam HD',        89.99,  'Electronics',  200),
    (7,  'Keyboard Mech',   149.99,  'Electronics',  120),
    (8,  'Monitor 27in',    399.99,  'Electronics',  80),
    (9,  'Bookshelf',       179.99,  'Furniture',    60),
    (10, 'Headset Pro',     199.99,  'Electronics',  90);

-- Mark the good state
SET ts_good_products = CURRENT_TIMESTAMP();
SELECT $ts_good_products AS good_state_time;

SELECT SYSTEM$WAIT(3);

-- *** SIMULATE: A bad batch job corrupts prices ***
UPDATE products SET price = price * 10;  -- Prices multiplied by 10!
DELETE FROM products WHERE category = 'Furniture';  -- Furniture deleted!
INSERT INTO products VALUES (11, 'Fake Product', 9999.99, 'Unknown', 0);

SELECT 'CORRUPTED STATE:' AS info;
SELECT * FROM products ORDER BY product_id;

-- ROLLBACK PATTERN: Clone → Validate → Swap → Clean up

-- Step 1: Create a zero-copy clone at the good historical point
CREATE TABLE products_rollback CLONE products
    AT(TIMESTAMP => $ts_good_products);

-- Step 2: Validate the clone has correct data
SELECT 'VALIDATING ROLLBACK CLONE:' AS info;
SELECT * FROM products_rollback ORDER BY product_id;
SELECT COUNT(*) AS expected_10_rows FROM products_rollback;

-- Step 3: Atomic SWAP (zero downtime)
-- After swap: products = clean data, products_rollback = corrupted data
ALTER TABLE products SWAP WITH products_rollback;

-- Step 4: Verify production table is clean
SELECT 'AFTER SWAP - PRODUCTION TABLE:' AS info;
SELECT * FROM products ORDER BY product_id;  -- Should show original clean data

-- Step 5: Inspect the corrupted data in backup (optional - for audit)
SELECT 'CORRUPTED DATA (in backup table):' AS info;
SELECT * FROM products_rollback ORDER BY product_id;

-- Step 6: Clean up backup table
DROP TABLE products_rollback;


-- ============================================================
-- SECTION 5: DROPPING AND RESTORING OBJECTS (UNDROP)
-- ============================================================
-- Objective: Practice UNDROP at table, schema, database level
-- ============================================================

-- 5.A: UNDROP TABLE
-- -----------------

CREATE OR REPLACE TABLE important_config (
    key   VARCHAR(100),
    value VARCHAR(500)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO important_config VALUES
    ('app_version', '2.5.1'),
    ('max_connections', '100'),
    ('timeout_seconds', '30'),
    ('feature_flag_x', 'enabled');

SELECT * FROM important_config;

-- *** SIMULATE ACCIDENT: Table dropped ***
DROP TABLE important_config;

-- Verify it's gone
SELECT * FROM important_config;  -- This should error

-- List dropped tables still in Time Travel
SHOW TABLES HISTORY IN SCHEMA TT_SCHEMA;
-- Look for important_config with a non-null dropped_on column

-- RESTORE IT
UNDROP TABLE important_config;

-- Verify data is back
SELECT * FROM important_config;
SELECT 'Table restored successfully with ' || COUNT(*) || ' rows' AS status
FROM important_config;


-- 5.B: UNDROP TABLE - NAME CONFLICT SCENARIO
-- -------------------------------------------
-- What happens when you drop a table, create a new one with the same name,
-- then want the ORIGINAL back?

CREATE OR REPLACE TABLE config_v2 (
    setting VARCHAR(100),
    val     VARCHAR(200)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO config_v2 VALUES ('original_setting', 'original_value');

-- Drop it
DROP TABLE config_v2;

-- Someone creates a new table with the same name
CREATE TABLE config_v2 (
    setting VARCHAR(100),
    val     VARCHAR(200)
);
INSERT INTO config_v2 VALUES ('new_setting', 'new_value');

-- Show both versions in history
SHOW TABLES HISTORY LIKE 'config_v2%';

-- Now try to UNDROP -- this will FAIL because name already exists
-- UNDROP TABLE config_v2;  -- Uncomment to see the error

-- CORRECT APPROACH:
-- Step 1: Rename the new (current) table
ALTER TABLE config_v2 RENAME TO config_v2_new;

-- Step 2: Now UNDROP the original
UNDROP TABLE config_v2;

-- Verify original is back
SELECT 'ORIGINAL TABLE (restored):' AS info;
SELECT * FROM config_v2;

SELECT 'NEW TABLE (renamed):' AS info;
SELECT * FROM config_v2_new;

-- Cleanup
DROP TABLE config_v2_new;


-- 5.C: MULTIPLE DROPPED VERSIONS - UNDROP ORDER
-- -----------------------------------------------
-- UNDROP always restores the MOST RECENTLY dropped version first

CREATE TABLE multi_version_table (id INT, data VARCHAR(50))
DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO multi_version_table VALUES (1, 'Version 1 Data');

DROP TABLE multi_version_table;  -- Drop version 1

CREATE TABLE multi_version_table (id INT, data VARCHAR(50))
DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO multi_version_table VALUES (2, 'Version 2 Data');

DROP TABLE multi_version_table;  -- Drop version 2

CREATE TABLE multi_version_table (id INT, data VARCHAR(50))
DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO multi_version_table VALUES (3, 'Version 3 Data - CURRENT');

-- Show all 3 versions
SHOW TABLES HISTORY LIKE 'multi_version_table%';
-- You see: 1 active (version 3), 2 dropped (versions 1 and 2)

-- UNDROP recovers MOST RECENT DROP (version 2) but name conflict with active!
-- Step 1: Rename current (version 3)
ALTER TABLE multi_version_table RENAME TO multi_version_v3;

-- Step 2: UNDROP restores version 2
UNDROP TABLE multi_version_table;
SELECT 'Restored Version 2:' AS info;
SELECT * FROM multi_version_table;  -- Should show Version 2 Data

-- Step 3: Rename version 2 to free the name
ALTER TABLE multi_version_table RENAME TO multi_version_v2;

-- Step 4: UNDROP again restores version 1
UNDROP TABLE multi_version_table;
SELECT 'Restored Version 1:' AS info;
SELECT * FROM multi_version_table;  -- Should show Version 1 Data

-- Cleanup
DROP TABLE multi_version_table;
DROP TABLE multi_version_v2;
DROP TABLE multi_version_v3;


-- 5.D: UNDROP SCHEMA (Restores all child objects)
-- -------------------------------------------------

CREATE SCHEMA IF NOT EXISTS dropped_schema_test;

CREATE TABLE dropped_schema_test.customers (
    id INT, name VARCHAR(100)
) DATA_RETENTION_TIME_IN_DAYS = 1;

CREATE TABLE dropped_schema_test.invoices (
    id INT, amount NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO dropped_schema_test.customers VALUES (1, 'Alice'), (2, 'Bob');
INSERT INTO dropped_schema_test.invoices VALUES (101, 500.00), (102, 750.00);

-- Drop the ENTIRE schema (drops all tables inside too)
DROP SCHEMA dropped_schema_test;

-- Verify schema is gone
SHOW SCHEMAS HISTORY IN DATABASE TT_LAB;

-- RESTORE the schema (restores ALL tables inside)
UNDROP SCHEMA dropped_schema_test;

-- Verify everything came back
USE SCHEMA dropped_schema_test;
SELECT 'customers restored:' AS info;
SELECT * FROM customers;

SELECT 'invoices restored:' AS info;
SELECT * FROM invoices;

-- Switch back to main schema
USE SCHEMA TT_SCHEMA;
DROP SCHEMA dropped_schema_test;


-- 5.E: UNDROP DATABASE (Restores everything)
-- -------------------------------------------

CREATE DATABASE IF NOT EXISTS dropped_db_test;
CREATE SCHEMA dropped_db_test.app_schema;
CREATE TABLE dropped_db_test.app_schema.settings (
    key VARCHAR(50), value VARCHAR(100)
) DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO dropped_db_test.app_schema.settings VALUES
    ('env', 'production'), ('region', 'us-east-1');

-- Drop the entire database
DROP DATABASE dropped_db_test;

SHOW DATABASES HISTORY;  -- See it listed as dropped

-- RESTORE everything
UNDROP DATABASE dropped_db_test;

-- Verify
SELECT * FROM dropped_db_test.app_schema.settings;

-- Switch back and cleanup
USE DATABASE TT_LAB;
USE SCHEMA TT_SCHEMA;
DROP DATABASE dropped_db_test;


-- ============================================================
-- SECTION 6: QUERYING HISTORICAL DATA (ANALYTICAL PATTERNS)
-- ============================================================
-- Objective: Use Time Travel for audit and analysis
-- ============================================================

-- Setup: Table with multiple changes over time
CREATE OR REPLACE TABLE stock_prices (
    symbol      VARCHAR(10),
    price       NUMBER(10,2),
    volume      BIGINT,
    recorded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 1;

-- State 1: Initial prices
INSERT INTO stock_prices (symbol, price, volume) VALUES
    ('AAPL', 185.50, 1000000),
    ('GOOGL', 140.25, 800000),
    ('MSFT', 415.00, 1200000),
    ('AMZN', 185.75, 950000);

SET ts_t1 = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(3);

-- State 2: Prices change
UPDATE stock_prices SET price = price * 1.02, volume = volume + 50000;
SET ts_t2 = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(3);

-- State 3: More changes
UPDATE stock_prices SET price = price * 0.98, volume = volume - 100000;
SET ts_t3 = CURRENT_TIMESTAMP();

-- 6.1 POINT-IN-TIME QUERY: What were prices at T1, T2, T3?
SELECT 'Prices at T1 (initial):' AS timepoint;
SELECT symbol, price, volume FROM stock_prices AT(TIMESTAMP => $ts_t1);

SELECT 'Prices at T2 (after first update):' AS timepoint;
SELECT symbol, price, volume FROM stock_prices AT(TIMESTAMP => $ts_t2);

SELECT 'Prices at T3 (after second update):' AS timepoint;
SELECT symbol, price, volume FROM stock_prices AT(TIMESTAMP => $ts_t3);

SELECT 'Current prices:' AS timepoint;
SELECT symbol, price, volume FROM stock_prices;

-- 6.2 COMPARE CURRENT VS HISTORICAL (price diff analysis)
SELECT
    curr.symbol,
    hist.price   AS price_1hr_ago,
    curr.price   AS current_price,
    ROUND(curr.price - hist.price, 2)                        AS price_change,
    ROUND((curr.price - hist.price) / hist.price * 100, 2)   AS pct_change
FROM stock_prices curr
JOIN stock_prices AT(TIMESTAMP => $ts_t1) hist ON curr.symbol = hist.symbol
ORDER BY pct_change DESC;

-- 6.3 DAILY ROW COUNT TREND (using UNION ALL across time points)
-- This shows how row counts changed at different points
SELECT 'T1' AS timepoint, COUNT(*) AS row_count FROM stock_prices AT(TIMESTAMP => $ts_t1)
UNION ALL
SELECT 'T2', COUNT(*) FROM stock_prices AT(TIMESTAMP => $ts_t2)
UNION ALL
SELECT 'T3', COUNT(*) FROM stock_prices AT(TIMESTAMP => $ts_t3)
UNION ALL
SELECT 'CURRENT', COUNT(*) FROM stock_prices;

-- 6.4 SELF-JOIN FOR CHANGE DETECTION
-- Find all rows that changed between two points
SELECT
    t1.symbol,
    t1.price   AS old_price,
    t2.price   AS new_price,
    t1.volume  AS old_volume,
    t2.volume  AS new_volume
FROM stock_prices AT(TIMESTAMP => $ts_t1) t1
JOIN stock_prices AT(TIMESTAMP => $ts_t2) t2 ON t1.symbol = t2.symbol
WHERE t1.price <> t2.price OR t1.volume <> t2.volume;

-- 6.5 FIND ROWS THAT WERE DELETED (using MINUS / EXCEPT)
-- Simulate: Delete some rows
DELETE FROM stock_prices WHERE symbol IN ('AMZN');
SET ts_after_delete = CURRENT_TIMESTAMP();

-- Find what was deleted
SELECT 'Rows deleted since T3:' AS info;
SELECT symbol, price FROM stock_prices AT(TIMESTAMP => $ts_t3)
MINUS
SELECT symbol, price FROM stock_prices;

-- 6.6 FIND ROWS THAT WERE INSERTED
SELECT 'Rows added since T1:' AS info;
SELECT symbol, price FROM stock_prices
MINUS
SELECT symbol, price FROM stock_prices AT(TIMESTAMP => $ts_t1);


-- ============================================================
-- SECTION 7: CLONING WITH TIME TRAVEL
-- ============================================================
-- Objective: Create historical clones for backup and testing
-- ============================================================

-- Setup: A table with history
CREATE OR REPLACE TABLE sales_data (
    sale_id     INT,
    region      VARCHAR(50),
    product     VARCHAR(100),
    revenue     NUMBER(12,2),
    sale_date   DATE
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO sales_data VALUES
    (1, 'North', 'Product A', 50000.00, '2024-01-10'),
    (2, 'South', 'Product B', 75000.00, '2024-01-11'),
    (3, 'East',  'Product A', 62000.00, '2024-01-12'),
    (4, 'West',  'Product C', 45000.00, '2024-01-13'),
    (5, 'North', 'Product B', 88000.00, '2024-01-14');

SET ts_before_changes = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(3);

-- Make changes (bad ETL run simulation)
UPDATE sales_data SET revenue = revenue * 0.1;  -- Wrong! Revenue decimated
INSERT INTO sales_data VALUES (99, 'UNKNOWN', 'BAD DATA', -1.00, '1900-01-01');

-- 7.1 CREATE TABLE CLONE at historical point (zero-copy)
CREATE TABLE sales_data_backup CLONE sales_data
    AT(TIMESTAMP => $ts_before_changes);

-- Verify the clone has clean data
SELECT 'Clone contains clean data:' AS info;
SELECT * FROM sales_data_backup ORDER BY sale_id;

-- Verify current table has bad data
SELECT 'Current table has corrupted data:' AS info;
SELECT * FROM sales_data ORDER BY sale_id;

-- 7.2 Clone with OFFSET
CREATE TABLE sales_data_5min_ago CLONE sales_data
    AT(OFFSET => -300);  -- 5 minutes ago

SELECT * FROM sales_data_5min_ago ORDER BY sale_id;
DROP TABLE sales_data_5min_ago;  -- Cleanup

-- 7.3 Clone with STATEMENT (before a specific DML)
SET bad_update_id = LAST_QUERY_ID(-2);  -- Get ID of the bad UPDATE above

CREATE TABLE sales_data_before_bad_update CLONE sales_data
    BEFORE(STATEMENT => $bad_update_id);

SELECT 'Clone from BEFORE bad update:' AS info;
SELECT * FROM sales_data_before_bad_update ORDER BY sale_id;

DROP TABLE sales_data_before_bad_update;

-- 7.4 CREATE SCHEMA CLONE at historical point
CREATE SCHEMA IF NOT EXISTS source_schema_for_clone;
USE SCHEMA source_schema_for_clone;

CREATE TABLE t_alpha (id INT, val VARCHAR(50)) DATA_RETENTION_TIME_IN_DAYS = 1;
CREATE TABLE t_beta  (id INT, val VARCHAR(50)) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO t_alpha VALUES (1, 'alpha_row1'), (2, 'alpha_row2');
INSERT INTO t_beta  VALUES (1, 'beta_row1'),  (2, 'beta_row2');

SET ts_schema_good = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(3);

-- Corrupt some data
UPDATE t_alpha SET val = 'CORRUPTED';

USE SCHEMA TT_SCHEMA;

-- Clone the ENTIRE SCHEMA at historical point
CREATE SCHEMA schema_clone CLONE source_schema_for_clone
    AT(TIMESTAMP => $ts_schema_good);

-- Verify both tables restored in schema clone
SELECT 'Alpha table in clone:' AS info;
SELECT * FROM schema_clone.t_alpha;

SELECT 'Beta table in clone:' AS info;
SELECT * FROM schema_clone.t_beta;

-- Cleanup
DROP SCHEMA schema_clone;
DROP SCHEMA source_schema_for_clone;

-- 7.5 IGNORE TABLES WITH INSUFFICIENT DATA RETENTION
-- Used when some child tables have 0-day retention in a database/schema clone

CREATE TABLE sales_data_no_tt (
    id INT, data VARCHAR(50)
) DATA_RETENTION_TIME_IN_DAYS = 0;

INSERT INTO sales_data_no_tt VALUES (1, 'no time travel table');

-- Without IGNORE TABLES: would fail if any table has no TT coverage for the timestamp
-- With IGNORE TABLES: skips those tables and clones the rest
CREATE TABLE sales_data_backup_safe CLONE sales_data
    AT(TIMESTAMP => $ts_before_changes)
    IGNORE TABLES WITH INSUFFICIENT DATA RETENTION;

SELECT * FROM sales_data_backup_safe ORDER BY sale_id;

DROP TABLE sales_data_backup_safe;
DROP TABLE sales_data_no_tt;
DROP TABLE sales_data_backup;


-- ============================================================
-- SECTION 8: TRANSIENT AND TEMPORARY TABLES
-- ============================================================
-- Objective: Understand Time Travel limits for transient/temp
-- ============================================================

-- 8.1 TRANSIENT TABLE - Max 1 day retention, NO Fail-safe

CREATE TRANSIENT TABLE transient_staging (
    id      INT,
    batch   VARCHAR(50),
    payload VARCHAR(1000)
) DATA_RETENTION_TIME_IN_DAYS = 1;

-- Verify it's transient and has 1-day max
SHOW TABLES LIKE 'transient_staging';

INSERT INTO transient_staging VALUES
    (1, 'batch_001', '{"key": "value1"}'),
    (2, 'batch_001', '{"key": "value2"}'),
    (3, 'batch_002', '{"key": "value3"}');

-- Time Travel WORKS on transient tables (within 1 day)
SET ts_transient_start = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(2);
DELETE FROM transient_staging WHERE id = 2;

-- Recover the deleted row
INSERT INTO transient_staging
    SELECT * FROM transient_staging
    BEFORE(STATEMENT => LAST_QUERY_ID())
    WHERE id = 2;

SELECT * FROM transient_staging ORDER BY id;

-- 8.2 Try setting retention > 1 on transient (SHOULD FAIL)
-- Uncomment the next line to see the error:
-- ALTER TABLE transient_staging SET DATA_RETENTION_TIME_IN_DAYS = 5;
-- ERROR: Object does not support the specified retention time.

-- 8.3 TRANSIENT SCHEMA - All tables inside are transient by default

CREATE TRANSIENT SCHEMA staging_area;

CREATE TABLE staging_area.raw_events (
    event_id   INT,
    event_type VARCHAR(50),
    payload    VARCHAR(1000)
);
-- This table is automatically TRANSIENT (no explicit keyword needed)

SHOW TABLES IN SCHEMA staging_area;
-- retention_time = 1, kind = TABLE (transient by nature)

DROP SCHEMA staging_area;

-- 8.4 TEMPORARY TABLE - Exists only for session duration

CREATE TEMPORARY TABLE temp_calc (
    id     INT,
    result NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO temp_calc VALUES (1, 100.0), (2, 200.0), (3, 300.0);

-- Time Travel works within the session
SET ts_temp_start = CURRENT_TIMESTAMP();
UPDATE temp_calc SET result = result * -1;

SELECT 'Temp table negative values:' AS info;
SELECT * FROM temp_calc;

SELECT 'Temp table original values:' AS info;
SELECT * FROM temp_calc AT(TIMESTAMP => $ts_temp_start);

-- Note: When session ends, temp table is dropped permanently.
-- No Fail-safe means data is truly gone after session.


-- ============================================================
-- SECTION 9: CHANGES CLAUSE - CDC WITHOUT STREAMS
-- ============================================================
-- Objective: Query change tracking metadata using CHANGES
-- ============================================================

-- Setup: Enable change tracking on a table
CREATE OR REPLACE TABLE inventory (
    item_id     INT,
    item_name   VARCHAR(100),
    quantity    INT,
    last_update TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 1;

-- REQUIRED: Enable change tracking
ALTER TABLE inventory SET CHANGE_TRACKING = TRUE;

-- Verify change tracking is on
SHOW TABLES LIKE 'inventory';
-- Look for change_tracking = ON

SET ts_changes_start = CURRENT_TIMESTAMP();

INSERT INTO inventory (item_id, item_name, quantity) VALUES
    (1, 'Laptop',   50),
    (2, 'Monitor',  80),
    (3, 'Keyboard', 200),
    (4, 'Mouse',    250),
    (5, 'Webcam',   100);

SELECT SYSTEM$WAIT(2);
SET ts_after_inserts = CURRENT_TIMESTAMP();

-- Make various DML changes
UPDATE inventory SET quantity = quantity - 10 WHERE item_id IN (1, 2);
DELETE FROM inventory WHERE item_id = 5;
INSERT INTO inventory (item_id, item_name, quantity) VALUES (6, 'Headset', 75);

SET ts_after_mixed_dml = CURRENT_TIMESTAMP();

-- 9.1 DEFAULT changes (all DML: inserts, updates, deletes)
SELECT 'ALL CHANGES since start:' AS info;
SELECT
    METADATA$ACTION,
    METADATA$ISUPDATE,
    item_id,
    item_name,
    quantity
FROM inventory
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_changes_start);
-- You see: INSERTs, UPDATE (as DELETE old + INSERT new), DELETE

-- 9.2 APPEND_ONLY changes (only net-new inserts)
SELECT 'APPEND-ONLY CHANGES (net new inserts):' AS info;
SELECT
    METADATA$ACTION,
    item_id,
    item_name,
    quantity
FROM inventory
CHANGES(INFORMATION => APPEND_ONLY)
    AT(TIMESTAMP => $ts_changes_start);
-- Only items 1-4 and 6 (item 5 was inserted AND deleted, so not in APPEND_ONLY)

-- 9.3 CHANGES with END clause (windowed interval)
SELECT 'CHANGES in a specific window (inserts only to after_inserts):' AS info;
SELECT
    METADATA$ACTION,
    item_id,
    item_name,
    quantity
FROM inventory
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_changes_start)
    END(TIMESTAMP => $ts_after_inserts);

-- 9.4 Understanding METADATA columns
SELECT
    METADATA$ACTION     AS action,        -- INSERT or DELETE
    METADATA$ISUPDATE   AS is_update,     -- TRUE if this is from an UPDATE
    METADATA$ROW_ID     AS row_id,        -- Immutable internal row identifier
    item_id,
    item_name,
    quantity
FROM inventory
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_after_inserts);
-- UPDATE shows as 2 rows: DELETE (old values, ISUPDATE=TRUE) + INSERT (new values, ISUPDATE=TRUE)
-- Pure DELETE shows as DELETE (ISUPDATE=FALSE)
-- Pure INSERT shows as INSERT (ISUPDATE=FALSE)

-- 9.5 Count changes by action type
SELECT
    METADATA$ACTION AS action,
    COUNT(*)        AS count
FROM inventory
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_changes_start)
GROUP BY METADATA$ACTION
ORDER BY METADATA$ACTION;


-- ============================================================
-- SECTION 10: TIME TRAVEL WITH STREAMS
-- ============================================================
-- Objective: Understand how Streams use Time Travel internally
-- ============================================================

CREATE OR REPLACE TABLE source_orders (
    order_id INT,
    product  VARCHAR(100),
    qty      INT,
    price    NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO source_orders VALUES
    (1, 'Widget A', 10, 25.00),
    (2, 'Widget B', 5,  49.99),
    (3, 'Widget C', 20, 12.50);

-- 10.1 Create a standard stream
CREATE OR REPLACE STREAM orders_cdc_stream ON TABLE source_orders;

-- Check stream properties including stale_after
SHOW STREAMS LIKE 'orders_cdc_stream';
-- stale_after tells you when the stream will become stale

-- 10.2 Make changes - stream should capture them
INSERT INTO source_orders VALUES (4, 'Widget D', 8, 35.00);
UPDATE source_orders SET qty = qty + 5 WHERE order_id = 1;
DELETE FROM source_orders WHERE order_id = 3;

-- 10.3 Query the stream (but DON'T consume it yet - no DML transaction)
SELECT 'Stream contents (unconsumed):' AS info;
SELECT
    METADATA$ACTION,
    METADATA$ISUPDATE,
    order_id, product, qty, price
FROM orders_cdc_stream;
-- Shows INSERT for order_id=4, UPDATE (as DELETE+INSERT) for order_id=1,
-- DELETE for order_id=3

-- 10.4 Check if stream has data
SELECT SYSTEM$STREAM_HAS_DATA('orders_cdc_stream') AS has_data;

-- 10.5 Use AT(STREAM => ...) to see table at stream's current offset
SELECT 'Table state at stream offset:' AS info;
SELECT * FROM source_orders AT(STREAM => 'orders_cdc_stream');
-- This is the state BEFORE the unconsumed changes in the stream

-- 10.6 Create a new stream at the SAME offset as existing stream
CREATE OR REPLACE STREAM orders_cdc_stream_copy ON TABLE source_orders
    AT(STREAM => 'orders_cdc_stream');

SELECT 'Copy stream contents (same offset):' AS info;
SELECT METADATA$ACTION, order_id, product FROM orders_cdc_stream_copy;

-- 10.7 Demonstrate staleness concept
-- The stream's stale_after is tied to the table's retention period.
-- If we set table retention to 0, the stream immediately goes stale.
-- (We won't do this destructively - just observe the concept)

SHOW STREAMS LIKE 'orders_cdc_stream';
-- See stale_after timestamp = now + MAX(DATA_RETENTION, MAX_DATA_EXTENSION)

-- 10.8 MAX_DATA_EXTENSION_TIME_IN_DAYS
-- Snowflake automatically extends table retention (up to this value)
-- to prevent streams from going stale

SHOW PARAMETERS LIKE 'MAX_DATA_EXTENSION_TIME_IN_DAYS' IN TABLE source_orders;

-- Set a custom extension limit for a specific table
ALTER TABLE source_orders SET MAX_DATA_EXTENSION_TIME_IN_DAYS = 7;
SHOW PARAMETERS LIKE 'MAX_DATA_EXTENSION_TIME_IN_DAYS' IN TABLE source_orders;

-- Reset it
ALTER TABLE source_orders UNSET MAX_DATA_EXTENSION_TIME_IN_DAYS;

-- Cleanup
DROP STREAM orders_cdc_stream_copy;


-- ============================================================
-- SECTION 11: SCHEMA EVOLUTION AND TIME TRAVEL
-- ============================================================
-- Objective: Understand how schema changes interact with Time Travel.
-- IMPORTANT: Historical queries use CURRENT schema, not historical schema.
-- ============================================================

CREATE OR REPLACE TABLE schema_evolution_test (
    id      INT,
    name    VARCHAR(100),
    email   VARCHAR(200)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO schema_evolution_test (id, name, email) VALUES
    (1, 'Alice', 'alice@example.com'),
    (2, 'Bob',   'bob@example.com');

SET ts_pre_schema_change = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(3);

-- Add a new column
ALTER TABLE schema_evolution_test ADD COLUMN phone VARCHAR(20);

-- Insert a row with the new column
INSERT INTO schema_evolution_test VALUES (3, 'Charlie', 'charlie@example.com', '555-1234');

-- 11.1 Query historical data - NOTE: the new column appears with NULLs for old rows
SELECT 'Historical data (uses CURRENT schema - new column shows NULL for old rows):' AS info;
SELECT * FROM schema_evolution_test
AT(TIMESTAMP => $ts_pre_schema_change);
-- You see columns: id, name, email, phone
-- Rows 1 and 2 show phone = NULL (column didn't exist then, but current schema is used)

SELECT 'Current data:' AS info;
SELECT * FROM schema_evolution_test ORDER BY id;
-- Row 3 has phone populated

-- 11.2 Drop a column and observe
ALTER TABLE schema_evolution_test DROP COLUMN email;

-- Historical query still uses current schema (no email column)
SELECT 'Historical data after column drop:' AS info;
SELECT * FROM schema_evolution_test
AT(TIMESTAMP => $ts_pre_schema_change);
-- email column is gone from results even though it existed at that time!
-- This is the key caveat: current schema is always used


-- ============================================================
-- SECTION 12: TIME TRAVEL AND RENAME OPERATIONS
-- ============================================================
-- Objective: Verify that RENAME preserves Time Travel history
-- ============================================================

CREATE OR REPLACE TABLE original_name (
    id    INT,
    value VARCHAR(100)
) DATA_RETENTION_TIME_IN_DAYS = 1;

INSERT INTO original_name VALUES (1, 'row one'), (2, 'row two');

SET ts_before_rename = CURRENT_TIMESTAMP();
SELECT SYSTEM$WAIT(2);

UPDATE original_name SET value = 'updated row one' WHERE id = 1;

-- Rename the table
ALTER TABLE original_name RENAME TO renamed_table;

-- Time Travel STILL WORKS after rename (history is preserved)
SELECT 'Historical data accessible after rename:' AS info;
SELECT * FROM renamed_table AT(TIMESTAMP => $ts_before_rename) ORDER BY id;
-- Shows 'row one' (original value) - rename didn't break history

-- Move table to different schema via rename
USE SCHEMA TT_SCHEMA;
CREATE SCHEMA IF NOT EXISTS other_schema;

ALTER TABLE renamed_table RENAME TO other_schema.renamed_table;

-- Time Travel still works after cross-schema move
SELECT * FROM other_schema.renamed_table AT(TIMESTAMP => $ts_before_rename);

-- Cleanup
DROP SCHEMA other_schema;


-- ============================================================
-- SECTION 13: STORAGE METRICS AND MONITORING
-- ============================================================
-- Objective: Monitor Time Travel storage consumption
-- ============================================================

-- 13.1 Check Time Travel storage for all tables in account
SELECT
    table_catalog,
    table_schema,
    table_name,
    ROUND(active_bytes / 1024 / 1024, 2)              AS active_mb,
    ROUND(time_travel_bytes / 1024 / 1024, 2)          AS time_travel_mb,
    ROUND(failsafe_bytes / 1024 / 1024, 2)             AS failsafe_mb,
    ROUND(retained_for_clone_bytes / 1024 / 1024, 2)   AS retained_for_clone_mb,
    table_dropped
FROM snowflake.account_usage.table_storage_metrics
WHERE table_catalog = 'TT_LAB'
  AND (active_bytes > 0 OR time_travel_bytes > 0 OR failsafe_bytes > 0)
ORDER BY time_travel_bytes DESC
LIMIT 20;

-- 13.2 High-churn table analysis (Time Travel ratio)
SELECT
    table_name,
    active_bytes,
    time_travel_bytes,
    failsafe_bytes,
    CASE
        WHEN active_bytes > 0
        THEN ROUND(time_travel_bytes / active_bytes, 2)
        ELSE NULL
    END AS tt_to_active_ratio
FROM snowflake.account_usage.table_storage_metrics
WHERE table_catalog = 'TT_LAB'
  AND active_bytes > 0
ORDER BY tt_to_active_ratio DESC NULLS LAST;

-- 13.3 Find tables with Time Travel disabled (retention = 0)
SELECT
    table_schema,
    table_name,
    retention_time
FROM information_schema.tables
WHERE table_schema = 'TT_SCHEMA'
  AND retention_time = 0;

-- 13.4 Audit: Tables with non-standard retention
SELECT
    table_schema,
    table_name,
    retention_time,
    table_type
FROM information_schema.tables
WHERE table_schema = 'TT_SCHEMA'
  AND retention_time > 1
ORDER BY retention_time DESC;

-- 13.5 Find all dropped tables still in Time Travel (still costing storage)
SHOW TABLES HISTORY IN SCHEMA TT_SCHEMA;
-- Any row with non-NULL dropped_on is consuming Time Travel storage


-- ============================================================
-- SECTION 14: RETENTION CHANGE BEHAVIOR (INCREASE vs DECREASE)
-- ============================================================
-- Objective: Understand what happens when you change retention
-- ============================================================

CREATE OR REPLACE TABLE retention_test (
    id   INT,
    data VARCHAR(100)
) DATA_RETENTION_TIME_IN_DAYS = 3;

INSERT INTO retention_test VALUES (1, 'A'), (2, 'B'), (3, 'C');
SELECT SYSTEM$WAIT(2);
UPDATE retention_test SET data = 'A_updated' WHERE id = 1;

-- 14.1 Verify current retention
SHOW TABLES LIKE 'retention_test';

-- 14.2 INCREASE RETENTION: Existing Time Travel data gets kept longer
ALTER TABLE retention_test SET DATA_RETENTION_TIME_IN_DAYS = 7;
SHOW TABLES LIKE 'retention_test';

-- 14.3 DECREASE RETENTION: Data outside new window is purged
-- (background process, not immediate)
ALTER TABLE retention_test SET DATA_RETENTION_TIME_IN_DAYS = 1;
SHOW TABLES LIKE 'retention_test';
-- Note: TIME_TRAVEL_BYTES in storage metrics may temporarily show old data
-- until background process completes

-- 14.4 DISABLE Time Travel by setting to 0
ALTER TABLE retention_test SET DATA_RETENTION_TIME_IN_DAYS = 0;
SHOW TABLES LIKE 'retention_test';

-- With retention = 0, dropping the table makes it unrecoverable
-- DROP TABLE retention_test;
-- UNDROP TABLE retention_test;  -- This would FAIL since no Time Travel

-- Re-enable
ALTER TABLE retention_test SET DATA_RETENTION_TIME_IN_DAYS = 1;


-- ============================================================
-- SECTION 15: DROPPED CONTAINER RETENTION INHERITANCE GOTCHA
-- ============================================================
-- Objective: Understand how dropped schemas ignore child retention
-- ============================================================

CREATE SCHEMA IF NOT EXISTS parent_schema_test
    DATA_RETENTION_TIME_IN_DAYS = 1;

USE SCHEMA parent_schema_test;

-- Child table with EXPLICITLY longer retention
CREATE TABLE child_long_retention (
    id INT
) DATA_RETENTION_TIME_IN_DAYS = 7;  -- Explicitly set to 7 days

-- Child table with schema-default retention
CREATE TABLE child_default_retention (
    id INT
);

INSERT INTO child_long_retention VALUES (1), (2), (3);
INSERT INTO child_default_retention VALUES (10), (20);

SHOW TABLES IN SCHEMA parent_schema_test;
-- child_long_retention shows retention_time = 7
-- child_default_retention shows retention_time = 1

-- THE GOTCHA: When schema is dropped, children follow SCHEMA retention
-- even if they had explicit longer retention
DROP SCHEMA parent_schema_test;

-- The schema and its tables are now in Time Travel
SHOW SCHEMAS HISTORY IN DATABASE TT_LAB;

-- Both tables are retained for SCHEMA's retention (1 day)
-- NOT child_long_retention's 7-day explicit setting
-- This is documented Snowflake behavior

-- RESTORE to demonstrate
UNDROP SCHEMA parent_schema_test;
SELECT 'Both tables restored:' AS info;
SHOW TABLES IN SCHEMA parent_schema_test;

-- Cleanup
USE SCHEMA TT_SCHEMA;
DROP SCHEMA parent_schema_test;


-- ============================================================
-- SECTION 16: MIN_DATA_RETENTION_TIME_IN_DAYS (COMPLIANCE FLOOR)
-- ============================================================
-- Objective: Understand the account-level minimum retention
-- NOTE: Requires ACCOUNTADMIN role
-- ============================================================

-- Check current min retention setting
SHOW PARAMETERS LIKE 'MIN_DATA_RETENTION_TIME_IN_DAYS';

-- To set a minimum (ACCOUNTADMIN required):
-- ALTER ACCOUNT SET MIN_DATA_RETENTION_TIME_IN_DAYS = 3;

-- After setting MIN=3, a table with DATA_RETENTION=0 will effectively have 3 days
-- Effective retention = MAX(DATA_RETENTION_TIME_IN_DAYS, MIN_DATA_RETENTION_TIME_IN_DAYS)

-- Example verification:
CREATE OR REPLACE TABLE min_retention_demo (id INT, data VARCHAR(50))
    DATA_RETENTION_TIME_IN_DAYS = 0;  -- Trying to disable TT

SHOW TABLES LIKE 'min_retention_demo';
-- If MIN is set > 0, the effective retention shown will be the MIN value
-- even though we set 0 explicitly

-- Reset MIN (ACCOUNTADMIN required):
-- ALTER ACCOUNT UNSET MIN_DATA_RETENTION_TIME_IN_DAYS;

DROP TABLE min_retention_demo;


-- ============================================================
-- SECTION 17: EDGE CASES AND COMMON MISTAKES
-- ============================================================
-- Objective: Test boundary conditions and gotchas
-- ============================================================

-- 17.1 POSITIVE OFFSET (Future time - should ERROR)
CREATE OR REPLACE TABLE edge_test (id INT, val VARCHAR(50))
    DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO edge_test VALUES (1, 'test');

-- This WILL FAIL - positive offset = future time, not supported
-- Uncomment to see the error:
-- SELECT * FROM edge_test AT(OFFSET => 3600);
-- Error: Relative time is in the future

-- 17.2 TIMESTAMP BEFORE TABLE CREATION (should ERROR)
SET ts_way_in_past = '2020-01-01 00:00:00'::TIMESTAMP_NTZ;
-- This WILL FAIL - table didn't exist in 2020
-- Uncomment to see the error:
-- SELECT * FROM edge_test AT(TIMESTAMP => $ts_way_in_past);
-- Error: Object does not exist at timestamp or specified time is before the table was created

-- 17.3 AT | BEFORE on CTEs (NOT supported)
-- Uncomment to see the error:
-- WITH my_cte AS (SELECT * FROM edge_test)
-- SELECT * FROM my_cte AT(OFFSET => -60);
-- Error: Unsupported feature

-- Workaround for CTE limitation:
WITH my_cte AS (SELECT * FROM edge_test AT(OFFSET => -5))
SELECT * FROM my_cte;
-- Apply AT/BEFORE to the base table INSIDE the CTE

-- 17.4 AT | BEFORE on VIEWS (NOT supported directly)
CREATE OR REPLACE VIEW edge_test_view AS
    SELECT id, val FROM edge_test;

-- This WILL FAIL:
-- SELECT * FROM edge_test_view AT(OFFSET => -60);
-- Error: Time travel is not supported for views

-- Workaround: Query the underlying table directly
SELECT * FROM edge_test AT(OFFSET => -5);

-- 17.5 UNDROP when object with same name exists (name conflict)
CREATE OR REPLACE TABLE conflict_table (id INT) DATA_RETENTION_TIME_IN_DAYS = 1;
INSERT INTO conflict_table VALUES (1);

DROP TABLE conflict_table;

CREATE TABLE conflict_table (id INT);  -- New table, same name

-- This WILL FAIL - name conflict:
-- UNDROP TABLE conflict_table;
-- Error: Object already exists

-- Correct approach:
ALTER TABLE conflict_table RENAME TO conflict_table_new;
UNDROP TABLE conflict_table;
SELECT 'Original table restored:' AS info;
SELECT * FROM conflict_table;  -- Should show original row (1)

DROP TABLE conflict_table;
DROP TABLE conflict_table_new;

-- 17.6 TABLE WITH retention=0 dropped - UNRECOVERABLE
CREATE TABLE gone_forever (id INT) DATA_RETENTION_TIME_IN_DAYS = 0;
INSERT INTO gone_forever VALUES (1);
DROP TABLE gone_forever;

-- This WILL FAIL - no Time Travel data exists:
-- UNDROP TABLE gone_forever;
-- Error: No recoverable versions of object 'gone_forever' found in namespace...

-- 17.7 BEFORE clause does NOT support TIMESTAMP or OFFSET in isolation
-- Only STATEMENT works with BEFORE in the strictest sense for precise recovery
-- (Though BEFORE TIMESTAMP and BEFORE OFFSET work but are less precise)
SELECT * FROM edge_test BEFORE(STATEMENT => LAST_QUERY_ID());
-- Works, shows state before last query

-- 17.8 Time Travel with LIMIT (works fine)
SELECT * FROM orders AT(OFFSET => -60) LIMIT 3 ORDER BY order_id;

-- 17.9 Time Travel with WHERE filters (works fine)
SELECT * FROM orders AT(OFFSET => -60) WHERE customer = 'Alice';

-- 17.10 Time Travel with aggregations (works fine)
SELECT COUNT(*), SUM(amount) FROM orders AT(OFFSET => -60);


-- ============================================================
-- SECTION 18: TIME TRAVEL WITH ACCESS CONTROL
-- ============================================================
-- Objective: Understand that TT respects existing privileges
-- ============================================================

-- 18.1 Time Travel uses the SAME privileges as regular queries
-- If you have SELECT on a table, you can use AT/BEFORE on it
-- No special TIME_TRAVEL privilege exists

-- 18.2 For UNDROP, you need OWNERSHIP + CREATE on parent
-- Check what privileges you have
SHOW GRANTS ON TABLE orders;

-- 18.3 Verify current role can do Time Travel (SELECT privilege)
-- If your role has SELECT, this works:
SELECT COUNT(*) FROM orders AT(OFFSET => -10);

-- 18.4 The HISTORY in SHOW commands doesn't require special privs
-- It shows what you have access to
SHOW TABLES HISTORY IN SCHEMA TT_SCHEMA;


-- ============================================================
-- SECTION 19: TIME TRAVEL WITH COPY INTO / SNOWPIPE DATA
-- ============================================================
-- Objective: Understand that COPY INTO DML is recoverable
-- ============================================================

-- Create a target table for loading
CREATE OR REPLACE TABLE copy_target (
    id       INT,
    name     VARCHAR(100),
    amount   NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

SET ts_before_load = CURRENT_TIMESTAMP();

-- Simulate what COPY INTO does (INSERT INTO as equivalent for testing)
INSERT INTO copy_target VALUES
    (1, 'Record A', 1000.00),
    (2, 'Record B', 2000.00),
    (3, 'Record C', 3000.00);

SET load_query_id = LAST_QUERY_ID();

SELECT 'Loaded 3 records:' AS info;
SELECT * FROM copy_target;

-- Simulate: The loaded data was wrong
-- Recovery: Undo the load using Time Travel
-- Option 1: Truncate and reload correct data
TRUNCATE TABLE copy_target;
SET truncate_qid = LAST_QUERY_ID();

-- Verify empty
SELECT COUNT(*) AS empty_check FROM copy_target;

-- Recover the pre-truncate state if needed
INSERT INTO copy_target
    SELECT * FROM copy_target BEFORE(STATEMENT => $truncate_qid);

SELECT 'Recovered data:' AS info;
SELECT * FROM copy_target ORDER BY id;


-- ============================================================
-- SECTION 20: COMPREHENSIVE AUDIT TRAIL PATTERN
-- ============================================================
-- Objective: Build a complete audit using Time Travel + CHANGES
-- ============================================================

CREATE OR REPLACE TABLE audit_subject (
    record_id  INT,
    category   VARCHAR(50),
    status     VARCHAR(20),
    value      NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 1;

ALTER TABLE audit_subject SET CHANGE_TRACKING = TRUE;

SET ts_audit_start = CURRENT_TIMESTAMP();

-- Simulate various operations over time
INSERT INTO audit_subject VALUES
    (1, 'A', 'ACTIVE', 100.00),
    (2, 'B', 'ACTIVE', 200.00),
    (3, 'C', 'ACTIVE', 300.00);

SELECT SYSTEM$WAIT(2);
SET ts_audit_mid1 = CURRENT_TIMESTAMP();

UPDATE audit_subject SET status = 'INACTIVE', value = 150.00 WHERE record_id = 1;
DELETE FROM audit_subject WHERE record_id = 3;
INSERT INTO audit_subject VALUES (4, 'D', 'ACTIVE', 400.00);

SELECT SYSTEM$WAIT(2);
SET ts_audit_mid2 = CURRENT_TIMESTAMP();

UPDATE audit_subject SET value = value * 1.1 WHERE status = 'ACTIVE';

-- 20.1 Full change history with labels
SELECT
    METADATA$ACTION                                         AS action,
    METADATA$ISUPDATE                                       AS is_update,
    record_id,
    category,
    status,
    value,
    'From start to now'                                     AS period
FROM audit_subject
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_audit_start)
ORDER BY record_id, METADATA$ACTION;

-- 20.2 Reconstruct change log with timestamps using UNION ALL at each window
SELECT ts_audit_start::VARCHAR   AS snapshot_time, 'T0' AS label, * FROM audit_subject AT(TIMESTAMP => $ts_audit_start)
UNION ALL
SELECT ts_audit_mid1::VARCHAR,   'T1',             * FROM audit_subject AT(TIMESTAMP => $ts_audit_mid1)
UNION ALL
SELECT ts_audit_mid2::VARCHAR,   'T2',             * FROM audit_subject AT(TIMESTAMP => $ts_audit_mid2)
UNION ALL
SELECT CURRENT_TIMESTAMP()::VARCHAR, 'CURRENT',   * FROM audit_subject
ORDER BY label, record_id;

-- 20.3 Net changes only (what was the net effect end-to-end)
SELECT
    METADATA$ACTION AS net_action,
    record_id, category, status, value
FROM audit_subject
CHANGES(INFORMATION => DEFAULT)
    AT(TIMESTAMP => $ts_audit_start)
ORDER BY record_id, net_action;
-- A row inserted+updated will show as INSERT (new values)
-- A row inserted+deleted will NOT appear (net effect = nothing)


-- ============================================================
-- SECTION 21: FINAL CLEANUP
-- ============================================================

USE DATABASE TT_LAB;
USE SCHEMA TT_SCHEMA;

-- Drop all tables created in this lab
DROP TABLE IF EXISTS tbl_default_retention;
DROP TABLE IF EXISTS tbl_5day_retention;
DROP TABLE IF EXISTS tbl_no_retention;
DROP TABLE IF EXISTS tbl_inherits_schema;
DROP TABLE IF EXISTS tbl_overrides_schema;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS important_config;
DROP TABLE IF EXISTS stock_prices;
DROP TABLE IF EXISTS sales_data;
DROP TABLE IF EXISTS transient_staging;
DROP TABLE IF EXISTS temp_calc;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS source_orders;
DROP TABLE IF EXISTS schema_evolution_test;
DROP TABLE IF EXISTS retention_test;
DROP TABLE IF EXISTS edge_test;
DROP TABLE IF EXISTS copy_target;
DROP TABLE IF EXISTS audit_subject;
DROP TABLE IF EXISTS orders_stream;

DROP STREAM IF EXISTS orders_cdc_stream;
DROP STREAM IF EXISTS orders_cdc_stream_copy;

DROP VIEW IF EXISTS edge_test_view;

-- Drop the lab database entirely (if you want full cleanup)
-- USE ROLE SYSADMIN;
-- DROP DATABASE TT_LAB;

SELECT 'Lab cleanup complete!' AS status;

-- ============================================================
-- QUICK REFERENCE CHEAT SHEET
-- ============================================================
/*

=== AT | BEFORE SYNTAX ===

SELECT * FROM <table> AT(TIMESTAMP => '<datetime>'::TIMESTAMP_TZ);
SELECT * FROM <table> AT(OFFSET => -<seconds>);
SELECT * FROM <table> AT(STATEMENT => '<query_id>');
SELECT * FROM <table> AT(STREAM => '<stream_name>');
SELECT * FROM <table> BEFORE(STATEMENT => '<query_id>');

=== CLONE WITH TIME TRAVEL ===

CREATE TABLE t2 CLONE t1 AT(TIMESTAMP => '<datetime>'::TIMESTAMP_TZ);
CREATE TABLE t2 CLONE t1 AT(OFFSET => -3600);
CREATE TABLE t2 CLONE t1 BEFORE(STATEMENT => '<query_id>');
CREATE SCHEMA s2 CLONE s1 AT(OFFSET => -3600);
CREATE DATABASE db2 CLONE db1 AT(OFFSET => -86400)
    IGNORE TABLES WITH INSUFFICIENT DATA RETENTION;

=== UNDROP ===

UNDROP TABLE <name>;
UNDROP SCHEMA <name>;
UNDROP DATABASE <name>;

=== SHOW HISTORY ===

SHOW TABLES HISTORY;
SHOW SCHEMAS HISTORY;
SHOW DATABASES HISTORY;

=== RETENTION SETTINGS ===

CREATE TABLE t (id INT) DATA_RETENTION_TIME_IN_DAYS = N;
ALTER TABLE t SET DATA_RETENTION_TIME_IN_DAYS = N;
ALTER TABLE t UNSET DATA_RETENTION_TIME_IN_DAYS;
ALTER SCHEMA s SET DATA_RETENTION_TIME_IN_DAYS = N;
ALTER DATABASE db SET DATA_RETENTION_TIME_IN_DAYS = N;

=== CHANGES CLAUSE ===

ALTER TABLE t SET CHANGE_TRACKING = TRUE;
SELECT * FROM t CHANGES(INFORMATION => DEFAULT) AT(OFFSET => -3600);
SELECT * FROM t CHANGES(INFORMATION => APPEND_ONLY) AT(OFFSET => -3600);
SELECT * FROM t CHANGES(INFORMATION => DEFAULT)
    AT(OFFSET => -7200) END(OFFSET => -3600);

=== STORAGE MONITORING ===

SELECT table_name, time_travel_bytes, failsafe_bytes
FROM snowflake.account_usage.table_storage_metrics
ORDER BY time_travel_bytes DESC;

=== RECOVERY PATTERNS ===

-- Recover deleted rows:
INSERT INTO t SELECT * FROM t BEFORE(STATEMENT => '<delete_qid>');

-- Full table rollback:
CREATE TABLE t_clean CLONE t AT(TIMESTAMP => '<good_time>');
ALTER TABLE t SWAP WITH t_clean;
DROP TABLE t_clean;

-- Truncate recovery:
INSERT INTO t SELECT * FROM t BEFORE(STATEMENT => '<truncate_qid>');

*/

-- ============================================================
-- END OF LAB
-- ============================================================
