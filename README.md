Oracle to PostgreSQL migration tools
====================================

`ora_migrator` is a plugin for [`db_migrator`][migrator] that uses
[`oracle_fdw`][fdw] to migrate an Oracle database to PostgreSQL.

Please read the `db_migrator` documentation for usage instructions;
this README only covers the installation and setup of the plugin
as well as additional features that are not covered in the general
documentation.


 [migrator]: https://github.com/cybertec-postgresql/db_migrator
 [fdw]: http://laurenz.github.io/oracle_fdw/

Prerequisites
=============

- You need PostgreSQL 9.5 or later.

- The `oracle_fdw` and `db_migrator` extensions must be installed.

- A foreign server must be defined for the Oracle database you want
  to access.

- The user who calls the `create_oraviews` function to create the
  foreign tables must have the `USAGE` privilege on the foreign server.

- A user mapping must exist for the user who calls the `create_oraviews`
  function.

- The Oracle user used in the user mapping must have privileges to read
  the following Oracle dictionary views:

  - `DBA_COL_PRIVS`
  - `DBA_CONS_COLUMNS`
  - `DBA_CONSTRAINTS`
  - `DBA_IND_COLUMNS`
  - `DBA_IND_EXPRESSIONS`
  - `DBA_INDEXES`
  - `DBA_MVIEWS`
  - `DBA_MVIEW_LOGS`
  - `DBA_PROCEDURES`
  - `DBA_SEGMENTS`
  - `DBA_SEQUENCES`
  - `DBA_SOURCE`
  - `DBA_TAB_COLUMNS`
  - `DBA_TAB_PRIVS`
  - `DBA_TABLES`
  - `DBA_TRIGGERS`
  - `DBA_USERS`
  - `DBA_VIEWS`

  You can choose to grant the user the `SELECT ANY DICTIONARY`
  system privilege instead, which includes all of the above.

Installation
============

The extension files must be placed in the `extension` subdirectory of
the PostgreSQL shared files directory, which can be found with

    pg_config --sharedir

If the extension building infrastructure PGXS is installed, you can do that
simply with

    make install

The extension is installed with the SQL command

    CREATE EXTENSION ora_migrator;

This statement can be executed by any user with the right to create
functions in the `public` schema (or the schema you specified in the
optional `SCHEMA` clause of `CREATE EXTENSION`).

Objects created by the extension
================================

Migration functions
-------------------

The `db_migrator` callback function `db_migrator_callback()` returns the
migration functions provided by the extension.
See the `db_migrator` documentation for details.

The "metadata view creation function" `create_oraviews` creates some
additional objects in the FDW stage that provide information that will be
helpful for Oracle migrations:

### package definitions ###

    packages (
       schema       text    NOT NULL,
       package_name text    NOT NULL,
       is_body      boolean NOT NULL,
       source       text    NOT NULL
    )

- `is_body` is `FALSE` for the package definition and `TRUE` for the
  package body definition

This view can be used to make the transation of package code easier.

### segments ###

    segments (
       schema       text   NOT NULL,
       segment_name text   NOT NULL,
       segment_type text   NOT NULL,
       bytes        bigint NOT NULL
    )

This foreign table is most useful for assessing the size of tables and
indexes in Oracle.

### migration cost estimate ###

    migration_cost_estimate (
       schema          text    NOT NULL,
       task_type       text    NOT NULL,
       task_content    bigint  NOT NULL,
       task_unit       text    NOT NULL,
       migration_hours integer NOT NULL
    )

- `task_type` is one of `tables`, `data_migration`, `functions`, `triggers`,
  `packages` and `views`.

- `task_content` is the quantity for this taks type

- `task_unit` is the unit of `task_content`

- `migration_hours` is a rough estimate of the hours it may take to complete
  this task

This view can help to assess the migration costs for an Oracle database.

Additional objects
------------------

### table function `oracle_test_table` ###

This function tests an Oracle table for potential migration problems.
You have to run it after `db_migrate_prepare`.

The parameters are:

- `server`: the name of the Oracle foreign server

- `schema`: the schema name

- `table_name`: the table name

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `db_migrate_prepare`.

`schema` and `table_name` must be values from the columns of the same name
of the `tables` table in the PostgreSQL stage.

This is a table function and returns the Oracle ROWID of the problematic
rows as well as a message describing the problem.

Currently there are tests for two problems:

- zero bytes `chr(0)` in string columns

- values in string columns that are not in the database encoding

### function `oracle_migrate_test_data` ###

This function calls `oracle_test_table` for all tables in the
PostgreSQL staging schema and records the results in the table `test_error`
in the FDW stage (after emptying the table).

In addition, an error summary is added to the table `test_error_stats`
in the FDW stage.  This is useful for measuring the progress of
cleaning up bad data in Oracle over time.

The function returns the total number of errors encountered.

The function parameters are:

- `server`: the name of the Oracle foreign server

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `oracle_migrate_prepare`.

- `only_schemas` (default NULL): An array of Oracle schema names
  that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
  system schemas are processed.
  The names must be as they appear in Oracle, which is usually in upper case.

### tables `oracle_test_table` and `test_error_stats` ###

These tables contain individual and summary results for runs of
`oracle_migrate_test_data`.

Support
=======

Create an [issue on Github][issue] or contact [Cybertec][cybertec].


 [issue]: https://github.com/cybertec-postgresql/ora_migrator/issues
 [cybertec]: https://www.cybertec-postgresql.com
