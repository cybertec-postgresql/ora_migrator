Oracle to PostgreSQL migration tools
====================================

`ora_migrator` is a plugin for [`db_migrator`][migrator] that uses
[`oracle_fdw`][fdw] to migrate an Oracle database to PostgreSQL.

Please read the `db_migrator` documentation for usage instructions;
this README only covers the installation and setup of the plugin
as well as additional features that are not covered in the general
documentation.

In addition to that, `ora_migrator` offers a replication functionality
from Oracle to PostgreSQL which can be used for almost zero down time
migration from Oracle.  See [Replication](#replication) for details.

Note that since schema names are usually in upper case in Oracle,
you will need to use upper case schema names for the `only_schemas`
parameter of the `db_migrator` functions.


 [migrator]: https://github.com/cybertec-postgresql/db_migrator
 [fdw]: http://laurenz.github.io/oracle_fdw/

Options
=======

The following option can be used for `db_migrate_prepare`,
`db_migrate_mkforeign` and `db_migrate`:

- `max_long` (integer, default value 32767): will be used to set the
  `max_long` option on the foreign tables.  This determines the maximal
  length of LONG, LONG RAW and XMLTYPE columns.

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

- To use replication, the user must have the `CREATE TABLE` and
  `CREATE TRIGGER` privileges.

  To use replication for tables not owned by the Oracle user, the user must
  have the `CREATE ANY TABLE`, `CREATE ANY INDEX`, `CREATE ANY TRIGGER`,
  `DROP ANY TABLE`, `DROP ANY TRIGGER` and `SELECT ANY TABLE` privilege (this
  is required to create and drop logging tables and triggers).

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

- `staging_schema` (default `fdw_stage`): name of the remote staging schema

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `oracle_migrate_prepare`.

- `only_schemas` (default NULL): An array of Oracle schema names
  that should be migrated to PostgreSQL. If NULL, all schemas except Oracle
  system schemas are processed.
  The names must be as they appear in Oracle, which is usually in upper case.

### tables `oracle_test_table` and `test_error_stats` ###

These tables contain individual and summary results for runs of
`oracle_migrate_test_data`.

Replication functions
---------------------

### function `oracle_replication_start` ###

This function creates all the objects necessary for replication in the
Oracle and PostgreSQL databases.  PostgreSQL objects will be created in the
Postgres staging schema, Oracle objects in the same schema as the replicated
table.

This function should be called right before `db_migrate_tables`, and no
data modification activity should occur on Oracle between the time when you
start `oracle_replication_start` and the time you call `db_migrate_tables`.

The function parameters are:

- `server`: the name of the Oracle foreign server

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `oracle_migrate_prepare`

The objects created by the function are:

- a PostgreSQL foreign table `__ReplicationEnd` that shows a timestamp
  guaranteed to be earlier than the oldest active transaction on Oracle

- a PostgreSQL table `__ReplicationStart` used to store the starting point for
  the next replication catch-up

For each table in the `tables` table of the Postgres stage that has `migrate`
set to `TRUE`, the following objects are created:

- an Oracle table `__Log_<tablename>` to collect changes to `<tablename>`

- an Oracle trigger `__Log_<tablename>_TRIG` on `<tablename>`

- a PostgreSQL foreign table `__Log_<schema>/<tablename>` for the Oracle change
  log table

### function `oracle_catchup_table` ###

Copies data that have changed during a certain time interval from an Oracle
table to PostgreSQL.

This requires that `oracle_replication_start` has created the required objects
and that the data migration has finished.

Parameters:

- `schema`: the schema of the migrated table

- `table_name`: the name of the migrated table

- `from_ts`: replicate changes later than that timestamp

- `to_ts`: replicate changes up to and including that timestamp

This is a "low level" function called by `oracle_replication_catchup`; it can
be used if you want to parallelize catch-up by running it concurrently
for different tables.

### function `oracle_catchup_sequence` ###

Parameters:

- `schema`: the schema of the migrated sequence

- `sequence_name`: the name of the migrated sequence

- `staging_schema` (default `fdw_stage`): name of the remote staging schema

Queries the current value of the Oracle sequence on the remote side and sets
the migrated sequence to that value.

### function `oracle_replication_catchup` ###

Copies all changes in all Oracle tables and sequences since the last catch-up
to PostgreSQL.

The start timestamp is taken from `__ReplicationStart`, the end from
`__ReplicationEnd` (which contains the latest safe timestamp).
After successful completion, the replicaton end time is saved in
`__ReplicationStart` for the next time.

Parameters:

- `staging_schema` (default `fdw_stage`): name of the remote staging schema

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `oracle_migrate_prepare`

You can call this function anytime after `oracle_replication_start` has
completed.

Unless you have no triggers or foreign key constraints in your database,
you should set the configuration parameter `session_replication_role` to
`replica` when calling this function.  Then triggers don't fire, and
foreign key constraints are not checked.

`oracle_replication_catchup` uses the `SERIALIZABLE` isolation level on
Oracle, so it sees a fixed snapshot of the Oracle database, and the data
will be consistent on the PostgreSQL side, even if the Oracle database is
modified concurrently.

If you want to use replication for near-zero down time migration, call
it twice in short succession and make sure that there is no data modification
activity on Oracle during the second call.  Once the second catch-up has
completed, you can switch the application over to PostgreSQL immediately.

### function `oracle_replication_finish` ###

Removes all objects created by `oracle_replication_start` in PostgreSQL
and Oracle.

This is used to clean up after you have finished migrating from Oracle.

- `server`: the name of the Oracle foreign server

- `pgstage_schema` (default `pgsql_stage`): The name of the PostgreSQL stage
  created by `oracle_migrate_prepare`

Replication
===========

`ora_migrator` offers a simple trigger-based replication functionality
from Oracle to PostgreSQL.

This can be used to migrate databases from Oracle to PostgreSQL with
almost no down time.

The procedure is as follows:

- Prepare migration as described in the `db_migrator` documentation
  by calling `db_migrate_prepare` and `db_migrate_mkforeign`.

- Suspend all data modification activity on the Oracle database.
  This is necessary because Oracle does not support transactional DDL.

- Then call `oracle_replication_start` to set up all the required
  objects.  This will create log tables and triggers in the Oracle
  database.

- Then start the data migration as usual with `db_migrate_tables`.

  As soon as `db_migrate_tables` has started, data modification
  activity on the Oracle database can resume.  The migration will run
  using the `SERIALIZABLE` transaction isolation level, so the
  migrated data will be consistent.

  Make sure that you have enough UNDO space on Oracle, else the data
  migration may fail.

- Migrate constraints and indexes with `db_migrate_constraints` and
  other objects as described in the `db_migrator` documentation.

- At any time, you can call `oracle_replication_catchup` to transfer
  changed data from Oracle to PostgreSQL.

  This calls `oracle_catchup_table` for all affected tables, so to
  parallelize operation, you can call that latter function directly
  for all affected tables.

  Note that catching up will *not* purge the log tables on Oracle.

  To avoid problems with foreign key constraints in PostgreSQL, make
  sure that the configuration parameter `session_replication_role`
  is set to `replica` while you are running `oracle_catchup_table`.

  For near-zero down time migration, the last call to
  `oracle_replication_catchup` must also be performed while there
  is no data modification activity on the Oracle database.
  After that call, switch the application over to PostgreSQL.

- To end replication, call `oracle_replication_finish`.
  That will delete all the objects created for replication.

- Finally, call `db_migrate_finish` to drop all auxiliary objects.

Support
=======

Create an [issue on Github][issue] or contact [Cybertec][cybertec].


 [issue]: https://github.com/cybertec-postgresql/ora_migrator/issues
 [cybertec]: https://www.cybertec-postgresql.com
