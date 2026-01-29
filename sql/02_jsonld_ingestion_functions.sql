-- JSON-LD Ingestion Functions
-- Functions to parse and load JSON-LD metadata and data into PostgreSQL

-- Function to ingest JSON-LD metadata into data_source table
CREATE OR REPLACE FUNCTION backbone.ingest_jsonld_metadata(jsonld_data JSONB)
RETURNS UUID AS $$
DECLARE
    v_data_source_uuid UUID;
    v_dataset_id TEXT;
    v_creator_array TEXT[];
    v_provider_array TEXT[];
    v_keywords_array TEXT[];
    v_measurement_technique JSONB;
    v_additional_props JSONB;
BEGIN
    -- Extract dataset ID from @id field
    v_dataset_id := jsonld_data->>'@id';

    -- Extract creator array
    SELECT ARRAY_AGG(value->>'name')
    INTO v_creator_array
    FROM jsonb_array_elements(jsonld_data->'creator') AS value;

    -- Extract provider array
    SELECT ARRAY_AGG(value)
    INTO v_provider_array
    FROM jsonb_array_elements_text(jsonld_data->'provider') AS value;

    -- Extract keywords
    SELECT ARRAY_AGG(value)
    INTO v_keywords_array
    FROM jsonb_array_elements_text(jsonld_data->'keywords') AS value;

    -- Extract measurement technique
    v_measurement_technique := jsonld_data->'measurementTechnique';

    -- Extract additional properties
    v_additional_props := jsonld_data->'additionalProperty';

    -- Insert or update data source
    INSERT INTO backbone.data_source (
        dataset_id,
        dataset_name,
        dataset_version,
        description,
        creator,
        provider,
        license,
        spatial_coverage,
        date_published,
        date_modified,
        keywords,
        url,
        measurement_technique,
        additional_properties,
        geom_type,
        etl_metadata
    ) VALUES (
        v_dataset_id,
        jsonld_data->>'name',
        jsonld_data->>'version',
        jsonld_data->>'description',
        v_creator_array,
        v_provider_array,
        jsonld_data->>'license',
        COALESCE((jsonld_data->'spatialCoverage'->0->>'name'), 'Unknown'),
        (jsonld_data->>'datePublished')::DATE,
        (jsonld_data->>'dateModified')::DATE,
        v_keywords_array,
        jsonld_data->>'url',
        v_measurement_technique,
        v_additional_props,
        jsonld_data->>'type',
        jsonld_data->'about'
    )
    ON CONFLICT (dataset_id) DO UPDATE SET
        dataset_name = EXCLUDED.dataset_name,
        dataset_version = EXCLUDED.dataset_version,
        description = EXCLUDED.description,
        date_modified = EXCLUDED.date_modified,
        updated_at = NOW()
    RETURNING data_source_uuid INTO v_data_source_uuid;

    RAISE NOTICE 'Ingested data source: % (UUID: %)', jsonld_data->>'name', v_data_source_uuid;

    RETURN v_data_source_uuid;
END;
$$ LANGUAGE plpgsql;

-- Function to ingest variable metadata from JSON-LD
CREATE OR REPLACE FUNCTION backbone.ingest_jsonld_variables(
    jsonld_data JSONB,
    p_data_source_uuid UUID
)
RETURNS INTEGER AS $$
DECLARE
    v_variable JSONB;
    v_count INTEGER := 0;
    v_property_id TEXT;
    v_start_date DATE;
    v_end_date DATE;
BEGIN
    -- Loop through variableMeasured array
    FOR v_variable IN SELECT * FROM jsonb_array_elements(jsonld_data->'variableMeasured')
    LOOP
        -- Extract propertyID (may be an array, take first element)
        IF jsonb_typeof(v_variable->'propertyID') = 'array' THEN
            v_property_id := v_variable->'propertyID'->0;
        ELSE
            v_property_id := v_variable->>'propertyID';
        END IF;

        -- Parse dates if present
        BEGIN
            v_start_date := TO_DATE(v_variable->>'startDate', 'MM/DD/YY');
        EXCEPTION WHEN OTHERS THEN
            v_start_date := NULL;
        END;

        BEGIN
            v_end_date := TO_DATE(v_variable->>'endDate', 'MM/DD/YY');
        EXCEPTION WHEN OTHERS THEN
            v_end_date := NULL;
        END;

        -- Insert variable
        INSERT INTO backbone.variable_source (
            data_source_uuid,
            variable_name,
            variable_description,
            property_id,
            data_type,
            unit_code,
            unit_text,
            min_value,
            max_value,
            start_date,
            end_date
        ) VALUES (
            p_data_source_uuid,
            v_variable->>'name',
            v_variable->>'description',
            v_property_id,
            v_variable->'qudt:dataType',
            v_variable->>'unitCode',
            v_variable->>'unitText',
            (v_variable->>'minValue')::NUMERIC,
            (v_variable->>'maxValue')::NUMERIC,
            v_start_date,
            v_end_date
        )
        ON CONFLICT (data_source_uuid, variable_name) DO UPDATE SET
            variable_description = EXCLUDED.variable_description,
            unit_text = EXCLUDED.unit_text,
            min_value = EXCLUDED.min_value,
            max_value = EXCLUDED.max_value;

        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'Ingested % variables for data source %', v_count, p_data_source_uuid;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Main function to process JSON-LD file
CREATE OR REPLACE FUNCTION backbone.load_jsonld_file(jsonld_text TEXT)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_jsonld JSONB;
    v_data_source_uuid UUID;
    v_var_count INTEGER;
    v_dataset_name TEXT;
BEGIN
    -- Parse JSON-LD text
    BEGIN
        v_jsonld := jsonld_text::JSONB;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid JSON-LD format: %', SQLERRM;
    END;

    -- Ingest metadata
    v_data_source_uuid := backbone.ingest_jsonld_metadata(v_jsonld);
    v_dataset_name := v_jsonld->>'name';

    -- Ingest variables
    v_var_count := backbone.ingest_jsonld_variables(v_jsonld, v_data_source_uuid);

    RETURN QUERY SELECT v_data_source_uuid, v_dataset_name, v_var_count;
END;
$$ LANGUAGE plpgsql;

-- Helper function to load JSON-LD from file path (requires plsh or similar)
-- This is a placeholder - actual implementation depends on file access method
CREATE OR REPLACE FUNCTION backbone.load_jsonld_from_path(file_path TEXT)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_jsonld_content TEXT;
BEGIN
    -- Read file content (this requires pg_read_file or similar extension)
    -- For Docker environments, files should be mounted and accessible
    BEGIN
        v_jsonld_content := pg_read_file(file_path);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Cannot read file %: %', file_path, SQLERRM;
    END;

    -- Process the JSON-LD content
    RETURN QUERY SELECT * FROM backbone.load_jsonld_file(v_jsonld_content);
END;
$$ LANGUAGE plpgsql;

-- Function to create a dynamic data source table from JSON-LD structure
CREATE OR REPLACE FUNCTION backbone.create_datasource_table(
    p_data_source_uuid UUID,
    p_schema_name TEXT DEFAULT 'public'
)
RETURNS TEXT AS $$
DECLARE
    v_table_name TEXT;
    v_dataset_name TEXT;
    v_geom_type TEXT;
    v_create_sql TEXT;
    v_variable RECORD;
    v_columns TEXT := '';
BEGIN
    -- Get data source info
    SELECT
        LOWER(REGEXP_REPLACE(dataset_name, '[^a-zA-Z0-9_]', '_', 'g')),
        geom_type,
        dataset_name
    INTO v_table_name, v_geom_type, v_dataset_name
    FROM backbone.data_source
    WHERE data_source_uuid = p_data_source_uuid;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Data source UUID % not found', p_data_source_uuid;
    END IF;

    -- Build column definitions from variables
    FOR v_variable IN
        SELECT
            LOWER(REGEXP_REPLACE(variable_name, '[^a-zA-Z0-9_]', '_', 'g')) as col_name,
            CASE
                WHEN data_type LIKE '%numeric%' THEN 'NUMERIC'
                WHEN data_type LIKE '%varchar%' THEN 'TEXT'
                WHEN data_type LIKE '%int%' THEN 'INTEGER'
                ELSE 'TEXT'
            END as pg_type
        FROM backbone.variable_source
        WHERE data_source_uuid = p_data_source_uuid
    LOOP
        v_columns := v_columns || format('%I %s, ', v_variable.col_name, v_variable.pg_type);
    END LOOP;

    -- Create table with geometry column
    v_create_sql := format(
        'CREATE TABLE IF NOT EXISTS %I.%I (
            gid SERIAL PRIMARY KEY,
            %s
            wgs_geom GEOMETRY(GEOMETRY, 4326),
            geom_local GEOMETRY
        )',
        p_schema_name,
        v_table_name,
        v_columns
    );

    EXECUTE v_create_sql;

    -- Create spatial index
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_wgs_geom ON %I.%I USING GIST(wgs_geom)',
        v_table_name, p_schema_name, v_table_name);

    RAISE NOTICE 'Created table %.% for data source %', p_schema_name, v_table_name, v_dataset_name;

    RETURN format('%I.%I', p_schema_name, v_table_name);
END;
$$ LANGUAGE plpgsql;

-- Helper function to download JSON-LD to temp file
CREATE OR REPLACE FUNCTION backbone.download_jsonld_to_file(
    url TEXT,
    temp_file TEXT DEFAULT '/tmp/jsonld_metadata.json'
)
RETURNS TEXT AS $$
#!/bin/sh

# Download JSON-LD file from URL
echo "Downloading JSON-LD metadata from $1..."
curl -s -L -o "$2" "$1"

if [ $? -ne 0 ]; then
    echo "Error: Download failed"
    exit 1
fi

echo "Downloaded to: $2"
$$ LANGUAGE plsh;

-- Function to fetch JSON-LD from URL and load it
CREATE OR REPLACE FUNCTION backbone.fetch_and_load_jsonld(
    url TEXT,
    temp_file TEXT DEFAULT '/tmp/jsonld_metadata.json'
)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_download_result TEXT;
    v_jsonld_content TEXT;
BEGIN
    -- Download the JSON-LD file
    v_download_result := backbone.download_jsonld_to_file(url, temp_file);

    RAISE NOTICE '%', v_download_result;

    -- Read the downloaded file
    BEGIN
        v_jsonld_content := pg_read_file(temp_file);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to read downloaded file %: %', temp_file, SQLERRM;
    END;

    -- Process the JSON-LD content
    RETURN QUERY SELECT * FROM backbone.load_jsonld_file(v_jsonld_content);

    -- Note: Cleanup of temp file could be added here with another shell function if needed
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backbone.ingest_jsonld_metadata IS 'Parses JSON-LD metadata and stores in data_source table';
COMMENT ON FUNCTION backbone.ingest_jsonld_variables IS 'Extracts variable definitions from JSON-LD and stores in variable_source';
COMMENT ON FUNCTION backbone.load_jsonld_file IS 'Main entry point to load JSON-LD content from text';
COMMENT ON FUNCTION backbone.load_jsonld_from_path IS 'Load JSON-LD from file path using pg_read_file';
COMMENT ON FUNCTION backbone.download_jsonld_to_file IS 'Download JSON-LD file from URL to temporary location';
COMMENT ON FUNCTION backbone.fetch_and_load_jsonld IS 'Fetch JSON-LD metadata from URL and load into database';
COMMENT ON FUNCTION backbone.create_datasource_table IS 'Dynamically creates a table structure based on JSON-LD variable definitions';
