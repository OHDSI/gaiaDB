-- Location Data Ingestion Functions
-- Functions to load LOCATION and LOCATION_HISTORY CSV data

-- Function to load LOCATION data from CSV
CREATE OR REPLACE FUNCTION working.load_location_csv(csv_path TEXT)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
    v_copy_sql TEXT;
BEGIN
    -- Create temporary table for CSV import
    CREATE TEMP TABLE IF NOT EXISTS temp_location (
        location_id INTEGER,
        address_1 TEXT,
        address_2 TEXT,
        city TEXT,
        state TEXT,
        zip TEXT,
        county TEXT,
        location_source_value TEXT,
        country_concept_id INTEGER,
        country_source_value TEXT,
        latitude DOUBLE PRECISION,
        longitude DOUBLE PRECISION
    ) ON COMMIT DROP;

    -- Copy CSV data
    v_copy_sql := format(
        'COPY temp_location FROM %L WITH (FORMAT csv, HEADER true, DELIMITER %L)',
        csv_path, ','
    );

    EXECUTE v_copy_sql;

    -- Insert into main location table with geometry
    INSERT INTO working.location (
        location_id,
        address_1,
        address_2,
        city,
        state,
        zip,
        county,
        location_source_value,
        country_concept_id,
        country_source_value,
        latitude,
        longitude,
        geom
    )
    SELECT
        location_id,
        address_1,
        address_2,
        city,
        state,
        zip,
        county,
        location_source_value,
        country_concept_id,
        country_source_value,
        latitude,
        longitude,
        ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
    FROM temp_location
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL
    ON CONFLICT (location_id) DO UPDATE SET
        address_1 = EXCLUDED.address_1,
        address_2 = EXCLUDED.address_2,
        city = EXCLUDED.city,
        state = EXCLUDED.state,
        zip = EXCLUDED.zip,
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        geom = EXCLUDED.geom;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Loaded % location records from %', v_count, csv_path;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Function to load LOCATION_HISTORY data from CSV
CREATE OR REPLACE FUNCTION working.load_location_history_csv(csv_path TEXT)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
    v_copy_sql TEXT;
BEGIN
    -- Create temporary table for CSV import
    CREATE TEMP TABLE IF NOT EXISTS temp_location_history (
        location_id INTEGER,
        relationship_type_concept_id INTEGER,
        domain_id INTEGER,
        entity_id INTEGER,
        start_date DATE,
        end_date DATE
    ) ON COMMIT DROP;

    -- Copy CSV data
    v_copy_sql := format(
        'COPY temp_location_history FROM %L WITH (FORMAT csv, HEADER true, DELIMITER %L)',
        csv_path, ','
    );

    EXECUTE v_copy_sql;

    -- Insert into main location_history table
    INSERT INTO working.location_history (
        location_id,
        relationship_type_concept_id,
        domain_id,
        entity_id,
        start_date,
        end_date
    )
    SELECT
        location_id,
        relationship_type_concept_id,
        domain_id,
        entity_id,
        start_date,
        end_date
    FROM temp_location_history
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Loaded % location history records from %', v_count, csv_path;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Combined function to load both LOCATION and LOCATION_HISTORY
CREATE OR REPLACE FUNCTION working.load_location_data(
    location_csv_path TEXT,
    location_history_csv_path TEXT
)
RETURNS TABLE(
    location_count INTEGER,
    location_history_count INTEGER
) AS $$
DECLARE
    v_loc_count INTEGER;
    v_hist_count INTEGER;
BEGIN
    -- Load locations first
    v_loc_count := working.load_location_csv(location_csv_path);

    -- Load location history
    v_hist_count := working.load_location_history_csv(location_history_csv_path);

    RETURN QUERY SELECT v_loc_count, v_hist_count;
END;
$$ LANGUAGE plpgsql;

-- Function to geocode addresses that are missing coordinates
CREATE OR REPLACE FUNCTION working.geocode_missing_locations()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
    v_location RECORD;
    v_full_address TEXT;
BEGIN
    -- This is a placeholder for geocoding functionality
    -- In production, this would integrate with a geocoding service
    -- For now, it just identifies records needing geocoding

    FOR v_location IN
        SELECT location_id, address_1, address_2, city, state, zip
        FROM working.location
        WHERE geom IS NULL AND address_1 IS NOT NULL
    LOOP
        v_full_address := CONCAT_WS(', ',
            v_location.address_1,
            NULLIF(v_location.address_2, ''),
            v_location.city,
            v_location.state,
            v_location.zip
        );

        RAISE NOTICE 'Location % needs geocoding: %', v_location.location_id, v_full_address;
        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE '% locations need geocoding', v_count;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Function to validate location data
CREATE OR REPLACE FUNCTION working.validate_location_data()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    details TEXT
) AS $$
BEGIN
    -- Check for locations without geometry
    RETURN QUERY
    SELECT
        'Missing Geometry'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END,
        FORMAT('%s locations missing geometry', COUNT(*))
    FROM working.location
    WHERE geom IS NULL;

    -- Check for locations outside valid coordinate ranges
    RETURN QUERY
    SELECT
        'Invalid Coordinates'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        FORMAT('%s locations with invalid coordinates', COUNT(*))
    FROM working.location
    WHERE latitude NOT BETWEEN -90 AND 90
       OR longitude NOT BETWEEN -180 AND 180;

    -- Check for orphaned location_history records
    RETURN QUERY
    SELECT
        'Orphaned History Records'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'WARN' END,
        FORMAT('%s history records with no matching location', COUNT(*))
    FROM working.location_history lh
    LEFT JOIN working.location l ON lh.location_id = l.location_id
    WHERE l.location_id IS NULL;

    -- Check temporal validity
    RETURN QUERY
    SELECT
        'Invalid Date Ranges'::TEXT,
        CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        FORMAT('%s records where end_date < start_date', COUNT(*))
    FROM working.location_history
    WHERE end_date < start_date;
END;
$$ LANGUAGE plpgsql;

-- Function to get location statistics
CREATE OR REPLACE FUNCTION working.location_statistics()
RETURNS TABLE(
    metric TEXT,
    value BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 'Total Locations'::TEXT, COUNT(*)
    FROM working.location;

    RETURN QUERY
    SELECT 'Geocoded Locations'::TEXT, COUNT(*)
    FROM working.location
    WHERE geom IS NOT NULL;

    RETURN QUERY
    SELECT 'Total Location History Records'::TEXT, COUNT(*)
    FROM working.location_history;

    RETURN QUERY
    SELECT 'Unique Entities'::TEXT, COUNT(DISTINCT entity_id)
    FROM working.location_history;

    RETURN QUERY
    SELECT 'Unique Locations Used'::TEXT, COUNT(DISTINCT location_id)
    FROM working.location_history;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION working.load_location_csv IS 'Load LOCATION data from CSV file and create point geometries';
COMMENT ON FUNCTION working.load_location_history_csv IS 'Load LOCATION_HISTORY data from CSV file';
COMMENT ON FUNCTION working.load_location_data IS 'Load both LOCATION and LOCATION_HISTORY files in one call';
COMMENT ON FUNCTION working.validate_location_data IS 'Validate location data for common issues';
COMMENT ON FUNCTION working.location_statistics IS 'Get summary statistics about loaded location data';
