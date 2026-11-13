-- Raster Functions
-- Register raster datasets (loaded with raster2pgsql into public.<table_id>) in the catalog and
-- join them to locations. A raster is not copied into geom_*/attr_* tables: the tiles stay where
-- raster2pgsql put them and backbone.raster_layer records which tiles and band stand for which period.

-- * - * - * - * - * - * - * - * - * -
-- backbone.raster_layer
--   One row per layer of a raster variable: the raster table, the band, the SRID and the period it
--   stands for. A table loaded from several files (e.g. one per year, raster2pgsql -F) has one layer
--   per file, selected by the filename column; filename NULL means every tile of the table.
-- * - * - * - * - * - * - * - * - * -
CREATE TABLE IF NOT EXISTS backbone.raster_layer (
    raster_layer_id SERIAL PRIMARY KEY,
    attr_index_id   INTEGER NOT NULL REFERENCES backbone.attr_index (attr_index_id) ON DELETE CASCADE,
    raster_schema   TEXT    NOT NULL DEFAULT 'public',
    raster_table    TEXT    NOT NULL,
    raster_column   TEXT    NOT NULL DEFAULT 'rast',
    filename        TEXT,
    band            INTEGER NOT NULL DEFAULT 1,
    srid            INTEGER NOT NULL,
    start_date      DATE    NOT NULL,
    end_date        DATE    NOT NULL,
    created_at      TIMESTAMP DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_raster_layer_unique
    ON backbone.raster_layer (attr_index_id, COALESCE(filename, ''), band);


-- * - * - * - * - * - * - * - * - * -
-- backbone.datasource_structure(data_source_uuid)
--   The data representation of a registered data source ('raster', 'vector' or 'table'), from the
--   dataRepresentation term of measurementTechnique in its JSON-LD; NULL when it has none.
--   backbone.ingest_datasource() uses it to register rasters after the ETL.
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION backbone.datasource_structure(p_data_source_uuid UUID)
RETURNS TEXT AS $$
    SELECT lower(elem->>'termCode')
    FROM backbone.data_source ds,
         jsonb_array_elements(CASE WHEN jsonb_typeof(ds.measurement_technique) = 'array' THEN ds.measurement_technique ELSE '[]'::jsonb END) elem
    WHERE ds.data_source_uuid = p_data_source_uuid
      AND elem->'inDefinedTermSet'->>'name' = 'dataRepresentation'
    LIMIT 1;
$$ LANGUAGE sql STABLE;


-- * - * - * - * - * - * - * - * - * -
-- backbone.raster_layers_from_etl_metadata(table_id)
--   The raster_layers array of /data/{table_id}/meta_etl_{table_id}.json: the period each file of a
--   multi-file raster table stands for, as [{"filename", "start_date", "end_date"}]. NULL when the
--   file, or the field, is not there (the table is then one layer over the variable's dates).
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION backbone.raster_layers_from_etl_metadata(p_table_id TEXT)
RETURNS JSONB AS $$
BEGIN
    RETURN (pg_read_file(format('/data/%s/meta_etl_%s.json', p_table_id, p_table_id))::jsonb)->'raster_layers';
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- * - * - * - * - * - * - * - * - * -
-- backbone.gdsc_load_raster_variable(params jsonb)
--   Register one variable of a raster table, the raster counterpart of gdsc_load_variable().
--   params: table_id, variable_id (required); band (default 1); description, concept_id,
--   unit_concept_id, unit, start_date, end_date, source, variable_nodata (as gdsc_load_variable);
--   layers: optional array of {"filename", "start_date", "end_date"}. Without layers the whole
--   table is one layer covering start_date..end_date.
--   Safe to run again: the layers of the variable are replaced.
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION backbone.gdsc_load_raster_variable(params jsonb)
RETURNS json AS $$
DECLARE
    v_table_id   TEXT := params->>'table_id';
    v_variable   TEXT := params->>'variable_id';
    v_band       INTEGER := COALESCE(NULLIF(params->>'band', '')::integer, 1);
    v_col        TEXT := 'rast';
    v_geom_id    INTEGER;
    v_attr_id    INTEGER;
    v_srid       INTEGER;
    v_start      DATE := NULLIF(params->>'start_date', '')::date;
    v_end        DATE := NULLIF(params->>'end_date', '')::date;
    v_has_filename BOOLEAN;
    v_layers     JSONB;
    v_layer      JSONB;
    v_count      INTEGER := 0;
BEGIN
    IF v_table_id IS NULL OR v_variable IS NULL THEN
        RAISE EXCEPTION 'params must include table_id and variable_id';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = v_table_id AND column_name = v_col) THEN
        RAISE EXCEPTION 'public.%.% not found. Has the raster been loaded with raster2pgsql (ingest_datasource)?', v_table_id, v_col;
    END IF;

    EXECUTE format('SELECT ST_SRID(%I) FROM public.%I WHERE %I IS NOT NULL LIMIT 1', v_col, v_table_id, v_col) INTO v_srid;
    IF v_srid IS NULL OR v_srid = 0 THEN
        RAISE EXCEPTION 'public.% has no raster with a known SRID (load it with raster2pgsql -s <srid>)', v_table_id;
    END IF;

    SELECT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = v_table_id AND column_name = 'filename')
    INTO v_has_filename;

    -- geom_index: reuse the row ingest_jsonld_variables registered, or create it
    SELECT geom_index_id INTO v_geom_id FROM backbone.geom_index WHERE table_name = v_table_id;
    IF NOT FOUND THEN
        INSERT INTO backbone.geom_index (geom_type_source_value, table_name, table_desc, database_schema)
        VALUES ('raster', v_table_id, COALESCE(NULLIF(params->>'table_description', ''), v_table_id), 'public')
        RETURNING geom_index_id INTO v_geom_id;
    END IF;
    UPDATE backbone.geom_index SET geom_type_concept_id = 2052496985  -- Raster
    WHERE geom_index_id = v_geom_id AND geom_type_concept_id IS NULL;

    -- attr_index: one row per variable, as for vector sources
    SELECT attr_index_id INTO v_attr_id FROM backbone.attr_index
    WHERE table_name = v_table_id AND variable_name = v_variable;
    IF NOT FOUND THEN
        IF v_start IS NULL OR v_end IS NULL THEN
            RAISE EXCEPTION 'start_date and end_date are required to register variable "%"', v_variable;
        END IF;
        INSERT INTO backbone.attr_index (
            geom_index_id, table_name, variable_name, variable_desc, attr_concept_id, unit_concept_id, unit_source_value,
            attr_start_date, attr_end_date, attr_no_value_as_number, attr_no_value_as_string, attr_source_value, database_schema
        ) VALUES (
            v_geom_id, v_table_id, v_variable, COALESCE(NULLIF(params->>'description', ''), v_variable),
            NULLIF(params->>'concept_id', '')::int, NULLIF(params->>'unit_concept_id', '')::int, NULLIF(params->>'unit', ''),
            v_start, v_end, NULLIF(params->>'variable_nodata', '')::numeric, NULLIF(params->>'variable_nodata', ''),
            COALESCE(params->>'source', v_variable), 'public'
        ) RETURNING attr_index_id INTO v_attr_id;
    ELSE
        SELECT COALESCE(v_start, attr_start_date), COALESCE(v_end, attr_end_date) INTO v_start, v_end
        FROM backbone.attr_index WHERE attr_index_id = v_attr_id;
    END IF;

    v_layers := COALESCE(params->'layers',
                         jsonb_build_array(jsonb_build_object('start_date', v_start, 'end_date', v_end)));

    DELETE FROM backbone.raster_layer WHERE attr_index_id = v_attr_id;
    FOR v_layer IN SELECT * FROM jsonb_array_elements(v_layers)
    LOOP
        IF v_layer->>'filename' IS NOT NULL AND NOT v_has_filename THEN
            RAISE EXCEPTION 'layer "%" needs a filename column in public.% (load with raster2pgsql -F)', v_layer->>'filename', v_table_id;
        END IF;
        INSERT INTO backbone.raster_layer (attr_index_id, raster_schema, raster_table, raster_column, filename, band, srid, start_date, end_date)
        VALUES (v_attr_id, 'public', v_table_id, v_col, NULLIF(v_layer->>'filename', ''), v_band, v_srid,
                (v_layer->>'start_date')::date, (v_layer->>'end_date')::date);
        v_count := v_count + 1;
    END LOOP;

    RETURN json_build_object('raster', 'public.' || v_table_id, 'attr_index_id', v_attr_id, 'layers', v_count, 'srid', v_srid);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backbone.gdsc_load_raster_variable(jsonb)
    IS 'register a variable of a raster table (raster2pgsql) and its layers in backbone.raster_layer';


-- * - * - * - * - * - * - * - * - * -
-- backbone.gdsc_load_all_raster_variables
--   Register every variable of a table_id that ingest_jsonld_variables put in attr_index, taking
--   description, concept, unit and dates from there (the raster counterpart of gdsc_load_all_variables).
--   p_layers is passed to every variable, e.g. one entry per file of an annual series.
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION backbone.gdsc_load_all_raster_variables(
    p_table_id TEXT,
    p_layers   JSONB DEFAULT NULL,
    p_source   TEXT  DEFAULT NULL,
    p_band     INTEGER DEFAULT 1
)
RETURNS TABLE(variable_name TEXT, result JSON) AS $$
DECLARE
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT ai.variable_name AS vname, ai.variable_desc, ai.attr_concept_id, ai.unit_concept_id,
               ai.unit_source_value, ai.attr_start_date, ai.attr_end_date, gi.table_desc
        FROM backbone.attr_index ai JOIN backbone.geom_index gi USING (geom_index_id)
        WHERE ai.table_name = p_table_id
        ORDER BY ai.attr_index_id
    LOOP
        variable_name := v_row.vname;
        result := backbone.gdsc_load_raster_variable(jsonb_strip_nulls(jsonb_build_object(
            'table_id', p_table_id, 'variable_id', v_row.vname, 'band', p_band,
            'description', v_row.variable_desc, 'concept_id', v_row.attr_concept_id, 'unit_concept_id', v_row.unit_concept_id,
            'unit', v_row.unit_source_value, 'start_date', v_row.attr_start_date, 'end_date', v_row.attr_end_date,
            'source', p_source, 'table_description', v_row.table_desc, 'layers', p_layers)));
        RETURN NEXT;
    END LOOP;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No variables in backbone.attr_index for table_id "%". Run backbone.ingest_datasource() first.', p_table_id;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- * - * - * - * - * - * - * - * - * -
-- working.spatial_join_raster_from_catalog
--   Join the locations in working.location_merge to a registered raster variable and insert the
--   result into working.external_exposure, like spatial_join_from_catalog does for vector sources.
--   p_method 'point'       the value of the cell containing the location (ST_Value); no value (nodata,
--                          or outside the raster) gives no row
--            'buffer_mean' the mean of the cells whose centre is within p_buffer_meters of the location
--                          (ST_Clip + ST_SummaryStats over the tiles); the buffer is a geography buffer
--                          in metres, as for vector sources
--            'class_fraction' for categorical rasters: one row per class present in the buffer, with the
--                          share of the valid cells (ST_Clip + ST_ValueCount over the tiles) in value_as_number
--                          and the class value in modifier_source_value; classes absent from the buffer
--                          (fraction 0) get no row
--   Each layer whose period overlaps a location's period gives one row, with the dates clipped to the overlap.
--   p_exposure_type_concept_id is the "Exposure Type Concept" of the data source, 0 when not given.
-- * - * - * - * - * - * - * - * - * -
CREATE OR REPLACE FUNCTION working.spatial_join_raster_from_catalog(
    p_variable_name TEXT,
    p_table_id TEXT DEFAULT NULL,
    p_method TEXT DEFAULT 'point',
    p_buffer_meters NUMERIC DEFAULT 0,
    p_exposure_type_concept_id INTEGER DEFAULT 0
)
RETURNS INTEGER AS $$
DECLARE
    v_attr_index_id INTEGER;
    v_attr_concept_id INTEGER;
    v_unit_concept_id INTEGER;
    v_variable_source_id INTEGER;
    v_relationship_concept_id INTEGER;
    v_relationship_source TEXT;
    v_source TEXT;
    v_tbl RECORD;
    v_has_filename BOOLEAN;
    v_filename_cond TEXT;
    v_inner TEXT;
    v_sql TEXT;
    v_n INTEGER;
    v_count INTEGER := 0;
BEGIN
    IF p_method NOT IN ('point', 'buffer_mean', 'class_fraction') THEN
        RAISE EXCEPTION 'unknown method "%": use point, buffer_mean or class_fraction', p_method;
    END IF;
    IF p_method <> 'point' AND COALESCE(p_buffer_meters, 0) <= 0 THEN
        RAISE EXCEPTION 'method % needs p_buffer_meters > 0', p_method;
    END IF;

    SELECT ai.attr_index_id, ai.attr_concept_id, ai.unit_concept_id, ai.variable_source_id
    INTO v_attr_index_id, v_attr_concept_id, v_unit_concept_id, v_variable_source_id
    FROM backbone.attr_index ai
    WHERE ai.variable_name = p_variable_name
      AND (p_table_id IS NULL OR ai.table_name = p_table_id)
      AND EXISTS (SELECT 1 FROM backbone.raster_layer rl WHERE rl.attr_index_id = ai.attr_index_id)
    ORDER BY ai.attr_index_id
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Raster variable "%" not found%. Has it been registered via backbone.gdsc_load_raster_variable()?',
            p_variable_name,
            CASE WHEN p_table_id IS NOT NULL THEN format(' for table_id "%s"', p_table_id) ELSE '' END;
    END IF;

    -- a point is within its cell; a buffer mean is within a radius of the location
    v_relationship_concept_id := working.spatial_relationship_concept_id('ST_Within', CASE WHEN p_method = 'point' THEN 0 ELSE p_buffer_meters END);
    v_relationship_source := CASE p_method WHEN 'point' THEN 'ST_Value'
                                           WHEN 'buffer_mean' THEN 'ST_Clip+ST_SummaryStats(mean)'
                                           ELSE 'ST_Clip+ST_ValueCount(fraction)' END;
    v_source := COALESCE(v_variable_source_id::text, p_variable_name);

    FOR v_tbl IN
        SELECT DISTINCT raster_schema, raster_table, raster_column FROM backbone.raster_layer WHERE attr_index_id = v_attr_index_id
    LOOP
        SELECT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = v_tbl.raster_schema AND table_name = v_tbl.raster_table AND column_name = 'filename')
        INTO v_has_filename;
        v_filename_cond := CASE WHEN v_has_filename THEN '(rl.filename IS NULL OR r.filename = rl.filename)' ELSE 'TRUE' END;

        IF p_method = 'point' THEN
            -- a point on a tile edge meets two tiles: keep one value per location period and layer
            v_inner := format($SQL$
                SELECT DISTINCT ON (gol.location_history_id, rl.raster_layer_id)
                    gol.location_id, gol.domain_id, gol.entity_id,
                    GREATEST(rl.start_date, gol.start_date) AS s, LEAST(rl.end_date, gol.end_date) AS e,
                    ST_Value(r.%1$I, rl.band, p.pt) AS v, CAST(NULL AS TEXT) AS cls
                FROM working.location_merge gol
                JOIN backbone.raster_layer rl ON rl.attr_index_id = %2$L AND rl.raster_table = %3$L AND rl.raster_schema = %4$L
                    AND rl.start_date <= gol.end_date AND rl.end_date >= gol.start_date
                CROSS JOIN LATERAL (SELECT ST_Transform(gol.geom, rl.srid) AS pt) p
                JOIN %4$I.%3$I r ON %5$s AND ST_Intersects(r.%1$I, p.pt)
                ORDER BY gol.location_history_id, rl.raster_layer_id, ST_Value(r.%1$I, rl.band, p.pt) NULLS LAST
            $SQL$, v_tbl.raster_column, v_attr_index_id, v_tbl.raster_table, v_tbl.raster_schema, v_filename_cond);
        ELSIF p_method = 'buffer_mean' THEN
            v_inner := format($SQL$
                SELECT gol.location_id, gol.domain_id, gol.entity_id,
                    GREATEST(rl.start_date, gol.start_date) AS s, LEAST(rl.end_date, gol.end_date) AS e,
                    sum((ss.st).sum) / nullif(sum((ss.st).count), 0) AS v, CAST(NULL AS TEXT) AS cls
                FROM working.location_merge gol
                JOIN backbone.raster_layer rl ON rl.attr_index_id = %2$L AND rl.raster_table = %3$L AND rl.raster_schema = %4$L
                    AND rl.start_date <= gol.end_date AND rl.end_date >= gol.start_date
                CROSS JOIN LATERAL (SELECT ST_Transform(ST_Buffer(gol.geom::geography, %6$L)::geometry, rl.srid) AS b) p
                JOIN %4$I.%3$I r ON %5$s AND ST_Intersects(r.%1$I, p.b)
                CROSS JOIN LATERAL (SELECT ST_SummaryStats(ST_Clip(r.%1$I, rl.band, p.b, true)) AS st) ss
                GROUP BY gol.location_history_id, rl.raster_layer_id, gol.location_id, gol.domain_id, gol.entity_id, rl.start_date, rl.end_date, gol.start_date, gol.end_date
            $SQL$, v_tbl.raster_column, v_attr_index_id, v_tbl.raster_table, v_tbl.raster_schema, v_filename_cond, p_buffer_meters);
        ELSE
            -- cells per class in the buffer, summed over the tiles, as a share of the valid cells of the buffer
            v_inner := format($SQL$
                SELECT t.location_id, t.domain_id, t.entity_id, t.s, t.e,
                    t.n::double precision / sum(t.n) OVER (PARTITION BY t.location_history_id, t.raster_layer_id) AS v,
                    t.class_value::text AS cls
                FROM (
                    SELECT gol.location_history_id, rl.raster_layer_id, gol.location_id, gol.domain_id, gol.entity_id,
                        GREATEST(rl.start_date, gol.start_date) AS s, LEAST(rl.end_date, gol.end_date) AS e,
                        vc.class_value, sum(vc.n) AS n
                    FROM working.location_merge gol
                    JOIN backbone.raster_layer rl ON rl.attr_index_id = %2$L AND rl.raster_table = %3$L AND rl.raster_schema = %4$L
                        AND rl.start_date <= gol.end_date AND rl.end_date >= gol.start_date
                    CROSS JOIN LATERAL (SELECT ST_Transform(ST_Buffer(gol.geom::geography, %6$L)::geometry, rl.srid) AS b) p
                    JOIN %4$I.%3$I r ON %5$s AND ST_Intersects(r.%1$I, p.b)
                    CROSS JOIN LATERAL ST_ValueCount(ST_Clip(r.%1$I, rl.band, p.b, true), 1, true) AS vc(class_value, n)
                    GROUP BY gol.location_history_id, rl.raster_layer_id, gol.location_id, gol.domain_id, gol.entity_id,
                             rl.start_date, rl.end_date, gol.start_date, gol.end_date, vc.class_value
                ) t
            $SQL$, v_tbl.raster_column, v_attr_index_id, v_tbl.raster_table, v_tbl.raster_schema, v_filename_cond, p_buffer_meters);
        END IF;

        v_sql := format($SQL$
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
                %2$L::integer, %3$L::integer, %1$L::integer,
                %4$L, %5$L, CAST(NULL AS VARCHAR(50)),
                CAST(NULL AS INTEGER), CAST(hit.cls AS VARCHAR(50)), CAST(NULL AS INTEGER),
                hit.v, CAST(NULL AS INTEGER), %6$L::integer
            FROM (%7$s) hit
            WHERE hit.v IS NOT NULL
        $SQL$, v_attr_concept_id, COALESCE(p_exposure_type_concept_id, 0), v_relationship_concept_id,
               v_source, v_relationship_source, v_unit_concept_id, v_inner);

        EXECUTE v_sql;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_count := v_count + v_n;
    END LOOP;

    RAISE NOTICE 'Raster spatial join (%) complete. Inserted % exposure records for variable %', p_method, v_count, p_variable_name;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION working.spatial_join_raster_from_catalog(TEXT, TEXT, TEXT, NUMERIC, INTEGER)
    IS 'join locations to a registered raster variable (point value, buffer mean or class fractions) into working.external_exposure';
