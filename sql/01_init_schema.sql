-- gaiaCore Database Initialization
-- Creates schemas, extensions, and base tables

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS plsh;

-- Create schemas
CREATE SCHEMA IF NOT EXISTS backbone;
CREATE SCHEMA IF NOT EXISTS public;
CREATE SCHEMA IF NOT EXISTS working;

-- Grant permissions
GRANT USAGE ON SCHEMA backbone TO PUBLIC;
GRANT USAGE ON SCHEMA working TO PUBLIC;

-- Create sequences
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

-- Data source metadata table
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

-- Variable source table (tracks individual variables/attributes in datasets)
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

-- Geometry template table
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

-- Create spatial index
CREATE INDEX IF NOT EXISTS idx_geom_template_wgs84
    ON backbone.geom_template USING GIST(geom_wgs84);

-- Attribute template table
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

-- LOCATION table (geocoded addresses)
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

-- Create spatial index for locations
CREATE INDEX IF NOT EXISTS idx_location_geom
    ON working.location USING GIST(geom);

-- LOCATION_HISTORY table (person-location-time relationships)
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

-- Location merge view (combines location and location_history with geometry)
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

-- External exposure output table
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

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_external_exposure_location
    ON working.external_exposure(location_id);
CREATE INDEX IF NOT EXISTS idx_external_exposure_person
    ON working.external_exposure(person_id);
CREATE INDEX IF NOT EXISTS idx_external_exposure_dates
    ON working.external_exposure(exposure_start_date, exposure_end_date);

-- Create update trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add update trigger to data_source
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
