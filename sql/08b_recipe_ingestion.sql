-- Recipe ingestion (draft recipe profile v0.1)
--
-- A recipe is one JSON-LD document that states what a dataset is and how to load it (see
-- schema/gaia_recipe_v0_1.yaml in OHDSI/gaiaCatalog). These functions fill the same backbone tables as the
-- flat JSON-LD functions of 02_jsonld_ingestion_functions.sql (data_source, variable_source, geom_index,
-- attr_index), from the recipe alone:
--
--   * the validity period is declared (gaia:validity), never inferred from a name or a coverage;
--   * a variable's role decides whether it is registered for loading (a measure is; identifiers and names are not);
--   * the nodata value, the feature label column and the retrieval/derivation settings are read from the recipe
--     (the first two used to be typed at load time).
--
-- Scope: metadata only. Loading values (gdsc_load_*) and running the ETL still use the existing functions and the
-- meta_etl file. The recipe parts a loader needs are kept in data_source.etl_metadata for that follow-up.
--
-- load_jsonld_file() calls these when the document declares the profile, so every existing entry point
-- (load_datasource_metadata, ingest_datasource, ...) accepts a recipe unchanged.

-- ---------------------------------------------------------------------------
-- backbone.is_recipe
-- TRUE when the document declares conformance to the recipe profile this file reads (0.1).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.is_recipe(p_doc JSONB)
RETURNS BOOLEAN AS $$
    SELECT COALESCE(
        (SELECT bool_or(c->>'@id' = 'https://w3id.org/ohdsi/gaia/recipe/0.1')
         FROM jsonb_array_elements(
                CASE WHEN jsonb_typeof(p_doc->'schema:subjectOf'->'dcterms:conformsTo') = 'array'
                     THEN p_doc->'schema:subjectOf'->'dcterms:conformsTo' ELSE '[]'::jsonb END) c),
        FALSE);
$$ LANGUAGE sql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.recipe_validity
-- The period of a gaia:validity object as (start, end): a period gives its first and last day, static gives the
-- static period (1900-01-01 to 2100-12-31, as for an undated raster or a geometry-only source). NULL, NULL when
-- the object is absent or unreadable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.recipe_validity(p_validity JSONB, OUT start_date DATE, OUT end_date DATE) AS $$
BEGIN
    IF p_validity IS NULL OR jsonb_typeof(p_validity) <> 'object' THEN
        RETURN;
    ELSIF lower(COALESCE(p_validity->>'gaia:static', '')) = 'true' THEN
        start_date := DATE '1900-01-01';
        end_date   := DATE '2100-12-31';
    ELSE
        start_date := backbone.parse_partial_date(p_validity->>'gaia:start', FALSE);
        end_date   := backbone.parse_partial_date(p_validity->>'gaia:end', TRUE);
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.recipe_concept_id
-- The OMOP concept id of a variable: the number at the end of an Athena concept URI
-- (https://athena.ohdsi.org/search-terms/terms/2052499839), or a bare integer (accepted while recipes migrate).
-- NULL when there is none.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.recipe_concept_id(p_variable JSONB)
RETURNS INTEGER AS $$
DECLARE
    v_first JSONB := p_variable->'schema:propertyID'->0;
    v_text  TEXT;
BEGIN
    IF v_first IS NULL THEN
        RETURN NULL;
    END IF;
    v_text := CASE WHEN jsonb_typeof(v_first) = 'object' THEN v_first->>'@id' ELSE v_first #>> '{}' END;
    IF v_text ~ '^[0-9]+$' THEN
        RETURN v_text::INTEGER;
    END IF;
    RETURN substring(v_text from '^https?://athena\.ohdsi\.org/search-terms/terms/([0-9]+)$')::INTEGER;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.recipe_data_type
-- The data_type text the loader functions know (variable_source.data_type) for a recipe's physical type.
-- Raster value types are mapped to the Postgres name of the same width.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.recipe_data_type(p_type TEXT)
RETURNS TEXT AS $$
    SELECT CASE lower(p_type)
        WHEN 'float32' THEN 'float4'
        WHEN 'uint8'   THEN 'int2'
        WHEN 'int16'   THEN 'int2'
        WHEN 'uint16'  THEN 'int4'
        ELSE lower(p_type)
    END;
$$ LANGUAGE sql IMMUTABLE;


-- ---------------------------------------------------------------------------
-- backbone.ingest_recipe_metadata
-- Fills backbone.data_source from a recipe and returns its UUID.
-- The table id is the recipe's schema:identifier value; dataset_id is the recipe @id, whose last segment is
-- the same id (the convention the other functions use to find the table).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.ingest_recipe_metadata(p_doc JSONB)
RETURNS UUID AS $$
DECLARE
    v_uuid       UUID;
    v_table_id   TEXT := p_doc->'schema:identifier'->>'schema:value';
    v_dataset_id TEXT := p_doc->>'@id';
    v_rep        TEXT := p_doc->>'gaia:representation';
    v_geom_type  TEXT;
    v_srid       INTEGER;
    v_start      DATE;
    v_end        DATE;
    v_technique  JSONB;
BEGIN
    IF NOT backbone.is_recipe(p_doc) THEN
        RAISE EXCEPTION 'not a recipe: schema:subjectOf/dcterms:conformsTo must include https://w3id.org/ohdsi/gaia/recipe/0.1';
    END IF;
    IF v_table_id IS NULL OR v_table_id !~ '^[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'recipe has no valid schema:identifier value (the table id), got %', v_table_id;
    END IF;
    IF v_dataset_id IS NULL OR split_part(v_dataset_id, '/', array_length(string_to_array(v_dataset_id, '/'), 1)) <> v_table_id THEN
        RAISE EXCEPTION 'recipe @id (%) must end with the table id (%)', v_dataset_id, v_table_id;
    END IF;
    IF v_rep NOT IN ('vector', 'raster', 'table') THEN
        RAISE EXCEPTION 'recipe % has no valid gaia:representation (%)', v_table_id, v_rep;
    END IF;
    SELECT s.start_date, s.end_date INTO v_start, v_end FROM backbone.recipe_validity(p_doc->'gaia:validity') s;
    IF v_start IS NULL OR v_end IS NULL THEN
        RAISE EXCEPTION 'recipe % must declare gaia:validity (a period or static); it is not inferred', v_table_id;
    END IF;

    -- geom_type as the flat entries give it: the geometry of a vector, a table's target geometry, else a label
    v_geom_type := CASE v_rep
        WHEN 'vector' THEN p_doc->>'gaia:geometryType'
        WHEN 'raster' THEN 'Raster Dataset'
        ELSE COALESCE(
            (SELECT ds.geom_type FROM backbone.data_source ds
             WHERE ds.dataset_id LIKE '%/' || (p_doc->'gaia:joinsTo'->>'gaia:table')
             LIMIT 1),
            'Table Dataset')
    END;

    v_srid := COALESCE(
        substring(p_doc->'geosparql:crs'->>'@id' from '/EPSG/0/([0-9]+)$')::INTEGER,
        (SELECT ds.srid FROM backbone.data_source ds
         WHERE ds.dataset_id LIKE '%/' || (p_doc->'gaia:joinsTo'->>'gaia:table') LIMIT 1),
        4326);

    -- the legacy measurementTechnique terms, so datasource_structure() and the raster registration work as before
    v_technique := jsonb_build_array(jsonb_build_object(
        'termCode', v_rep, 'inDefinedTermSet', jsonb_build_object('name', 'dataRepresentation')));
    IF v_rep = 'vector' THEN
        v_technique := v_technique || jsonb_build_array(jsonb_build_object(
            'termCode', p_doc->>'gaia:geometryType', 'inDefinedTermSet', jsonb_build_object('name', 'vectorGeometry')));
    END IF;

    INSERT INTO backbone.data_source (
        dataset_id, dataset_name, dataset_version, description, license,
        measurement_technique, additional_properties, geom_type, srid, etl_metadata
    ) VALUES (
        v_dataset_id,
        p_doc->>'schema:name',
        p_doc->>'schema:version',
        p_doc->>'schema:description',
        p_doc->'schema:license'->>0,
        v_technique,
        NULL,
        v_geom_type,
        v_srid,
        -- what a loader needs from the recipe, in one place (see the scope note at the top of this file)
        jsonb_strip_nulls(jsonb_build_object(
            'recipe_profile',   'https://w3id.org/ohdsi/gaia/recipe/0.1',
            'representation',   v_rep,
            'geometry_type',    p_doc->'gaia:geometryType',
            'label_column',     p_doc->'gaia:labelColumn',
            'joins_to',         p_doc->'gaia:joinsTo',
            'validity',         p_doc->'gaia:validity',
            'update_frequency', p_doc->'gaia:updateFrequency',
            'files',            p_doc->'gaia:files',
            'retrieval',        p_doc->'gaia:retrieval',
            'derivation',       p_doc->'gaia:derivation'))
    )
    ON CONFLICT (dataset_id) DO UPDATE SET
        dataset_name          = EXCLUDED.dataset_name,
        dataset_version       = EXCLUDED.dataset_version,
        description           = EXCLUDED.description,
        license               = EXCLUDED.license,
        measurement_technique = EXCLUDED.measurement_technique,
        geom_type             = EXCLUDED.geom_type,
        srid                  = EXCLUDED.srid,
        etl_metadata          = EXCLUDED.etl_metadata,
        updated_at            = NOW()
    RETURNING data_source_uuid INTO v_uuid;

    RAISE NOTICE 'Ingested recipe: % (UUID: %)', p_doc->>'schema:name', v_uuid;
    RETURN v_uuid;
END;
$$ LANGUAGE plpgsql;


-- ---------------------------------------------------------------------------
-- backbone.ingest_recipe_variables
-- Fills backbone.variable_source for every variable of the recipe, registers the geom_index row of the table,
-- and an attr_index row for each variable that is to be loaded as a value: a Measure, or an Attribute of a numeric
-- or jsonb type. Identifiers, descriptors and other attributes stay in variable_source only, so
-- gdsc_load_all_variables never tries to load an id column as a value.
-- A variable's period is its own gaia:validity, else the dataset's. Returns the number of variables.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION backbone.ingest_recipe_variables(p_doc JSONB, p_data_source_uuid UUID)
RETURNS INTEGER AS $$
DECLARE
    v_var          JSONB;
    v_count        INTEGER := 0;
    v_table_id     TEXT := p_doc->'schema:identifier'->>'schema:value';
    v_geom_type    TEXT;
    v_geom_index   INTEGER;
    v_ds_start     DATE;
    v_ds_end       DATE;
    v_start        DATE;
    v_end          DATE;
    v_type         TEXT;
    v_concept      INTEGER;
    v_role         TEXT;
    v_numeric      BOOLEAN;
    v_nodata       NUMERIC;
    v_vs_id        INTEGER;
BEGIN
    SELECT ds.geom_type INTO v_geom_type FROM backbone.data_source ds WHERE ds.data_source_uuid = p_data_source_uuid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'data_source_uuid % not found in backbone.data_source (run ingest_recipe_metadata first)', p_data_source_uuid;
    END IF;
    SELECT s.start_date, s.end_date INTO v_ds_start, v_ds_end FROM backbone.recipe_validity(p_doc->'gaia:validity') s;

    SELECT geom_index_id INTO v_geom_index FROM backbone.geom_index WHERE table_name = v_table_id;
    IF NOT FOUND THEN
        INSERT INTO backbone.geom_index (geom_type_source_value, table_name, table_desc, database_schema)
        VALUES (COALESCE(v_geom_type, 'Unknown'), v_table_id, COALESCE(p_doc->>'schema:name', v_table_id), 'working')
        RETURNING geom_index_id INTO v_geom_index;
    END IF;

    FOR v_var IN SELECT * FROM jsonb_array_elements(p_doc->'schema:variableMeasured')
    LOOP
        v_type    := backbone.recipe_data_type(v_var->>'cdif:physicalDataType');
        v_concept := backbone.recipe_concept_id(v_var);
        v_role    := v_var->>'cdif:role';
        v_numeric := v_type IN ('float4', 'float8', 'numeric', 'int2', 'int4', 'int8');

        IF v_var ? 'gaia:validity' THEN
            SELECT s.start_date, s.end_date INTO v_start, v_end FROM backbone.recipe_validity(v_var->'gaia:validity') s;
        ELSE
            v_start := v_ds_start; v_end := v_ds_end;
        END IF;

        INSERT INTO backbone.variable_source (
            data_source_uuid, variable_name, variable_description, property_id, data_type,
            unit_code, min_value, max_value, start_date, end_date, attr_concept_id
        ) VALUES (
            p_data_source_uuid,
            v_var->>'schema:name',
            v_var->>'schema:description',
            COALESCE(v_var->'schema:propertyID'->0->>'@id', v_var->'schema:propertyID'->>0),
            v_type,
            v_var->>'schema:unitCode',
            NULLIF(v_var->>'schema:minValue', '')::NUMERIC,
            NULLIF(v_var->>'schema:maxValue', '')::NUMERIC,
            v_start, v_end, v_concept
        )
        ON CONFLICT (data_source_uuid, variable_name) DO UPDATE SET
            variable_description = EXCLUDED.variable_description,
            property_id          = EXCLUDED.property_id,
            data_type            = EXCLUDED.data_type,
            unit_code            = EXCLUDED.unit_code,
            min_value            = EXCLUDED.min_value,
            max_value            = EXCLUDED.max_value,
            start_date           = EXCLUDED.start_date,
            end_date             = EXCLUDED.end_date,
            attr_concept_id      = EXCLUDED.attr_concept_id
        RETURNING variable_source_id INTO v_vs_id;

        IF v_role = 'Measure' OR (v_role = 'Attribute' AND (v_numeric OR v_type IN ('jsonb', 'json'))) THEN
            v_nodata := CASE WHEN jsonb_typeof(v_var->'cdi:nullSequence') = 'number'
                             THEN (v_var->>'cdi:nullSequence')::NUMERIC END;
            IF NOT EXISTS (SELECT 1 FROM backbone.attr_index WHERE table_name = v_table_id AND variable_name = v_var->>'schema:name') THEN
                INSERT INTO backbone.attr_index (
                    geom_index_id, variable_source_id, table_name, variable_name, variable_desc,
                    attr_concept_id, unit_source_value, attr_start_date, attr_end_date,
                    attr_no_value_as_number, attr_source_value, database_schema
                ) VALUES (
                    v_geom_index, v_vs_id, v_table_id, v_var->>'schema:name',
                    COALESCE(v_var->>'schema:description', v_var->>'schema:name'),
                    v_concept, v_var->>'schema:unitCode', v_start, v_end,
                    v_nodata, v_var->>'schema:name', 'working'
                );
            ELSE
                UPDATE backbone.attr_index
                SET variable_source_id = v_vs_id, attr_start_date = v_start, attr_end_date = v_end,
                    attr_no_value_as_number = v_nodata, attr_concept_id = v_concept
                WHERE table_name = v_table_id AND variable_name = v_var->>'schema:name';
            END IF;
        END IF;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION backbone.ingest_recipe_metadata IS 'Fill backbone.data_source from a recipe (profile v0.1): the validity is declared, not inferred.';
COMMENT ON FUNCTION backbone.ingest_recipe_variables IS 'Fill variable_source, geom_index and attr_index from a recipe; only measures (and numeric or jsonb attributes) are registered for loading.';
