-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gdsc_get_schema_tables()
--   Get all tables in the schema
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: backbone.gdsc_get_schema_tables(text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_get_schema_tables(text)

CREATE OR REPLACE FUNCTION backbone.gdsc_get_schema_tables(
	schema_name text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	result jsonb;
BEGIN
	-- get the list of tables
	SELECT jsonb_agg(table_name) INTO result
		FROM information_schema.tables
		WHERE table_schema = schema_name
		AND table_type = 'BASE TABLE' AND table_name != 'spatial_ref_sys';

	RETURN result;
	
END;
$BODY$;

ALTER FUNCTION backbone.gdsc_get_schema_tables(text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_get_schema_tables(text)
    IS 'return table names in named schema';


-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gdsc_get_loaded_variables_for_table()
--   Get a list of vairables loaded in the attr table give an table_id.
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: backbone.gdsc_get_loaded_variables_for_table(text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_get_loaded_variables_for_table(text);

CREATE OR REPLACE FUNCTION backbone.gdsc_get_loaded_variables_for_table(
	table_id text)
    RETURNS json
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	result json;
BEGIN
	-- get the list of loaded variables
	EXECUTE format('
		SELECT json_agg(variable_name)
			FROM backbone.attr_index
			WHERE table_name=''%s'';
	', table_id) INTO result;

	RETURN result;
	
END;
$BODY$;

ALTER FUNCTION backbone.gdsc_get_loaded_variables_for_table(text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_get_loaded_variables_for_table(text)
    IS 'return names of loaded variables for datasource';


-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gdsc_path_and_dependencies()
--   Get a list of all dependencies for a complex ETL pipeline
--   given the table_id.
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: backbone.gdsc_path_and_dependencies(text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_path_and_dependencies(text);

CREATE OR REPLACE FUNCTION backbone.gdsc_path_and_dependencies(
    table_id text)
    RETURNS text
    LANGUAGE 'plsh'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
#!/bin/sh

dpath=$(find /data -name "$1" -type d)
echo $dpath
deps=$(cat $dpath/meta_etl_$1.json | grep dependency)
if [[ ${#deps} -gt 0 ]]
then
  echo $deps | grep -o '\[[^][]*]' | sed 's/^.//;s/.$//' | awk -F',' '{for(i=1;i<=NF;i++) print $i}'
fi

$BODY$;

ALTER FUNCTION backbone.gdsc_path_and_dependencies(text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_path_and_dependencies(text)
    IS 'get the path and dependencies from the metadata';


-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gdsc_load_variable()
--   Create entries in the geom_index and attr_index tables and then
--   create instances of the geom_template and attr_template tables for
--   the given dataset and variable parameters.
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: backbone.gdsc_load_variable(jsonb)

-- DROP FUNCTION IF EXISTS backbone.gdsc_load_variable(jsonb);

CREATE OR REPLACE FUNCTION backbone.gdsc_load_variable(
	params jsonb)
    RETURNS json
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	geom_entry_exists    boolean;
	attr_entry_exists    boolean;
	geom_table_exists    boolean;
	geom_table_populated boolean;
	attr_table_exists    boolean;
	attr_rows_loaded     boolean;
	table_pk             text;
	geom_id              int4;
	attr_id              int4;
	geom_table_name      text;
	attr_table_name      text;
	attr_seq_name        text;
	geom_instance        varchar := 'None';
	attr_instance        varchar := 'None';

BEGIN

	-- TODO: primary keys, geometry names (labels) -> hard coded in this instance for ma_2018_svi_tract
	-- TODO: nodata values
	-- TODO: geom type and conceptID??
	-- TODO: put this function in backbone and adjust

	geom_table_name := 'geom_' || (params->>'table_id')::text;
	attr_table_name := 'attr_' || (params->>'table_id')::text;
	attr_seq_name   := attr_table_name || '_attr_record_id_seq';

	-- get the primary key for the table
	RAISE NOTICE 'getting pk for table: %', params->>'table_id';
	SELECT att.attname
	INTO   table_pk
	FROM pg_catalog.pg_constraint con
	JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
	JOIN pg_catalog.pg_namespace nsp ON nsp.oid = con.connamespace
	JOIN pg_catalog.pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
	WHERE con.contype = 'p'
	  AND rel.relname = (params->>'table_id')::text
	  AND nsp.nspname = 'public';
	RAISE NOTICE 'PK for table: %', table_pk;

	-- =================================================================
	-- geom_index catalog row -- create if missing. May already exist,
	-- e.g. registered by backbone.ingest_jsonld_variables() at metadata
	-- ingestion time, before this table's data was ever loaded.
	-- =================================================================
	SELECT EXISTS (
		SELECT 1 FROM backbone.geom_index WHERE table_name = (params->>'table_id')::text
	) INTO geom_entry_exists;

	IF NOT geom_entry_exists THEN
		RAISE NOTICE 'creating geom index entry';
		INSERT INTO backbone.geom_index (
			geom_type_source_value, table_name, table_desc, database_schema
		) VALUES (
			(params->>'geom_type')::text,
			(params->>'table_id')::text,
			(params->>'table_description')::text,
			'working'
		);
	END IF;

	SELECT geom_index_id INTO geom_id
	FROM backbone.geom_index
	WHERE table_name = (params->>'table_id')::text;

	geom_instance := geom_table_name;

	-- =================================================================
	-- working.geom_<table_id> instance table -- create the schema if
	-- missing, then populate only if it's still empty. Checked
	-- separately from the catalog row above so a pre-registered
	-- geom_index entry can't cause data loading to be silently skipped.
	-- =================================================================
	SELECT EXISTS (
		SELECT 1 FROM information_schema.tables
		WHERE table_schema = 'working' AND table_name = geom_table_name
	) INTO geom_table_exists;

	IF NOT geom_table_exists THEN
		RAISE NOTICE 'creating geom table from template: %', geom_table_name;
		EXECUTE format('CREATE TABLE working.%I AS TABLE backbone.geom_template', geom_table_name);
		EXECUTE format('ALTER TABLE working.%I ADD PRIMARY KEY (geom_record_id)', geom_table_name);
		EXECUTE format(
			'ALTER TABLE working.%I ADD CONSTRAINT %I FOREIGN KEY (geom_index_id) REFERENCES backbone.geom_index (geom_index_id)',
			geom_table_name, 'fk_' || geom_table_name || '_geom_index'
		);
	END IF;

	EXECUTE format('SELECT EXISTS (SELECT 1 FROM working.%I LIMIT 1)', geom_table_name)
		INTO geom_table_populated;

	IF NOT geom_table_populated THEN
		RAISE NOTICE 'insert into geom table: %', geom_id;
		EXECUTE format(
			'INSERT INTO working.%I (geom_record_id, geom_index_id, geom_name, geom_wgs84, geom_local_epsg, geom_local_value)
			 SELECT %I, %L, %I, ST_Transform(geom, 4326), ST_SRID(geom_local), geom_local
			 FROM public.%I',
			geom_table_name,
			table_pk, geom_id, (params->>'geom_label')::text,
			(params->>'table_id')::text
		);
	END IF;

	-- =================================================================
	-- attr_index catalog row -- create if missing (see geom_index note).
	-- =================================================================
	SELECT EXISTS (
		SELECT 1 FROM backbone.attr_index
		WHERE variable_name = (params->>'variable_id')::text
		  AND table_name = (params->>'table_id')::text
	) INTO attr_entry_exists;

	IF NOT attr_entry_exists THEN
		RAISE NOTICE 'creating attr index entry';
		INSERT INTO backbone.attr_index (
			geom_index_id, table_name, variable_name, variable_desc,
			attr_concept_id, unit_concept_id, unit_source_value,
			attr_start_date, attr_end_date,
			attr_no_value_as_number, attr_no_value_as_string,
			attr_source_value, database_schema
		) VALUES (
			geom_id,
			(params->>'table_id')::text,
			(params->>'variable_id')::text,
			(params->>'description')::text,
			NULLIF((params->>'concept_id')::int, NULL)::int,
			NULLIF((params->>'concept_id')::int, NULL)::int,
			(params->>'unit')::text,
			(params->>'start_date')::date,
			(params->>'end_date')::date,
			(params->>'variable_nodata')::numeric,
			(params->>'variable_nodata')::text,
			(params->>'source')::text,
			'working'
		);
	END IF;

	SELECT attr_index_id INTO attr_id
	FROM backbone.attr_index
	WHERE variable_name = (params->>'variable_id')::text
	  AND table_name = (params->>'table_id')::text;

	attr_instance := attr_table_name;

	-- =================================================================
	-- working.attr_<table_id> instance table -- shared across every
	-- variable loaded from this table_id, so the table itself is
	-- created once; rows are keyed by attr_index_id, so THIS variable's
	-- values are (re)loaded independently of whether the shared table
	-- or another variable's rows already exist.
	-- =================================================================
	SELECT EXISTS (
		SELECT 1 FROM information_schema.tables
		WHERE table_schema = 'working' AND table_name = attr_table_name
	) INTO attr_table_exists;

	IF NOT attr_table_exists THEN
		EXECUTE format('CREATE TABLE working.%I AS TABLE backbone.attr_template', attr_table_name);
		EXECUTE format('CREATE SEQUENCE working.%I OWNED BY working.%I.attr_record_id', attr_seq_name, attr_table_name);
		EXECUTE format('ALTER TABLE working.%I ALTER COLUMN attr_record_id SET DEFAULT nextval(%L)', attr_table_name, 'working.' || attr_seq_name);
		EXECUTE format('ALTER TABLE working.%I ADD PRIMARY KEY (attr_record_id)', attr_table_name);
		EXECUTE format(
			'ALTER TABLE working.%I ADD CONSTRAINT %I FOREIGN KEY (attr_index_id) REFERENCES backbone.attr_index (attr_index_id)',
			attr_table_name, 'fk_' || attr_table_name || '_attr_index'
		);
		EXECUTE format(
			'ALTER TABLE working.%I ADD CONSTRAINT %I FOREIGN KEY (geom_record_id) REFERENCES working.%I (geom_record_id)',
			attr_table_name, 'fk_' || attr_table_name || '_' || geom_table_name, geom_table_name
		);
	END IF;

	EXECUTE format('SELECT EXISTS (SELECT 1 FROM working.%I WHERE attr_index_id = %L)', attr_table_name, attr_id)
		INTO attr_rows_loaded;

	IF NOT attr_rows_loaded THEN
		EXECUTE format(
			'INSERT INTO working.%I (attr_index_id, geom_record_id, value_as_number, value_as_string)
			 SELECT %L, %I, %I, TO_CHAR(%I, ''99999999990.99'')
			 FROM public.%I',
			attr_table_name,
			attr_id, table_pk, (params->>'variable_id')::text, (params->>'variable_id')::text,
			(params->>'table_id')::text
		);
	END IF;

	RETURN '{"geom": "' || geom_instance || '","attr": "' || attr_instance || '"}';

END;
$BODY$;

ALTER FUNCTION backbone.gdsc_load_variable(jsonb)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_load_variable(jsonb)
    IS 'transform staged table to OHDSI GIS schema and populate index tables';


-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gdsc_load_all_variables()
--   Call gdsc_load_variable() once for every variable already registered
--   in backbone.attr_index for a table_id (i.e. every variable
--   ingest_jsonld_variables() found start/end dates for). Metadata fields
--   (description, concept_id, unit, dates, geom_type, table_desc) are
--   pulled from attr_index/geom_index rather than re-specified per call.
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: backbone.gdsc_load_all_variables(text, text, numeric, text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_load_all_variables(text, text, numeric, text);

CREATE OR REPLACE FUNCTION backbone.gdsc_load_all_variables(
    p_table_id        text,
    p_geom_label      text,
    p_variable_nodata numeric DEFAULT NULL,
    p_source          text DEFAULT NULL
)
    RETURNS TABLE(
        variable_name text,
        status        text,
        message       text
    )
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    v_row    RECORD;
    v_result json;
BEGIN
    FOR v_row IN
        SELECT ai.variable_name, ai.variable_desc, ai.attr_concept_id, ai.unit_source_value,
               ai.attr_start_date, ai.attr_end_date, gi.geom_type_source_value, gi.table_desc
        FROM backbone.attr_index ai
        JOIN backbone.geom_index gi ON gi.geom_index_id = ai.geom_index_id
        WHERE ai.table_name = p_table_id
        ORDER BY ai.variable_name
    LOOP
        BEGIN
            v_result := backbone.gdsc_load_variable(
                jsonb_build_object(
                    'table_id',          p_table_id,
                    'geom_type',         v_row.geom_type_source_value,
                    'table_description', v_row.table_desc,
                    'geom_label',        p_geom_label,
                    'variable_id',       v_row.variable_name,
                    'description',       v_row.variable_desc,
                    'concept_id',        v_row.attr_concept_id,
                    'unit',              v_row.unit_source_value,
                    'start_date',        v_row.attr_start_date,
                    'end_date',          v_row.attr_end_date,
                    'variable_nodata',   p_variable_nodata,
                    'source',            COALESCE(p_source, v_row.table_desc)
                )
            );
            variable_name := v_row.variable_name;
            status  := 'success';
            message := v_result::text;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            variable_name := v_row.variable_name;
            status  := 'error';
            message := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;

    IF NOT FOUND THEN
        RAISE WARNING 'No backbone.attr_index rows found for table_id "%". Has ingest_jsonld_variables() registered this data source''s variables yet?', p_table_id;
    END IF;
END;
$BODY$;

ALTER FUNCTION backbone.gdsc_load_all_variables(text, text, numeric, text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_load_all_variables(text, text, numeric, text)
    IS 'Run gdsc_load_variable() for every variable registered in backbone.attr_index for a table_id, reporting per-variable success/error';