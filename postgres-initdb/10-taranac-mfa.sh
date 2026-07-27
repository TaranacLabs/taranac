#!/bin/bash
# Runs inside the PostgreSQL container on first init (empty data dir only).
# Creates the separate database the taranac-mfa service uses.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE taranac_mfa OWNER ${POSTGRES_USER};
EOSQL

echo "Database 'taranac_mfa' created successfully."
