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
      '   schema varchar(128) NOT NULL,\n'
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
      '   schema varchar(128) NOT NULL,\n'
      '   table_name varchar(128) NOT NULL,\n'
      '   column_name varchar(128) NOT NULL,\n'
      '   column_id integer NOT NULL,\n'
      '   type_name varchar(128) NOT NULL,\n'
      '   type_schema varchar(128) NOT NULL,\n'
      '   length integer NOT NULL,\n'
      '   precision integer,\n'
      '   scale integer,\n'
      '   nullable boolean NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT col.owner, col.table_name, col.column_name,\n'
         '       col.column_id, col.data_type, col.data_type_owner,\n'
         '       col.char_length, col.data_precision, col.data_scale,\n'
         '       CASE WHEN col.nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable\n'
         'FROM all_tab_columns col'
      ')'', max_long ''%s'', readonly ''true'')';
BEGIN
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_tables', schema);
   EXECUTE format(ora_tables_sql, schema, server, max_viewdef);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_columns', schema);
   EXECUTE format(ora_columns_sql, schema, server, max_viewdef);
END;$$;
