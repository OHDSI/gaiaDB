-- Spatial Join Functions
-- Parameterized functions to perform spatial joins between locations and data sources

-- Main parameterized spatial join function
-- Supports both 1-point (geometry in same table) and 2-point (geometry in separate table) joins
CREATE OR REPLACE FUNCTION working.spatial_join_exposure(
    p_variable_name TEXT,
    p_data_source_table TEXT,
    p_geometry_source_table TEXT DEFAULT NULL,
    p_variable_merge_column TEXT DEFAULT NULL,
    p_geometry_merge_column TEXT DEFAULT NULL,
    p_spatial_operator TEXT DEFAULT 'st_within',
    p_buffer_meters NUMERIC DEFAULT 0
)
RETURNS INTEGER AS $$
DECLARE
    v_sql TEXT;
    v_variable_source_id INTEGER;
    v_data_source_uuid UUID;
    v_attr_concept_id INTEGER;
    v_unit_concept_id INTEGER;
    v_value_as_concept_id INTEGER;
    v_attr_start_date DATE;
    v_attr_end_date DATE;
    v_count INTEGER;
    v_is_two_point BOOLEAN;
BEGIN
    -- Determine if this is a 1-point or 2-point join
    v_is_two_point := (p_geometry_source_table IS NOT NULL);

    -- Get variable metadata
    SELECT
        vs.variable_source_id,
        vs.data_source_uuid,
        vs.attr_concept_id,
        vs.unit_concept_id,
        vs.value_as_concept_id,
        COALESCE(vs.attr_start_date, vs.start_date),
        COALESCE(vs.attr_end_date, vs.end_date)
    INTO
        v_variable_source_id,
        v_data_source_uuid,
        v_attr_concept_id,
        v_unit_concept_id,
        v_value_as_concept_id,
        v_attr_start_date,
        v_attr_end_date
    FROM backbone.variable_source vs
    WHERE vs.variable_name = p_variable_name
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Variable "%" not found in backbone.variable_source', p_variable_name;
    END IF;

    RAISE NOTICE 'Processing spatial join for variable: % (ID: %)', p_variable_name, v_variable_source_id;

    -- Build the SQL for 1-point join (geometry in same table as attributes)
    IF NOT v_is_two_point THEN
        v_sql := format($SQL$
            INSERT INTO working.external_exposure(
                location_id,
                person_id,
                exposure_concept_id,
                exposure_start_date,
                exposure_start_datetime,
                exposure_end_date,
                exposure_end_datetime,
                exposure_type_concept_id,
                exposure_relationship_concept_id,
                exposure_source_concept_id,
                exposure_source_value,
                exposure_relationship_source_value,
                dose_unit_source_value,
                quantity,
                modifier_source_value,
                operator_concept_id,
                value_as_number,
                value_as_concept_id,
                unit_concept_id
            )
            SELECT
                gol.location_id,
                CASE
                    WHEN gol.domain_id = 1147314 THEN gol.entity_id
                    ELSE 0
                END AS person_id,
                CASE
                    WHEN att.attr_concept_id IS NOT NULL THEN att.attr_concept_id::float::int
                    ELSE 0
                END AS exposure_concept_id,
                GREATEST(att.attr_start_date::date, gol.start_date) AS exposure_start_date,
                GREATEST(att.attr_start_date::timestamp, gol.start_date::timestamp) AS exposure_start_datetime,
                LEAST(att.attr_end_date::date, gol.end_date) AS exposure_end_date,
                LEAST(att.attr_end_date::timestamp, gol.end_date::timestamp) AS exposure_end_datetime,
                0 AS exposure_type_concept_id,
                0 AS exposure_relationship_concept_id,
                NULL AS exposure_source_concept_id,
                %L AS exposure_source_value,
                CAST(NULL AS VARCHAR(50)) AS exposure_relationship_source_value,
                CAST(NULL AS VARCHAR(50)) AS dose_unit_source_value,
                CAST(NULL AS INTEGER) AS quantity,
                CAST(NULL AS VARCHAR(50)) AS modifier_source_value,
                CAST(NULL AS INTEGER) AS operator_concept_id,
                geo.%I::numeric AS value_as_number,
                att.value_as_concept_id::float::integer AS value_as_concept_id,
                att.unit_concept_id::float::integer AS unit_concept_id
            FROM (
                SELECT
                    *,
                    1 AS join_all,
                    %L::integer AS attr_concept_id,
                    %L::date AS attr_start_date,
                    %L::date AS attr_end_date,
                    %L::integer AS unit_concept_id,
                    %L::integer AS value_as_concept_id
                FROM backbone.variable_source
                WHERE variable_name = %L
            ) att
            INNER JOIN (
                SELECT %I, wgs_geom, 1 AS join_all
                FROM %s
            ) geo ON att.join_all = geo.join_all
            JOIN working.location_merge gol
                ON %s(
                    gol.geom,
                    CASE
                        WHEN %L > 0 THEN ST_Buffer(geo.wgs_geom::geography, %L)::geometry
                        ELSE geo.wgs_geom
                    END
                )
                AND (
                    gol.start_date BETWEEN att.attr_start_date::date AND att.attr_end_date::date
                    OR gol.end_date BETWEEN att.attr_start_date::date AND att.attr_end_date::date
                    OR (gol.start_date <= att.attr_start_date::date AND gol.end_date >= att.attr_end_date::date)
                )
        $SQL$,
            p_variable_name,  -- exposure_source_value
            p_variable_name,  -- column name for value_as_number
            v_attr_concept_id,
            v_attr_start_date,
            v_attr_end_date,
            v_unit_concept_id,
            v_value_as_concept_id,
            p_variable_name,  -- WHERE clause
            p_variable_name,  -- SELECT column
            p_data_source_table,  -- FROM table
            p_spatial_operator,  -- spatial operator
            p_buffer_meters,  -- buffer check
            p_buffer_meters   -- buffer value
        );

    -- Build the SQL for 2-point join (geometry in separate table)
    ELSE
        v_sql := format($SQL$
            INSERT INTO working.external_exposure(
                location_id,
                person_id,
                exposure_concept_id,
                exposure_start_date,
                exposure_start_datetime,
                exposure_end_date,
                exposure_end_datetime,
                exposure_type_concept_id,
                exposure_relationship_concept_id,
                exposure_source_concept_id,
                exposure_source_value,
                exposure_relationship_source_value,
                dose_unit_source_value,
                quantity,
                modifier_source_value,
                operator_concept_id,
                value_as_number,
                value_as_concept_id,
                unit_concept_id
            )
            SELECT
                gol.location_id,
                CASE
                    WHEN gol.domain_id = 1147314 THEN gol.entity_id
                    ELSE 0
                END AS person_id,
                CASE
                    WHEN att.attr_concept_id IS NOT NULL THEN att.attr_concept_id::float::int
                    ELSE 0
                END AS exposure_concept_id,
                GREATEST(att.attr_start_date::date, gol.start_date) AS exposure_start_date,
                GREATEST(att.attr_start_date::timestamp, gol.start_date::timestamp) AS exposure_start_datetime,
                LEAST(att.attr_end_date::date, gol.end_date) AS exposure_end_date,
                LEAST(att.attr_end_date::timestamp, gol.end_date::timestamp) AS exposure_end_datetime,
                0 AS exposure_type_concept_id,
                0 AS exposure_relationship_concept_id,
                CASE
                    WHEN att.attr_concept_id IS NOT NULL THEN att.attr_concept_id::float::int
                    ELSE 0
                END AS exposure_source_concept_id,
                %L AS exposure_source_value,
                CAST(NULL AS VARCHAR(50)) AS exposure_relationship_source_value,
                CAST(NULL AS VARCHAR(50)) AS dose_unit_source_value,
                CAST(NULL AS INTEGER) AS quantity,
                CAST(NULL AS VARCHAR(50)) AS modifier_source_value,
                CAST(NULL AS INTEGER) AS operator_concept_id,
                geo.%I::numeric AS value_as_number,
                att.value_as_concept_id::float::integer AS value_as_concept_id,
                att.unit_concept_id::float::integer AS unit_concept_id
            FROM (
                SELECT
                    *,
                    1 AS join_all,
                    %L::integer AS attr_concept_id,
                    %L::date AS attr_start_date,
                    %L::date AS attr_end_date,
                    %L::integer AS unit_concept_id,
                    %L::integer AS value_as_concept_id
                FROM backbone.variable_source
                WHERE variable_name = %L
            ) att
            INNER JOIN (
                SELECT a.%I, b.wgs_geom, 1 AS join_all
                FROM %s a
                INNER JOIN %s b ON a.%I = b.%I
            ) geo ON att.join_all = geo.join_all
            JOIN working.location_merge gol
                ON %s(
                    gol.geom,
                    CASE
                        WHEN %L > 0 THEN ST_Buffer(geo.wgs_geom::geography, %L)::geometry
                        ELSE geo.wgs_geom
                    END
                )
                AND (
                    gol.start_date BETWEEN att.attr_start_date::date AND att.attr_end_date::date
                    OR gol.end_date BETWEEN att.attr_start_date::date AND att.attr_end_date::date
                    OR (gol.start_date <= att.attr_start_date::date AND gol.end_date >= att.attr_end_date::date)
                )
        $SQL$,
            p_variable_name,  -- exposure_source_value
            p_variable_name,  -- column name for value_as_number
            v_attr_concept_id,
            v_attr_start_date,
            v_attr_end_date,
            v_unit_concept_id,
            v_value_as_concept_id,
            p_variable_name,  -- WHERE clause
            p_variable_name,  -- SELECT column from data table
            p_data_source_table,  -- FROM data table
            p_geometry_source_table,  -- JOIN geometry table
            p_variable_merge_column,  -- JOIN condition data side
            p_geometry_merge_column,  -- JOIN condition geometry side
            p_spatial_operator,  -- spatial operator
            p_buffer_meters,  -- buffer check
            p_buffer_meters   -- buffer value
        );
    END IF;

    -- Execute the spatial join
    RAISE NOTICE 'Executing spatial join SQL...';
    EXECUTE v_sql;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Spatial join complete. Inserted % exposure records for variable %', v_count, p_variable_name;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Wrapper function for simple 1-point spatial joins
CREATE OR REPLACE FUNCTION working.spatial_join_simple(
    p_variable_name TEXT,
    p_data_source_table TEXT
)
RETURNS INTEGER AS $$
BEGIN
    RETURN working.spatial_join_exposure(
        p_variable_name := p_variable_name,
        p_data_source_table := p_data_source_table
    );
END;
$$ LANGUAGE plpgsql;

-- Function to process all variables from a data source
CREATE OR REPLACE FUNCTION working.spatial_join_all_variables(
    p_data_source_uuid UUID,
    p_data_source_table TEXT,
    p_geometry_source_table TEXT DEFAULT NULL
)
RETURNS TABLE(
    variable_name TEXT,
    records_created INTEGER
) AS $$
DECLARE
    v_variable RECORD;
    v_count INTEGER;
BEGIN
    FOR v_variable IN
        SELECT vs.variable_name
        FROM backbone.variable_source vs
        WHERE vs.data_source_uuid = p_data_source_uuid
        ORDER BY vs.variable_name
    LOOP
        BEGIN
            v_count := working.spatial_join_exposure(
                v_variable.variable_name,
                p_data_source_table,
                p_geometry_source_table
            );

            RETURN QUERY SELECT v_variable.variable_name, v_count;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Error processing variable %: %', v_variable.variable_name, SQLERRM;
            RETURN QUERY SELECT v_variable.variable_name, 0;
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Function to get exposure statistics
CREATE OR REPLACE FUNCTION working.exposure_statistics()
RETURNS TABLE(
    metric TEXT,
    value BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 'Total Exposure Records'::TEXT, COUNT(*)
    FROM working.external_exposure;

    RETURN QUERY
    SELECT 'Unique Persons Exposed'::TEXT, COUNT(DISTINCT person_id)
    FROM working.external_exposure
    WHERE person_id > 0;

    RETURN QUERY
    SELECT 'Unique Locations'::TEXT, COUNT(DISTINCT location_id)
    FROM working.external_exposure;

    RETURN QUERY
    SELECT 'Unique Exposure Variables'::TEXT, COUNT(DISTINCT exposure_source_value)
    FROM working.external_exposure;

    RETURN QUERY
    SELECT 'Date Range (days)'::TEXT,
           (MAX(exposure_end_date) - MIN(exposure_start_date))::BIGINT
    FROM working.external_exposure;
END;
$$ LANGUAGE plpgsql;

-- Function to clear exposure data (for re-processing)
CREATE OR REPLACE FUNCTION working.clear_exposure_data(
    p_variable_name TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF p_variable_name IS NULL THEN
        DELETE FROM working.external_exposure;
    ELSE
        DELETE FROM working.external_exposure
        WHERE exposure_source_value = p_variable_name;
    END IF;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Deleted % exposure records', v_count;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION working.spatial_join_exposure IS 'Parameterized spatial join between locations and data source, supports both 1-point and 2-point geometries';
COMMENT ON FUNCTION working.spatial_join_simple IS 'Simplified wrapper for 1-point spatial joins';
COMMENT ON FUNCTION working.spatial_join_all_variables IS 'Process spatial joins for all variables in a data source';
COMMENT ON FUNCTION working.exposure_statistics IS 'Get summary statistics about exposure calculations';
COMMENT ON FUNCTION working.clear_exposure_data IS 'Clear exposure data for reprocessing';
