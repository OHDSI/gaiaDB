-- gaiaCore Database Initialization
-- Creates schemas, extensions, base tables, vocabulary tables, and loads functions

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS plsh;

-- Create schemas
CREATE SCHEMA IF NOT EXISTS backbone;
CREATE SCHEMA IF NOT EXISTS public;
CREATE SCHEMA IF NOT EXISTS working;
CREATE SCHEMA IF NOT EXISTS vocabulary;

SET search_path = backbone, public;

-- Grant permissions
GRANT USAGE ON SCHEMA backbone TO PUBLIC;
GRANT USAGE ON SCHEMA working TO PUBLIC;

-- * - * - * - * - * - * - * - * - * -
-- BACKBONE SCHEMA
-- * - * - * - * - * - * - * - * - * -

CREATE SEQUENCE IF NOT EXISTS backbone.variable_source_variable_source_id_seq
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    START 1
    CACHE 1
    NO CYCLE;

CREATE SEQUENCE IF NOT EXISTS backbone.attr_template_attr_record_id_seq
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    START 1
    CACHE 1
    NO CYCLE;

CREATE SEQUENCE IF NOT EXISTS backbone.geom_template_geom_record_id_seq
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    START 1
    CACHE 1
    NO CYCLE;

CREATE TABLE IF NOT EXISTS backbone.data_source (
    data_source_uuid UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    dataset_id TEXT NOT NULL UNIQUE,
    dataset_name TEXT NOT NULL,
    dataset_version TEXT,
    description TEXT,
    creator TEXT[],
    provider TEXT[],
    license TEXT,
    spatial_coverage TEXT,
    date_published DATE,
    date_modified DATE,
    keywords TEXT[],
    url TEXT,
    measurement_technique JSONB,
    additional_properties JSONB,
    geom_type TEXT,
    srid INTEGER DEFAULT 4326,
    etl_metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS backbone.variable_source (
    variable_source_id SERIAL PRIMARY KEY,
    data_source_uuid UUID REFERENCES backbone.data_source(data_source_uuid),
    variable_name TEXT NOT NULL,
    variable_description TEXT,
    property_id TEXT,
    data_type TEXT,
    unit_code TEXT,
    unit_text TEXT,
    min_value NUMERIC,
    max_value NUMERIC,
    start_date DATE,
    end_date DATE,
    attr_concept_id INTEGER,
    value_as_concept_id INTEGER,
    unit_concept_id INTEGER,
    attr_start_date DATE,
    attr_end_date DATE,
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(data_source_uuid, variable_name)
);

CREATE TABLE IF NOT EXISTS backbone.geom_template (
    geom_record_id SERIAL PRIMARY KEY,
    data_source_uuid UUID REFERENCES backbone.data_source(data_source_uuid),
    geom_name TEXT,
    geom_source_coding TEXT,
    geom_source_value TEXT,
    geom_wgs84 GEOMETRY(GEOMETRY, 4326),
    geom_local_epsg INTEGER,
    geom_local_value GEOMETRY,
    properties JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_geom_template_wgs84
    ON backbone.geom_template USING GIST(geom_wgs84);

CREATE TABLE IF NOT EXISTS backbone.attr_template (
    attr_record_id SERIAL PRIMARY KEY,
    geom_record_id INTEGER REFERENCES backbone.geom_template(geom_record_id),
    variable_source_id INTEGER REFERENCES backbone.variable_source(variable_source_id),
    attr_concept_id INTEGER,
    attr_start_date DATE NOT NULL,
    attr_end_date DATE NOT NULL,
    value_as_number DOUBLE PRECISION,
    value_as_string TEXT,
    value_as_concept_id INTEGER,
    unit_concept_id INTEGER,
    unit_source_value TEXT,
    qualifier_concept_id INTEGER,
    qualifier_source_value TEXT,
    attr_source_concept_id INTEGER,
    attr_source_value TEXT NOT NULL,
    value_source_value TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- * - * - * - * - * - * - * - * - * -
-- WORKING SCHEMA
-- * - * - * - * - * - * - * - * - * -

CREATE TABLE IF NOT EXISTS working.location (
    location_id SERIAL PRIMARY KEY,
    address_1 TEXT,
    address_2 TEXT,
    city TEXT,
    state TEXT,
    zip TEXT,
    county TEXT,
    location_source_value TEXT,
    country_concept_id INTEGER,
    country_source_value TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    geom GEOMETRY(POINT, 4326),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_location_geom
    ON working.location USING GIST(geom);

CREATE TABLE IF NOT EXISTS working.location_history (
    location_history_id SERIAL PRIMARY KEY,
    location_id INTEGER REFERENCES working.location(location_id),
    relationship_type_concept_id INTEGER,
    domain_id INTEGER,
    entity_id INTEGER,
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE OR REPLACE VIEW working.location_merge AS
SELECT
    lh.location_history_id,
    lh.location_id,
    lh.relationship_type_concept_id,
    lh.domain_id,
    lh.entity_id,
    lh.start_date,
    lh.end_date,
    l.geom,
    l.latitude,
    l.longitude,
    l.address_1,
    l.city,
    l.state,
    l.zip
FROM working.location_history lh
INNER JOIN working.location l ON lh.location_id = l.location_id;

CREATE TABLE IF NOT EXISTS working.external_exposure (
    external_exposure_id SERIAL PRIMARY KEY,
    location_id INTEGER,
    person_id INTEGER,
    exposure_concept_id INTEGER,
    exposure_start_date DATE,
    exposure_start_datetime TIMESTAMP,
    exposure_end_date DATE,
    exposure_end_datetime TIMESTAMP,
    exposure_type_concept_id INTEGER,
    exposure_relationship_concept_id INTEGER,
    exposure_source_concept_id INTEGER,
    exposure_source_value TEXT,
    exposure_relationship_source_value TEXT,
    dose_unit_source_value TEXT,
    quantity INTEGER,
    modifier_source_value TEXT,
    operator_concept_id INTEGER,
    value_as_number NUMERIC,
    value_as_concept_id INTEGER,
    unit_concept_id INTEGER,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_external_exposure_location
    ON working.external_exposure(location_id);
CREATE INDEX IF NOT EXISTS idx_external_exposure_person
    ON working.external_exposure(person_id);
CREATE INDEX IF NOT EXISTS idx_external_exposure_dates
    ON working.external_exposure(exposure_start_date, exposure_end_date);

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_data_source_updated_at
    BEFORE UPDATE ON backbone.data_source
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

COMMENT ON SCHEMA backbone IS 'Core metadata and template tables for GAIA data model';
COMMENT ON SCHEMA working IS 'Working tables for locations and exposure calculations';
COMMENT ON TABLE backbone.data_source IS 'Metadata about external data sources from JSON-LD';
COMMENT ON TABLE backbone.variable_source IS 'Individual variables/attributes tracked in data sources';
COMMENT ON TABLE backbone.geom_template IS 'Geometry records from external data sources';
COMMENT ON TABLE backbone.attr_template IS 'Attribute values associated with geometries';
COMMENT ON TABLE working.location IS 'Geocoded location records';
COMMENT ON TABLE working.location_history IS 'Person-location-time relationships';
COMMENT ON TABLE working.external_exposure IS 'Calculated exposure results from spatial joins';

-- * - * - * - * - * - * - * - * - * -
-- VOCABULARY SCHEMA
-- * - * - * - * - * - * - * - * - * -

CREATE TABLE vocabulary.concept (
    concept_id integer NOT NULL,
    concept_name varchar(255) NOT NULL,
    domain_id varchar(20) NOT NULL,
    vocabulary_id varchar(20) NOT NULL,
    concept_class_id varchar(20) NOT NULL,
    standard_concept varchar(1) NULL,
    concept_code varchar(50) NOT NULL,
    valid_start_date date NOT NULL,
    valid_end_date date NOT NULL,
    invalid_reason varchar(1) NULL
);

CREATE TABLE vocabulary.vocabulary (
    vocabulary_id varchar(20) NOT NULL,
    vocabulary_name varchar(255) NOT NULL,
    vocabulary_reference varchar(255) NULL,
    vocabulary_version varchar(255) NULL,
    vocabulary_concept_id integer NOT NULL
);

CREATE TABLE vocabulary.domain (
    domain_id varchar(20) NOT NULL,
    domain_name varchar(255) NOT NULL,
    domain_concept_id integer NOT NULL
);

CREATE TABLE vocabulary.concept_class (
    concept_class_id varchar(20) NOT NULL,
    concept_class_name varchar(255) NOT NULL,
    concept_class_concept_id integer NOT NULL
);

CREATE TABLE vocabulary.concept_relationship (
    concept_id_1 integer NOT NULL,
    concept_id_2 integer NOT NULL,
    relationship_id varchar(20) NOT NULL,
    valid_start_date date NOT NULL,
    valid_end_date date NOT NULL,
    invalid_reason varchar(1) NULL
);

CREATE TABLE vocabulary.relationship (
    relationship_id varchar(20) NOT NULL,
    relationship_name varchar(255) NOT NULL,
    is_hierarchical varchar(1) NOT NULL,
    defines_ancestry varchar(1) NOT NULL,
    reverse_relationship_id varchar(20) NOT NULL,
    relationship_concept_id integer NOT NULL
);

CREATE TABLE vocabulary.concept_synonym (
    concept_id integer NOT NULL,
    concept_synonym_name varchar(1000) NOT NULL,
    language_concept_id integer NOT NULL
);

CREATE TABLE vocabulary.concept_ancestor (
    ancestor_concept_id integer NOT NULL,
    descendant_concept_id integer NOT NULL,
    min_levels_of_separation integer NOT NULL,
    max_levels_of_separation integer NOT NULL
);

CREATE TABLE vocabulary.source_to_concept_map (
    source_code varchar(50) NOT NULL,
    source_concept_id integer NOT NULL,
    source_vocabulary_id varchar(20) NOT NULL,
    source_code_description varchar(255) NULL,
    target_concept_id integer NOT NULL,
    target_vocabulary_id varchar(20) NOT NULL,
    valid_start_date date NOT NULL,
    valid_end_date date NOT NULL,
    invalid_reason varchar(1) NULL
);

CREATE TABLE vocabulary.drug_strength (
    drug_concept_id integer NOT NULL,
    ingredient_concept_id integer NOT NULL,
    amount_value NUMERIC NULL,
    amount_unit_concept_id integer NULL,
    numerator_value NUMERIC NULL,
    numerator_unit_concept_id integer NULL,
    denominator_value NUMERIC NULL,
    denominator_unit_concept_id integer NULL,
    box_size integer NULL,
    valid_start_date date NOT NULL,
    valid_end_date date NOT NULL,
    invalid_reason varchar(1) NULL
);

CREATE TABLE vocabulary.temp_vocabulary_data (
    vocabulary_id varchar(20) NOT NULL,
    vocabulary_name varchar(255) NULL,
    vocabulary_reference varchar(255) NULL,
    vocabulary_version varchar(255) NULL,
    vocabulary_concept_id int4 NULL
);

-- Primary keys
ALTER TABLE vocabulary.concept
    ADD CONSTRAINT xpk_concept PRIMARY KEY (concept_id);
ALTER TABLE vocabulary.vocabulary
    ADD CONSTRAINT xpk_vocabulary PRIMARY KEY (vocabulary_id);
ALTER TABLE vocabulary.domain
    ADD CONSTRAINT xpk_domain PRIMARY KEY (domain_id);
ALTER TABLE vocabulary.concept_class
    ADD CONSTRAINT xpk_concept_class PRIMARY KEY (concept_class_id);
ALTER TABLE vocabulary.concept_relationship
    ADD CONSTRAINT xpk_concept_relationship PRIMARY KEY (concept_id_1, concept_id_2, relationship_id);
ALTER TABLE vocabulary.relationship
    ADD CONSTRAINT xpk_relationship PRIMARY KEY (relationship_id);
ALTER TABLE vocabulary.concept_ancestor
    ADD CONSTRAINT xpk_concept_ancestor PRIMARY KEY (ancestor_concept_id, descendant_concept_id);
ALTER TABLE vocabulary.source_to_concept_map
    ADD CONSTRAINT xpk_source_to_concept_map PRIMARY KEY (source_vocabulary_id, target_concept_id, source_code, valid_end_date);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT xpk_drug_strength PRIMARY KEY (drug_concept_id, ingredient_concept_id);

-- Indexes
CREATE UNIQUE INDEX idx_concept_concept_id ON vocabulary.concept (concept_id ASC);
CLUSTER vocabulary.concept USING idx_concept_concept_id;
CREATE INDEX idx_concept_code ON vocabulary.concept (concept_code ASC);
CREATE INDEX idx_concept_vocabluary_id ON vocabulary.concept (vocabulary_id ASC);
CREATE INDEX idx_concept_domain_id ON vocabulary.concept (domain_id ASC);
CREATE INDEX idx_concept_class_id ON vocabulary.concept (concept_class_id ASC);
CREATE INDEX idx_concept_id_varchar ON vocabulary.concept (cast(concept_id AS VARCHAR));

CREATE UNIQUE INDEX idx_vocabulary_vocabulary_id ON vocabulary.vocabulary (vocabulary_id ASC);
CLUSTER vocabulary.vocabulary USING idx_vocabulary_vocabulary_id;

CREATE UNIQUE INDEX idx_domain_domain_id ON vocabulary.domain (domain_id ASC);
CLUSTER vocabulary.domain USING idx_domain_domain_id;

CREATE UNIQUE INDEX idx_concept_class_class_id ON vocabulary.concept_class (concept_class_id ASC);
CLUSTER vocabulary.concept_class USING idx_concept_class_class_id;

CREATE INDEX idx_concept_relationship_id_1 ON vocabulary.concept_relationship (concept_id_1 ASC);
CREATE INDEX idx_concept_relationship_id_2 ON vocabulary.concept_relationship (concept_id_2 ASC);
CREATE INDEX idx_concept_relationship_id_3 ON vocabulary.concept_relationship (relationship_id ASC);

CREATE UNIQUE INDEX idx_relationship_rel_id ON vocabulary.relationship (relationship_id ASC);
CLUSTER vocabulary.relationship USING idx_relationship_rel_id;

CREATE INDEX idx_concept_synonym_id ON vocabulary.concept_synonym (concept_id ASC);
CLUSTER vocabulary.concept_synonym USING idx_concept_synonym_id;

CREATE INDEX idx_concept_ancestor_id_1 ON vocabulary.concept_ancestor (ancestor_concept_id ASC);
CLUSTER vocabulary.concept_ancestor USING idx_concept_ancestor_id_1;
CREATE INDEX idx_concept_ancestor_id_2 ON vocabulary.concept_ancestor (descendant_concept_id ASC);

CREATE INDEX idx_source_to_concept_map_id_3 ON vocabulary.source_to_concept_map (target_concept_id ASC);
CLUSTER vocabulary.source_to_concept_map USING idx_source_to_concept_map_id_3;
CREATE INDEX idx_source_to_concept_map_id_1 ON vocabulary.source_to_concept_map (source_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_id_2 ON vocabulary.source_to_concept_map (target_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_code ON vocabulary.source_to_concept_map (source_code ASC);

CREATE INDEX idx_drug_strength_id_1 ON vocabulary.drug_strength (drug_concept_id ASC);
CLUSTER vocabulary.drug_strength USING idx_drug_strength_id_1;
CREATE INDEX idx_drug_strength_id_2 ON vocabulary.drug_strength (ingredient_concept_id ASC);

-- Foreign key constraints
ALTER TABLE vocabulary.concept
    ADD CONSTRAINT fpk_concept_domain FOREIGN KEY (domain_id) REFERENCES vocabulary.domain (domain_id);
ALTER TABLE vocabulary.concept
    ADD CONSTRAINT fpk_concept_class FOREIGN KEY (concept_class_id) REFERENCES vocabulary.concept_class (concept_class_id);
ALTER TABLE vocabulary.concept
    ADD CONSTRAINT fpk_concept_vocabulary FOREIGN KEY (vocabulary_id) REFERENCES vocabulary.vocabulary (vocabulary_id);
ALTER TABLE vocabulary.vocabulary
    ADD CONSTRAINT fpk_vocabulary_concept FOREIGN KEY (vocabulary_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.domain
    ADD CONSTRAINT fpk_domain_concept FOREIGN KEY (domain_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_class
    ADD CONSTRAINT fpk_concept_class_concept FOREIGN KEY (concept_class_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_relationship
    ADD CONSTRAINT fpk_concept_relationship_c_1 FOREIGN KEY (concept_id_1) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_relationship
    ADD CONSTRAINT fpk_concept_relationship_c_2 FOREIGN KEY (concept_id_2) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_relationship
    ADD CONSTRAINT fpk_concept_relationship_id FOREIGN KEY (relationship_id) REFERENCES vocabulary.relationship (relationship_id);
ALTER TABLE vocabulary.relationship
    ADD CONSTRAINT fpk_relationship_concept FOREIGN KEY (relationship_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.relationship
    ADD CONSTRAINT fpk_relationship_reverse FOREIGN KEY (reverse_relationship_id) REFERENCES vocabulary.relationship (relationship_id);
ALTER TABLE vocabulary.concept_synonym
    ADD CONSTRAINT fpk_concept_synonym_concept FOREIGN KEY (concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_synonym
    ADD CONSTRAINT fpk_concept_synonym_language_concept FOREIGN KEY (language_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_ancestor
    ADD CONSTRAINT fpk_concept_ancestor_concept_1 FOREIGN KEY (ancestor_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.concept_ancestor
    ADD CONSTRAINT fpk_concept_ancestor_concept_2 FOREIGN KEY (descendant_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.source_to_concept_map
    ADD CONSTRAINT fpk_source_to_concept_map_v_1 FOREIGN KEY (source_vocabulary_id) REFERENCES vocabulary.vocabulary (vocabulary_id);
ALTER TABLE vocabulary.source_to_concept_map
    ADD CONSTRAINT fpk_source_to_concept_map_v_2 FOREIGN KEY (target_vocabulary_id) REFERENCES vocabulary.vocabulary (vocabulary_id);
ALTER TABLE vocabulary.source_to_concept_map
    ADD CONSTRAINT fpk_source_to_concept_map_c_1 FOREIGN KEY (target_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT fpk_drug_strength_concept_1 FOREIGN KEY (drug_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT fpk_drug_strength_concept_2 FOREIGN KEY (ingredient_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT fpk_drug_strength_unit_1 FOREIGN KEY (amount_unit_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT fpk_drug_strength_unit_2 FOREIGN KEY (numerator_unit_concept_id) REFERENCES vocabulary.concept (concept_id);
ALTER TABLE vocabulary.drug_strength
    ADD CONSTRAINT fpk_drug_strength_unit_3 FOREIGN KEY (denominator_unit_concept_id) REFERENCES vocabulary.concept (concept_id);

-- * - * - * - * - * - * - * - * - * -
-- LOAD GAIACORE FUNCTIONS
-- * - * - * - * - * - * - * - * - * -

\i /sql/02_jsonld_ingestion_functions.sql
\i /sql/03_location_ingestion_functions.sql
\i /sql/04_spatial_join_functions.sql
\i /sql/05_data_source_retrieval_functions.sql
