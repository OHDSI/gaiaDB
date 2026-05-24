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

# download if needed
if [[ $do_update = 1 ]]; then
  (exit 1)
  until [[ "$?" == 0 ]]; do
      wget -O download/ma_2022_svi_tract.zip 'https://svi.cdc.gov/Documents/Data/2022/db/states/Massachusetts.zip'
  done
  unzip -d download download/ma_2022_svi_tract.zip && rm download/ma_2022_svi_tract.zip
  # record download datestamp
  echo $(date '+%F %T') > datestamp
fi

# load into postGIS
(exit 1)
until [[ "$?" == 0 ]]; do
  ogr2ogr -lco GEOMETRY_NAME=geom -f PostgreSQL PG:"dbname=$POSTGRES_DB port=$POSTGRES_PORT user=$POSTGRES_USER password=$POSTGRES_PASSWORD host='gaia-db'" download/SVI2022_MASSACHUSETTS_tract.gdb -nlt multipolygon -nln ma_2022_svi_tract
done

