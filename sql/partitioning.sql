
/* connect as migration user */
\connect - migrator

SET client_min_messages = WARNING;
SET datestyle = 'ISO, MDY';

/* set up staging schemas */
SELECT db_migrate_prepare(
   plugin => 'ora_migrator',
   server => 'oracle',
   only_schemas => ARRAY['TESTSCHEMA3'],
   options => JSONB '{"max_long": 1024}'
);

/* perform the data migration */
SELECT db_migrate_mkforeign(
   plugin => 'ora_migrator',
   server => 'oracle',
   options => JSONB '{"max_long": 1024}'
);

/* migrate the rest of the database */
SELECT db_migrate_tables(
   plugin => 'ora_migrator'
);

/* we have to check the log table before we drop the schema */
SELECT operation, schema_name, object_name, failed_sql, error_message
FROM pgsql_stage.migrate_log
ORDER BY log_time;

SELECT db_migrate_finish();

/* check results */

\d+ testschema3.part1
\d+ testschema3.part2
\d testschema3.part3

\d+ testschema3.part4
\d+ testschema3.part4_a
\d+ testschema3.part4_b

SELECT tableoid::regclass partname, * FROM testschema3.part1;
SELECT tableoid::regclass partname, * FROM testschema3.part2;
SELECT tableoid::regclass partname, * FROM testschema3.part3;
SELECT tableoid::regclass partname, * FROM testschema3.part4;