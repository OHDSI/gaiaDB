#!/usr/bin/env bash
set -e

# ---------------------------------------------------------------------------
# /data population
#
# Priority (highest wins):
#   INIT_WITH_DATASOURCE_MOUNT=TRUE  – /data is a bind-mount; do nothing
#   INIT_WITH_CATALOG=TRUE (default) – shallow-clone gaiaCatalog; copy datastore/data/* to /data
#   INIT_WITH_CATALOG=FALSE          – copy bundled /extras/* to /data
# ---------------------------------------------------------------------------

MOUNT_FLAG=$(echo "${INIT_WITH_DATASOURCE_MOUNT:-FALSE}" | tr '[:lower:]' '[:upper:]')
CATALOG_FLAG=$(echo "${INIT_WITH_CATALOG:-TRUE}" | tr '[:lower:]' '[:upper:]')

if [ "$MOUNT_FLAG" = "TRUE" ]; then
    echo "[gaiaDB] INIT_WITH_DATASOURCE_MOUNT=TRUE — expecting /data to be a bind-mount, skipping population"

elif [ "$CATALOG_FLAG" = "TRUE" ]; then
    echo "[gaiaDB] INIT_WITH_CATALOG=TRUE — cloning gaiaCatalog into /data..."
    git clone --depth 1 https://github.com/OHDSI/gaiaCatalog /tmp/gaiaCatalog
    mkdir -p /data
    cp -r /tmp/gaiaCatalog/datastore/data/. /data/
    rm -rf /tmp/gaiaCatalog
    chown -R 70:70 /data/
    echo "[gaiaDB] gaiaCatalog data loaded into /data"

else
    echo "[gaiaDB] INIT_WITH_CATALOG=FALSE — copying bundled example sources from /extras into /data..."
    mkdir -p /data
    cp -r /extras/. /data/
    chown -R 70:70 /data/
    echo "[gaiaDB] Example sources loaded into /data"
fi

# ---------------------------------------------------------------------------
# Postgres authentication
# ---------------------------------------------------------------------------
# if from docker-compose 
if [ -z "${POSTGRES_PASSWORD}" ]; then
    export POSTGRES_PASSWORD=$(cat $POSTGRES_PASSWORD_FILE)
    unset POSTGRES_PASSWORD_FILE
fi

# if from docker-compose
if [ -z "${DB_AUTHENTICATOR_PASSWORD}" ]; then 
    export DB_AUTHENTICATOR_PASSWORD=$(cat $AUTHENTICATOR_PASSWORD_FILE)
    unset AUTHENTICATOR_PASSWORD_FILE
fi

# TODO handle all API keys, perhaps from abstracted list somewhere ...

# ETL scripts (run in-container via plsh/gdsc_exec) always connect to this
# same container's own Postgres, never to a separate "gaia-db" host -- so the
# .pgpass host field is '*' (match any host) rather than a specific name that
# has to be kept in sync with whatever host= each script happens to use.
# POSTGRES_PORT defaults to 5432 since GDAL's PG: connection-string parser
# (used by ogr2ogr in the ETL scripts) fails hard on an empty port= rather
# than falling back to the default the way plain libpq does.
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"

echo "*:${POSTGRES_PORT}:${POSTGRES_DB}:${POSTGRES_USER}:${POSTGRES_PASSWORD}" > ~/.pgpass
chmod 0600 ~/.pgpass
chown 70:70 ~/.pgpass
echo "[gaiaDB] postgres authentication set"


# Hand off to the official PostgreSQL entrypoint
exec bash /usr/local/bin/docker-entrypoint.sh postgres
