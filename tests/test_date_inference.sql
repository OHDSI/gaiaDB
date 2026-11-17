-- Tests for date parsing and inference when ingesting JSON-LD variables
-- Covers: backbone.parse_partial_date, backbone.infer_dataset_year, backbone.dataset_year_conflict and the dates
--         ingest_jsonld_variables gives a variable (year-only dates, one-sided dates, temporalCoverage, year in the
--         raster name, the static marker, the static period of a raster with no date at all)
--
-- Run against a fully initialized gaiaDB instance:
--   psql -U postgres -d gaiacore -f tests/test_date_inference.sql
--
-- Everything rolls back when the suite finishes.
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
-- parse_partial_date
-- -------------------------------------------------------------------------
SELECT _assert('parse_partial_date: a year is the whole year',
    backbone.parse_partial_date('2021', FALSE) = '2021-01-01' AND backbone.parse_partial_date('2021', TRUE) = '2021-12-31');
SELECT _assert('parse_partial_date: a month is the whole month (also February of a leap year)',
    backbone.parse_partial_date('2021-03', FALSE) = '2021-03-01' AND backbone.parse_partial_date('2021-03', TRUE) = '2021-03-31'
    AND backbone.parse_partial_date('2024-02', TRUE) = '2024-02-29');
SELECT _assert('parse_partial_date: a full date and an ISO timestamp give their date',
    backbone.parse_partial_date('2021-06-15', TRUE) = '2021-06-15' AND backbone.parse_partial_date('2021-06-15T10:30:00Z', FALSE) = '2021-06-15');
SELECT _assert('parse_partial_date: empty, blank and non-dates give NULL',
    backbone.parse_partial_date(NULL) IS NULL AND backbone.parse_partial_date('  ') IS NULL
    AND backbone.parse_partial_date('soon') IS NULL AND backbone.parse_partial_date('2021-13') IS NULL AND backbone.parse_partial_date('0000') IS NULL);

-- -------------------------------------------------------------------------
-- infer_dataset_year
-- -------------------------------------------------------------------------
SELECT _assert('infer_dataset_year: from the table_id and from the name',
    backbone.infer_dataset_year('mdc_2021_nlcd_land_cover', NULL) = 2021 AND backbone.infer_dataset_year(NULL, '2019 Miami-Dade VIIRS') = 2019);
SELECT _assert('infer_dataset_year: a version number is not a year (v2023-5 after the leading 2021)',
    backbone.infer_dataset_year('mdc_2021_nlcd_tcc_v2023_5', '2021 Miami-Dade NLCD Tree Cover v2023-5') = 2021);
SELECT _assert('infer_dataset_year: name and table_id must agree',
    backbone.infer_dataset_year('mdc_2021_nlcd_land_cover', '2020 Something') IS NULL);
SELECT _assert('dataset_year_conflict: only when both carry a year and they differ',
    backbone.dataset_year_conflict('mdc_2021_x', '2020 Y') AND NOT backbone.dataset_year_conflict('mdc_2021_x', '2021 Y')
    AND NOT backbone.dataset_year_conflict('mdc_2021_x', 'No year') AND NOT backbone.dataset_year_conflict('hh_dem', NULL));
SELECT _assert('infer_dataset_year: no year, or a year that is not leading, gives NULL',
    backbone.infer_dataset_year('hh_dem_srtm', 'Huayhuash DEM (SRTM)') IS NULL AND backbone.infer_dataset_year(NULL, 'DEM of 2010') IS NULL);

-- -------------------------------------------------------------------------
-- Dates of an ingested variable
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fx(p_id TEXT, p_name TEXT, p_structure TEXT, p_cov TEXT, p_start TEXT, p_end TEXT, p_static BOOLEAN DEFAULT FALSE, p_type TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
    doc JSONB;
    u   UUID;
BEGIN
    doc := jsonb_build_object(
        '@id', 'https://example.org/' || p_id, 'name', p_name, 'type', 'Dataset',
        'measurementTechnique', jsonb_build_array(jsonb_build_object(
            'inDefinedTermSet', jsonb_build_object('name', 'dataRepresentation'), 'termCode', p_structure)),
        'variableMeasured', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('name', 'v', 'startDate', p_start, 'endDate', p_end, 'qudt:dataType', p_type))))
        || CASE WHEN p_cov IS NOT NULL THEN jsonb_build_object('temporalCoverage', p_cov) ELSE '{}'::jsonb END
        || CASE WHEN p_static THEN jsonb_build_object('additionalProperty', jsonb_build_array(
               jsonb_build_object('@type', 'PropertyValue', 'propertyID', 'http://dbpedia.org/resource/Spatial_reference_system', 'value', 'https://epsg.io/4326'),
               jsonb_build_object('@type', 'PropertyValue', 'name', 'temporalDimension', 'value', 'static'))) ELSE '{}'::jsonb END;
    u := backbone.ingest_jsonld_metadata(doc);
    PERFORM backbone.ingest_jsonld_variables(doc, u);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _dates(p_table_id TEXT) RETURNS TEXT AS $$
    SELECT attr_start_date::text || '/' || attr_end_date::text FROM backbone.attr_index WHERE table_name = p_table_id;
$$ LANGUAGE sql;

SELECT _fx('t_year_only', 'x', 'raster', NULL, '2024', NULL);
SELECT _assert('a startDate that is only a year covers that year (end inferred)', _dates('t_year_only') = '2024-01-01/2024-12-31');

SELECT _fx('t_end_only', 'x', 'raster', NULL, NULL, '2022');
SELECT _assert('an endDate that is only a year covers that year (start inferred)', _dates('t_end_only') = '2022-01-01/2022-12-31');

SELECT _fx('t_months', 'x', 'vector', NULL, '2021-03', '2021-05');
SELECT _assert('year-month dates run from the first day of the first month to the last day of the last', _dates('t_months') = '2021-03-01/2021-05-31');

SELECT _fx('t_full', 'x', 'vector', '2000-01-01/2001-12-31', '2010-02-03', '2010-04-05');
SELECT _assert('full dates are kept as they are and win over the temporalCoverage', _dates('t_full') = '2010-02-03/2010-04-05');

SELECT _fx('t_cov', 'x', 'vector', '2014/2019', NULL, NULL, FALSE, 'float8');
SELECT _assert('a numeric variable without dates takes the temporalCoverage, years expanded (vector too)', _dates('t_cov') = '2014-01-01/2019-12-31');

SELECT _fx('t_cov_jsonb', 'x', 'vector', '2014/2019', NULL, NULL, FALSE, 'jsonb');
SELECT _assert('a jsonb series without dates takes the temporalCoverage', _dates('t_cov_jsonb') = '2014-01-01/2019-12-31');

SELECT _fx('t_cov_text', 'x', 'vector', '2014/2019', NULL, NULL, FALSE, 'varchar');
SELECT _assert('a text variable (identifier) does not take the temporalCoverage (no attr_index row)',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 't_cov_text'));

SELECT _fx('t_cov_notype', 'x', 'vector', '2014/2019', NULL, NULL);
SELECT _assert('a variable without a data type does not take the temporalCoverage on a vector source (no attr_index row)',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 't_cov_notype'));

SELECT _fx('t_cov_rast', 'x', 'raster', '2014/2019', NULL, NULL);
SELECT _assert('a raster variable takes the temporalCoverage whatever its type', _dates('t_cov_rast') = '2014-01-01/2019-12-31');

SELECT _fx('t_cov_single', 'x', 'vector', '2019', NULL, NULL, FALSE, 'float8');
SELECT _assert('a single-year temporalCoverage is that year', _dates('t_cov_single') = '2019-01-01/2019-12-31');

SELECT _fx('mdc_2021_nlcd_x', '2021 Miami-Dade NLCD X', 'raster', NULL, NULL, NULL);
SELECT _assert('a raster without any dates takes the year in its name and table_id', _dates('mdc_2021_nlcd_x') = '2021-01-01/2021-12-31');

SELECT _fx('mdc_2020_vec', '2020 Vector thing', 'vector', NULL, NULL, NULL);
SELECT _assert('a vector source without dates is not given the year of its name or a static period (no attr_index row)',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 'mdc_2020_vec'));

SELECT _fx('tl_static_vec', 'TIGER thing', 'vector', NULL, NULL, NULL, TRUE, 'float8');
SELECT _assert('a vector dataset marked temporalDimension static gives its undated numeric variables the static period',
    _dates('tl_static_vec') = '1900-01-01/2100-12-31');

SELECT _fx('tl_static_text', 'TIGER names', 'vector', NULL, NULL, NULL, TRUE, 'varchar');
SELECT _assert('a static vector dataset leaves text variables (names, identifiers) unregistered',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 'tl_static_text'));

SELECT _fx('tl_static_notype', 'TIGER no type', 'vector', NULL, NULL, NULL, TRUE);
SELECT _assert('a static vector dataset leaves variables without a data type unregistered',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 'tl_static_notype'));

SELECT _fx('mdc_2021_static_rast', '2021 Marked raster', 'raster', NULL, NULL, NULL, TRUE);
SELECT _assert('the static marker wins over the year in a raster name', _dates('mdc_2021_static_rast') = '1900-01-01/2100-12-31');

SELECT _fx('tl_static_dated', 'x', 'vector', NULL, '2020-01-01', '2020-12-31', TRUE, 'float8');
SELECT _assert('dates on the variable win over the static marker', _dates('tl_static_dated') = '2020-01-01/2020-12-31');

SELECT _fx('tl_static_cov', 'x', 'vector', '2015/2016', NULL, NULL, TRUE, 'float8');
SELECT _assert('the temporalCoverage wins over the static marker', _dates('tl_static_cov') = '2015-01-01/2016-12-31');

SELECT _fx('hh_dem_x', 'Some DEM (SRTM)', 'raster', NULL, NULL, NULL);
SELECT _assert('a raster without any date or year is static', _dates('hh_dem_x') = '1900-01-01/2100-12-31');

SELECT _fx('mdc_2021_clash', '2020 Clash', 'raster', NULL, NULL, NULL);
SELECT _assert('a raster whose name and table_id disagree on the year is not guessed (no attr_index row)',
    NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = 'mdc_2021_clash'));

SELECT _assert('the variable_source row carries the inferred dates too',
    (SELECT start_date = '2021-01-01' AND end_date = '2021-12-31' FROM backbone.variable_source vs
     JOIN backbone.data_source ds USING (data_source_uuid) WHERE ds.dataset_id = 'https://example.org/mdc_2021_nlcd_x'));

ROLLBACK;
