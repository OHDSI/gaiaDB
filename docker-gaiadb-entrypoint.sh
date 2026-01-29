#!/usr/bin/env bash

# TODO: put all init scripts in init folder and then simply copy all in Dockerfile

# Postgres authentication - both as client and server, not sure if this is good ...
echo gaia-db:$POSTGRES_PORT:$POSTGRES_DB:$POSTGRES_USER:$(cat $PG_PASSWORD_FILE) > ~/.pgpass
chmod 0600 ~/.pgpass

# run postgres docker-entrypoint.sh
bash /usr/local/bin/docker-entrypoint.sh postgres
