#!/usr/bin/env bash

# TODO: put all init scripts in init folder and then simply copy all in Dockerfile

# Authenticator login for APIs - there may be a better way with JWT authentication ...
psql -U $POSTGRES_USER --dbname="$POSTGRES_DB" -c "CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '$DB_AUTHENTICATOR_PASSWORD';"
