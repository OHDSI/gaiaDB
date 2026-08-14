-- JSON-LD Ingestion Functions
-- Parse and load JSON-LD metadata and variable definitions into backbone tables.

-- ---------------------------------------------------------------------------
-- backbone.ingest_jsonld_metadata
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.ingest_jsonld_metadata(jsonld_data JSONB)
RETURNS UUID AS $$
DECLARE
    v_data_source_uuid   UUID;
    v_dataset_id         TEXT;
    v_creator_array      TEXT[];
    v_provider_array     TEXT[];
    v_keywords_array     TEXT[];
    v_measurement_technique JSONB;
    v_additional_props   JSONB;
    v_geom_type          TEXT;
    v_srid               INTEGER;
BEGIN
    v_dataset_id := jsonld_data->>'@id';

    SELECT ARRAY_AGG(value->>'name')
    INTO v_creator_array
    FROM jsonb_array_elements(jsonld_data->'creator') AS value;

    SELECT ARRAY_AGG(value)
    INTO v_provider_array
    FROM jsonb_array_elements_text(jsonld_data->'provider') AS value;

    SELECT ARRAY_AGG(value)
    INTO v_keywords_array
    FROM jsonb_array_elements_text(jsonld_data->'keywords') AS value;

    v_measurement_technique := jsonld_data->'measurementTechnique';
    v_additional_props      := jsonld_data->'additionalProperty';

    -- Geometry type: read from the 'vectorGeometry' DefinedTermSet in measurementTechnique.
    -- Falls back to the top-level 'type' key if the term is absent.
    SELECT elem->>'termCode'
    INTO v_geom_type
    FROM jsonb_array_elements(jsonld_data->'measurementTechnique') AS elem
    WHERE elem->'inDefinedTermSet'->>'name' = 'vectorGeometry'
    LIMIT 1;

    IF v_geom_type IS NULL THEN
        v_geom_type := jsonld_data->>'type';
    END IF;

    -- SRID: extract numeric code from the Spatial_reference_system additionalProperty value
    -- e.g. "https://epsg.io/4269" → 4269
    BEGIN
        SELECT regexp_replace(elem->>'value', '^[^0-9]*([0-9]+)[^0-9]*$', '\1')::INTEGER
        INTO v_srid
        FROM jsonb_array_elements(jsonld_data->'additionalProperty') AS elem
        WHERE elem->>'propertyID' LIKE '%Spatial_reference_system%'
        LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        v_srid := 4326;
    END;

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
        srid,
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
        v_geom_type,
        COALESCE(v_srid, 4326),
        jsonld_data->'about'
    )
    ON CONFLICT (dataset_id) DO UPDATE SET
        dataset_name        = EXCLUDED.dataset_name,
        dataset_version     = EXCLUDED.dataset_version,
        description         = EXCLUDED.description,
        geom_type           = EXCLUDED.geom_type,
        srid                = EXCLUDED.srid,
        date_modified       = EXCLUDED.date_modified,
        updated_at          = NOW()
    RETURNING data_source_uuid INTO v_data_source_uuid;

    RAISE NOTICE 'Ingested data source: % (UUID: %)', jsonld_data->>'name', v_data_source_uuid;

    RETURN v_data_source_uuid;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.ingest_jsonld_variables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.ingest_jsonld_variables(
    jsonld_data       JSONB,
    p_data_source_uuid UUID
)
RETURNS INTEGER AS $$
DECLARE
    v_variable        JSONB;
    v_count           INTEGER := 0;
    v_property_id     TEXT;
    v_attr_concept_id INTEGER;
    v_start_date      DATE;
    v_end_date        DATE;
    v_dataset_id      TEXT;
    v_dataset_name    TEXT;
    v_geom_type       TEXT;
    v_table_id        TEXT;
    v_geom_index_id   INTEGER;
BEGIN
    -- Resolve table_id / geom_type / dataset_name once, up front, so
    -- geom_index/attr_index can be registered alongside variable_source.
    -- table_id follows the same "last URL segment of dataset_id" convention
    -- retrieve_and_ingest_datasource() uses to derive ETL script paths.
    SELECT dataset_id, geom_type, dataset_name
    INTO   v_dataset_id, v_geom_type, v_dataset_name
    FROM   backbone.data_source
    WHERE  data_source_uuid = p_data_source_uuid;

    IF v_dataset_id IS NULL THEN
        RAISE EXCEPTION 'data_source_uuid % not found in backbone.data_source (run ingest_jsonld_metadata first)', p_data_source_uuid;
    END IF;

    v_table_id := split_part(
        v_dataset_id, '/',
        array_length(string_to_array(v_dataset_id, '/'), 1)
    );

    -- Register a geom_index catalog entry for this table_id if one doesn't
    -- already exist. This only creates the catalog row -- it does NOT create
    -- or populate the working.geom_<table_id> instance table, since that
    -- requires the raw public.<table_id> table (loaded later by the osgeo
    -- ETL step) to already exist. backbone.gdsc_load_variable() is what
    -- creates/populates the instance table, using this catalog row.
    SELECT geom_index_id INTO v_geom_index_id
    FROM backbone.geom_index
    WHERE table_name = v_table_id;

    IF NOT FOUND THEN
        INSERT INTO backbone.geom_index (
            geom_type_source_value, table_name, table_desc, database_schema
        ) VALUES (
            COALESCE(v_geom_type, 'Unknown'), v_table_id, COALESCE(v_dataset_name, v_table_id), 'working'
        )
        RETURNING geom_index_id INTO v_geom_index_id;
    END IF;

    FOR v_variable IN SELECT * FROM jsonb_array_elements(jsonld_data->'variableMeasured')
    LOOP
        -- propertyID is typically an array; use ->> to get plain text without JSON quotes
        IF jsonb_typeof(v_variable->'propertyID') = 'array' THEN
            v_property_id := v_variable->'propertyID'->>0;
        ELSE
            v_property_id := v_variable->>'propertyID';
        END IF;

        -- Attempt to interpret the propertyID as an OHDSI concept_id integer
        BEGIN
            v_attr_concept_id := NULLIF(v_property_id, '')::INTEGER;
        EXCEPTION WHEN OTHERS THEN
            v_attr_concept_id := NULL;
        END;

        -- Dates are stored in ISO format (YYYY-MM-DD) in the JSON-LD
        BEGIN
            v_start_date := (v_variable->>'startDate')::DATE;
        EXCEPTION WHEN OTHERS THEN
            v_start_date := NULL;
        END;

        BEGIN
            v_end_date := (v_variable->>'endDate')::DATE;
        EXCEPTION WHEN OTHERS THEN
            v_end_date := NULL;
        END;

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
            end_date,
            attr_concept_id
        ) VALUES (
            p_data_source_uuid,
            v_variable->>'name',
            v_variable->>'description',
            v_property_id,
            v_variable->>'qudt:dataType',
            v_variable->>'unitCode',
            v_variable->>'unitText',
            -- Guard against empty-string minValue/maxValue
            NULLIF(v_variable->>'minValue', '')::NUMERIC,
            NULLIF(v_variable->>'maxValue', '')::NUMERIC,
            v_start_date,
            v_end_date,
            v_attr_concept_id
        )
        ON CONFLICT (data_source_uuid, variable_name) DO UPDATE SET
            variable_description = EXCLUDED.variable_description,
            unit_text            = EXCLUDED.unit_text,
            min_value            = EXCLUDED.min_value,
            max_value            = EXCLUDED.max_value,
            attr_concept_id      = EXCLUDED.attr_concept_id;

        -- Register an attr_index catalog entry for this variable, if one
        -- doesn't already exist. Like geom_index above, this only creates
        -- the catalog row; gdsc_load_variable() still owns loading actual
        -- values into working.attr_<table_id>. attr_start_date/attr_end_date
        -- are NOT NULL on attr_index, so a variable whose JSON-LD is missing
        -- startDate/endDate is skipped here (it's still ingested into
        -- variable_source above) with a warning, rather than aborting the
        -- whole batch.
        IF NOT EXISTS (
            SELECT 1 FROM backbone.attr_index
            WHERE table_name = v_table_id AND variable_name = (v_variable->>'name')
        ) THEN
            IF v_start_date IS NULL OR v_end_date IS NULL THEN
                RAISE WARNING 'Skipping attr_index entry for variable "%": missing startDate/endDate in JSON-LD', v_variable->>'name';
            ELSE
                INSERT INTO backbone.attr_index (
                    geom_index_id,
                    table_name,
                    variable_name,
                    variable_desc,
                    attr_concept_id,
                    unit_source_value,
                    attr_start_date,
                    attr_end_date,
                    attr_source_value,
                    database_schema
                ) VALUES (
                    v_geom_index_id,
                    v_table_id,
                    v_variable->>'name',
                    COALESCE(v_variable->>'description', v_variable->>'name'),
                    v_attr_concept_id,
                    v_variable->>'unitText',
                    v_start_date,
                    v_end_date,
                    v_variable->>'name',
                    'working'
                );
            END IF;
        END IF;

        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE 'Ingested % variables for data source %', v_count, p_data_source_uuid;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.load_jsonld_file  –  parse JSON text and run both ingest steps
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.load_jsonld_file(jsonld_text TEXT)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name     TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_jsonld          JSONB;
    v_data_source_uuid UUID;
    v_var_count       INTEGER;
    v_dataset_name    TEXT;
BEGIN
    BEGIN
        v_jsonld := jsonld_text::JSONB;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid JSON-LD: %', SQLERRM;
    END;

    v_data_source_uuid := backbone.ingest_jsonld_metadata(v_jsonld);
    v_dataset_name     := v_jsonld->>'name';
    v_var_count        := backbone.ingest_jsonld_variables(v_jsonld, v_data_source_uuid);

    RETURN QUERY SELECT v_data_source_uuid, v_dataset_name, v_var_count;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.load_jsonld_from_path  –  read a file and call load_jsonld_file
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.load_jsonld_from_path(file_path TEXT)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name     TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_content TEXT;
BEGIN
    BEGIN
        v_content := pg_read_file(file_path);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Cannot read %: %', file_path, SQLERRM;
    END;

    RETURN QUERY SELECT * FROM backbone.load_jsonld_file(v_content);
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.create_datasource_table
-- Dynamically creates a staging table from variable_source definitions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.create_datasource_table(
    p_data_source_uuid UUID,
    p_schema_name      TEXT DEFAULT 'public'
)
RETURNS TEXT AS $$
DECLARE
    v_table_name  TEXT;
    v_dataset_name TEXT;
    v_geom_type   TEXT;
    v_create_sql  TEXT;
    v_variable    RECORD;
    v_columns     TEXT := '';
BEGIN
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

    FOR v_variable IN
        SELECT
            LOWER(REGEXP_REPLACE(variable_name, '[^a-zA-Z0-9_]', '_', 'g')) AS col_name,
            CASE
                WHEN data_type ILIKE '%float%' OR data_type = 'float8' OR data_type = 'float4' THEN 'DOUBLE PRECISION'
                WHEN data_type ILIKE '%int%'   OR data_type = 'int4'   OR data_type = 'int8'   THEN 'INTEGER'
                WHEN data_type ILIKE '%bool%'                                                   THEN 'BOOLEAN'
                WHEN data_type ILIKE '%varchar%' OR data_type ILIKE '%text%'                   THEN 'TEXT'
                ELSE 'TEXT'
            END AS pg_type
        FROM backbone.variable_source
        WHERE data_source_uuid = p_data_source_uuid
    LOOP
        v_columns := v_columns || format('%I %s, ', v_variable.col_name, v_variable.pg_type);
    END LOOP;

    v_create_sql := format(
        'CREATE TABLE IF NOT EXISTS %I.%I (
            gid SERIAL PRIMARY KEY,
            %s
            geom GEOMETRY(GEOMETRY, 4326),
            geom_local GEOMETRY
        )',
        p_schema_name,
        v_table_name,
        v_columns
    );

    EXECUTE v_create_sql;

    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%I_geom ON %I.%I USING GIST(geom)',
        v_table_name, p_schema_name, v_table_name
    );

    RAISE NOTICE 'Created table %.% for data source %', p_schema_name, v_table_name, v_dataset_name;

    RETURN format('%I.%I', p_schema_name, v_table_name);
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.download_jsonld_to_file  (plsh helper)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.download_jsonld_to_file(
    url       TEXT,
    temp_file TEXT DEFAULT '/tmp/jsonld_metadata.json'
)
RETURNS TEXT AS $$
#!/bin/sh
curl -s -L -o "$2" "$1"
if [ $? -ne 0 ]; then
    echo "Error: download failed"
    exit 1
fi
echo "Downloaded to: $2"
$$ LANGUAGE plsh;


-- ---------------------------------------------------------------------------
-- backbone.fetch_and_load_jsonld  –  download from URL then load
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.fetch_and_load_jsonld(
    url       TEXT,
    temp_file TEXT DEFAULT '/tmp/jsonld_metadata.json'
)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name     TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_content TEXT;
BEGIN
    PERFORM backbone.download_jsonld_to_file(url, temp_file);

    BEGIN
        v_content := pg_read_file(temp_file);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Failed to read downloaded file %: %', temp_file, SQLERRM;
    END;

    RETURN QUERY SELECT * FROM backbone.load_jsonld_file(v_content);
END;
$$ LANGUAGE plpgsql;


COMMENT ON FUNCTION backbone.ingest_jsonld_metadata  IS 'Parse JSON-LD top-level metadata into backbone.data_source. Reads geom_type from measurementTechnique and SRID from additionalProperty.';
COMMENT ON FUNCTION backbone.ingest_jsonld_variables IS 'Parse variableMeasured array into backbone.variable_source. Sets attr_concept_id from propertyID.';
COMMENT ON FUNCTION backbone.load_jsonld_file        IS 'Main entry point: parse JSON-LD text and run both ingest steps.';
COMMENT ON FUNCTION backbone.load_jsonld_from_path   IS 'Load JSON-LD from a file path via pg_read_file.';
COMMENT ON FUNCTION backbone.create_datasource_table IS 'Dynamically create a staging table from variable_source definitions.';
COMMENT ON FUNCTION backbone.download_jsonld_to_file IS 'Download a JSON-LD file from a URL.';
COMMENT ON FUNCTION backbone.fetch_and_load_jsonld   IS 'Download JSON-LD from URL and load into database.';
