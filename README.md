Oracle to PostgreSQL migration tools
====================================

ora_migrator is a PostgreSQL extension that uses
[oracle_fdw](http://laurenz.github.io/oracle_fdw/)
to migrate an Oracle database to PostgreSQL.

In addition to that, it provides foreign tables and views that allow
convenient access to Oracle metadata from PostgreSQL.

Prerequisites
=============

- The oracle_fdw extension must be installed.

- A foreign server must be defined for the Oracle database you want
  to access.

- The user who calls the `create_oraviews` function to create the
  foreign tables must have the `USAGE` privilege on the foreign server.

- A user mapping must exist for the user who calls the `create_oraviews`
  function.

- The Oracle user used in the user mapping must have privileges to read
  the following Oracle dictionary views:

  - `ALL_CONS_COLUMNS`
  - `ALL_CONSTRAINTS`
  - `ALL_IND_COLUMNS`
  - `ALL_IND_EXPRESSIONS`
  - `ALL_INDEXES`
  - `ALL_MVIEWS`
  - `ALL_PROCEDURES`
  - `ALL_SEQUENCES`
  - `ALL_SOURCE`
  - `ALL_TAB_COLUMNS`
  - `ALL_TABLES`
  - `ALL_USERS`
  - `ALL_VIEWS`

  You can choose to grant the use the `SELECT ANY DICTIONARY`
  system privilege instead.

Installation
============

The extension files must be placed in the `extension` subdirectory of
the PostgreSQL shared files directory, which can be found with

    pg_config --sharedir

The extension is installed with the SQL command

    CREATE EXTENSION ora_migrator;

This statement can be executed by any user with the right to create
functions in the `public` schema (or the schema you specified in the
optional `SCHEMA` clause of `CREATE EXTENSION`).

Objects created by the extension
================================

- Function `oracle_migrate`:

  Performs a migration from an Oracle foreign server to PostgreSQL.

  The parameters are:

  - `server`: the name of the Oracle foreign server which will be migrated
    to PostgreSQL.  
    You must have the `USAGE` privilege on that server.

  - `staging_schema` (default `ora_staging`): the name of a schema that
    will be created for temporary objects used during the migration
    (specifically, the objects created by `create_oraviews`).

  - `schemas` (default NULL): an array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

  - `max_long` (default 32767): the maximal length of view definitions,
    `DEFAULT` and index expressions in Oracle.

  You need permissions to create schemas in the PostgreSQL database
  to use this function.

- Function `oracle_migrate_prepare`:

  Performs the first step of `oracle_migrate`.

  The parameters are the same as for `oracle_migrate`.

  Steps performed:

  - Create the staging schema.

  - Call `create_oraviews` to create the metadata views there.

  - Create all the destination schemas for the migration.

  - Use `IMPORT FOREIGN SCHEMA` to create foreign tables in the
    destination schemas.

- Function `oracle_materialize`:

  Replaces a foreign table with a real table.

  The parameters are:

  - `s`: name of the PostgreSQL schema where the foreign table is.

  - `t`: name of a foreign table.

- Function `oracle_migrate_tables`:

  Calls `oracle_materialize` for all foreign tables in a migrated schemas
  to replace them with real tables.

  The parameters are:

  - `staging_schema` (default `ora_staging`): the name of the staging
    schema created by `oracle_migrate_prepare`.

  - `schemas` (default NULL): an array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

- Function `oracle_migrate_constraints`:

  Creates constraints and indexes on all tables migrated from Oracle with
  `oracle_migrate_tables`.

  The parameters are:

  - `staging_schema` (default `ora_staging`): the name of the staging
    schema created by `oracle_migrate_prepare`.

  - `schemas` (default NULL): an array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

- Function `oracle_migrate_finish`:

  Drops the staging schema.

  Parameter:

  - `staging_schema` (default `ora_staging`): the name of the staging
    schema created by `oracle_migrate_prepare`.

- Function `create_oraviews`:

  This function creates a number of foreign tables and views for
  Oracle metadata.  
  It takes the following parameters:

  - `server`: the name of the Oracle foreign server for which the
    foreign tables will be created.  
    You must have the `USAGE` privilege on that server.

  - `schema` (default `public`): the name of the schema where the
    foreign tables and views will be created.  
    The schema must exist, and you must have the `CREATE` privilege
    on it.

  - `max_long` (default 32767): the maximal length of view definitions,
    `DEFAULT` and index expressions in Oracle.

  Calling the function will create the following foreign tables and views:

  - `oracle_schemas`: Oracle schemas
  - `ora_checks`: Oracle ckeck constraints
  - `ora_columns`: columns of Oracle tables and views
  - `ora_foreign_keys`: columns of Oracle foreign key constraints
  - `ora_functions`: source code of Oracle functions and procedures
    (but not package or object definitions)
  - `ora_keys`: columns of Oracle primary and foreign keys
  - `ora_tables`: Oracle tables
  - `ora_views`: definition of Oracle views
  - `ora_sequences`: Oracle sequences
  - `ora_index_columns`: columns of Oracle indexes that do *not* belong
    to a constraint

  Objects in Oracle system schemas will not be shown.

Usage
=====

You can query the foreign tables with additional conditions, e.g.

    SELECT table_name,
           constraint_name,
           column_name,
           remote_table,
           remote_column
    FROM ora_foreign_keys
    WHERE schema = 'LAURENZ'
      AND remote_schema = 'LAURENZ'
    ORDER BY table_name, position;

Conditions will be pushed down to Oracle whenever that is possible
for oracle_fdw, so the queries should be efficient.

ALl Oracle object names will appear like they are in Oracle, which is
usually in upper case.
