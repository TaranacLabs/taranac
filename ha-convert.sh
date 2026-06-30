#!/usr/bin/env bash
# ha-convert.sh — convert THIS existing single node into the SEED (node-1) of an HA
# cluster (docs/guide/ha.md §10.1). Run it on your current standalone install AFTER
# you have uploaded the HA license. It swaps the DB to the Patroni image, which
# ADOPTS the existing PGDATA in place (no re-init — the §6.7 baseline is already
# right), and brings node-1 up as the primary that initialises the DCS.
#
# This MUST run (and node-1 must become primary) BEFORE any other node runs
# ha-join.sh — otherwise an empty joining node could win the bootstrap race and
# clone over node-1's real data. Convert is SEQUENTIAL: node-1 first.
#
# Prerequisite: copy the cluster-wide HA settings into this .env first (the SAME on
# every node — see the .env HA block / ha-join.sh header): TARANAC_CLUSTER_NAME,
# DB_HOSTS, ETCD_HOSTS, ETCD_INITIAL_CLUSTER, POSTGRES_REPLICATION_PASSWORD,
# PG_ALLOW_CIDR. Bring up the witness etcd (a SEPARATE host) around now too — node-1
# needs etcd quorum (>= 2 of 3 members) to initialise the cluster.
#
# Usage (on node-1, from the bundle dir):
#   ./ha-convert.sh --node-name node-1 --node-address 10.0.0.1
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ENV_FILE=.env
COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

NODE_NAME=""; NODE_ADDRESS=""; ETCD_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node-name)    NODE_NAME="$2"; shift 2 ;;
    --node-address) NODE_ADDRESS="$2"; shift 2 ;;
    --etcd-name)    ETCD_NAME="$2"; shift 2 ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"

fail() { echo "ha-convert: $*" >&2; exit 1; }
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- ; }
setenv() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    local esc; esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ── Guards ───────────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — this is meant to run on a configured standalone install."
[ -n "$NODE_NAME" ]    || fail "missing --node-name (this seed node's unique cluster name)"
[ -n "$NODE_ADDRESS" ] || fail "missing --node-address (this node's routable host/IP)"
for k in TARANAC_CLUSTER_NAME DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER POSTGRES_REPLICATION_PASSWORD; do
  [ -n "$(getenv "$k")" ] || fail "$k is not set in .env — add the cluster-wide HA block first (see the .env HA section)."
done

# Witness guard (ha.md §8) — a 2-node cluster needs a 3rd etcd arbiter.
MEMBERS=$(getenv ETCD_INITIAL_CLUSTER); MCOUNT=$(printf '%s' "$MEMBERS" | tr ',' '\n' | grep -c '=')
[ "$MCOUNT" -ge 3 ] || fail "ETCD_INITIAL_CLUSTER lists $MCOUNT etcd member(s); HA REQUIRES >= 3 (the DB nodes + a witness arbiter in a SEPARATE failure domain) or a partition cannot reach quorum → split-brain (ha.md §8)."

# Directionality: the SEED must have EXISTING data (the opposite of a joining node).
VOL="taranac_pg_data"
docker volume inspect "$VOL" >/dev/null 2>&1 || fail "Postgres volume '${VOL}' not found — convert runs on a POPULATED standalone node. (A fresh node should be a join, not a convert.)"
[ -n "$(docker run --rm -v "${VOL}:/d" postgres:16-alpine sh -c 'ls -A /d 2>/dev/null')" ] || fail "Postgres volume '${VOL}' is EMPTY — nothing to adopt. Convert runs on your existing standalone data."

echo "ha-convert: converting '${NODE_NAME}' (${NODE_ADDRESS}) into the HA seed of cluster '$(getenv TARANAC_CLUSTER_NAME)'…"
echo "ha-convert: ⚠️  Patroni will ADOPT the existing data dir in place (no re-init). Take a backup first if you have not."

setenv TARANAC_NODE_NAME "$NODE_NAME"
setenv NODE_ADDRESS "$NODE_ADDRESS"
setenv ETCD_NAME "$ETCD_NAME"
# Authoritative HA marker — the bundle tooling (./taranac, install.sh, taranac-update.sh)
# reads this to ALWAYS merge docker-compose.ha.yml on this node (never base-only, which
# would start a 2nd writable Postgres on the Patroni PGDATA → split-brain). ha.md §13 A.
setenv TARANAC_HA 1

# Stop the standalone stack so nothing holds the data volume, then bring it up on
# the HA overlay (Patroni adopts the existing PGDATA + initialises the DCS).
docker compose --env-file "$ENV_FILE" -f docker-compose.yml down >/dev/null 2>&1 || true
echo "ha-convert: starting node-1 on the HA overlay (Patroni adopts the data + initialises the cluster)…"
${COMPOSE} pull >/dev/null 2>&1 || true
${COMPOSE} up -d

echo "ha-convert: waiting for node-1 to come up as the PRIMARY (needs etcd quorum — is the witness up?)…"
primary=""
for _ in $(seq 1 60); do
  if docker exec taranac-db psql -U taranac -d taranac -tAc "select not pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
    primary=1; break
  fi
  sleep 5
done
[ -n "$primary" ] || fail "node-1 did not become primary within the timeout. Most likely etcd has NO QUORUM — ensure the witness etcd (and any other members in ETCD_INITIAL_CLUSTER) are up and reachable, then check: docker logs taranac-db"

echo "ha-convert: done — node-1 is the primary. NOW issue a join token and run ha-join.sh on each other node:"
echo "    ./taranac cluster join-token --name node-2 --address <addr>"
echo "    # then on node-2:  MASTER_KEY=<key> ./ha-join.sh --node-name node-2 --node-address <addr> --join-token <secret>"
