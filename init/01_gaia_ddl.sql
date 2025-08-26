-- * - * - * - * - * - * - * - * - * -
-- BACKBONE SCHEMA CONSTRUCTION
-- * - * - * - * - * - * - * - * - * -

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

CREATE SCHEMA IF NOT EXISTS backbone;
CREATE SCHEMA IF NOT EXISTS gaia;

SET search_path = backbone, public;

--postgresql DDL Specification for Gaia Data Model 0.1.1

CREATE TABLE backbone.geom_index (
			geom_index_id SERIAL4 PRIMARY KEY,
			data_type_id numeric NULL,
			data_type_name varchar(255) NULL,
			geom_type_concept_id numeric NULL,
			geom_type_source_value varchar(255) NOT NULL,
			table_name varchar(255) NOT NULL,
			table_desc text NOT NULL,
			database_schema varchar(255) NOT NULL );

CREATE TABLE backbone.attr_index (
			attr_index_id SERIAL4 PRIMARY KEY,
			geom_index_id int4 NOT NULL,
			CONSTRAINT fk_attr_index_geom_index
			  FOREIGN KEY (geom_index_id) 
			  REFERENCES backbone.geom_index (geom_index_id),
			table_name varchar(255) NOT NULL,
			variable_name varchar NOT NULL,
			variable_desc text NOT NULL,
			attr_concept_id int4 NULL,
			unit_concept_id int4 NULL,
			unit_source_value varchar NULL,
			attr_start_date date NOT NULL,
			attr_end_date date NOT NULL,
			attr_no_value_as_number numeric NULL,
			attr_no_value_as_string varchar NULL,
			qualifier_concept_id int4 NULL,
			qualifier_source_value varchar NULL,
			attr_source_concept_id int4 NULL,
			attr_source_value varchar NOT NULL,
			database_schema varchar(255) NOT NULL );

CREATE TABLE backbone.geom_template (
			geom_record_id int4 PRIMARY KEY,
			geom_index_id int4 NOT NULL,
			CONSTRAINT fk_geom_template_geom_index
			  FOREIGN KEY (geom_index_id) 
			  REFERENCES backbone.geom_index (geom_index_id),
			geom_name varchar NOT NULL,
			geom_source_coding varchar NOT NULL,
			geom_source_value varchar NOT NULL,
			geom_wgs84 geometry NULL,
			geom_local_epsg int4 NOT NULL,
			geom_local_value geometry NOT NULL );

CREATE TABLE backbone.attr_template (
			attr_record_id int4 PRIMARY KEY,
			attr_index_id int4 NOT NULL,
			CONSTRAINT fk_attr_template_attr_index
			  FOREIGN KEY (attr_index_id) 
			  REFERENCES backbone.attr_index (attr_index_id),
			geom_record_id int4 NOT NULL,
			CONSTRAINT fk_attr_template_geom_template
			  FOREIGN KEY (geom_record_id) 
			  REFERENCES backbone.geom_template (geom_record_id),
			value_as_number float8 NULL,
			value_as_string varchar NULL,
			value_as_concept_id int4 NULL,
			value_source_value varchar NOT NULL );


