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
      '         ''''AURORA$JIS$UTILITY$'''', ''''AURORA$ORB$UNAUTHENTICATED'''', ''''BI'''',\n'
      '         ''''CTXSYS'''', ''''DBSNMP'''', ''''DIP'''', ''''DMSYS'''', ''''EXFSYS'''', ''''FLOWS_FILES'''',\n'
      '         ''''HR'''', ''''IX'''', ''''LBACSYS'''', ''''MDDATA'''', ''''MDSYS'''', ''''MGMT_VIEW'''',\n'
      '         ''''ODM'''', ''''ODM_MTR'''', ''''OE'''', ''''OLAPSYS'''', ''''ORACLE_OCM'''', ''''ORDDATA'''',\n'
      '         ''''ORDPLUGINS'''', ''''ORDSYS'''', ''''OSE$HTTP$ADMIN'''', ''''OUTLN'''', ''''PM'''',\n'
      '         ''''SCOTT'''', ''''SH'''', ''''SI_INFORMTN_SCHEMA'''', ''''SPATIAL_CSW_ADMIN_USR'''',\n'
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
         '   JOIN dba_tables tab\n'
         '      ON tab.owner = col.owner AND tab.table_name = col.table_name\n'
         'WHERE (col.owner, col.table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND (col.owner, col.table_name)\n'
         '     NOT IN (SELECT log_owner, log_table\n'
         '             FROM dba_mview_logs)\n'
         '  AND tab.temporary = ''''N''''\n'
         '  AND tab.secondary = ''''N''''\n'
         '  AND tab.nested    = ''''NO''''\n'
         '  AND tab.dropped   = ''''NO''''\n'
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

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION create_oraviews(name, name, integer) IS 'create Oracle foreign tables for the metadata of a foreign server';

CREATE FUNCTION oracle_tolower(text) RETURNS name
   /* this will silently truncate anything exceeding 63 bytes ...*/
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
'SELECT CASE WHEN $1 = upper($1) THEN lower($1)::name ELSE $1::name END';

COMMENT ON FUNCTION oracle_tolower(text) IS 'helper function to fold Oracle names to lower case';

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
   t name
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

      /* create a table and fill it */
      EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I)', s, t, s, ft);
      EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I', s, t, s, ft);

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
   END;

   RETURN FALSE;
END;$$;

COMMENT ON FUNCTION oracle_materialize(name, name) IS 'turn an Oracle foreign table into a PostgreSQL table';

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
   geom_type    text := 'text';
   expr         text;
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

   /* set "search_path" to the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I', extschema);

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
   PERFORM create_oraviews(server, staging_schema, max_long);

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Copy definitions to PostgreSQL staging schema "%" ...', pgstage_schema;
   SET LOCAL client_min_messages = warning;

   /* get the postgis geometry type if it exists */
   SELECT extnamespace::regnamespace::text || '.geometry' INTO geom_type
      FROM pg_catalog.pg_extension
      WHERE extname = 'postgis';

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

   /* create PostgreSQL "columns" tables */
   CREATE TABLE columns(
      schema        name         NOT NULL,
      table_name    name         NOT NULL,
      column_name   name         NOT NULL,
      oracle_name   varchar(128) NOT NULL,
      position      integer      NOT NULL,
      type_name     name         NOT NULL,
      oracle_type   varchar(128) NOT NULL,
      nullable      boolean      NOT NULL,
      default_value text
   );

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
         WHEN v_type = 'SDO_GEOMETRY' AND v_typschema = 'MDSYS' THEN n_type := geom_type;
         ELSE n_type := 'text';  -- cannot translate
      END CASE;

      /* try to translate default value */
      expr := replace(replace(lower(v_default),
                              'sysdate',
                              'current_date'),
                      'systimestamp',
                      'current_timestamp');

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
         );
   END LOOP;

   CLOSE c_col;

   /* constraints for the "columns" table */
   ALTER TABLE columns ADD PRIMARY KEY (schema, table_name, column_name);
   ALTER TABLE columns ADD UNIQUE (schema, table_name, column_name, position);

   /* copy "tables" table */
   CREATE TABLE tables (
      schema        name         NOT NULL,
      oracle_schema varchar(128) NOT NULL,
      table_name    name         NOT NULL,
      oracle_name   varchar(128) NOT NULL,
      migrate       boolean      NOT NULL DEFAULT TRUE
   );
   EXECUTE format(E'INSERT INTO tables (schema, oracle_schema, table_name, oracle_name)\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          schema,\n'
                   '          oracle_tolower(table_name),\n'
                   '          table_name\n'
                   '   FROM %I.tables\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE tables ADD PRIMARY KEY (schema, table_name);

   /* copy "checks" table */
   CREATE TABLE checks (
      schema          name    NOT NULL,
      table_name      name    NOT NULL,
      constraint_name name    NOT NULL,
      "deferrable"    boolean NOT NULL,
      deferred        boolean NOT NULL,
      condition       text    NOT NULL
   );
   EXECUTE format(E'INSERT INTO checks\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(constraint_name),\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          lower(condition)\n'
                   '   FROM %I.checks\n'
                   '   WHERE ($1 IS NULL OR schema =ANY ($1))\n'
                   '     AND condition !~ ''^"[^"]*" IS NOT NULL$''',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE checks ADD PRIMARY KEY (schema, table_name, constraint_name);

  /* copy "foreign_keys" table */
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
     remote_column   name    NOT NULL
   );
   EXECUTE format(E'INSERT INTO foreign_keys\n'
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
                   '   WHERE ($1 IS NULL OR schema =ANY ($1) AND remote_schema =ANY ($1))',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE foreign_keys ADD PRIMARY KEY (schema, table_name, constraint_name, position);

   /* copy "keys" table */
   CREATE TABLE keys (
      schema          name     NOT NULL,
      table_name      name     NOT NULL,
      constraint_name name     NOT NULL,
      "deferrable"    boolean  NOT NULL,
      deferred        boolean  NOT NULL,
      column_name     name     NOT NULL,
      position        integer  NOT NULL,
      is_primary      boolean  NOT NULL
   );
   EXECUTE format(E'INSERT INTO keys\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(constraint_name),\n'
                   '          "deferrable",\n'
                   '          deferred,\n'
                   '          oracle_tolower(column_name),\n'
                   '          position,\n'
                   '          is_primary\n'
                   '   FROM %I.keys\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE keys ADD PRIMARY KEY (schema, table_name, constraint_name, position);

   /* copy "views" table */
   CREATE TABLE views (
      schema     name NOT NULL,
      view_name  name NOT NULL,
      definition text NOT NULL
   );
   EXECUTE format(E'INSERT INTO views\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(view_name),\n'
                   '          definition\n'
                   '   FROM %I.views\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE views ADD PRIMARY KEY (schema, view_name);

   /* copy "functions" view */
   CREATE TABLE functions (
      schema         name    NOT NULL,
      function_name  name    NOT NULL,
      is_procedure   boolean NOT NULL,
      source         text    NOT NULL
   );
   EXECUTE format(E'INSERT INTO functions\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(function_name),\n'
                   '          is_procedure,\n'
                   '          source\n'
                   '   FROM %I.functions\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE functions ADD PRIMARY KEY (schema, function_name);

   /* copy "sequences" view */
   CREATE TABLE sequences (
      schema        name    NOT NULL,
      sequence_name name    NOT NULL,
      min_value     bigint,
      max_value     bigint,
      increment_by  bigint  NOT NULL,
      cyclical      boolean NOT NULL,
      cache_size    integer NOT NULL,
      last_value    bigint  NOT NULL
   );
   EXECUTE format(E'INSERT INTO sequences\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(sequence_name),\n'
                   '          adjust_to_bigint(min_value),\n'
                   '          adjust_to_bigint(max_value),\n'
                   '          adjust_to_bigint(increment_by),\n'
                   '          cyclical,\n'
                   '          GREATEST(cache_size, 1) AS cache_size,\n'
                   '          adjust_to_bigint(last_value)\n'
                   '   FROM %I.sequences\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE sequences ADD PRIMARY KEY (schema, sequence_name);

   /* copy "index_columns" view */
   CREATE TABLE index_columns (
      schema        name NOT NULL,
      table_name    name NOT NULL,
      index_name    name NOT NULL,
      uniqueness    boolean NOT NULL,
      position      integer NOT NULL,
      descend       boolean NOT NULL,
      is_expression boolean NOT NULL,
      column_name   text    NOT NULL
   );
   EXECUTE format(E'INSERT INTO index_columns\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(index_name),\n'
                   '          uniqueness,\n'
                   '          position,\n'
                   '          descend,\n'
                   '          is_expression,\n'
                   '          CASE WHEN is_expression THEN ''('' || lower(column_name) || '')'' ELSE oracle_tolower(column_name) END\n'
                   '   FROM %I.index_columns\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE index_columns ADD PRIMARY KEY (schema, index_name, position);

   /* copy "schemas" table */
   CREATE TABLE schemas (
      schema name NOT NULL
   );
   EXECUTE format(E'INSERT INTO schemas\n'
                   '   SELECT oracle_tolower(schema)\n'
                   '   FROM %I.schemas\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE schemas ADD PRIMARY KEY (schema);

   /* copy "triggers" view */
   CREATE TABLE triggers (
      schema            name         NOT NULL,
      table_name        name         NOT NULL,
      trigger_name      name         NOT NULL,
      is_before         boolean      NOT NULL,
      triggering_event  varchar(227) NOT NULL,
      for_each_row      boolean      NOT NULL,
      when_clause       text,
      referencing_names name         NOT NULL,
      trigger_body      text         NOT NULL
   );
   EXECUTE format(E'INSERT INTO triggers\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(trigger_name),\n'
                   '          is_before,\n'
                   '          triggering_event,\n'
                   '          for_each_row,\n'
                   '          when_clause,\n'
                   '          referencing_names,\n'
                   '          trigger_body\n'
                   '   FROM %I.triggers\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE triggers ADD PRIMARY KEY (schema, table_name, trigger_name);

   /* copy "packages" view */
   CREATE TABLE packages (
      schema       name    NOT NULL,
      package_name name    NOT NULL,
      is_body      boolean NOT NULL,
      source       text    NOT NULL
   );
   EXECUTE format(E'INSERT INTO packages\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(package_name),\n'
                   '          is_body,\n'
                   '          source\n'
                   '   FROM %I.packages\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE packages ADD PRIMARY KEY (schema, package_name, is_body);

   /* copy "table_privs" table */
   CREATE TABLE table_privs (
      schema     name        NOT NULL,
      table_name name        NOT NULL,
      privilege  varchar(40) NOT NULL,
      grantor    name        NOT NULL,
      grantee    name        NOT NULL,
      grantable  boolean     NOT NULL
   );
   EXECUTE format(E'INSERT INTO table_privs\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          privilege,\n'
                   '          oracle_tolower(grantor),\n'
                   '          oracle_tolower(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.table_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE table_privs ADD PRIMARY KEY (schema, table_name, grantee, privilege);

   /* copy "column_privs" table */
   CREATE TABLE column_privs (
      schema      name        NOT NULL,
      table_name  name        NOT NULL,
      column_name name        NOT NULL,
      privilege   varchar(40) NOT NULL,
      grantor     name        NOT NULL,
      grantee     name        NOT NULL,
      grantable   boolean     NOT NULL
   );
   EXECUTE format(E'INSERT INTO column_privs\n'
                   '   SELECT oracle_tolower(schema),\n'
                   '          oracle_tolower(table_name),\n'
                   '          oracle_tolower(column_name),\n'
                   '          privilege,\n'
                   '          oracle_tolower(grantor),\n'
                   '          oracle_tolower(grantee),\n'
                   '          grantable\n'
                   '   FROM %I.column_privs\n'
                   '   WHERE $1 IS NULL OR schema =ANY ($1)',
                  staging_schema)
      USING only_schemas;
   ALTER TABLE column_privs ADD PRIMARY KEY (schema, table_name, column_name, grantee, privilege);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN 0;
END;$$;

COMMENT ON FUNCTION oracle_migrate_prepare(name, name, name, name[], integer) IS 'first step of "oracle_migrate": create and populate staging schemas';

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

            rc := rc + 1;
      END;
   END IF;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_mkforeign(name, name, name, name[], integer) IS 'second step of "oracle_migrate": create schemas, sequemces and foreign tables';

CREATE FUNCTION oracle_migrate_tables(
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL
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
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas)
   LOOP
      EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
      RAISE NOTICE 'Migrating table %.% ...', sch, tab;
      SET LOCAL client_min_messages = warning;

      /* turn that foreign table into a real table */
      IF NOT oracle_materialize(sch, tab) THEN
         rc := rc + 1;
         /* remove the foreign table if it failed */
         EXECUTE format('DROP FOREIGN TABLE %I.%I', sch, tab);
      END IF;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_tables(name, name, name[]) IS 'third step of "oracle_migrate": copy tables from Oracle';

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

            rc := rc + 1;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RETURN rc;
END;$$;

COMMENT ON FUNCTION oracle_migrate_constraints(name, name[]) IS 'third step of "oracle_migrate": create constraints and indexes';

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

COMMENT ON FUNCTION oracle_migrate_finish(name, name) IS 'final step of "oracle_migrate": drop staging schema';

CREATE FUNCTION oracle_migrate(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_stage',
   pgstage_schema name    DEFAULT NAME 'pgsql_stage',
   only_schemas   name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
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
   rc := rc + oracle_migrate_tables(staging_schema, pgstage_schema, only_schemas);

   /*
    * Fourth step:
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

COMMENT ON FUNCTION oracle_migrate(name, name, name, name[], integer) IS 'migrate an Oracle database from a foreign server to PostgreSQL';
