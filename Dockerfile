FROM postgis/postgis:16-3.4-alpine

RUN mkdir /csv
COPY csv/data_source.csv /csv/data_source.csv
COPY csv/variable_source.csv /csv/variable_source.csv
RUN wget -O /csv/gis_vocabulary_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_vocabulary_stage_v1.csv
RUN wget -O /csv/gis_concept_class_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_concept_class_stage_v1.csv
RUN wget -O /csv/gis_domain_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_domain_stage_v1.csv
RUN wget -O /csv/gis_concept_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_concept_stage_v1.csv
RUN wget -O /csv/gis_relationship_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_relationship_stage_v1.csv
RUN wget -O /csv/gis_concept_relationship_fragment.csv https://raw.githubusercontent.com/OHDSI/GIS/refs/heads/main/vocabularies/gis_vocabs_concept_relationship_stage_v1.csv
COPY init.sql /docker-entrypoint-initdb.d/init.sql