-- JSON-LD Ingestion Functions
-- Parse and load JSON-LD metadata and variable definitions into backbone tables.

-- ---------------------------------------------------------------------------
-- backbone.parse_partial_date
-- Parse a JSON-LD date that may be given only to the year ("2021") or the month ("2021-03").
-- With p_end = FALSE the first day of the period is returned (2021-01-01, 2021-03-01), with
-- p_end = TRUE the last (2021-12-31, 2021-03-31). A full date or an ISO timestamp gives its date.
-- NULL when the text is empty or not a date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.parse_partial_date(p_text TEXT, p_end BOOLEAN DEFAULT FALSE)
RETURNS DATE AS $$
DECLARE
    t TEXT := btrim(p_text);
    d DATE;
BEGIN
    IF t IS NULL OR t = '' THEN
        RETURN NULL;
    ELSIF t ~ '^[0-9]{4}$' THEN
        RETURN CASE WHEN p_end THEN make_date(t::int, 12, 31) ELSE make_date(t::int, 1, 1) END;
    ELSIF t ~ '^[0-9]{4}-[0-9]{2}$' THEN
        d := (t || '-01')::date;
        RETURN CASE WHEN p_end THEN (d + interval '1 month - 1 day')::date ELSE d END;
    END IF;
    RETURN left(t, 10)::date;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.infer_dataset_year
-- The year a dataset stands for when its metadata gives no dates at all: the leading year of the
-- dataset name ("2021 Miami-Dade NLCD Land Cover") or the year after the first segment of the
-- table_id (mdc_2021_nlcd_land_cover). When both are present they must agree. NULL otherwise.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.infer_dataset_year(p_table_id TEXT, p_name TEXT)
RETURNS INTEGER AS $$
    SELECT CASE WHEN id_year IS NOT NULL AND name_year IS NOT NULL AND id_year <> name_year THEN NULL
                ELSE COALESCE(id_year, name_year) END
    FROM (SELECT substring(p_table_id from '^[^_]+_((?:19|20)[0-9]{2})_')::int AS id_year,
                 substring(p_name from '^\s*((?:19|20)[0-9]{2})(?![0-9])')::int AS name_year) y;
$$ LANGUAGE sql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.dataset_year_conflict
-- TRUE when the table_id and the dataset name each carry a year (see infer_dataset_year) and the
-- years differ: the year of the dataset is then unclear and is not guessed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.dataset_year_conflict(p_table_id TEXT, p_name TEXT)
RETURNS BOOLEAN AS $$
    SELECT COALESCE(id_year <> name_year, FALSE)
    FROM (SELECT substring(p_table_id from '^[^_]+_((?:19|20)[0-9]{2})_')::int AS id_year,
                 substring(p_name from '^\s*((?:19|20)[0-9]{2})(?![0-9])')::int AS name_year) y;
$$ LANGUAGE sql IMMUTABLE;


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
    v_structure       TEXT;
    v_coverage        TEXT;
    v_cov_start       DATE;
    v_cov_end         DATE;
    v_name_year       INTEGER;
    v_year_conflict   BOOLEAN := FALSE;
    v_static_marked   BOOLEAN := FALSE;
    v_date_note       TEXT;
    v_numeric         BOOLEAN;
    -- period of an attribute that does not change over time (a DEM, a boundary's area): like a
    -- geometry-only source it is valid whenever a location is
    v_static_start    CONSTANT DATE := DATE '1900-01-01';
    v_static_end      CONSTANT DATE := DATE '2100-12-31';
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

    -- Dataset-level fallbacks for variables without dates: the temporalCoverage ("2014-01-01/2019-12-31",
    -- or a single year or date), and for raster sources the year in the name or table_id.
    v_coverage := NULLIF(btrim(jsonld_data->>'temporalCoverage'), '');
    IF v_coverage IS NOT NULL THEN
        v_cov_start := backbone.parse_partial_date(split_part(v_coverage, '/', 1), FALSE);
        v_cov_end   := backbone.parse_partial_date(COALESCE(NULLIF(split_part(v_coverage, '/', 2), ''), split_part(v_coverage, '/', 1)), TRUE);
        IF v_cov_start IS NULL OR v_cov_end IS NULL THEN
            v_cov_start := NULL; v_cov_end := NULL;
        END IF;
    END IF;

    -- A dataset can declare that its attributes do not change over time with
    --   "additionalProperty": [{"@type": "PropertyValue", "name": "temporalDimension", "value": "static"}]
    SELECT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(jsonld_data->'additionalProperty') = 'array'
                                       THEN jsonld_data->'additionalProperty' ELSE '[]'::jsonb END) ap
        WHERE lower(ap->>'name') = 'temporaldimension' AND lower(ap->>'value') = 'static'
    ) INTO v_static_marked;

    SELECT lower(elem->>'termCode') INTO v_structure
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(jsonld_data->'measurementTechnique') = 'array'
                                   THEN jsonld_data->'measurementTechnique' ELSE '[]'::jsonb END) elem
    WHERE elem->'inDefinedTermSet'->>'name' = 'dataRepresentation'
    LIMIT 1;
    IF v_structure = 'raster' THEN
        v_name_year := backbone.infer_dataset_year(v_table_id, v_dataset_name);
        v_year_conflict := backbone.dataset_year_conflict(v_table_id, v_dataset_name);
    END IF;

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

        -- Dates are ISO (YYYY-MM-DD), but a year ("2021") or a month ("2021-03") is accepted: it stands for
        -- the whole period (1 January to 31 December). When only one end is given the other is the end of
        -- the same period, so startDate "2021" alone is the year 2021. A variable without dates takes the
        -- dataset's temporalCoverage (a raster, or a numeric or jsonb variable: identifiers and names stay
        -- unregistered), then the static period (1900-01-01 to 2100-12-31) when the dataset is
        -- marked temporalDimension static (a raster, or a variable with a numeric qudt:dataType: identifiers and
        -- names stay unregistered), then for a raster the year in its name or table_id; a raster with
        -- no date at all is static, unless its name and table_id disagree on a year.
        -- Other vector sources are not given a default: many of their variables are undated on purpose
        -- (identifiers, names, attributes of a vintage), and registering them all would load every one of them.
        v_date_note := NULL;
        v_numeric := lower(COALESCE(v_variable->>'qudt:dataType', '')) IN (
            'float', 'float4', 'float8', 'real', 'double', 'double precision', 'numeric', 'decimal', 'number',
            'int', 'int2', 'int4', 'int8', 'int16', 'int32', 'int64', 'smallint', 'integer', 'bigint', 'long', 'short');
        v_start_date := backbone.parse_partial_date(v_variable->>'startDate', FALSE);
        v_end_date   := backbone.parse_partial_date(v_variable->>'endDate', TRUE);
        IF v_start_date IS NULL AND v_end_date IS NOT NULL THEN
            v_start_date := backbone.parse_partial_date(v_variable->>'endDate', FALSE);
            v_date_note := 'the period of endDate';
        ELSIF v_end_date IS NULL AND v_start_date IS NOT NULL THEN
            v_end_date := backbone.parse_partial_date(v_variable->>'startDate', TRUE);
            v_date_note := 'the period of startDate';
        ELSIF v_start_date IS NULL AND v_end_date IS NULL THEN
            IF v_cov_start IS NOT NULL AND (v_structure = 'raster' OR v_numeric
                    OR lower(COALESCE(v_variable->>'qudt:dataType', '')) IN ('jsonb', 'json')) THEN
                v_start_date := v_cov_start; v_end_date := v_cov_end;
                v_date_note := 'the dataset temporalCoverage';
            ELSIF v_static_marked AND (v_structure = 'raster' OR v_numeric) THEN
                v_start_date := v_static_start; v_end_date := v_static_end;
                v_date_note := 'the static period (the dataset is marked temporalDimension static)';
            ELSIF v_name_year IS NOT NULL THEN
                v_start_date := make_date(v_name_year, 1, 1); v_end_date := make_date(v_name_year, 12, 31);
                v_date_note := 'the year in the dataset name or table_id';
            ELSIF v_structure = 'raster' AND NOT v_year_conflict THEN
                v_start_date := v_static_start; v_end_date := v_static_end;
                v_date_note := 'the static period (no date anywhere in the metadata)';
            END IF;
        END IF;
        IF v_date_note IS NOT NULL THEN
            RAISE NOTICE 'Variable "%": dates % to % taken from %', v_variable->>'name', v_start_date, v_end_date, v_date_note;
        END IF;

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
                    variable_source_id,
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
                    (SELECT vs.variable_source_id FROM backbone.variable_source vs
                     WHERE vs.data_source_uuid = p_data_source_uuid
                       AND vs.variable_name = v_variable->>'name'),
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
        ELSE
            UPDATE backbone.attr_index ai
            SET variable_source_id = vs.variable_source_id
            FROM backbone.variable_source vs
            WHERE vs.data_source_uuid = p_data_source_uuid
              AND vs.variable_name = v_variable->>'name'
              AND ai.table_name = v_table_id
              AND ai.variable_name = v_variable->>'name'
              AND ai.variable_source_id IS NULL;
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

    IF backbone.is_recipe(v_jsonld) THEN
        -- a recipe (sql/08b_recipe_ingestion.sql; the functions are looked up when this one runs)
        v_data_source_uuid := backbone.ingest_recipe_metadata(v_jsonld);
        v_dataset_name     := v_jsonld->>'schema:name';
        v_var_count        := backbone.ingest_recipe_variables(v_jsonld, v_data_source_uuid);
    ELSE
        v_data_source_uuid := backbone.ingest_jsonld_metadata(v_jsonld);
        v_dataset_name     := v_jsonld->>'name';
        v_var_count        := backbone.ingest_jsonld_variables(v_jsonld, v_data_source_uuid);
    END IF;

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
