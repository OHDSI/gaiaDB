-- Tests for point sources: Voronoi cells and the nearest-point join
-- Covers: backbone.create_voronoi_source, working.spatial_join_nearest_from_catalog
--
-- Run against a fully initialized gaiaDB instance:
--   psql -U postgres -d gaiacore -f tests/test_point_sources.sql
--
-- Fixture (EPSG:5070 metres from an origin near downtown Los Angeles): monitors A (0, 0), B (1000, 0), C (0, 2000) and
-- D (5000, 5000) with annual values 2014 / 2015 of A 10 / 15, B 20 / 25, C 30 / 35, D 100 / 105.
-- Everything rolls back when the suite finishes.
--
-- Output: PASS / FAIL lines via RAISE NOTICE.

BEGIN;

CREATE OR REPLACE FUNCTION _assert(description TEXT, condition BOOLEAN)
RETURNS VOID AS $$
BEGIN
    IF condition THEN
        RAISE NOTICE 'PASS: %', description;
    ELSE
        RAISE NOTICE 'FAIL: %', description;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- position in the fixture (metres east and north of the origin) to a lon/lat point
CREATE OR REPLACE FUNCTION _pt(dx DOUBLE PRECISION, dy DOUBLE PRECISION, srid INTEGER DEFAULT 4326)
RETURNS GEOMETRY AS $$
    SELECT ST_Transform(ST_SetSRID(ST_MakePoint(-2025500 + dx, 1463500 + dy), 5070), srid);
$$ LANGUAGE sql IMMUTABLE;

-- -------------------------------------------------------------------------
-- Fixture: the point table as the catalog's postgis step leaves it
-- -------------------------------------------------------------------------
CREATE TABLE public.test_mon (
    ogc_fid serial PRIMARY KEY, geom geometry(Point, 4269), monitor_id integer, pm25 jsonb, geom_local geometry(Point, 4269));
INSERT INTO public.test_mon (geom, monitor_id, pm25, geom_local)
SELECT _pt(x, y, 4269), id, jsonb_build_object('2014-01-01/2014-12-31', v, '2015-01-01/2015-12-31', v + 5), _pt(x, y, 4269)
FROM (VALUES (1, 0, 0, 10), (2, 1000, 0, 20), (3, 0, 2000, 30), (4, 5000, 5000, 100)) AS m(id, x, y, v);

-- Persons (domain 1147314). 900001: near A all the time. 900002: near B until 30 June 2014, then near A. 900003: near D.
-- 900004: 21 km from every monitor.
INSERT INTO working.location (location_id, geom, longitude, latitude)
SELECT id, g, ST_X(g), ST_Y(g) FROM (VALUES (900001, _pt(200, 0)), (900002, _pt(700, 0)), (900012, _pt(200, 0)), (900003, _pt(5200, 5000)), (900004, _pt(20000, 20000))) AS l(id, g);
INSERT INTO working.location_history (location_id, relationship_type_concept_id, domain_id, entity_id, start_date, end_date) VALUES
    (900001, 2052496995, 1147314, 900001, '2014-01-01', '2015-12-31'),
    (900002, 2052496995, 1147314, 900002, '2014-01-01', '2014-06-30'),
    (900012, 2052496995, 1147314, 900002, '2014-07-01', '2015-12-31'),
    (900003, 2052496995, 1147314, 900003, '2014-01-01', '2015-12-31'),
    (900004, 2052496995, 1147314, 900004, '2014-01-01', '2015-12-31');

SELECT backbone.gdsc_load_variable($${
  "table_id": "test_mon", "variable_id": "pm25", "geom_type": "point", "table_description": "test monitors", "geom_label": "monitor_id", "description": "test value",
  "concept_id": "2052499839", "start_date": "2014-01-01", "end_date": "2015-12-31", "source": "test"}$$::jsonb);

-- -------------------------------------------------------------------------
-- Nearest point
-- -------------------------------------------------------------------------
SELECT working.spatial_join_nearest_from_catalog('pm25', 'test_mon', 1, NULL, 2, FALSE, 2052499878);

SELECT _assert('nearest: a person gets the value of the nearest monitor, one row per annual window',
    (SELECT array_agg(value_as_number::float8 ORDER BY exposure_start_date) = ARRAY[10, 15]::float8[]
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('nearest: a move inside a window gives two rows with the dates split at the move',
    (SELECT array_agg(value_as_number::float8 || ':' || exposure_start_date::text || '/' || exposure_end_date::text ORDER BY exposure_start_date, exposure_end_date)
          = ARRAY['20:2014-01-01/2014-06-30', '10:2014-07-01/2014-12-31', '15:2015-01-01/2015-12-31']
     FROM working.external_exposure WHERE person_id = 900002));

SELECT _assert('nearest: a person near the far monitor D gets its value',
    (SELECT array_agg(value_as_number::float8 ORDER BY exposure_start_date) = ARRAY[100, 105]::float8[]
     FROM working.external_exposure WHERE person_id = 900003));
SELECT _assert('nearest: 21 km from every monitor, the nearest (D) is still used: there is no distance limit by default',
    (SELECT array_agg(value_as_number::float8 ORDER BY exposure_start_date) = ARRAY[100, 105]::float8[]
     FROM working.external_exposure WHERE person_id = 900004));

SELECT _assert('nearest: concepts (type, Near/Proximity to, exposure) and the verbatim method',
    (SELECT bool_and(exposure_type_concept_id = 2052499878 AND exposure_relationship_concept_id = 2052497004
                     AND exposure_concept_id = 2052499839 AND exposure_relationship_source_value = 'nearest' AND modifier_source_value IS NULL)
     FROM working.external_exposure WHERE person_id = 900001));

DELETE FROM working.external_exposure;
SELECT working.spatial_join_nearest_from_catalog('pm25', 'test_mon', 1, 5000, 2, TRUE);
SELECT _assert('max distance: a person with no monitor within it gets no row, the others are unchanged',
    NOT EXISTS (SELECT 1 FROM working.external_exposure WHERE person_id = 900004)
    AND (SELECT count(*) FROM working.external_exposure WHERE person_id IN (900001, 900002, 900003)) = 7);
-- the fixture distance is 200 m in EPSG:5070; the geodesic distance differs by the scale of the projection (about 0.7% here)
SELECT _assert('record distance: modifier_source_value holds the geodesic distance to the nearest monitor (about 201 m)',
    (SELECT bool_and(substring(modifier_source_value from 'distance_m=([0-9.]+)')::float8 BETWEEN 198 AND 205) FROM working.external_exposure WHERE person_id = 900001));

-- inverse-distance weighted mean of the two nearest of person 900001 (A at 200 m, B at 800 m, weights 1/d^2)
DELETE FROM working.external_exposure;
SELECT working.spatial_join_nearest_from_catalog('pm25', 'test_mon', 2, NULL, 2);
SELECT _assert('idw: the weighted mean of the k nearest, weights 1 / distance^2 (A 200 m, B 800 m)',
    (SELECT abs(value_as_number::float8 - (10 * (1.0 / 200 ^ 2) + 20 * (1.0 / 800 ^ 2)) / ((1.0 / 200 ^ 2) + (1.0 / 800 ^ 2))) < 0.01
     FROM working.external_exposure WHERE person_id = 900001 AND exposure_start_date = '2014-01-01'));
SELECT _assert('idw: the method is written verbatim', (SELECT bool_and(exposure_relationship_source_value = 'idw k=2 power=2') FROM working.external_exposure WHERE person_id = 900001));

DELETE FROM working.external_exposure;

-- -------------------------------------------------------------------------
-- Voronoi cells
-- -------------------------------------------------------------------------
SELECT _assert('voronoi: one cell per monitor',
    backbone.create_voronoi_source('test_mon', 'test_mon_vor',
        ST_MakeEnvelope(-2025500 - 1000, 1463500 - 1000, -2025500 + 6000, 1463500 + 6000, 5070), 5070) = 4);

SELECT _assert('voronoi: the cells tile the clip area (7 km x 7 km) without gaps or overlaps',
    (SELECT abs(sum(ST_Area(ST_Transform(geom, 5070))) - 49000000) < 49000000 * 1e-4 FROM public.test_mon_vor)
    AND (SELECT count(*) FROM public.test_mon_vor a JOIN public.test_mon_vor b ON a.ogc_fid < b.ogc_fid AND ST_Overlaps(a.geom, b.geom)) = 0
    AND (SELECT bool_and(ST_IsValid(geom)) FROM public.test_mon_vor));

SELECT _assert('voronoi: every monitor lies in its own cell and the cell keeps the attributes of its monitor',
    (SELECT count(*) = 4 AND bool_and(ST_Contains(v.geom, m.geom) AND v.pm25 = m.pm25 AND v.monitor_id = m.monitor_id)
     FROM public.test_mon m JOIN public.test_mon_vor v USING (monitor_id)));

SELECT _assert('voronoi: the cells are MultiPolygons in the CRS of the point table',
    (SELECT Find_SRID('public', 'test_mon_vor', 'geom') = 4269 AND GeometryType(geom) = 'MULTIPOLYGON' FROM public.test_mon_vor LIMIT 1));

-- a location is in the cell of its nearest monitor: probe a grid (offset so that no probe is on an edge)
SELECT _assert('voronoi: every probe location is in the cell of its nearest monitor (grid of 484 probes)',
    (SELECT count(*) = 484 AND bool_and(cell_id = near_id) FROM (
        SELECT (SELECT v.monitor_id FROM public.test_mon_vor v WHERE ST_Within(p.g, v.geom)) AS cell_id,
               (SELECT m.monitor_id FROM public.test_mon m ORDER BY ST_Distance(ST_Transform(p.g, 5070), ST_Transform(m.geom, 5070)) LIMIT 1) AS near_id
        FROM (SELECT _pt(-500 + i * 250 + 13.7, -500 + j * 250 + 7.3, 4269) AS g FROM generate_series(0, 21) i, generate_series(0, 21) j) p) t));

-- joined like any polygon source, the cells give the same exposure as the nearest-point join
SELECT backbone.gdsc_load_variable($${
  "table_id": "test_mon_vor", "variable_id": "pm25", "geom_type": "multipolygon", "table_description": "test cells", "geom_label": "monitor_id", "description": "test value",
  "concept_id": "2052499839", "start_date": "2014-01-01", "end_date": "2015-12-31", "source": "test"}$$::jsonb);
SELECT working.spatial_join_from_catalog('pm25', 'test_mon_vor', 'ST_Within', 0, 2052499878);
CREATE TEMP TABLE cells_rows ON COMMIT DROP AS
    SELECT person_id, exposure_start_date, exposure_end_date, value_as_number FROM working.external_exposure WHERE person_id IN (900001, 900002, 900003);
DELETE FROM working.external_exposure;
SELECT working.spatial_join_nearest_from_catalog('pm25', 'test_mon', 1, NULL, 2, FALSE, 2052499878);
SELECT _assert('the Voronoi cells joined with spatial_join_from_catalog and the nearest-point join give the same rows',
    (SELECT count(*) = 7 FROM cells_rows)
    AND NOT EXISTS (SELECT 1 FROM (SELECT person_id, exposure_start_date, exposure_end_date, value_as_number FROM working.external_exposure WHERE person_id IN (900001, 900002, 900003)
                                   EXCEPT SELECT * FROM cells_rows) d));

-- defaults: UTM zone and the enlarged bounding box
SELECT _assert('voronoi: defaults (UTM zone of the points, bounding box enlarged by 10%) give a cell per monitor',
    backbone.create_voronoi_source('test_mon', 'test_mon_vor_default') = 4);
SELECT _assert('voronoi: the cells of the defaults are valid',
    (SELECT count(*) = 4 AND bool_and(ST_IsValid(geom)) FROM public.test_mon_vor_default));

-- a point outside the clip has no cell; points at the same place are an error
SELECT _assert('voronoi: a monitor outside the clip area has no cell',
    backbone.create_voronoi_source('test_mon', 'test_mon_vor_small', ST_MakeEnvelope(-2025500 - 500, 1463500 - 500, -2025500 + 1500, 1463500 + 2500, 5070), 5070) = 3);

CREATE TABLE public.test_mon_dup AS SELECT * FROM public.test_mon;
INSERT INTO public.test_mon_dup (geom, monitor_id, pm25, geom_local) SELECT geom, 99, pm25, geom_local FROM public.test_mon WHERE monitor_id = 1;
DO $$
BEGIN
    PERFORM backbone.create_voronoi_source('test_mon_dup', 'test_mon_dup_vor');
    RAISE NOTICE 'FAIL: points at identical locations should raise';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: points at identical locations raise (%)', left(SQLERRM, 50);
END $$;

DO $$
BEGIN
    PERFORM backbone.create_voronoi_source('no_such_table', 'x');
    RAISE NOTICE 'FAIL: a missing source table should raise';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: a missing source table raises';
END $$;

DO $$
BEGIN
    PERFORM working.spatial_join_nearest_from_catalog('no_such_variable');
    RAISE NOTICE 'FAIL: unknown variable should raise';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: unknown variable raises';
END $$;

ROLLBACK;
