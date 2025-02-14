--postgresql CDM Primary Key Constraints for OMOP Common Data Model 0.1
ALTER TABLE @cdmDatabaseSchema.data_source  ADD CONSTRAINT xpk_data_source PRIMARY KEY (data_source_uuid);
ALTER TABLE @cdmDatabaseSchema.variable_source  ADD CONSTRAINT xpk_variable_source PRIMARY KEY (variable_source_id);
ALTER TABLE @cdmDatabaseSchema.attr_index  ADD CONSTRAINT xpk_attr_index PRIMARY KEY (attr_index_id);
ALTER TABLE @cdmDatabaseSchema.geom_index  ADD CONSTRAINT xpk_geom_index PRIMARY KEY (geom_index_id);
ALTER TABLE @cdmDatabaseSchema.attr_template  ADD CONSTRAINT xpk_attr_template PRIMARY KEY (attr_record_id);
ALTER TABLE @cdmDatabaseSchema.geom_template  ADD CONSTRAINT xpk_geom_template PRIMARY KEY (geom_record_id);
