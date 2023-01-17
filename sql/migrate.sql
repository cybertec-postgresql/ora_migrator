/*
 * Test migration from Oracle.
 *
 * This requires that an Oracle database is running on the same
 * machine, the test schema has been created with "ora_mktest.sql",
 * ORACLE_SID and ORACLE_HOME are defined in the PostgreSQL server's
 * environment and the Oracle library directory is in the
 * library path.
 */

/* connect as migration user */
\connect - migrator

SET client_min_messages = WARNING;

/* remove potential leftovers from previous tests */
DO
$$BEGIN
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TRIGGER testschema1."__Log_BADDATA_TRIG"');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TABLE testschema1."__Log_BADDATA" PURGE');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TRIGGER testschema1."__Log_LOG_TRIG"');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TABLE testschema1."__Log_LOG" PURGE');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TRIGGER testschema1."__Log_TAB1_TRIG"');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TABLE testschema1."__Log_TAB1" PURGE');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TRIGGER testschema1."__Log_TAB2_TRIG"');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TABLE testschema1."__Log_TAB2" PURGE');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TRIGGER testschema2."__Log_TAB3_TRIG"');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   BEGIN
      PERFORM oracle_execute('oracle', 'DROP TABLE testschema2."__Log_TAB3" PURGE');
   EXCEPTION
      WHEN fdw_unable_to_create_execution THEN NULL;
   END;
   PERFORM oracle_execute('oracle', 'DELETE FROM testschema1.tab1 WHERE id >= 3');
   PERFORM oracle_execute('oracle', 'DELETE FROM testschema1.log WHERE id >= 3');
END;$$;

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
  AND task_type <> 'data_migration'  /* size is variable */
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

SELECT oracle_migrate_test_data(
   server => 'oracle',
   only_schemas => ARRAY['TESTSCHEMA1', 'TESTSCHEMA2']
);

/* strip zero bytes from "baddata" (will still fail) */
UPDATE pgsql_stage.columns
SET options = JSONB '{"strip_zeros": "true"}'
WHERE schema = 'testschema1'
  AND table_name = 'baddata'
  AND column_name = 'value1';

/* perform the data migration */
SELECT db_migrate_mkforeign(
   plugin => 'ora_migrator',
   server => 'oracle',
   options => JSONB '{"max_long": 1024}'
);

/* no replication for "baddata" */
UPDATE pgsql_stage.tables SET
   migrate = FALSE
WHERE schema = 'testschema1'
  AND table_name = 'baddata';

/* set up replication */
SELECT oracle_replication_start(
   server => 'oracle'
);

/* but we want to get the migration errors for "baddata" */
UPDATE pgsql_stage.tables SET
   migrate = TRUE
WHERE schema = 'testschema1'
  AND table_name = 'baddata';

/* migrate the rest of the database */
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

/* no replication for "baddata" */
UPDATE pgsql_stage.tables SET
   migrate = FALSE
WHERE schema = 'testschema1'
  AND table_name = 'baddata';

/* add some test data for replication */
SELECT oracle_execute(
          'oracle',
          E'INSERT INTO tab1 (id, vc, n, bf, bd, d, ts)\n'
          'VALUES (3, ''string'', 123, 3.14, 2.718,\n'
          '        to_date(''2020-04-01'', ''YYYY-MM-DD''),\n'
          '        to_timestamp(''2020-04-01 08:30:00'', ''YYYY-MM-DD HH24:MI:SS''))'
       );

SELECT oracle_execute(
          'oracle',
          E'INSERT INTO tab1 (id, vc, n, bf, bd, d, ts)\n'
          'VALUES (4, ''string 2'', -123, 3.14, -2.718,\n'
          '        to_date(''0044-03-15 BC'', ''YYYY-MM-DD AD''),\n'
          '        to_timestamp(''0033-03-31 15:00:00'', ''YYYY-MM-DD HH24:MI:SS''))'
       );

SELECT oracle_execute(
          'oracle',
          E'UPDATE tab1 SET d = to_date(''1970-04-01'', ''YYYY-MM-DD''), ts = NULL WHERE id = 4'
       );

SELECT oracle_execute(
          'oracle',
          E'UPDATE tab1 SET id = 99, vc = ''newstring'' WHERE id = 4'
       );

SELECT oracle_execute(
          'oracle',
          E'DELETE FROM tab1 WHERE id = 99'
       );

/* catch up on Oracle data modifications */

SELECT oracle_replication_catchup();

/* one more change and a second catch-up */

SELECT oracle_execute(
          'oracle',
          E'DELETE FROM tab1 WHERE id = 3'
       );

SELECT oracle_replication_catchup();

/* clean up replication tools */

SELECT oracle_replication_finish('oracle');

/* we have to check the log table before we drop the schema */
SELECT operation, schema_name, object_name, failed_sql, error_message
FROM pgsql_stage.migrate_log
ORDER BY log_time;

SELECT db_migrate_finish();

/* clean up Oracle test data */
SELECT oracle_execute('oracle', 'DELETE FROM testschema1.tab1 WHERE id >= 3');
SELECT oracle_execute('oracle', 'DELETE FROM testschema1.log WHERE id >= 3');
