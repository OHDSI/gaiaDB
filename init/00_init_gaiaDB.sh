#!/usr/bin/env bash

# TODO: put all init scripts in init folder and then simply copy all in Dockerfile

# ---------------------------------------------------------------------------
# Postgres authentication
# ---------------------------------------------------------------------------

# $DB_AUTHENTICATOR_PASSWORD: check if empty variable exists from docker-compose
if [ -z "${DB_AUTHENTICATOR_PASSWORD}" ]; then 
    export DB_AUTHENTICATOR_PASSWORD=$(cat $AUTHENTICATOR_PASSWORD_FILE)
    unset AUTHENTICATOR_PASSWORD_FILE
    echo [gaiaDB] set db autheticator password
fi

# Authenticator login for APIs - there may be a better way with JWT authentication ...
psql -U $POSTGRES_USER --dbname="$POSTGRES_DB" -c "CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '$DB_AUTHENTICATOR_PASSWORD';"
unset DB_AUTHENTICATOR_PASSWORD
echo [gaiaDB] authenticator role created in the database