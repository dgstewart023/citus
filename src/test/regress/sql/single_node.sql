--
-- SINGLE_NODE
--

CREATE SCHEMA single_node;
SET search_path TO single_node;
SET citus.shard_count TO 4;
SET citus.shard_replication_factor TO 1;
SET citus.next_shard_id TO 90630500;

-- Ensure tuple data in explain analyze output is the same on all PG versions
SET citus.enable_binary_protocol = TRUE;

-- do not cache any connections for now, will enable it back soon
ALTER SYSTEM SET citus.max_cached_conns_per_worker TO 0;

-- adding the coordinator as inactive is disallowed
SELECT 1 FROM master_add_inactive_node('localhost', :master_port, groupid => 0);

-- before adding a node we are not officially a coordinator
SELECT citus_is_coordinator();

-- idempotently add node to allow this test to run without add_coordinator
SET client_min_messages TO WARNING;
SELECT 1 FROM citus_set_coordinator_host('localhost', :master_port);

-- after adding a node we are officially a coordinator
SELECT citus_is_coordinator();

-- coordinator cannot be disabled
SELECT 1 FROM citus_disable_node('localhost', :master_port);

RESET client_min_messages;

SELECT 1 FROM master_remove_node('localhost', :master_port);

SELECT count(*) FROM pg_dist_node;

-- there are no workers now, but we should still be able to create Citus tables

-- force local execution when creating the index
ALTER SYSTEM SET citus.local_shared_pool_size TO -1;

-- Postmaster might not ack SIGHUP signal sent by pg_reload_conf() immediately,
-- so we need to sleep for some amount of time to do our best to ensure that
-- postmaster reflects GUC changes.
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);

CREATE TABLE failover_to_local (a int);
SELECT create_distributed_table('failover_to_local', 'a', shard_count=>32);

CREATE INDEX CONCURRENTLY ON failover_to_local(a);

-- reset global GUC changes
ALTER SYSTEM RESET citus.local_shared_pool_size;
ALTER SYSTEM RESET citus.max_cached_conns_per_worker;
SELECT pg_reload_conf();

CREATE TABLE single_node_nullkey_c1(a int, b int);
SELECT create_distributed_table('single_node_nullkey_c1', null, colocate_with=>'none', distribution_type=>null);

CREATE TABLE single_node_nullkey_c2(a int, b int);
SELECT create_distributed_table('single_node_nullkey_c2', null, colocate_with=>'none', distribution_type=>null);

-- created on different colocation groups ..
SELECT
(
    SELECT colocationid FROM pg_dist_partition
    WHERE logicalrelid = 'single_node.single_node_nullkey_c1'::regclass
)
!=
(
    SELECT colocationid FROM pg_dist_partition
    WHERE logicalrelid = 'single_node.single_node_nullkey_c2'::regclass
);

-- .. but both are associated to coordinator
SELECT groupid = 0 FROM pg_dist_placement
WHERE shardid = (
    SELECT shardid FROM pg_dist_shard
    WHERE logicalrelid = 'single_node.single_node_nullkey_c1'::regclass
);

SELECT groupid = 0 FROM pg_dist_placement
WHERE shardid = (
    SELECT shardid FROM pg_dist_shard
    WHERE logicalrelid = 'single_node.single_node_nullkey_c2'::regclass
);

-- try creating a single-shard table from a shard relation
SELECT shardid AS round_robin_test_c1_shard_id FROM pg_dist_shard WHERE logicalrelid = 'single_node.single_node_nullkey_c1'::regclass \gset
SELECT create_distributed_table('single_node_nullkey_c1_' || :round_robin_test_c1_shard_id , null, colocate_with=>'none', distribution_type=>null);

-- create a tenant schema on single node setup
SET citus.enable_schema_based_sharding TO ON;

CREATE SCHEMA tenant_1;
CREATE TABLE tenant_1.tbl_1 (a int);

-- verify that we recorded tenant_1 in pg_dist_schema
SELECT COUNT(*)=1 FROM pg_dist_schema WHERE schemaid::regnamespace::text = 'tenant_1';

-- verify that tenant_1.tbl_1 is recorded in pg_dist_partition, as a single-shard table
SELECT COUNT(*)=1 FROM pg_dist_partition
WHERE logicalrelid = 'tenant_1.tbl_1'::regclass AND
      partmethod = 'n' AND repmodel = 's' AND colocationid IS NOT NULL;

RESET citus.enable_schema_based_sharding;

-- Test lazy conversion from Citus local to single-shard tables
-- and reference tables, on single node. This means that no shard
-- replication should be needed.

CREATE TABLE ref_table_conversion_test (
    a int PRIMARY KEY
);
SELECT citus_add_local_table_to_metadata('ref_table_conversion_test');

-- save old shardid and placementid
SELECT get_shard_id_for_distribution_column('single_node.ref_table_conversion_test') AS ref_table_conversion_test_old_shard_id \gset
SELECT placementid AS ref_table_conversion_test_old_coord_placement_id FROM pg_dist_placement WHERE shardid = :ref_table_conversion_test_old_shard_id \gset

SELECT create_reference_table('ref_table_conversion_test');

SELECT public.verify_pg_dist_partition_for_reference_table('single_node.ref_table_conversion_test');
SELECT public.verify_shard_placements_for_reference_table('single_node.ref_table_conversion_test',
                                                          :ref_table_conversion_test_old_shard_id,
                                                          :ref_table_conversion_test_old_coord_placement_id);

CREATE TABLE single_shard_conversion_test_1 (
    int_col_1 int PRIMARY KEY,
    text_col_1 text UNIQUE,
    int_col_2 int
);
SELECT citus_add_local_table_to_metadata('single_shard_conversion_test_1');

-- save old shardid
SELECT get_shard_id_for_distribution_column('single_node.single_shard_conversion_test_1') AS single_shard_conversion_test_1_old_shard_id \gset

SELECT create_distributed_table('single_shard_conversion_test_1', null, colocate_with=>'none');

SELECT public.verify_pg_dist_partition_for_single_shard_table('single_node.single_shard_conversion_test_1');
SELECT public.verify_shard_placement_for_single_shard_table('single_node.single_shard_conversion_test_1', :single_shard_conversion_test_1_old_shard_id, true);

CREATE TABLE single_shard_conversion_test_2 (
    int_col_1 int
);
SELECT citus_add_local_table_to_metadata('single_shard_conversion_test_2');

-- save old shardid
SELECT get_shard_id_for_distribution_column('single_node.single_shard_conversion_test_2') AS single_shard_conversion_test_2_old_shard_id \gset

SELECT create_distributed_table('single_shard_conversion_test_2', null, colocate_with=>'none');

SELECT public.verify_pg_dist_partition_for_single_shard_table('single_node.single_shard_conversion_test_2');
SELECT public.verify_shard_placement_for_single_shard_table('single_node.single_shard_conversion_test_2', :single_shard_conversion_test_2_old_shard_id, true);

-- make sure that they're created on different colocation groups
SELECT
(
    SELECT colocationid FROM pg_dist_partition
    WHERE logicalrelid = 'single_node.single_shard_conversion_test_1'::regclass
)
!=
(
    SELECT colocationid FROM pg_dist_partition
    WHERE logicalrelid = 'single_node.single_shard_conversion_test_2'::regclass
);

SET client_min_messages TO WARNING;
DROP TABLE failover_to_local, single_node_nullkey_c1, single_node_nullkey_c2, ref_table_conversion_test, single_shard_conversion_test_1, single_shard_conversion_test_2;
DROP SCHEMA tenant_1 CASCADE;
RESET client_min_messages;

-- so that we don't have to update rest of the test output
SET citus.next_shard_id TO 90630500;

CREATE TABLE ref(x int, y int);
SELECT create_reference_table('ref');

SELECT groupid, nodename, nodeport, isactive, shouldhaveshards, hasmetadata, metadatasynced FROM pg_dist_node;

DROP TABLE ref;

-- remove the coordinator to try again with create_reference_table
SELECT master_remove_node(nodename, nodeport) FROM pg_dist_node WHERE groupid = 0;

CREATE TABLE loc(x int, y int);
SELECT citus_add_local_table_to_metadata('loc');

SELECT groupid, nodename, nodeport, isactive, shouldhaveshards, hasmetadata, metadatasynced FROM pg_dist_node;

DROP TABLE loc;

-- remove the coordinator to try again with create_distributed_table
SELECT master_remove_node(nodename, nodeport) FROM pg_dist_node WHERE groupid = 0;

-- verify the coordinator gets auto added with the localhost guc
ALTER SYSTEM SET citus.local_hostname TO '127.0.0.1'; --although not a hostname, should work for connecting locally
SELECT pg_reload_conf();
SELECT pg_sleep(.1); -- wait to make sure the config has changed before running the GUC

CREATE TABLE test(x int, y int);
SELECT create_distributed_table('test','x');

SELECT groupid, nodename, nodeport, isactive, shouldhaveshards, hasmetadata, metadatasynced FROM pg_dist_node;
DROP TABLE test;
-- remove the coordinator to try again
SELECT master_remove_node(nodename, nodeport) FROM pg_dist_node WHERE groupid = 0;

ALTER SYSTEM RESET citus.local_hostname;
SELECT pg_reload_conf();
SELECT pg_sleep(.1); -- wait to make sure the config has changed before running the GUC

CREATE TABLE test(x int, y int);
SELECT create_distributed_table('test','x');

SELECT groupid, nodename, nodeport, isactive, shouldhaveshards, hasmetadata, metadatasynced FROM pg_dist_node;

BEGIN;
	-- we should not enable MX for this temporary node just because
	-- it'd spawn a bg worker targeting this node
	-- and that changes the connection count specific tests
	-- here
	SET LOCAL citus.enable_metadata_sync TO OFF;
	-- cannot add workers with specific IP as long as I have a placeholder coordinator record
	SELECT 1 FROM master_add_node('127.0.0.1', :worker_1_port);
COMMIT;

BEGIN;
	-- we should not enable MX for this temporary node just because
	-- it'd spawn a bg worker targeting this node
	-- and that changes the connection count specific tests
	-- here
	SET LOCAL citus.enable_metadata_sync TO OFF;
	-- adding localhost workers is ok
	SELECT 1 FROM master_add_node('localhost', :worker_1_port);
COMMIT;

-- we don't need this node anymore
SELECT 1 FROM master_remove_node('localhost', :worker_1_port);

-- set the coordinator host to something different than localhost
SELECT 1 FROM citus_set_coordinator_host('127.0.0.1');

BEGIN;
	-- we should not enable MX for this temporary node just because
	-- it'd spawn a bg worker targeting this node
	-- and that changes the connection count specific tests
	-- here
	SET LOCAL citus.enable_metadata_sync TO OFF;
	-- adding workers with specific IP is ok now
	SELECT 1 FROM master_add_node('127.0.0.1', :worker_1_port);
COMMIT;

-- we don't need this node anymore
SELECT 1 FROM master_remove_node('127.0.0.1', :worker_1_port);

-- set the coordinator host back to localhost for the remainder of tests
SELECT 1 FROM citus_set_coordinator_host('localhost');

-- should have shards setting should not really matter for a single node
SELECT 1 FROM master_set_node_property('localhost', :master_port, 'shouldhaveshards', true);

CREATE TYPE new_type AS (n int, m text);
CREATE TABLE test_2(x int, y int, z new_type);
SELECT create_distributed_table('test_2','x');

CREATE TABLE ref(a int, b int);
SELECT create_reference_table('ref');
CREATE TABLE local(c int, d int);

CREATE TABLE public.another_schema_table(a int, b int);
SELECT create_distributed_table('public.another_schema_table', 'a');

CREATE TABLE non_binary_copy_test (key int PRIMARY KEY, value new_type);
SELECT create_distributed_table('non_binary_copy_test', 'key');
INSERT INTO non_binary_copy_test SELECT i, (i, 'citus9.5')::new_type FROM generate_series(0,1000)i;

-- Confirm the basics work
INSERT INTO test VALUES (1, 2), (3, 4), (5, 6), (2, 7), (4, 5);
SELECT * FROM test WHERE x = 1;
SELECT count(*) FROM test;
SELECT * FROM test ORDER BY x;
UPDATE test SET y = y + 1 RETURNING *;
WITH cte_1 AS (UPDATE test SET y = y - 1 RETURNING *) SELECT * FROM cte_1 ORDER BY 1,2;

-- show that we can filter remote commands
-- given that citus.grep_remote_commands, we log all commands
SET citus.log_local_commands to true;
SELECT count(*) FROM public.another_schema_table WHERE a = 1;

-- grep matches all commands
SET citus.grep_remote_commands TO "%%";
SELECT count(*) FROM public.another_schema_table WHERE a = 1;

-- only filter a specific shard for the local execution
BEGIN;
	SET LOCAL citus.grep_remote_commands TO "%90630515%";
	SELECT count(*) FROM public.another_schema_table;
	-- match nothing
	SET LOCAL citus.grep_remote_commands TO '%nothing%';
	SELECT count(*) FROM public.another_schema_table;
COMMIT;

-- only filter a specific shard for the remote execution
BEGIN;
	SET LOCAL citus.enable_local_execution TO FALSE;
	SET LOCAL citus.grep_remote_commands TO '%90630515%';
	SET LOCAL citus.log_remote_commands TO ON;
	SELECT count(*) FROM public.another_schema_table;
	-- match nothing
	SET LOCAL citus.grep_remote_commands TO '%nothing%';
	SELECT count(*) FROM public.another_schema_table;
COMMIT;

RESET citus.log_local_commands;
RESET citus.grep_remote_commands;

-- Test upsert with constraint
CREATE TABLE upsert_test
(
	part_key int UNIQUE,
	other_col int,
	third_col int
);

-- distribute the table
SELECT create_distributed_table('upsert_test', 'part_key');

-- do a regular insert
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1), (2, 2) RETURNING *;

SET citus.log_remote_commands to true;

-- observe that there is a conflict and the following query does nothing
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT DO NOTHING RETURNING *;

-- same as the above with different syntax
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT (part_key) DO NOTHING RETURNING *;

-- again the same query with another syntax
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;

BEGIN;

-- force local execution
SELECT count(*) FROM upsert_test WHERE part_key = 1;

SET citus.log_remote_commands to false;

-- multi-shard pushdown query that goes through local execution
INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;

-- multi-shard pull-to-coordinator query that goes through local execution

INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test LIMIT 100 ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;

COMMIT;

-- to test citus local tables
select undistribute_table('upsert_test');
-- create citus local table
select citus_add_local_table_to_metadata('upsert_test');
-- test the constraint with local execution
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;

DROP TABLE upsert_test;

CREATE TABLE relation_tracking_table_1(id int, nonid int);
SELECT create_distributed_table('relation_tracking_table_1', 'id', colocate_with := 'none');
INSERT INTO relation_tracking_table_1 select generate_series(6, 10000, 1), 0;

CREATE or REPLACE function foo()
returns setof relation_tracking_table_1
AS $$
BEGIN
RETURN query select * from relation_tracking_table_1 order by 1 limit 10;
end;
$$ language plpgsql;

CREATE TABLE relation_tracking_table_2 (id int, nonid int);

-- use the relation-access in this session
select foo();

-- we should be able to use sequential mode, as the previous multi-shard
-- relation access has been cleaned-up
BEGIN;
SET LOCAL citus.multi_shard_modify_mode TO sequential;
INSERT INTO relation_tracking_table_2 select generate_series(6, 1000, 1), 0;
SELECT create_distributed_table('relation_tracking_table_2', 'id', colocate_with := 'none');
SELECT count(*) FROM relation_tracking_table_2;
ROLLBACK;

BEGIN;
INSERT INTO relation_tracking_table_2 select generate_series(6, 1000, 1), 0;
SELECT create_distributed_table('relation_tracking_table_2', 'id', colocate_with := 'none');
SELECT count(*) FROM relation_tracking_table_2;
COMMIT;

SET client_min_messages TO ERROR;
DROP TABLE relation_tracking_table_2, relation_tracking_table_1 CASCADE;
RESET client_min_messages;

CREATE SCHEMA "Quoed.Schema";
SET search_path TO "Quoed.Schema";


CREATE TABLE "long_constraint_upsert\_test"
(
	part_key int,
	other_col int,
	third_col int,

	CONSTRAINT "looo oooo ooooo ooooooooooooooooo oooooooo oooooooo ng quoted  \aconstraint" UNIQUE (part_key)
);
-- distribute the table and create shards
SELECT create_distributed_table('"long_constraint_upsert\_test"', 'part_key');


INSERT INTO "long_constraint_upsert\_test" (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT  "looo oooo ooooo ooooooooooooooooo oooooooo oooooooo ng quoted  \aconstraint" DO NOTHING RETURNING *;

ALTER TABLE "long_constraint_upsert\_test" RENAME TO simple_table_name;

INSERT INTO simple_table_name (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT  "looo oooo ooooo ooooooooooooooooo oooooooo oooooooo ng quoted  \aconstraint" DO NOTHING RETURNING *;

-- this is currently not supported, but once we support
-- make sure that the following query also works fine
ALTER TABLE simple_table_name RENAME CONSTRAINT "looo oooo ooooo ooooooooooooooooo oooooooo oooooooo ng quoted  \aconstraint"  TO simple_constraint_name;
--INSERT INTO simple_table_name (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT  simple_constraint_name DO NOTHING RETURNING *;

SET search_path TO single_node;
SET client_min_messages TO ERROR;
DROP SCHEMA  "Quoed.Schema" CASCADE;
RESET client_min_messages;

-- test partitioned index creation with long name
CREATE TABLE test_index_creation1
(
    tenant_id integer NOT NULL,
    timeperiod timestamp without time zone NOT NULL,
    field1 integer NOT NULL,
    inserted_utc timestamp without time zone NOT NULL DEFAULT now(),
    PRIMARY KEY(tenant_id, timeperiod)
) PARTITION BY RANGE (timeperiod);

CREATE TABLE test_index_creation1_p2020_09_26
PARTITION OF test_index_creation1 FOR VALUES FROM ('2020-09-26 00:00:00') TO ('2020-09-27 00:00:00');
CREATE TABLE test_index_creation1_p2020_09_27
PARTITION OF test_index_creation1 FOR VALUES FROM ('2020-09-27 00:00:00') TO ('2020-09-28 00:00:00');

select create_distributed_table('test_index_creation1', 'tenant_id');

-- should be able to create indexes with INCLUDE/WHERE
CREATE INDEX ix_test_index_creation5 ON test_index_creation1
	USING btree(tenant_id, timeperiod)
	INCLUDE (field1) WHERE (tenant_id = 100);

-- test if indexes are created
SELECT 1 AS created WHERE EXISTS(SELECT * FROM pg_indexes WHERE indexname LIKE '%test_index_creation%');

-- test citus size functions in transaction with modification
CREATE TABLE test_citus_size_func (a int);
SELECT create_distributed_table('test_citus_size_func', 'a');
INSERT INTO test_citus_size_func VALUES(1), (2);

BEGIN;
	-- DDL with citus_table_size
	ALTER TABLE test_citus_size_func ADD COLUMN newcol INT;
	SELECT citus_table_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- DDL with citus_relation_size
	ALTER TABLE test_citus_size_func ADD COLUMN newcol INT;
	SELECT citus_relation_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- DDL with citus_total_relation_size
	ALTER TABLE test_citus_size_func ADD COLUMN newcol INT;
	SELECT citus_total_relation_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- single shard insert with citus_table_size
	INSERT INTO test_citus_size_func VALUES (3);
	SELECT citus_table_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- multi shard modification with citus_table_size
	INSERT INTO test_citus_size_func  SELECT * FROM  test_citus_size_func;
	SELECT citus_table_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- single shard insert with citus_relation_size
	INSERT INTO test_citus_size_func VALUES (3);
	SELECT citus_relation_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- multi shard modification with citus_relation_size
	INSERT INTO test_citus_size_func  SELECT * FROM  test_citus_size_func;
	SELECT citus_relation_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- single shard insert with citus_total_relation_size
	INSERT INTO test_citus_size_func VALUES (3);
	SELECT citus_total_relation_size('test_citus_size_func');
ROLLBACK;

BEGIN;
	-- multi shard modification with citus_total_relation_size
	INSERT INTO test_citus_size_func  SELECT * FROM  test_citus_size_func;
	SELECT citus_total_relation_size('test_citus_size_func');
ROLLBACK;

-- we should be able to limit intermediate results
BEGIN;
       SET LOCAL citus.max_intermediate_result_size TO 0;
       WITH cte_1 AS (SELECT * FROM test OFFSET 0) SELECT * FROM cte_1;
ROLLBACK;

-- the first cte (cte_1) does not exceed the limit
-- but the second (cte_2) exceeds, so we error out
BEGIN;
	SET LOCAL citus.max_intermediate_result_size TO '1kB';
	INSERT INTO  test SELECT i,i from generate_series(0,1000)i;

	-- only pulls 1 row, should not hit the limit
	WITH cte_1 AS (SELECT * FROM test LIMIT 1) SELECT count(*) FROM cte_1;

	-- cte_1 only pulls 1 row, but cte_2 all rows
	WITH cte_1 AS (SELECT * FROM test LIMIT 1),
	     cte_2 AS (SELECT * FROM test OFFSET 0)
	SELECT count(*) FROM cte_1, cte_2;
ROLLBACK;

-- single shard and multi-shard delete
-- inside a transaction block
BEGIN;
	DELETE FROM test WHERE y = 5;
	INSERT INTO test VALUES (4, 5);

	DELETE FROM test WHERE x = 1;
	INSERT INTO test VALUES (1, 2);
COMMIT;

CREATE INDEX single_node_i1 ON test(x);
CREATE INDEX single_node_i2 ON test(x,y);
REINDEX SCHEMA single_node;

REINDEX SCHEMA CONCURRENTLY single_node;

-- keep one of the indexes
-- drop w/wout tx blocks
BEGIN;
	DROP INDEX single_node_i2;
ROLLBACK;
DROP INDEX single_node_i2;

-- change the schema w/wout TX block
BEGIN;
	ALTER TABLE public.another_schema_table SET SCHEMA single_node;
ROLLBACK;
ALTER TABLE public.another_schema_table SET SCHEMA single_node;

BEGIN;
	TRUNCATE test;
	SELECT * FROM test;
ROLLBACK;

VACUUM test;
VACUUM test, test_2;
VACUUM ref, test;
VACUUM ANALYZE test(x);
ANALYZE ref;
ANALYZE test_2;
VACUUM local;
VACUUM local, ref, test, test_2;
VACUUM FULL test, ref;

BEGIN;
	ALTER TABLE test ADD COLUMN z INT DEFAULT 66;
	SELECT count(*) FROM test WHERE z = 66;
ROLLBACK;

-- explain analyze should work on a single node
EXPLAIN (COSTS FALSE, ANALYZE TRUE, TIMING FALSE, SUMMARY FALSE)
	SELECT * FROM test;

-- common utility command
SELECT pg_size_pretty(citus_relation_size('test'::regclass));

-- basic view queries
CREATE VIEW single_node_view AS
	SELECT count(*) as cnt FROM test t1 JOIN test t2 USING (x);
SELECT * FROM single_node_view;
SELECT * FROM single_node_view, test WHERE test.x = single_node_view.cnt;

-- copy in/out
BEGIN;
	COPY test(x) FROM PROGRAM 'seq 32';
	SELECT count(*) FROM test;
	COPY (SELECT count(DISTINCT x) FROM test) TO STDOUT;
	INSERT INTO test SELECT i,i FROM generate_series(0,100)i;
ROLLBACK;

-- master_create_empty_shard on coordinator
BEGIN;
CREATE TABLE append_table (a INT, b INT);
SELECT create_distributed_table('append_table','a','append');
SELECT master_create_empty_shard('append_table');
END;

-- alter table inside a tx block
BEGIN;
	ALTER TABLE test ADD COLUMN z single_node.new_type;

	INSERT INTO test VALUES (99, 100, (1, 'onder')::new_type) RETURNING *;
ROLLBACK;

-- prepared statements with custom types
PREPARE single_node_prepare_p1(int, int, new_type) AS
	INSERT INTO test_2 VALUES ($1, $2, $3);

EXECUTE single_node_prepare_p1(1, 1, (95, 'citus9.5')::new_type);
EXECUTE single_node_prepare_p1(2 ,2, (94, 'citus9.4')::new_type);
EXECUTE single_node_prepare_p1(3 ,2, (93, 'citus9.3')::new_type);
EXECUTE single_node_prepare_p1(4 ,2, (92, 'citus9.2')::new_type);
EXECUTE single_node_prepare_p1(5 ,2, (91, 'citus9.1')::new_type);
EXECUTE single_node_prepare_p1(6 ,2, (90, 'citus9.0')::new_type);

PREPARE use_local_query_cache(int) AS SELECT count(*) FROM test_2 WHERE x =  $1;

EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);

SET client_min_messages TO DEBUG2;
-- the 6th execution will go through the planner
-- the 7th execution will skip the planner as it uses the cache
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);

RESET client_min_messages;


-- partitioned table should be fine, adding for completeness
CREATE TABLE collections_list (
	key bigint,
	ts timestamptz DEFAULT now(),
	collection_id integer,
	value numeric,
	PRIMARY KEY(key, collection_id)
) PARTITION BY LIST (collection_id );

SELECT create_distributed_table('collections_list', 'key');
CREATE TABLE collections_list_0
	PARTITION OF collections_list (key, ts, collection_id, value)
	FOR VALUES IN ( 0 );
CREATE TABLE collections_list_1
	PARTITION OF collections_list (key, ts, collection_id, value)
	FOR VALUES IN ( 1 );

INSERT INTO collections_list SELECT i, '2011-01-01', i % 2, i * i FROM generate_series(0, 100) i;
SELECT count(*) FROM collections_list WHERE key < 10 AND collection_id = 1;
SELECT count(*) FROM collections_list_0 WHERE key < 10 AND collection_id = 1;
SELECT count(*) FROM collections_list_1 WHERE key = 11;
ALTER TABLE collections_list DROP COLUMN ts;
SELECT * FROM collections_list, collections_list_0 WHERE collections_list.key=collections_list_0.key  ORDER BY 1 DESC,2 DESC,3 DESC,4 DESC LIMIT 1;

-- test hash distribution using INSERT with generate_series() function
CREATE OR REPLACE FUNCTION part_hashint4_noop(value int4, seed int8)
RETURNS int8 AS $$
SELECT value + seed;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OPERATOR CLASS part_test_int4_ops
FOR TYPE int4
USING HASH AS
operator 1 =,
function 2 part_hashint4_noop(int4, int8);

CREATE TABLE hash_parted (
	a int,
  b int
) PARTITION BY HASH (a part_test_int4_ops);
CREATE TABLE hpart0 PARTITION OF hash_parted FOR VALUES WITH (modulus 4, remainder 0);
CREATE TABLE hpart1 PARTITION OF hash_parted FOR VALUES WITH (modulus 4, remainder 1);
CREATE TABLE hpart2 PARTITION OF hash_parted FOR VALUES WITH (modulus 4, remainder 2);
CREATE TABLE hpart3 PARTITION OF hash_parted FOR VALUES WITH (modulus 4, remainder 3);

-- Disable metadata sync since citus doesn't support distributing
-- operator class for now.
SET citus.enable_metadata_sync TO OFF;
SELECT create_distributed_table('hash_parted ', 'a');

INSERT INTO hash_parted VALUES (1, generate_series(1, 10));

SELECT * FROM hash_parted ORDER BY 1, 2;

ALTER TABLE hash_parted DETACH PARTITION hpart0;
ALTER TABLE hash_parted DETACH PARTITION hpart1;
ALTER TABLE hash_parted DETACH PARTITION hpart2;
ALTER TABLE hash_parted DETACH PARTITION hpart3;
RESET citus.enable_metadata_sync;

-- test range partition without creating partitions and inserting with generate_series()
-- should error out even in plain PG since no partition of relation "parent_tab" is found for row
-- in Citus it errors out because it fails to evaluate partition key in insert
CREATE TABLE parent_tab (id int) PARTITION BY RANGE (id);
SELECT create_distributed_table('parent_tab', 'id');
INSERT INTO parent_tab VALUES (generate_series(0, 3));
-- now it should work
CREATE TABLE parent_tab_1_2 PARTITION OF parent_tab FOR VALUES FROM (1) to (2);
ALTER TABLE parent_tab ADD COLUMN b int;
INSERT INTO parent_tab VALUES (1, generate_series(0, 3));
SELECT * FROM parent_tab ORDER BY 1, 2;

-- make sure that parallel accesses are good
SET citus.force_max_query_parallelization TO ON;
SELECT * FROM test_2 ORDER BY 1 DESC;
DELETE FROM test_2 WHERE y = 1000 RETURNING *;
RESET citus.force_max_query_parallelization ;

BEGIN;
	INSERT INTO test_2 VALUES (7 ,2, (83, 'citus8.3')::new_type);
	SAVEPOINT s1;
	INSERT INTO test_2 VALUES (9 ,1, (82, 'citus8.2')::new_type);
	SAVEPOINT s2;
	ROLLBACK TO SAVEPOINT s1;
	SELECT * FROM test_2 WHERE z = (83, 'citus8.3')::new_type OR z = (82, 'citus8.2')::new_type;
	RELEASE SAVEPOINT s1;
COMMIT;

SELECT * FROM test_2 WHERE z = (83, 'citus8.3')::new_type OR z = (82, 'citus8.2')::new_type;

-- final query is only intermediate result

-- we want PG 11/12/13 behave consistently, the CTEs should be MATERIALIZED
WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1 ORDER BY 1,2;

-- final query is router query
WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1, test_2 WHERE  test_2.x = cte_1.x AND test_2.x = 7 ORDER BY 1,2;

-- final query is a distributed query
WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1, test_2 WHERE  test_2.x = cte_1.x AND test_2.y != 2 ORDER BY 1,2;

-- query pushdown should work
SELECT
	*
FROM
	(SELECT x, count(*) FROM test_2 GROUP BY x) as foo,
	(SELECT x, count(*) FROM test_2 GROUP BY x) as bar
WHERE
	foo.x = bar.x
ORDER BY 1 DESC, 2 DESC, 3 DESC, 4 DESC
LIMIT 1;

-- make sure that foreign keys work fine
ALTER TABLE test_2 ADD CONSTRAINT first_pkey PRIMARY KEY (x);
ALTER TABLE test ADD CONSTRAINT foreign_key FOREIGN KEY (x) REFERENCES test_2(x) ON DELETE CASCADE;

-- show that delete on test_2 cascades to test
SELECT * FROM test WHERE x = 5;
DELETE FROM test_2 WHERE x = 5;
SELECT * FROM test WHERE x = 5;
INSERT INTO test_2 VALUES (5 ,2, (91, 'citus9.1')::new_type);
INSERT INTO test VALUES (5, 6);

INSERT INTO ref VALUES (1, 2), (5, 6), (7, 8);
SELECT count(*) FROM ref;
SELECT * FROM ref ORDER BY a;
SELECT * FROM test, ref WHERE x = a ORDER BY x;

INSERT INTO local VALUES (1, 2), (3, 4), (7, 8);
SELECT count(*) FROM local;
SELECT * FROM local ORDER BY c;
SELECT * FROM ref, local WHERE a = c ORDER BY a;

-- Check repartition joins are supported
SET citus.enable_repartition_joins TO ON;
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x;
SET citus.enable_single_hash_repartition_joins TO ON;
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x;

SET search_path TO public;
SET citus.enable_single_hash_repartition_joins TO OFF;
SELECT * FROM single_node.test t1, single_node.test t2 WHERE t1.x = t2.y ORDER BY t1.x;
SET citus.enable_single_hash_repartition_joins TO ON;
SELECT * FROM single_node.test t1, single_node.test t2 WHERE t1.x = t2.y ORDER BY t1.x;
SET search_path TO single_node;

SET citus.task_assignment_policy TO 'round-robin';
SET citus.enable_single_hash_repartition_joins TO ON;
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x;

SET citus.task_assignment_policy TO 'greedy';
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x;

SET citus.task_assignment_policy TO 'first-replica';
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x;

RESET citus.enable_repartition_joins;
RESET citus.enable_single_hash_repartition_joins;

-- INSERT SELECT router
BEGIN;
INSERT INTO test(x, y) SELECT x, y FROM test WHERE x = 1;
SELECT count(*) from test;
ROLLBACK;


-- INSERT SELECT pushdown
BEGIN;
INSERT INTO test(x, y) SELECT x, y FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT analytical query
BEGIN;
INSERT INTO test(x, y) SELECT count(x), max(y) FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT repartition
BEGIN;
INSERT INTO test(x, y) SELECT y, x FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT from reference table into distributed
BEGIN;
INSERT INTO test(x, y) SELECT a, b FROM ref;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT from local table into distributed
BEGIN;
INSERT INTO test(x, y) SELECT c, d FROM local;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT x, y FROM test;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT c, d FROM local;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT x, y FROM test;
SELECT count(*) from local;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT a, b FROM ref;
SELECT count(*) from local;
ROLLBACK;

-- Confirm that dummy placements work
SELECT count(*) FROM test WHERE false;
SELECT count(*) FROM test WHERE false GROUP BY GROUPING SETS (x,y);
-- Confirm that they work with round-robin task assignment policy
SET citus.task_assignment_policy TO 'round-robin';
SELECT count(*) FROM test WHERE false;
SELECT count(*) FROM test WHERE false GROUP BY GROUPING SETS (x,y);
RESET citus.task_assignment_policy;

SELECT count(*) FROM test;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT x, y FROM test;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT c, d FROM local;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT x, y FROM test;
SELECT count(*) from local;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT a, b FROM ref;
SELECT count(*) from local;
ROLLBACK;

-- query fails on the shards should be handled
-- nicely
SELECT x/0 FROM test;

-- Add "fake" pg_dist_transaction records and run recovery
-- to show that it is recovered

-- Temporarily disable automatic 2PC recovery
ALTER SYSTEM SET citus.recover_2pc_interval TO -1;
SELECT pg_reload_conf();

BEGIN;
CREATE TABLE should_commit (value int);
PREPARE TRANSACTION 'citus_0_should_commit';

-- zero is the coordinator's group id, so we can hard code it
INSERT INTO pg_dist_transaction VALUES (0, 'citus_0_should_commit');
SELECT recover_prepared_transactions();

-- the table should be seen
SELECT * FROM should_commit;

-- set the original back
ALTER SYSTEM RESET citus.recover_2pc_interval;
SELECT pg_reload_conf();

RESET citus.task_executor_type;

-- make sure undistribute table works fine
ALTER TABLE test DROP CONSTRAINT foreign_key;
SELECT undistribute_table('test_2');
SELECT * FROM pg_dist_partition WHERE logicalrelid = 'test_2'::regclass;

CREATE TABLE reference_table_1 (col_1 INT UNIQUE, col_2 INT UNIQUE, UNIQUE (col_2, col_1));
SELECT create_reference_table('reference_table_1');

CREATE TABLE distributed_table_1 (col_1 INT UNIQUE);
SELECT create_distributed_table('distributed_table_1', 'col_1');

CREATE TABLE citus_local_table_1 (col_1 INT UNIQUE);
SELECT citus_add_local_table_to_metadata('citus_local_table_1');

CREATE TABLE partitioned_table_1 (col_1 INT UNIQUE, col_2 INT) PARTITION BY RANGE (col_1);
CREATE TABLE partitioned_table_1_100_200 PARTITION OF partitioned_table_1 FOR VALUES FROM (100) TO (200);
CREATE TABLE partitioned_table_1_200_300 PARTITION OF partitioned_table_1 FOR VALUES FROM (200) TO (300);
SELECT create_distributed_table('partitioned_table_1', 'col_1');

ALTER TABLE citus_local_table_1 ADD CONSTRAINT fkey_1 FOREIGN KEY (col_1) REFERENCES reference_table_1(col_2);
ALTER TABLE reference_table_1 ADD CONSTRAINT fkey_2 FOREIGN KEY (col_2) REFERENCES reference_table_1(col_1);
ALTER TABLE distributed_table_1 ADD CONSTRAINT fkey_3 FOREIGN KEY (col_1) REFERENCES reference_table_1(col_1);
ALTER TABLE citus_local_table_1 ADD CONSTRAINT fkey_4 FOREIGN KEY (col_1) REFERENCES reference_table_1(col_2);
ALTER TABLE partitioned_table_1 ADD CONSTRAINT fkey_5 FOREIGN KEY (col_1) REFERENCES reference_table_1(col_2);

SELECT undistribute_table('partitioned_table_1', cascade_via_foreign_keys=>true);

CREATE TABLE local_table_1 (col_1 INT UNIQUE);
CREATE TABLE local_table_2 (col_1 INT UNIQUE);
CREATE TABLE local_table_3 (col_1 INT UNIQUE);

ALTER TABLE local_table_2 ADD CONSTRAINT fkey_6 FOREIGN KEY (col_1) REFERENCES local_table_1(col_1);
ALTER TABLE local_table_3 ADD CONSTRAINT fkey_7 FOREIGN KEY (col_1) REFERENCES local_table_1(col_1);
ALTER TABLE local_table_1 ADD CONSTRAINT fkey_8 FOREIGN KEY (col_1) REFERENCES local_table_1(col_1);

SELECT citus_add_local_table_to_metadata('local_table_2', cascade_via_foreign_keys=>true);

CREATE PROCEDURE call_delegation(x int) LANGUAGE plpgsql AS $$
BEGIN
	 INSERT INTO test (x) VALUES ($1);
END;$$;
SELECT * FROM pg_dist_node;
SELECT create_distributed_function('call_delegation(int)', '$1', 'test');

CREATE FUNCTION function_delegation(int) RETURNS void AS $$
BEGIN
UPDATE test SET y = y + 1 WHERE x <  $1;
END;
$$ LANGUAGE plpgsql;
SELECT create_distributed_function('function_delegation(int)', '$1', 'test');

SET client_min_messages TO DEBUG1;
CALL call_delegation(1);
SELECT function_delegation(1);

SET client_min_messages TO WARNING;
DROP TABLE test CASCADE;

CREATE OR REPLACE FUNCTION pg_catalog.get_all_active_client_backend_count()
    RETURNS bigint
    LANGUAGE C STRICT
    AS 'citus', $$get_all_active_client_backend_count$$;

-- set the cached connections to zero
-- and execute a distributed query so that
-- we end up with zero cached connections afterwards
ALTER SYSTEM SET citus.max_cached_conns_per_worker TO 0;
SELECT pg_reload_conf();

-- disable deadlock detection and re-trigger 2PC recovery
-- once more when citus.max_cached_conns_per_worker is zero
-- so that we can be sure that the connections established for
-- maintanince daemon is closed properly.
-- this is to prevent random failures in the tests (otherwise, we
-- might see connections established for this operations)
ALTER SYSTEM SET citus.distributed_deadlock_detection_factor TO -1;
ALTER SYSTEM SET citus.recover_2pc_interval TO '1ms';
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);

-- now that last 2PC recovery is done, we're good to disable it
ALTER SYSTEM SET citus.recover_2pc_interval TO '-1';
SELECT pg_reload_conf();

-- test alter_distributed_table UDF
CREATE TABLE adt_table (a INT, b INT);
CREATE TABLE adt_col (a INT UNIQUE, b INT);
CREATE TABLE adt_ref (a INT REFERENCES adt_col(a));

SELECT create_distributed_table('adt_table', 'a', colocate_with:='none');
SELECT create_distributed_table('adt_col', 'a', colocate_with:='adt_table');
SELECT create_distributed_table('adt_ref', 'a', colocate_with:='adt_table');

INSERT INTO adt_table VALUES (1, 2), (3, 4), (5, 6);
INSERT INTO adt_col VALUES (3, 4), (5, 6), (7, 8);
INSERT INTO adt_ref VALUES (3), (5);

SELECT table_name, citus_table_type, distribution_column, shard_count FROM public.citus_tables WHERE table_name::text LIKE 'adt%';
SELECT STRING_AGG(table_name::text, ', ' ORDER BY 1) AS "Colocation Groups" FROM public.citus_tables WHERE table_name::text LIKE 'adt%' GROUP BY colocation_id ORDER BY 1;
SELECT conrelid::regclass::text AS "Referencing Table", pg_get_constraintdef(oid, true) AS "Definition" FROM  pg_constraint
    WHERE (conrelid::regclass::text = 'adt_col' OR confrelid::regclass::text = 'adt_col') ORDER BY 1;

SELECT alter_distributed_table('adt_table', shard_count:=6, cascade_to_colocated:=true);

SELECT table_name, citus_table_type, distribution_column, shard_count FROM public.citus_tables WHERE table_name::text LIKE 'adt%';
SELECT STRING_AGG(table_name::text, ', ' ORDER BY 1) AS "Colocation Groups" FROM public.citus_tables WHERE table_name::text LIKE 'adt%' GROUP BY colocation_id ORDER BY 1;
SELECT conrelid::regclass::text AS "Referencing Table", pg_get_constraintdef(oid, true) AS "Definition" FROM  pg_constraint
    WHERE (conrelid::regclass::text = 'adt_col' OR confrelid::regclass::text = 'adt_col') ORDER BY 1;

SELECT alter_distributed_table('adt_table', distribution_column:='b', colocate_with:='none');

SELECT table_name, citus_table_type, distribution_column, shard_count FROM public.citus_tables WHERE table_name::text LIKE 'adt%';
SELECT STRING_AGG(table_name::text, ', ' ORDER BY 1) AS "Colocation Groups" FROM public.citus_tables WHERE table_name::text LIKE 'adt%' GROUP BY colocation_id ORDER BY 1;
SELECT conrelid::regclass::text AS "Referencing Table", pg_get_constraintdef(oid, true) AS "Definition" FROM  pg_constraint
    WHERE (conrelid::regclass::text = 'adt_col' OR confrelid::regclass::text = 'adt_col') ORDER BY 1;

SELECT * FROM adt_table ORDER BY 1;
SELECT * FROM adt_col ORDER BY 1;
SELECT * FROM adt_ref ORDER BY 1;

-- make sure that COPY (e.g., INSERT .. SELECT) and
-- alter_distributed_table works in the same TX
BEGIN;
SET LOCAL citus.enable_local_execution=OFF;
INSERT INTO adt_table SELECT x, x+1 FROM generate_series(1, 1000) x;
SELECT alter_distributed_table('adt_table', distribution_column:='a');
ROLLBACK;

BEGIN;
INSERT INTO adt_table SELECT x, x+1 FROM generate_series(1, 1000) x;
SELECT alter_distributed_table('adt_table', distribution_column:='a');
SELECT COUNT(*) FROM adt_table;
END;

SELECT table_name, citus_table_type, distribution_column, shard_count FROM public.citus_tables WHERE table_name::text = 'adt_table';


\c - - - :master_port
-- sometimes Postgres is a little slow to terminate the backends
-- even if PGFinish is sent. So, to prevent any flaky tests, sleep
SELECT pg_sleep(0.1);
-- since max_cached_conns_per_worker == 0 at this point, the
-- backend(s) that execute on the shards will be terminated
-- so show that there no internal backends
SET search_path TO single_node;
SET citus.next_shard_id TO 90730500;
SELECT count(*) from should_commit;
SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'citus_internal%';
SELECT get_all_active_client_backend_count();
BEGIN;
	SET LOCAL citus.shard_count TO 32;
	SET LOCAL citus.force_max_query_parallelization TO ON;
	SET LOCAL citus.enable_local_execution TO false;

	CREATE TABLE test (a int);
	SET citus.shard_replication_factor TO 1;
	SELECT create_distributed_table('test', 'a');
	SELECT count(*) FROM test;

	-- now, we should have additional 32 connections
    SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'citus_internal%';

    -- single external connection
    SELECT get_all_active_client_backend_count();
ROLLBACK;


\c - - - :master_port
SET search_path TO single_node;
SET citus.next_shard_id TO 90830500;

-- simulate that even if there is no connection slots
-- to connect, Citus can switch to local execution
SET citus.force_max_query_parallelization TO false;
SET citus.log_remote_commands TO ON;
ALTER SYSTEM SET citus.local_shared_pool_size TO -1;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SET citus.executor_slow_start_interval TO 10;
SELECT count(*) from another_schema_table;

UPDATE another_schema_table SET b = b;

-- INSERT .. SELECT pushdown and INSERT .. SELECT via repartitioning
-- not that we ignore INSERT .. SELECT via coordinator as it relies on
-- COPY command
INSERT INTO another_schema_table SELECT * FROM another_schema_table;
INSERT INTO another_schema_table SELECT b::int, a::int FROM another_schema_table;

-- multi-row INSERTs
INSERT INTO another_schema_table VALUES (1,1), (2,2), (3,3), (4,4), (5,5),(6,6),(7,7);

-- INSERT..SELECT with re-partitioning when using local execution
BEGIN;
INSERT INTO another_schema_table VALUES (1,100);
INSERT INTO another_schema_table VALUES (2,100);
INSERT INTO another_schema_table SELECT b::int, a::int FROM another_schema_table;
SELECT * FROM another_schema_table WHERE a = 100 ORDER BY b;
ROLLBACK;

-- intermediate results
WITH cte_1 AS (SELECT * FROM another_schema_table LIMIT 1000)
	SELECT count(*) FROM cte_1;

-- this is to get ready for the next tests
TRUNCATE another_schema_table;

-- copy can use local execution even if there is no connection available
COPY another_schema_table(a) FROM PROGRAM 'seq 32';

-- INSERT .. SELECT with co-located intermediate results
SET citus.log_remote_commands to false;
CREATE UNIQUE INDEX another_schema_table_pk ON another_schema_table(a);

SET citus.log_local_commands to true;
INSERT INTO another_schema_table SELECT * FROM another_schema_table LIMIT 10000 ON CONFLICT(a) DO NOTHING;
INSERT INTO another_schema_table SELECT * FROM another_schema_table ORDER BY a LIMIT 10 ON CONFLICT(a) DO UPDATE SET b = EXCLUDED.b + 1 RETURNING *;

-- INSERT .. SELECT with co-located intermediate result for non-binary input
WITH cte_1 AS
(INSERT INTO non_binary_copy_test SELECT * FROM non_binary_copy_test LIMIT 10000 ON CONFLICT (key) DO UPDATE SET value = (0, 'citus0')::new_type RETURNING value)
SELECT count(*) FROM cte_1;

-- test with NULL columns
ALTER TABLE non_binary_copy_test ADD COLUMN z INT;
WITH cte_1 AS
(INSERT INTO non_binary_copy_test SELECT * FROM non_binary_copy_test LIMIT 10000 ON CONFLICT (key) DO UPDATE SET value = (0, 'citus0')::new_type RETURNING z)
SELECT bool_and(z is null) FROM cte_1;

-- test with type coersion (int -> text) and also NULL values with coersion
WITH cte_1 AS
(INSERT INTO non_binary_copy_test SELECT * FROM non_binary_copy_test LIMIT 10000 ON CONFLICT (key) DO UPDATE SET value = (0, 'citus0')::new_type RETURNING key, z)
SELECT count(DISTINCT key::text), count(DISTINCT z::text) FROM cte_1;

-- test disabling drop and truncate for known shards
SET citus.shard_replication_factor TO 1;
CREATE TABLE test_disabling_drop_and_truncate (a int);
SELECT create_distributed_table('test_disabling_drop_and_truncate', 'a');
SET citus.enable_manual_changes_to_shards TO off;

-- these should error out
DROP TABLE test_disabling_drop_and_truncate_90830500;
TRUNCATE TABLE test_disabling_drop_and_truncate_90830500;

RESET citus.enable_manual_changes_to_shards ;

-- these should work as expected
TRUNCATE TABLE test_disabling_drop_and_truncate_90830500;
DROP TABLE test_disabling_drop_and_truncate_90830500;

DROP TABLE test_disabling_drop_and_truncate;

-- test creating distributed or reference tables from shards
CREATE TABLE test_creating_distributed_relation_table_from_shard (a int);
SELECT create_distributed_table('test_creating_distributed_relation_table_from_shard', 'a');

-- these should error because shards cannot be used to:
-- create distributed table
SELECT create_distributed_table('test_creating_distributed_relation_table_from_shard_90830504', 'a');

-- create reference table
SELECT create_reference_table('test_creating_distributed_relation_table_from_shard_90830504');

RESET citus.shard_replication_factor;
DROP TABLE test_creating_distributed_relation_table_from_shard;

-- lets flush the copy often to make sure everyhing is fine
SET citus.local_copy_flush_threshold TO 1;
TRUNCATE another_schema_table;
INSERT INTO another_schema_table(a) SELECT i from generate_Series(0,10000)i;
WITH cte_1 AS
(INSERT INTO another_schema_table SELECT * FROM another_schema_table ORDER BY a LIMIT 10000 ON CONFLICT(a) DO NOTHING RETURNING *)
SELECT count(*) FROM cte_1;
WITH cte_1 AS
(INSERT INTO non_binary_copy_test SELECT * FROM non_binary_copy_test LIMIT 10000 ON CONFLICT (key) DO UPDATE SET value = (0, 'citus0')::new_type RETURNING z)
SELECT bool_and(z is null) FROM cte_1;

RESET citus.local_copy_flush_threshold;

RESET citus.local_copy_flush_threshold;

CREATE OR REPLACE FUNCTION coordinated_transaction_should_use_2PC()
RETURNS BOOL LANGUAGE C STRICT VOLATILE AS 'citus',
$$coordinated_transaction_should_use_2PC$$;

-- a multi-shard/single-shard select that is failed over to local
-- execution doesn't start a 2PC
BEGIN;
	SELECT count(*) FROM another_schema_table;
	SELECT count(*) FROM another_schema_table WHERE a = 1;
	WITH cte_1 as (SELECT * FROM another_schema_table LIMIT 10)
		SELECT count(*) FROM cte_1;
	WITH cte_1 as (SELECT * FROM another_schema_table WHERE a = 1 LIMIT 10)
		SELECT count(*) FROM cte_1;
	SELECT coordinated_transaction_should_use_2PC();
ROLLBACK;

-- same without a transaction block
WITH cte_1 AS (SELECT count(*) as cnt FROM another_schema_table LIMIT 1000),
	 cte_2 AS (SELECT coordinated_transaction_should_use_2PC() as enabled_2pc)
SELECT cnt, enabled_2pc FROM cte_1, cte_2;

-- a multi-shard modification that is failed over to local
-- execution starts a 2PC
BEGIN;
	UPDATE another_schema_table SET b = b + 1;
	SELECT coordinated_transaction_should_use_2PC();
ROLLBACK;

-- a multi-shard modification that is failed over to local
-- execution starts a 2PC
BEGIN;
	WITH cte_1 AS (UPDATE another_schema_table SET b = b + 1 RETURNING *)
		SELECT count(*) FROM cte_1;
	SELECT coordinated_transaction_should_use_2PC();
ROLLBACK;

-- same without transaction block
WITH cte_1 AS (UPDATE another_schema_table SET b = b + 1 RETURNING *)
SELECT coordinated_transaction_should_use_2PC();

-- a single-shard modification that is failed over to local
-- starts 2PC execution
BEGIN;
	UPDATE another_schema_table SET b = b + 1 WHERE a = 1;
	SELECT coordinated_transaction_should_use_2PC();
ROLLBACK;

-- if the local execution is disabled, we cannot failover to
-- local execution and the queries would fail
SET citus.enable_local_execution TO  false;
SELECT count(*) from another_schema_table;
UPDATE another_schema_table SET b = b;
INSERT INTO another_schema_table SELECT * FROM another_schema_table;
INSERT INTO another_schema_table SELECT b::int, a::int FROM another_schema_table;
WITH cte_1 AS (SELECT * FROM another_schema_table LIMIT 1000)
	SELECT count(*) FROM cte_1;

INSERT INTO another_schema_table VALUES (1,1), (2,2), (3,3), (4,4), (5,5),(6,6),(7,7);

-- copy fails if local execution is disabled and there is no connection slot
COPY another_schema_table(a) FROM PROGRAM 'seq 32';

-- set the values to originals back
ALTER SYSTEM RESET citus.max_cached_conns_per_worker;
ALTER SYSTEM RESET citus.distributed_deadlock_detection_factor;
ALTER SYSTEM RESET citus.recover_2pc_interval;
ALTER SYSTEM RESET citus.distributed_deadlock_detection_factor;
ALTER SYSTEM RESET citus.local_shared_pool_size;
SELECT pg_reload_conf();



-- suppress notices
SET client_min_messages TO error;

-- cannot remove coordinator since a reference table exists on coordinator and no other worker nodes are added
SELECT 1 FROM master_remove_node('localhost', :master_port);

-- Cleanup
DROP SCHEMA single_node CASCADE;
-- Remove the coordinator again
SELECT 1 FROM master_remove_node('localhost', :master_port);
-- restart nodeid sequence so that multi_cluster_management still has the same
-- nodeids
ALTER SEQUENCE pg_dist_node_nodeid_seq RESTART 1;
