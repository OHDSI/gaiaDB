#!/bin/bash

# ma_2022_svi_tract_postgis_derivative.sh
# Finish ETL into postGIS from postgis_derivative_postgis container
#
# Data source: https://svi.cdc.gov/Documents/Data/2022/db/states/Massachusetts.zip
# Destination postGIS table: ma_2022_svi_tract
#
# Created by etl() on 2026-02-12 10:25:43
# Do not edit directly

# Move into correct directory
cd /data/ma_2022_svi_tract/

export PGPASSWORD=$(cat $POSTGRES_PASSWORD_FILE)
# Create pg_dump of table SQL in derivate directory on postgis.
pg_dump -d $POSTGRES_DB -U $POSTGRES_USER -p $POSTGRES_PORT -h $POSTGRES_HOST -t ma_2022_svi_tract > derived/ma_2022_svi_tract.sql

# Create downloadable tarfile of SQL in derivative directory on postgis
rm -f derived/ma_2022_svi_tract.sql.tar.gz
tar -czf derived/ma_2022_svi_tract.sql.tar.gz meta_dcat_ma_2022_svi_tract.json -C derived ma_2022_svi_tract.sql

