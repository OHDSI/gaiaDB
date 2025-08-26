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


-- * - * - * - * - * - * - * - * - * -
-- VOCABULARY SCHEMA CONSTRUCTION
-- * - * - * - * - * - * - * - * - * -

-- ADD VOCABULARIES

CREATE SCHEMA IF NOT EXISTS vocabulary;

CREATE TABLE vocabulary.concept (
			concept_id integer NOT NULL,
			concept_name varchar(255) NOT NULL,
			domain_id varchar(25) NOT NULL,
			vocabulary_id varchar(25) NOT NULL,
			concept_class_id varchar(25) NOT NULL,
			standard_concept varchar(1) NULL,
			concept_code varchar(50) NOT NULL,
			valid_start_date date NOT NULL,
			valid_end_date date NOT NULL,
			invalid_reason varchar(1) NULL );

CREATE TABLE vocabulary.vocabulary (
			vocabulary_id varchar(25) NOT NULL,
			vocabulary_name varchar(255) NOT NULL,
			vocabulary_reference varchar(255) NULL,
			vocabulary_version varchar(255) NULL,
			vocabulary_concept_id integer NOT NULL );

CREATE TABLE vocabulary.domain (
			domain_id varchar(25) NOT NULL,
			domain_name varchar(255) NOT NULL,
			domain_concept_id integer NOT NULL );

CREATE TABLE vocabulary.concept_class (
			concept_class_id varchar(25) NOT NULL,
			concept_class_name varchar(255) NOT NULL,
			concept_class_concept_id integer NOT NULL );

CREATE TABLE vocabulary.concept_relationship (
			concept_id_1 integer NOT NULL,
			concept_id_2 integer NOT NULL,
			relationship_id varchar(25) NOT NULL,
			valid_start_date date NOT NULL,
			valid_end_date date NOT NULL,
			invalid_reason varchar(1) NULL );

CREATE TABLE vocabulary.relationship (
			relationship_id varchar(25) NOT NULL,
			relationship_name varchar(255) NOT NULL,
			is_hierarchical varchar(1) NOT NULL,
			defines_ancestry varchar(1) NOT NULL,
			reverse_relationship_id varchar(25) NOT NULL,
			relationship_concept_id integer NOT NULL );

CREATE TABLE vocabulary.concept_synonym (
			concept_id integer NOT NULL,
			concept_synonym_name varchar(1000) NOT NULL,
			language_concept_id integer NOT NULL );

CREATE TABLE vocabulary.concept_ancestor (
			ancestor_concept_id integer NOT NULL,
			descendant_concept_id integer NOT NULL,
			min_levels_of_separation integer NOT NULL,
			max_levels_of_separation integer NOT NULL );

CREATE TABLE vocabulary.source_to_concept_map (
			source_code varchar(50) NOT NULL,
			source_concept_id integer NOT NULL,
			source_vocabulary_id varchar(25) NOT NULL,
			source_code_description varchar(255) NULL,
			target_concept_id integer NOT NULL,
			target_vocabulary_id varchar(25) NOT NULL,
			valid_start_date date NOT NULL,
			valid_end_date date NOT NULL,
			invalid_reason varchar(1) NULL );

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
			invalid_reason varchar(1) NULL );

CREATE TABLE vocabulary.temp_vocabulary_data (
    vocabulary_id varchar(25) NOT NULL,
    vocabulary_name varchar(255) NULL,
    vocabulary_reference varchar(255) NULL,
    vocabulary_version varchar(255) NULL,
    vocabulary_concept_id int4 NULL
);

-- ADD GENERAL VOCABULARY CONCEPTS FOR GIS & SDOH


\COPY vocabulary.temp_vocabulary_data FROM '/csv/gis_vocabulary_fragment.csv' DELIMITER ',' CSV HEADER;
-- Insert new vocabulary concept_ids (that are not in vocabulary) into concept table
INSERT INTO vocabulary.concept
SELECT vocabulary_concept_id AS concept_id
        , vocabulary_name AS concept_name
        , 'Metadata' AS domain_id
        , 'Vocabulary' AS vocabulary_id
        , 'Vocabulary' AS concept_class_id
        , NULL AS standard_concept
        , 'OMOP generated' AS concept_code
        , '1970-01-01' AS valid_start_date
        , '2099-12-31' AS valid_end_date
        , NULL AS invalid_reason
FROM vocabulary.temp_vocabulary_data
WHERE vocabulary_id NOT IN (
    SELECT vocabulary_id
    FROM vocabulary.vocabulary
);
INSERT INTO vocabulary.vocabulary SELECT * FROM vocabulary.temp_vocabulary_data WHERE vocabulary_id NOT IN (SELECT vocabulary_id FROM vocabulary.vocabulary);

-- ADD CONCEPT_CLASSES
CREATE TABLE vocabulary.temp_concept_class_data (
    concept_class_id varchar(25) NOT NULL,
    concept_class_name varchar(255) NULL,
    concept_class_concept_id int4 NULL
);
\COPY vocabulary.temp_concept_class_data FROM '/csv/gis_concept_class_fragment.csv' DELIMITER ',' CSV HEADER;
-- Insert new concept_class concept_ids (that are not in concept_class) into concept table
INSERT INTO vocabulary.concept
SELECT concept_class_concept_id AS concept_id
        , concept_class_name AS concept_name
        , 'Metadata' AS domain_id
        , 'Concept Class' AS vocabulary_id
        , 'Concept Class' AS concept_class_id
        , NULL AS standard_concept
        , 'OMOP generated' AS concept_code
        , '1970-01-01' AS valid_start_date
        , '2099-12-31' AS valid_end_date
        , NULL AS invalid_reason
FROM vocabulary.temp_concept_class_data
WHERE concept_class_id NOT IN (
    SELECT concept_class_id
    FROM vocabulary.concept_class
);

INSERT INTO vocabulary.concept_class SELECT * FROM vocabulary.temp_concept_class_data WHERE concept_class_id NOT IN (SELECT concept_class_id FROM vocabulary.concept_class);

-- ADD DOMAINS
CREATE TABLE vocabulary.temp_domain_data (
    domain_id varchar(25) NOT NULL,
    domain_name varchar(255) NULL,
    domain_concept_id int4 NULL
);
\COPY vocabulary.temp_domain_data FROM '/csv/gis_domain_fragment.csv' DELIMITER ',' CSV HEADER;
-- Insert new domain concept_ids (that are not in domain) into concept table
INSERT INTO vocabulary.concept
SELECT domain_concept_id AS concept_id
        , domain_name AS concept_name
        , 'Metadata' AS domain_id
        , 'Domain' AS vocabulary_id
        , 'Domain' AS concept_class_id
        , NULL AS standard_concept
        , 'OMOP generated' AS concept_code
        , '1970-01-01' AS valid_start_date
        , '2099-12-31' AS valid_end_date
        , NULL AS invalid_reason
FROM vocabulary.temp_domain_data
WHERE domain_id NOT IN (
    SELECT domain_id
    FROM vocabulary.domain
);
INSERT INTO vocabulary.domain SELECT * FROM vocabulary.temp_domain_data WHERE domain_id NOT IN (SELECT domain_id FROM vocabulary.domain);

-- ADD CONCEPTS
CREATE TABLE vocabulary.temp_concept_data (
    concept_id integer NULL,
    concept_name text NULL,
    domain_id text NULL,
    vocabulary_id text NULL,
    concept_class_id text NULL,
    standard_concept text NULL,
    concept_code text NULL,
    valid_start_date date NULL,
    valid_end_date date NULL,
    invalid_reason text NULL
);
\COPY vocabulary.temp_concept_data FROM '/csv/gis_concept_fragment.csv' DELIMITER ',' CSV HEADER;

INSERT INTO vocabulary.concept
SELECT   concept_id
        , LEFT(concept_name, 255)
        , domain_id
        , vocabulary_id
        , concept_class_id
        , standard_concept
        , concept_code
        , valid_start_date
        , valid_end_date
        , invalid_reason
FROM vocabulary.temp_concept_data
;
-- INSERT INTO vocabulary.concept SELECT * FROM vocabulary.temp_concept_data;

-- ADD RELATIONSHIPS
CREATE TABLE vocabulary.temp_relationship_data (
    relationship_id varchar(25) NOT NULL,
	relationship_name varchar(255) NULL,
	is_hierarchical varchar(1) NULL,
	defines_ancestry varchar(1) NULL,
	reverse_relationship_id varchar(25) NULL,
	relationship_concept_id int4 NULL
);
\COPY vocabulary.temp_relationship_data FROM '/csv/gis_relationship_fragment.csv' DELIMITER ',' CSV HEADER;
-- Insert new relationship concept_ids (that are not in relationship) into concept table
INSERT INTO vocabulary.concept
SELECT relationship_concept_id AS concept_id
        , relationship_name AS concept_name
        , 'Metadata' AS domain_id
        , 'Relationship' AS vocabulary_id
        , 'Relationship' AS concept_class_id
        , NULL AS standard_concept
        , 'OMOP generated' AS concept_code
        , '1970-01-01' AS valid_start_date
        , '2099-12-31' AS valid_end_date
        , NULL AS invalid_reason
FROM vocabulary.temp_relationship_data;
INSERT INTO vocabulary.relationship SELECT * FROM vocabulary.temp_relationship_data;

-- ADD CONCEPT_RELATIONSHIPS
CREATE TABLE vocabulary.temp_concept_relationship_data (
    concept_id_1 int4 NULL,
    concept_id_2 int4 NULL,
    relationship_id text NULL,
    valid_start_date date NULL,
    valid_end_date date NULL,
    invalid_reason text NULL
);


\COPY vocabulary.temp_concept_relationship_data FROM '/csv/gis_concept_relationship_fragment.csv' DELIMITER ',' CSV HEADER;

INSERT INTO vocabulary.concept_relationship
SELECT      concept_id_1
			, concept_id_2
			, relationship_id
			, valid_start_date
			, valid_end_date
			, invalid_reason
FROM vocabulary.temp_concept_relationship_data;

-- ADD REVERSE CONCEPT_RELATIONSHIPS (WHERE MISSING)
INSERT INTO vocabulary.concept_relationship
select rev.*
from (
	select cr.concept_id_2 as concept_id_1
			, cr.concept_id_1 as concept_id_2
			, r.reverse_relationship_id as relationship_id
			, cr.valid_start_date
			, cr.valid_end_date
			, cr.invalid_reason
	from vocabulary.concept_relationship cr
	inner join vocabulary.relationship r
	on cr.relationship_id = r.relationship_id
	and  cr.concept_id_1 > 2000000000
) rev
left join (
	select *
	from vocabulary.concept_relationship
		where concept_id_1 > 2000000000
) orig
on rev.concept_id_1 = orig.concept_id_1
and rev.concept_id_2 = orig.concept_id_2
and rev.relationship_id = orig.relationship_id
where orig.concept_id_1 is NULL;


-- Drop all temporary tables
DROP TABLE vocabulary.temp_concept_data;
DROP TABLE vocabulary.temp_concept_relationship_data;
DROP TABLE vocabulary.temp_concept_class_data;
DROP TABLE vocabulary.temp_domain_data;
DROP TABLE vocabulary.temp_relationship_data;
DROP TABLE vocabulary.temp_vocabulary_data;

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

-- constraints
CREATE UNIQUE INDEX idx_concept_concept_id ON vocabulary.concept (concept_id ASC);
CLUSTER
vocabulary.concept USING idx_concept_concept_id;
CREATE INDEX idx_concept_code ON vocabulary.concept (concept_code ASC);
CREATE INDEX idx_concept_vocabluary_id ON vocabulary.concept (vocabulary_id ASC);
CREATE INDEX idx_concept_domain_id ON vocabulary.concept (domain_id ASC);
CREATE INDEX idx_concept_class_id ON vocabulary.concept (concept_class_id ASC);
CREATE INDEX idx_concept_id_varchar ON vocabulary.concept (cast(concept_id AS VARCHAR));
CREATE UNIQUE INDEX idx_vocabulary_vocabulary_id ON vocabulary.vocabulary (vocabulary_id ASC);
CLUSTER
vocabulary.vocabulary USING idx_vocabulary_vocabulary_id;
CREATE UNIQUE INDEX idx_domain_domain_id ON vocabulary.domain (domain_id ASC);
CLUSTER
vocabulary.domain USING idx_domain_domain_id;
CREATE UNIQUE INDEX idx_concept_class_class_id ON vocabulary.concept_class (concept_class_id ASC);
CLUSTER
vocabulary.concept_class USING idx_concept_class_class_id;
CREATE INDEX idx_concept_relationship_id_1 ON vocabulary.concept_relationship (concept_id_1 ASC);
CREATE INDEX idx_concept_relationship_id_2 ON vocabulary.concept_relationship (concept_id_2 ASC);
CREATE INDEX idx_concept_relationship_id_3 ON vocabulary.concept_relationship (relationship_id ASC);
CREATE UNIQUE INDEX idx_relationship_rel_id ON vocabulary.relationship (relationship_id ASC);
CLUSTER
vocabulary.relationship USING idx_relationship_rel_id;
CREATE INDEX idx_concept_synonym_id ON vocabulary.concept_synonym (concept_id ASC);
CLUSTER
vocabulary.concept_synonym USING idx_concept_synonym_id;
CREATE INDEX idx_concept_ancestor_id_1 ON vocabulary.concept_ancestor (ancestor_concept_id ASC);
CLUSTER
vocabulary.concept_ancestor USING idx_concept_ancestor_id_1;
CREATE INDEX idx_concept_ancestor_id_2 ON vocabulary.concept_ancestor (descendant_concept_id ASC);
CREATE INDEX idx_source_to_concept_map_id_3 ON vocabulary.source_to_concept_map (target_concept_id ASC);
CLUSTER
vocabulary.source_to_concept_map USING idx_source_to_concept_map_id_3;
CREATE INDEX idx_source_to_concept_map_id_1 ON vocabulary.source_to_concept_map (source_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_id_2 ON vocabulary.source_to_concept_map (target_vocabulary_id ASC);
CREATE INDEX idx_source_to_concept_map_code ON vocabulary.source_to_concept_map (source_code ASC);
CREATE INDEX idx_drug_strength_id_1 ON vocabulary.drug_strength (drug_concept_id ASC);
CLUSTER
vocabulary.drug_strength USING idx_drug_strength_id_1;
CREATE INDEX idx_drug_strength_id_2 ON vocabulary.drug_strength (ingredient_concept_id ASC);

-- foreign key constraints
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