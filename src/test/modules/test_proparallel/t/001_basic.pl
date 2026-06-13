# Copyright (c) 2026, PostgreSQL Global Development Group

# Test parallel autovacuum behavior

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

# Check if the extension injection_points is available, as it may be
# possible that this script is run with installcheck, where the module
# would not be installed by default.
if (!$node->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

# Create all functions needed for testing
$node->safe_psql(
	'postgres', qq{
	CREATE EXTENSION injection_points;
});

# Objects that are depend on given table
sub print_rel_dependencies
{
	my ($node, $relname) = @_;
	my $psql_out;

	$psql_out = $node->safe_psql('postgres', qq{
		SELECT
		    dep_name AS dependent_name,
		    dep_class_id AS dependency_classid
		FROM (
		    SELECT
		        d.classid AS dep_class_id,
		        CASE
		            WHEN d.classid = 'pg_class'::regclass THEN c.relname
		            WHEN d.classid = 'pg_type'::regclass THEN t.typname
		            WHEN d.classid = 'pg_proc'::regclass THEN p.proname
		            WHEN d.classid = 'pg_trigger'::regclass THEN tr.tgname
		            WHEN d.classid = 'pg_attrdef'::regclass THEN 'default value for column ' || a.adnum
		            WHEN d.classid = 'pg_constraint'::regclass THEN con.conname
		            ELSE '(unknown)'
		        END AS dep_name
		    FROM pg_depend d
		    JOIN pg_class src ON d.refobjid = src.oid AND d.refclassid = 'pg_class'::regclass
		    LEFT JOIN pg_class c ON d.objid = c.oid AND d.classid = 'pg_class'::regclass
		    LEFT JOIN pg_type t ON d.objid = t.oid AND d.classid = 'pg_type'::regclass
		    LEFT JOIN pg_proc p ON d.objid = p.oid AND d.classid = 'pg_proc'::regclass
		    LEFT JOIN pg_trigger tr ON d.objid = tr.oid AND d.classid = 'pg_trigger'::regclass
		    LEFT JOIN pg_attrdef a ON d.objid = a.oid AND d.classid = 'pg_attrdef'::regclass
		    LEFT JOIN pg_constraint con ON d.objid = con.oid AND d.classid = 'pg_constraint'::regclass
		    WHERE src.relname = '$relname'
		) sub;
	});

	diag("\ndependencies of $relname:\n$psql_out\n");
}

sub print_rel_referencers
{
	my ($node, $relname) = @_;
	my $psql_out;

	$psql_out = $node->safe_psql('postgres', qq{
		SELECT
		    src_name AS source_name,
		    src_class_id AS source_classid
		FROM (
		    SELECT
		        d.refclassid AS src_class_id,
		        CASE
		            WHEN d.refclassid = 'pg_class'::regclass THEN c.relname
		            WHEN d.refclassid = 'pg_type'::regclass THEN t.typname
		            WHEN d.refclassid = 'pg_proc'::regclass THEN p.proname
		            WHEN d.refclassid = 'pg_trigger'::regclass THEN tr.tgname
		            WHEN d.refclassid = 'pg_namespace'::regclass THEN n.nspname || ' (from pg_namespace)'
		            WHEN d.refclassid = 'pg_attrdef'::regclass THEN 'default value for column ' || a.adnum
		            WHEN d.refclassid = 'pg_constraint'::regclass THEN con.conname
		            ELSE '(unknown)'
		        END AS src_name
		    FROM pg_depend d
		    JOIN pg_class dep ON d.objid = dep.oid AND d.classid = 'pg_class'::regclass
		    LEFT JOIN pg_class c ON d.refobjid = c.oid AND d.refclassid = 'pg_class'::regclass
		    LEFT JOIN pg_type t ON d.refobjid = t.oid AND d.refclassid = 'pg_type'::regclass
		    LEFT JOIN pg_proc p ON d.refobjid = p.oid AND d.refclassid = 'pg_proc'::regclass
		    LEFT JOIN pg_trigger tr ON d.refobjid = tr.oid AND d.refclassid = 'pg_trigger'::regclass
		    LEFT JOIN pg_namespace n ON d.refobjid = n.oid AND d.refclassid = 'pg_namespace'::regclass
		    LEFT JOIN pg_attrdef a ON d.refobjid = a.oid AND d.refclassid = 'pg_attrdef'::regclass
		    LEFT JOIN pg_constraint con ON d.refobjid = con.oid AND d.refclassid = 'pg_constraint'::regclass
		    WHERE dep.relname = 'users'
		) sub;
	});

	diag("\nreferencers of $relname:\n$psql_out\n");
}

sub get_rel_proparallel
{
	my ($node, $relname) = @_;
	my $psql_out;

	$psql_out = $node->safe_psql('postgres', qq{
		SELECT relparalleldml FROM pg_class WHERE relname = '$relname';
	});

	# diag("\nproparallel of $relname: $psql_out\n");
	return $psql_out;
}

# Create table and fill it with some data
$node->safe_psql('postgres', qq{
	CREATE TABLE logtable (
	    id SERIAL PRIMARY KEY,
	    table_name VARCHAR(100),
	    operation VARCHAR(20),
	    row_id INTEGER
	);

	CREATE TABLE users (
	    id SERIAL PRIMARY KEY,
	    name VARCHAR(100) NOT NULL,
	    created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE OR REPLACE FUNCTION log_insert_operation()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	PARALLEL RESTRICTED
	AS \$\$
	BEGIN
	    INSERT INTO logtable (table_name, operation, row_id)
	    VALUES (TG_TABLE_NAME, TG_OP, NEW.id);

	    RETURN NEW;
	END;
	\$\$;

	CREATE OR REPLACE FUNCTION log_insert_operation_1()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	PARALLEL UNSAFE
	AS \$\$
	BEGIN
	    INSERT INTO logtable (table_name, operation, row_id)
	    VALUES (TG_TABLE_NAME, TG_OP, NEW.id);

	    RETURN NEW;
	END;
	\$\$;

	CREATE OR REPLACE FUNCTION log_insert_operation_2()
	RETURNS TRIGGER
	LANGUAGE plpgsql
	PARALLEL SAFE
	AS \$\$
	BEGIN
	    INSERT INTO logtable (table_name, operation, row_id)
	    VALUES (TG_TABLE_NAME, TG_OP, NEW.id);

	    RETURN NEW;
	END;
	\$\$;
});

# ---
# OK, lets do it
# ---

my $proparallel;

$node->safe_psql('postgres', qq{

	-- Super main table
	CREATE TABLE main_table (
		id SERIAL,
		category VARCHAR(50) NOT NULL,
		created_at DATE NOT NULL
	) PARTITION BY RANGE (created_at);

	-- First partition
	CREATE TABLE main_table_2023
	PARTITION OF main_table
	FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');

	-- Second partition that is partitioned table itself
	CREATE TABLE main_table_2024 (
		id SERIAL,
		category VARCHAR(50) NOT NULL,
		created_at DATE NOT NULL
	) PARTITION BY LIST (category);

	ALTER TABLE main_table ATTACH PARTITION main_table_2024
	FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

	CREATE TABLE main_table_2024_category_a
	PARTITION OF main_table_2024
	FOR VALUES IN ('A');

	CREATE TABLE main_table_2024_category_b
	PARTITION OF main_table_2024
	FOR VALUES IN ('B');

});

# Check that everybody's hazard is set to "safe"
$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "s");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "s");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "s");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "s");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "s");

# FOR EACH ROW trigger will be created for each partition
$node->safe_psql('postgres', qq{
	CREATE TRIGGER main_table_insert_trigger
	BEFORE INSERT ON main_table
	FOR EACH ROW
	EXECUTE FUNCTION log_insert_operation();
});

# Check that each partition updated its hazard after trigger creation
$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "r");

# FOR EACH STATEMENT trigger will not be created for each partition, but they
# must update their hazards anyway
# TODO check such trigger creation for one of a children (must lead to parent's hazard recompution)
$node->safe_psql('postgres', qq{
	CREATE TRIGGER main_table_insert_trigger_1
    AFTER INSERT ON main_table
    FOR EACH STATEMENT
	EXECUTE FUNCTION log_insert_operation_1();
});

$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "r");

$node->safe_psql('postgres', qq{
	CREATE TRIGGER main_table_2024_category_b_insert_trigger
    AFTER INSERT ON main_table_2024_category_b
    FOR EACH STATEMENT
	EXECUTE FUNCTION log_insert_operation_1();
});

$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "u");

$node->safe_psql('postgres', qq{
	DROP TRIGGER main_table_2024_category_b_insert_trigger
	ON main_table_2024_category_b;
});

$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "r");

$node->safe_psql('postgres', qq{
	CREATE TRIGGER main_table_2024_category_b_insert_trigger
    AFTER INSERT ON main_table_2024_category_b
    FOR EACH STATEMENT
	EXECUTE FUNCTION log_insert_operation_2();
});

$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "r");

# function is depending on pg_language and pg_namespace
$node->safe_psql('postgres', qq{
	ALTER FUNCTION log_insert_operation_2() PARALLEL UNSAFE;
});

$proparallel = get_rel_proparallel($node, "main_table");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2023");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024");
is($proparallel, "u");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_a");
is($proparallel, "r");
$proparallel = get_rel_proparallel($node, "main_table_2024_category_b");
is($proparallel, "u");

$node->stop;
done_testing();
