-- Tests for recipe ingestion (sql/08b_recipe_ingestion.sql)
-- Covers: backbone.is_recipe, recipe_validity, recipe_concept_id, recipe_data_type, and the rows
--         load_jsonld_file() writes to data_source, variable_source, geom_index and attr_index for a recipe
--         (the four example recipes of OHDSI/gaiaCatalog schema/recipes), plus the errors a recipe must raise.
--
-- Run against a fully initialized gaiaDB instance:
--   psql -U postgres -d gaiacore -f tests/test_recipe_ingestion.sql
--
-- Everything rolls back when the suite finishes.
-- Output: PASS / FAIL lines via RAISE NOTICE.

BEGIN;

CREATE OR REPLACE FUNCTION _assert(description TEXT, condition BOOLEAN)
RETURNS VOID AS $$
BEGIN
    IF condition THEN RAISE NOTICE 'PASS: %', description; ELSE RAISE NOTICE 'FAIL: %', description; END IF;
END;
$$ LANGUAGE plpgsql;

-- true when running the statement raises an error whose message contains the text
CREATE OR REPLACE FUNCTION _raises(p_sql TEXT, p_text TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE p_sql;
    RETURN FALSE;
EXCEPTION WHEN OTHERS THEN
    RETURN position(p_text in SQLERRM) > 0;
END;
$$ LANGUAGE plpgsql;

CREATE TEMP TABLE _recipes (name TEXT PRIMARY KEY, doc TEXT);
INSERT INTO _recipes VALUES ('mdc_2021_nlcd_land_cover', $r${"@context":{"schema":"http://schema.org/","cdif":"https://w3id.org/cdif/","cdi":"http://ddialliance.org/Specification/DDI-CDI/1.0/RDF/","geocr":"http://mlcommons.org/croissant/geocr/","geosparql":"http://www.opengis.net/ont/geosparql#","dcterms":"http://purl.org/dc/terms/","spdx":"http://spdx.org/rdf/terms#","gaia":"https://w3id.org/ohdsi/gaia/"},"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_2021_nlcd_land_cover","@type":["schema:Dataset"],"schema:identifier":{"@type":["schema:PropertyValue"],"schema:propertyID":{"@id":"https://w3id.org/ohdsi/gaia/recipe/"},"schema:value":"mdc_2021_nlcd_land_cover"},"schema:name":"2021 Miami-Dade NLCD Land Cover","schema:version":"2026-10-17","schema:license":["https://creativecommons.org/publicdomain/mark/1.0/"],"gaia:representation":"raster","geosparql:crs":{"@id":"http://www.opengis.net/def/crs/EPSG/0/4326"},"geocr:spatialResolution":{"schema:value":30,"schema:unitCode":"http://qudt.org/vocab/unit/M"},"gaia:validity":{"gaia:start":"2021","gaia:end":"2021","gaia:layout":"single"},"gaia:updateFrequency":"never","schema:variableMeasured":[{"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_2021_nlcd_land_cover/var/lc","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"lc","schema:description":"Classified land cover (NLCD 2021, contiguous US legend)","cdif:role":"Measure","cdif:physicalDataType":"uint8","gaia:band":1,"gaia:valueDomain":[{"gaia:code":"11","gaia:label":"Open Water"},{"gaia:code":"12","gaia:label":"Perennial Ice/Snow"},{"gaia:code":"21","gaia:label":"Developed, Open Space"},{"gaia:code":"22","gaia:label":"Developed, Low Intensity"},{"gaia:code":"23","gaia:label":"Developed, Medium Intensity"},{"gaia:code":"24","gaia:label":"Developed, High Intensity"},{"gaia:code":"31","gaia:label":"Barren Land"},{"gaia:code":"41","gaia:label":"Deciduous Forest"},{"gaia:code":"42","gaia:label":"Evergreen Forest"},{"gaia:code":"43","gaia:label":"Mixed Forest"},{"gaia:code":"52","gaia:label":"Shrub/Scrub"},{"gaia:code":"71","gaia:label":"Grassland/Herbaceous"},{"gaia:code":"81","gaia:label":"Pasture/Hay"},{"gaia:code":"82","gaia:label":"Cultivated Crops"},{"gaia:code":"90","gaia:label":"Woody Wetlands"},{"gaia:code":"95","gaia:label":"Emergent Herbaceous Wetlands"}]}],"gaia:files":[{"gaia:path":"mdc_2021_nlcd_land_cover.tif"}],"gaia:derivation":{"gaia:method":"clip","gaia:inputs":["us_2021_nlcd_land_cover","fl_2022_tl_cousub"],"gaia:parameters":{"cutline":{"recipe":"fl_2022_tl_cousub","filter":[{"column":"countyfp","operator":"=","value":"086"}]}}},"schema:subjectOf":{"dcterms:conformsTo":[{"@id":"https://w3id.org/cdif/core/2.0"},{"@id":"https://w3id.org/cdif/discovery/2.0"},{"@id":"https://w3id.org/cdif/data_description/2.0"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/0.1"}]}}$r$);
INSERT INTO _recipes VALUES ('mdc_hospitals', $r${"@context":{"schema":"http://schema.org/","cdif":"https://w3id.org/cdif/","cdi":"http://ddialliance.org/Specification/DDI-CDI/1.0/RDF/","geocr":"http://mlcommons.org/croissant/geocr/","geosparql":"http://www.opengis.net/ont/geosparql#","dcterms":"http://purl.org/dc/terms/","spdx":"http://spdx.org/rdf/terms#","gaia":"https://w3id.org/ohdsi/gaia/"},"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals","@type":["schema:Dataset"],"schema:identifier":{"@type":["schema:PropertyValue"],"schema:propertyID":{"@id":"https://w3id.org/ohdsi/gaia/recipe/"},"schema:value":"mdc_hospitals"},"schema:name":"Miami-Dade Hospitals","schema:version":"2026-10-17","schema:license":["https://creativecommons.org/publicdomain/mark/1.0/"],"gaia:representation":"vector","geosparql:crs":{"@id":"http://www.opengis.net/def/crs/EPSG/0/4326"},"gaia:geometryType":"point","gaia:labelColumn":"name","gaia:validity":{"gaia:static":true},"gaia:updateFrequency":"as_needed","schema:variableMeasured":[{"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals/var/objectid","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"objectid","cdif:role":"UnitIdentifier","cdif:physicalDataType":"int4","schema:minValue":1,"schema:maxValue":28},{"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals/var/name","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"name","cdif:role":"Descriptor","cdif:physicalDataType":"varchar"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals/var/zipcode","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"zipcode","cdif:role":"Attribute","cdif:physicalDataType":"int4","schema:minValue":33012,"schema:maxValue":33189}],"cdif:hasPrimaryKey":{"@type":["cdif:Key"],"cdif:isComposedOf":[{"@type":["cdi:ComponentPosition"],"cdi:indexes":{"@id":"https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals/var/objectid"},"cdi:value":1}]},"gaia:retrieval":{"gaia:method":"arcgis_featureserver","gaia:url":"https://services.arcgis.com/8Pc9XBTAsYuxx9Ny/arcgis/rest/services/Hospital_gdb/FeatureServer/0/query?where=1%3D1&outFields=*&outSR=4326&f=json"},"schema:subjectOf":{"dcterms:conformsTo":[{"@id":"https://w3id.org/cdif/core/2.0"},{"@id":"https://w3id.org/cdif/discovery/2.0"},{"@id":"https://w3id.org/cdif/data_description/2.0"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/0.1"}]}}$r$);
INSERT INTO _recipes VALUES ('synthetic_raster_annual', $r${"@context":{"schema":"http://schema.org/","cdif":"https://w3id.org/cdif/","cdi":"http://ddialliance.org/Specification/DDI-CDI/1.0/RDF/","geocr":"http://mlcommons.org/croissant/geocr/","geosparql":"http://www.opengis.net/ont/geosparql#","dcterms":"http://purl.org/dc/terms/","spdx":"http://spdx.org/rdf/terms#","gaia":"https://w3id.org/ohdsi/gaia/"},"@id":"https://w3id.org/ohdsi/gaia/recipe/synthetic_raster_annual","@type":["schema:Dataset"],"schema:identifier":{"@type":["schema:PropertyValue"],"schema:propertyID":{"@id":"https://w3id.org/ohdsi/gaia/recipe/"},"schema:value":"synthetic_raster_annual"},"schema:name":"Simulated annual exposure rasters","schema:version":"2026-11-13","schema:license":["https://creativecommons.org/publicdomain/zero/1.0/"],"gaia:representation":"raster","geosparql:crs":{"@id":"http://www.opengis.net/def/crs/EPSG/0/5070"},"geocr:spatialResolution":{"schema:value":250,"schema:unitCode":"http://qudt.org/vocab/unit/M"},"geocr:temporalResolution":"P1Y","gaia:validity":{"gaia:start":"2014","gaia:end":"2019","gaia:layout":"file_per_period"},"gaia:updateFrequency":"never","schema:variableMeasured":[{"@id":"https://w3id.org/ohdsi/gaia/recipe/synthetic_raster_annual/var/pm25_annual","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"pm25_annual","schema:description":"Simulated annual exposure at the cell centre","schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}],"cdif:role":"Measure","cdif:physicalDataType":"float32","schema:unitCode":"http://qudt.org/vocab/unit/MicroGM-PER-M3","cdi:nullSequence":-9999,"gaia:band":1}],"gaia:files":[{"gaia:path":"synthetic_raster_annual_2014.tif","gaia:period":{"gaia:start":"2014","gaia:end":"2014"},"spdx:checksum":"sha256:ef213ba4c7a3e69aeeda46ddea813e65ab72a21466542859cf079c21a18e8b17"},{"gaia:path":"synthetic_raster_annual_2015.tif","gaia:period":{"gaia:start":"2015","gaia:end":"2015"},"spdx:checksum":"sha256:becb32b88479815d6ee9111bf3f2fb471bd91e393b32669c1badff72516b5059"},{"gaia:path":"synthetic_raster_annual_2016.tif","gaia:period":{"gaia:start":"2016","gaia:end":"2016"},"spdx:checksum":"sha256:7aabf051d8883140d28d493d474377b320c3fab2a168f8a971c0bb7ce52371a1"},{"gaia:path":"synthetic_raster_annual_2017.tif","gaia:period":{"gaia:start":"2017","gaia:end":"2017"},"spdx:checksum":"sha256:e781b81d588ddc6a18106fa65cbfdf27b0c64b7d18e37796095e98f7cf3cf943"},{"gaia:path":"synthetic_raster_annual_2018.tif","gaia:period":{"gaia:start":"2018","gaia:end":"2018"},"spdx:checksum":"sha256:27f274a846ee055f6aead084a3fcdc5cc131b5dda2acb44834a4453b774f384a"},{"gaia:path":"synthetic_raster_annual_2019.tif","gaia:period":{"gaia:start":"2019","gaia:end":"2019"},"spdx:checksum":"sha256:1f45681ec031daa2eb8c60dd12a96c2e7c27c05e8dc64abf3e70815d5e8e4c3a"}],"gaia:retrieval":{"gaia:method":"download","gaia:url":"https://raw.githubusercontent.com/OHDSI/GIS/main/syntheticDataGIS/raster/data"},"schema:subjectOf":{"dcterms:conformsTo":[{"@id":"https://w3id.org/cdif/core/2.0"},{"@id":"https://w3id.org/cdif/discovery/2.0"},{"@id":"https://w3id.org/cdif/data_description/2.0"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/0.1"}]}}$r$);
INSERT INTO _recipes VALUES ('us_2014_2019_monthly_pm25_by_county_cdc', $r${"@context":{"schema":"http://schema.org/","cdif":"https://w3id.org/cdif/","cdi":"http://ddialliance.org/Specification/DDI-CDI/1.0/RDF/","geocr":"http://mlcommons.org/croissant/geocr/","geosparql":"http://www.opengis.net/ont/geosparql#","dcterms":"http://purl.org/dc/terms/","spdx":"http://spdx.org/rdf/terms#","gaia":"https://w3id.org/ohdsi/gaia/"},"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc","@type":["schema:Dataset"],"schema:identifier":{"@type":["schema:PropertyValue"],"schema:propertyID":{"@id":"https://w3id.org/ohdsi/gaia/recipe/"},"schema:value":"us_2014_2019_monthly_pm25_by_county_cdc"},"schema:name":"2014-2019 CDC PM 2.5 Monthly Predictions for US Counties","schema:version":"2026-10-09","schema:license":["https://opendatacommons.org/licenses/by/1-0/"],"gaia:representation":"table","geosparql:crs":{"@id":"http://www.opengis.net/def/crs/EPSG/0/4269"},"geocr:temporalResolution":"P1M","gaia:validity":{"gaia:start":"2014-01","gaia:end":"2019-12","gaia:layout":"jsonb_series"},"gaia:updateFrequency":"never","schema:variableMeasured":[{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/statefips","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"statefips","cdif:role":"Attribute","cdif:physicalDataType":"varchar"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/countyfips","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"countyfips","cdif:role":"Attribute","cdif:physicalDataType":"varchar"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/geoid","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"geoid","cdif:role":"UnitIdentifier","cdif:physicalDataType":"varchar"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/pm25_max_pred","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"pm25_max_pred","schema:description":"Maximum predicted PM2.5","schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}],"cdif:role":"Measure","cdif:physicalDataType":"jsonb","schema:unitCode":"http://qudt.org/vocab/unit/MicroGM-PER-M3","gaia:validity":{"gaia:start":"2014-01","gaia:end":"2019-12","gaia:layout":"jsonb_series"}},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/pm25_med_pred","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"pm25_med_pred","schema:description":"Median predicted PM2.5","schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}],"cdif:role":"Measure","cdif:physicalDataType":"jsonb","schema:unitCode":"http://qudt.org/vocab/unit/MicroGM-PER-M3","gaia:validity":{"gaia:start":"2014-01","gaia:end":"2019-12","gaia:layout":"jsonb_series"}},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/pm25_mean_pred","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"pm25_mean_pred","schema:description":"Mean predicted PM2.5","schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}],"cdif:role":"Measure","cdif:physicalDataType":"jsonb","schema:unitCode":"http://qudt.org/vocab/unit/MicroGM-PER-M3","gaia:validity":{"gaia:start":"2014-01","gaia:end":"2019-12","gaia:layout":"jsonb_series"}},{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/pm25_pop_pred","@type":["schema:PropertyValue","cdi:InstanceVariable"],"schema:name":"pm25_pop_pred","schema:description":"Population-weighted predicted PM2.5","schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}],"cdif:role":"Measure","cdif:physicalDataType":"jsonb","schema:unitCode":"http://qudt.org/vocab/unit/MicroGM-PER-M3","gaia:validity":{"gaia:start":"2014-01","gaia:end":"2019-12","gaia:layout":"jsonb_series"}}],"cdif:hasPrimaryKey":{"@type":["cdif:Key"],"cdif:isComposedOf":[{"@type":["cdi:ComponentPosition"],"cdi:indexes":{"@id":"https://w3id.org/ohdsi/gaia/recipe/us_2014_2019_monthly_pm25_by_county_cdc/var/geoid"},"cdi:value":1}]},"gaia:joinsTo":{"gaia:table":"us_2019_county_tl","gaia:joinKey":"geoid","gaia:targetKey":"geoid"},"gaia:retrieval":{"gaia:method":"api_query","gaia:url":"https://data.cdc.gov/api/v3/views/53mz-4zqd/query.csv","gaia:credential":"CDC_APP_TOKEN","gaia:transform":{"gaia:engine":"ogr2ogr_sqlite","gaia:reason":"Parses month strings and pivots rows into one jsonb series per county (the jsonb_series operation, not yet defined)","gaia:script":"see etl_parameters in meta_etl_us_2014_2019_monthly_pm25_by_county_cdc.json"}},"schema:subjectOf":{"dcterms:conformsTo":[{"@id":"https://w3id.org/cdif/core/2.0"},{"@id":"https://w3id.org/cdif/discovery/2.0"},{"@id":"https://w3id.org/cdif/data_description/2.0"},{"@id":"https://w3id.org/ohdsi/gaia/recipe/0.1"}]}}$r$);

-- -------------------------------------------------------------------------
-- helpers
-- -------------------------------------------------------------------------
SELECT _assert('is_recipe: true for each example recipe',
    (SELECT bool_and(backbone.is_recipe(doc::jsonb)) FROM _recipes));
SELECT _assert('is_recipe: false for a flat JSON-LD document, a document with no conformsTo, and an empty object',
    NOT backbone.is_recipe('{"@id":"https://x/y","name":"y"}'::jsonb)
    AND NOT backbone.is_recipe('{"schema:subjectOf":{"dcterms:conformsTo":[{"@id":"https://w3id.org/cdif/core/2.0"}]}}'::jsonb)
    AND NOT backbone.is_recipe('{}'::jsonb));

SELECT _assert('recipe_validity: a period gives its first and last day',
    (SELECT start_date = '2014-01-01' AND end_date = '2019-12-31'
     FROM backbone.recipe_validity('{"gaia:start":"2014-01","gaia:end":"2019-12"}'::jsonb)));
SELECT _assert('recipe_validity: static gives the static period',
    (SELECT start_date = '1900-01-01' AND end_date = '2100-12-31' FROM backbone.recipe_validity('{"gaia:static":true}'::jsonb)));
SELECT _assert('recipe_validity: nothing or nonsense gives NULL',
    (SELECT start_date IS NULL AND end_date IS NULL FROM backbone.recipe_validity(NULL))
    AND (SELECT start_date IS NULL FROM backbone.recipe_validity('{"gaia:start":"soon","gaia:end":"later"}'::jsonb)));

SELECT _assert('recipe_concept_id: an Athena URI, a bare integer, and no concept',
    backbone.recipe_concept_id('{"schema:propertyID":[{"@id":"https://athena.ohdsi.org/search-terms/terms/2052499839"}]}'::jsonb) = 2052499839
    AND backbone.recipe_concept_id('{"schema:propertyID":[2052499839]}'::jsonb) = 2052499839
    AND backbone.recipe_concept_id('{"schema:propertyID":[{"@id":"https://example.org/other"}]}'::jsonb) IS NULL
    AND backbone.recipe_concept_id('{}'::jsonb) IS NULL);
SELECT _assert('recipe_data_type: raster value types map to a Postgres name, others pass through',
    backbone.recipe_data_type('float32') = 'float4' AND backbone.recipe_data_type('uint8') = 'int2'
    AND backbone.recipe_data_type('jsonb') = 'jsonb' AND backbone.recipe_data_type('varchar') = 'varchar');

-- -------------------------------------------------------------------------
-- loading the example recipes through load_jsonld_file (the dispatch)
-- -------------------------------------------------------------------------
SELECT _assert('load_jsonld_file: loads all four recipes and reports their variable counts',
    (SELECT array_agg(r.variables_loaded ORDER BY r.dataset_name)
     FROM _recipes, LATERAL backbone.load_jsonld_file(doc) r) = ARRAY[7, 1, 3, 1]);

SELECT _assert('data_source: id, name, version, license and the structure term are read from the recipe',
    (SELECT dataset_name = 'Miami-Dade Hospitals' AND dataset_version = '2026-10-17'
        AND license = 'https://creativecommons.org/publicdomain/mark/1.0/'
        AND backbone.datasource_structure(data_source_uuid) = 'vector'
     FROM backbone.data_source WHERE dataset_id = 'https://w3id.org/ohdsi/gaia/recipe/mdc_hospitals'));
SELECT _assert('data_source: geom_type is the geometry of a vector, Raster Dataset for a raster, and a label for an unjoined table',
    (SELECT geom_type FROM backbone.data_source WHERE dataset_id LIKE '%/mdc_hospitals') = 'point'
    AND (SELECT geom_type FROM backbone.data_source WHERE dataset_id LIKE '%/synthetic_raster_annual') = 'Raster Dataset'
    AND (SELECT geom_type FROM backbone.data_source WHERE dataset_id LIKE '%/us_2014_2019_monthly_pm25_by_county_cdc') = 'Table Dataset');
SELECT _assert('data_source: srid comes from the EPSG URI',
    (SELECT srid FROM backbone.data_source WHERE dataset_id LIKE '%/synthetic_raster_annual') = 5070
    AND (SELECT srid FROM backbone.data_source WHERE dataset_id LIKE '%/mdc_hospitals') = 4326
    AND (SELECT srid FROM backbone.data_source WHERE dataset_id LIKE '%/us_2014_2019_monthly_pm25_by_county_cdc') = 4269);
SELECT _assert('data_source.etl_metadata keeps what a loader needs: label column, join target, retrieval, derivation, files',
    (SELECT etl_metadata->>'label_column' = 'name' AND etl_metadata->'retrieval'->>'gaia:method' = 'arcgis_featureserver'
     FROM backbone.data_source WHERE dataset_id LIKE '%/mdc_hospitals')
    AND (SELECT etl_metadata->'joins_to'->>'gaia:table' = 'us_2019_county_tl' AND etl_metadata->'retrieval'->>'gaia:credential' = 'CDC_APP_TOKEN'
         FROM backbone.data_source WHERE dataset_id LIKE '%/us_2014_2019_monthly_pm25_by_county_cdc')
    AND (SELECT etl_metadata->'derivation'->>'gaia:method' = 'clip' FROM backbone.data_source WHERE dataset_id LIKE '%/mdc_2021_nlcd_land_cover')
    AND (SELECT jsonb_array_length(etl_metadata->'files') = 6 FROM backbone.data_source WHERE dataset_id LIKE '%/synthetic_raster_annual'));

-- variable_source
SELECT _assert('variable_source: the validity is the declared one (period, static, one year)',
    (SELECT bool_and(start_date = '2014-01-01' AND end_date = '2019-12-31') FROM backbone.variable_source vs
     JOIN backbone.data_source ds USING (data_source_uuid) WHERE ds.dataset_id LIKE '%/us_2014_2019_monthly_pm25_by_county_cdc')
    AND (SELECT bool_and(start_date = '1900-01-01' AND end_date = '2100-12-31') FROM backbone.variable_source vs
         JOIN backbone.data_source ds USING (data_source_uuid) WHERE ds.dataset_id LIKE '%/mdc_hospitals')
    AND (SELECT bool_and(start_date = '2021-01-01' AND end_date = '2021-12-31') FROM backbone.variable_source vs
         JOIN backbone.data_source ds USING (data_source_uuid) WHERE ds.dataset_id LIKE '%/mdc_2021_nlcd_land_cover'));
SELECT _assert('variable_source: concept id from the Athena URI; none where the recipe gives none',
    (SELECT attr_concept_id FROM backbone.variable_source WHERE variable_name = 'pm25_annual'
        AND data_source_uuid = (SELECT data_source_uuid FROM backbone.data_source WHERE dataset_id LIKE '%/synthetic_raster_annual')) = 2052499839
    AND (SELECT attr_concept_id IS NULL FROM backbone.variable_source WHERE variable_name = 'lc'
        AND data_source_uuid = (SELECT data_source_uuid FROM backbone.data_source WHERE dataset_id LIKE '%/mdc_2021_nlcd_land_cover')));
SELECT _assert('variable_source: types, unit and min/max are read from the recipe',
    (SELECT data_type = 'float4' AND unit_code = 'http://qudt.org/vocab/unit/MicroGM-PER-M3' FROM backbone.variable_source WHERE variable_name = 'pm25_annual')
    AND (SELECT data_type = 'int2' FROM backbone.variable_source WHERE variable_name = 'lc')
    AND (SELECT min_value = 33012 AND max_value = 33189 FROM backbone.variable_source WHERE variable_name = 'zipcode'));

-- attr_index: only the variables to be loaded as values
SELECT _assert('attr_index: the four PM2.5 measures are registered, the id and FIPS columns are not',
    (SELECT array_agg(variable_name::text ORDER BY variable_name) FROM backbone.attr_index WHERE table_name = 'us_2014_2019_monthly_pm25_by_county_cdc')
        = ARRAY['pm25_max_pred', 'pm25_mean_pred', 'pm25_med_pred', 'pm25_pop_pred']);
SELECT _assert('attr_index: a numeric attribute is registered, an identifier and a name are not (the identifier-column bug)',
    (SELECT array_agg(variable_name::text) FROM backbone.attr_index WHERE table_name = 'mdc_hospitals') = ARRAY['zipcode']);
SELECT _assert('attr_index: nodata comes from the recipe; dates and concept as declared',
    (SELECT attr_no_value_as_number = -9999 AND attr_start_date = '2014-01-01' AND attr_end_date = '2019-12-31' AND attr_concept_id = 2052499839
     FROM backbone.attr_index WHERE table_name = 'synthetic_raster_annual' AND variable_name = 'pm25_annual'));
SELECT _assert('attr_index: a categorical raster measure is registered for its year',
    (SELECT attr_start_date = '2021-01-01' AND attr_end_date = '2021-12-31' FROM backbone.attr_index WHERE table_name = 'mdc_2021_nlcd_land_cover'));
SELECT _assert('geom_index: one row per recipe table, with the data source geometry type',
    (SELECT count(*) FROM backbone.geom_index WHERE table_name IN ('mdc_hospitals','synthetic_raster_annual','mdc_2021_nlcd_land_cover','us_2014_2019_monthly_pm25_by_county_cdc')) = 4
    AND (SELECT geom_type_source_value FROM backbone.geom_index WHERE table_name = 'mdc_hospitals') = 'point');

-- loading again changes nothing
SELECT count(*) AS attr_rows_before FROM backbone.attr_index \gset
SELECT count(*) AS vs_rows_before FROM backbone.variable_source \gset
SELECT count(*) FROM _recipes, LATERAL backbone.load_jsonld_file(doc) \gset
SELECT _assert('loading the recipes a second time adds no rows',
    (SELECT count(*) FROM backbone.attr_index) = :attr_rows_before AND (SELECT count(*) FROM backbone.variable_source) = :vs_rows_before);

-- -------------------------------------------------------------------------
-- errors
-- -------------------------------------------------------------------------
SELECT _assert('a recipe without gaia:validity is refused (no inference)',
    _raises($q$SELECT backbone.ingest_recipe_metadata((SELECT doc::jsonb - 'gaia:validity' FROM _recipes WHERE name = 'mdc_hospitals'))$q$, 'must declare gaia:validity'));
SELECT _assert('a recipe whose @id does not end with its table id is refused',
    _raises($q$SELECT backbone.ingest_recipe_metadata((SELECT jsonb_set(doc::jsonb, '{@id}', '"https://w3id.org/ohdsi/gaia/recipe/other"') FROM _recipes WHERE name = 'mdc_hospitals'))$q$, 'must end with the table id'));
SELECT _assert('a document that is not a recipe is refused by ingest_recipe_metadata',
    _raises($q$SELECT backbone.ingest_recipe_metadata('{"@id":"https://x/y","name":"y"}'::jsonb)$q$, 'not a recipe'));
SELECT _assert('a recipe with an unknown representation is refused',
    _raises($q$SELECT backbone.ingest_recipe_metadata((SELECT jsonb_set(doc::jsonb, '{gaia:representation}', '"cube"') FROM _recipes WHERE name = 'mdc_hospitals'))$q$, 'gaia:representation'));

ROLLBACK;
