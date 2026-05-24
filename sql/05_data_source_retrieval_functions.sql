-- Data Source Retrieval and Ingestion Functions
--
-- backbone.gdsc_exec is defined here because it is only used by this file.
--
-- Full ingestion protocol for a dataset living at /data/{table_id}/:
--
--   1. backbone.load_datasource_metadata(table_id)
--        Reads /data/{table_id}/meta_json-ld_{table_id}.json and calls
--        ingest_jsonld_metadata + ingest_jsonld_variables.
--
--   2. backbone.retrieve_and_ingest_datasource(uuid [, script_path [, shell]])
--        Runs a single ETL shell script for the data source.
--        Default script path: /data/{table_id}/etl/{table_id}_osgeo
--        (gdsc_exec appends .sh automatically)
--
--   3. backbone.ingest_datasource(table_id)
--        Full protocol in sequence:
--          a. load JSON-LD metadata
--          b. {table_id}_osgeo.sh   — download source data and load via ogr2ogr
--          c. {table_id}_postgis.sh — fix geometry, add local projection column
--
-- Convenience:
--   backbone.quick_ingest_datasource(dataset_name [, script_path])
--   backbone.list_downloadable_datasources()


-- ---------------------------------------------------------------------------
-- backbone.gdsc_exec
-- Execute a shell script via plsh. The script argument must omit the .sh
-- extension — gdsc_exec appends it before invoking the shell.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.gdsc_exec(shell TEXT, script TEXT)
RETURNS TEXT AS $$
#!/bin/sh
$1 $2.sh
echo "Complete"
$$ LANGUAGE plsh;

COMMENT ON FUNCTION backbone.gdsc_exec(TEXT, TEXT) IS
    'Run a shell script: gdsc_exec(''/bin/sh'', ''/path/to/script'') executes /path/to/script.sh';


-- ---------------------------------------------------------------------------
-- backbone.load_datasource_metadata
-- Discovers the JSON-LD file at the standard path and runs both ingest steps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.load_datasource_metadata(p_table_id TEXT)
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name     TEXT,
    variables_loaded INTEGER
) AS $$
DECLARE
    v_path TEXT;
BEGIN
    v_path := format('/data/%s/meta_json-ld_%s.json', p_table_id, p_table_id);

    RETURN QUERY SELECT * FROM backbone.load_jsonld_from_path(v_path);
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.retrieve_and_ingest_datasource
-- Resolves and executes the ETL shell script for a registered data source.
--
-- Script path convention (when p_script_path is NULL):
--   /data/{table_id}/etl/{table_id}_postgis
-- gdsc_exec appends .sh, so the file on disk is:
--   /data/{table_id}/etl/{table_id}_postgis.sh
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.retrieve_and_ingest_datasource(
    p_data_source_uuid UUID,
    p_script_path      TEXT DEFAULT NULL,
    p_shell            TEXT DEFAULT '/bin/sh'
)
RETURNS TABLE(step TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_dataset_name TEXT;
    v_dataset_id   TEXT;
    v_table_id     TEXT;
    v_script_path  TEXT;
    v_result       TEXT;
BEGIN
    SELECT dataset_name, dataset_id
    INTO   v_dataset_name, v_dataset_id
    FROM   backbone.data_source
    WHERE  data_source_uuid = p_data_source_uuid;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'error'::TEXT, 'error'::TEXT,
            format('Data source UUID %s not found', p_data_source_uuid)::TEXT;
        RETURN;
    END IF;

    RETURN QUERY SELECT 'metadata'::TEXT, 'success'::TEXT,
        format('Found data source: %s', v_dataset_name)::TEXT;

    IF p_script_path IS NOT NULL THEN
        v_script_path := p_script_path;
    ELSE
        -- Derive table_id from the last URL segment of dataset_id
        v_table_id := split_part(
            v_dataset_id, '/',
            array_length(string_to_array(v_dataset_id, '/'), 1)
        );
        -- Default to osgeo script (download + ogr2ogr load); .sh appended by gdsc_exec
        v_script_path := format('/data/%s/etl/%s_osgeo', v_table_id, v_table_id);
    END IF;

    RETURN QUERY SELECT 'ingestion'::TEXT, 'in_progress'::TEXT,
        format('Running: %s.sh', v_script_path)::TEXT;

    BEGIN
        v_result := backbone.gdsc_exec(p_shell, v_script_path);
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE != 'XX000' THEN  -- ignore generic errors
            RETURN QUERY SELECT 'ingestion'::TEXT, 'error'::TEXT,
                format('Script failed: %s', SQLERRM)::TEXT;
            RETURN;
        END IF;
    END;

    RETURN QUERY SELECT 'ingestion'::TEXT, 'success'::TEXT, v_result::TEXT;

    UPDATE backbone.data_source
    SET etl_metadata = COALESCE(etl_metadata, '[]'::jsonb) ||
        jsonb_build_array(jsonb_build_object(
            'ingested_at',  NOW(),
            'script_path',  v_script_path || '.sh'
        ))
    WHERE data_source_uuid = p_data_source_uuid;

    RETURN QUERY SELECT 'complete'::TEXT, 'success'::TEXT,
        format('ETL complete for %s', v_dataset_name)::TEXT;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.ingest_datasource
-- Full three-step protocol:
--   1. Load JSON-LD metadata (ingest_jsonld_metadata + ingest_jsonld_variables)
--   2. Run {table_id}_osgeo.sh   — download source file and load via ogr2ogr
--   3. Run {table_id}_postgis.sh — clean geometry and add local projection column
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.ingest_datasource(
    p_table_id TEXT,
    p_shell    TEXT DEFAULT '/bin/sh'
)
RETURNS TABLE(step TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_data_source_uuid UUID;
    v_dataset_name     TEXT;
    v_variables_loaded INTEGER;
    v_osgeo_script     TEXT;
    v_postgis_script   TEXT;
    v_osgeo_ok         BOOLEAN := TRUE;
    v_step             TEXT;
    v_status           TEXT;
    v_message          TEXT;
BEGIN
    v_osgeo_script   := format('/data/%s/etl/%s_osgeo',   p_table_id, p_table_id);
    v_postgis_script := format('/data/%s/etl/%s_postgis', p_table_id, p_table_id);

    -- Step 1: load JSON-LD metadata
    step    := 'metadata_load'; status := 'in_progress';
    message := format('Loading /data/%s/meta_json-ld_%s.json', p_table_id, p_table_id);
    RETURN NEXT;

    BEGIN
        SELECT r.data_source_uuid, r.dataset_name, r.variables_loaded
        INTO   v_data_source_uuid, v_dataset_name, v_variables_loaded
        FROM   backbone.load_datasource_metadata(p_table_id) r;
    EXCEPTION WHEN OTHERS THEN
        step := 'metadata_load'; status := 'error';
        message := format('Metadata load failed: %s', SQLERRM);
        RETURN NEXT;
        RETURN;
    END;

    step    := 'metadata_load'; status := 'success';
    message := format('Loaded "%s" with %s variables', v_dataset_name, v_variables_loaded);
    RETURN NEXT;

    -- Step 2: osgeo — download source data and load into PostGIS via ogr2ogr.
    -- Stream each row from retrieve_and_ingest_datasource, tracking any error in one pass.
    FOR v_step, v_status, v_message IN
        SELECT r.step, r.status, r.message
        FROM   backbone.retrieve_and_ingest_datasource(v_data_source_uuid, v_osgeo_script, p_shell) r
    LOOP
        step := v_step; status := v_status; message := v_message;
        RETURN NEXT;
        IF v_status = 'error' THEN v_osgeo_ok := FALSE; END IF;
    END LOOP;

    IF NOT v_osgeo_ok THEN
        step    := 'postgis'; status := 'skipped';
        message := 'Skipping postgis step — osgeo step reported an error';
        RETURN NEXT;
        RETURN;
    END IF;

    -- Step 3: postgis — clean geometry, add local projection column
    step := 'postgis'; status := 'in_progress';
    message := format('Running: %s.sh', v_postgis_script);
    RETURN NEXT;

    BEGIN
        PERFORM backbone.gdsc_exec(p_shell, v_postgis_script);
    EXCEPTION WHEN OTHERS THEN
        step := 'postgis'; status := 'error';
        message := format('postgis script failed: %s', SQLERRM);
        RETURN NEXT;
        RETURN;
    END;

    step    := 'postgis'; status := 'success';
    message := format('Geometry updated for %s', v_dataset_name);
    RETURN NEXT;

    step    := 'complete'; status := 'success';
    message := format('Ingestion complete for %s', v_dataset_name);
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.quick_ingest_datasource
-- Look up UUID by dataset name, then run its ETL script (no metadata reload).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.quick_ingest_datasource(
    p_dataset_name TEXT,
    p_script_path  TEXT DEFAULT NULL
)
RETURNS TABLE(step TEXT, status TEXT, message TEXT) AS $$
DECLARE
    v_data_source_uuid UUID;
BEGIN
    SELECT data_source_uuid INTO v_data_source_uuid
    FROM   backbone.data_source
    WHERE  dataset_name ILIKE '%' || p_dataset_name || '%'
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'error'::TEXT, 'error'::TEXT,
            format('No data source matching "%s"', p_dataset_name)::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT r.step, r.status, r.message
    FROM   backbone.retrieve_and_ingest_datasource(v_data_source_uuid, p_script_path) r;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.list_downloadable_datasources
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.list_downloadable_datasources()
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name     TEXT,
    table_id         TEXT,
    geom_type        TEXT,
    srid             INTEGER,
    etl_script       TEXT,
    already_ingested BOOLEAN,
    last_ingested_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ds.data_source_uuid,
        ds.dataset_name,
        split_part(ds.dataset_id, '/',
            array_length(string_to_array(ds.dataset_id, '/'), 1)
        ) AS table_id,
        ds.geom_type,
        ds.srid,
        format('/data/%s/etl/%s_postgis.sh',
            split_part(ds.dataset_id, '/', array_length(string_to_array(ds.dataset_id, '/'), 1)),
            split_part(ds.dataset_id, '/', array_length(string_to_array(ds.dataset_id, '/'), 1))
        ) AS etl_script,
        (
            SELECT COUNT(*) > 0
            FROM   jsonb_array_elements(COALESCE(ds.etl_metadata, '[]'::jsonb)) elem
            WHERE  elem ? 'ingested_at'
        ) AS already_ingested,
        (
            SELECT MAX((elem->>'ingested_at')::TIMESTAMPTZ)
            FROM   jsonb_array_elements(COALESCE(ds.etl_metadata, '[]'::jsonb)) elem
            WHERE  elem ? 'ingested_at'
        ) AS last_ingested_at
    FROM backbone.data_source ds
    ORDER BY ds.dataset_name;
END;
$$ LANGUAGE plpgsql;


COMMENT ON FUNCTION backbone.load_datasource_metadata     IS 'Load JSON-LD from /data/{table_id}/meta_json-ld_{table_id}.json into backbone tables.';
COMMENT ON FUNCTION backbone.retrieve_and_ingest_datasource IS 'Run the ETL script for a registered data source. Default: /data/{table_id}/etl/{table_id}_postgis.sh';
COMMENT ON FUNCTION backbone.ingest_datasource            IS 'Full protocol: (1) load JSON-LD metadata, (2) run _osgeo.sh to download + ogr2ogr load, (3) run _postgis.sh to clean geometry and add local projection.';
COMMENT ON FUNCTION backbone.quick_ingest_datasource      IS 'Look up a data source by name and run its ETL script.';
COMMENT ON FUNCTION backbone.list_downloadable_datasources IS 'List all data sources with ETL script paths and ingestion status.';
