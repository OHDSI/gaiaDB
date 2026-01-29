-- Data Source Retrieval and Ingestion Functions
-- Functions to download, extract, and ingest external data sources using ogr2ogr

-- Enable plsh extension for shell commands (if not already enabled)
-- Note: plsh must be installed in the Docker image
-- CREATE EXTENSION IF NOT EXISTS plsh;

-- Function to download and extract files (based on gis_note_misc2.txt)
CREATE OR REPLACE FUNCTION backbone.fetch_and_extract_file(
    url TEXT,
    destination TEXT,
    compression TEXT DEFAULT NULL,
    extracted_file TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
#!/bin/sh

# Create destination directory
mkdir -p "$(dirname "$2")"

# Download file
echo "Downloading from $1..."
curl -s -S -L --connect-timeout 30 --max-time 300 -o "$2" -- "$1"

if [ ! -f "$2" ] || [ ! -s "$2" ]; then
    echo "Error: Download failed - file not found or empty"
    exit 1
fi

echo "Download successful: $2"

# Extract if compression type specified
if [ -n "$3" ]; then
    case "$3" in
        zip)
            echo "Extracting ZIP archive..."
            unzip -o "$2" -d "$(dirname "$2")"
            echo "Extracted to: $(dirname "$2")"
            ;;
        tar.gz|tgz)
            echo "Extracting TAR.GZ archive..."
            tar -xzf "$2" -C "$(dirname "$2")"
            echo "Extracted to: $(dirname "$2")"
            ;;
        tar)
            echo "Extracting TAR archive..."
            tar -xf "$2" -C "$(dirname "$2")"
            echo "Extracted to: $(dirname "$2")"
            ;;
        gz)
            echo "Extracting GZ file..."
            gunzip -f "$2"
            echo "Extracted: $(dirname "$2")/$(basename "$2" .gz)"
            ;;
        *)
            echo "Unknown compression type: $3. No extraction performed."
            ;;
    esac
else
    echo "No extraction needed."
fi

echo "Complete: $2"
$$ LANGUAGE plsh;

-- Function to ingest raw spatial data using ogr2ogr (based on gis_note_misc2.txt line 35)
CREATE OR REPLACE FUNCTION backbone.ingest_raw_data(
    file_path TEXT,
    table_name TEXT,
    schema_name TEXT DEFAULT 'public',
    srid INTEGER DEFAULT 4326,
    geometry_column TEXT DEFAULT 'wgs_geom',
    geometry_type TEXT DEFAULT NULL,
    additional_options TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
#!/bin/sh

# Build ogr2ogr command
DB_CONN="dbname=gaiacore user=postgres"
OPTIONS="-f PostgreSQL"

# Add geometry column name
OPTIONS="$OPTIONS -lco GEOMETRY_NAME=$5"

# Add FID column
OPTIONS="$OPTIONS -lco FID=gid"

# Set target SRID
OPTIONS="$OPTIONS -t_srs EPSG:$4"

# Add geometry type if specified
if [ -n "$6" ]; then
    OPTIONS="$OPTIONS -nlt $6"
fi

# Add schema to table name if specified
if [ "$3" != "public" ]; then
    FULL_TABLE="$3.$2"
else
    FULL_TABLE="$2"
fi

# Add any additional options
if [ -n "$7" ]; then
    OPTIONS="$OPTIONS $7"
fi

# Execute ogr2ogr
echo "Importing $1 into $FULL_TABLE..."
echo "Command: ogr2ogr $OPTIONS PG:\"$DB_CONN\" \"$1\" -nln $FULL_TABLE"

ogr2ogr $OPTIONS PG:"$DB_CONN" "$1" -nln "$FULL_TABLE"

if [ $? -eq 0 ]; then
    echo "Successfully imported $1 into $FULL_TABLE"
else
    echo "Error: Import failed"
    exit 1
fi
$$ LANGUAGE plsh;

-- Function to ingest SQL-based data sources
CREATE OR REPLACE FUNCTION backbone.ingest_sql_data(
    file_path TEXT,
    schema_name TEXT DEFAULT 'public'
)
RETURNS TEXT AS $$
#!/bin/sh

# Check if file is gzip compressed
if file "$1" | grep -q "gzip compressed"; then
    echo "File is gzip compressed, decompressing..."
    # Decompress using zcat (reads gzip regardless of extension)
    SQL_FILE="${1%.sql}_decompressed.sql"
    zcat "$1" > "$SQL_FILE"
    if [ ! -f "$SQL_FILE" ] || [ ! -s "$SQL_FILE" ]; then
        echo "Error: Decompression failed"
        exit 1
    fi
    echo "Decompressed to: $SQL_FILE"
else
    SQL_FILE="$1"
fi

# Clean the SQL file - remove everything before "-- PostgreSQL database dump"
CLEANED_FILE="${SQL_FILE%.sql}_cleaned.sql"
if grep -q "^-- PostgreSQL database dump" "$SQL_FILE"; then
    echo "Cleaning SQL file - removing header lines..."
    sed -n '/^-- PostgreSQL database dump/,$p' "$SQL_FILE" > "$CLEANED_FILE"
    SQL_FILE="$CLEANED_FILE"
    echo "Cleaned SQL file ready"
fi

echo "Executing SQL file: $SQL_FILE"
psql "dbname=gaiacore user=postgres" -f "$SQL_FILE"
echo "Successfully executed SQL file: $SQL_FILE"
$$ LANGUAGE plsh;

-- Function to process ETL metadata from JSON-LD
CREATE OR REPLACE FUNCTION backbone.extract_etl_info_from_jsonld(
    p_data_source_uuid UUID
)
RETURNS TABLE(
    download_url TEXT,
    file_format TEXT,
    compression_type TEXT,
    processing_notes TEXT
) AS $$
DECLARE
    v_wget_action jsonb;
    v_download_url TEXT;
BEGIN
    -- Find the 'etl_metadata' array element where potentialAction->name = 'Pseudo Code'
    SELECT elem INTO v_wget_action
    FROM backbone.data_source ds,
         jsonb_array_elements(ds.etl_metadata) elem
    WHERE ds.data_source_uuid = p_data_source_uuid
      AND elem->'potentialAction'->>'name' = 'Pseudo Code'
    LIMIT 1;

    -- Extract download URL from the wget action result or fall back to distribution
    SELECT COALESCE(
        v_wget_action->'potentialAction'->'result'->>'url',
        v_wget_action->'potentialAction'->'object'->>'url',
        ds.etl_metadata->'distribution'->>0
    ) INTO v_download_url
    FROM backbone.data_source ds
    WHERE ds.data_source_uuid = p_data_source_uuid;

    -- Return the extracted information
    RETURN QUERY
    SELECT
        v_download_url as download_url,
        -- Extract file format
        COALESCE(
            v_wget_action->'potentialAction'->'result'->>'encodingFormat',
            'shapefile'
        ) as file_format,
        -- Determine compression from URL or format
        CASE
            WHEN v_download_url LIKE '%.zip' THEN 'zip'
            WHEN v_download_url LIKE '%.tar.gz' THEN 'tar.gz'
            WHEN v_download_url LIKE '%.tgz' THEN 'tar.gz'
            ELSE NULL
        END as compression_type,
        -- Extract processing notes
        v_wget_action->'potentialAction'->>'description' as processing_notes;
END;
$$ LANGUAGE plpgsql;

-- Main function to retrieve and ingest a data source
CREATE OR REPLACE FUNCTION backbone.retrieve_and_ingest_datasource(
    p_data_source_uuid UUID,
    p_download_url TEXT DEFAULT NULL,
    p_target_schema TEXT DEFAULT 'public',
    p_target_table TEXT DEFAULT NULL,
    p_work_directory TEXT DEFAULT '/var/lib/postgresql/data/workdir',
    p_keep_downloaded BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    step TEXT,
    status TEXT,
    message TEXT,
    details JSONB
) AS $$
DECLARE
    v_dataset_name TEXT;
    v_dataset_id TEXT;
    v_download_url TEXT;
    v_file_format TEXT;
    v_compression_type TEXT;
    v_processing_notes TEXT;
    v_table_name TEXT;
    v_file_name TEXT;
    v_download_path TEXT;
    v_extracted_path TEXT;
    v_result TEXT;
    v_geom_type TEXT;
    v_measurement_technique JSONB;
BEGIN
    -- Step 1: Get data source metadata
    RETURN QUERY SELECT 'metadata_retrieval'::TEXT, 'in_progress'::TEXT,
        'Retrieving data source metadata'::TEXT, NULL::JSONB;

    SELECT
        ds.dataset_name,
        ds.dataset_id,
        ds.geom_type,
        ds.measurement_technique
    INTO
        v_dataset_name,
        v_dataset_id,
        v_geom_type,
        v_measurement_technique
    FROM backbone.data_source ds
    WHERE ds.data_source_uuid = p_data_source_uuid;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'metadata_retrieval'::TEXT, 'error'::TEXT,
            format('Data source UUID %s not found', p_data_source_uuid)::TEXT,
            NULL::JSONB;
        RETURN;
    END IF;

    RETURN QUERY SELECT 'metadata_retrieval'::TEXT, 'success'::TEXT,
        format('Retrieved metadata for: %s', v_dataset_name)::TEXT,
        jsonb_build_object(
            'dataset_name', v_dataset_name,
            'dataset_id', v_dataset_id,
            'geom_type', v_geom_type
        );

    -- Step 2: Extract ETL information from JSON-LD
    RETURN QUERY SELECT 'etl_info_extraction'::TEXT, 'in_progress'::TEXT,
        'Extracting ETL information from metadata'::TEXT, NULL::JSONB;

    SELECT * INTO v_download_url, v_file_format, v_compression_type, v_processing_notes
    FROM backbone.extract_etl_info_from_jsonld(p_data_source_uuid);

    -- Override with provided URL if given
    IF p_download_url IS NOT NULL THEN
        v_download_url := p_download_url;
        -- Auto-detect compression from URL
        IF v_download_url LIKE '%.zip' THEN
            v_compression_type := 'zip';
        ELSIF v_download_url LIKE '%.tar.gz' OR v_download_url LIKE '%.tgz' THEN
            v_compression_type := 'tar.gz';
        END IF;
    END IF;

    IF v_download_url IS NULL THEN
        RETURN QUERY SELECT 'etl_info_extraction'::TEXT, 'error'::TEXT,
            'No download URL found in metadata or provided as parameter'::TEXT,
            NULL::JSONB;
        RETURN;
    END IF;

    RETURN QUERY SELECT 'etl_info_extraction'::TEXT, 'success'::TEXT,
        'ETL information extracted'::TEXT,
        jsonb_build_object(
            'download_url', v_download_url,
            'file_format', v_file_format,
            'compression_type', v_compression_type
        );

    -- Step 3: Determine table name
    v_table_name := COALESCE(
        p_target_table,
        LOWER(REGEXP_REPLACE(v_dataset_name, '[^a-zA-Z0-9_]', '_', 'g'))
    );

    -- Step 4: Download and extract file
    RETURN QUERY SELECT 'download'::TEXT, 'in_progress'::TEXT,
        format('Downloading from: %s', v_download_url)::TEXT,
        NULL::JSONB;

    -- Extract filename from URL, handling query parameters
    v_file_name := split_part(v_download_url, '/', array_length(string_to_array(v_download_url, '/'), 1));
    v_file_name := split_part(v_file_name, '?', 1); -- Remove query parameters

    -- If filename is empty or just a query string, use dataset name
    IF v_file_name = '' OR v_file_name IS NULL THEN
        v_file_name := format('%s.%s',
            LOWER(REGEXP_REPLACE(v_dataset_name, '[^a-zA-Z0-9_]', '_', 'g')),
            COALESCE(v_file_format, 'dat')
        );
    END IF;

    v_download_path := format('%s/%s', p_work_directory, v_file_name);

    BEGIN
        RAISE NOTICE 'Starting download from: %', v_download_url;
        RAISE NOTICE 'Download destination: %', v_download_path;

        v_result := backbone.fetch_and_extract_file(
            v_download_url,
            v_download_path,
            v_compression_type
        );

        RAISE NOTICE 'Download completed successfully';
        RAISE NOTICE 'Download result: %', v_result;

        RETURN QUERY SELECT 'download'::TEXT, 'success'::TEXT,
            v_result::TEXT,
            jsonb_build_object('download_path', v_download_path);

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Download failed with error: %', SQLERRM;
        RETURN QUERY SELECT 'download'::TEXT, 'error'::TEXT,
            format('Download failed: %s', SQLERRM)::TEXT,
            jsonb_build_object('error', SQLERRM);
        RETURN;
    END;

    -- Step 5: Determine extracted file path
    IF v_compression_type = 'zip' THEN
        -- For shapefiles in zip, need to find the .shp file
        v_extracted_path := format('%s/%s.shp',
            p_work_directory,
            regexp_replace(v_file_name, '\.zip$', '', 'i')
        );
    ELSIF v_compression_type IS NOT NULL THEN
        v_extracted_path := regexp_replace(v_download_path, '\.(tar\.gz|tgz|gz)$', '', 'i');
    ELSE
        v_extracted_path := v_download_path;
    END IF;

    -- Step 6: Ingest into PostgreSQL using appropriate method
    RETURN QUERY SELECT 'ingestion'::TEXT, 'in_progress'::TEXT,
        format('Ingesting into %s.%s using %s method', p_target_schema, v_table_name,
               CASE WHEN v_file_format = 'sql' THEN 'SQL' ELSE 'ogr2ogr' END)::TEXT,
        NULL::JSONB;

    BEGIN
        -- Check if this is a SQL file
        IF v_file_format = 'sql' OR v_extracted_path LIKE '%.sql' THEN
            -- Use SQL ingestion method
            v_result := backbone.ingest_sql_data(
                v_extracted_path,
                p_target_schema
            );

            RETURN QUERY SELECT 'ingestion'::TEXT, 'success'::TEXT,
                v_result::TEXT,
                jsonb_build_object(
                    'schema', p_target_schema,
                    'method', 'sql',
                    'message', 'SQL file executed successfully'
                );
        ELSE
            -- Use ogr2ogr for spatial data formats
            -- Determine geometry type from measurement technique
            IF v_measurement_technique IS NOT NULL THEN
                v_geom_type := v_measurement_technique->1->>'termCode';
                IF v_geom_type = 'multipolygon' THEN
                    v_geom_type := 'MULTIPOLYGON';
                ELSIF v_geom_type = 'polygon' THEN
                    v_geom_type := 'POLYGON';
                ELSIF v_geom_type = 'point' THEN
                    v_geom_type := 'POINT';
                ELSIF v_geom_type = 'line' THEN
                    v_geom_type := 'LINESTRING';
                END IF;
            END IF;

            v_result := backbone.ingest_raw_data(
                v_extracted_path,
                v_table_name,
                p_target_schema,
                4326, -- SRID
                'wgs_geom', -- geometry column name
                v_geom_type -- geometry type
            );

            RETURN QUERY SELECT 'ingestion'::TEXT, 'success'::TEXT,
                v_result::TEXT,
                jsonb_build_object(
                    'schema', p_target_schema,
                    'table', v_table_name,
                    'method', 'ogr2ogr',
                    'full_name', format('%s.%s', p_target_schema, v_table_name)
                );
        END IF;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'ingestion'::TEXT, 'error'::TEXT,
            format('Ingestion failed: %s', SQLERRM)::TEXT,
            jsonb_build_object('error', SQLERRM);
        RETURN;
    END;

    -- Step 7: Create spatial index (only for non-SQL data sources)
    IF v_file_format != 'sql' AND v_extracted_path NOT LIKE '%.sql' THEN
        RETURN QUERY SELECT 'indexing'::TEXT, 'in_progress'::TEXT,
            'Creating spatial index'::TEXT,
            NULL::JSONB;

        BEGIN
            EXECUTE format(
                'CREATE INDEX IF NOT EXISTS idx_%I_wgs_geom ON %I.%I USING GIST(wgs_geom)',
                v_table_name,
                p_target_schema,
                v_table_name
            );

            RETURN QUERY SELECT 'indexing'::TEXT, 'success'::TEXT,
                format('Created spatial index on %s.%s', p_target_schema, v_table_name)::TEXT,
                NULL::JSONB;

        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT 'indexing'::TEXT, 'warning'::TEXT,
                format('Could not create index: %s', SQLERRM)::TEXT,
                jsonb_build_object('error', SQLERRM);
        END;
    ELSE
        RETURN QUERY SELECT 'indexing'::TEXT, 'skipped'::TEXT,
            'Skipping spatial index for SQL data source'::TEXT,
            NULL::JSONB;
    END IF;

    -- Step 8: Cleanup downloaded files (if requested)
    IF NOT p_keep_downloaded THEN
        RETURN QUERY SELECT 'cleanup'::TEXT, 'in_progress'::TEXT,
            'Removing downloaded files'::TEXT,
            NULL::JSONB;

        -- Note: File cleanup would require additional plsh function
        -- For now, just report what should be cleaned
        RETURN QUERY SELECT 'cleanup'::TEXT, 'info'::TEXT,
            format('Downloaded files at: %s', v_download_path)::TEXT,
            jsonb_build_object(
                'download_path', v_download_path,
                'note', 'Manual cleanup may be required'
            );
    END IF;

    -- Step 9: Update data source metadata with table location
    UPDATE backbone.data_source
    SET etl_metadata = COALESCE(etl_metadata, '{}'::jsonb) ||
        jsonb_build_object(
            'ingested_table', jsonb_build_object(
                'schema', p_target_schema,
                'table', v_table_name,
                'ingested_at', NOW()
            )
        )
    WHERE data_source_uuid = p_data_source_uuid;

    RETURN QUERY SELECT 'complete'::TEXT, 'success'::TEXT,
        format('Data source successfully ingested into %s.%s', p_target_schema, v_table_name)::TEXT,
        jsonb_build_object(
            'schema', p_target_schema,
            'table', v_table_name,
            'dataset_name', v_dataset_name
        );

END;
$$ LANGUAGE plpgsql;

-- Simplified wrapper function for quick ingestion
CREATE OR REPLACE FUNCTION backbone.quick_ingest_datasource(
    p_dataset_name TEXT,
    p_download_url TEXT DEFAULT NULL
)
RETURNS TABLE(
    step TEXT,
    status TEXT,
    message TEXT
) AS $$
DECLARE
    v_data_source_uuid UUID;
BEGIN
    -- Find data source by name
    SELECT data_source_uuid INTO v_data_source_uuid
    FROM backbone.data_source
    WHERE dataset_name ILIKE '%' || p_dataset_name || '%'
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'error'::TEXT, 'error'::TEXT,
            format('Data source matching "%s" not found', p_dataset_name)::TEXT;
        RETURN;
    END IF;

    -- Call main function
    RETURN QUERY
    SELECT r.step, r.status, r.message
    FROM backbone.retrieve_and_ingest_datasource(
        v_data_source_uuid,
        p_download_url
    ) r;
END;
$$ LANGUAGE plpgsql;

-- Function to list downloadable data sources
CREATE OR REPLACE FUNCTION backbone.list_downloadable_datasources()
RETURNS TABLE(
    data_source_uuid UUID,
    dataset_name TEXT,
    has_download_url BOOLEAN,
    download_url TEXT,
    file_format TEXT,
    already_ingested BOOLEAN,
    ingested_table TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ds.data_source_uuid,
        ds.dataset_name,
        -- Check if wget action with URL exists
        (
            SELECT COALESCE(
                elem->'potentialAction'->'result'->>'url',
                elem->'potentialAction'->'object'->>'url'
            ) IS NOT NULL
            FROM jsonb_array_elements(ds.etl_metadata) elem
            WHERE elem->'potentialAction'->>'name' = 'wget'
            LIMIT 1
        ) as has_download_url,
        -- Extract download URL from wget action or fall back to distribution
        COALESCE(
            (
                SELECT COALESCE(
                    elem->'potentialAction'->'result'->>'url',
                    elem->'potentialAction'->'object'->>'url'
                )
                FROM jsonb_array_elements(ds.etl_metadata) elem
                WHERE elem->'potentialAction'->>'name' = 'wget'
                LIMIT 1
            ),
            ds.etl_metadata->'distribution'->>0
        ) as download_url,
        -- Extract file format from wget action
        COALESCE(
            (
                SELECT elem->'potentialAction'->'result'->>'encodingFormat'
                FROM jsonb_array_elements(ds.etl_metadata) elem
                WHERE elem->'potentialAction'->>'name' = 'wget'
                LIMIT 1
            ),
            'unknown'
        ) as file_format,
        (ds.etl_metadata->'ingested_table') IS NOT NULL as already_ingested,
        COALESCE(
            format('%s.%s',
                ds.etl_metadata->'ingested_table'->>'schema',
                ds.etl_metadata->'ingested_table'->>'table'
            ),
            NULL
        ) as ingested_table
    FROM backbone.data_source ds
    ORDER BY ds.dataset_name;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backbone.fetch_and_extract_file IS 'Download and optionally extract compressed files from URL';
COMMENT ON FUNCTION backbone.ingest_raw_data IS 'Ingest spatial data using ogr2ogr (based on gis_note_misc2.txt line 35)';
COMMENT ON FUNCTION backbone.ingest_sql_data IS 'Ingest SQL-based data sources by executing SQL file';
COMMENT ON FUNCTION backbone.extract_etl_info_from_jsonld IS 'Extract ETL information from JSON-LD metadata by searching for wget action';
COMMENT ON FUNCTION backbone.retrieve_and_ingest_datasource IS 'Main function to download, extract, and ingest a data source (supports both spatial and SQL formats)';
COMMENT ON FUNCTION backbone.quick_ingest_datasource IS 'Simplified wrapper to ingest a data source by name';
COMMENT ON FUNCTION backbone.list_downloadable_datasources IS 'List all data sources with download information';
