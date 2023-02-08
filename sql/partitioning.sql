/* for requirements, see "migrate.sql" */

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

/* create foreign tables */
SELECT db_migrate_mkforeign(
   plugin => 'ora_migrator',
   server => 'oracle',
   options => JSONB '{"max_long": 1024}'
);

/* migrate the data */
SELECT db_migrate_tables(
   plugin => 'ora_migrator'
);

/* migrate the constraints */
SELECT db_migrate_constraints(
   plugin => 'ora_migrator'
);

/* clean up */
SELECT db_migrate_finish();

/* check results */

\d+ testschema3.part1
\d+ testschema3.part2
\d+ testschema3.part3

SELECT tableoid::regclass partname, * FROM testschema3.part1;
SELECT tableoid::regclass partname, * FROM testschema3.part2;
SELECT tableoid::regclass partname, * FROM testschema3.part3;
