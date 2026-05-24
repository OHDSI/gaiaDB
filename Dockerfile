FROM postgis/postgis:16-3.4-alpine

# Install required packages for gaiaCore functionality
# TODO check what is still needed - some of this looks redundant
RUN apk add --no-cache \
    libintl \
    gdal \
    gdal-tools \
    gdal-driver-pg \
    postgresql-contrib \
    curl \
    wget \
    ca-certificates \
    git \
    build-base \
    postgresql-dev \
    bc \
    make \
    g++ \
    clang15 \
    llvm15

# Install plsh (PostgreSQL shell procedural language)
RUN cd /tmp && \
    git clone https://github.com/petere/plsh.git && \
    cd plsh && \
    make && \
    make install && \
    cd / && \
    rm -rf /tmp/plsh

# Create required directories
# TODO: we may want to better locate these
RUN mkdir -p /csv /sql /data /extras /run
RUN chown 70:70 /csv /sql /data /extras /run

USER postgres

# Runtime defaults — override with -e at docker run or in docker-compose
ENV INIT_WITH_CATALOG=TRUE
ENV INIT_WITH_DATASOURCE_MOUNT=FALSE

## Download vocabulary CSV files from CVB repository
#RUN wget -O /csv/gis_vocabulary_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/vocabulary_delta.csv
#RUN wget -O /csv/gis_concept_class_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_class_delta.csv
#RUN wget -O /csv/gis_domain_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/domain_delta.csv
#RUN wget -O /csv/gis_concept_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_delta.csv
#RUN wget -O /csv/gis_relationship_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/relationship_delta.csv
#RUN wget -O /csv/gis_concept_relationship_fragment.csv https://raw.githubusercontent.com/TuftsCTSI/CVB/refs/heads/main/GIS/Ontology/concept_relationship_delta.csv

# Copy SQL db function files
COPY sql/*.sql /sql/

# Copy db initialization scripts (shell + schema init)
COPY init/00_init_gaiaDB.sh /docker-entrypoint-initdb.d/
COPY sql/01_init_schema.sql /docker-entrypoint-initdb.d/

# Bundle example sources (used when INIT_WITH_CATALOG=FALSE)
COPY extras/ /extras/

# copy entrypoint script
COPY --chmod=0755 docker-gaiadb-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/docker-gaiadb-entrypoint.sh"]

# Expose PostgreSQL port and start postgres
EXPOSE 5432
CMD ["postgres"]
