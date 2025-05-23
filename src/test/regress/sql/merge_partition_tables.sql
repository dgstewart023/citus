-- We create two sets of source and target tables, one set in Postgres and
-- the other in Citus distributed. We run the _exact_ MERGE SQL on both sets
-- and compare the final results of the target tables in Postgres and Citus.
-- The results should match. This process is repeated for various combinations
-- of MERGE SQL.

DROP SCHEMA IF EXISTS merge_partition_tables CASCADE;
CREATE SCHEMA merge_partition_tables;
SET search_path TO merge_partition_tables;
SET citus.shard_count TO 4;
SET citus.next_shard_id TO 7000000;
SET citus.explain_all_tasks TO true;
SET citus.shard_replication_factor TO 1;
SET citus.max_adaptive_executor_pool_size TO 1;
SET client_min_messages = warning;
SELECT 1 FROM master_add_node('localhost', :master_port, groupid => 0);
RESET client_min_messages;


CREATE TABLE pg_target(id int, val int) PARTITION BY RANGE(id);
CREATE TABLE pg_source(id int, val int, const int) PARTITION BY RANGE(val);
CREATE TABLE citus_target(id int, val int) PARTITION BY RANGE(id);
CREATE TABLE citus_source(id int, val int, const int) PARTITION BY RANGE(val);
SELECT citus_add_local_table_to_metadata('citus_target');
SELECT citus_add_local_table_to_metadata('citus_source');

CREATE TABLE part1 PARTITION OF pg_target FOR VALUES FROM (1) TO (2500) WITH (autovacuum_enabled=off);
CREATE TABLE part2 PARTITION OF pg_target FOR VALUES FROM (2501) TO (5000) WITH (autovacuum_enabled=off);
CREATE TABLE part3 PARTITION OF pg_target FOR VALUES FROM (5001) TO (7500) WITH (autovacuum_enabled=off);
CREATE TABLE part4 PARTITION OF pg_target DEFAULT WITH (autovacuum_enabled=off);
CREATE TABLE part5 PARTITION OF citus_target FOR VALUES FROM (1) TO (2500) WITH (autovacuum_enabled=off);
CREATE TABLE part6 PARTITION OF citus_target FOR VALUES FROM (2501) TO (5000) WITH (autovacuum_enabled=off);
CREATE TABLE part7 PARTITION OF citus_target FOR VALUES FROM (5001) TO (7500) WITH (autovacuum_enabled=off);
CREATE TABLE part8 PARTITION OF citus_target DEFAULT WITH (autovacuum_enabled=off);

CREATE TABLE part9 PARTITION OF pg_source FOR VALUES FROM (1) TO (2500) WITH (autovacuum_enabled=off);
CREATE TABLE part10 PARTITION OF pg_source FOR VALUES FROM (2501) TO (5000) WITH (autovacuum_enabled=off);
CREATE TABLE part11 PARTITION OF pg_source FOR VALUES FROM (5001) TO (7500) WITH (autovacuum_enabled=off);
CREATE TABLE part12 PARTITION OF pg_source DEFAULT WITH (autovacuum_enabled=off);
CREATE TABLE part13 PARTITION OF citus_source FOR VALUES FROM (1) TO (2500) WITH (autovacuum_enabled=off);
CREATE TABLE part14 PARTITION OF citus_source FOR VALUES FROM (2501) TO (5000) WITH (autovacuum_enabled=off);
CREATE TABLE part15 PARTITION OF citus_source FOR VALUES FROM (5001) TO (7500) WITH (autovacuum_enabled=off);
CREATE TABLE part16 PARTITION OF citus_source DEFAULT WITH (autovacuum_enabled=off);

CREATE OR REPLACE FUNCTION cleanup_data() RETURNS VOID SET search_path TO merge_partition_tables AS $$
    TRUNCATE pg_target;
    TRUNCATE pg_source;
    TRUNCATE citus_target;
    TRUNCATE citus_source;
    SELECT undistribute_table('citus_target');
    SELECT undistribute_table('citus_source');
$$
LANGUAGE SQL;

--
-- Load same set of data to both Postgres and Citus tables
--
CREATE OR REPLACE FUNCTION setup_data() RETURNS VOID SET search_path TO merge_partition_tables AS $$
    INSERT INTO pg_source SELECT i, i+1, 1 FROM generate_series(1, 10000) i;
    INSERT INTO pg_target SELECT i, 1 FROM generate_series(5001, 10000) i;
    INSERT INTO citus_source SELECT i, i+1, 1 FROM generate_series(1, 10000) i;
    INSERT INTO citus_target SELECT i, 1 FROM generate_series(5001, 10000) i;
$$
LANGUAGE SQL;

--
-- Compares the final target tables, merge-modified data, of both Postgres and Citus tables
--
CREATE OR REPLACE FUNCTION check_data(table1_name text, column1_name text, table2_name text, column2_name text)
RETURNS VOID SET search_path TO merge_partition_tables AS $$
DECLARE
    table1_avg numeric;
    table2_avg numeric;
BEGIN
    EXECUTE format('SELECT COALESCE(AVG(%I), 0) FROM %I', column1_name, table1_name) INTO table1_avg;
    EXECUTE format('SELECT COALESCE(AVG(%I), 0) FROM %I', column2_name, table2_name) INTO table2_avg;

    IF table1_avg > table2_avg THEN
        RAISE EXCEPTION 'The average of %.% is greater than %.%', table1_name, column1_name, table2_name, column2_name;
    ELSIF table1_avg < table2_avg THEN
        RAISE EXCEPTION 'The average of %.% is less than %.%', table1_name, column1_name, table2_name, column2_name;
    ELSE
        RAISE NOTICE 'The average of %.% is equal to %.%', table1_name, column1_name, table2_name, column2_name;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION compare_data() RETURNS VOID SET search_path TO merge_partition_tables AS $$
    SELECT check_data('pg_target', 'id', 'citus_target', 'id');
    SELECT check_data('pg_target', 'val', 'citus_target', 'val');
$$
LANGUAGE SQL;

-- Test colocated partition tables

SET client_min_messages = ERROR;
SELECT cleanup_data();
SELECT setup_data();
SELECT create_distributed_table('citus_target', 'id');
SELECT create_distributed_table('citus_source', 'id', colocate_with=>'citus_target');
RESET client_min_messages;

MERGE INTO pg_target t
USING pg_source s
ON t.id = s.id
WHEN MATCHED AND t.id <= 7500 THEN
        UPDATE SET val = s.val + 1
WHEN MATCHED THEN
	DELETE
WHEN NOT MATCHED THEN
        INSERT VALUES(s.id, s.val);

MERGE INTO citus_target t
USING citus_source s
ON t.id = s.id
WHEN MATCHED AND t.id <= 7500 THEN
        UPDATE SET val = s.val + 1
WHEN MATCHED THEN
	DELETE
WHEN NOT MATCHED THEN
        INSERT VALUES(s.id, s.val);

SELECT compare_data();

-- Test non-colocated partition tables

SET client_min_messages = ERROR;
SELECT cleanup_data();
SELECT setup_data();
SELECT create_distributed_table('citus_target', 'id');
SELECT create_distributed_table('citus_source', 'id', colocate_with=>'none');
RESET client_min_messages;

MERGE INTO pg_target t
USING pg_source s
ON t.id = s.id
WHEN MATCHED AND t.id <= 7500 THEN
        UPDATE SET val = s.val + 1
WHEN MATCHED THEN
	DELETE
WHEN NOT MATCHED THEN
        INSERT VALUES(s.id, s.val);

MERGE INTO citus_target t
USING citus_source s
ON t.id = s.id
WHEN MATCHED AND t.id <= 7500 THEN
        UPDATE SET val = s.val + 1
WHEN MATCHED THEN
	DELETE
WHEN NOT MATCHED THEN
        INSERT VALUES(s.id, s.val);

SELECT compare_data();
DROP SCHEMA merge_partition_tables CASCADE;
