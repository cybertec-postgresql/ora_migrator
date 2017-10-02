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
   ora_table_cols_sql text := E'CREATE FOREIGN TABLE %I.ora_table_cols (\n'
      '  schema varchar(128) NOT NULL,\n'
      '  table_name varchar(128) NOT NULL,\n'
      '  column_name varchar(128) NOT NULL,\n'
      '  column_id integer NOT NULL,\n'
      '  type_name varchar(128) NOT NULL,\n'
      '  type_schema varchar(128) NOT NULL,\n'
      '  length integer,\n'
      '  precision integer,\n'
      '  scale integer,\n'
      '  nullable boolean NOT NULL,\n'
      '  primary_key boolean NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT col.owner, col.table_name, col.column_name, col.column_id, col.data_type, col.data_type_owner,\n'
         '       col.char_length, col.data_precision, col.data_scale,\n'
         '       CASE WHEN col.nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable,\n'
         '       CASE WHEN primkey_col.position IS NOT NULL THEN 1 ELSE 0 END AS primary_key\n'
         'FROM all_tab_columns col,\n'
         '     (SELECT con.table_name, cons_col.column_name, cons_col.position\n'
         '      FROM all_constraints con, all_cons_columns cons_col\n'
         '      WHERE con.owner = cons_col.owner AND con.table_name = cons_col.table_name\n'
         '        AND con.constraint_name = cons_col.constraint_name\n'
         '        AND con.constraint_type = ''''P'''') primkey_col\n'
         'WHERE col.table_name = primkey_col.table_name(+) AND col.column_name = primkey_col.column_name(+)'
      ')'', max_long ''%s'', readonly ''true'')';
BEGIN
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_table_cols', schema);
   EXECUTE format(ora_table_cols_sql, schema, server, max_viewdef);
END;$$;
