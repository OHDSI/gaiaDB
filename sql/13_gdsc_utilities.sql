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
--   check if given table exists in given schema
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
	-- get the list of tables
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