# Test access to temporary tables of other sessions

# We need to know oid of first session's temporary schema
setup { CREATE TABLE temp_schema_id(oid oid); }

teardown { DROP TABLE temp_schema_id; }

session s1

# In first session we only need to create temporary table and "remember" its oid
step s1_st1 { CREATE TEMP TABLE test_tmp(id int); }
step s1_st2 { INSERT INTO temp_schema_id SELECT pg_my_temp_schema(); }

session s2

# In this DO block we will try to access to temp table created before via
# INSERT/UPDATE/DELETE/SELECT/TRUNCATE/LOCK operations
step s2_st1
{
    DO $$
        DECLARE
            schema_name text;
            result      RECORD;
        BEGIN
            -- Find out name of temporary schema of first session
            SELECT nspname INTO schema_name
              FROM pg_namespace
             WHERE oid = (SELECT oid FROM temp_schema_id LIMIT 1);

            -- Both INSERT operation must fail due to 'cannot access temporary
            -- tables of other sessions' error
            BEGIN
                EXECUTE format('INSERT INTO %I.test_tmp VALUES (1);', schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            BEGIN
                EXECUTE format('INSERT INTO %I.test_tmp VALUES (2);', schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            -- SELECT operation must fail due to 'cannot access temporary tables
            -- of other sessions' error
            BEGIN
                FOR result IN
                    EXECUTE format('SELECT * FROM %I.test_tmp;', schema_name) LOOP
                        RAISE NOTICE '%', result;
                    END LOOP;
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            -- UPDATE operation must fail due to 'cannot access temporary tables
            -- of other sessions' error
            BEGIN
                EXECUTE format('UPDATE %I.test_tmp SET id = 100 WHERE id = 3;', schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            -- DELETE operation must fail due to 'cannot access temporary tables
            -- of other sessions' error
            BEGIN
                EXECUTE format('DELETE FROM %I.test_tmp WHERE id = 3;', schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            -- LOCK operation must fail due to 'cannot access temporary tables
            -- of other sessions' error
            BEGIN
                EXECUTE format('BEGIN;
                                LOCK TABLE %I.test_tmp;
                                COMMIT;',
                                schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;

            -- DROP operation must fail due to 'cannot access temporary tables
            -- of other sessions' error
            BEGIN
                EXECUTE format('DROP TABLE %I.test_tmp;', schema_name);
            EXCEPTION
                WHEN feature_not_supported
                THEN RAISE NOTICE 'cannot access temporary tables of other sessions';
            END;
        END
    $$;
}

permutation
    s1_st1
    s1_st2
    s2_st1