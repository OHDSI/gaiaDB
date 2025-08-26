-- * - * - * - * - * - * - * - * - * -
-- FUNCTION gaia_load_variables()
-- * - * - * - * - * - * - * - * - * -

-- FUNCTION: gaia.gaia_load_variable(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, numeric, numeric, date, date, integer)

-- DROP FUNCTION IF EXISTS gaia.gaia_load_variable(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, numeric, numeric, date, date, integer);

CREATE OR REPLACE FUNCTION gaia.gaia_load_variable(
	table_id character varying,
	table_description character varying,
	geom_type character varying,
	geom_label character varying,
	variable_nodata character varying,
	variable_id character varying,
	decription character varying,
	source character varying,
	type character varying,
	unit character varying,
	unit_concept_id integer,
	min_val numeric,
	max_val numeric,
	start_date date,
	end_date date,
	concept_id integer)
    RETURNS json
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	geom_entry_exists boolean;
	attr_entry_exists boolean;
	table_pk text;
	geom_index_id int4;
	attr_index_id int4;
	attr_instance_exists boolean;
	geom_instance varchar := 'None';
	attr_instance varchar := 'None';

BEGIN

	-- TODO: primary keys, geometry names (labels) -> hard coded in this instance for ma_2018_svi_tract
	-- TODO: nodata values
	-- TODO: geom type and conceptID??
	-- TODO: put this function in backbone and adjust

	-- get the primary key for the table
	EXECUTE format('
		SELECT c.column_name
		FROM information_schema.table_constraints tc 
		JOIN information_schema.constraint_column_usage AS ccu USING (constraint_schema, constraint_name) 
		JOIN information_schema.columns AS c ON c.table_schema = tc.constraint_schema
		  AND tc.table_name = c.table_name AND ccu.column_name = c.column_name
		WHERE constraint_type = ''PRIMARY KEY'' and tc.table_name = ''%I'';
	', table_id) INTO table_pk;

	-- check for existing geom index entry and create one if none exists
	EXECUTE format('
		SELECT EXISTS (
		   SELECT FROM backbone.geom_index 
		   WHERE table_name   = ''%s''
		);', table_id) INTO geom_entry_exists;

	IF NOT geom_entry_exists THEN

		-- create geom index entry
		RAISE NOTICE 'creating geom index entry';
		EXECUTE format('
			INSERT INTO backbone.geom_index (
				geom_type_source_value,
				table_name,
				table_desc,
				database_schema
			)
			VALUES (
				$1,$2,$3,$4
			);
		') USING geom_type, table_id, table_description,'gaia';

		-- get the geom_index_id for the table
		EXECUTE format('
			SELECT geom_index_id 
			FROM backbone.geom_index
			WHERE table_name = ''%s'';', table_id) INTO geom_index_id;	

		-- create geom table
		EXECUTE format('
			CREATE TABLE gaia.geom_%I AS TABLE backbone.geom_template;
			ALTER TABLE gaia.geom_%I ADD PRIMARY KEY (geom_record_id);
			ALTER TABLE gaia.geom_%I ADD CONSTRAINT fk_geom_%I_geom_index
			  FOREIGN KEY (geom_index_id)
			  REFERENCES backbone.geom_index (geom_index_id);
		', table_id, table_id, table_id,table_id);
		-- create constraints for PK and FK relations??

		-- insert geom values into the geom table
		EXECUTE format('
			INSERT INTO gaia.geom_%I (
			  geom_record_id,
			  geom_index_id,
			  geom_name,
			  geom_wgs84,
			  geom_local_epsg,
			  geom_local_value
			)
			SELECT 
			  %I as geom_record_id,
			  $1 as geom_index_id,
			  %I as geom_name,
			  ST_Transform(geom, 4326) as geom_wgs84,
			  ST_SRID(geom_local) as geom_local_epsg,
			  geom_local as geom_local_value
			FROM public.%I;
		', table_id, table_pk, geom_label, table_id) USING geom_index_id;

		geom_instance := 'geom_' || table_id;

	END IF;

	-- get the geom_index_id for the table
	EXECUTE format('
		SELECT geom_index_id 
		FROM backbone.geom_index
		WHERE table_name = ''%s'';', table_id) INTO geom_index_id;	

	-- check for existing attr index entry
	EXECUTE format('
		SELECT EXISTS (
		   SELECT FROM backbone.attr_index 
		   WHERE variable_name = ''%s''
		   AND table_name   = ''%s''
		);', variable_id, table_id) INTO attr_entry_exists;

	-- create the attr index entry and the associated attr table
	IF NOT attr_entry_exists THEN

		RAISE NOTICE 'creating attr index entry';
		EXECUTE format('
			INSERT INTO backbone.attr_index (
				geom_index_id,
				table_name,
				variable_name,
				variable_desc,
				attr_concept_id,
				unit_concept_id,
				unit_source_value,
				attr_start_date,
				attr_end_date,
				attr_no_value_as_number,
				attr_no_value_as_string,
				attr_source_value,
				database_schema
			)
			VALUES (
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13
			);
		') USING geom_index_id, table_id, variable_id, decription, concept_id, unit_concept_id, unit, start_date, end_date, variable_nodata::numeric, variable_nodata, source, 'gaia';

		-- get the attr_index_id for the table
		EXECUTE format('
			SELECT attr_index_id 
			FROM backbone.attr_index
			WHERE table_name = ''%s'';', table_id) INTO attr_index_id;	

		-- check if the attr instance table already exists
		EXECUTE format('
			SELECT EXISTS (
				SELECT FROM information_schema.tables 
				WHERE  table_schema = ''gaia''
				  AND table_name = ''attr_%s''
			);', table_id) INTO attr_instance_exists;		

		IF NOT attr_instance_exists THEN
			-- create attr table if not already present
			EXECUTE format('
				CREATE TABLE gaia.attr_%I AS TABLE backbone.attr_template;
				CREATE SEQUENCE gaia.attr_%I_attr_record_id_seq OWNED BY gaia.attr_%I.attr_record_id;
				ALTER TABLE gaia.attr_%I ALTER COLUMN attr_record_id SET DEFAULT nextval(''gaia.attr_%I_attr_record_id_seq'');
				ALTER TABLE gaia.attr_%I ADD PRIMARY KEY (attr_record_id);
				ALTER TABLE gaia.attr_%I ADD CONSTRAINT fk_attr_%I_attr_index
				  FOREIGN KEY (attr_index_id)
				  REFERENCES backbone.attr_index (attr_index_id);
				ALTER TABLE gaia.attr_%I ADD CONSTRAINT fk_attr_%I_geom_%I
				  FOREIGN KEY (geom_record_id)
				  REFERENCES gaia.geom_%I (geom_record_id);
			', table_id, table_id, table_id, table_id, table_id, table_id, table_id, table_id, table_id, table_id, table_id, table_id);
			-- create constraints for PK and FK relations??
		END IF;

		-- insert attribute values into the attr table
		EXECUTE format('
			INSERT INTO gaia.attr_%I (
			  attr_index_id,
			  geom_record_id,
			  value_as_number,
			  value_as_string
			)
			SELECT 
			  $1 as attr_index_id,
			  %I as geom_record_id,
			  %I as value_as_number,
			  TO_CHAR(%I,''99999999990.99'') as value_as_string
			FROM public.%I;
		', table_id, table_pk, variable_id, variable_id, table_id) USING attr_index_id;

		attr_instance := 'attr_' || table_id;

	END IF;

	RETURN '{"geom": "' || geom_instance || '","attr": "' || attr_instance || '"}';
	
END;
$BODY$;

ALTER FUNCTION gaia.gaia_load_variable(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, numeric, numeric, date, date, integer)
    OWNER TO postgres;

