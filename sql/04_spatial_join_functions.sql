-- Spatial Join Functions
-- Parameterized functions to perform spatial joins between locations and data sources

-- Map the spatial operator (and buffer) used for a join to an OMOP GIS
-- "Geometry Relationship" concept for external_exposure.exposure_relationship_concept_id.
-- Hard-coded until the GIS vocabulary is loaded and this can be looked up from vocabulary.concept.
-- Distance-based relationships with no corresponding join operator here
-- (Separated by 2052496975, Near/Proximity to 2052497004, Beyond 2052497131)
-- are not produced; unmapped operators return 0.
CREATE OR REPLACE FUNCTION working.spatial_relationship_concept_id(
    p_spatial_operator TEXT,
    p_buffer_meters NUMERIC DEFAULT 0
)
RETURNS INTEGER AS $$
    SELECT CASE
        -- location falls within the geometry grown by a buffer
        WHEN lower(p_spatial_operator) IN ('st_within', 'st_coveredby') AND COALESCE(p_buffer_meters, 0) > 0
            THEN 2052496942  -- Within a Radius of [specific distance]
        WHEN lower(p_spatial_operator) IN ('st_within', 'st_coveredby')
            THEN 2052496943  -- Within
        WHEN lower(p_spatial_operator) = 'st_intersects'
            THEN 2052497024  -- Intersects
        WHEN lower(p_spatial_operator) = 'st_overlaps'
            THEN 2052496998  -- Overlaps
        WHEN lower(p_spatial_operator) = 'st_touches'
            THEN 2052497079  -- Adjacent to
        ELSE 0
    END;
$$ LANGUAGE sql IMMUTABLE;

-- Map a data source geometry to an OMOP GIS "Geometry Type" concept for
-- external_exposure.exposure_type_concept_id. Evaluated per feature, since a
-- single source table can mix geometry types. Hard-coded until the GIS
-- vocabulary is loaded and this can be looked up from vocabulary.concept.
-- Any other geometry type (e.g. CIRCULARSTRING, MULTISURFACE) maps to
-- Complex Geometry for now. Raster (2052496985), Solid (2052496974) and
-- Element Relevant To Geometry (2052497051) are not produced: there is no
-- raster join path yet and the others have no matching PostGIS type.
CREATE OR REPLACE FUNCTION working.geometry_type_concept_id(p_geom GEOMETRY)
RETURNS INTEGER AS $$
    SELECT CASE GeometryType(p_geom)
        WHEN 'POINT'              THEN 2052496994  -- Point
        WHEN 'MULTIPOINT'         THEN 2052497013  -- MultiPoint
        WHEN 'LINESTRING'         THEN 2052497023  -- LineString
        WHEN 'MULTILINESTRING'    THEN 2052497014  -- MultiLineString
        WHEN 'POLYGON'            THEN 2052496992  -- Polygon
        WHEN 'MULTIPOLYGON'       THEN 2052497012  -- MultiPolygon
        WHEN 'CURVEPOLYGON'       THEN 2052498289  -- CurvePolygon
        WHEN 'GEOMETRYCOLLECTION' THEN 2052497042  -- GeometryCollection
        WHEN 'TIN'                THEN 2052496959  -- Triangulated Irregular Network (TIN)
        ELSE CASE WHEN p_geom IS NULL THEN 0
                  ELSE 2052497069  -- Complex Geometry
             END
    END;
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- p_exposure_type_concept_id is the "Exposure Type Concept" describing the kind of
-- data source (e.g. Air Quality Database 2052499878); 0 when not given.
-- The geometry type of the source lives on backbone.geom_index.geom_type_concept_id.
DROP FUNCTION IF EXISTS working.spatial_join_from_catalog(TEXT, TEXT, TEXT, NUMERIC);
CREATE OR REPLACE FUNCTION working.spatial_join_from_catalog(
    p_variable_name TEXT,
    p_table_id TEXT DEFAULT NULL,
    p_spatial_operator TEXT DEFAULT 'ST_Within',
    p_buffer_meters NUMERIC DEFAULT 0,
    p_exposure_type_concept_id INTEGER DEFAULT 0
)
RETURNS INTEGER AS $$
DECLARE
    v_sql TEXT;
    v_attr_index_id INTEGER;
    v_geom_index_id INTEGER;
    v_attr_schema TEXT;
    v_attr_table_name TEXT;
    v_geom_schema TEXT;
    v_geom_table_name TEXT;
    v_attr_concept_id INTEGER;
    v_unit_concept_id INTEGER;
    v_attr_source_concept_id INTEGER;
    v_variable_source_id INTEGER;
    v_attr_start_date DATE;
    v_attr_end_date DATE;
    v_count INTEGER;
    v_relationship_concept_id INTEGER;
BEGIN
    -- Locate the catalog entry for this variable (optionally scoped to one table_id,
    -- since the same variable_name could in principle be loaded from multiple sources).
    SELECT
        ai.attr_index_id, ai.geom_index_id, ai.database_schema, 'attr_' || ai.table_name,
        ai.attr_concept_id, ai.unit_concept_id, ai.attr_source_concept_id,
        ai.attr_start_date, ai.attr_end_date, ai.variable_source_id
    INTO
        v_attr_index_id, v_geom_index_id, v_attr_schema, v_attr_table_name,
        v_attr_concept_id, v_unit_concept_id, v_attr_source_concept_id,
        v_attr_start_date, v_attr_end_date, v_variable_source_id
    FROM backbone.attr_index ai
    WHERE ai.variable_name = p_variable_name
      AND (p_table_id IS NULL OR ai.table_name = p_table_id)
    ORDER BY ai.attr_index_id
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Variable "%" not found in backbone.attr_index%. Has it been loaded via backbone.gdsc_load_variable()?',
            p_variable_name,
            CASE WHEN p_table_id IS NOT NULL THEN format(' for table_id "%s"', p_table_id) ELSE '' END;
    END IF;

    SELECT gi.database_schema, 'geom_' || gi.table_name
    INTO v_geom_schema, v_geom_table_name
    FROM backbone.geom_index gi
    WHERE gi.geom_index_id = v_geom_index_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'geom_index_id % (referenced by attr_index_id %) not found in backbone.geom_index', v_geom_index_id, v_attr_index_id;
    END IF;

    RAISE NOTICE 'Processing catalog spatial join for variable: % (attr_index_id: %, attr table: %.%, geom table: %.%)',
        p_variable_name, v_attr_index_id, v_attr_schema, v_attr_table_name, v_geom_schema, v_geom_table_name;

    v_relationship_concept_id := working.spatial_relationship_concept_id(p_spatial_operator, p_buffer_meters);

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
            COALESCE(%1$L::integer, 0) AS exposure_concept_id,
            GREATEST(att_dates.attr_start_date, gol.start_date) AS exposure_start_date,
            GREATEST(att_dates.attr_start_date::timestamp, gol.start_date::timestamp) AS exposure_start_datetime,
            LEAST(att_dates.attr_end_date, gol.end_date) AS exposure_end_date,
            LEAST(att_dates.attr_end_date::timestamp, gol.end_date::timestamp) AS exposure_end_datetime,
            %15$L::integer AS exposure_type_concept_id,
            %14$L::integer AS exposure_relationship_concept_id,
            %1$L::integer AS exposure_source_concept_id,
            %5$L AS exposure_source_value,
            %16$L AS exposure_relationship_source_value,
            CAST(NULL AS VARCHAR(50)) AS dose_unit_source_value,
            CAST(NULL AS INTEGER) AS quantity,
            CAST(NULL AS VARCHAR(50)) AS modifier_source_value,
            CAST(NULL AS INTEGER) AS operator_concept_id,
            att.value_as_number,
            att.value_as_concept_id,
            %12$L::integer AS unit_concept_id
        FROM %6$I.%7$I att
        JOIN %8$I.%9$I geo ON att.geom_record_id = geo.geom_record_id
        -- Each attr row carries its own time window (e.g. one month of a
        -- 2014-2019 series); attr_index only holds the variable's overall
        -- span, so use it only as a fallback for rows loaded without dates.
        CROSS JOIN LATERAL (
            SELECT
                COALESCE(att.attr_start_date, %2$L::date) AS attr_start_date,
                COALESCE(att.attr_end_date, %3$L::date) AS attr_end_date
        ) att_dates
        JOIN working.location_merge gol
            ON %10$s(
                gol.geom,
                CASE
                    WHEN %11$L > 0 THEN ST_Buffer(geo.geom_wgs84::geography, %11$L)::geometry
                    ELSE geo.geom_wgs84
                END
            )
            AND (
                gol.start_date BETWEEN att_dates.attr_start_date AND att_dates.attr_end_date
                OR gol.end_date BETWEEN att_dates.attr_start_date AND att_dates.attr_end_date
                OR (gol.start_date <= att_dates.attr_start_date AND gol.end_date >= att_dates.attr_end_date)
            )
        WHERE att.attr_index_id = %13$L
    $SQL$,
        v_attr_concept_id,          -- 1: exposure_concept_id
        v_attr_start_date,          -- 2: fallback start date for attr rows without their own window
        v_attr_end_date,            -- 3: fallback end date for attr rows without their own window
        v_attr_source_concept_id,   -- 4: (unused)
        COALESCE(v_variable_source_id::text, p_variable_name),  -- 5: exposure_source_value (variable_source_id)
        v_attr_schema,              -- 6: FROM attr instance schema
        v_attr_table_name,          -- 7: FROM attr instance table
        v_geom_schema,              -- 8: JOIN geom instance schema
        v_geom_table_name,          -- 9: JOIN geom instance table
        p_spatial_operator,         -- 10: spatial operator
        p_buffer_meters,            -- 11: buffer check/value
        v_unit_concept_id,          -- 12: unit_concept_id
        v_attr_index_id,            -- 13: restrict to this variable's rows in the shared attr_X table
        v_relationship_concept_id,  -- 14: exposure_relationship_concept_id
        COALESCE(p_exposure_type_concept_id, 0),  -- 15: exposure_type_concept_id
        p_spatial_operator          -- 16: exposure_relationship_source_value (verbatim operator)
    );

    RAISE NOTICE 'Executing catalog spatial join SQL...';
    EXECUTE v_sql;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Catalog spatial join complete. Inserted % exposure records for variable %', v_count, p_variable_name;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Process spatial joins for every variable loaded (via gdsc_load_variable) under a given table_id
DROP FUNCTION IF EXISTS working.spatial_join_all_from_catalog(TEXT, TEXT, NUMERIC);
CREATE OR REPLACE FUNCTION working.spatial_join_all_from_catalog(
    p_table_id TEXT,
    p_spatial_operator TEXT DEFAULT 'ST_Within',
    p_buffer_meters NUMERIC DEFAULT 0,
    p_exposure_type_concept_id INTEGER DEFAULT 0
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
        -- attr_index.variable_name is varchar; RETURN QUERY below requires an
        -- exact type match against RETURNS TABLE(variable_name TEXT, ...), so
        -- cast here rather than at each RETURN QUERY site.
        SELECT ai.variable_name::TEXT AS variable_name
        FROM backbone.attr_index ai
        WHERE ai.table_name = p_table_id
        ORDER BY ai.variable_name
    LOOP
        BEGIN
            v_count := working.spatial_join_from_catalog(
                v_variable.variable_name,
                p_table_id,
                p_spatial_operator,
                p_buffer_meters,
                p_exposure_type_concept_id
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
        WHERE exposure_source_value = p_variable_name
           OR exposure_source_value IN (
                SELECT variable_source_id::text FROM backbone.variable_source
                WHERE variable_name = p_variable_name);
    END IF;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'Deleted % exposure records', v_count;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION working.spatial_relationship_concept_id IS 'Map a spatial join operator and buffer to an OMOP GIS Geometry Relationship concept_id (0 if unmapped)';
COMMENT ON FUNCTION working.geometry_type_concept_id IS 'Map a geometry to an OMOP GIS Geometry Type concept_id (Complex Geometry if no specific concept, 0 if NULL)';
COMMENT ON FUNCTION working.spatial_join_from_catalog IS 'Spatial join driven by backbone.attr_index/geom_index, joining the working.attr_<table_id>/geom_<table_id> instance tables created by backbone.gdsc_load_variable()';
COMMENT ON FUNCTION working.spatial_join_all_from_catalog IS 'Run spatial_join_from_catalog for every variable loaded under a given table_id';
COMMENT ON FUNCTION working.exposure_statistics IS 'Get summary statistics about exposure calculations';
COMMENT ON FUNCTION working.clear_exposure_data IS 'Clear exposure data for reprocessing';
