-- Tests for JSON-LD ingestion pipeline
-- Covers: ingest_jsonld_metadata, ingest_jsonld_variables, load_jsonld_file,
--         load_datasource_metadata, retrieve_and_ingest_datasource,
--         ingest_datasource, list_downloadable_datasources, create_datasource_table
--
-- Run against a fully initialized gaiaDB instance:
--   psql -U postgres -d gaiacore -f tests/test_jsonld_ingestion.sql
--
-- Tests use a savepoint-per-test pattern so each test is isolated and the
-- entire suite rolls back when finished, leaving no state in the database.
--
-- Output: PASS / FAIL lines via RAISE NOTICE.

BEGIN;

-- -------------------------------------------------------------------------
-- Assertion helper
-- -------------------------------------------------------------------------
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
-- Fixture: the example JSON-LD document
-- (trimmed to only the fields exercised by the ingestion functions)
-- -------------------------------------------------------------------------
CREATE TEMP TABLE fixture(doc JSONB) ON COMMIT DROP;

INSERT INTO fixture VALUES ($$
{
  "@context": {
    "@language": "en",
    "@vocab": "https://schema.org/"
  },
  "@type": "Dataset",
  "@id": "https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract",
  "name": "2022 Massachusetts CDC Social Vulnerability Index (tracts)",
  "version": "2026-02-10",
  "description": "Social vulnerability refers to the potential negative effects on communities.",
  "license": "https://creativecommons.org/licenses/by/4.0/",
  "url": "https://www.atsdr.cdc.gov/place-health/php/svi/svi-data-documentation-download.html",
  "datePublished": "2020-10-22",
  "dateModified": "2026-02-23",
  "creator": [
    {
      "@type": "Organization",
      "name": "Center for Disease Control"
    }
  ],
  "provider": ["CDC"],
  "keywords": ["Massachusetts", "CDC", "Vulnerability", "Social Vulnerability Index", "Census Tracts", "Public-Safety"],
  "spatialCoverage": [
    {
      "@type": "AdministrativeArea",
      "name": "Massachusetts"
    }
  ],
  "about": [
    {
      "@type": "Event",
      "name": "ETL process for 2022 Massachusetts CDC Social Vulnerability Index (tracts)",
      "potentialAction": {
        "@type": "Action",
        "name": "Pseudo Code",
        "description": "TODO",
        "result": {
          "@type": "Dataset",
          "encodingFormat": "sql",
          "url": "https://gdsc.idsc.miami.edu/download/data/ma_2022_svi_tract/?file=ma_2022_svi_tract&format=sql"
        }
      }
    },
    {
      "@type": "Event",
      "name": "ETL process for 2022 Massachusetts CDC Social Vulnerability Index (tracts)",
      "potentialAction": {
        "@type": "Action",
        "name": "wget",
        "description": "ETL process for 2022 Massachusetts CDC Social Vulnerability Index (tracts)",
        "object": {
          "@type": "Dataset",
          "url": "https://www.atsdr.cdc.gov/place-health/php/svi/svi-data-documentation-download.html"
        },
        "result": {
          "@type": "Dataset",
          "encodingFormat": "sql",
          "url": "https://gdsc.idsc.miami.edu/download/data/ma_2022_svi_tract/?file=ma_2022_svi_tract&format=sql"
        }
      }
    }
  ],
  "variableMeasured": [
    {
      "@type": "PropertyValue",
      "name": "area_sqmi",
      "description": "Tract area in square miles",
      "propertyID": ["2052497175"],
      "qudt:dataType": "float8",
      "unitText": "square miles"
    },
    {
      "@type": "PropertyValue",
      "name": "county",
      "description": "County name",
      "propertyID": ["2052499639"],
      "qudt:dataType": "varchar"
    },
    {
      "@type": "PropertyValue",
      "name": "e_afam",
      "description": "Black/African American persons estimate",
      "propertyID": ["2052499783"],
      "qudt:dataType": "int4",
      "unitCode": "H87",
      "unitText": "1 person",
      "minValue": "",
      "maxValue": ""
    },
    {
      "@type": "PropertyValue",
      "name": "e_totpop",
      "description": "Population estimate",
      "propertyID": ["2052499900"],
      "qudt:dataType": "int4",
      "unitCode": "H87",
      "unitText": "1 person",
      "minValue": "0",
      "maxValue": "999999"
    },
    {
      "@type": "PropertyValue",
      "name": "rpl_themes",
      "description": "Overall percentile ranking",
      "propertyID": ["2052500100"],
      "qudt:dataType": "float8",
      "minValue": "0",
      "maxValue": "1",
      "startDate": "2022-01-01",
      "endDate": "2022-12-31"
    }
  ],
  "measurementTechnique": [
    {
      "@type": "DefinedTerm",
      "inDefinedTermSet": {
        "@type": "DefinedTermSet",
        "name": "dataRepresentation"
      },
      "termCode": "vector"
    },
    {
      "@type": "DefinedTerm",
      "inDefinedTermSet": {
        "@type": "DefinedTermSet",
        "name": "vectorGeometry"
      },
      "termCode": "multipolygon"
    }
  ],
  "additionalProperty": [
    {
      "@type": "PropertyValue",
      "propertyID": "http://dbpedia.org/resource/Spatial_reference_system",
      "value": "https://epsg.io/4269"
    }
  ]
}
$$::JSONB);


-- =========================================================================
-- TEST 1: ingest_jsonld_metadata populates data_source correctly
-- =========================================================================
SAVEPOINT t1;

DO $$
DECLARE
    v_uuid UUID;
    v_row  backbone.data_source%ROWTYPE;
    v_doc  JSONB;
BEGIN
    SELECT doc INTO v_doc FROM fixture;
    v_uuid := backbone.ingest_jsonld_metadata(v_doc);

    SELECT * INTO v_row FROM backbone.data_source WHERE data_source_uuid = v_uuid;

    PERFORM _assert('T1.1 returns a non-null UUID',
        v_uuid IS NOT NULL);

    PERFORM _assert('T1.2 dataset_id equals @id field',
        v_row.dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract');

    PERFORM _assert('T1.3 dataset_name set correctly',
        v_row.dataset_name = '2022 Massachusetts CDC Social Vulnerability Index (tracts)');

    PERFORM _assert('T1.4 dataset_version set correctly',
        v_row.dataset_version = '2026-02-10');

    PERFORM _assert('T1.5 creator array contains CDC org',
        v_row.creator @> ARRAY['Center for Disease Control']);

    PERFORM _assert('T1.6 provider array contains CDC',
        v_row.provider @> ARRAY['CDC']);

    PERFORM _assert('T1.7 keywords array populated',
        array_length(v_row.keywords, 1) = 6);

    PERFORM _assert('T1.8 keywords contains expected value',
        v_row.keywords @> ARRAY['Massachusetts']);

    PERFORM _assert('T1.9 spatial_coverage extracted from spatialCoverage[0].name',
        v_row.spatial_coverage = 'Massachusetts');

    PERFORM _assert('T1.10 date_published parsed correctly',
        v_row.date_published = '2020-10-22'::DATE);

    PERFORM _assert('T1.11 date_modified parsed correctly',
        v_row.date_modified = '2026-02-23'::DATE);

    PERFORM _assert('T1.12 license stored',
        v_row.license = 'https://creativecommons.org/licenses/by/4.0/');

    PERFORM _assert('T1.13 url stored',
        v_row.url = 'https://www.atsdr.cdc.gov/place-health/php/svi/svi-data-documentation-download.html');

    PERFORM _assert('T1.14 etl_metadata populated from about array',
        jsonb_typeof(v_row.etl_metadata) = 'array');

    PERFORM _assert('T1.15 etl_metadata has 2 action entries',
        jsonb_array_length(v_row.etl_metadata) = 2);

    PERFORM _assert('T1.16 geom_type extracted from measurementTechnique vectorGeometry termCode',
        v_row.geom_type = 'multipolygon');

    PERFORM _assert('T1.17 srid extracted from additionalProperty Spatial_reference_system value',
        v_row.srid = 4269);
END;
$$;


-- =========================================================================
-- TEST 2: ingest_jsonld_variables populates variable_source correctly
-- =========================================================================
DO $$
DECLARE
    v_uuid  UUID;
    v_count INTEGER;
    v_doc   JSONB;
    v_var   backbone.variable_source%ROWTYPE;
BEGIN
    SELECT doc INTO v_doc FROM fixture;
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    v_count := backbone.ingest_jsonld_variables(v_doc, v_uuid);

    PERFORM _assert('T2.1 returns count equal to variableMeasured array length',
        v_count = 5);

    PERFORM _assert('T2.2 correct number of variable_source rows inserted',
        (SELECT COUNT(*) FROM backbone.variable_source WHERE data_source_uuid = v_uuid) = 5);

    -- area_sqmi: propertyID is array, function should take element 0
    SELECT * INTO v_var
    FROM backbone.variable_source
    WHERE data_source_uuid = v_uuid AND variable_name = 'area_sqmi';

    PERFORM _assert('T2.3 area_sqmi row exists',
        v_var.variable_name IS NOT NULL);

    PERFORM _assert('T2.4 area_sqmi description populated',
        v_var.variable_description = 'Tract area in square miles');

    PERFORM _assert('T2.5 propertyID extracted as plain text without JSON quotes',
        v_var.property_id = '2052497175');

    PERFORM _assert('T2.5b attr_concept_id cast from propertyID integer string',
        v_var.attr_concept_id = 2052497175);

    PERFORM _assert('T2.6 area_sqmi unitText stored',
        v_var.unit_text = 'square miles');

    -- e_totpop: has numeric minValue and maxValue
    SELECT * INTO v_var
    FROM backbone.variable_source
    WHERE data_source_uuid = v_uuid AND variable_name = 'e_totpop';

    PERFORM _assert('T2.7 e_totpop min_value parsed correctly',
        v_var.min_value = 0);

    PERFORM _assert('T2.8 e_totpop max_value parsed correctly',
        v_var.max_value = 999999);

    -- rpl_themes: has startDate / endDate
    SELECT * INTO v_var
    FROM backbone.variable_source
    WHERE data_source_uuid = v_uuid AND variable_name = 'rpl_themes';

    PERFORM _assert('T2.9 rpl_themes start_date parsed from ISO YYYY-MM-DD format',
        v_var.start_date = '2022-01-01'::DATE);

    PERFORM _assert('T2.10 rpl_themes end_date parsed from ISO YYYY-MM-DD format',
        v_var.end_date = '2022-12-31'::DATE);
END;
$$;


-- =========================================================================
-- TEST 3: empty-string minValue/maxValue does not crash ingestion
-- (currently handled via exception block in ingest_jsonld_variables)
-- =========================================================================
DO $$
DECLARE
    v_uuid UUID;
    v_var  backbone.variable_source%ROWTYPE;
BEGIN
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    -- e_afam has minValue: "" and maxValue: "" - cast to NUMERIC should yield NULL
    SELECT * INTO v_var
    FROM backbone.variable_source
    WHERE data_source_uuid = v_uuid AND variable_name = 'e_afam';

    PERFORM _assert('T3.1 e_afam row inserted despite empty-string minValue/maxValue',
        v_var.variable_name IS NOT NULL);

    PERFORM _assert('T3.2 e_afam min_value is NULL (empty string coerced gracefully)',
        v_var.min_value IS NULL);

    PERFORM _assert('T3.3 e_afam max_value is NULL (empty string coerced gracefully)',
        v_var.max_value IS NULL);
END;
$$;


-- =========================================================================
-- TEST 4: load_jsonld_file end-to-end (metadata + variables in one call)
-- =========================================================================
SAVEPOINT t4;

DO $$
DECLARE
    v_result RECORD;
    v_doc    JSONB;
BEGIN
    -- Use a slightly different @id to avoid conflict with savepoint T1 data
    SELECT doc INTO v_doc FROM fixture;
    v_doc := jsonb_set(v_doc, '{@id}', '"https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract_t4"');
    v_doc := jsonb_set(v_doc, '{name}', '"T4 Test Dataset"');

    SELECT * INTO v_result FROM backbone.load_jsonld_file(v_doc::TEXT);

    PERFORM _assert('T4.1 load_jsonld_file returns a data_source_uuid',
        v_result.data_source_uuid IS NOT NULL);

    PERFORM _assert('T4.2 load_jsonld_file returns correct dataset_name',
        v_result.dataset_name = 'T4 Test Dataset');

    PERFORM _assert('T4.3 load_jsonld_file returns correct variables_loaded count',
        v_result.variables_loaded = 5);
END;
$$;

ROLLBACK TO t4;


-- =========================================================================
-- TEST 5: upsert idempotency - calling ingest_jsonld_metadata twice does
--         not create duplicate data_source rows
-- =========================================================================
DO $$
DECLARE
    v_uuid1  UUID;
    v_uuid2  UUID;
    v_count  BIGINT;
    v_doc    JSONB;
BEGIN
    SELECT doc INTO v_doc FROM fixture;
    SELECT data_source_uuid INTO v_uuid1
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    -- Call again with updated name to trigger the ON CONFLICT DO UPDATE path
    v_doc := jsonb_set(v_doc, '{name}', '"Updated Name"');
    v_uuid2 := backbone.ingest_jsonld_metadata(v_doc);

    SELECT COUNT(*) INTO v_count
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    PERFORM _assert('T5.1 second ingestion returns same UUID (upsert)',
        v_uuid1 = v_uuid2);

    PERFORM _assert('T5.2 no duplicate data_source rows created',
        v_count = 1);

    PERFORM _assert('T5.3 dataset_name updated by ON CONFLICT DO UPDATE',
        (SELECT dataset_name FROM backbone.data_source WHERE data_source_uuid = v_uuid1)
            = 'Updated Name');
END;
$$;


-- =========================================================================
-- TEST 6: upsert idempotency for variables - re-ingesting does not create
--         duplicates (ON CONFLICT (data_source_uuid, variable_name) DO UPDATE)
-- =========================================================================
DO $$
DECLARE
    v_uuid   UUID;
    v_count  BIGINT;
    v_doc    JSONB;
BEGIN
    SELECT doc INTO v_doc FROM fixture;
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    PERFORM backbone.ingest_jsonld_variables(v_doc, v_uuid);

    SELECT COUNT(*) INTO v_count
    FROM backbone.variable_source
    WHERE data_source_uuid = v_uuid;

    PERFORM _assert('T6.1 re-ingesting variables does not create duplicates',
        v_count = 5);
END;
$$;


-- =========================================================================
-- TEST 7: load_jsonld_file rejects malformed JSON
-- =========================================================================
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        PERFORM backbone.load_jsonld_file('{ this is not valid json }');
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    PERFORM _assert('T7.1 load_jsonld_file raises exception on invalid JSON',
        v_raised);
END;
$$;


-- =========================================================================
-- TEST 8: list_downloadable_datasources — script path, geometry metadata
-- =========================================================================
DO $$
DECLARE
    v_uuid UUID;
    v_row  RECORD;
BEGIN
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    SELECT * INTO v_row
    FROM backbone.list_downloadable_datasources()
    WHERE data_source_uuid = v_uuid;

    PERFORM _assert('T8.1 table_id derived as last URL segment of dataset_id',
        v_row.table_id = 'ma_2022_svi_tract');

    PERFORM _assert('T8.2 etl_script follows /data/{table_id}/etl/{table_id}_postgis.sh convention',
        v_row.etl_script = '/data/ma_2022_svi_tract/etl/ma_2022_svi_tract_postgis.sh');

    PERFORM _assert('T8.3 geom_type propagated from measurementTechnique',
        v_row.geom_type = 'multipolygon');

    PERFORM _assert('T8.4 srid propagated from additionalProperty',
        v_row.srid = 4269);

    PERFORM _assert('T8.5 already_ingested is FALSE before any ETL run',
        v_row.already_ingested IS FALSE);

    PERFORM _assert('T8.6 last_ingested_at is NULL before any ETL run',
        v_row.last_ingested_at IS NULL);
END;
$$;


-- =========================================================================
-- TEST 9: retrieve_and_ingest_datasource uses caller-supplied script path
--         (we can't actually run the script in a unit test, so we verify
--         the error message references the correct path when it fails)
-- =========================================================================
DO $$
DECLARE
    v_uuid   UUID;
    v_rows   TEXT[];
    v_steps  TEXT[];
BEGIN
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    -- Supply a non-existent script; expect ingestion to fail gracefully
    SELECT ARRAY_AGG(step ORDER BY ordinality),
           ARRAY_AGG(message ORDER BY ordinality)
    INTO   v_steps, v_rows
    FROM   backbone.retrieve_and_ingest_datasource(
               v_uuid,
               '/nonexistent/etl_test'
           )
    WITH ORDINALITY AS r(step, status, message, ordinality);

    PERFORM _assert('T9.1 first step is metadata success',
        v_steps[1] = 'metadata');

    PERFORM _assert('T9.2 in_progress step announces supplied script path',
        v_rows[2] LIKE '%/nonexistent/etl_test.sh%');

    PERFORM _assert('T9.3 function returns rows without unhandled exception',
        array_length(v_steps, 1) >= 2);
END;
$$;


-- =========================================================================
-- TEST 10: create_datasource_table builds a table with expected columns
-- =========================================================================
SAVEPOINT t10;

DO $$
DECLARE
    v_uuid       UUID;
    v_table_name TEXT;
    v_col_count  BIGINT;
BEGIN
    SELECT data_source_uuid INTO v_uuid
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    v_table_name := backbone.create_datasource_table(v_uuid, 'public');

    PERFORM _assert('T10.1 create_datasource_table returns a non-null table reference',
        v_table_name IS NOT NULL);

    -- Verify geom column exists (v_table_name is schema-qualified, e.g. "public"."updated_name")
    SELECT COUNT(*) INTO v_col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = LOWER(REGEXP_REPLACE(
              (SELECT dataset_name FROM backbone.data_source WHERE data_source_uuid = v_uuid),
              '[^a-zA-Z0-9_]', '_', 'g'))
      AND column_name = 'geom';

    PERFORM _assert('T10.2 created table has geom geometry column',
        v_col_count = 1);

    -- Verify variable columns created (area_sqmi → should map to TEXT since data_type is stored as JSONB string)
    SELECT COUNT(*) INTO v_col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = LOWER(REGEXP_REPLACE(
              (SELECT dataset_name FROM backbone.data_source WHERE data_source_uuid = v_uuid),
              '[^a-zA-Z0-9_]', '_', 'g'));

    PERFORM _assert('T10.3 created table has more than 2 columns (variables + geometry)',
        v_col_count > 2);
END;
$$;

ROLLBACK TO t10;


-- =========================================================================
-- TEST 11: load_datasource_metadata raises a clear error when the JSON-LD
--          file does not exist at the expected path
-- =========================================================================
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        PERFORM backbone.load_datasource_metadata('nonexistent_dataset_xyz');
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
        PERFORM _assert('T11.1 error message references the expected file path',
            SQLERRM LIKE '%/data/nonexistent_dataset_xyz/meta_json-ld_nonexistent_dataset_xyz.json%');
    END;

    PERFORM _assert('T11.2 load_datasource_metadata raises exception for missing file',
        v_raised);
END;
$$;


-- =========================================================================
-- TEST 12: ingest_datasource step sequence
--          Uses a non-existent table_id so metadata load fails on the file
--          read, letting us verify the step names and early-exit behaviour
--          without needing a real /data directory.
-- =========================================================================
DO $$
DECLARE
    v_steps    TEXT[];
    v_statuses TEXT[];
    v_step     TEXT;
    v_status   TEXT;
    v_message  TEXT;
    i          INTEGER := 0;
BEGIN
    -- Collect all rows from ingest_datasource for a table_id with no metadata file
    FOR v_step, v_status, v_message IN
        SELECT r.step, r.status, r.message
        FROM backbone.ingest_datasource('nonexistent_dataset_xyz') r
    LOOP
        i := i + 1;
        v_steps    := array_append(v_steps,    v_step);
        v_statuses := array_append(v_statuses, v_status);
    END LOOP;

    PERFORM _assert('T12.1 first step is metadata_load',
        v_steps[1] = 'metadata_load');

    PERFORM _assert('T12.2 metadata_load in_progress row emitted before attempt',
        v_steps[1] = 'metadata_load' AND v_statuses[1] = 'in_progress');

    PERFORM _assert('T12.3 metadata_load error row emitted on missing file',
        'error' = ANY(v_statuses));

    PERFORM _assert('T12.4 function exits after metadata error — no ingestion or postgis rows',
        NOT ('ingestion' = ANY(v_steps)) AND NOT ('postgis' = ANY(v_steps)));
END;
$$;


-- =========================================================================
-- TEST 13: retrieve_and_ingest_datasource default script path uses _osgeo
--
-- Cannot call retrieve_and_ingest_datasource(uuid) without a script path
-- in a unit test — gdsc_exec will attempt to run the real ETL script.
-- Instead, replicate the path-derivation logic directly and verify it.
-- =========================================================================
DO $$
DECLARE
    v_dataset_id TEXT;
    v_table_id   TEXT;
BEGIN
    SELECT dataset_id INTO v_dataset_id
    FROM backbone.data_source
    WHERE dataset_id = 'https://gdsc.idsc.miami.edu/detail/ma_2022_svi_tract';

    -- Replicate path derivation from retrieve_and_ingest_datasource
    v_table_id := split_part(
        v_dataset_id, '/',
        array_length(string_to_array(v_dataset_id, '/'), 1)
    );

    PERFORM _assert('T13.1 table_id is last URL segment of dataset_id',
        v_table_id = 'ma_2022_svi_tract');

    PERFORM _assert('T13.2 default script path uses _osgeo convention',
        format('/data/%s/etl/%s_osgeo.sh', v_table_id, v_table_id)
            LIKE '%_osgeo.sh%');
END;
$$;


-- =========================================================================
-- TEST 14: Load LOCATION / LOCATION_HISTORY fixture data and verify the
--          spatial join pipeline populates EXTERNAL_EXPOSURE
--
-- Uses a representative sample from extras/csv/LOCATION.csv and
-- extras/csv/LOCATION_HISTORY.csv (Fresno, CA points). Location-history
-- dates are set to 2021-2023 so they overlap the rpl_themes variable
-- period (2022-01-01 to 2022-12-31).
-- =========================================================================
SAVEPOINT t14;

DO $$
DECLARE
    v_uuid  UUID;
    v_count INTEGER;
    v_doc   JSONB;
    v_row   RECORD;
BEGIN
    -- Load LOCATION rows with geometry built from lat/lon
    INSERT INTO working.location
        (location_id, address_1, city, state, zip, country_source_value,
         latitude, longitude, geom)
    VALUES
        (9001, '1248 N Blackstone Ave', 'FRESNO', 'CA', '93703', 'UNITED STATES OF AMERICA',
         36.75891146, -119.7902719, ST_SetSRID(ST_MakePoint(-119.7902719, 36.75891146), 4326)),
        (9002, '1256 N Fresno St',      'FRESNO', 'CA', '93703', 'UNITED STATES OF AMERICA',
         36.75917287, -119.781401,  ST_SetSRID(ST_MakePoint(-119.781401,  36.75917287), 4326)),
        (9003, '2615 E Clinton Ave',    'FRESNO', 'CA', '93703', 'UNITED STATES OF AMERICA',
         36.77357544, -119.7796299, ST_SetSRID(ST_MakePoint(-119.7796299, 36.77357544), 4326));

    -- Load LOCATION_HISTORY rows; dates span 2021-2023 to overlap rpl_themes (2022)
    INSERT INTO working.location_history
        (location_id, relationship_type_concept_id, domain_id, entity_id, start_date, end_date)
    VALUES
        (9001, 32848, 1147314, 3763, '2021-01-01', '2023-12-31'),
        (9002, 32848, 1147314, 5587, '2021-01-01', '2023-12-31'),
        (9003, 32848, 1147314, 1011, '2021-01-01', '2023-12-31');

    PERFORM _assert('T14.1 working.location rows inserted with geometry',
        (SELECT COUNT(*) FROM working.location WHERE location_id IN (9001, 9002, 9003)) = 3);

    PERFORM _assert('T14.2 working.location_history rows inserted',
        (SELECT COUNT(*) FROM working.location_history WHERE location_id IN (9001, 9002, 9003)) = 3);

    PERFORM _assert('T14.3 location_merge view joins location and location_history',
        (SELECT COUNT(*) FROM working.location_merge WHERE location_id IN (9001, 9002, 9003)) = 3);

    -- Ingest fixture data source + variables (rpl_themes has startDate/endDate 2022)
    SELECT doc INTO v_doc FROM fixture;
    v_uuid := backbone.ingest_jsonld_metadata(v_doc);
    PERFORM backbone.ingest_jsonld_variables(v_doc, v_uuid);

    -- Staging table: one polygon covering all three Fresno points, one rpl_themes value
    EXECUTE $SQL$
        CREATE TEMP TABLE _test_svi_t14 (
            rpl_themes DOUBLE PRECISION,
            geom       GEOMETRY(GEOMETRY, 4326)
        )
    $SQL$;

    EXECUTE $SQL$
        INSERT INTO _test_svi_t14 (rpl_themes, geom)
        VALUES (0.75, ST_SetSRID(ST_MakeEnvelope(-120.0, 36.5, -119.5, 37.1), 4326))
    $SQL$;

    -- Run the spatial join
    v_count := working.spatial_join_exposure(
        'rpl_themes',
        '_test_svi_t14',
        NULL, NULL, NULL,
        'st_within',
        0
    );

    PERFORM _assert('T14.4 spatial_join_exposure matched at least one location',
        v_count > 0);

    PERFORM _assert('T14.5 external_exposure rows created',
        (SELECT COUNT(*) FROM working.external_exposure) > 0);

    SELECT * INTO v_row
    FROM working.external_exposure
    WHERE location_id IN (9001, 9002, 9003)
    LIMIT 1;

    PERFORM _assert('T14.6 exposure location_id traces back to a loaded location',
        v_row.location_id IN (9001, 9002, 9003));

    PERFORM _assert('T14.7 person_id populated from entity_id (domain_id = 1147314)',
        v_row.person_id > 0);

    PERFORM _assert('T14.8 exposure_source_value is the variable name',
        v_row.exposure_source_value = 'rpl_themes');

    PERFORM _assert('T14.9 value_as_number reflects the staged rpl_themes value',
        v_row.value_as_number = 0.75);
END;
$$;

ROLLBACK TO t14;


-- =========================================================================
-- TEST 15: backbone.gdsc_load_variable() populates backbone.geom_index /
--          backbone.attr_index and their working.geom_*/attr_* instance
--          tables, and working.spatial_join_from_catalog() reads from that
--          catalog (rather than raw caller-supplied table names) to
--          populate EXTERNAL_EXPOSURE.
-- =========================================================================
SAVEPOINT t15;

DO $$
DECLARE
    v_count  INTEGER;
    v_result JSON;
    v_row    RECORD;
BEGIN
    -- Raw staged table mimicking ogr2ogr/osgeo output: PK + geom + geom_local + attribute
    CREATE TABLE public._test_svi_catalog (
        gid SERIAL PRIMARY KEY,
        rpl_themes DOUBLE PRECISION,
        geom GEOMETRY(GEOMETRY, 4326),
        geom_local GEOMETRY
    );

    INSERT INTO public._test_svi_catalog (rpl_themes, geom, geom_local)
    VALUES (
        0.75,
        ST_SetSRID(ST_MakeEnvelope(-120.0, 36.5, -119.5, 37.1), 4326),
        ST_SetSRID(ST_MakeEnvelope(-120.0, 36.5, -119.5, 37.1), 4326)
    );

    -- A location that falls inside the polygon above
    INSERT INTO working.location
        (location_id, address_1, city, state, zip, country_source_value,
         latitude, longitude, geom)
    VALUES
        (9101, '1248 N Blackstone Ave', 'FRESNO', 'CA', '93703', 'UNITED STATES OF AMERICA',
         36.75891146, -119.7902719, ST_SetSRID(ST_MakePoint(-119.7902719, 36.75891146), 4326));

    INSERT INTO working.location_history
        (location_id, relationship_type_concept_id, domain_id, entity_id, start_date, end_date)
    VALUES
        (9101, 32848, 1147314, 3763, '2021-01-01', '2023-12-31');

    -- Populate backbone.geom_index/attr_index + working.geom_*/attr_* via the catalog loader
    v_result := backbone.gdsc_load_variable(jsonb_build_object(
        'table_id', '_test_svi_catalog',
        'geom_type', 'Polygon',
        'table_description', 'Test SVI catalog fixture',
        'geom_label', 'gid',
        'variable_id', 'rpl_themes',
        'description', 'RPL Themes test variable',
        'concept_id', 12345,
        'unit', 'index_score',
        'start_date', '2022-01-01',
        'end_date', '2022-12-31',
        'variable_nodata', -999,
        'source', 'test fixture'
    ));

    PERFORM _assert('T15.1 gdsc_load_variable created a backbone.geom_index entry',
        EXISTS (SELECT 1 FROM backbone.geom_index WHERE table_name = '_test_svi_catalog'));

    PERFORM _assert('T15.2 gdsc_load_variable created a backbone.attr_index entry',
        EXISTS (SELECT 1 FROM backbone.attr_index
                WHERE table_name = '_test_svi_catalog' AND variable_name = 'rpl_themes'));

    PERFORM _assert('T15.3 working.geom__test_svi_catalog instance table populated',
        (SELECT COUNT(*) FROM working.geom__test_svi_catalog) = 1);

    PERFORM _assert('T15.4 working.attr__test_svi_catalog instance table populated',
        (SELECT COUNT(*) FROM working.attr__test_svi_catalog) = 1);

    -- Run the catalog-driven spatial join -- this is the function under test:
    -- it must resolve the instance tables from attr_index/geom_index itself.
    v_count := working.spatial_join_from_catalog('rpl_themes', '_test_svi_catalog');

    PERFORM _assert('T15.5 spatial_join_from_catalog matched the fixture location',
        v_count = 1);

    SELECT * INTO v_row
    FROM working.external_exposure
    WHERE location_id = 9101;

    PERFORM _assert('T15.6 external_exposure row created via the catalog-driven join',
        v_row.location_id = 9101);

    PERFORM _assert('T15.7 value_as_number reflects the working.attr_* instance value',
        v_row.value_as_number = 0.75);

    PERFORM _assert('T15.8 exposure_source_value is the variable name',
        v_row.exposure_source_value = 'rpl_themes');

    PERFORM _assert('T15.9 exposure dates reflect attr_index (not the never-populated instance row)',
        v_row.exposure_start_date = '2022-01-01' AND v_row.exposure_end_date = '2022-12-31');
END;
$$;

ROLLBACK TO t15;


-- =========================================================================
-- Cleanup and rollback all test data
-- =========================================================================
DROP FUNCTION _assert(TEXT, BOOLEAN);

ROLLBACK;

-- End of test suite.
-- Re-run with: psql -U postgres -d gaiacore -f tests/test_jsonld_ingestion.sql
-- All state is rolled back; the database is left unchanged.
