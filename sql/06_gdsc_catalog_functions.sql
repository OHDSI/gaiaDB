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
	geom_entry_exists boolean;
	attr_entry_exists boolean;
	table_pk text;
	geom_id int4;
	attr_id int4;
	attr_instance_exists boolean;
	geom_instance varchar := 'None';
	attr_instance varchar := 'None';

BEGIN

	-- TODO: primary keys, geometry names (labels) -> hard coded in this instance for ma_2018_svi_tract
	-- TODO: nodata values
	-- TODO: geom type and conceptID??
	-- TODO: put this function in backbone and adjust
	
	-- get the primary key for the table
	-- params := params->'params';

	RAISE NOTICE 'getting pk for table: %', params->>'table_id';
	EXECUTE format('
		SELECT att.attname AS pkey
		FROM pg_catalog.pg_constraint con
		JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
		JOIN pg_catalog.pg_namespace nsp ON nsp.oid = con.connamespace
		JOIN pg_catalog.pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
		WHERE con.contype = ''p''
		  AND rel.relname = ''%s''
		  AND nsp.nspname = ''public'';', 
		params->>'table_id'
	) INTO table_pk;
    RAISE NOTICE 'PK for table: %', table_pk;

	-- check for existing geom index entry and create one if none exists
	EXECUTE format('
		SELECT EXISTS (
		   SELECT FROM backbone.geom_index 
		   WHERE table_name   = ''%s''
		);', 
		(params->>'table_id')::text
	) INTO geom_entry_exists;

	IF NOT geom_entry_exists THEN

		-- create geom index entry
		RAISE NOTICE 'creating geom index entry';
		EXECUTE format('
			INSERT INTO backbone.geom_index (
				geom_type_source_value,
				table_name,
				table_desc,
				database_schema
			)
			VALUES (
				''%s'',''%s'',''%s'',''%s''
			);', 
			(params->>'geom_type')::text, 
			(params->>'table_id')::text, 
			(params->>'table_description')::text, 
			'working'
		);

		-- get the geom_index_id for the table
		EXECUTE format('
			SELECT geom_index_id 
			FROM backbone.geom_index
			WHERE table_name = ''%s'';', 
			(params->>'table_id')::text
		) INTO geom_id;	

		-- create geom table
		RAISE NOTICE 'creating geom table from template: %', (params->>'table_id')::text;
		EXECUTE format('
			CREATE TABLE working.geom_%s AS TABLE backbone.geom_template;
			ALTER TABLE working.geom_%s ADD PRIMARY KEY (geom_record_id);
			ALTER TABLE working.geom_%s ADD CONSTRAINT fk_geom_%s_geom_index
			  FOREIGN KEY (geom_index_id)
			  REFERENCES backbone.geom_index (geom_index_id);', 
			(params->>'table_id')::text, 
			(params->>'table_id')::text, 
			(params->>'table_id')::text, 
			(params->>'table_id')::text
		);
		-- create constraints for PK and FK relations??

		-- insert geom values into the geom table
		RAISE NOTICE 'insert into geom table: %', geom_id;
		EXECUTE format('
			INSERT INTO working.geom_%s (
			  geom_record_id,
			  geom_index_id,
			  geom_name,
			  geom_wgs84,
			  geom_local_epsg,
			  geom_local_value
			)
			SELECT 
			  %s as geom_record_id,
			  %s as geom_index_id,
			  %s as geom_name,
			  ST_Transform(geom, 4326) as geom_wgs84,
			  ST_SRID(geom_local) as geom_local_epsg,
			  geom_local as geom_local_value
			FROM public.%s;', 
			(params->>'table_id')::text, 
			table_pk, geom_id, 
			(params->>'geom_label')::text, 
			(params->>'table_id')::text
		);

	END IF;

	geom_instance := 'geom_' || (params->>'table_id')::text;

	-- get the geom_index_id for the table
	EXECUTE format('
		SELECT geom_index_id 
		FROM backbone.geom_index
		WHERE table_name = ''%s'';',
		(params->>'table_id')::text
	) INTO geom_id;	

	-- check for existing attr index entry
	EXECUTE format('
		SELECT EXISTS (
		   SELECT FROM backbone.attr_index 
		   WHERE variable_name = ''%s''
		   AND table_name = ''%s''
		);', 
		(params->>'variable_id')::text, 
		(params->>'table_id')::text
	) INTO attr_entry_exists;

	-- create the attr index entry and the associated attr table
	IF NOT attr_entry_exists THEN

		RAISE NOTICE 'creating attr index entry';
		EXECUTE format('
			INSERT INTO backbone.attr_index (
				geom_index_id,
				table_name,
				variable_name,
				variable_desc,
				attr_concept_id,
				unit_concept_id,
				unit_source_value,
				attr_start_date,
				attr_end_date,
				attr_no_value_as_number,
				attr_no_value_as_string,
				attr_source_value,
				database_schema
			)
			VALUES (
				%s,''%s'',''%s'',''%s'',%s,%s,''%s'',''%s'',''%s'',%s,''%s'',''%s'',''%s''
			);',
			geom_id, 
			(params->>'table_id')::text, 
			(params->>'variable_id')::text, 
			(params->>'description')::text, 
			NULLIF((params->>'concept_id')::int,null)::int,
			NULLIF((params->>'concept_id')::int,null)::int,
			(params->>'unit')::text, 
			(params->>'start_date')::date, 
			(params->>'end_date')::date, 
			(params->>'variable_nodata')::numeric, 
			(params->>'variable_nodata')::text, 
			(params->>'source')::text,
			'working'
		);

		-- get the attr_index_id for the table and variable
		EXECUTE format('
			SELECT attr_index_id 
			FROM backbone.attr_index
			WHERE variable_name = ''%s''
			AND table_name = ''%s'';', 
			(params->>'variable_id')::text, 
			(params->>'table_id')::text
		) INTO attr_id;	

		-- check if the attr instance table already exists
		EXECUTE format('
			SELECT EXISTS (
				SELECT FROM information_schema.tables 
				WHERE  table_schema = ''working''
				  AND table_name = ''attr_%s''
			);', 
			(params->>'table_id')::text
		) INTO attr_instance_exists;		

		IF NOT attr_instance_exists THEN
			-- create attr table if not already present
			EXECUTE format('
				CREATE TABLE working.attr_%s AS TABLE backbone.attr_template;
				CREATE SEQUENCE working.attr_%s_attr_record_id_seq OWNED BY working.attr_%s.attr_record_id;
				ALTER TABLE working.attr_%s ALTER COLUMN attr_record_id SET DEFAULT nextval(''working.attr_%s_attr_record_id_seq'');
				ALTER TABLE working.attr_%s ADD PRIMARY KEY (attr_record_id);
				ALTER TABLE working.attr_%s ADD CONSTRAINT fk_attr_%s_attr_index
				  FOREIGN KEY (attr_index_id)
				  REFERENCES backbone.attr_index (attr_index_id);
				ALTER TABLE working.attr_%s ADD CONSTRAINT fk_attr_%s_geom_%s
				  FOREIGN KEY (geom_record_id)
				  REFERENCES working.geom_%s (geom_record_id);', 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text, 
				(params->>'table_id')::text
			);
			-- create constraints for PK and FK relations??
		END IF;

		-- insert attribute values into the attr table
		EXECUTE format('
			INSERT INTO working.attr_%s (
			  attr_index_id,
			  geom_record_id,
			  value_as_number,
			  value_as_string
			)
			SELECT 
			  $1 as attr_index_id,
			  %I as geom_record_id,
			  %I as value_as_number,
			  TO_CHAR(%s,''99999999990.99'') as value_as_string
			FROM public.%s;', 
			(params->>'table_id')::text, 
			table_pk, 
			(params->>'variable_id')::text, 
			(params->>'variable_id')::text, 
			(params->>'table_id')::text
		) USING attr_id;

		attr_instance := 'attr_' || (params->>'table_id')::text;

	END IF;

	RETURN '{"geom": "' || geom_instance || '","attr": "' || attr_instance || '"}';
	
END;
$BODY$;

ALTER FUNCTION backbone.gdsc_load_variable(jsonb)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_load_variable(jsonb)
    IS 'transform staged table to OHDSI GIS schema and populate index tables';