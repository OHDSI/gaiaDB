#!/bin/bash

# ma_2022_svi_tract_osgeo_derivative.sh
# Finish ETL into postGIS from osgeo_derivative_postgis container
#
# Data source: https://svi.cdc.gov/Documents/Data/2022/db/states/Massachusetts.zip
# Destination postGIS table: ma_2022_svi_tract
#
# Created by etl() on 2026-05-23 15:07:15
# Do not edit directly

# Move into corrrect directory and create derivative directory in data package on osgeo
cd /data/ma_2022_svi_tract/
mkdir -p derived


