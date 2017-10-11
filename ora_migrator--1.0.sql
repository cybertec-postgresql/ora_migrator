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

   ora_sys_schemas text :=
      E'''''ANONYMOUS'''', ''''APEX_PUBLIC_USER'''', ''''APEX_030200'''', ''''APEX_040000'''', ''''APPQOSSYS'''',\n'
      '         ''''AURORA$JIS$UTILITY$'''', ''''AURORA$ORB$UNAUTHENTICATED'''', ''''BI'''',\n'
      '         ''''CTXSYS'''', ''''DBSNMP'''', ''''DIP'''', ''''DMSYS'''', ''''EXFSYS'''', ''''FLOWS_FILES'''',\n'
      '         ''''HR'''', ''''IX'''', ''''LBACSYS'''', ''''MDDATA'''', ''''MDSYS'''', ''''MGMT_VIEW'''',\n'
      '         ''''ODM'''', ''''ODM_MTR'''', ''''OE'''', ''''OLAPSYS'''', ''''ORACLE_OCM'''', ''''ORDDATA'''',\n'
      '         ''''ORDPLUGINS'''', ''''ORDSYS'''', ''''OSE$HTTP$ADMIN'''', ''''OUTLN'''', ''''PM'''',\n'
      '         ''''SCOTT'''', ''''SH'''', ''''SI_INFORMTN_SCHEMA'''', ''''SPATIAL_CSW_ADMIN_USR'''',\n'
      '         ''''SPATIAL_WFS_ADMIN_USR'''', ''''SYS'''', ''''SYSMAN'''', ''''SYSTEM'''', ''''TRACESRV'''',\n'
      '         ''''MTSSYS'''', ''''OASPUBLIC'''', ''''OLAPSYS'''', ''''OWBSYS'''', ''''OWBSYS_AUDIT'''',\n'
      '         ''''WEBSYS'''', ''''WK_PROXY'''', ''''WKSYS'''', ''''WK_TEST'''', ''''WMSYS'''', ''''XDB'''', ''''XS$NULL''''';

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
      '       col_expression IS NOT NULL AS is_expression,\n'
      '       coalesce(col_expression, col_name) AS column_name\n'
      'FROM %I.ora_index_exp\n';

   ora_schemas_sql text := E'CREATE FOREIGN TABLE %I.ora_schemas (\n'
      '   schema varchar(128) NOT NULL\n'
      ') SERVER %I OPTIONS (table ''('
         'SELECT username\n'
         'FROM all_users\n'
         'WHERE username NOT IN( ' || ora_sys_schemas || E')'
      ')'', max_long ''%s'', readonly ''true'')';

   ora_trig_sql text := E'CREATE FOREIGN TABLE %I.ora_trig (\n'
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
         'FROM all_triggers\n'
         'WHERE table_owner NOT IN( ' || ora_sys_schemas || E')\n'
         '  AND base_object_type IN (''''TABLE'''', ''''VIEW'''')\n'
         '  AND status = ''''ENABLED''''\n'
         '  AND crossedition = ''''NO''''\n'
         '  AND trigger_type <> ''''COMPOUND'''''
      ')'', max_long ''%s'', readonly ''true'')';

   ora_triggers_sql text := E'CREATE VIEW %I.ora_triggers AS\n'
      'SELECT schema,\n'
      '       table_name,\n'
      '       trigger_name,\n'
      '       trigger_type LIKE ''BEFORE%%'' AS is_before,\n'
      '       triggering_event,\n'
      '       trigger_type LIKE ''%%EACH ROW'' AS for_each_row,\n'
      '       when_clause,\n'
      '       referencing_names,\n'
      '       trigger_body\n'
      'FROM %I.ora_trig';

BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

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
   /* ora_trig and ora_triggers */
   EXECUTE format('DROP VIEW IF EXISTS %I.ora_triggers', schema);
   EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.ora_trig', schema);
   EXECUTE format(ora_trig_sql, schema, server, max_long);
   EXECUTE format('COMMENT ON FOREIGN TABLE %I.ora_trig IS ''Oracle triggers on foreign server "%I"''', schema, server);
   EXECUTE format(ora_triggers_sql, schema, schema);
   EXECUTE format('COMMENT ON VIEW %I.ora_triggers IS ''Oracle triggers on foreign server "%I"''', schema, server);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION create_oraviews(name, name, integer) IS 'create Oracle foreign tables for the metadata of a foreign server';

CREATE FUNCTION oracle_tolower(text) RETURNS text
   LANGUAGE sql STABLE CALLED ON NULL INPUT SET search_path = pg_catalog AS
'SELECT CASE WHEN $1 = upper($1) THEN lower($1) ELSE $1 END';

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
) RETURNS void
   LANGUAGE plpgsql VOLATILE STRICT SET search_path = pg_catalog AS
$$DECLARE
   ft     name;
   errmsg text;
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
   EXCEPTION
      WHEN others THEN
         /* turn the error into a warning */
         GET STACKED DIAGNOSTICS
            errmsg := MESSAGE_TEXT;
         RAISE WARNING 'Error loading table data for %.%', s, t
            USING DETAIL = errmsg;
   END;
END;$$;

COMMENT ON FUNCTION oracle_materialize(name, name) IS 'turn an Oracle foreign table into a PostgreSQL table';

CREATE FUNCTION oracle_migrate_prepare(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_staging',
   schemas        name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   s            name;
   extschema    name;
   tablist      text;
   sch          name;
   seq          name;
   minv         numeric;
   maxv         numeric;
   incr         numeric;
   cycl         boolean;
   cachesiz     integer;
   lastval      numeric;
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

   /* set "search_path" to the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I', extschema);

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating staging schema ...';
   SET LOCAL client_min_messages = warning;

   /* create staging schema */
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

   /* create the migration views in the staging schema */
   PERFORM create_oraviews(server, staging_schema, max_long);

   /* set "search_path" to the staging schema and the extension schema */
   EXECUTE format('SET LOCAL search_path = %I, %I', staging_schema, extschema);

   /* loop through the schemas that should be migrated */
   FOR s IN
      SELECT schema FROM ora_schemas
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
   LOOP
      EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
      RAISE NOTICE 'Creating foreign tables for schema "%"...', s;
      SET LOCAL client_min_messages = warning;

      /* create schema */
      EXECUTE format('CREATE SCHEMA %I', oracle_tolower(s));

      /* get a list of tables in the schema */
      SELECT string_agg(format('%I', oracle_tolower(table_name)), ', ') INTO tablist
         FROM ora_tables
         WHERE schema = s;

      CONTINUE WHEN tablist IS NULL;

      /* create foreign tables for all these tables */
      EXECUTE format('IMPORT FOREIGN SCHEMA %I LIMIT TO (%s) FROM SERVER %I INTO %I', s, tablist, server, oracle_tolower(s));
   END LOOP;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating sequences ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all sequences */
   FOR sch, seq, minv, maxv, incr, cycl, cachesiz, lastval IN
      SELECT schema, sequence_name, min_value, max_value, increment_by, cyclical, cache_size, last_value
         FROM ora_sequences
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
   LOOP
      EXECUTE format('CREATE SEQUENCE %I.%I INCREMENT %s MINVALUE %s MAXVALUE %s START %s CACHE %s %sCYCLE',
                     oracle_tolower(sch), oracle_tolower(seq), adjust_to_bigint(incr), adjust_to_bigint(minv),
                     adjust_to_bigint(maxv), adjust_to_bigint(lastval + 1), cachesiz,
                     CASE WHEN cycl THEN '' ELSE 'NO ' END);
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION oracle_migrate_prepare(name, name, name[], integer) IS 'first step of "oracle_migrate": create schemas and foreign table definitions';

CREATE FUNCTION oracle_migrate_tables(
   staging_schema name    DEFAULT NAME 'ora_staging',
   schemas        name[]  DEFAULT NULL
) RETURNS void
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema    name;
   s            name;
   t            name;
   old_msglevel text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the staging schema and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', staging_schema, extschema);

   /* loop through the schemas that should be migrated */
   FOR s IN
      SELECT schema FROM ora_schemas
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
   LOOP
      /* loop through all external tables in that schema */
      FOR t IN
         SELECT relname
         FROM pg_catalog.pg_class
         WHERE relnamespace = format('%I', oracle_tolower(s))::regnamespace
           AND relkind = 'f'
      LOOP
         EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
         RAISE NOTICE 'Migrating table "%"."%" ...', oracle_tolower(s), t;
         SET LOCAL client_min_messages = warning;

         /* turn that foreign table into a real table */
         PERFORM oracle_materialize(oracle_tolower(s), t);
      END LOOP;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION oracle_migrate_tables(name, name[]) IS 'second step of "oracle_migrate": copy tables from Oracle';

CREATE FUNCTION oracle_migrate_constraints(
   staging_schema name    DEFAULT NAME 'ora_staging',
   schemas        name[]  DEFAULT NULL
) RETURNS void
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
   old_msglevel text;
BEGIN
   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   /* set "search_path" to the staging schema and the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I, %I', staging_schema, extschema);

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating UNIQUE and PRIMARY KEY constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all key constraint columns */
   old_s := '';
   old_t := '';
   old_c := '';
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, colname, colpos, prim IN
      SELECT schema, table_name, constraint_name, "deferrable", deferred,
             column_name, position, is_primary
      FROM ora_keys
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
      ORDER BY schema, table_name, constraint_name, position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
                  EXECUTE stmt || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT;
                  RAISE WARNING 'Error creating primary key or unique constraint on table %.%',
                                oracle_tolower(old_s), oracle_tolower(old_t)
                     USING DETAIL = errmsg;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD %s (',
                        oracle_tolower(loc_s), oracle_tolower(loc_t),
                        CASE WHEN prim THEN 'PRIMARY KEY' ELSE 'UNIQUE' END);
         stmt_suffix := format(')%s DEFERRABLE INITIALLY %s',
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', oracle_tolower(colname));
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT;
            RAISE WARNING 'Error creating primary key or unique constraint on table %.%',
                          oracle_tolower(old_s), oracle_tolower(old_t)
               USING DETAIL = errmsg;
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
      SELECT schema, table_name, constraint_name, "deferrable", deferred, delete_rule,
             column_name, position, remote_schema, remote_table, remote_column
         FROM ora_foreign_keys
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
            AND remote_schema =ANY (schemas)
      ORDER BY schema, table_name, constraint_name, position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> cons_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || stmt_middle || stmt_suffix;
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT;
                  RAISE WARNING 'Error creating foreign key constraint on table %.%',
                                oracle_tolower(old_s), oracle_tolower(old_t)
                     USING DETAIL = errmsg;
            END;
         END IF;

         stmt := format('ALTER TABLE %I.%I ADD FOREIGN KEY (',
                        oracle_tolower(loc_s), oracle_tolower(loc_t));
         stmt_middle := format(') REFERENCES %I.%I (',
                               oracle_tolower(rem_s), oracle_tolower(rem_t));
         stmt_suffix := format(')%s DEFERRABLE INITIALLY %s',
                              CASE WHEN candefer THEN '' ELSE ' NOT' END,
                              CASE WHEN is_deferred THEN 'DEFERRED' ELSE 'IMMEDIATE' END);
         old_s := loc_s;
         old_t := loc_t;
         old_c := cons_name;
         separator := '';
      END IF;

      stmt := stmt || separator || format('%I', oracle_tolower(colname));
      stmt_middle := stmt_middle || separator || format('%I', oracle_tolower(rem_colname));
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || stmt_middle || stmt_suffix;
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT;
            RAISE WARNING 'Error creating foreign key constraint on table %.%',
                          oracle_tolower(old_s), oracle_tolower(old_t)
               USING DETAIL = errmsg;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Creating CHECK constraints ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all check constraints except NOT NULL checks */
   FOR loc_s, loc_t, cons_name, candefer, is_deferred, expr IN
      SELECT schema, table_name, constraint_name, "deferrable", deferred, condition
         FROM ora_checks
      WHERE (schemas IS NULL
         OR schema =ANY (schemas))
        AND condition !~ e'^"[^"]*" IS NOT NULL$'
   LOOP
      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ADD CHECK(%s)',
                       oracle_tolower(loc_s), oracle_tolower(loc_t), oracle_tolower(expr));
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT;
            RAISE WARNING 'Error creating CHECK constraint on table %.% with expression "%"',
                          oracle_tolower(loc_s), oracle_tolower(loc_t), oracle_tolower(expr)
               USING DETAIL = errmsg;
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
      SELECT schema, table_name, index_name, uniqueness, position, descend, is_expression, column_name
         FROM ora_index_columns
      WHERE schemas IS NULL
         OR schema =ANY (schemas)
      ORDER BY schema, table_name, index_name, position
   LOOP
      IF old_s <> loc_s OR old_t <> loc_t OR old_c <> ind_name THEN
         IF old_t <> '' THEN
            BEGIN
               EXECUTE stmt || ')';
            EXCEPTION
               WHEN others THEN
                  /* turn the error into a warning */
                  GET STACKED DIAGNOSTICS
                     errmsg := MESSAGE_TEXT;
                  RAISE WARNING 'Error executing "%"', stmt || ')'
                     USING DETAIL = errmsg;
            END;
         END IF;

         stmt := format('CREATE %sINDEX ON %I.%I (',
                        CASE WHEN uniq THEN 'UNIQUE ' ELSE '' END,
                        oracle_tolower(loc_s), oracle_tolower(loc_t));
         old_s := loc_s;
         old_t := loc_t;
         old_c := ind_name;
         separator := '';
      END IF;

      /* fold expressions to lower case */
      stmt := stmt || separator
                   || CASE WHEN is_expr
                           THEN '(' || lower(expr) || ')'
                           ELSE quote_ident(oracle_tolower(expr))
                      END
                   || ' ' || CASE WHEN des THEN 'DESC' ELSE 'ASC' END;
      separator := ', ';
   END LOOP;

   IF old_t <> '' THEN
      BEGIN
         EXECUTE stmt || ')';
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT;
            RAISE WARNING 'Error executing "%"', stmt || ')'
               USING DETAIL = errmsg;
      END;
   END IF;

   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
   RAISE NOTICE 'Setting column default values ...';
   SET LOCAL client_min_messages = warning;

   /* loop through all default expressions */
   FOR loc_s, loc_t, colname, expr IN
      SELECT schema, table_name, column_name, default_value
      FROM ora_columns
      WHERE (schemas IS NULL
         OR schema =ANY (schemas))
        AND default_value IS NOT NULL
   LOOP
      expr := replace(replace(lower(expr),
                              'sysdate',
                              'current_date'),
                      'systimestamp',
                      'current_timestamp');

      BEGIN
         EXECUTE format('ALTER TABLE %I.%I ALTER %I SET DEFAULT %s',
                        oracle_tolower(loc_s), oracle_tolower(loc_t),
                        oracle_tolower(colname), expr);
      EXCEPTION
         WHEN others THEN
            /* turn the error into a warning */
            GET STACKED DIAGNOSTICS
               errmsg := MESSAGE_TEXT;
            RAISE WARNING 'Error setting default value on % of table %.% to "%"',
                          oracle_tolower(colname), oracle_tolower(loc_s), oracle_tolower(loc_t), expr
               USING DETAIL = errmsg;
      END;
   END LOOP;

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;
END;$$;

COMMENT ON FUNCTION oracle_migrate_constraints(name, name[]) IS 'third step of "oracle_migrate": create constraints and indexes';

CREATE FUNCTION oracle_migrate_finish(
   staging_schema name    DEFAULT NAME 'ora_staging'
) RETURNS void
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   old_msglevel text;
BEGIN
   RAISE NOTICE 'Dropping staging schema ...';

   /* remember old setting */
   old_msglevel := current_setting('client_min_messages');
   /* make the output less verbose */
   SET LOCAL client_min_messages = warning;

   EXECUTE format('DROP SCHEMA %I CASCADE', staging_schema);

   /* reset client_min_messages */
   EXECUTE 'SET LOCAL client_min_messages = ' || old_msglevel;

   RAISE NOTICE 'Migration completed.';
END;$$;

COMMENT ON FUNCTION oracle_migrate_finish(name) IS 'final step of "oracle_migrate": drop staging schema';

CREATE FUNCTION oracle_migrate(
   server         name,
   staging_schema name    DEFAULT NAME 'ora_staging',
   schemas        name[]  DEFAULT NULL,
   max_long       integer DEFAULT 32767
) RETURNS void
   LANGUAGE plpgsql VOLATILE CALLED ON NULL INPUT SET search_path = pg_catalog AS
$$DECLARE
   extschema name;
BEGIN
   /* set "search_path" to the extension schema */
   SELECT extnamespace::regnamespace INTO extschema
      FROM pg_catalog.pg_extension
      WHERE extname = 'ora_migrator';
   EXECUTE format('SET LOCAL search_path = %I', extschema);

   /*
    * First step:
    * Create staging schema and define the oracle metadata views there.
    * Create the destination schemas and the foreign tables and sequences there.
    */
   PERFORM oracle_migrate_prepare(server, staging_schema, schemas, max_long);

   /*
    * Second step:
    * Copy the tables over from Oracle.
    */
   PERFORM oracle_migrate_tables(staging_schema, schemas);

   /*
    * Third step:
    * Create constraints and indexes.
    */
   PERFORM oracle_migrate_constraints(staging_schema, schemas);

   /*
    * Second step:
    * Copy the tables over from Oracle.
    */
   PERFORM oracle_migrate_finish(staging_schema);
END;$$;

COMMENT ON FUNCTION oracle_migrate(name, name, name[], integer) IS 'migrate an Oracle database from a foreign server to PostgreSQL';
