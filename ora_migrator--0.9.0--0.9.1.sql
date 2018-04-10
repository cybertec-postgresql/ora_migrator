/* upgrade from version 0.9.0 to 0.9.1 */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION ora_migrator" to load this file. \quit

CREATE OR REPLACE FUNCTION oracle_migrate_tables(
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
      WHERE migrate
        AND (only_schemas IS NULL
         OR schema =ANY (only_schemas))
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

CREATE OR REPLACE FUNCTION oracle_migrate_refresh(
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
   RAISE NOTICE 'Copy definitions to PostgreSQL staging schema "%" ...', pgstage_schema;
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
                   '          lower(condition)\n'
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
