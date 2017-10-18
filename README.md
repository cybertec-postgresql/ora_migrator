Oracle to PostgreSQL migration tools
====================================

ora_migrator is a PostgreSQL extension that uses
[oracle_fdw](http://laurenz.github.io/oracle_fdw/)
to migrate an Oracle database to PostgreSQL.

Only sequences and normal tables with their constraints and indexes will
be migrated, all objects containing PL/SQL code (triggers, functions,
procedures and packages) will have to be migrated by hand.

In addition to that, the extension can be used to create foreign tables
and views that allow convenient access to Oracle metadata from PostgreSQL.

Cookbook
========

A superuser sets the stage:

    CREATE EXTENSION oracle_fdw;

    CREATE EXTENSION ora_migrator;

    CREATE SERVER oracle FOREIGN DATA WRAPPER oracle_fdw
       OPTIONS (dbserver '//dbserver.mydomain.com/ORADB');

    GRANT USAGE ON FOREIGN SERVER oracle TO migrator;

    CREATE USER MAPPING FOR migrator SERVER oracle
       OPTIONS (user 'orauser', password 'orapwd');

PostgreSQL user `migrator` has the privilege to create PostgreSQL schemas
and Oracle user `orauser` has the `SELECT ANY DICTIONARY` privilege.

Now we connect as `migrator` and perform the migration so that all objects
will belong to this user:

    SELECT oracle_migrate('oracle');

    NOTICE:  Creating staging schemas "ora_stage" and "pgsql_stage" ...
    NOTICE:  Creating Oracle metadata views in schema "ora_stage" ...
    NOTICE:  Copy definitions to PostgreSQL staging schema "pgsql_stage" ...
    NOTICE:  Creating schemas ...
    NOTICE:  Creating sequences ...
    NOTICE:  Creating foreign tables ...
    NOTICE:  Migrating table "social"."email" ...
    NOTICE:  Migrating table "social"."blog" ...
    NOTICE:  Migrating table "laurenz"."xml" ...
    WARNING:  Error loading table data for laurenz.xml
    DETAIL:  column "xml" of foreign table "xml" cannot be converted to or from Oracle data type
    NOTICE:  Migrating table "laurenz"."log" ...
    NOTICE:  Migrating table "laurenz"."integers" ...
    NOTICE:  Migrating table "laurenz"."employee" ...
    NOTICE:  Migrating table "laurenz"."department" ...
    NOTICE:  Creating UNIQUE and PRIMARY KEY constraints ...
    WARNING:  Error creating primary key or unique constraint on table laurenz.xml
    DETAIL:  relation "laurenz.xml" does not exist
    NOTICE:  Creating FOREIGN KEY constraints ...
    NOTICE:  Creating CHECK constraints ...
    NOTICE:  Creating indexes ...
    NOTICE:  Setting column default values ...
    NOTICE:  Dropping staging schemas ...
    NOTICE:  Migration completed with 2 errors.
    DEBUG:  oracle_fdw: commit remote transaction
     oracle_migrate 
    ----------------
                  2
    (1 row)

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

  - `DBA_CONS_COLUMNS`
  - `DBA_CONSTRAINTS`
  - `DBA_IND_COLUMNS`
  - `DBA_IND_EXPRESSIONS`
  - `DBA_INDEXES`
  - `DBA_MVIEWS`
  - `DBA_SEQUENCES`
  - `DBA_TAB_COLUMNS`
  - `DBA_TABLES`
  - `DBA_USERS`

  The above privileges are required for database migration.

  Additionally, `SELECT` privileges on the following dictionary views are
  required by some oth the views created by `create_oraviews`:
  
  - `DBA_PROCEDURES`
  - `DBA_SOURCE`
  - `DBA_VIEWS`
  - `DBA_TAB_PRIVS`
  - `DBA_COL_PRIVS`

  You can choose to grant the user the `SELECT ANY DICTIONARY`
  system privilege instead, which includes all of the above.

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
  Only tables and sequences are migrated, triggers, functions, procedures
  and packages will have to migrated by hand.

  The parameters are:

  - `server`: The name of the Oracle foreign server which will be migrated
    to PostgreSQL.  
    You must have the `USAGE` privilege on that server.

  - `staging_schema` (default `ora_stage`): The name of a schema that
    will be created for objects used during the migration
    (specifically, the objects created by `create_oraviews`).
    This schema will be dropped after the migration is completed.

  - `pgstage_schema` (default `pgsql_stage`): The name of a schema that
    will be created for tables containing PostgreSQL metadata.
    This schema will be dropped after the migration is completed.

  - `only_schemas` (default NULL): An array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

  - `max_long` (default 32767): The maximal length of view definitions,
    `DEFAULT` and index expressions in Oracle.

  You need permissions to create schemas in the PostgreSQL database
  to use this function.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `oracle_migrate_prepare`:

  Performs the first step of `oracle_migrate`.

  The parameters are the same as for `oracle_migrate`.

  Steps performed:

  - Create staging schemas for Oracle and PostgreSQL data.

  - Call `create_oraviews` to create the metadata in the Oracle stage.

  - Create tables in the PostgreSQL stage and fill them with values from
    the views in the Oracle stage.  Names and data types will be
    translated wherever possible.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `oracle_migrate_mkforeign`:

  Performs the second step of `oracle_migrate`.

  The parameters are the same as for `oracle_migrate`.

  Steps performed:

  - Create the destination schemas in the PostgreSQL database.

  - Create sequences in the destination schemas.

  - Create foreign tables in the destination schemas.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `oracle_materialize`:

  Replaces a foreign table with a real table and migrates the contents.  
  This function is used internally by `oracle_migrate_tables`, but can be
  useful to parallelize migration (see the "Usage" section).

  The parameters are:

  - `s`: The name of the PostgreSQL schema containing the foreign table.

  - `t`: The name of the PostgreSQL foreign table.

  The return value is TRUE if the operation succeeded, otherwise FALSE.

- Function `oracle_migrate_tables`:

  Calls `oracle_materialize` for all foreign tables in the migrated schemas
  to replace them with real tables.

  The parameters are:

  - `staging_schema` (default `ora_stage`): The name of the Oracle stage
    created by `oracle_migrate_prepare`.

  - `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
    created by `oracle_migrate_prepare`.

  - `only_schemas` (default NULL): An array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `oracle_migrate_constraints`:

  Creates constraints and indexes on all tables migrated from Oracle with
  `oracle_migrate_tables`.

  The parameters are:

  - `pgstage_schema` (default `pgsql_stage`): The name of the staging
    schema created by `oracle_migrate_prepare`.

  - `only_schemas` (default NULL): An array of Oracle schema names
    that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
    system schemas are processed.  
    The names must be as they appear in Oracle, which is usually in upper case.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `oracle_migrate_finish`:

  Drops the staging schemas.

  Parameter:

  - `staging_schema` (default `ora_stage`): The name of the Oracle staging
    schema created by `oracle_migrate_prepare`.

  - `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL
    staging schema created by `oracle_migrate_pgschema`.

  The return value is the number of captured errors that have been turned
  into warnings.

- Function `create_oraviews`:

  This function creates a number of foreign tables and views for
  Oracle metadata.  
  It takes the following parameters:

  - `server`: The name of the Oracle foreign server for which the
    foreign tables will be created.  
    You must have the `USAGE` privilege on that server.

  - `schema` (default `public`): The name of the schema where the
    foreign tables and views will be created.  
    The schema must exist, and you must have the `CREATE` privilege
    on it.

  - `max_long` (default 32767): The maximal length of view definitions,
    `DEFAULT` and index expressions in Oracle.

  Calling the function will create the following foreign tables and views:

  - `schemas`: Oracle schemas
  - `checks`: Oracle ckeck constraints
  - `column_privs`: Privileges on Oracle table columns
  - `columns`: columns of Oracle tables and views
  - `foreign_keys`: columns of Oracle foreign key constraints
  - `functions`: source code of Oracle functions and procedures
    (but not package or object definitions)
  - `keys`: columns of Oracle primary and foreign keys
  - `packages`: source code of Oracle packages and package bodies
  - `table_privs`: Privileges on Oracle tables
  - `tables`: Oracle tables
  - `triggers`: Oracle triggers
  - `views`: definition of Oracle views
  - `sequences`: Oracle sequences
  - `index_columns`: columns of Oracle indexes that do *not* belong
    to a constraint
  - `schemas`: Oracle schemas
  - `triggers`: Triggers on Oracle tables
  - `packages`: definition and bodies of PL/SQL packages
  - `table_privs`: privileges of users on tables
  - `column_privs`: privileges of users on table columns

  Objects in Oracle system schemas will not be shown.

Usage
=====

The main use of this extension is to migrate Oracle databases to PostgreSQL.

You can either perform the migration by calling `oracle_migrate`, or you do
it step by step:

- Call `oracle_migrate_prepare` to create the Oracle staging schema with the
  Oracle metadata views and the PostgreSQL staging schema with metadata
  copied and translated from the Oracle stage.

- After this step, you can modify the data in the PostgreSQL stage, from which
  the PostgreSQL tables are created.  This is useful if you want to modify
  data types, indexes or constraints.

  Be aware that you cannot rename the schema or table names, which are the
  link between Oracle and PostgreSQL tables.

- Call `oracle_migrate_mkforeign` to create the PostgreSQL schemas
  and sequences and foreign tables.

- Call `oracle_migrate_tables` to replace the foreign tables with real
  tables and migrate the data from Oracle.

  Alternatively, you can use `oracle_materialize` to do this step for
  Each table individually. This has the advantage that you can
  migrate several tables in parallel in multiple database sessions,
  which may speed up the migration process.

- Call `oracle_migrate_constraints` to migrate constraints and
  indexes from Oracle.

- Call `oracle_migrate_finish` to remove the staging schemas and complete
  the migration.

Apart from migration, you can use the function `create_oraviews` to create
foreign tables and views that allow convenient access to Oracle metadata
from PostgreSQL.

This is used by `oracle_migrate_prepare` to populate the staging schema,
but it may be useful for other tools.

These foreign tables can be used in arbitrary queries, e.g.

    SELECT table_name,
           constraint_name,
           column_name,
           remote_table,
           remote_column
    FROM foreign_keys
    WHERE schema = 'LAURENZ'
      AND remote_schema = 'LAURENZ'
    ORDER BY table_name, position;

The additional conditions will be pushed down to Oracle whenever that
is possible for oracle_fdw, so the queries should be efficient.

All Oracle object names will appear like they are in Oracle, which is
usually in upper case.
