-- Cleanup for databases that ingested JSON-LD metadata with gaiaDB between 2026-11-13 (raster support, a3c0ca3) and
-- the fix of 2026-11-17 (25d831e).
--
-- In that window an undated text variable (an identifier or a name) of a dataset that has a temporalCoverage was
-- registered in backbone.attr_index with the dataset's period, so gdsc_load_all_variables would try to load it as a value.
-- This removes those registrations (and any values already loaded for them). The variable descriptions in
-- backbone.variable_source stay. It touches only the 21 variables below, which are the text variables without dates in the
-- gaiaCatalog JSON-LD of 2026-11-17 that have a dataset temporalCoverage; names are compared trimmed (two names in the
-- Tanzania entry start with a newline in the catalog).
--
-- Run it in psql as the database owner. It reports what it removed; nothing happens for a variable that is not registered.
-- Check the list first:
--   SELECT ai.attr_index_id, ai.table_name, ai.variable_name, vs.data_type
--   FROM backbone.attr_index ai JOIN backbone.variable_source vs USING (variable_source_id)
--   WHERE lower(vs.data_type) NOT IN ('float','float4','float8','real','double','double precision','numeric','decimal',
--     'number','int','int2','int4','int8','int16','int32','int64','smallint','integer','bigint','long','short','jsonb','json')
--   ORDER BY 2, 3;   -- text variables that are registered: review any that are not in the list below

BEGIN;

CREATE TEMP TABLE cleanup_variables (table_id TEXT, variable_name TEXT) ON COMMIT DROP;
INSERT INTO cleanup_variables VALUES
    ('synthetic_county_ses', 'geoid'),
    ('synthetic_road_proximity', 'band'),
    ('synthetic_tract_ses', 'geoid'),
    ('tz_2022_nbs_magu_district', 'dist_name'),
    ('tz_2022_nbs_magu_district', 'reg_name'),
    ('us_2014_2019_monthly_pm25_by_county_cdc', 'statefips'),
    ('us_2014_2019_monthly_pm25_by_county_cdc', 'countyfips'),
    ('us_2014_2019_monthly_pm25_by_county_cdc', 'geoid'),
    ('us_2014_2019_monthly_pm25_by_tract_cdc', 'statefips'),
    ('us_2014_2019_monthly_pm25_by_tract_cdc', 'countyfips'),
    ('us_2014_2019_monthly_pm25_by_tract_cdc', 'geoid'),
    ('us_2019_prisecroads_tl', 'linearid'),
    ('us_2019_prisecroads_tl', 'fullname'),
    ('us_2019_prisecroads_tl', 'rttyp'),
    ('us_2019_prisecroads_tl', 'mtfcc'),
    ('us_2022_annual_aqi_by_county', 'state'),
    ('us_2022_annual_aqi_by_county', 'county'),
    ('us_2022_annual_aqi_by_county', 'year'),
    ('us_2023_annual_aqi_by_county', 'state'),
    ('us_2023_annual_aqi_by_county', 'county'),
    ('us_2023_annual_aqi_by_county', 'year');

DO $$
DECLARE
    r RECORD;
    v_values BIGINT;
    v_total_values BIGINT := 0;
    v_registrations INTEGER := 0;
BEGIN
    FOR r IN
        SELECT ai.attr_index_id, ai.table_name, ai.variable_name, ai.database_schema
        FROM backbone.attr_index ai
        JOIN backbone.variable_source vs ON vs.variable_source_id = ai.variable_source_id
        JOIN cleanup_variables c ON c.table_id = ai.table_name AND btrim(c.variable_name) = btrim(ai.variable_name)
        WHERE lower(vs.data_type) NOT IN ('float', 'float4', 'float8', 'real', 'double', 'double precision', 'numeric', 'decimal',
                                          'number', 'int', 'int2', 'int4', 'int8', 'int16', 'int32', 'int64', 'smallint',
                                          'integer', 'bigint', 'long', 'short', 'jsonb', 'json')
    LOOP
        -- values loaded by gdsc_load_all_variables, if the attribute table exists
        IF to_regclass(format('working.%I', 'attr_' || r.table_name)) IS NOT NULL THEN
            EXECUTE format('DELETE FROM working.%I WHERE attr_index_id = %s', 'attr_' || r.table_name, r.attr_index_id);
            GET DIAGNOSTICS v_values = ROW_COUNT;
            v_total_values := v_total_values + v_values;
        END IF;
        DELETE FROM backbone.attr_index WHERE attr_index_id = r.attr_index_id;
        v_registrations := v_registrations + 1;
        RAISE NOTICE 'removed %.% (attr_index_id %)', r.table_name, btrim(r.variable_name), r.attr_index_id;
    END LOOP;
    RAISE NOTICE '% registration(s) and % loaded value row(s) removed', v_registrations, v_total_values;
END
$$;

COMMIT;
