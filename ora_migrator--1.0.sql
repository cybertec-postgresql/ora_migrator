/* tools for Oracle to PostgreSQL migration */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION ora_migrator" to load this file. \quit

CREATE FUNCTION create_oraviews (
   server      name,
   schema      name    DEFAULT NAME 'public',
   max_long integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE STRICT AS
$$DECLARE
   ora_sys_schemas text :=
      E'''''ANONYMOUS'''', ''''APEX_PUBLIC_USER'''', ''''APEX_030200'''', ''''APPQOSSYS'''',\n'
      '         ''''AURORA$JIS$UTILITY$'''', ''''AURORA$ORB$UNAUTHENTICATED'''', ''''BI'''',\n'
      '         ''''CTXSYS'''', ''''DBSNMP'''', ''''DIP'''', ''''DMSYS'''', ''''EXFSYS'''',\n'
      '         ''''HR'''', ''''IX'''', ''''LBACSYS'''', ''''MDDATA'''', ''''MDSYS'''', ''''MGMT_VIEW'''',\n'
      '         ''''ODM'''', ''''ODM_MTR'''', ''''OE'''', ''''OLAPSYS'''', ''''ORACLE_OCM'''', ''''ORDDATA'''',\n'
      '         ''''ORDPLUGINS'''', ''''ORDSYS'''', ''''OSE$HTTP$ADMIN'''', ''''OUTLN'''', ''''PM'''',\n'
      '         ''''SCOTT'''', ''''SH'''', ''''SI_INFORMTN_SCHEMA'''', ''''SPATIAL_CSW_ADMIN_USR'''',\n'
      '         ''''SPATIAL_WFS_ADMIN_USR'''', ''''SYS'''', ''''SYSMAN'''', ''''SYSTEM'''', ''''TRACESRV'''',\n'
      '         ''''MTSSYS'''', ''''OASPUBLIC'''', ''''OLAPSYS'''', ''''OWBSYS'''', ''''OWBSYS_AUDIT'''',\n'
      '         ''''WEBSYS'''', ''''WK_PROXY'''', ''''WKSYS'''', ''''WK_TEST'''', ''''WMSYS'''', ''''XDB''''';

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
         '  AND dropped   = ''''NO''''\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM all_mviews)\n'
         '  AND owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_columns_sql text := E'CREATE FOREIGN TABLE %I.ora_columns (\n'
      '   schema        varchar(128) NOT NULL,\n'
      '   table_name    varchar(128) NOT NULL,\n'
      '   column_name   varchar(128) NOT NULL,\n'
      '   position      integer      NOT NULL,\n'
      '   type_name     varchar(128) NOT NULL,\n'
      '   type_schema   varchar(128) NOT NULL,\n'
      '   length        integer      NOT NULL,\n'
      '   precision     integer,\n'
      '   scale         integer,\n'
      '   nullable      boolean      NOT NULL,\n'
      '   default_value text\n'
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
         '       CASE WHEN nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable,\n'
         '       data_default\n'
         'FROM all_tab_columns\n'
         'WHERE owner NOT IN (' || ora_sys_schemas || E')'
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
         '  AND invalid         IS NULL\n'
         '  AND owner NOT IN (' || ora_sys_schemas || E')'
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
         'WHERE con.constraint_type = ''''R''''\n'
         '  AND con.owner NOT IN (' || ora_sys_schemas || E')'
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
         '  AND con.owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_views_sql text := E'CREATE FOREIGN TABLE %I.ora_views (\n'
      '   schema     varchar(128) NOT NULL,\n'
      '   view_name  varchar(128) NOT NULL,\n'
      '   definition text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       view_name,\n'
         '       text\n'
         'FROM all_views\n'
         'WHERE owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_func_src_sql text := E'CREATE FOREIGN TABLE %I.ora_func_src (\n'
      '   schema        varchar(128) NOT NULL,\n'
      '   function_name varchar(128) NOT NULL,\n'
      '   is_procedure  boolean      NOT NULL,\n'
      '   line_number   integer      NOT NULL,\n'
      '   line          text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT pro.owner,\n'
         '       pro.object_name,\n'
         '       CASE WHEN pro.object_type = ''''PROCEDURE'''' THEN 1 ELSE 0 END is_procedure,\n'
         '       src.line,\n'
         '       src.text\n'
         'FROM all_procedures pro\n'
         '   JOIN all_source src\n'
         '      ON pro.owner = src.owner\n'
         '         AND pro.object_name = src.name\n'
         '         AND pro.object_type = src.type\n'
         'WHERE pro.object_type IN (''''FUNCTION'''', ''''PROCEDURE'''')\n'
         '  AND pro.owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_functions_sql text := E'CREATE VIEW %I.ora_functions AS\n'
      'SELECT schema,\n'
      '       function_name,\n'
      '       is_procedure,\n'
      '       string_agg(line, TEXT '''' ORDER BY line_number) AS source\n'
      'FROM %I.ora_func_src\n'
      'GROUP BY schema, function_name, is_procedure';

   ora_sequences_sql text := E'CREATE FOREIGN TABLE %I.ora_sequences (\n'
      '   schema        varchar(128) NOT NULL,\n'
      '   sequence_name varchar(128) NOT NULL,\n'
      '   min_value     numeric(28),\n'
      '   max_value     numeric(28),\n'
      '   increment_by  numeric(28)  NOT NULL,\n'
      '   cyclical      boolean      NOT NULL,\n'
      '   cache_size    integer      NOT NULL,\n'
      '   last_value    numeric(28)  NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT sequence_owner,\n'
         '       sequence_name,\n'
         '       min_value,\n'
         '       max_value,\n'
         '       increment_by,\n'
         '       CASE WHEN cycle_flag = ''''Y'''' THEN 1 ELSE 0 END cyclical,\n'
         '       cache_size,\n'
         '       last_number\n'
         'FROM all_sequences\n'
         'WHERE sequence_owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_index_exp_sql text := E'CREATE FOREIGN TABLE %I.ora_index_exp (\n'
      '   schema         varchar(128) NOT NULL,\n'
      '   table_name     varchar(128) NOT NULL,\n'
      '   index_name     varchar(128) NOT NULL,\n'
      '   uniqueness     boolean      NOT NULL,\n'
      '   position       integer      NOT NULL,\n'
      '   descend        boolean      NOT NULL,\n'
      '   col_name       text         NOT NULL,\n'
      '   col_expression text\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT ic.table_owner,\n'
         '       ic.table_name,\n'
         '       ic.index_name,\n'
         '       CASE WHEN i.uniqueness = ''''UNIQUE'''' THEN 1 ELSE 0 END uniqueness,\n'
         '       ic.column_position,\n'
         '       CASE WHEN ic.descend = ''''DESC'''' THEN 1 ELSE 0 END descend,\n'
         '       ic.column_name,\n'
         '       ie.column_expression\n'
         'FROM all_indexes i,\n'
         '     all_ind_columns ic,\n'
         '     all_ind_expressions ie\n'
         'WHERE i.owner            = ic.index_owner\n'
         '  AND i.index_name       = ic.index_name\n'
         '  AND i.table_owner      = ic.table_owner\n'
         '  AND i.table_name       = ic.table_name\n'
         '  AND ic.index_owner     = ie.index_owner(+)\n'
         '  AND ic.index_name      = ie.index_name(+)\n'
         '  AND ic.table_owner     = ie.table_owner(+)\n'
         '  AND ic.table_name      = ie.table_name(+)\n'
         '  AND ic.column_position = ie.column_position(+)\n'
         '  AND i.index_type NOT IN (''''LOB'''', ''''DOMAIN'''')\n'
         '  AND NOT EXISTS (SELECT 1\n'
         '                  FROM all_constraints c\n'
         '                  WHERE c.owner = i.table_owner\n'
         '                    AND c.table_name = i.table_name\n'
         '                    AND COALESCE(c.index_owner, i.owner) = i.owner\n'
         '                    AND c.index_name = i.index_name)\n'
         '  AND ic.table_owner NOT IN (' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_index_columns_sql text := E'CREATE VIEW %I.ora_index_columns AS\n'
      'SELECT schema,\n'
      '       table_name,\n'
      '       index_name,\n'
      '       uniqueness,\n'
      '       position,\n'
      '       descend,\n'
      '       coalesce(col_expression, col_name) AS column_name\n'
      'FROM %I.ora_index_exp\n';

   ora_schemas_sql text := E'CREATE FOREIGN TABLE %I.ora_schemas (\n'
      '   schema varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT username\n'
         'FROM all_users\n'
         'WHERE username NOT IN( ' || ora_sys_schemas || E')\n'
      ')'', max_long ''%s'', readonly ''true'')';

BEGIN
   /* ora_tables */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_tables', schema);
   EXECUTE format(ora_tables_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_tables IS ''Oracle tables on foreign server "%I"''', schema, server);
   /* ora_columns */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_columns', schema);
   EXECUTE format(ora_columns_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_columns IS ''columns of Oracle tables and views on foreign server "%I"''', schema, server);
   /* ora_checks */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_checks', schema);
   EXECUTE format(ora_checks_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_checks IS ''Oracle check constraints on foreign server "%I"''', schema, server);
   /* ora_foreign_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_foreign_keys', schema);
   EXECUTE format(ora_foreign_keys_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_foreign_keys IS ''Oracle foreign key columns on foreign server "%I"''', schema, server);
   /* ora_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_keys', schema);
   EXECUTE format(ora_keys_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_keys IS ''Oracle primary and unique key columns on foreign server "%I"''', schema, server);
   /* ora_views */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_views', schema);
   EXECUTE format(ora_views_sql, schema, server, max_long);
   /* ora_func_src and ora_functions */
   EXECUTE format('DROP VIEW IF EXISTS %I.ora_functions', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_func_src', schema);
   EXECUTE format(ora_func_src_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_func_src IS ''source lines for Oracle functions and procedures on foreign server "%I"''', schema, server);
   EXECUTE format(ora_functions_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.ora_functions IS ''Oracle functions and procedures on foreign server "%I"''', schema, server);
   /* ora_sequences */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_sequences', schema);
   EXECUTE format(ora_sequences_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_sequences IS ''Oracle sequences on foreign server "%I"''', schema, server);
   /* ora_index_exp and ora_index_columns */
   EXECUTE format('DROP VIEW IF EXISTS %I.ora_index_columns', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_index_exp', schema);
   EXECUTE format(ora_index_exp_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_index_exp IS ''Oracle index columns on foreign server "%I"''', schema, server);
   EXECUTE format(ora_index_columns_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.ora_index_columns IS ''Oracle index columns on foreign server "%I"''', schema, server);
   /* ora_schemas */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_schemas', schema);
   EXECUTE format(ora_schemas_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_schemas IS ''Oracle schemas on foreign server "%I"''', schema, server);
END;$$;

COMMENT ON FUNCTION create_oraviews(name, name, integer) IS 'create Oracle foreign tables for the metadata of a foreign server';

CREATE FUNCTION migrate_oracle(
   server      name,
   schemas     name[]  DEFAULT NULL,
   max_long    integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE STRICT AS
$$BEGIN
END;$$;

COMMENT ON FUNCTION migrate_oracle(name, name[], integer) IS 'migrate an Oracle database from a foreign server to PostgreSQL';
