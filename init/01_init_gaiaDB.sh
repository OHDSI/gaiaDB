#!/usr/bin/env bash

# TODO: put all init scripts in init folder and then simply copy all in Dockerfile

# Authenticator login for APIs - there may be a better way with JWT authentication ...
export DB_AUTHENTICATOR_PASSWORD=$(cat $AUTHENTICATOR_PASSWORD_FILE)
psql -U $POSTGRES_USER --dbname="$POSTGRES_DB" -c "CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '$DB_AUTHENTICATOR_PASSWORD';"

# Postgres authentication - both as client and server, not sure if this is good ...
echo gaia-db:$POSTGRES_PORT:$POSTGRES_DB:$POSTGRES_USER:$(cat $PG_PASSWORD_FILE) > ~/.pgpass
chmod 0600 ~/.pgpass


