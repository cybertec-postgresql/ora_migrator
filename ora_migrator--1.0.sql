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
         'SELECT owner,\n'
         '       table_name\n'
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
      '   position    integer      NOT NULL,\n'
      '   type_name   varchar(128) NOT NULL,\n'
      '   type_schema varchar(128) NOT NULL,\n'
      '   length      integer      NOT NULL,\n'
      '   precision   integer,\n'
      '   scale       integer,\n'
      '   nullable    boolean      NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       column_name,\n'
         '       column_id,\n'
         '       data_type,\n'
         '       data_type_owner,\n'
         '       char_length,\n'
         '       data_precision,\n'
         '       data_scale,\n'
         '       CASE WHEN nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable\n'
         'FROM all_tab_columns'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_checks_sql text := E'CREATE FOREIGN TABLE %I.ora_checks (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   condition       text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       constraint_name,\n'
         '       CASE WHEN deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       search_condition\n'
         'FROM all_constraints\n'
         'WHERE constraint_type = ''''C''''\n'
         '  AND status          = ''''ENABLED''''\n'
         '  AND validated       = ''''VALIDATED''''\n'
         '  AND invalid         IS NULL'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_foreign_keys_sql text := E'CREATE FOREIGN TABLE %I.ora_foreign_keys (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   column_name     varchar(128) NOT NULL,\n'
      '   position        integer      NOT NULL,\n'
      '   remote_schema   varchar(128) NOT NULL,\n'
      '   remote_table    varchar(128) NOT NULL,\n'
      '   remote_column   varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT con.owner,\n'
         '       con.table_name,\n'
         '       con.constraint_name,\n'
         '       CASE WHEN deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       col.column_name,\n'
         '       col.position,\n'
         '       r_col.owner AS remote_schema,\n'
         '       r_col.table_name AS remote_table,\n'
         '       r_col.column_name AS remote_column\n'
         'FROM all_constraints con\n'
         '   JOIN all_cons_columns col\n'
         '      ON (con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name)\n'
         '   JOIN all_cons_columns r_col\n'
         '      ON (con.r_owner = r_col.owner AND con.r_constraint_name = r_col.constraint_name)\n'
         'WHERE con.constraint_type = ''''R'''''
      ')'', max_long ''%s'', readonly ''true'')';

   ora_keys_sql text := E'CREATE FOREIGN TABLE %I.ora_keys (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   column_name     varchar(128) NOT NULL,\n'
      '   position        integer      NOT NULL,\n'
      '   is_primary      boolean      NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT con.owner,\n'
         '       con.table_name,\n'
         '       con.constraint_name,\n'
         '       CASE WHEN deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       col.column_name,\n'
         '       col.position,\n'
         '       CASE WHEN con.constraint_type = ''''P'''' THEN 1 ELSE 0 END is_primary\n'
         'FROM all_constraints con\n'
         '   JOIN all_cons_columns col\n'
         '      ON (con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name)\n'
         'WHERE con.constraint_type IN (''''P'''', ''''U'''')\n'
      ')'', max_long ''%s'', readonly ''true'')';

BEGIN
   /* ora_tables */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_tables', schema);
   EXECUTE format(ora_tables_sql, schema, server, max_viewdef);
   /* ora_columns */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_columns', schema);
   EXECUTE format(ora_columns_sql, schema, server, max_viewdef);
   /* ora_checks */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_checks', schema);
   EXECUTE format(ora_checks_sql, schema, server, max_viewdef);
   /* ora_foreign_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_foreign_keys', schema);
   EXECUTE format(ora_foreign_keys_sql, schema, server, max_viewdef);
   /* ora_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_keys', schema);
   EXECUTE format(ora_keys_sql, schema, server, max_viewdef);
END;$$;
