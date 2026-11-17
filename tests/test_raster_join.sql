-- Tests for raster registration and the raster spatial join
-- Covers: backbone.gdsc_load_raster_variable, backbone.gdsc_load_all_raster_variables,
--         working.spatial_join_raster_from_catalog (point, buffer_mean and class_fraction)
--
-- Run against a fully initialized gaiaDB instance:
--   psql -U postgres -d gaiacore -f tests/test_raster_join.sql
--
-- The fixture is a 4 x 4 raster of 1000 m cells in EPSG:5070 (upper left corner x -2026000, y 1464000),
-- cell (row r, column c) = 10 r + c, one layer per year in one table (filename column):
-- y2014.tif = the values, y2015.tif = the values + 100. Cell (row 2, column 4) is nodata.
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

-- -------------------------------------------------------------------------
-- Fixture: raster table as raster2pgsql -F would leave it
-- -------------------------------------------------------------------------
CREATE TABLE public.test_raster_annual (rid SERIAL PRIMARY KEY, rast raster, filename TEXT);

INSERT INTO public.test_raster_annual (rast, filename)
SELECT ST_SetValue(
         ST_SetValues(
           ST_AddBand(ST_MakeEmptyRaster(4, 4, -2026000, 1464000, 1000, -1000, 0, 0, 5070), '32BF'::text, 0, -9999),
           1, 1, 1,
           ARRAY[[11 + y.add, 12 + y.add, 13 + y.add, 14 + y.add],
                 [21 + y.add, 22 + y.add, 23 + y.add, -9999],
                 [31 + y.add, 32 + y.add, 33 + y.add, 34 + y.add],
                 [41 + y.add, 42 + y.add, 43 + y.add, 44 + y.add]]::double precision[][]),
         1, 4, 2, -9999),
       'y' || y.yr || '.tif'
FROM (VALUES (2014, 0), (2015, 100)) AS y(yr, add);

CREATE INDEX ON public.test_raster_annual USING gist (ST_ConvexHull(rast));

-- Persons (domain 1147314): 900001 stays in cell (1,1); 900002 lives in cell (3,3) until 30 June 2014, then in (1,1);
-- 900003 lives in the nodata cell; 900004 lives outside the raster.
CREATE TEMP TABLE fx_loc (location_id INTEGER, x DOUBLE PRECISION, y DOUBLE PRECISION) ON COMMIT DROP;
INSERT INTO fx_loc VALUES (900001, -2025500, 1463500),   -- cell (1,1), value 11
                          (900002, -2023500, 1461500),   -- cell (3,3), value 33
                          (900003, -2022500, 1462500),   -- cell (2,4), nodata
                          (900004, -2030000, 1463500);   -- outside

INSERT INTO working.location (location_id, geom, longitude, latitude)
SELECT location_id, g, ST_X(g), ST_Y(g)
FROM (SELECT location_id, ST_Transform(ST_SetSRID(ST_MakePoint(x, y), 5070), 4326) AS g FROM fx_loc) t;

INSERT INTO working.location_history (location_id, relationship_type_concept_id, domain_id, entity_id, start_date, end_date) VALUES
    (900001, 2052496995, 1147314, 900001, '2014-01-01', '2015-12-31'),
    (900002, 2052496995, 1147314, 900002, '2014-01-01', '2014-06-30'),
    (900001, 2052496995, 1147314, 900002, '2014-07-01', '2014-12-31'),
    (900003, 2052496995, 1147314, 900003, '2014-01-01', '2015-12-31'),
    (900004, 2052496995, 1147314, 900004, '2014-01-01', '2015-12-31');

-- -------------------------------------------------------------------------
-- Registration
-- -------------------------------------------------------------------------
SELECT backbone.gdsc_load_raster_variable($${
  "table_id": "test_raster_annual", "variable_id": "test_value", "description": "test cell value",
  "concept_id": 2052499839, "unit": "ug/m3", "start_date": "2014-01-01", "end_date": "2015-12-31",
  "layers": [
    {"filename": "y2014.tif", "start_date": "2014-01-01", "end_date": "2014-12-31"},
    {"filename": "y2015.tif", "start_date": "2015-01-01", "end_date": "2015-12-31"}
  ]}$$::jsonb);

SELECT _assert('registration: two layers recorded with the raster SRID',
    (SELECT count(*) = 2 AND min(srid) = 5070 AND max(srid) = 5070
     FROM backbone.raster_layer rl JOIN backbone.attr_index ai USING (attr_index_id)
     WHERE ai.table_name = 'test_raster_annual'));

SELECT _assert('registration: geom_index gets the Raster geometry type concept',
    (SELECT geom_type_concept_id = 2052496985 FROM backbone.geom_index WHERE table_name = 'test_raster_annual'));

SELECT _assert('registration: running it again replaces the layers, it does not add to them',
    (SELECT (backbone.gdsc_load_raster_variable($${
        "table_id": "test_raster_annual", "variable_id": "test_value",
        "layers": [{"filename": "y2014.tif", "start_date": "2014-01-01", "end_date": "2014-12-31"},
                   {"filename": "y2015.tif", "start_date": "2015-01-01", "end_date": "2015-12-31"}]}$$::jsonb)->>'layers')::int = 2)
    AND (SELECT count(*) FROM backbone.raster_layer rl JOIN backbone.attr_index ai USING (attr_index_id)
         WHERE ai.table_name = 'test_raster_annual') = 2);

CREATE TABLE public.test_raster_nofile AS
SELECT ST_AddBand(ST_MakeEmptyRaster(2, 2, -2026000, 1464000, 1000, -1000, 0, 0, 5070), '32BF'::text, 1, -9999) AS rast;

DO $$
BEGIN
    PERFORM backbone.gdsc_load_raster_variable($j${
        "table_id": "test_raster_nofile", "variable_id": "v", "start_date": "2014-01-01", "end_date": "2014-12-31",
        "layers": [{"filename": "a.tif", "start_date": "2014-01-01", "end_date": "2014-12-31"}]}$j$::jsonb);
    RAISE NOTICE 'FAIL: a layer with a filename needs a filename column';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: a layer with a filename needs a filename column (%)', left(SQLERRM, 40);
END $$;

SELECT _assert('registration: without layers the whole table is one layer over the variable dates',
    (SELECT (backbone.gdsc_load_raster_variable($${"table_id": "test_raster_nofile", "variable_id": "v",
        "start_date": "2014-01-01", "end_date": "2014-12-31"}$$::jsonb)->>'layers')::int = 1));

-- -------------------------------------------------------------------------
-- Point join
-- -------------------------------------------------------------------------
SELECT working.spatial_join_raster_from_catalog('test_value', 'test_raster_annual', 'point', 0, 2052499878);

SELECT _assert('point: a person in one cell gets one row per yearly layer',
    (SELECT count(*) = 2 FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('point: values are the cell value of each layer (11 in 2014, 111 in 2015)',
    (SELECT array_agg(value_as_number::float8 ORDER BY exposure_start_date) = ARRAY[11, 111]::float8[]
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('point: exposure dates are the layer period clipped to the residence',
    (SELECT array_agg(exposure_start_date::text || '/' || exposure_end_date::text ORDER BY exposure_start_date)
          = ARRAY['2014-01-01/2014-12-31', '2015-01-01/2015-12-31']
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('point: a move inside a layer period gives two rows with the dates split at the move',
    (SELECT array_agg(value_as_number::float8 || ':' || exposure_start_date::text || '/' || exposure_end_date::text ORDER BY exposure_start_date)
          = ARRAY['33:2014-01-01/2014-06-30', '11:2014-07-01/2014-12-31']
     FROM working.external_exposure WHERE person_id = 900002));

SELECT _assert('point: nodata cell gives no row', NOT EXISTS (SELECT 1 FROM working.external_exposure WHERE person_id = 900003));
SELECT _assert('point: location outside the raster gives no row', NOT EXISTS (SELECT 1 FROM working.external_exposure WHERE person_id = 900004));

SELECT _assert('point: concepts (type, Within relationship, exposure concept) and verbatim method',
    (SELECT bool_and(exposure_type_concept_id = 2052499878 AND exposure_relationship_concept_id = 2052496943
                     AND exposure_concept_id = 2052499839 AND exposure_relationship_source_value = 'ST_Value')
     FROM working.external_exposure WHERE person_id = 900001));

DELETE FROM working.external_exposure;

-- -------------------------------------------------------------------------
-- Buffer mean: 1100 m reaches the right and lower neighbours of cell (1,1) (1000 m) but not the diagonal (1414 m)
-- -------------------------------------------------------------------------
SELECT working.spatial_join_raster_from_catalog('test_value', 'test_raster_annual', 'buffer_mean', 1100);

SELECT _assert('buffer_mean: mean of the cells whose centre is in the buffer (11, 12, 21 = 14.667; +100 in 2015)',
    (SELECT bool_and(abs(value_as_number::float8 - (14.0 + 2.0/3.0 + CASE WHEN exposure_start_date >= '2015-01-01' THEN 100 ELSE 0 END)) < 1e-6)
            AND count(*) = 2
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('buffer_mean: nodata is left out of the mean (23, 14, 34 around the nodata cell = 23.667)',
    (SELECT bool_and(abs(value_as_number::float8 - (23.0 + 2.0/3.0 + CASE WHEN exposure_start_date >= '2015-01-01' THEN 100 ELSE 0 END)) < 1e-6)
            AND count(*) = 2
     FROM working.external_exposure WHERE person_id = 900003));

SELECT _assert('buffer_mean: relationship is Within a Radius, source value names the method',
    (SELECT bool_and(exposure_relationship_concept_id = 2052496942 AND exposure_relationship_source_value LIKE 'ST_Clip%')
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('buffer_mean: location outside the raster gives no row', NOT EXISTS (SELECT 1 FROM working.external_exposure WHERE person_id = 900004));

-- -------------------------------------------------------------------------
-- Class fractions: a categorical raster with the same grid, class 1 everywhere except class 2 in cells (1,2) and (2,1),
-- and nodata in cell (2,4). Around cell (1,1) a 1100 m buffer holds cells 1, 2, 2 (class 1: 1/3, class 2: 2/3);
-- around the nodata cell it holds the three valid neighbours, all class 1.
-- -------------------------------------------------------------------------
CREATE TABLE public.test_raster_class AS
SELECT ST_SetValues(
         ST_AddBand(ST_MakeEmptyRaster(4, 4, -2026000, 1464000, 1000, -1000, 0, 0, 5070), '8BUI'::text, 1, 255),
         1, 1, 1,
         ARRAY[[1, 2, 1, 1], [2, 1, 1, 255], [1, 1, 1, 1], [1, 1, 1, 1]]::double precision[][]) AS rast;

SELECT backbone.gdsc_load_raster_variable($${
  "table_id": "test_raster_class", "variable_id": "test_class", "start_date": "2014-01-01", "end_date": "2015-12-31"}$$::jsonb);

DELETE FROM working.external_exposure;
SELECT working.spatial_join_raster_from_catalog('test_class', 'test_raster_class', 'class_fraction', 1100);

SELECT _assert('class_fraction: one row per class present, class value in modifier_source_value, share in value_as_number',
    (SELECT array_agg(modifier_source_value || '=' || round(value_as_number::numeric, 4) ORDER BY modifier_source_value)
          = ARRAY['1=0.3333', '2=0.6667']
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('class_fraction: nodata is left out of the shares (only class 1, share 1)',
    (SELECT count(*) = 1 AND bool_and(modifier_source_value = '1' AND abs(value_as_number::float8 - 1) < 1e-9)
     FROM working.external_exposure WHERE person_id = 900003));

SELECT _assert('class_fraction: shares of each location period sum to 1',
    (SELECT bool_and(abs(total - 1) < 1e-9) FROM (
        SELECT sum(value_as_number::float8) AS total FROM working.external_exposure
        WHERE person_id BETWEEN 900001 AND 900004 GROUP BY person_id, exposure_start_date, exposure_end_date) t));

SELECT _assert('class_fraction: relationship is Within a Radius, source value names the method',
    (SELECT bool_and(exposure_relationship_concept_id = 2052496942 AND exposure_relationship_source_value = 'ST_Clip+ST_ValueCount(fraction)')
     FROM working.external_exposure WHERE person_id = 900001));

SELECT _assert('class_fraction: location outside the raster gives no row', NOT EXISTS (SELECT 1 FROM working.external_exposure WHERE person_id = 900004));

-- -------------------------------------------------------------------------
-- Routing helpers used by ingest_datasource
-- -------------------------------------------------------------------------
INSERT INTO backbone.data_source (dataset_id, dataset_name, measurement_technique) VALUES
  ('https://example.org/test_structure_raster', 'test raster source',
   '[{"@type": "DefinedTerm", "inDefinedTermSet": {"@type": "DefinedTermSet", "name": "dataRepresentation"}, "termCode": "raster"}]'),
  ('https://example.org/test_structure_vector', 'test vector source',
   '[{"@type": "DefinedTerm", "inDefinedTermSet": {"@type": "DefinedTermSet", "name": "dataRepresentation"}, "termCode": "vector"},
     {"@type": "DefinedTerm", "inDefinedTermSet": {"@type": "DefinedTermSet", "name": "vectorGeometry"}, "termCode": "polygon"}]'),
  ('https://example.org/test_structure_none', 'test source without a structure', NULL);

SELECT _assert('structure: raster, vector and missing are told apart',
    (SELECT array_agg(backbone.datasource_structure(data_source_uuid) ORDER BY dataset_id) IS NOT DISTINCT FROM ARRAY[NULL, 'raster', 'vector']::text[]
     FROM backbone.data_source WHERE dataset_id LIKE 'https://example.org/test_structure_%'));

SELECT _assert('layers from ETL metadata: no file, no layers (NULL)', backbone.raster_layers_from_etl_metadata('no_such_table_id') IS NULL);

SELECT _assert('layers from ETL metadata: a table_id that is not a plain identifier is refused (it becomes a file path)',
    backbone.etl_metadata_field('../../etc/passwd', 'raster_layers') IS NULL AND backbone.raster_bands_from_etl_metadata('a/b') IS NULL);

-- -------------------------------------------------------------------------
-- A band per variable
-- -------------------------------------------------------------------------
CREATE TABLE public.t_bands (rid SERIAL PRIMARY KEY, rast raster);
INSERT INTO public.t_bands (rast)
SELECT ST_AddBand(ST_AddBand(ST_MakeEmptyRaster(2, 2, -2026000, 1464000, 1000, -1000, 0, 0, 5070), '32BF'::text, 5, -9999), '32BF'::text, 50, -9999);

DO $j$
DECLARE doc JSONB;
BEGIN
    doc := jsonb_build_object('@id', 'https://example.org/t_bands', 'name', 'two-band raster', 'type', 'Dataset',
        'measurementTechnique', jsonb_build_array(jsonb_build_object('inDefinedTermSet', jsonb_build_object('name', 'dataRepresentation'), 'termCode', 'raster')),
        'variableMeasured', jsonb_build_array(
            jsonb_build_object('name', 'b_first', 'startDate', '2014-01-01', 'endDate', '2014-12-31'),
            jsonb_build_object('name', 'b_second', 'startDate', '2014-01-01', 'endDate', '2014-12-31')));
    PERFORM backbone.ingest_jsonld_variables(doc, backbone.ingest_jsonld_metadata(doc));
END
$j$;

SELECT count(*) FROM backbone.gdsc_load_all_raster_variables('t_bands', NULL, 'test', 1, '{"b_second": 2}'::jsonb);
SELECT _assert('bands: a variable named in p_bands reads its band, the others the default band',
    (SELECT array_agg(ai.variable_name || ':' || rl.band ORDER BY ai.variable_name) = ARRAY['b_first:1', 'b_second:2']
     FROM backbone.raster_layer rl JOIN backbone.attr_index ai USING (attr_index_id) WHERE ai.table_name = 't_bands'));

DELETE FROM working.external_exposure;
SELECT working.spatial_join_raster_from_catalog('b_second', 't_bands');
SELECT _assert('bands: the join of the second variable reads band 2',
    (SELECT value_as_number = 50 FROM working.external_exposure WHERE person_id = 900001 LIMIT 1));
DELETE FROM working.external_exposure;

-- -------------------------------------------------------------------------
-- Privileges
-- -------------------------------------------------------------------------
SELECT _assert('privileges: the anonymous role cannot register a raster, and can join',
    NOT has_function_privilege('web_anon', 'backbone.gdsc_load_raster_variable(jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('web_anon', 'backbone.gdsc_load_all_raster_variables(text, jsonb, text, integer, jsonb)', 'EXECUTE')
    AND has_function_privilege('web_anon', 'working.spatial_join_raster_from_catalog(text, text, text, numeric, integer)', 'EXECUTE'));

-- -------------------------------------------------------------------------
-- Errors
-- -------------------------------------------------------------------------
DO $$
BEGIN
    PERFORM working.spatial_join_raster_from_catalog('no_such_variable');
    RAISE NOTICE 'FAIL: unknown variable should raise';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: unknown variable raises (%)', left(SQLERRM, 40);
END $$;

DO $$
BEGIN
    PERFORM working.spatial_join_raster_from_catalog('test_value', 'test_raster_annual', 'class_fraction', 0);
    RAISE NOTICE 'FAIL: class_fraction without a buffer should raise';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS: class_fraction without a buffer raises';
END $$;

ROLLBACK;
