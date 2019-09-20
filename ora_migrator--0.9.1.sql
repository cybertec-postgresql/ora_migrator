/* tools for Oracle to PostgreSQL migration */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION ora_migrator" to load this file. \quit

CREATE FUNCTION create_oraviews (
   server      name,
   schema      name    DEFAULT NAME 'public',
   max_long integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE STRICT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;

   sys_schemas text :=
      E'''''ANONYMOUS'''', ''''APEX_PUBLIC_USER'''', ''''APEX_030200'''', ''''APEX_040000'''', ''''APPQOSSYS'''',\n'
      '         ''''AUDSYS'''', ''''AURORA$JIS$UTILITY$'''', ''''AURORA$ORB$UNAUTHENTICATED'''',\n'
      '         ''''CTXSYS'''', ''''DBSNMP'''', ''''DIP'''', ''''DMSYS'''', ''''DVSYS'''', ''''EXFSYS'''', ''''FLOWS_30000'''', ''''FLOWS_FILES'''',\n'
      '         ''''GSMADMIN_INTERNAL'''', ''''LBACSYS'''', ''''MDDATA'''', ''''MDSYS'''', ''''MGMT_VIEW'''',\n'
      '         ''''ODM'''', ''''ODM_MTR'''', ''''OJVMSYS'''', ''''OLAPSYS'''', ''''ORACLE_OCM'''', ''''ORDDATA'''',\n'
      '         ''''ORDPLUGINS'''', ''''ORDSYS'''', ''''OSE$HTTP$ADMIN'''', ''''OUTLN'''',\n'
      '         ''''SI_INFORMTN_SCHEMA'''', ''''SPATIAL_WFS_ADMIN_USR'''', ''''SPATIAL_CSW_ADMIN_USR'''',\n'
      '         ''''SPATIAL_WFS_ADMIN_USR'''', ''''SYS'''', ''''SYSMAN'''', ''''SYSTEM'''', ''''TRACESRV'''',\n'
      '         ''''MTSSYS'''', ''''OASPUBLIC'''', ''''OLAPSYS'''', ''''OWBSYS'''', ''''OWBSYS_AUDIT'''', ''''PERFSTAT'''',\n'
      '         ''''WEBSYS'''', ''''WK_PROXY'''', ''''WKSYS'''', ''''WK_TEST'''', ''''WMSYS'''', ''''XDB'''', ''''XS$NULL''''';

   tables_sql text := E'CREATE FOREIGN TABLE %I.tables (\n'
      '   schema     varchar(128) NOT NULL,\n'
      '   table_name varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name\n'
         'FROM dba_tables\n'
         'WHERE temporary = ''''N''''\n'
         '  AND secondary = ''''N''''\n'
         '  AND nested    = ''''NO''''\n'
         '  AND dropped   = ''''NO''''\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT log_owner, log_table\n'
         '             FROM dba_mview_logs)\n'
         '  AND owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   columns_sql text := E'CREATE FOREIGN TABLE %I.columns (\n'
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
         'SELECT col.owner,\n'
         '       col.table_name,\n'
         '       col.column_name,\n'
         '       col.column_id,\n'
         '       col.data_type,\n'
         '       col.data_type_owner,\n'
         '       col.char_length,\n'
         '       col.data_precision,\n'
         '       col.data_scale,\n'
         '       CASE WHEN col.nullable = ''''Y'''' THEN 1 ELSE 0 END AS nullable,\n'
         '       col.data_default\n'
         'FROM dba_tab_columns col\n'
         '   JOIN (SELECT owner, table_name\n'
         '            FROM dba_tables\n'
         '            WHERE owner NOT IN (' || sys_schemas || E')\n'
         '              AND temporary = ''''N''''\n'
         '              AND secondary = ''''N''''\n'
         '              AND nested    = ''''NO''''\n'
         '              AND dropped   = ''''NO''''\n'
         '         UNION SELECT owner, view_name\n'
         '            FROM dba_views\n'
         '            WHERE owner NOT IN (' || sys_schemas || E')\n'
         '        ) tab\n'
         '      ON tab.owner = col.owner AND tab.table_name = col.table_name\n'
         'WHERE (col.owner, col.table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND (col.owner, col.table_name)\n'
         '     NOT IN (SELECT log_owner, log_table\n'
         '             FROM dba_mview_logs)\n'
         '  AND col.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   checks_sql text := E'CREATE FOREIGN TABLE %I.checks (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   condition       text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT con.owner,\n'
         '       con.table_name,\n'
         '       con.constraint_name,\n'
         '       CASE WHEN con.deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN con.deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       con.search_condition\n'
         'FROM dba_constraints con\n'
         '   JOIN dba_tables tab\n'
         '      ON tab.owner = con.owner AND tab.table_name = con.table_name\n'
         'WHERE tab.temporary = ''''N''''\n'
         '  AND tab.secondary = ''''N''''\n'
         '  AND tab.nested    = ''''NO''''\n'
         '  AND tab.dropped   = ''''NO''''\n'
         '  AND con.constraint_type = ''''C''''\n'
         '  AND con.status          = ''''ENABLED''''\n'
         '  AND con.validated       = ''''VALIDATED''''\n'
         '  AND con.invalid         IS NULL\n'
         '  AND con.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   foreign_keys_sql text := E'CREATE FOREIGN TABLE %I.foreign_keys (\n'
      '   schema          varchar(128) NOT NULL,\n'
      '   table_name      varchar(128) NOT NULL,\n'
      '   constraint_name varchar(128) NOT NULL,\n'
      '   "deferrable"    boolean      NOT NULL,\n'
      '   deferred        boolean      NOT NULL,\n'
      '   delete_rule     text         NOT NULL,\n'
      '   column_name     varchar(128) NOT NULL,\n'
      '   position        integer      NOT NULL,\n'
      '   remote_schema   varchar(128) NOT NULL,\n'
      '   remote_table    varchar(128) NOT NULL,\n'
      '   remote_column   varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT con.owner,\n'
         '       con.table_name,\n'
         '       con.constraint_name,\n'
         '       CASE WHEN con.deferrable = ''''DEFERRABLE'''' THEN 1 ELSE 0 END deferrable,\n'
         '       CASE WHEN con.deferred   = ''''DEFERRED''''   THEN 1 ELSE 0 END deferred,\n'
         '       con.delete_rule,\n'
         '       col.column_name,\n'
         '       col.position,\n'
         '       r_col.owner AS remote_schema,\n'
         '       r_col.table_name AS remote_table,\n'
         '       r_col.column_name AS remote_column\n'
         'FROM dba_constraints con\n'
         '   JOIN dba_cons_columns col\n'
         '      ON con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name\n'
         '   JOIN dba_cons_columns r_col\n'
         '      ON con.r_owner = r_col.owner AND con.r_constraint_name = r_col.constraint_name AND col.position = r_col.position\n'
         'WHERE con.constraint_type = ''''R''''\n'
         '  AND con.status          = ''''ENABLED''''\n'
         '  AND con.validated       = ''''VALIDATED''''\n'
         '  AND con.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   keys_sql text := E'CREATE FOREIGN TABLE %I.keys (\n'
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
         'FROM dba_tables tab\n'
         '   JOIN dba_constraints con\n'
         '      ON tab.owner = con.owner AND tab.table_name = con.table_name\n'
         '   JOIN dba_cons_columns col\n'
         '      ON con.owner = col.owner AND con.table_name = col.table_name AND con.constraint_name = col.constraint_name\n'
         'WHERE (con.owner, con.table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND con.constraint_type IN (''''P'''', ''''U'''')\n'
         '  AND con.status    = ''''ENABLED''''\n'
         '  AND con.validated = ''''VALIDATED''''\n'
         '  AND tab.temporary = ''''N''''\n'
         '  AND tab.secondary = ''''N''''\n'
         '  AND tab.nested    = ''''NO''''\n'
         '  AND tab.dropped   = ''''NO''''\n'
         '  AND con.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   views_sql text := E'CREATE FOREIGN TABLE %I.views (\n'
      '   schema     varchar(128) NOT NULL,\n'
      '   view_name  varchar(128) NOT NULL,\n'
      '   definition text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       view_name,\n'
         '       text\n'
         'FROM dba_views\n'
         'WHERE owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   func_src_sql text := E'CREATE FOREIGN TABLE %I.func_src (\n'
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
         'FROM dba_procedures pro\n'
         '   JOIN dba_source src\n'
         '      ON pro.owner = src.owner\n'
         '         AND pro.object_name = src.name\n'
         '         AND pro.object_type = src.type\n'
         'WHERE pro.object_type IN (''''FUNCTION'''', ''''PROCEDURE'''')\n'
         '  AND pro.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   functions_sql text := E'CREATE VIEW %I.functions AS\n'
      'SELECT schema,\n'
      '       function_name,\n'
      '       is_procedure,\n'
      '       string_agg(line, TEXT '''' ORDER BY line_number) AS source\n'
      'FROM %I.func_src\n'
      'GROUP BY schema, function_name, is_procedure';

   sequences_sql text := E'CREATE FOREIGN TABLE %I.sequences (\n'
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
         'FROM dba_sequences\n'
         'WHERE sequence_owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   index_exp_sql text := E'CREATE FOREIGN TABLE %I.index_exp (\n'
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
         'FROM dba_indexes i,\n'
         '     dba_ind_columns ic,\n'
         '     dba_ind_expressions ie\n'
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
         '                  FROM dba_constraints c\n'
         '                  WHERE c.owner = i.table_owner\n'
         '                    AND c.table_name = i.table_name\n'
         '                    AND COALESCE(c.index_owner, i.owner) = i.owner\n'
         '                    AND c.index_name = i.index_name)\n'
         '  AND ic.table_owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   index_columns_sql text := E'CREATE VIEW %I.index_columns AS\n'
      'SELECT schema,\n'
      '       table_name,\n'
      '       index_name,\n'
      '       uniqueness,\n'
      '       position,\n'
      '       descend,\n'
      '       col_expression IS NOT NULL\n'
      '          AND (NOT descend OR col_expression !~ ''^"[^"]*"$'') AS is_expression,\n'
      '       coalesce(\n'
      '          CASE WHEN descend AND col_expression ~ ''^"[^"]*"$''\n'
      '               THEN replace (col_expression, ''"'', '''')\n'
      '               ELSE col_expression\n'
      '          END,\n'
      '          col_name) AS column_name\n'
      'FROM %I.index_exp\n';

   schemas_sql text := E'CREATE FOREIGN TABLE %I.schemas (\n'
      '   schema varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT username\n'
         'FROM dba_users\n'
         'WHERE username NOT IN( ' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   trig_sql text := E'CREATE FOREIGN TABLE %I.trig (\n'
      '   schema            varchar(128) NOT NULL,\n'
      '   table_name        varchar(128) NOT NULL,\n'
      '   trigger_name      varchar(128) NOT NULL,\n'
      '   trigger_type      varchar(16)  NOT NULL,\n'
      '   triggering_event  varchar(227) NOT NULL,\n'
      '   when_clause       text,\n'
      '   referencing_names varchar(128) NOT NULL,\n'
      '   trigger_body      text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT table_owner,\n'
         '       table_name,\n'
         '       trigger_name,\n'
         '       trigger_type,\n'
         '       triggering_event,\n'
         '       when_clause,\n'
         '       referencing_names,\n'
         '       trigger_body\n'
         'FROM dba_triggers\n'
         'WHERE table_owner NOT IN( ' || sys_schemas || E')\n'
         '  AND base_object_type IN (''''TABLE'''', ''''VIEW'''')\n'
         '  AND status = ''''ENABLED''''\n'
         '  AND crossedition = ''''NO''''\n'
         '  AND trigger_type <> ''''COMPOUND'''''
      ')'', max_long ''%s'', readonly ''true'')';

   triggers_sql text := E'CREATE VIEW %I.triggers AS\n'
      'SELECT schema,\n'
      '       table_name,\n'
      '       trigger_name,\n'
      '       trigger_type LIKE ''BEFORE%%'' AS is_before,\n'
      '       triggering_event,\n'
      '       trigger_type LIKE ''%%EACH ROW'' AS for_each_row,\n'
      '       when_clause,\n'
      '       referencing_names,\n'
      '       trigger_body\n'
      'FROM %I.trig';

   pack_src_sql text := E'CREATE FOREIGN TABLE %I.pack_src (\n'
      '   schema       varchar(128) NOT NULL,\n'
      '   package_name varchar(128) NOT NULL,\n'
      '   src_type     varchar(12)  NOT NULL,\n'
      '   line_number  integer      NOT NULL,\n'
      '   line         text         NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT pro.owner,\n'
         '       pro.object_name,\n'
         '       src.type,\n'
         '       src.line,\n'
         '       src.text\n'
         'FROM dba_procedures pro\n'
         '   JOIN dba_source src\n'
         '      ON pro.owner = src.owner\n'
         '         AND pro.object_name = src.name\n'
         'WHERE pro.object_type = ''''PACKAGE''''\n'
         '  AND src.type IN (''''PACKAGE'''', ''''PACKAGE BODY'''')\n'
         '  AND procedure_name IS NULL\n'
         '  AND pro.owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   packages_sql text := E'CREATE VIEW %I.packages AS\n'
      'SELECT schema,\n'
      '       package_name,\n'
      '       src_type = ''PACKAGE BODY'' AS is_body,\n'
      '       string_agg(line, TEXT '''' ORDER BY line_number) AS source\n'
      'FROM %I.pack_src\n'
      'GROUP BY schema, package_name, src_type';

   table_privs_sql text := E'CREATE FOREIGN TABLE %I.table_privs (\n'
      '   schema     varchar(128) NOT NULL,\n'
      '   table_name varchar(128) NOT NULL,\n'
      '   privilege  varchar(40)  NOT NULL,\n'
      '   grantor    varchar(128) NOT NULL,\n'
      '   grantee    varchar(128) NOT NULL,\n'
      '   grantable  boolean      NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       privilege,\n'
         '       grantor,\n'
         '       grantee,\n'
         '       CASE WHEN grantable = ''''YES'''' THEN 1 ELSE 0 END grantable\n'
         'FROM dba_tab_privs\n'
         'WHERE owner NOT IN (' || sys_schemas || E')\n'
         '  AND grantor NOT IN (' || sys_schemas || E')\n'
         '  AND grantee NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   column_privs_sql text := E'CREATE FOREIGN TABLE %I.column_privs (\n'
      '   schema      varchar(128) NOT NULL,\n'
      '   table_name  varchar(128) NOT NULL,\n'
      '   column_name varchar(128) NOT NULL,\n'
      '   privilege   varchar(40)  NOT NULL,\n'
      '   grantor     varchar(128) NOT NULL,\n'
      '   grantee     varchar(128) NOT NULL,\n'
      '   grantable   boolean      NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       column_name,\n'
         '       privilege,\n'
         '       grantor,\n'
         '       grantee,\n'
         '       CASE WHEN grantable = ''''YES'''' THEN 1 ELSE 0 END grantable\n'
         'FROM dba_col_privs\n'
         'WHERE owner NOT IN (' || sys_schemas || E')\n'
         '  AND grantor NOT IN (' || sys_schemas || E')\n'
         '  AND grantee NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   segments_sql text := E'CREATE FOREIGN TABLE %I.segments (\n'
      '   schema       varchar(128) NOT NULL,\n'
      '   segment_name varchar(128) NOT NULL,\n'
      '   segment_type varchar(18)  NOT NULL,\n'
      '   bytes        bigint       NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       segment_name,\n'
         '       segment_type,\n'
         '       bytes\n'
         'FROM dba_segments\n'
         'WHERE owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* tables */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.tables', schema);
   EXECUTE format(tables_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.tables IS ''Oracle tables on foreign server "%I"''', schema, server);
   /* columns */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.columns', schema);
   EXECUTE format(columns_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.columns IS ''columns of Oracle tables and views on foreign server "%I"''', schema, server);
   /* checks */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.checks', schema);
   EXECUTE format(checks_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.checks IS ''Oracle check constraints on foreign server "%I"''', schema, server);
   /* foreign_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.foreign_keys', schema);
   EXECUTE format(foreign_keys_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.foreign_keys IS ''Oracle foreign key columns on foreign server "%I"''', schema, server);
   /* keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.keys', schema);
   EXECUTE format(keys_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.keys IS ''Oracle primary and unique key columns on foreign server "%I"''', schema, server);
   /* views */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.views', schema);
   EXECUTE format(views_sql, schema, server, max_long);
   /* func_src and functions */
   EXECUTE format('DROP VIEW IF EXISTS %I.functions', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.func_src', schema);
   EXECUTE format(func_src_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.func_src IS ''source lines for Oracle functions and procedures on foreign server "%I"''', schema, server);
   EXECUTE format(functions_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.functions IS ''Oracle functions and procedures on foreign server "%I"''', schema, server);
   /* sequences */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.sequences', schema);
   EXECUTE format(sequences_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.sequences IS ''Oracle sequences on foreign server "%I"''', schema, server);
   /* index_exp and index_columns */
   EXECUTE format('DROP VIEW IF EXISTS %I.index_columns', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.index_exp', schema);
   EXECUTE format(index_exp_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.index_exp IS ''Oracle index columns on foreign server "%I"''', schema, server);
   EXECUTE format(index_columns_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.index_columns IS ''Oracle index columns on foreign server "%I"''', schema, server);
   /* schemas */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.schemas', schema);
   EXECUTE format(schemas_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.schemas IS ''Oracle schemas on foreign server "%I"''', schema, server);
   /* trig and triggers */
   EXECUTE format('DROP VIEW IF EXISTS %I.triggers', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.trig', schema);
   EXECUTE format(trig_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.trig IS ''Oracle triggers on foreign server "%I"''', schema, server);
   EXECUTE format(triggers_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.triggers IS ''Oracle triggers on foreign server "%I"''', schema, server);
   /* pack_src and packages */
   EXECUTE format('DROP VIEW IF EXISTS %I.packages', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.pack_src', schema);
   EXECUTE format(pack_src_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.pack_src IS ''Oracle package source lines on foreign server "%I"''', schema, server);
   EXECUTE format(packages_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.packages IS ''Oracle packages on foreign server "%I"''', schema, server);
   /* table_privs */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.table_privs', schema);
   EXECUTE format(table_privs_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.table_privs IS ''Privileges on Oracle tables on foreign server "%I"''', schema, server);
   /* column_privs */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.column_privs', schema);
   EXECUTE format(column_privs_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.column_privs IS ''Privileges on Oracle table columns on foreign server "%I"''', schema, server);
   /* segments */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.segments', schema);
   EXECUTE format(segments_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.segments IS ''Size of Oracle objects on foreign server "%I"''', schema, server);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION create_oraviews(name, name, integer) IS
   'create Oracle foreign tables for the metadata of a foreign server';

/* this will silently truncate anything exceeding 63 bytes ...*/
CREATE FUNCTION oracle_tolower(text) RETURNS name
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
'SELECT CASE WHEN $1 = upper($1) THEN lower($1)::name ELSE $1::name END';

COMMENT ON FUNCTION oracle_tolower(text) IS
   'helper function to fold Oracle names to lower case';

CREATE FUNCTION translate_expression(s text) RETURNS text
   LANGUAGE plpgsql IMMUTABLE STRICT SET search_path FROM CURRENT AS
$$DECLARE
   r text;
BEGIN
   FOR r IN
      SELECT idents[1]
      FROM regexp_matches(s, '"([^"]*)"', 'g') AS idents
   LOOP
      s := replace(s, '"' || r || '"', '"' || oracle_tolower(r) || '"' );
   END LOOP;
   s := regexp_replace(s, '\msysdate\M', 'current_date', 'gi');
   s := regexp_replace(s, '\msystimestamp\M', 'current_timestamp', 'gi');

   RETURN s;
END;$$;

COMMENT ON FUNCTION translate_expression(text) IS
   'helper function to translate Oracle SQL expressions to PostgreSQL';

CREATE FUNCTION adjust_to_bigint(numeric) RETURNS bigint
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$SELECT CASE WHEN $1 < -9223372036854775808
              THEN BIGINT '-9223372036854775808'
              WHEN $1 > 9223372036854775807
              THEN BIGINT '9223372036854775807'
              ELSE $1::bigint
         END$$;

CREATE FUNCTION oracle_materialize(
   s name,
   t name,
   with_data boolean DEFAULT TRUE,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS boolean
   LANGUAGE plpgsql VOLATILE STRICT SET search_path = pg_catalog AS
$$DECLARE
   ft     name;
   errmsg text;
   detail text;
BEGIN
   BEGIN
      /* rename the foreign table */
      ft := t || E'\x07';
      EXECUTE format('ALTER FOREIGN TABLE %I.%I RENAME TO %I', s, t, ft);

      /* create a table */
      EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I)', s, t, s, ft);

      /* move the data if desired */
      IF with_data THEN
         EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I', s, t, s, ft);
      END IF;

      /* drop the foreign table */
      EXECUTE format('DROP FOREIGN TABLE %I.%I', s, ft);

      RETURN TRUE;
   EXCEPTION
      WHEN others THEN
         /* turn the error into a warning */
         GET STACKED DIAGNOSTICS
            errmsg := MESSAGE_TEXT,
            detail := PG_EXCEPTION_DETAIL;
         RAISE WARNING 'Error loading table data for %.%', s, t
            USING DETAIL = errmsg || coalesce(': ' || detail, '');

         EXECUTE
            format(
               E'INSERT INTO %I.migrate_log\n'
               '   (operation, schema_name, object_name, failed_sql, error_message)\n'
               'VALUES (\n'
               '   ''copy table data'',\n'
               '   %L,\n'
               '   %L,\n'
               '   %L,\n'
               '   %L\n'
               ')',
               pgstage_schema,
               s,
               t,
               format('INSERT INTO %I.%I SELECT * FROM %I.%I', s, t, s, ft),
               errmsg || coalesce(': ' || detail, '')
            );
   END;

   RETURN FALSE;
END;$$;

COMMENT ON FUNCTION oracle_materialize(name, name, boolean, name) IS
   'turn an Oracle foreign table into a PostgreSQL table';

CREATE FUNCTION oracle_migrate_refresh(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   old_msglevel text;
   c_col        refcursor;
   v_schema     varchar(128);
   v_table      varchar(128);
   v_column     varchar(128);
   v_pos        integer;
   v_type       varchar(128);
   v_typschema  varchar(128);
   v_length     integer;
   v_precision  integer;
   v_scale      integer;
   v_nullable   boolean;
   v_default    text;
   n_type       text;
   geom_type    text;
   expr         text;
   s            text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* test if the foreign server can be used */
   BEGIN
      SELECT extnamespace::regnamespace INTO extschema
         FROM pg_catalog.pg_extension
         WHERE extname = 'oracle_fdw';
      EXECUTE format('SET LOCAL search_path = %I', extschema);
      PERFORM oracle_diag(server);
   EXCEPTION
      WHEN OTHERS THEN
         RAISE WARNING 'Cannot establish connection with foreign server "%"', server;
         RAISE;
   END;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Copying definitions to PostgreSQL staging schema "%" ...', pgstage_schema;
   SET LOCAL client_min_messages = warning;

   /* get the postgis geometry type if it exists */
   SELECT extnamespace::regnamespace::text || '.geometry' INTO geom_type
      FROM pg_catalog.pg_extension
      WHERE extname = 'postgis';
   IF geom_type IS NULL THEN geom_type := 'text'; END IF;

   /* set "search_path" to the Oracle stage */
   EXECUTE format('SET LOCAL search_path = %I', staging_schema);

   /* open cursors for columns */
   OPEN c_col FOR
      SELECT schema, table_name, column_name, position, type_name, type_schema,
             length, precision, scale, nullable, default_value
      FROM columns
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas);

   /* set "search_path" to the PostgreSQL stage */
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* loop through Oracle columns and translate them to PostgreSQL columns */
   LOOP
      FETCH c_col INTO v_schema, v_table, v_column, v_pos, v_type, v_typschema,
                   v_length, v_precision, v_scale, v_nullable, v_default;

      EXIT WHEN NOT FOUND;

      /* get the PostgreSQL type */
      CASE
         WHEN v_type = 'VARCHAR2'  THEN n_type := 'character varying(' || v_length || ')';
         WHEN v_type = 'NVARCHAR2' THEN n_type := 'character varying(' || v_length || ')';
         WHEN v_type = 'CHAR'      THEN n_type := 'character(' || v_length || ')';
         WHEN v_type = 'NCHAR'     THEN n_type := 'character(' || v_length || ')';
         WHEN v_type = 'CLOB'      THEN n_type := 'text';
         WHEN v_type = 'LONG'      THEN n_type := 'text';
         WHEN v_type = 'NUMBER'    THEN
            IF v_precision IS NULL THEN n_type := 'numeric';
            ELSIF v_scale = 0  THEN
               IF v_precision < 5     THEN n_type := 'smallint';
               ELSIF v_precision < 10 THEN n_type := 'integer';
               ELSIF v_precision < 19 THEN n_type := 'bigint';
               ELSE n_type := 'numeric(' || v_precision || ')';
               END IF;
            ELSE n_type := 'numeric(' || v_precision || ', ' || v_scale || ')';
            END IF;
         WHEN v_type = 'FLOAT' THEN
            IF v_precision < 54 THEN n_type := 'float(' || v_precision || ')';
            ELSE n_type := 'numeric';
            END IF;
         WHEN v_type = 'BINARY_FLOAT'  THEN n_type := 'real';
         WHEN v_type = 'BINARY_DOUBLE' THEN n_type := 'double precision';
         WHEN v_type = 'RAW'           THEN n_type := 'bytea';
         WHEN v_type = 'BLOB'          THEN n_type := 'bytea';
         WHEN v_type = 'BFILE'         THEN n_type := 'bytea';
         WHEN v_type = 'LONG RAW'      THEN n_type := 'bytea';
         WHEN v_type = 'DATE'          THEN n_type := 'timestamp(0) without time zone';
         WHEN substr(v_type, 1, 9) = 'TIMESTAMP' THEN
            IF length(v_type) < 17 THEN n_type := 'timestamp(' || least(v_scale, 6) || ') without time zone';
            ELSE n_type := 'timestamp(' || least(v_scale, 6) || ') with time zone';
            END IF;
         WHEN substr(v_type, 1, 8) = 'INTERVAL' THEN
            IF substr(v_type, 10, 3) = 'DAY' THEN n_type := 'interval(' || least(v_scale, 6) || ')';
            ELSE n_type := 'interval(0)';
            END IF;
         WHEN v_type = 'XMLTYPE' AND (v_typschema = 'SYS' OR v_typschema = 'PUBLIC') THEN n_type := 'xml';
         WHEN v_type = 'SDO_GEOMETRY' AND v_typschema = 'MDSYS' THEN n_type := geom_type;
         ELSE n_type := 'text';  -- cannot translate
      END CASE;

      expr := translate_expression(v_default);

      /* insert a row into the columns table */
      INSERT INTO columns (schema, table_name, column_name, oracle_name, position, type_name, oracle_type, nullable, default_value)
         VALUES (
            oracle_tolower(v_schema),
            oracle_tolower(v_table),
            oracle_tolower(v_column),
            v_column,
            v_pos,
            n_type,
            v_type,
            v_nullable,
            expr
         )
         ON CONFLICT ON CONSTRAINT columns_pkey DO UPDATE SET
            oracle_name = EXCLUDED.oracle_name,
            oracle_type = EXCLUDED.oracle_type;
   END LOOP;

   CLOSE c_col;

   /* copy "tables" table */
   EXECUTE format(E'INSERT INTO tables (schema, oracle_schema, table_name, oracle_name)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          schema,\n'
                   '          oracle_tolower(table_name),\n'
                   '          table_name\n'
                   '   FROM %I.tables\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT tables_pkey DO UPDATE SET\n'
                   '   oracle_schema = EXCLUDED.oracle_schema,\n'
                   '   oracle_name   = EXCLUDED.oracle_name',
                  staging_schema)
      USING only_schemas;

   /* copy "checks" table */
   EXECUTE format(E'INSERT INTO checks (schema, table_name, constraint_name, "deferrable", deferred, condition)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(constraint_name),\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          translate_expression(condition)\n'
                   '   FROM %I.checks\n'
                   '   WHERE ($1 IS NULL OR schema =ANY ($1))\n'
                   '     AND condition !~ ''^"[^"]*" IS NOT NULL$''\n'
                   'ON CONFLICT ON CONSTRAINT checks_pkey DO UPDATE SET\n'
                   '   "deferrable" = EXCLUDED."deferrable",\n'
                   '   deferred     = EXCLUDED.deferred,\n'
                   '   condition    = lower(EXCLUDED.condition)',
                  staging_schema)
      USING only_schemas;

   /* copy "foreign_keys" table */
   EXECUTE format(E'INSERT INTO foreign_keys (schema, table_name, constraint_name, "deferrable", deferred, delete_rule,\n'
                   '                          column_name, position, remote_schema, remote_table, remote_column)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(constraint_name),\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          delete_rule,\n'
                   '          oracle_tolower(column_name),\n'
                   '          position,\n'
                   '          oracle_tolower(remote_schema),\n'
                   '          oracle_tolower(remote_table),\n'
                   '          oracle_tolower(remote_column)\n'
                   '   FROM %I.foreign_keys\n'
                   '   WHERE ($1 IS NULL OR schema =ANY ($1) AND remote_schema =ANY ($1))\n'
                   'ON CONFLICT ON CONSTRAINT foreign_keys_pkey DO UPDATE SET\n'
                   '   "deferrable"  = EXCLUDED."deferrable",\n'
                   '   deferred      = EXCLUDED.deferred,\n'
                   '   delete_rule   = EXCLUDED.delete_rule,\n'
                   '   column_name   = oracle_tolower(EXCLUDED.column_name),\n'
                   '   remote_schema = oracle_tolower(EXCLUDED.remote_schema),\n'
                   '   remote_table  = oracle_tolower(EXCLUDED.remote_table),\n'
                   '   remote_column = oracle_tolower(EXCLUDED.remote_column)',
                  staging_schema)
      USING only_schemas;

   /* copy "keys" table */
   EXECUTE format(E'INSERT INTO keys (schema, table_name, constraint_name, "deferrable", deferred, column_name, position, is_primary)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(constraint_name),\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          oracle_tolower(column_name),\n'
                   '          position,\n'
                   '          is_primary\n'
                   '   FROM %I.keys\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT keys_pkey DO UPDATE SET\n'
                   '   "deferrable"  = EXCLUDED."deferrable",\n'
                   '   deferred      = EXCLUDED.deferred,\n'
                   '   column_name   = oracle_tolower(EXCLUDED.column_name),\n'
                   '   is_primary    = EXCLUDED.is_primary',
                  staging_schema)
      USING only_schemas;

   /* copy "views" table */
   EXECUTE format(E'INSERT INTO views (schema, view_name, definition, oracle_def)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(view_name),\n'
                   '          definition,\n'
                   '          definition\n'
                   '   FROM %I.views\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT views_pkey DO UPDATE SET\n'
                   '   oracle_def = EXCLUDED.definition',
                  staging_schema)
      USING only_schemas;

   /* copy "functions" view */
   EXECUTE format(E'INSERT INTO functions (schema, function_name, is_procedure, source, oracle_source)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(function_name),\n'
                   '          is_procedure,\n'
                   '          source,\n'
                   '          source\n'
                   '   FROM %I.functions\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT functions_pkey DO UPDATE SET\n'
                   '   is_procedure  = EXCLUDED.is_procedure,\n'
                   '   oracle_source = EXCLUDED.source',
                  staging_schema)
      USING only_schemas;

   /* copy "sequences" view */
   EXECUTE format(E'INSERT INTO sequences (schema, sequence_name, min_value, max_value, increment_by,\n'
                   '                       cyclical, cache_size, last_value, oracle_value)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(sequence_name),\n'
                   '          adjust_to_bigint(min_value),\n'
                   '          adjust_to_bigint(max_value),\n'
                   '          adjust_to_bigint(increment_by),\n'
                   '          cyclical,\n'
                   '          GREATEST(cache_size, 1) AS cache_size,\n'
                   '          adjust_to_bigint(last_value),\n'
                   '          adjust_to_bigint(last_value)\n'
                   '   FROM %I.sequences\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT sequences_pkey DO UPDATE SET\n'
                   '   min_value    = EXCLUDED.min_value,\n'
                   '   max_value    = EXCLUDED.max_value,\n'
                   '   increment_by = EXCLUDED.increment_by,\n'
                   '   cyclical     = EXCLUDED.cyclical,\n'
                   '   cache_size   = EXCLUDED.cache_size,\n'
                   '   oracle_value = EXCLUDED.oracle_value',
                  staging_schema)
      USING only_schemas;

   /* copy "index_columns" view */
   EXECUTE format(E'INSERT INTO index_columns (schema, table_name, index_name, uniqueness, position, descend, is_expression, column_name)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(index_name),\n'
                   '          uniqueness,\n'
                   '          position,\n'
                   '          descend,\n'
                   '          is_expression,\n'
                   '          CASE WHEN is_expression THEN ''('' || lower(column_name) || '')'' ELSE oracle_tolower(column_name)::text END\n'
                   '   FROM %I.index_columns\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT index_columns_pkey DO UPDATE SET\n'
                   '   table_name    = EXCLUDED.table_name,\n'
                   '   uniqueness    = EXCLUDED.uniqueness,\n'
                   '   descend       = EXCLUDED.descend,\n'
                   '   is_expression = EXCLUDED.is_expression,\n'
                   '   column_name   = EXCLUDED.column_name',
                  staging_schema)
      USING only_schemas;

   /* copy "schemas" table */
   EXECUTE format(E'INSERT INTO schemas (schema)\n'
                   '   SELECT oracle_tolower(schema)\n'
                   '   FROM %I.schemas\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT DO NOTHING',
                  staging_schema)
      USING only_schemas;

   /* copy "triggers" view */
   EXECUTE format(E'INSERT INTO triggers (schema, table_name, trigger_name, is_before, triggering_event,\n'
                   '                      for_each_row, when_clause, referencing_names, trigger_body, oracle_source)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(trigger_name),\n'
                   '          is_before,\n'
                   '          triggering_event,\n'
                   '          for_each_row,\n'
                   '          when_clause,\n'
                   '          referencing_names,\n'
                   '          trigger_body,\n'
                   '          trigger_body\n'
                   '   FROM %I.triggers\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT triggers_pkey DO UPDATE SET\n'
                   '   is_before         = EXCLUDED.is_before,\n'
                   '   triggering_event  = EXCLUDED.triggering_event,\n'
                   '   for_each_row      = EXCLUDED.for_each_row,\n'
                   '   when_clause       = EXCLUDED.when_clause,\n'
                   '   referencing_names = EXCLUDED.referencing_names,\n'
                   '   oracle_source     = EXCLUDED.oracle_source',
                  staging_schema)
      USING only_schemas;

   /* copy "packages" view */
   EXECUTE format(E'INSERT INTO packages (schema, package_name, is_body, source)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(package_name),\n'
                   '          is_body,\n'
                   '          source\n'
                   '   FROM %I.packages\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT packages_pkey DO UPDATE SET\n'
                   '   source  = EXCLUDED.source',
                  staging_schema)
      USING only_schemas;

   /* copy "table_privs" table */
   EXECUTE format(E'INSERT INTO table_privs (schema, table_name, privilege, grantor, grantee, grantable)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          privilege,\n'
                   '          oracle_tolower(grantor),\n'
                   '          oracle_tolower(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.table_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT table_privs_pkey DO UPDATE SET\n'
                   '   grantor   = EXCLUDED.grantor,\n'
                   '   grantable = EXCLUDED.grantable',
                  staging_schema)
      USING only_schemas;

   /* copy "column_privs" table */
   EXECUTE format(E'INSERT INTO column_privs (schema, table_name, column_name, privilege, grantor, grantee, grantable)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(column_name),\n'
                   '          privilege,\n'
                   '          oracle_tolower(grantor),\n'
                   '          oracle_tolower(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.column_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)\n'
                   'ON CONFLICT ON CONSTRAINT column_privs_pkey DO UPDATE SET\n'
                   '   grantor   = EXCLUDED.grantor,\n'
                   '   grantable = EXCLUDED.grantable',
                  staging_schema)
      USING only_schemas;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN 0;
END;$$;

COMMENT ON FUNCTION oracle_migrate_refresh(name, name, name, name[], integer) IS
  'update the PostgreSQL stage with values from the Oracle stage';

CREATE FUNCTION oracle_migrate_prepare(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   old_msglevel text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* test if the foreign server can be used */
   BEGIN
      SELECT extnamespace::regnamespace INTO extschema
         FROM pg_catalog.pg_extension
         WHERE extname = 'oracle_fdw';
      EXECUTE format('SET LOCAL search_path = %I', extschema);
      PERFORM oracle_diag(server);
   EXCEPTION
      WHEN OTHERS THEN
         RAISE WARNING 'Cannot establish connection with foreign server "%"', server;
         RAISE;
   END;

   /* get the "ora_migrator" extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating staging schemas "%" and "%" ...', staging_schema, pgstage_schema;
   SET LOCAL client_min_messages = warning;

   /* create Oracle staging schema */
   BEGIN
      EXECUTE format('CREATE SCHEMA %I', staging_schema);
   EXCEPTION
      WHEN insufficient_privilege THEN
         RAISE insufficient_privilege USING
            MESSAGE = 'you do not have permission to create a schema in this database';
      WHEN duplicate_schema THEN
         RAISE duplicate_schema USING
            MESSAGE = 'staging schema "' || staging_schema || '" already exists',
            HINT = 'Drop the staging schema first or use a different one.';
   END;

   /* create PostgreSQL staging schema */
   BEGIN
      EXECUTE format('CREATE SCHEMA %I', pgstage_schema);
   EXCEPTION
      WHEN duplicate_schema THEN
         RAISE duplicate_schema USING
            MESSAGE = 'staging schema "' || pgstage_schema || '" already exists',
            HINT = 'Drop the staging schema first or use a different one.';
   END;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating Oracle metadata views in schema "%" ...', staging_schema;
   SET LOCAL client_min_messages = warning;

   /* create the migration views in the Oracle staging schema */
   EXECUTE format('SET LOCAL search_path = %I', extschema);
   PERFORM create_oraviews(server, staging_schema, max_long);

   /* set "search_path" to the PostgreSQL stage */
   EXECUTE format('SET LOCAL search_path = %I, %I, %I', pgstage_schema, staging_schema, extschema);

   /* create tables in the PostgreSQL stage */
   CREATE TABLE columns(
      schema        name         NOT NULL,
      table_name    name         NOT NULL,
      column_name   name         NOT NULL,
      oracle_name   varchar(128) NOT NULL,
      position      integer      NOT NULL,
      type_name     name         NOT NULL,
      oracle_type   varchar(128) NOT NULL,
      nullable      boolean      NOT NULL,
      default_value text,
      CONSTRAINT columns_pkey
         PRIMARY KEY (schema, table_name, column_name),
      CONSTRAINT columns_unique
         UNIQUE (schema, table_name, column_name, position)
   );

   CREATE TABLE tables (
      schema        name         NOT NULL,
      oracle_schema varchar(128) NOT NULL,
      table_name    name         NOT NULL,
      oracle_name   varchar(128) NOT NULL,
      migrate       boolean      NOT NULL DEFAULT TRUE,
      CONSTRAINT tables_pkey
         PRIMARY KEY (schema, table_name)
   );

   CREATE TABLE checks (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      condition       text    NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT checks_pkey
         PRIMARY KEY (schema, table_name, constraint_name)
   );

   CREATE TABLE foreign_keys (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      delete_rule     text    NOT NULL,
      column_name     name    NOT NULL,
      position        integer NOT NULL,
      remote_schema   name    NOT NULL,
      remote_table    name    NOT NULL,
      remote_column   name    NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT foreign_keys_pkey
         PRIMARY KEY (schema, table_name, constraint_name, position)
   );

   CREATE TABLE keys (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      column_name     name    NOT NULL,
      position        integer NOT NULL,
      is_primary      boolean NOT NULL,
      migrate         boolean NOT NULL DEFAULT TRUE,
      CONSTRAINT keys_pkey
         PRIMARY KEY (schema, table_name, constraint_name, position)
   );

   CREATE TABLE views (
      schema     name    NOT NULL,
      view_name  name    NOT NULL,
      definition text    NOT NULL,
      oracle_def text    NOT NULL,
      migrate    boolean NOT NULL DEFAULT TRUE,
      verified   boolean NOT NULL DEFAULT FALSE,
      CONSTRAINT views_pkey
         PRIMARY KEY (schema, view_name)
   );

   CREATE TABLE functions (
      schema         name    NOT NULL,
      function_name  name    NOT NULL,
      is_procedure   boolean NOT NULL,
      source         text    NOT NULL,
      oracle_source  text    NOT NULL,
      migrate        boolean NOT NULL DEFAULT FALSE,
      verified       boolean NOT NULL DEFAULT FALSE,
      CONSTRAINT functions_pkey
         PRIMARY KEY (schema, function_name)
   );

   CREATE TABLE sequences (
      schema        name    NOT NULL,
      sequence_name name    NOT NULL,
      min_value     bigint,
      max_value     bigint,
      increment_by  bigint  NOT NULL,
      cyclical      boolean NOT NULL,
      cache_size    integer NOT NULL,
      last_value    bigint  NOT NULL,
      oracle_value  bigint  NOT NULL,
      CONSTRAINT sequences_pkey
         PRIMARY KEY (schema, sequence_name)
   );

   CREATE TABLE index_columns (
      schema        name NOT NULL,
      table_name    name NOT NULL,
      index_name    name NOT NULL,
      uniqueness    boolean NOT NULL,
      position      integer NOT NULL,
      descend       boolean NOT NULL,
      is_expression boolean NOT NULL,
      column_name   text    NOT NULL,
      CONSTRAINT index_columns_pkey
         PRIMARY KEY (schema, index_name, position)
   );

   CREATE TABLE schemas (
      schema name NOT NULL
         CONSTRAINT schemas_pkey PRIMARY KEY
   );

   CREATE TABLE triggers (
      schema            name         NOT NULL,
      table_name        name         NOT NULL,
      trigger_name      name         NOT NULL,
      is_before         boolean      NOT NULL,
      triggering_event  varchar(227) NOT NULL,
      for_each_row      boolean      NOT NULL,
      when_clause       text,
      referencing_names name         NOT NULL,
      trigger_body      text         NOT NULL,
      oracle_source     text         NOT NULL,
      migrate           boolean      NOT NULL DEFAULT FALSE,
      verified          boolean      NOT NULL DEFAULT FALSE,
      CONSTRAINT triggers_pkey
         PRIMARY KEY (schema, table_name, trigger_name)
   );

   CREATE TABLE packages (
      schema       name    NOT NULL,
      package_name name    NOT NULL,
      is_body      boolean NOT NULL,
      source       text    NOT NULL,
      CONSTRAINT packages_pkey
         PRIMARY KEY (schema, package_name, is_body)
   );

   CREATE TABLE table_privs (
      schema     name        NOT NULL,
      table_name name        NOT NULL,
      privilege  varchar(40) NOT NULL,
      grantor    name        NOT NULL,
      grantee    name        NOT NULL,
      grantable  boolean     NOT NULL,
      CONSTRAINT table_privs_pkey
         PRIMARY KEY (schema, table_name, grantee, privilege, grantor)
   );

   CREATE TABLE column_privs (
      schema      name        NOT NULL,
      table_name  name        NOT NULL,
      column_name name        NOT NULL,
      privilege   varchar(40) NOT NULL,
      grantor     name        NOT NULL,
      grantee     name        NOT NULL,
      grantable   boolean     NOT NULL,
      CONSTRAINT column_privs_pkey
         PRIMARY KEY (schema, table_name, column_name, grantee, privilege)
   );

   /* table to record errors during migration */
   CREATE TABLE migrate_log (
      log_time timestamp with time zone PRIMARY KEY DEFAULT clock_timestamp(),
      operation text NOT NULL,
      schema_name name NOT NULL,
      object_name name NOT NULL,
      failed_sql text,
      error_message text NOT NULL
   );

   /* table to record errors from "oracle_migrate_test_data" */
   CREATE TABLE test_error (
      log_time   timestamp with time zone NOT NULL DEFAULT current_timestamp,
      schema     name                     NOT NULL,
      table_name name                     NOT NULL,
      rowid      text                     NOT NULL,
      message    text                     NOT NULL,
      PRIMARY KEY (schema, table_name, log_time, rowid)
   );

   /* table for cumulative errors from "oracle_migrate_test_data" */
   CREATE TABLE test_error_stats (
      log_time   timestamp with time zone NOT NULL,
      schema     name                     NOT NULL,
      table_name name                     NOT NULL,
      errcount   bigint                   NOT NULL,
      PRIMARY KEY (schema, table_name, log_time)
   );

   /* rough estimate of the migration costs */
   CREATE VIEW oracle_migration_cost_estimate AS
      SELECT 'tables'::text                 AS task_type,
             count(*)::bigint               AS task_content,
             'table'::text                  AS task_unit,
             ceil(count(*) / 10.0)::integer AS migration_hours
      FROM tables
      WHERE migrate
   UNION ALL
      SELECT 'data_migration'::text,
             sum(bytes)::bigint,
             'bytes'::text,
             ceil(sum(bytes::float8) / 26843545600.0)::integer
      FROM segments AS s
         JOIN tables AS t
            ON s.schema = t.oracle_schema
               AND s.segment_name = t.oracle_name
      WHERE s.segment_type = 'TABLE'
        AND t.migrate
   UNION ALL
      SELECT object_type::text,
             bytes::bigint,
             'characters'::text,
             ceil(bytes / 1024.0)::integer
      FROM oracle_code_count() AS q;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   /* copy data from the Oracle stage to the PostgreSQL stage */
   EXECUTE format('SET LOCAL search_path = %I', extschema);
   RETURN oracle_migrate_refresh(server, staging_schema, pgstage_schema, only_schemas, max_long);
END;$$;

COMMENT ON FUNCTION oracle_migrate_prepare(name, name, name, name[], integer) IS
   'first step of "oracle_migrate": create and populate staging schemas';

CREATE FUNCTION oracle_migrate_mkforeign(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   s            name;
   t            name;
   sch          name;
   seq          name;
   minv         numeric;
   maxv         numeric;
   incr         numeric;
   cycl         boolean;
   cachesiz     integer;
   lastval      numeric;
   tab          name;
   colname      name;
   typ          text;
   pos          integer;
   nul          boolean;
   fsch         text;
   ftab         text;
   o_fsch       text;
   o_ftab       text;
   o_sch        name;
   o_tab        name;
   stmt         text;
   separator    text;
   old_msglevel text;
   errmsg       text;
   detail       text;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the PostgreSQL staging schema and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating schemas ...';
   SET LOCAL client_min_messages = warning;

   /* loop through the schemas that should be migrated */
   FOR s IN
      SELECT schema FROM schemas
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas)
   LOOP
      BEGIN
         /* create schema */
         EXECUTE format('CREATE SCHEMA %I', s);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating schema "%"', s
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create schema'',\n'
                  '   %L,\n'
                  '   '''',\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  s,
                  format('CREATE SCHEMA %I', s),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating sequences ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all sequences */
   FOR sch, seq, minv, maxv, incr, cycl, cachesiz, lastval IN
      SELECT schema, sequence_name, min_value, max_value, increment_by, cyclical, cache_size, last_value
         FROM sequences
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas)
   LOOP
      BEGIN
      EXECUTE format('CREATE SEQUENCE %I.%I INCREMENT %s MINVALUE %s MAXVALUE %s START %s CACHE %s %sCYCLE',
                     sch, seq, incr, minv, maxv, lastval + 1, cachesiz,
                     CASE WHEN cycl THEN '' ELSE 'NO ' END);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating sequence %.%', sch, seq
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create sequence'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  seq,
                  format('CREATE SEQUENCE %I.%I INCREMENT %s MINVALUE %s MAXVALUE %s START %s CACHE %s %sCYCLE',
                         sch, seq, incr, minv, maxv, lastval + 1, cachesiz,
                         CASE WHEN cycl THEN '' ELSE 'NO ' END),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating foreign tables ...';
   SET LOCAL client_min_messages = warning;

   /* create foreign tables */
   o_sch := '';
   o_tab := '';
   stmt := '';
   separator := '';
   FOR sch, tab, colname, pos, typ, nul, fsch, ftab IN
      EXECUTE format(
         E'SELECT schema,\n'
          '       table_name,\n'
          '       pc.column_name,\n'
          '       pc.position,\n'
          '       pc.type_name,\n'
          '       pc.nullable,\n'
          '       pt.oracle_schema,\n'
          '       pt.oracle_name\n'
          'FROM columns pc\n'
          '   JOIN tables pt\n'
          '      USING (schema, table_name)\n'
          'WHERE pt.migrate\n'
          'ORDER BY schema, table_name, pc.position',
         staging_schema)
   LOOP
      IF o_sch <> sch OR o_tab <> tab THEN
         IF o_tab <> '' THEN
            BEGIN
               EXECUTE stmt || format(E') SERVER %I\n'
                                       '   OPTIONS (schema ''%s'', table ''%s'', readonly ''true'', max_long ''%s'')',
                                      server, o_fsch, o_ftab, max_long);
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating foreign table %.%', sch, tab
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''create foreign table'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        sch,
                        tab,
                        stmt || format(E') SERVER %I\n'
                                       '   OPTIONS (schema ''%s'', table ''%s'', readonly ''true'', max_long ''%s'')',
                                       server, o_fsch, o_ftab, max_long),
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format(E'CREATE FOREIGN TABLE %I.%I (\n', sch, tab);
         o_sch := sch;
         o_tab := tab;
         o_fsch := fsch;
         o_ftab := ftab;
         separator := '';
      END IF;

      stmt := stmt || format(E'   %s%I %s%s\n',
                             separator, colname, typ,
                             CASE WHEN nul THEN '' ELSE ' NOT NULL' END);
      separator := ', ';
   END LOOP;

   /* last foreign table */
   IF o_tab <> '' THEN
      BEGIN
         EXECUTE stmt || format(E') SERVER %I\n'
                                 '   OPTIONS (schema ''%s'', table ''%s'', readonly ''true'', max_long ''%s'')',
                                server, o_fsch, o_ftab, max_long);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating foreign table %.%', sch, tab
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create foreign table'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  tab,
                  stmt || format(E') SERVER %I\n'
                                 '   OPTIONS (schema ''%s'', table ''%s'', readonly ''true'', max_long ''%s'')',
                                 server, o_fsch, o_ftab, max_long),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_mkforeign(name, name, name, name[], integer) IS
   'second step of "oracle_migrate": create schemas, sequemces and foreign tables';

CREATE FUNCTION oracle_migrate_tables(
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   with_data      boolean DEFAULT TRUE
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;
   extschema    name;
   sch          name;
   tab          name;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the Oracle stage and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;

   /* loop through all foreign tables to be migrated */
   FOR sch, tab IN
      SELECT schema, table_name FROM tables
      WHERE migrate
        AND (only_schemas IS NULL
         OR schema =ANY (only_schemas))
   LOOP
      EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
      RAISE NOTICE 'Migrating table %.% ...', sch, tab;
      SET LOCAL client_min_messages = warning;

      /* turn that foreign table into a real table */
      IF NOT oracle_materialize(sch, tab, with_data, pgstage_schema) THEN
         rc := rc + 1;
         /* remove the foreign table if it failed */
         EXECUTE format('DROP FOREIGN TABLE %I.%I', sch, tab);
      END IF;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_tables(name, name, name[], boolean) IS
   'third step of "oracle_migrate": copy tables from Oracle';

CREATE FUNCTION oracle_migrate_functions(
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog SET check_function_bodies = off AS
$$DECLARE
   extschema    name;
   sch          name;
   fname        name;
   src          text;
   errmsg       text;
   detail       text;
   old_msglevel text;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the Oracle stage and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;
   FOR sch, fname, src IN
      SELECT schema, function_name, source
      FROM functions
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND migrate
   LOOP
      BEGIN
         /* set "search_path" so that the function can be created without schema */
         EXECUTE format('SET LOCAL search_path = %I', sch);

         EXECUTE 'CREATE ' || src;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating function %.%', sch, fname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create function'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  fname,
                  'CREATE ' || src,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_functions(name, name[]) IS
   'fourth step of "oracle_migrate": create functions';

CREATE FUNCTION oracle_migrate_triggers(
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog SET check_function_bodies = off AS
$$DECLARE
   extschema    name;
   sch          name;
   tabname      name;
   trigname     name;
   bef          boolean;
   event        text;
   eachrow      boolean;
   whencl       text;
   ref          text;
   src          text;
   errmsg       text;
   detail       text;
   old_msglevel text;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the Oracle stage and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;
   FOR sch, tabname, trigname, bef, event, eachrow, whencl, ref, src IN
      SELECT schema, table_name, trigger_name, is_before, triggering_event,
             for_each_row, when_clause, referencing_names, trigger_body
      FROM triggers
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND migrate
   LOOP
      BEGIN
         /* create the trigger function */
         EXECUTE format(E'CREATE FUNCTION %I.%I() RETURNS trigger LANGUAGE plpgsql AS\n$_f_$%s$_f_$',
                        sch, trigname, src);
         /* create the trigger itself */
         EXECUTE format(E'CREATE TRIGGER %I %s %s ON %I.%I FOR EACH %s\n'
                        '   EXECUTE PROCEDURE %I.%I()',
                        trigname,
                        CASE WHEN bef THEN 'BEFORE' ELSE 'AFTER' END,
                        event,
                        sch, tabname,
                        CASE WHEN eachrow THEN 'ROW' ELSE 'STATEMENT' END,
                        sch, trigname);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating trigger % on %.%', trigname, sch, tabname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create trigger'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  tabname,
                  format(E'CREATE FUNCTION %I.%I() RETURNS trigger LANGUAGE plpgsql AS\n$_f_$%s$_f_$',
                         sch, trigname, src) || E';\n' ||
                  format(E'CREATE TRIGGER %I %s %s ON %I.%I FOR EACH %s\n'
                         '   EXECUTE PROCEDURE %I.%I()',
                         trigname,
                         CASE WHEN bef THEN 'BEFORE' ELSE 'AFTER' END,
                         event,
                         sch, tabname,
                         CASE WHEN eachrow THEN 'ROW' ELSE 'STATEMENT' END,
                         sch, trigname),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_triggers(name, name[]) IS
   'fifth step of "oracle_migrate": create triggers';

CREATE FUNCTION oracle_migrate_views(
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   sch          name;
   vname        name;
   col          name;
   src          text;
   stmt         text;
   separator    text;
   errmsg       text;
   detail       text;
   old_msglevel text;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the Oracle stage and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;
   FOR sch, vname, src IN
      SELECT schema, view_name, definition
      FROM views
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND migrate
   LOOP
      stmt := format(E'CREATE VIEW %I.%I (', sch, vname);
      separator := E'\n   ';
      FOR col IN
         SELECT column_name
            FROM columns
            WHERE schema = sch
              AND table_name = vname
            ORDER BY position
      LOOP
         stmt := stmt || separator || quote_ident(col);
         separator := E',\n   ';
      END LOOP;
      stmt := stmt || E'\n) AS ' || src;

      BEGIN
         /* set "search_path" so that the function body can reference objects without schema */
         EXECUTE format('SET LOCAL search_path = %I', sch);

         EXECUTE stmt;

         EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating view %.%', sch, vname
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create view'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  sch,
                  vname,
                  stmt,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_views(name, name[]) IS
   'sixth step of "oracle_migrate": create views';

CREATE FUNCTION oracle_migrate_constraints(
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   stmt         text;
   stmt_middle  text;
   stmt_suffix  text;
   separator    text;
   old_s        name;
   old_t        name;
   old_c        name;
   loc_s        name;
   loc_t        name;
   ind_name     name;
   cons_name    name;
   candefer     boolean;
   is_deferred  boolean;
   delrule      text;
   colname      name;
   colpos       integer;
   rem_s        name;
   rem_t        name;
   rem_colname  name;
   prim         boolean;
   expr         text;
   uniq         boolean;
   des          boolean;
   is_expr      boolean;
   errmsg       text;
   detail       text;
   old_msglevel text;
   rc           integer := 0;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the PostgreSQL staging schema and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating UNIQUE and PRIMARY KEY constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all key constraint columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, colname, colpos, prim IN
      SELECT schema, table_name, k.constraint_name, k."deferrable", k.deferred,
             k.column_name, k.position, k.is_primary
      FROM keys k
         JOIN tables t
            USING (schema, table_name)
      WHERE (only_schemas IS NULL
         OR k.schema =ANY (only_schemas))
        AND t.migrate
        AND k.migrate
      ORDER BY schema, table_name, k.constraint_name, k.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
                  EXECUTE stmt || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating primary key or unique constraint on table %.%', old_s, old_t
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''unique constraint'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || stmt_suffix,
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD %s (', loc_s, loc_t,
                        CASE WHEN prim THEN 'PRIMARY KEY' ELSE 'UNIQUE' END);
         stmt_suffix := format(')%s DEFERRABLE INITIALLY %s',
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', colname);
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating primary key or unique constraint on table %.%',
                          old_s, old_t
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''unique constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || stmt_suffix,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating FOREIGN KEY constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all foreign key constraint columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, delrule,
       colname, colpos, rem_s, rem_t, rem_colname IN
      SELECT fk.schema, fk.table_name, fk.constraint_name, fk."deferrable", fk.deferred, fk.delete_rule,
             fk.column_name, fk.position, fk.remote_schema, fk.remote_table, fk.remote_column
      FROM foreign_keys fk
         JOIN tables tl
            USING (schema, table_name)
         JOIN tables tf
            ON fk.remote_schema = tf.schema AND fk.remote_table = tf.table_name
      WHERE (only_schemas IS NULL
         OR fk.schema =ANY (only_schemas)
            AND fk.remote_schema =ANY (only_schemas))
        AND tl.migrate
        AND tf.migrate
        AND fk.migrate
      ORDER BY fk.schema, fk.table_name, fk.constraint_name, fk.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || stmt_middle || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error creating foreign key constraint on table %.%', old_s, old_t
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''foreign key constraint'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || stmt_middle || stmt_suffix,
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD FOREIGN KEY (', loc_s, loc_t);
         stmt_middle := format(') REFERENCES %I.%I (', rem_s, rem_t);
         stmt_suffix := format(')%s DEFERRABLE INITIALLY %s',
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', colname);
      stmt_middle := stmt_middle || separator || format('%I', rem_colname);
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_middle || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating foreign key constraint on table %.%', old_s, old_t
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''foreign key constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || stmt_middle || stmt_suffix,
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating CHECK constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all check constraints except NOT NULL checks */
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, expr IN
      SELECT schema, table_name, c.constraint_name, c."deferrable", c.deferred, c.condition
      FROM checks c
         JOIN tables t
            USING (schema, table_name)
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND t.migrate
        AND c.migrate
   LOOP
      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ADD CHECK(%s)', loc_s, loc_t, expr);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error creating CHECK constraint on table %.% with expression "%"', loc_s, loc_t, expr
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''check constraint'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  loc_s,
                  loc_t,
                  format('ALTER TABLE %I.%I ADD CHECK(%s)', loc_s, loc_t, expr),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating indexes ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all index columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, ind_name, uniq, colpos, des, is_expr, expr IN
      SELECT schema, table_name, i.index_name, i.uniqueness, i.position, i.descend, i.is_expression, i.column_name
      FROM index_columns i
         JOIN tables t
            USING (schema, table_name)
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND t.migrate
      ORDER BY schema, table_name, i.index_name, i.position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> ind_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || ')';
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT,
                     detail := PG_EXCEPTION_DETAIL;
                  RAISE WARNING 'Error executing "%"', stmt || ')'
                     USING DETAIL = errmsg || coalesce(': ' || detail, '');

                  EXECUTE
                     format(
                        E'INSERT INTO %I.migrate_log\n'
                        '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                        'VALUES (\n'
                        '   ''create index'',\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L,\n'
                        '   %L\n'
                        ')',
                        pgstage_schema,
                        old_s,
                        old_t,
                        stmt || ')',
                        errmsg || coalesce(': ' || detail, '')
                     );

                  rc := rc + 1;
            END;
         END IF;

         stmt := format('CREATE %sINDEX ON %I.%I (',
                        CASE WHEN uniq THEN 'UNIQUE ' ELSE '' END, loc_s, loc_t);
         old_s := loc_s;
         old_t := loc_t;
         old_c := ind_name;
         separator := '';
      END IF;

      /* fold expressions to lower case */
      stmt := stmt || separator || expr
                   || CASE WHEN des THEN ' DESC' ELSE ' ASC' END;
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || ')';
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error executing "%"', stmt || ')'
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''create index'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  old_s,
                  old_t,
                  stmt || ')',
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Setting column default values ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all default expressions */
   FOR loc_s, loc_t, colname, expr IN
      SELECT schema, table_name, c.column_name, c.default_value
      FROM columns c
         JOIN tables t
            USING (schema, table_name)
      WHERE (only_schemas IS NULL
         OR schema =ANY (only_schemas))
        AND t.migrate
        AND c.default_value IS NOT NULL
   LOOP
      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ALTER %I SET DEFAULT %s',
                        loc_s, loc_t, colname, expr);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT,
               detail := PG_EXCEPTION_DETAIL;
            RAISE WARNING 'Error setting default value on % of table %.% to "%"',
                          colname, loc_s, loc_t, expr
               USING DETAIL = errmsg || coalesce(': ' || detail, '');

            EXECUTE
               format(
                  E'INSERT INTO %I.migrate_log\n'
                  '   (operation, schema_name, object_name, failed_sql, error_message)\n'
                  'VALUES (\n'
                  '   ''column default'',\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L,\n'
                  '   %L\n'
                  ')',
                  pgstage_schema,
                  loc_s,
                  loc_t,
                  format('ALTER TABLE %I.%I ALTER %I SET DEFAULT %s',
                         loc_s, loc_t, colname, expr),
                  errmsg || coalesce(': ' || detail, '')
               );

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_constraints(name, name[])
   IS 'seventh step of "oracle_migrate": create constraints and indexes';

CREATE FUNCTION oracle_migrate_finish(
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage'
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;
BEGIN
   RAISE NOTICE 'Dropping staging schemas ...';

   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE format('DROP SCHEMA %I CASCADE', staging_schema);
   EXECUTE format('DROP SCHEMA %I CASCADE', pgstage_schema);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN 0;
END;$$;

COMMENT ON FUNCTION oracle_migrate_finish(name, name) IS
   'final step of "oracle_migrate": drop staging schema';

CREATE FUNCTION oracle_migrate(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767,
   with_data      boolean DEFAULT TRUE
) RETURNS integer
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema name;
   rc        integer := 0;
BEGIN
   /* set "search_path" to the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I', extschema);

   /*
    * First step:
    * Create staging schema and define the oracle metadata views there.
    */
   rc := rc + oracle_migrate_prepare(server, staging_schema, pgstage_schema, only_schemas, max_long);

   /*
    * Second step:
    * Create the destination schemas and the foreign tables and sequences there.
    */
   rc := rc + oracle_migrate_mkforeign(server, staging_schema, pgstage_schema, only_schemas, max_long);

   /*
    * Third step:
    * Copy the tables over from Oracle.
    */
   rc := rc + oracle_migrate_tables(staging_schema, pgstage_schema, only_schemas, with_data);

   /*
    * Fourth step:
    * Create functions (this won't do anything since they have "migrate = FALSE").
    */
   rc := rc + oracle_migrate_functions(pgstage_schema, only_schemas);

   /*
    * Fifth step:
    * Create triggers (this won't do anything since they have "migrate = FALSE").
    */
   rc := rc + oracle_migrate_triggers(pgstage_schema, only_schemas);

   /*
    * Sixth step:
    * Create views.
    */
   rc := rc + oracle_migrate_views(pgstage_schema, only_schemas);

   /*
    * Seventh step:
    * Create constraints and indexes.
    */
   rc := rc + oracle_migrate_constraints(pgstage_schema, only_schemas);

   /*
    * Final step:
    * Drop the staging schema.
    */
   rc := rc + oracle_migrate_finish(staging_schema, pgstage_schema);

   RAISE NOTICE 'Migration completed with % errors.', rc;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate(name, name, name, name[], integer, boolean) IS
   'migrate an Oracle database from a foreign server to PostgreSQL';

CREATE FUNCTION oracle_code_count(
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS TABLE (
   object_type text,
   number bigint,
   lines bigint,
   bytes bigint
) LANGUAGE plpgsql SET search_path = pg_catalog AS
$$BEGIN
   RETURN QUERY EXECUTE
      format(
         E'SELECT ''function'' AS object_type,\n'
         '       count(*) AS number,\n'
         '       coalesce(sum((SELECT count(*) FROM regexp_matches(oracle_source, E''\\n'', ''g'')))::bigint, 0) AS lines,\n'
         '       coalesce(sum(octet_length(oracle_source)), 0) AS bytes\n'
         'FROM %I.functions\n'
         'UNION ALL\n'
         'SELECT ''trigger'' AS object_type,\n'
         '       count(*) AS number,\n'
         '       coalesce(sum((SELECT count(*) + 1 FROM regexp_matches(oracle_source, E''\\n'', ''g'')))::bigint, 0) AS lines,\n'
         '       coalesce(sum(octet_length(oracle_source)), 0) AS bytes\n'
         'FROM %I.triggers\n'
         'UNION ALL\n'
         'SELECT ''package'' AS object_type,\n'
         '       count(*) AS number,\n'
         '       coalesce(sum((SELECT count(*) FROM regexp_matches(source, E''\\n'', ''g'')))::bigint, 0) AS lines,\n'
         '       coalesce(sum(octet_length(source)), 0) AS bytes\n'
         'FROM %I.packages\n'
         'WHERE is_body\n'
         'UNION ALL\n'
         'SELECT ''view'' AS object_type,\n'
         '       count(*) AS number,\n'
         '       coalesce(sum((SELECT count(*) + 1 FROM regexp_matches(oracle_def, E''\\n'', ''g'')))::bigint, 0) AS lines,\n'
         '       coalesce(sum(octet_length(oracle_def)), 0) AS bytes\n'
         'FROM %I.views',
         pgstage_schema,
         pgstage_schema,
         pgstage_schema,
         pgstage_schema
      );
END;$$;

COMMENT ON FUNCTION oracle_code_count(name) IS
   'provide statistics on the PL/SQL code and views in the Oracle database';

CREATE FUNCTION oracle_test_table(
   server         name,
   schema         name,
   table_name     name,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS TABLE (
   rowid          text,
   message        text
) LANGUAGE plpgsql VOLATILE STRICT SET search_path = pg_catalog AS
$$DECLARE
   v_schema     text;
   v_table      text;
   v_column     text;
   v_oratype    text;
   v_where      text[] := ARRAY[]::text[];
   v_select     text[] := ARRAY[]::text[];
   old_msglevel text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE format('SET LOCAL search_path = %I', pgstage_schema);

   /* check if the table exists */
   IF NOT EXISTS (
         SELECT 1 FROM tables
         WHERE tables.schema = $2 AND tables.table_name = $3
      )
   THEN
      RAISE EXCEPTION '%',
         format('table %I.%I not found in %I.tables',
                $2,
                $3,
                $4
         );
   END IF;

   /*
    * The idea is to create a temporary foreign table on an SQL statement
    * that performs the required checks on the Oracle side.
    */

   FOR v_schema, v_table, v_column, v_oratype IN
      SELECT t.oracle_schema AS schema,
             t.oracle_name AS table_name,
             c.oracle_name AS column_name,
             c.oracle_type
      FROM tables AS t
         JOIN columns AS c USING (schema, table_name)
      WHERE t.schema = $2
        AND t.table_name = $3
        /* unfortunately our trick doesn't work for CLOB */
        AND c.oracle_type IN ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR', 'VARCHAR')
      ORDER BY c.position
   LOOP
      /* test for zero bytes */
      v_select := v_select
         || format(
               E'CASE WHEN %I LIKE ''''%%'''' || chr(0) || ''''%%'''' THEN ''''zero byte in %I '''' END',
               v_column,
               v_column
            );

      v_where := v_where
         || format(
               E'(%I LIKE ''''%%'''' || chr(0) || ''''%%'''')',
               v_column,
               v_column
            );

      /*
       * Test for corrupt string data.
       * The trick is to convert the string to a different encoding and back.
       * We have to choose an encoding that
       * - can store all possible characters
       * - is different from the original encoding (else nothing is done)
       * If there are bad bytes, they will be replaced with "replacement characters".
       */
      IF v_oratype IN ('NVARCHAR2', 'NCHAR') THEN
         /* NVARCHAR2 and NCHAR are stored in AS16UTF16 or UTF8 */
         v_select := v_select
            || format(
                  E'CASE WHEN convert(convert(%I, ''''AL32UTF8''''), (SELECT value FROM nls_database_parameters WHERE parameter = ''''NLS_NCHAR_CHARACTERSET''''), ''''AL32UTF8'''') <> %I THEN ''''invalid byte in %I '''' END',
                  v_column,
                  v_column,
                  v_column
               );

         v_where := v_where
            || format(
                  E'(convert(convert(%I, ''''AL32UTF8''''), (SELECT value FROM nls_database_parameters WHERE parameter = ''''NLS_NCHAR_CHARACTERSET''''), ''''AL32UTF8'''') <> %I)',
                  v_column,
                  v_column
               );
      ELSE
         /* all other strings are *never* stored in AL16UTF16 */
         v_select := v_select
            || format(
                  E'CASE WHEN convert(convert(%I, ''''AL16UTF16''''), (SELECT value FROM nls_database_parameters WHERE parameter = ''''NLS_CHARACTERSET''''), ''''AL16UTF16'''') <> %I THEN ''''invalid byte in %I '''' END',
                  v_column,
                  v_column,
                  v_column
               );

         v_where := v_where
            || format(
                  E'(convert(convert(%I, ''''AL16UTF16''''), (SELECT value FROM nls_database_parameters WHERE parameter = ''''NLS_CHARACTERSET''''), ''''AL16UTF16'''') <> %I)',
                  v_column,
                  v_column
               );
      END IF;
   END LOOP;

   /* if there is no string column, we are done */
   IF cardinality(v_where) = 0 THEN
      RETURN;
   END IF;

   DROP FOREIGN TABLE IF EXISTS pg_temp.oracle_errors;

   EXECUTE
      format(
         E'CREATE FOREIGN TABLE pg_temp.oracle_errors (\n'
         '   rowid   text NOT NULL,\n'
         '   message text NOT NULL\n'
         ') SERVER %I OPTIONS (\n'
         '   table E''(SELECT CAST(rowid AS varchar2(100)) AS row_id,\\n''\n'
         '         ''       %s AS message\\n''\n'
         '         ''FROM %I.%I\\n''\n'
         '         ''WHERE %s)'')',
         server,
         array_to_string(v_select, E'\\n''\n         ''       || '),
         v_schema,
         v_table,
         array_to_string(v_where, E'\\n''\n         ''   OR ')
      );

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN QUERY SELECT * FROM pg_temp.oracle_errors;
END;$$;

COMMENT ON FUNCTION oracle_test_table(name, name, name, name) IS
   'test an Oracle table for potential migration problems';

CREATE FUNCTION oracle_migrate_test_data(
   server         name,
   pgstage_schema name DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
) RETURNS bigint
   LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog AS
$$DECLARE
   extschema text;
   v_schema  text;
   v_table   text;
BEGIN
   /* set "search_path" to the PostgreSQL staging schema and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;

   /* purge the error detail log */
   TRUNCATE test_error;

   /* collect the errors from each table */
   FOR v_schema, v_table IN
      SELECT schema, table_name FROM tables
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas)
   LOOP
      INSERT INTO test_error
         (schema, table_name, rowid, message)
      SELECT v_schema,
             v_table,
             err.rowid,
             err.message
      FROM oracle_test_table(server, v_schema, v_table, pgstage_schema) AS err;
   END LOOP;

   /* add error summary to the statistics table */
   INSERT INTO test_error_stats
      (log_time, schema, table_name, errcount)
   SELECT current_timestamp,
          schema,
          table_name,
          count(*)
   FROM test_error
   GROUP BY schema, table_name;

   RETURN (SELECT sum(errcount)
           FROM test_error_stats
           WHERE log_time = current_timestamp);
END;$$;

COMMENT ON FUNCTION oracle_migrate_test_data(name, name, name[]) IS
   'test all Oracle table for potential migration problems';
