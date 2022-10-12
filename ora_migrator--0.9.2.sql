/* tools for Oracle to PostgreSQL migration */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION ora_migrator" to load this file. \quit

CREATE FUNCTION create_oraviews(
   server      name,
   schema      name    DEFAULT NAME 'public',
   options     jsonb   DEFAULT NULL
) RETURNS void
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;
   v_max_long   integer := 32767;

   sys_schemas text :=
      E'''''ANONYMOUS'''', ''''APEX_PUBLIC_USER'''', ''''APEX_030200'''', ''''APEX_040000'''',\n'
      '         ''''APEX_050000'''', ''''APPQOSSYS'''', ''''AUDSYS'''', ''''AURORA$JIS$UTILITY$'''',\n'
      '         ''''AURORA$ORB$UNAUTHENTICATED'''', ''''CTXSYS'''', ''''DBSFWUSER'''', ''''DBSNMP'''',\n'
      '         ''''DIP'''', ''''DMSYS'''', ''''DVSYS'''', ''''DVF'''', ''''EXFSYS'''',\n'
      '         ''''FLOWS_30000'''', ''''FLOWS_FILES'''', ''''GDOSYS'''', ''''GGSYS'''',\n'
      '         ''''GSMADMIN_INTERNAL'''', ''''GSMCATUSER'''', ''''GSMUSER'''', ''''LBACSYS'''',\n'
      '         ''''MDDATA'''', ''''MDSYS'''', ''''MGMT_VIEW'''', ''''ODM'''', ''''ODM_MTR'''',\n'
      '         ''''OJVMSYS'''', ''''OLAPSYS'''', ''''ORACLE_OCM'''', ''''ORDDATA'''',\n'
      '         ''''ORDPLUGINS'''', ''''ORDSYS'''', ''''OSE$HTTP$ADMIN'''', ''''OUTLN'''',\n'
      '         ''''PDBADMIN'''', ''''REMOTE_SCHEDULER_AGENT'''', ''''SI_INFORMTN_SCHEMA'''',\n'
      '         ''''SPATIAL_WFS_ADMIN_USR'''', ''''SPATIAL_CSW_ADMIN_USR'''', ''''SPATIAL_WFS_ADMIN_USR'''',\n'
      '         ''''SYS'''', ''''SYS$UMF'''', ''''SYSBACKUP'''', ''''SYSDG'''', ''''SYSKM'''',\n'
      '         ''''SYSMAN'''', ''''SYSRAC'''', ''''SYSTEM'''', ''''TRACESRV'''',\n'
      '         ''''MTSSYS'''', ''''OASPUBLIC'''', ''''OLAPSYS'''', ''''OWBSYS'''', ''''OWBSYS_AUDIT'''',\n'
      '         ''''PERFSTAT'''', ''''WEBSYS'''', ''''WK_PROXY'''', ''''WKSYS'''', ''''WK_TEST'''',\n'
      '         ''''WMSYS'''', ''''XDB'''', ''''XS$NULL''''';

   tables_sql text := E'CREATE FOREIGN TABLE %I.tables (\n'
      '   schema     text NOT NULL,\n'
      '   table_name text NOT NULL\n'
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
      '   schema        text    NOT NULL,\n'
      '   table_name    text    NOT NULL,\n'
      '   column_name   text    NOT NULL,\n'
      '   position      integer NOT NULL,\n'
      '   type_name     text    NOT NULL,\n'
      '   length        integer NOT NULL,\n'
      '   precision     integer,\n'
      '   scale         integer,\n'
      '   nullable      boolean NOT NULL,\n'
      '   default_value text\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT col.owner,\n'
         '       col.table_name,\n'
         '       col.column_name,\n'
         '       col.column_id,\n'
         '       CASE WHEN col.data_type_owner IS NULL\n'
         '            THEN col.data_type\n'
         '            ELSE col.data_type_owner || ''''.'''' || col.data_type\n'
         '       END data_type,\n'
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
      '   schema          text    NOT NULL,\n'
      '   table_name      text    NOT NULL,\n'
      '   constraint_name text    NOT NULL,\n'
      '   "deferrable"    boolean NOT NULL,\n'
      '   deferred        boolean NOT NULL,\n'
      '   condition       text    NOT NULL\n'
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
      '   schema          text    NOT NULL,\n'
      '   table_name      text    NOT NULL,\n'
      '   constraint_name text    NOT NULL,\n'
      '   "deferrable"    boolean NOT NULL,\n'
      '   deferred        boolean NOT NULL,\n'
      '   delete_rule     text    NOT NULL,\n'
      '   column_name     text    NOT NULL,\n'
      '   position        integer NOT NULL,\n'
      '   remote_schema   text    NOT NULL,\n'
      '   remote_table    text    NOT NULL,\n'
      '   remote_column   text    NOT NULL\n'
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
      '   schema          text    NOT NULL,\n'
      '   table_name      text    NOT NULL,\n'
      '   constraint_name text    NOT NULL,\n'
      '   "deferrable"    boolean NOT NULL,\n'
      '   deferred        boolean NOT NULL,\n'
      '   column_name     text    NOT NULL,\n'
      '   position        integer NOT NULL,\n'
      '   is_primary      boolean NOT NULL\n'
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
      '   schema     text NOT NULL,\n'
      '   view_name  text NOT NULL,\n'
      '   definition text NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       view_name,\n'
         '       text\n'
         'FROM dba_views\n'
         'WHERE owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   func_src_sql text := E'CREATE FOREIGN TABLE %I.func_src (\n'
      '   schema        text    NOT NULL,\n'
      '   function_name text    NOT NULL,\n'
      '   is_procedure  boolean NOT NULL,\n'
      '   line_number   integer NOT NULL,\n'
      '   line          text    NOT NULL\n'
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
      '   schema        text        NOT NULL,\n'
      '   sequence_name text        NOT NULL,\n'
      '   min_value     numeric(28),\n'
      '   max_value     numeric(28),\n'
      '   increment_by  numeric(28) NOT NULL,\n'
      '   cyclical      boolean     NOT NULL,\n'
      '   cache_size    integer     NOT NULL,\n'
      '   last_value    numeric(28) NOT NULL\n'
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
      '   schema         text    NOT NULL,\n'
      '   table_name     text    NOT NULL,\n'
      '   index_name     text    NOT NULL,\n'
      '   uniqueness     boolean NOT NULL,\n'
      '   position       integer NOT NULL,\n'
      '   descend        boolean NOT NULL,\n'
      '   col_name       text    NOT NULL,\n'
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
         '     dba_tables t,\n'
         '     dba_ind_columns ic,\n'
         '     dba_ind_expressions ie\n'
         'WHERE i.table_owner      = t.owner\n'
         '  AND i.table_name       = t.table_name\n'
         '  AND i.owner            = ic.index_owner\n'
         '  AND i.index_name       = ic.index_name\n'
         '  AND i.table_owner      = ic.table_owner\n'
         '  AND i.table_name       = ic.table_name\n'
         '  AND ic.index_owner     = ie.index_owner(+)\n'
         '  AND ic.index_name      = ie.index_name(+)\n'
         '  AND ic.table_owner     = ie.table_owner(+)\n'
         '  AND ic.table_name      = ie.table_name(+)\n'
         '  AND ic.column_position = ie.column_position(+)\n'
         '  AND t.temporary        = ''''N''''\n'
         '  AND t.secondary        = ''''N''''\n'
         '  AND t.nested           = ''''NO''''\n'
         '  AND t.dropped          = ''''NO''''\n'
         '  AND i.index_type NOT IN (''''LOB'''', ''''DOMAIN'''')\n'
         '  AND coalesce(i.dropped, ''''NO'''') = ''''NO''''\n'
         '  AND NOT EXISTS (SELECT 1  /* exclude constraint indexes */\n'
         '                  FROM dba_constraints c\n'
         '                  WHERE c.owner = i.table_owner\n'
         '                    AND c.table_name = i.table_name\n'
         '                    AND COALESCE(c.index_owner, i.owner) = i.owner\n'
         '                    AND c.index_name = i.index_name)\n'
         '  AND NOT EXISTS (SELECT 1  /* exclude materialized views */\n'
         '                  FROM dba_mviews m\n'
         '                  WHERE m.owner = i.table_owner\n'
         '                    AND m.mview_name = i.table_name)\n'
         '  AND NOT EXISTS (SELECT 1  /* exclude materialized views logs */\n'
         '                  FROM dba_mview_logs ml\n'
         '                  WHERE ml.log_owner = i.table_owner\n'
         '                    AND ml.log_table = i.table_name)\n'
         '  AND ic.table_owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   index_columns_sql text := E'CREATE VIEW %I.index_columns AS\n'
      'SELECT schema,\n'
      '       table_name,\n'
      '       index_name,\n'
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
      'FROM %I.index_exp';

   indexes_sql text := E'CREATE VIEW %I.indexes AS\n'
      'SELECT DISTINCT\n'
      '       schema,\n'
      '       table_name,\n'
      '       index_name,\n'
      '       uniqueness\n'
      'FROM %I.index_exp';

   schemas_sql text := E'CREATE FOREIGN TABLE %I.schemas (\n'
      '   schema text NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT username\n'
         'FROM dba_users\n'
         'WHERE username NOT IN( ' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   trig_sql text := E'CREATE FOREIGN TABLE %I.trig (\n'
      '   schema            text NOT NULL,\n'
      '   table_name        text NOT NULL,\n'
      '   trigger_name      text NOT NULL,\n'
      '   trigger_type      text NOT NULL,\n'
      '   triggering_event  text NOT NULL,\n'
      '   when_clause       text,\n'
      '   referencing_names text NOT NULL,\n'
      '   trigger_body      text NOT NULL\n'
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
      '       CASE WHEN trigger_type LIKE ''BEFORE %%''\n'
      '            THEN ''BEFORE''\n'
      '            WHEN trigger_type LIKE ''AFTER %%''\n'
      '            THEN ''AFTER''\n'
      '            ELSE trigger_type\n'
      '       END AS trigger_type,\n'
      '       triggering_event,\n'
      '       trigger_type LIKE ''%%EACH ROW'' AS for_each_row,\n'
      '       when_clause,\n'
      '       referencing_names,\n'
      '       trigger_body\n'
      'FROM %I.trig';

   pack_src_sql text := E'CREATE FOREIGN TABLE %I.pack_src (\n'
      '   schema       text    NOT NULL,\n'
      '   package_name text    NOT NULL,\n'
      '   src_type     text    NOT NULL,\n'
      '   line_number  integer NOT NULL,\n'
      '   line         text    NOT NULL\n'
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
      '   schema     text    NOT NULL,\n'
      '   table_name text    NOT NULL,\n'
      '   privilege  text    NOT NULL,\n'
      '   grantor    text    NOT NULL,\n'
      '   grantee    text    NOT NULL,\n'
      '   grantable  boolean NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       p.privilege,\n'
         '       p.grantor,\n'
         '       p.grantee,\n'
         '       CASE WHEN p.grantable = ''''YES'''' THEN 1 ELSE 0 END grantable\n'
         'FROM dba_tab_privs p\n'
         '   JOIN dba_tables t USING (owner, table_name)\n'
         'WHERE t.temporary = ''''N''''\n'
         '  AND t.secondary = ''''N''''\n'
         '  AND t.nested    = ''''NO''''\n'
         '  AND coalesce(t.dropped, ''''NO'''') = ''''NO''''\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT log_owner, log_table\n'
         '             FROM dba_mview_logs)\n'
         '  AND owner NOT IN (' || sys_schemas || E')\n'
         '  AND p.grantor NOT IN (' || sys_schemas || E')\n'
         '  AND p.grantee NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   column_privs_sql text := E'CREATE FOREIGN TABLE %I.column_privs (\n'
      '   schema      text    NOT NULL,\n'
      '   table_name  text    NOT NULL,\n'
      '   column_name text    NOT NULL,\n'
      '   privilege   text    NOT NULL,\n'
      '   grantor     text    NOT NULL,\n'
      '   grantee     text    NOT NULL,\n'
      '   grantable   boolean NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       table_name,\n'
         '       c.column_name,\n'
         '       c.privilege,\n'
         '       c.grantor,\n'
         '       c.grantee,\n'
         '       CASE WHEN c.grantable = ''''YES'''' THEN 1 ELSE 0 END grantable\n'
         'FROM dba_col_privs c\n'
         '   JOIN dba_tables t USING (owner, table_name)\n'
         'WHERE t.temporary = ''''N''''\n'
         '  AND t.secondary = ''''N''''\n'
         '  AND t.nested    = ''''NO''''\n'
         '  AND t.dropped   = ''''NO''''\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT owner, mview_name\n'
         '             FROM dba_mviews)\n'
         '  AND (owner, table_name)\n'
         '     NOT IN (SELECT log_owner, log_table\n'
         '             FROM dba_mview_logs)\n'
         '  AND owner NOT IN (' || sys_schemas || E')\n'
         '  AND c.grantor NOT IN (' || sys_schemas || E')\n'
         '  AND c.grantee NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   segments_sql text := E'CREATE FOREIGN TABLE %I.segments (\n'
      '   schema       text   NOT NULL,\n'
      '   segment_name text   NOT NULL,\n'
      '   segment_type text   NOT NULL,\n'
      '   bytes        bigint NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT owner,\n'
         '       segment_name,\n'
         '       segment_type,\n'
         '       bytes\n'
         'FROM dba_segments\n'
         'WHERE owner NOT IN (' || sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   migration_cost_estimate_sql text := E'CREATE VIEW %I.migration_cost_estimate AS\n'
      '   SELECT schema,\n'
      '          ''tables''::text   AS task_type,\n'
      '          count(*)::bigint AS task_content,\n'
      '          ''count''::text    AS task_unit,\n'
      '          ceil(count(*) / 10.0)::integer AS migration_hours\n'
      '   FROM %I.tables\n'
      '   GROUP BY schema\n'
      'UNION ALL\n'
      '   SELECT t.schema,\n'
      '          ''data_migration''::text,\n'
      '          sum(bytes)::bigint,\n'
      '          ''bytes''::text,\n'
      '          ceil(sum(bytes::float8) / 26843545600.0)::integer\n'
      '   FROM %I.segments AS s\n'
      '      JOIN %I.tables AS t\n'
      '         ON s.schema = t.schema\n'
      '            AND s.segment_name = t.table_name\n'
      '   WHERE s.segment_type = ''TABLE''\n'
      '   GROUP BY t.schema\n'
      'UNION ALL\n'
      '   SELECT schema,\n'
      '          ''functions'',\n'
      '          coalesce(sum(octet_length(source)), 0),\n'
      '          ''characters''::text,\n'
      '          ceil(coalesce(sum(octet_length(source)), 0) / 512.0)::integer\n'
      '   FROM %I.functions\n'
      '   GROUP BY schema\n'
      'UNION ALL\n'
      '   SELECT schema,\n'
      '          ''triggers'',\n'
      '          coalesce(sum(octet_length(trigger_body)), 0),\n'
      '          ''characters''::text,\n'
      '          ceil(coalesce(sum(octet_length(trigger_body)), 0) / 512.0)::integer\n'
      '   FROM %I.triggers\n'
      '   GROUP BY schema\n'
      'UNION ALL\n'
      '   SELECT schema,\n'
      '          ''packages'',\n'
      '          coalesce(sum(octet_length(source)), 0),\n'
      '          ''characters''::text,\n'
      '          ceil(coalesce(sum(octet_length(source)), 0) / 512.0)::integer\n'
      '   FROM %I.packages\n'
      '   WHERE is_body\n'
      '   GROUP BY schema\n'
      'UNION ALL\n'
      '   SELECT schema,\n'
      '          ''views'',\n'
      '          coalesce(sum(octet_length(definition)), 0),\n'
      '          ''characters''::text,\n'
      '          ceil(coalesce(sum(octet_length(definition)), 0) / 512.0)::integer\n'
      '   FROM %I.views\n'
      '   GROUP BY schema';

   test_error_sql text := E'CREATE TABLE %I.test_error (\n'
      '   log_time   timestamp with time zone NOT NULL DEFAULT current_timestamp,\n'
      '   schema     name                     NOT NULL,\n'
      '   table_name name                     NOT NULL,\n'
      '   rowid      text                     NOT NULL,\n'
      '   message    text                     NOT NULL,\n'
      '   PRIMARY KEY (schema, table_name, log_time, rowid)\n'
      ')';

   test_error_stats_sql text := E'CREATE TABLE %I.test_error_stats (\n'
      '   log_time   timestamp with time zone NOT NULL,\n'
      '   schema     name                     NOT NULL,\n'
      '   table_name name                     NOT NULL,\n'
      '   errcount   bigint                   NOT NULL,\n'
      '   PRIMARY KEY (schema, table_name, log_time)\n'
      ')';

BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   IF options ? 'max_long' THEN
      v_max_long := (options->>'max_long')::integer;
   END IF;

   /* tables */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.tables', schema);
   EXECUTE format(tables_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.tables IS ''Oracle tables on foreign server "%I"''', schema, server);
   /* columns */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.columns', schema);
   EXECUTE format(columns_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.columns IS ''columns of Oracle tables and views on foreign server "%I"''', schema, server);
   /* checks */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.checks', schema);
   EXECUTE format(checks_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.checks IS ''Oracle check constraints on foreign server "%I"''', schema, server);
   /* foreign_keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.foreign_keys', schema);
   EXECUTE format(foreign_keys_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.foreign_keys IS ''Oracle foreign key columns on foreign server "%I"''', schema, server);
   /* keys */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.keys', schema);
   EXECUTE format(keys_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.keys IS ''Oracle primary and unique key columns on foreign server "%I"''', schema, server);
   /* views */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.views', schema);
   EXECUTE format(views_sql, schema, server, v_max_long);
   /* func_src and functions */
   EXECUTE format('DROP VIEW IF EXISTS %I.functions', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.func_src', schema);
   EXECUTE format(func_src_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.func_src IS ''source lines for Oracle functions and procedures on foreign server "%I"''', schema, server);
   EXECUTE format(functions_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.functions IS ''Oracle functions and procedures on foreign server "%I"''', schema, server);
   /* sequences */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.sequences', schema);
   EXECUTE format(sequences_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.sequences IS ''Oracle sequences on foreign server "%I"''', schema, server);
   /* index_exp and index_columns */
   EXECUTE format('DROP VIEW IF EXISTS %I.index_columns', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.index_exp', schema);
   EXECUTE format(index_exp_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.index_exp IS ''Oracle index columns on foreign server "%I"''', schema, server);
   EXECUTE format(index_columns_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.index_columns IS ''Oracle index columns on foreign server "%I"''', schema, server);
   /* indexes */
   EXECUTE format('DROP VIEW IF EXISTS %I.indexes', schema);
   EXECUTE format(indexes_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.indexes IS ''Oracle indexes on foreign server "%I"''', schema, server);
   /* schemas */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.schemas', schema);
   EXECUTE format(schemas_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.schemas IS ''Oracle schemas on foreign server "%I"''', schema, server);
   /* trig and triggers */
   EXECUTE format('DROP VIEW IF EXISTS %I.triggers', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.trig', schema);
   EXECUTE format(trig_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.trig IS ''Oracle triggers on foreign server "%I"''', schema, server);
   EXECUTE format(triggers_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.triggers IS ''Oracle triggers on foreign server "%I"''', schema, server);
   /* pack_src and packages */
   EXECUTE format('DROP VIEW IF EXISTS %I.packages', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.pack_src', schema);
   EXECUTE format(pack_src_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.pack_src IS ''Oracle package source lines on foreign server "%I"''', schema, server);
   EXECUTE format(packages_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.packages IS ''Oracle packages on foreign server "%I"''', schema, server);
   /* table_privs */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.table_privs', schema);
   EXECUTE format(table_privs_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.table_privs IS ''Privileges on Oracle tables on foreign server "%I"''', schema, server);
   /* column_privs */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.column_privs', schema);
   EXECUTE format(column_privs_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.column_privs IS ''Privileges on Oracle table columns on foreign server "%I"''', schema, server);
   /* segments */
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.segments', schema);
   EXECUTE format(segments_sql, schema, server, v_max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.segments IS ''Size of Oracle objects on foreign server "%I"''', schema, server);
   /* migration_cost_estimate */
   EXECUTE format('DROP VIEW IF EXISTS %I.migration_cost_estimate', schema);
   EXECUTE format(migration_cost_estimate_sql, schema, schema, schema, schema, schema, schema, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.migration_cost_estimate IS ''Estimate of the migration costs per schema and object type''', schema);
   /* test_error */
   EXECUTE format('DROP TABLE IF EXISTS %I.test_error', schema);
   EXECUTE format(test_error_sql, schema);
   EXECUTE format('COMMENT ON TABLE %I.test_error IS ''Errors from the last run of "oracle_migrate_test_data"''', schema);
   /* test_error_stats */
   EXECUTE format('DROP TABLE IF EXISTS %I.test_error_stats', schema);
   EXECUTE format(test_error_stats_sql, schema);
   EXECUTE format('COMMENT ON TABLE %I.test_error_stats IS ''Cumulative errors from previous runs of "oracle_migrate_test_data"''', schema);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION create_oraviews(name, name, jsonb) IS
   'create Oracle foreign tables for the metadata of a foreign server';

/* this will silently truncate anything exceeding 63 bytes ...*/
CREATE FUNCTION oracle_tolower(text) RETURNS name
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
'SELECT CASE WHEN $1 = upper($1) THEN lower($1)::name ELSE $1::name END';

COMMENT ON FUNCTION oracle_tolower(text) IS
   'helper function to fold Oracle names to lower case';

CREATE FUNCTION oracle_translate_expression(s text) RETURNS text
   LANGUAGE plpgsql IMMUTABLE STRICT SET search_path FROM CURRENT AS
$$DECLARE
   r text;
BEGIN
   /* translate identifiers to lower case */
   FOR r IN
      SELECT idents[1]
      FROM regexp_matches(s, '"([^"]*)"', 'g') AS idents
   LOOP
      s := replace(s, '"' || r || '"', '"' || oracle_tolower(r) || '"' );
   END LOOP;
   /*
    * Replace SYSDATE and SYSTIMESTAMP.
    * For the latter, "clock_timestamp()" would be more accurate, but
    * I think that "current_timestamp" is usually preferable.  This is
    * perhaps an unfounded personal opinion, but this function lays no
    * claim for completeness and total accuracy anyway.
    */
   s := regexp_replace(s, '\msysdate\M', 'current_date', 'gi');
   s := regexp_replace(s, '\msystimestamp\M', 'current_timestamp', 'gi');
   /*
    * Translate NEXTVAL from a pseudo-column to a function call.
    * We don't have to worry about a double quote in an identifier,
    * because Oracle doesn't support that anyway.
    */
   s := regexp_replace(s, '"([^"]*)"\."([^"]*)"\."nextval"',
                          'nextval(''"\1"."\2"'')', 'gi');

   RETURN s;
END;$$;

COMMENT ON FUNCTION oracle_translate_expression(text) IS
   'helper function to translate Oracle SQL expressions to PostgreSQL';

CREATE FUNCTION oracle_translate_datatype(
   v_type text,
   v_length integer,
   v_precision integer,
   v_scale integer
) RETURNS text
   LANGUAGE plpgsql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   v_geom_type text;
BEGIN
   /* get the postgis geometry type if it exists */
   SELECT extnamespace::regnamespace::text || '.geometry' INTO v_geom_type
      FROM pg_catalog.pg_extension
      WHERE extname = 'postgis';
   IF v_geom_type IS NULL THEN v_geom_type := 'text'; END IF;

   /* get the PostgreSQL type */
   CASE
      WHEN v_type = 'VARCHAR2'  THEN RETURN 'character varying(' || v_length || ')';
      WHEN v_type = 'NVARCHAR2' THEN RETURN 'character varying(' || v_length || ')';
      WHEN v_type = 'CHAR'      THEN RETURN 'character(' || v_length || ')';
      WHEN v_type = 'NCHAR'     THEN RETURN 'character(' || v_length || ')';
      WHEN v_type = 'CLOB'      THEN RETURN 'text';
      WHEN v_type = 'LONG'      THEN RETURN 'text';
      WHEN v_type = 'NUMBER'    THEN
         IF v_precision IS NULL THEN RETURN 'numeric';
         ELSIF v_scale = 0  THEN
            IF v_precision < 5     THEN RETURN 'smallint';
            ELSIF v_precision < 10 THEN RETURN 'integer';
            ELSIF v_precision < 19 THEN RETURN 'bigint';
            ELSE RETURN 'numeric(' || v_precision || ')';
            END IF;
         ELSE RETURN 'numeric(' || v_precision || ', ' || v_scale || ')';
         END IF;
      WHEN v_type = 'FLOAT' THEN
         IF v_precision < 54 THEN RETURN 'float(' || v_precision || ')';
         ELSE RETURN 'numeric';
         END IF;
      WHEN v_type = 'BINARY_FLOAT'  THEN RETURN 'real';
      WHEN v_type = 'BINARY_DOUBLE' THEN RETURN 'double precision';
      WHEN v_type = 'RAW'           THEN RETURN 'bytea';
      WHEN v_type = 'BLOB'          THEN RETURN 'bytea';
      WHEN v_type = 'BFILE'         THEN RETURN 'bytea';
      WHEN v_type = 'LONG RAW'      THEN RETURN 'bytea';
      WHEN v_type = 'DATE'          THEN RETURN 'timestamp(0) without time zone';
      WHEN substr(v_type, 1, 9) = 'TIMESTAMP' THEN
         IF length(v_type) < 17 THEN RETURN 'timestamp(' || least(v_scale, 6) || ') without time zone';
         ELSE RETURN 'timestamp(' || least(v_scale, 6) || ') with time zone';
         END IF;
      WHEN substr(v_type, 1, 8) = 'INTERVAL' THEN
         IF substr(v_type, 10, 3) = 'DAY' THEN RETURN 'interval(' || least(v_scale, 6) || ')';
         ELSE RETURN 'interval(0)';
         END IF;
      WHEN v_type = 'SYS.XMLTYPE' OR v_type = 'PUBLIC.XMLTYPE' THEN RETURN 'xml';
      WHEN v_type = 'MDSYS.SDO_GEOMETRY' THEN RETURN v_geom_type;
      ELSE RETURN 'text';  -- cannot translate
   END CASE;
END;$$;

COMMENT ON FUNCTION oracle_translate_datatype(text,integer,integer,integer) IS
   'translates an Oracle data type to a PostgreSQL data type';

CREATE FUNCTION oracle_mkforeign(
   server         name,
   schema         name,
   table_name     name,
   orig_schema    text,
   orig_table     text,
   column_names   name[],
   column_options jsonb[],
   orig_columns   text[],
   data_types     text[],
   nullable       boolean[],
   options        jsonb
) RETURNS text
   LANGUAGE plpgsql IMMUTABLE CALLED ON NULL INPUT AS
$$DECLARE
   stmt       text;
   i          integer;
   sep        text := '';
   colopt_str text;
BEGIN
   stmt := format(E'CREATE FOREIGN TABLE %I.%I (', schema, table_name);

   FOR i IN 1..cardinality(column_names) LOOP
      /* format the column options as string */
      SELECT ' OPTIONS (' ||
             string_agg(format('%I %L', j.key, j.value->>0), ', ') ||
             ')'
         INTO colopt_str
      FROM jsonb_each(column_options[i]) AS j;

      stmt := stmt || format(E'%s\n   %I %s%s%s',
                         sep, column_names[i], data_types[i],
                         coalesce(colopt_str, ''),
                         CASE WHEN nullable[i] THEN '' ELSE ' NOT NULL' END
                      );
      sep := ',';
   END LOOP;

   RETURN stmt || format(
                     E') SERVER %I\n'
                     '   OPTIONS (schema ''%s'', table ''%s'', readonly ''true'', max_long ''%s'')',
                     server, orig_schema, orig_table,
                     CASE WHEN options ? 'max_long'
                          THEN (options->>'max_long')::bigint
                          ELSE 32767
                     END
                  );
END;$$;

COMMENT ON FUNCTION oracle_mkforeign(name,name,name,text,text,name[],jsonb[],text[],text[],boolean[],jsonb) IS
   'construct a CREATE FOREIGN TABLE statement based on the input data';

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
      SELECT s.orig_schema AS schema,
             t.orig_table AS table_name,
             c.orig_column AS column_name,
             c.orig_type
      FROM schemas AS s
         JOIN tables AS t USING (schema)
         JOIN columns AS c USING (schema, table_name)
      WHERE t.schema = $2
        AND t.table_name = $3
        /* unfortunately our trick doesn't work for CLOB */
        AND c.orig_type ~~ ANY (ARRAY['VARCHAR2%', 'NVARCHAR2%', 'CHAR%', 'NCHAR%', 'VARCHAR%'])
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
   staging_schema name   DEFAULT NAME 'fdw_stage',
   pgstage_schema name   DEFAULT NAME 'pgsql_stage',
   only_schemas   name[] DEFAULT NULL
) RETURNS bigint
   LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog AS
$$DECLARE
   extschema text;
   v_schema  text;
   v_table   text;
   v_result  bigint;
BEGIN
   /* set "search_path" to the FDW staging schema and the extension schema */
   SELECT extnamespace::regnamespace::text INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %s', pgstage_schema, extschema);

   /* translate schema names to lower case */
   only_schemas := array_agg(oracle_tolower(os)) FROM unnest(only_schemas) os;

   /* purge the error detail log */
   EXECUTE format('TRUNCATE %I.test_error', staging_schema);

   /* collect the errors from each table */
   FOR v_schema, v_table IN
      SELECT schema, table_name FROM tables
      WHERE only_schemas IS NULL
         OR schema =ANY (only_schemas)
   LOOP
      EXECUTE
         format(
            E'INSERT INTO %I.test_error\n'
            '   (schema, table_name, rowid, message)\n'
            'SELECT $1,\n'
            '       $2,\n'
            '       err.rowid,\n'
            '       err.message\n'
            'FROM oracle_test_table($3, $4, $5, $6) AS err',
            staging_schema
         )
      USING v_schema, v_table, server, v_schema, v_table, pgstage_schema;
   END LOOP;

   /* add error summary to the statistics table */
   EXECUTE
      format(
         E'INSERT INTO %I.test_error_stats\n'
         '   (log_time, schema, table_name, errcount)\n'
         'SELECT current_timestamp,\n'
         '       schema,\n'
         '       table_name,\n'
         '       count(*)\n'
         'FROM %I.test_error\n'
         'GROUP BY schema, table_name',
         staging_schema,
         staging_schema
      );

   EXECUTE
      format(
         E'SELECT sum(errcount)\n'
         'FROM %I.test_error_stats\n'
         'WHERE log_time = current_timestamp',
         staging_schema
      )
   INTO v_result;

   RETURN v_result;
END;$$;

COMMENT ON FUNCTION oracle_migrate_test_data(name,name,name,name[]) IS
   'test all Oracle table for potential migration problems';

CREATE FUNCTION oracle_replication_start(
   server         name,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS void LANGUAGE plpgsql STRICT SET search_path = pg_catalog AS
$$DECLARE
   v_old_path        text;
   v_fdw_extschema   text;
   v_tabname         text;
   v_tabschema       text;
   v_colname         text;
   v_type            text;
   v_orig_schema     text;
   v_orig_table      text;
   v_orig_column     text;
   v_orig_type       text;
   v_is_pkey         boolean;
   v_create_logtable text;
   v_pkey_list       text;
   v_upd_col_list    text;
   v_upd_col_sep     text;
   v_col_list        text;
   v_new_col_list    text;
   v_old_col_list    text;
   v_create_foreign  text;
BEGIN
   /* remember old setting and set search_path */
   v_old_path := current_setting('search_path');

   EXECUTE format('SET LOCAL search_path = %I', pgstage_schema);

   SELECT extnamespace::regnamespace::text INTO v_fdw_extschema
   FROM pg_extension
   WHERE extname = 'oracle_fdw';

   /* create a foreign table for the oldest active Oracle transaction */
   EXECUTE
      format(
         E'CREATE FOREIGN TABLE "__ReplicationEnd" (\n'
         '   ts timestamp(0) without time zone NOT NULL\n'
         ') SERVER %I OPTIONS (table E'''
         '(SELECT coalesce(\\n'
         '    min(\\n'
         '       to_date(start_time, ''''MM/DD/YY HH24:MI:SS'''')\\n'
         '    ),\\n'
         '    sysdate\\n'
         ')\\n'
         '- INTERVAL ''''1'''' SECOND AS ts\\n'
         'FROM v$transaction)'')',
         server
      );

   /* create a table that will hold the replication start time */
   CREATE TABLE "__ReplicationStart" (
      ts timestamp(0) without time zone NOT NULL
   );
   INSERT INTO "__ReplicationStart" (ts) VALUES ('2000-01-01 00:00:00');

   FOR v_tabschema, v_orig_schema, v_tabname, v_orig_table IN
      SELECT s.schema, s.orig_schema, t.table_name, t.orig_table
      FROM schemas AS s
         JOIN tables AS t USING (schema)
      WHERE t.migrate
   LOOP
      /* create Oracle SQL statements for log table and trigger */
      v_create_logtable :=
         format(
            E'CREATE TABLE "%s"."__Log_%s" (\n'
            '   "__Operation" VARCHAR2(1 BYTE) CONSTRAINT "__Log_%s_Operation_NULL" NOT NULL,\n'
            '   "__Time" TIMESTAMP(6)',
            v_orig_schema,
            v_orig_table,
            v_orig_table
         );

      v_pkey_list := '';
      v_upd_col_list := '';
      v_col_list := '';
      v_new_col_list := '';
      v_old_col_list := '';

      v_upd_col_sep := '';

      /* also create an SQL statement for a foreign table for the log table */
      v_create_foreign :=
         format(
            E'CREATE FOREIGN TABLE %I (\n'
            '   "__Operation" varchar(1) NOT NULL,\n'
            '   "__Time" timestamp without time zone OPTIONS (key ''true'') NOT NULL',
            '__Log_' || v_tabschema || '/' || v_tabname
         );

      FOR v_colname, v_orig_column, v_type, v_orig_type, v_is_pkey IN
         SELECT c.column_name,
                c.orig_column,
                c.type_name,
                c.orig_type,
                coalesce(k.is_pkey, FALSE)
         FROM columns AS c
            LEFT JOIN (SELECT schema,
                              table_name,
                              column_name,
                              TRUE AS is_pkey
                       FROM keys
                       WHERE is_primary) AS k
               USING (schema, table_name, column_name)
         WHERE schema = v_tabschema
           AND table_name = v_tabname
         ORDER BY c.position
      LOOP
         v_create_logtable := v_create_logtable ||
            format(E',\n   "%s" %s', v_orig_column, v_orig_type);

         v_create_foreign := v_create_foreign ||
            format(E',\n   %I %s', v_colname, v_type);

         v_col_list := v_col_list ||
            format(E', "%s"', v_orig_column);

         v_new_col_list := v_new_col_list ||
            format(E', :NEW."%s"', v_orig_column);

         IF v_is_pkey THEN
            v_create_foreign := v_create_foreign ||
               ' OPTIONS (key ''true'') NOT NULL';

            v_old_col_list := v_old_col_list ||
               format(E', :OLD."%s"', v_orig_column);

            v_pkey_list := v_pkey_list ||
               format(E', "%s"', v_orig_column);

            v_upd_col_list := v_upd_col_list || v_upd_col_sep ||
               format(E'UPDATING(%L)', v_orig_column);

            v_upd_col_sep := ' OR ';
         END IF;
      END LOOP;

      /* create Oracle log table */
      EXECUTE
         format(
            E'SELECT %s.oracle_execute(%L,\n%L\n)',
            v_fdw_extschema,
            server,
            v_create_logtable ||
               format(
                  E',\n   PRIMARY KEY("__Time"%s)\n) SEGMENT CREATION IMMEDIATE',
                  v_pkey_list
               )
         );

      /* create Oracle trigger */
      EXECUTE
         format(
            E'SELECT %s.oracle_execute(%L,\n%L\n)',
            v_fdw_extschema,
            server,
            format(
               E'CREATE TRIGGER "%s"."__Log_%s_TRIG"\n'
               '   AFTER INSERT OR UPDATE OR DELETE ON "%s"."%s" FOR EACH ROW\n'
               'BEGIN\n'
               '   CASE\n'
               '      WHEN INSERTING THEN\n'
               '         INSERT INTO "__Log_%s" ("__Operation", "__Time"%s)\n'
               '         VALUES (''I'', localtimestamp%s);\n'
               '      WHEN %s THEN\n'
               '         INSERT INTO "__Log_%s" ("__Operation", "__Time"%s)\n'
               '         VALUES (''D'', localtimestamp%s);\n'
               '         INSERT INTO "__Log_%s" ("__Operation", "__Time"%s)\n'
               '         VALUES (''I'', localtimestamp%s);\n'
               '      WHEN UPDATING THEN\n'
               '         INSERT INTO "__Log_%s" ("__Operation", "__Time"%s)\n'
               '         VALUES (''U'', localtimestamp%s);\n'
               '      WHEN DELETING THEN\n'
               '         INSERT INTO "__Log_%s" ("__Operation", "__Time"%s)\n'
               '         VALUES (''D'', localtimestamp%s);\n'
               '   END CASE;\n'
               'END;',
               v_orig_schema,
               v_orig_table,
               v_orig_schema,
               v_orig_table,
               v_orig_table,
               v_col_list,
               v_new_col_list,
               v_upd_col_list,
               v_orig_table,
               v_pkey_list,
               v_old_col_list,
               v_orig_table,
               v_col_list,
               v_new_col_list,
               v_orig_table,
               v_col_list,
               v_new_col_list,
               v_orig_table,
               v_pkey_list,
               v_old_col_list
            )
         );

      /* create foreign table */
      EXECUTE v_create_foreign ||
         format(
            E'\n) SERVER %I OPTIONS (schema %L, table %L, readonly ''true'')',
            server,
            v_orig_schema,
            '__Log_' || v_orig_table
         );
   END LOOP;

   /* reset search_path */
   EXECUTE 'SET LOCAL search_path = ' || v_old_path;
END;$$;

COMMENT ON FUNCTION oracle_replication_start(name,name) IS
   'create all objects required for replication';

CREATE FUNCTION oracle_catchup_table(
   schema         name,
   table_name     name,
   from_ts        timestamp without time zone,
   to_ts          timestamp without time zone,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS void LANGUAGE plpgsql STRICT SET search_path = pg_catalog AS
$$DECLARE
   v_old_path      text;
   v_ft_name       text := '__Log_' || schema || '/' || table_name;
   v_ft            regclass;
   v_rec           record;
   v_ins_stmt      text;
   v_upd_stmt      text;
   v_del_stmt      text;
   v_where_clause  text;
   v_values        text;
   v_comma_sep     text;
   v_where_sep     text;
   v_upd_sep       text;
   v_colname       text;
   v_is_pkey       boolean;
   v_has_pkey      boolean := FALSE;
   v_op            text;
BEGIN
   /* remember old setting and set search_path */
   v_old_path := current_setting('search_path');

   EXECUTE format('SET LOCAL search_path = %I', pgstage_schema);

   SELECT c.oid::regclass INTO v_ft
   FROM pg_class AS c
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = pgstage_schema
     AND c.relname = v_ft_name
     AND c.relkind = 'f';

   IF NOT FOUND THEN
      RAISE EXCEPTION '%',
         format('table %I.%I does not exist', pgstage_schema, v_ft_name);
   END IF;

   /* generate INSERT, UPDATE and DELETE statements for the table */
   v_ins_stmt :=
      format(
         E'PREPARE ins_stmt(%s) AS\n'
         'INSERT INTO %I.%I (',
         v_ft,
         schema,
         table_name
      );

   v_upd_stmt :=
      format(
         E'PREPARE upd_stmt(%s) AS\n'
         'UPDATE %I.%I SET\n   ',
         v_ft,
         schema,
         table_name
      );

   v_del_stmt :=
      format(
         E'PREPARE del_stmt(%s) AS\n'
         'DELETE FROM %I.%I',
         v_ft,
         schema,
         table_name
      );

   v_where_clause := E'\nWHERE ';
   v_values := E')\nVALUES (';
   v_comma_sep := '';
   v_where_sep := '';
   v_upd_sep := '';

   FOR v_colname, v_is_pkey IN
      SELECT c.column_name,
             coalesce(k.is_pkey, FALSE)
      FROM columns AS c
         LEFT JOIN (SELECT keys.schema,
                           keys.table_name,
                           keys.column_name,
                           TRUE AS is_pkey
                    FROM keys
                    WHERE keys.is_primary) AS k
            USING (schema, table_name, column_name)
      WHERE c.schema = $1
        AND c.table_name = $2
      ORDER BY c.position
   LOOP
      /* "v_has_pkey" will end up TRUE if there is a primary key column */
      v_has_pkey := v_has_pkey OR v_is_pkey;

      v_ins_stmt := v_ins_stmt || v_comma_sep ||
         quote_ident(v_colname);

      v_values := v_values || v_comma_sep ||
         format('($1).%I', v_colname);

      v_comma_sep := ', ';

      IF v_is_pkey THEN
         v_where_clause := v_where_clause || v_where_sep ||
            format('%I = ($1).%I', v_colname, v_colname);

         v_where_sep := ' AND ';
      END IF;

      /* Have a SET clause for all columns, even the primary key */
      v_upd_stmt := v_upd_stmt || v_upd_sep ||
         format('%I = ($1).%I', v_colname, v_colname);

      v_upd_sep := E',\n   ';
   END LOOP;

   IF NOT v_has_pkey THEN
      RAISE EXCEPTION '%',
         format('cannot catch up for table %I.%I since it has no primary key',
                schema, table_name);
   END IF;

   /* prepare the statements */
   EXECUTE v_ins_stmt || v_values || ')';
   EXECUTE v_upd_stmt || v_where_clause;
   EXECUTE v_del_stmt || v_where_clause;

   /* loop through the changes and apply them */
   FOR v_rec IN
      EXECUTE
         format(
            E'SELECT * FROM %s\n'
            'WHERE "__Time" > $1 AND "__Time" <= $2\n'
            'ORDER BY "__Time"',
            v_ft
         )
      USING from_ts, to_ts
   LOOP
      /* get the type of DML operation */
      EXECUTE
         format(
            'SELECT ($1::text::%s)."__Operation"',
            v_ft
         )
         INTO v_op
         USING v_rec;

      /* call the correct prepared statement */
      CASE
         WHEN v_op = 'I' THEN
            EXECUTE format('EXECUTE ins_stmt(%L)', v_rec);
         WHEN v_op = 'U' THEN
            EXECUTE format('EXECUTE upd_stmt(%L)', v_rec);
         WHEN v_op = 'D' THEN
            EXECUTE format('EXECUTE del_stmt(%L)', v_rec);
         ELSE
            RAISE EXCEPTION 'ora_migrator internal error: unknown DML operation %', v_op;
      END CASE;
   END LOOP;

   DEALLOCATE ins_stmt;
   DEALLOCATE upd_stmt;
   DEALLOCATE del_stmt;

   /* reset search_path */
   EXECUTE 'SET LOCAL search_path = ' || v_old_path;
END;$$;

COMMENT ON FUNCTION oracle_catchup_table(name,name,timestamp without time zone,timestamp without time zone,name) IS
   'replay data modifications between two timestamps from Oracle to PostgreSQL';

CREATE FUNCTION oracle_catchup_sequence(
   schema         name,
   sequence_name  name,
   staging_schema name DEFAULT NAME 'fdw_stage'
) RETURNS void LANGUAGE plpgsql STRICT SET search_path = pg_catalog AS $$
DECLARE
   v_fdw_extschema text;
   v_last_value    bigint;
BEGIN

   SELECT extnamespace::regnamespace::text INTO v_fdw_extschema
   FROM pg_extension
   WHERE extname = 'oracle_fdw';

   EXECUTE format(
      E'SELECT last_value\n'
      'FROM %1$I.sequences \n'
      'WHERE %2$I.oracle_tolower(schema) = %3$L\n'
      '  AND %2$I.oracle_tolower(sequence_name) = %4$L',
      staging_schema, v_fdw_extschema, schema, sequence_name
   )
   INTO v_last_value;

   EXECUTE format(
      'SELECT setval(''%I.%I'', %L)',
      schema, sequence_name, v_last_value
   );

END;$$;

COMMENT ON FUNCTION oracle_catchup_sequence(name,name,name) IS
   'replay sequences modifications from Oracle to PostgreSQL';

CREATE FUNCTION oracle_replication_catchup(
   staging_schema name DEFAULT NAME 'fdw_stage',
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS void LANGUAGE plpgsql STRICT SET search_path = pg_catalog AS
$$DECLARE
   v_old_path  text;
   v_extschema text;
   v_tabschema name;
   v_tabname   name;
   v_from      timestamp without time zone;
   v_to        timestamp without time zone;
   v_seqschema name;
   v_seqname   name;
BEGIN
   /* remember old setting and set search_path */
   v_old_path := current_setting('search_path');

   EXECUTE format('SET LOCAL search_path = %I', pgstage_schema);

   SELECT extnamespace::regnamespace::text INTO v_extschema
   FROM pg_extension
   WHERE extname = 'ora_migrator';

   /* get the "from" timestamp from the last saved timestamp */
   SELECT ts INTO v_from
   FROM "__ReplicationStart";

   /* get the "to" timestamp from the oldest Oracle transaction */
   SELECT ts INTO v_to
   FROM "__ReplicationEnd";

   FOR v_tabschema, v_tabname IN
      SELECT s.schema, t.table_name
      FROM schemas AS s
         JOIN tables AS t USING (schema)
      WHERE t.migrate
   LOOP
      /* catch up on a single table */
      EXECUTE
         format(
            'SELECT %s.oracle_catchup_table($1, $2, $3, $4)',
            v_extschema
         )
      USING v_tabschema, v_tabname, v_from, v_to;
   END LOOP;

   /* save the "to" timestamp as new "from" timestamp */
   UPDATE "__ReplicationStart"
   SET ts = v_to;

   FOR v_seqschema, v_seqname IN
      SELECT schema, sequence_name
      FROM sequences
   LOOP
      /* catch up on a single sequence */
      EXECUTE
         format(
            'SELECT %s.oracle_catchup_sequence($1, $2, $3)',
            v_extschema
         )
      USING v_seqschema, v_seqname, staging_schema;
   END LOOP;

   /* reset search_path */
   EXECUTE 'SET LOCAL search_path = ' || v_old_path;
END;$$;

COMMENT ON FUNCTION oracle_replication_catchup(name,name) IS
   'replay data modifications for all tables from Oracle to PostgreSQL';

CREATE FUNCTION oracle_replication_finish(
   server         name,
   pgstage_schema name DEFAULT NAME 'pgsql_stage'
) RETURNS void LANGUAGE plpgsql STRICT SET search_path = pg_catalog AS
$$DECLARE
   v_old_path        text;
   v_fdw_extschema   text;
   v_tabname         text;
   v_tabschema       text;
   v_orig_schema     text;
   v_orig_table      text;
BEGIN
   /* remember old setting and set search_path */
   v_old_path := current_setting('search_path');

   EXECUTE format('SET LOCAL search_path = %I', pgstage_schema);

   SELECT extnamespace::regnamespace::text INTO v_fdw_extschema
   FROM pg_extension
   WHERE extname = 'oracle_fdw';

   /* drop the replication timestamp tables */
   DROP TABLE "__ReplicationStart";
   DROP FOREIGN TABLE "__ReplicationEnd";

   FOR v_tabschema, v_orig_schema, v_tabname, v_orig_table IN
      SELECT s.schema, s.orig_schema, t.table_name, t.orig_table
      FROM schemas AS s
         JOIN tables AS t USING (schema)
      WHERE t.migrate
   LOOP
      /* drop the foreign table for the Oracle log table */
      EXECUTE
         format(
            'DROP FOREIGN TABLE %I',
            '__Log_' || v_tabschema || '/' || v_tabname
         );
      /* drop then Oracle trigger */
      EXECUTE
         format(
            'SELECT %s.oracle_execute (%L, %L)',
            v_fdw_extschema,
            server,
            format(
               'DROP TRIGGER "%s"."__Log_%s_TRIG"',
               v_orig_schema,
               v_orig_table
            )
         );
      /* drop then Oracle log table */
      EXECUTE
         format(
            'SELECT %s.oracle_execute (%L, %L)',
            v_fdw_extschema,
            server,
            format(
               'DROP TABLE "%s"."__Log_%s" PURGE',
               v_orig_schema,
               v_orig_table
            )
         );
   END LOOP;

   /* reset search_path */
   EXECUTE 'SET LOCAL search_path = ' || v_old_path;
END;$$;

COMMENT ON FUNCTION oracle_replication_finish(name,name) IS
   'destroy all objects that were used for migration';

CREATE FUNCTION db_migrator_callback(
   OUT create_metadata_views_fun regprocedure,
   OUT translate_datatype_fun    regprocedure,
   OUT translate_identifier_fun  regprocedure,
   OUT translate_expression_fun  regprocedure,
   OUT create_foreign_table_fun  regprocedure
) RETURNS record
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$WITH ext AS (
   SELECT extnamespace::regnamespace::text AS schema_name
   FROM pg_extension
   WHERE extname = 'ora_migrator'
)
SELECT format('%s.%I(name,name,jsonb)', ext.schema_name, 'create_oraviews')::regprocedure,
       format('%s.%I(text,integer,integer,integer)', ext.schema_name, 'oracle_translate_datatype')::regprocedure,
       format('%s.%I(text)', ext.schema_name, 'oracle_tolower')::regprocedure,
       format('%s.%I(text)', ext.schema_name, 'oracle_translate_expression')::regprocedure,
       format('%s.%I(name,name,name,text,text,name[],jsonb[],text[],text[],boolean[],jsonb)', ext.schema_name, 'oracle_mkforeign')::regprocedure
FROM ext$$;

COMMENT ON FUNCTION db_migrator_callback() IS
   'callback for db_migrator to get the appropriate conversion functions';
