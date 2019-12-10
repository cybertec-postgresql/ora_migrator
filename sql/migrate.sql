/*
 * Test migration from Oracle.
 *
 * This requires that an Oracle database is running on the same
 * machine, the test schema has been created with "ora_mktest.sql",
 * ORACLE_SID and ORACLE_HOME are defined in the PostgreSQL server's
 * environment and the Oracle library directory is in the
 * library path.
 */

SET client_min_messages = WARNING;

/* create a user to perform the migration */
DROP ROLE IF EXISTS migrator;

CREATE ROLE migrator LOGIN;

/* create all requisite extensions */
CREATE EXTENSION oracle_fdw;
CREATE EXTENSION db_migrator;
CREATE EXTENSION ora_migrator;

/* create a foreign server and a user mapping */
CREATE SERVER oracle FOREIGN DATA WRAPPER oracle_fdw
   OPTIONS (dbserver '');

CREATE USER MAPPING FOR PUBLIC SERVER oracle
   OPTIONS (user 'testschema1', password 'good_password');

/* give the user the required permissions */
GRANT CREATE ON DATABASE contrib_regression TO migrator;

GRANT USAGE ON FOREIGN SERVER oracle TO migrator;

/* connect as migration user */
\connect - migrator

SET client_min_messages = WARNING;

/* set up staging schemas */
SELECT db_migrate_prepare(
   plugin => 'ora_migrator',
   server => 'oracle',
   only_schemas => ARRAY['TESTSCHEMA1', 'TESTSCHEMA2'],
   options => JSONB '{"max_long": 1024}'
);

SELECT schema, task_type, task_content, task_unit, sum(migration_hours)
FROM fdw_stage.migration_cost_estimate
WHERE schema IN ('TESTSCHEMA1', 'TESTSCHEMA2')
GROUP BY GROUPING SETS ((schema, task_type, task_content, task_unit), (schema))
ORDER BY schema, task_type;

/* edit some values in the staging schema */
UPDATE pgsql_stage.triggers
   SET trigger_body = replace(
                         replace(trigger_body, ':NEW', 'NEW'),
                         'USER',
                         'current_user'
                      )
   WHERE schema = 'testschema1'
     AND table_name = 'tab1'
     AND trigger_name = 'tab1_trig';

UPDATE pgsql_stage.functions SET migrate = TRUE;

UPDATE pgsql_stage.functions
   SET source = replace(
                   replace(
                      replace(source, 'RETURN DATE', 'RETURNS date'),
                      'BEGIN',
                      '$$BEGIN'
                   ),
                   'END;',
                   'END;$$ LANGUAGE plpgsql'
                )
   WHERE schema = 'testschema1'
     AND function_name = 'tomorrow';

UPDATE pgsql_stage.triggers SET migrate = TRUE;

/* test "baddata" for problems */
SELECT message
FROM oracle_test_table('oracle', 'testschema1', 'baddata')
ORDER BY message;

/* perform the migration */
SELECT db_migrate_mkforeign(
   plugin => 'ora_migrator',
   server => 'oracle',
   options => JSONB '{"max_long": 1024}'
);

SELECT oracle_migrate_test_data(
   server => 'oracle',
   only_schemas => ARRAY['TESTSCHEMA1', 'TESTSCHEMA2']
);

SELECT db_migrate_tables(
   plugin => 'ora_migrator'
);

SELECT db_migrate_constraints(
   plugin => 'ora_migrator'
);

SELECT db_migrate_functions(
   plugin => 'ora_migrator'
);

SELECT db_migrate_triggers(
   plugin => 'ora_migrator'
);

SELECT db_migrate_views(
   plugin => 'ora_migrator'
);

/* we have to check the log table before we drop the schema */
SELECT operation, schema_name, object_name, failed_sql, error_message
FROM pgsql_stage.migrate_log
ORDER BY log_time;

SELECT db_migrate_finish();
