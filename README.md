Oracle to PostgreSQL migration tools
====================================

ora_migrator is a PostgreSQL extension that uses
[oracle_fdw](http://laurenz.github.io/oracle_fdw/)
to create foreign tables that allow you to extract object metadata
from an Oracle database.

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
  - `ALL_PROCEDURES`
  - `ALL_SOURCE`
  - `ALL_TAB_COLUMNS`
  - `ALL_TABLES`
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

- Function `create_oraviews`.

  This function takes the following arguments:

  - `server`: the name of the Oracle foreign server for which the
    foreign tables will be created.  
    You must have the `USAGE` privilege on that server.

  - `schema` (default `public`): the name of the schema where the
    foreign tables and views will be created.  
    The schema must exist, and you must have the `CREATE` privilege
    on it.

  - `max_viewdef` (default 32767): the maximal length of a view definition
    in Oracle.

  Calling the function will create the following foreign tables and views:

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
for oracle_fdw,so the queries should be efficient.

ALl Oracle object names will appear like they are in Oracle, which is
usually in upper case.
