#!/bin/bash

# ma_2022_svi_tract_osgeo.sh
# Download and ETL into postGIS from osgeo_postgis container
#
# Data source: https://svi.cdc.gov/Documents/Data/2022/db/states/Massachusetts.zip
# Destination postGIS table: ma_2022_svi_tract
#
# Created by etl() on 2026-05-23 15:07:15
# Do not edit directly

# create directory structure and move into it
mkdir -p /data/ma_2022_svi_tract/download /data/ma_2022_svi_tract/etl && cd /data/ma_2022_svi_tract

# check for existence
export TZ=EST5EDT
do_update=0
list=$(ls)
file=datestamp
exists=$(test "${list#*$file}" != "$list" && echo 1)
if [[ $exists ]]; then

  # check need for update based on update frequency
  update_frequency='Never'
  no_update='-- As Needed Never'
  no_update=$(test "${no_update#*$update_frequency}" != "$no_update" && echo 1)
  if [[ ! $no_update ]]; then
    last_update=$(date -d "$(cat datestamp)" '+%s')
    check_date="$(date -d '-'"$update_frequency" '+%s')"
    if [[ "$check_date -ge $last_update" ]]; then do_update=1; fi
  fi

# does not exist
else do_update=1; fi

# NOTE: manually patched -- three fixes:
# 1) ogr2ogr/wget stderr is redirected to a log file instead of being left
#    connected to plsh's captured pipe. plsh reads a child's stdout to EOF
#    before it starts draining stderr, and treats any non-empty stderr as a
#    hard error; a statewide tract-level load emits enough GDAL warnings on
#    stderr to exceed the pipe buffer, which deadlocks ogr2ogr in write()
#    while plsh is still blocked reading stdout. See etl/etl.log.
# 2) host='gaia-db' -> host='localhost'. ogr2ogr always runs inside the same
#    container as the Postgres server it's loading into (via plsh), so
#    'gaia-db' only resolves under a specific docker-compose setup with a
#    service literally named gaia-db. localhost always resolves correctly
#    since Postgres listens on 0.0.0.0.
# 3) port=$POSTGRES_PORT -> port=${POSTGRES_PORT:-5432}. If POSTGRES_PORT
#    isn't set, GDAL's PG: connection-string parser fails hard on the empty
#    port= (unlike plain libpq, which falls back to the default) with
#    "invalid integer value ... for connection option port", so ogr2ogr
#    never even attempts to connect.

# download if needed
if [[ $do_update = 1 ]]; then
  (exit 1)
  until [[ "$?" == 0 ]]; do
      wget -O download/ma_2022_svi_tract.zip 'https://svi.cdc.gov/Documents/Data/2022/db/states/Massachusetts.zip' >> etl/etl.log 2>&1
  done
  unzip -d download download/ma_2022_svi_tract.zip && rm download/ma_2022_svi_tract.zip
  # record download datestamp
  echo $(date '+%F %T') > datestamp
fi

# load into postGIS
(exit 1)
until [[ "$?" == 0 ]]; do
  ogr2ogr -lco GEOMETRY_NAME=geom -f PostgreSQL PG:"dbname=$POSTGRES_DB port=${POSTGRES_PORT:-5432} user=$POSTGRES_USER password=$POSTGRES_PASSWORD host='localhost'" download/SVI2022_MASSACHUSETTS_tract.gdb -nlt multipolygon -nln ma_2022_svi_tract >> etl/etl.log 2>&1
done

