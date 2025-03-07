FROM postgis/postgis:16-3.4-alpine

RUN mkdir /csv
COPY csv/data_source.csv /csv/data_source.csv
COPY csv/variable_source.csv /csv/variable_source.csv
RUN wget -O /csv/gis_vocabulary_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/vocabulary_delta.csv
RUN wget -O /csv/gis_concept_class_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_class_delta.csv
RUN wget -O /csv/gis_domain_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/domain_delta.csv
RUN wget -O /csv/gis_concept_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_delta.csv
RUN wget -O /csv/gis_relationship_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/relationship_delta.csv
RUN wget -O /csv/gis_concept_relationship_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_relationship_delta.csv
COPY init.sql /docker-entrypoint-initdb.d/init.sql
