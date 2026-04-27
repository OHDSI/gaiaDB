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
    echo "[gaiaDB] gaiaCatalog data loaded into /data"

else
    echo "[gaiaDB] INIT_WITH_CATALOG=FALSE — copying bundled example sources from /extras into /data..."
    mkdir -p /data
    cp -r /extras/. /data/
    echo "[gaiaDB] Example sources loaded into /data"
fi

# ---------------------------------------------------------------------------
# Postgres authentication
# ---------------------------------------------------------------------------
echo "${POSTGRES_HOST:-gaia-db}:${POSTGRES_PORT}:${POSTGRES_DB}:${POSTGRES_USER}:$(cat "${PG_PASSWORD_FILE}")" > ~/.pgpass
chmod 0600 ~/.pgpass

# Hand off to the official PostgreSQL entrypoint
exec bash /usr/local/bin/docker-entrypoint.sh postgres
