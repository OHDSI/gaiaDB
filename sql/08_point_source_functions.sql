-- Point Source Functions
-- Assign the values of point sources (monitors, sensors) to locations: through a Voronoi tessellation of the
-- points, or through a nearest-neighbour join. The existing join (spatial_join_from_catalog) needs a distance
-- buffer for points, which gives a location no monitor or several.

-- * - * - * - * - * - * - * - * - * -
-- backbone.create_voronoi_source
--   Build the Voronoi (Thiessen) cells of a point source as a new polygon source. Every location inside a cell is
--   closer to the cell's point than to any other, so the polygon source joins with spatial_join_from_catalog
--   (ST_Within) and gives each location the value of its nearest point, one row per time window.
--   p_source_table_id  a point table in public (as the catalog's postgis step builds it: ogc_fid, geom, geom_local and the attributes)
--   p_target_table_id  the polygon table to create in public (replaced if it exists), same attributes; register it as a data source
--                      (JSON-LD + backbone.gdsc_load_all_variables) like any other
--   p_clip             the area the cells are cut to, with an SRID. Default: the bounding box of the points enlarged by
--                      10% of its longer side (the cells of the outer points are unbounded otherwise)
--   p_working_srid     the projected CRS (metres) the tessellation is computed in; default: the UTM zone of the points.
--                      Voronoi cells must not be computed in lon/lat, which distorts distances
--   p_segment_m        edges are cut into segments of this length before the cells are converted back to the point
--                      table's CRS, so that they stay straight in the projection
--   Returns the number of cells. A point outside p_clip has no cell. Two points at the same location are an error.
--   The target table is marked with a comment (source, CRS, segment length, clip); only a table that carries the mark is
--   replaced, so a call cannot drop any other table of public. Not executable by PUBLIC (see Privileges below).
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION backbone.create_voronoi_source(
    p_source_table_id TEXT,
    p_target_table_id TEXT,
    p_clip            GEOMETRY DEFAULT NULL,
    p_working_srid    INTEGER  DEFAULT NULL,
    p_segment_m       NUMERIC  DEFAULT 100
)
RETURNS INTEGER AS $$
DECLARE
    v_geom_srid INTEGER;
    v_work_srid INTEGER := p_working_srid;
    v_n         INTEGER;
    v_distinct  INTEGER;
    v_lon       DOUBLE PRECISION;
    v_lat       DOUBLE PRECISION;
    v_clip      GEOMETRY;
    v_col_defs  TEXT;
    v_cols      TEXT;
    v_cols_p    TEXT;
    v_cols_t    TEXT;
    v_has_fid   BOOLEAN;
    v_count     INTEGER;
BEGIN
    IF p_target_table_id = p_source_table_id THEN
        RAISE EXCEPTION 'the target table must not be the source table (%)', p_source_table_id;
    END IF;
    IF to_regclass(format('public.%I', p_target_table_id)) IS NOT NULL
       AND COALESCE(obj_description(to_regclass(format('public.%I', p_target_table_id)), 'pg_class'), '') NOT LIKE 'created by backbone.create_voronoi_source%' THEN
        RAISE EXCEPTION 'public.% exists and was not made by create_voronoi_source: it is not replaced (drop it yourself if that is what you want)', p_target_table_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = p_source_table_id AND column_name = 'geom') THEN
        RAISE EXCEPTION 'public.%.geom not found. Has the point source been ingested (backbone.ingest_datasource)?', p_source_table_id;
    END IF;
    v_geom_srid := Find_SRID('public', p_source_table_id, 'geom');

    EXECUTE format('SELECT count(*), count(DISTINCT ST_AsBinary(geom)), count(*) FILTER (WHERE GeometryType(geom) <> %L) FROM public.%I WHERE geom IS NOT NULL',
                   'POINT', p_source_table_id) INTO v_n, v_distinct, v_count;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'public.% has no points', p_source_table_id;
    ELSIF v_count > 0 THEN
        RAISE EXCEPTION 'public.% has geometries that are not points', p_source_table_id;
    ELSIF v_distinct < v_n THEN
        RAISE EXCEPTION 'public.% has points at identical locations (% of %); a Voronoi cell needs distinct points', p_source_table_id, v_n - v_distinct, v_n;
    END IF;

    IF v_work_srid IS NULL THEN
        EXECUTE format('SELECT ST_X(c), ST_Y(c) FROM (SELECT ST_Transform(ST_Centroid(ST_Collect(geom)), 4326) AS c FROM public.%I) t', p_source_table_id) INTO v_lon, v_lat;
        v_work_srid := (CASE WHEN v_lat >= 0 THEN 32600 ELSE 32700 END) + LEAST(60, GREATEST(1, floor((v_lon + 180) / 6)::int + 1));
    END IF;

    IF p_clip IS NOT NULL THEN
        IF ST_SRID(p_clip) = 0 THEN
            RAISE EXCEPTION 'p_clip needs an SRID (ST_SetSRID)';
        END IF;
        v_clip := ST_Transform(p_clip, v_work_srid);
    ELSE
        EXECUTE format('SELECT ST_Expand(e, 0.1 * GREATEST(ST_XMax(e) - ST_XMin(e), ST_YMax(e) - ST_YMin(e))) FROM (SELECT ST_Extent(ST_Transform(geom, %s))::geometry AS e FROM public.%I) t',
                       v_work_srid, p_source_table_id) INTO v_clip;
        v_clip := ST_SetSRID(v_clip, v_work_srid);
    END IF;

    -- the attributes of the source (everything but the key and the geometries) are carried to the cells
    SELECT string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum),
           string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum),
           string_agg(format('p.%I', a.attname), ', ' ORDER BY a.attnum),
           string_agg(format('t.%I', a.attname), ', ' ORDER BY a.attnum)
    INTO v_col_defs, v_cols, v_cols_p, v_cols_t
    FROM pg_attribute a
    WHERE a.attrelid = format('public.%I', p_source_table_id)::regclass AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname NOT IN ('ogc_fid', 'geom', 'geom_local');
    v_has_fid := EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = p_source_table_id AND column_name = 'ogc_fid');

    EXECUTE format('DROP TABLE IF EXISTS public.%I', p_target_table_id);
    EXECUTE format('CREATE TABLE public.%I (ogc_fid serial PRIMARY KEY, geom geometry(MultiPolygon, %s)%s, geom_local geometry(MultiPolygon, %s))',
                   p_target_table_id, v_geom_srid, COALESCE(', ' || v_col_defs, ''), v_geom_srid);

    EXECUTE format($SQL$
        INSERT INTO public.%1$I (geom, geom_local%3$s)
        SELECT t.g, t.g%4$s
        FROM (
            SELECT ST_Multi(ST_Transform(ST_Segmentize(ST_CollectionExtract(ST_Intersection(c.cell, %6$L::geometry), 3), %7$s), %5$s)) AS g%8$s,
                   %9$s AS src_id
            FROM (SELECT (ST_Dump(ST_VoronoiPolygons((SELECT ST_Collect(ST_Transform(geom, %10$s)) FROM public.%2$I), 0, %6$L::geometry))).geom AS cell) c
            JOIN (SELECT *, ST_Transform(geom, %10$s) AS pt FROM public.%2$I) p ON ST_Contains(c.cell, p.pt)
        ) t
        WHERE NOT ST_IsEmpty(t.g)
        ORDER BY t.src_id
    $SQL$, p_target_table_id, p_source_table_id,
           COALESCE(', ' || v_cols, ''), COALESCE(', ' || v_cols_t, ''),
           v_geom_srid, v_clip, p_segment_m, COALESCE(', ' || v_cols_p, ''),
           CASE WHEN v_has_fid THEN 'p.ogc_fid' ELSE 'NULL::integer' END, v_work_srid);
    GET DIAGNOSTICS v_count = ROW_COUNT;

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I USING gist (geom)', p_target_table_id || '_geom_geom_idx', p_target_table_id);
    EXECUTE format('COMMENT ON TABLE public.%I IS %L', p_target_table_id,
                   format('created by backbone.create_voronoi_source from public.%s (EPSG:%s, segments of %s m, clip %s)',
                          p_source_table_id, v_work_srid, p_segment_m, ST_AsText(ST_SnapToGrid(v_clip, 1))));
    RAISE NOTICE 'Voronoi source public.%: % cells from % points (tessellated in EPSG:%)', p_target_table_id, v_count, v_n, v_work_srid;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backbone.create_voronoi_source(TEXT, TEXT, GEOMETRY, INTEGER, NUMERIC)
    IS 'Voronoi cells of a point source as a polygon source (join it with spatial_join_from_catalog to assign each location its nearest point)';


-- * - * - * - * - * - * - * - * - * -
-- working.spatial_join_nearest_from_catalog
--   Join the locations in working.location_merge to the nearest points of a loaded variable (after
--   gdsc_load_all_variables) and insert the result into working.external_exposure, with the same time handling
--   as spatial_join_from_catalog: each time window of the variable that overlaps a location's period gives one
--   row, with the dates clipped to the overlap.
--   p_k                 1 (default): the value of the nearest point. More: the inverse-distance weighted mean of the k nearest
--   p_max_distance_m    points further away than this are not used; a location with none gets no row (default: no limit)
--   p_idw_power         the power of the distance in the weights 1 / distance^power (default 2; distances under 1 m count as 1 m)
--   p_record_distance   write 'distance_m=<distance to the nearest point>' to modifier_source_value (default on: how far the
--                       nearest point is says whether the value means anything for the location)
--   The k nearest are found with the spatial index (k-nearest-neighbour search, a GiST index on the geography of the
--   geometry table, created on first use), so the cost grows with k and the number of locations, not with the number of
--   points. The search ranks by spherical distance (what the index orders by); the distances that are used and recorded are
--   geodesic (spheroid), in metres. The two differ by up to about 0.3%, so two points whose distances differ by less than
--   that can be ranked the other way round from an exact spheroid ordering. Of points at exactly the same distance either
--   may come first (a second sort key would stop the planner from using the index); the same data gives the same answer. A point that has no value for a window is not a candidate for that window. The relationship is
--   "Near/Proximity to" (2052497004); the verbatim method is in exposure_relationship_source_value ('nearest' or
--   'idw k=.. power=..').
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION working.spatial_join_nearest_from_catalog(
    p_variable_name TEXT,
    p_table_id TEXT DEFAULT NULL,
    p_k INTEGER DEFAULT 1,
    p_max_distance_m NUMERIC DEFAULT NULL,
    p_idw_power NUMERIC DEFAULT 2,
    p_record_distance BOOLEAN DEFAULT TRUE,
    p_exposure_type_concept_id INTEGER DEFAULT 0
)
RETURNS INTEGER AS $$
DECLARE
    v_attr_index_id INTEGER;
    v_geom_index_id INTEGER;
    v_attr_schema TEXT;
    v_attr_table_name TEXT;
    v_geom_schema TEXT;
    v_geom_table_name TEXT;
    v_attr_concept_id INTEGER;
    v_unit_concept_id INTEGER;
    v_variable_source_id INTEGER;
    v_method TEXT;
    v_geog_index TEXT;
    v_dwithin TEXT;
    v_count INTEGER;
BEGIN
    IF COALESCE(p_k, 0) < 1 THEN
        RAISE EXCEPTION 'p_k must be at least 1';
    END IF;

    SELECT ai.attr_index_id, ai.geom_index_id, ai.database_schema, 'attr_' || ai.table_name,
           ai.attr_concept_id, ai.unit_concept_id, ai.variable_source_id
    INTO v_attr_index_id, v_geom_index_id, v_attr_schema, v_attr_table_name,
         v_attr_concept_id, v_unit_concept_id, v_variable_source_id
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

    SELECT gi.database_schema, 'geom_' || gi.table_name INTO v_geom_schema, v_geom_table_name
    FROM backbone.geom_index gi WHERE gi.geom_index_id = v_geom_index_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'geom_index_id % (referenced by attr_index_id %) not found in backbone.geom_index', v_geom_index_id, v_attr_index_id;
    END IF;

    -- KNN needs an index on the same expression as the ORDER BY (first use only; a role that may not create it falls back to a scan)
    v_geog_index := 'idx_' || v_geom_table_name || '_wgs84_geog';
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = v_geom_schema AND tablename = v_geom_table_name AND indexname = left(v_geog_index, 63)) THEN
        BEGIN
            EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I.%I USING gist ((geom_wgs84::geography))', v_geog_index, v_geom_schema, v_geom_table_name);
            EXECUTE format('ANALYZE %I.%I', v_geom_schema, v_geom_table_name);
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'no privilege to create %: the nearest search scans every point', v_geog_index;
        END;
    END IF;
    v_dwithin := CASE WHEN p_max_distance_m IS NULL THEN ''
                      ELSE format('AND ST_DWithin(geo.geom_wgs84::geography, gol.geom::geography, %L::numeric)', p_max_distance_m) END;

    v_method := CASE WHEN p_k = 1 THEN 'nearest' ELSE format('idw k=%s power=%s', p_k, p_idw_power) END;

    EXECUTE format($SQL$
        INSERT INTO working.external_exposure(
            location_id, person_id, exposure_concept_id,
            exposure_start_date, exposure_start_datetime, exposure_end_date, exposure_end_datetime,
            exposure_type_concept_id, exposure_relationship_concept_id, exposure_source_concept_id,
            exposure_source_value, exposure_relationship_source_value, dose_unit_source_value,
            quantity, modifier_source_value, operator_concept_id,
            value_as_number, value_as_concept_id, unit_concept_id
        )
        SELECT
            hit.location_id,
            CASE WHEN hit.domain_id = 1147314 THEN hit.entity_id ELSE 0 END,
            COALESCE(%1$L::integer, 0),
            hit.s, hit.s::timestamp, hit.e, hit.e::timestamp,
            %2$L::integer, 2052497004, %1$L::integer,
            %3$L, %4$L, CAST(NULL AS VARCHAR(50)),
            CAST(NULL AS INTEGER),
            CASE WHEN %5$L::boolean THEN 'distance_m=' || round(hit.d_nearest::numeric, 1) ELSE CAST(NULL AS VARCHAR(50)) END,
            CAST(NULL AS INTEGER),
            hit.v, CAST(NULL AS INTEGER), %6$L::integer
        FROM (
            SELECT gol.location_id, gol.domain_id, gol.entity_id,
                   GREATEST(w.s, gol.start_date) AS s, LEAST(w.e, gol.end_date) AS e,
                   sum(nn.val * nn.wt) / sum(nn.wt) AS v, min(nn.d) AS d_nearest
            FROM working.location_merge gol
            -- the time windows of the variable (one per year, month, ...; plain equality on the dates so that the attribute index is used)
            JOIN (SELECT DISTINCT att.attr_start_date AS s, att.attr_end_date AS e
                  FROM %7$I.%8$I att WHERE att.attr_index_id = %9$L) w
              ON w.s <= gol.end_date AND w.e >= gol.start_date
            CROSS JOIN LATERAL (
                SELECT q.val, q.d, 1.0 / power(GREATEST(q.d, 1.0), %10$L::numeric) AS wt
                FROM (
                    SELECT att.value_as_number AS val, ST_Distance(gol.geom::geography, geo.geom_wgs84::geography) AS d
                    FROM %7$I.%8$I att
                    JOIN %11$I.%12$I geo ON att.geom_record_id = geo.geom_record_id
                    WHERE att.attr_index_id = %9$L
                      AND att.attr_start_date = w.s AND att.attr_end_date = w.e
                      AND att.value_as_number IS NOT NULL AND gol.geom IS NOT NULL
                      %15$s
                    ORDER BY geo.geom_wgs84::geography <-> gol.geom::geography
                    LIMIT %13$s
                ) q
                WHERE %14$L::numeric IS NULL OR q.d <= %14$L::numeric
            ) nn
            GROUP BY gol.location_history_id, w.s, w.e, gol.location_id, gol.domain_id, gol.entity_id, gol.start_date, gol.end_date
        ) hit
    $SQL$,
        v_attr_concept_id,                      -- 1
        COALESCE(p_exposure_type_concept_id, 0), -- 2
        COALESCE(v_variable_source_id::text, p_variable_name), -- 3: exposure_source_value
        v_method,                               -- 4: exposure_relationship_source_value
        p_record_distance,                      -- 5
        v_unit_concept_id,                      -- 6
        v_attr_schema, v_attr_table_name,       -- 7, 8
        v_attr_index_id,                        -- 9
        p_idw_power,                            -- 10
        v_geom_schema, v_geom_table_name,       -- 11, 12
        p_k,                                    -- 13
        p_max_distance_m,                       -- 14
        v_dwithin                               -- 15: the distance limit, in a form the index can use
    );

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE 'Nearest-point spatial join (%) complete. Inserted % exposure records for variable %', v_method, v_count, p_variable_name;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION working.spatial_join_nearest_from_catalog(TEXT, TEXT, INTEGER, NUMERIC, NUMERIC, BOOLEAN, INTEGER)
    IS 'join locations to the nearest point(s) of a loaded variable (nearest or inverse-distance weighted) into working.external_exposure';


-- * - * - * - * - * - * - * - * - * -
-- Privileges
--   create_voronoi_source creates and replaces a table of public: not for the anonymous PostgREST role (functions are
--   executable by PUBLIC unless revoked). The join function, like spatial_join_from_catalog, only reads the catalog
--   and writes working.external_exposure and stays as it is.
-- * - * - * - * - * - * - * - * - * -
REVOKE EXECUTE ON FUNCTION backbone.create_voronoi_source(TEXT, TEXT, GEOMETRY, INTEGER, NUMERIC) FROM PUBLIC;
