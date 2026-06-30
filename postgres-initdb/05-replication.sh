#!/bin/bash
# Replication-ready baseline (HA Phase 0, docs/guide/ha.md §6.7 / D6).
#
# Runs ONCE, during the Postgres image's first-init phase (docker-entrypoint-
# initdb.d), so it only applies to a freshly-created data directory. Pre-creates
# the `replicator` role and a pg_hba entry that allows replication connections.
# Both are INERT on a single node — nothing connects as `replicator` until a
# Patroni replica is added (Phase 1/2) — but baking them in now means converting
# to HA later is a config overlay, not a re-init.
#
# The role password comes from POSTGRES_REPLICATION_PASSWORD (a deploy knob; the
# dev compose hard-codes a dev value, prod supplies its own). The pg_hba scope is
# `samenet` — the container's own networks only — not the world.
set -euo pipefail

REPL_PASSWORD="${POSTGRES_REPLICATION_PASSWORD:-replicator}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	DO \$\$
	BEGIN
	    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
	        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
	    END IF;
	END
	\$\$;
EOSQL

# Allow replication connections from the container's own networks only. Idempotent
# (only appended once on first init). Inert until a replica actually connects.
HBA="${PGDATA:-/var/lib/postgresql/data}/pg_hba.conf"
if ! grep -q '^host[[:space:]]\+replication[[:space:]]\+replicator' "$HBA" 2>/dev/null; then
	echo "host    replication     replicator      samenet                 scram-sha-256" >> "$HBA"
fi

echo "[init-replication] replicator role + pg_hba entry ready (inert on a single node)"
