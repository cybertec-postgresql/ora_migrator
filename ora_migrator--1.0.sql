/* tools for Oracle to PostgreSQL migration */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION ora_migrator" to load this file. \quit

CREATE FUNCTION create_oraviews (
   server name,
   schema name DEFAULT NAME 'public',
   max_viewdef integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE STRICT AS
$$DECLARE
   ora_tables_sql text := E'CREATE FOREIGN TABLE %I.ora_tables (\n'
      '   schema     varchar(128) NOT NULL,\n'
      '   table_name varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner, table_name\n'
         'FROM all_tables\n'
         'WHERE temporary = ''''N''''\n'
         '  AND secondary = ''''N''''\n'
         '  AND nested    = ''''NO''''\n'
         '  AND dropped   = ''''NO'''''
      ')'', max_long ''%s'', readonly ''true'')';

   ora_columns_sql text := E'CREATE FOREIGN TABLE %I.ora_columns (\n'
      '   schema      varchar(128) NOT NULL,\n'
      '   table_name  varchar(128) NOT NULL,\n'
      '   column_name varchar(128) NOT NULL,\n'
      '   column_id   integer      NOT NULL,\n'
      '   type_name   varchar(128) NOT NULL,\n'
      '   type_schema varchar(128) NOT NULL,\n'
      '   length      integer      NOT NULL,\n'
      '   precision   integer,\n'
      '   scale       integer,\n'
      '   nullable    boolean      NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,       table_name,     column_name,\n'
         '       column_id,   data_type,      data_type_owner,\n'
         '       char_length, data_precision, data_scale,\n'
         '       CASE WHEN nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable\n'
         'FROM all_tab_columns'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_check_constraints_sql text := E'CREATE FOREIGN TABLE %I.ora_check_constraints (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   condition       text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner, table_name, constraint_name,\n'
         '       CASE WHEN deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       search_condition\n'
         'FROM all_constraints\n'
         'WHERE constraint_type = ''''C''''\n'
         '  AND status          = ''''ENABLED''''\n'
         '  AND validated       = ''''VALIDATED''''\n'
         '  AND invalid         IS NULL'
      ')'', max_long ''%s'', readonly ''true'')';
BEGIN
   /* ora_tables */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_tables', schema);
   EXECUTE format(ora_tables_sql, schema, server, max_viewdef);
   /* ora_columns */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_columns', schema);
   EXECUTE format(ora_columns_sql, schema, server, max_viewdef);
   /* ora_check_constraints */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_check_constraints', schema);
   EXECUTE format(ora_check_constraints_sql, schema, server, max_viewdef);
END;$$;
