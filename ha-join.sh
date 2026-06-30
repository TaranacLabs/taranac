#!/usr/bin/env bash
# ha-join.sh — join THIS host to an existing Taranac HA cluster as a new node
# (docs/guide/ha.md §10.1). Patroni does the heavy lifting: with an empty data
# volume and the cluster already in the DCS, Patroni CLONES this node from the
# current primary (its own basebackup/pg_rewind) and streams it — there is NO
# manual pg_basebackup here (that was the Phase-1 path; two replication mechanisms
# would fight). This script is the thin orchestration around it:
#
#   1. Refuse unless this is a clean target (empty PGDATA) and you supplied
#      MASTER_KEY out-of-band + a join token (the license gate was enforced when
#      the token was issued on the primary).
#   2. Refuse a 2-node cluster with no witness — etcd must have >= 3 voting members
#      (the DB nodes + a separate-failure-domain arbiter), else a partition has no
#      quorum and failover is unsafe (ha.md §8). MANDATORY, not optional.
#   3. Provision identity (TARANAC_NODE_NAME/NODE_ADDRESS/ETCD_NAME) + MASTER_KEY
#      into .env, then bring up the stack WITH the HA overlay → Patroni clones this
#      node as a streaming replica.
#   4. Redeem the join token so the node registers its cluster_nodes row.
#
# Prerequisite: run `./install.sh --no-start` on this host first — it writes .env
# WITHOUT starting a standalone stack (a started standalone would initialise the data
# volume and trip this script's empty-volume guard). Then COPY the cluster-wide HA
# settings from the primary's .env into this .env BEFORE running this script — the
# same on every node:
#   TARANAC_CLUSTER_NAME, DB_HOSTS, ETCD_HOSTS, ETCD_INITIAL_CLUSTER,
#   POSTGRES_PASSWORD, POSTGRES_REPLICATION_PASSWORD, PG_ALLOW_CIDR
# (POSTGRES_PASSWORD/REPLICATION must MATCH the primary — they are the cluster's
# app + replication credentials.)
#
# Usage (on the NEW node, from the bundle dir):
#   MASTER_KEY=<the cluster master key>  \
#   ./ha-join.sh --node-name node-2 --node-address 10.0.0.2 --join-token <secret>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ENV_FILE=.env
COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

NODE_NAME=""; NODE_ADDRESS=""; JOIN_TOKEN=""; ETCD_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node-name)    NODE_NAME="$2"; shift 2 ;;
    --node-address) NODE_ADDRESS="$2"; shift 2 ;;
    --join-token)   JOIN_TOKEN="$2"; shift 2 ;;
    --etcd-name)    ETCD_NAME="$2"; shift 2 ;;   # defaults to the node name
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"

fail() { echo "ha-join: $*" >&2; exit 1; }
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- ; }
setenv() {  # set or replace KEY=VALUE in .env
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    # in-place, value may contain / and & — use a safe delimiter and escape
    local esc; esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ── Guards ───────────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — run './install.sh --no-start' on this node first (it writes .env without starting a standalone stack, so the data volume stays empty for the clone)."
[ -n "$NODE_NAME" ]    || fail "missing --node-name (this node's unique cluster name)"
[ -n "$NODE_ADDRESS" ] || fail "missing --node-address (this node's routable host/IP the other nodes reach)"
[ -n "$JOIN_TOKEN" ]   || fail "missing --join-token (issue it on the primary: ./taranac cluster join-token --name ${NODE_NAME} --address ${NODE_ADDRESS})"
[ -n "${MASTER_KEY:-}" ] || fail "MASTER_KEY must be provided out-of-band (env). It is NEVER replicated as data; the wrong/missing key makes every stored secret undecryptable."

# Cluster-wide HA settings must already be copied from the primary's .env.
for k in TARANAC_CLUSTER_NAME DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER POSTGRES_REPLICATION_PASSWORD; do
  [ -n "$(getenv "$k")" ] || fail "$k is not set in .env — copy the cluster-wide HA settings from the primary's .env first (see this script's header)."
done

# ── Witness guard (ha.md §8) — REFUSE a 2-node cluster with no arbiter ────────
# etcd must have >= 3 voting members. For 2 DB nodes that means a 3rd arbiter in a
# SEPARATE failure domain. We can verify the COUNT here; the separate-domain part
# is a runbook MUST (a co-located arbiter is useless).
MEMBERS=$(getenv ETCD_INITIAL_CLUSTER); MCOUNT=$(printf '%s' "$MEMBERS" | tr ',' '\n' | grep -c '=')
[ "$MCOUNT" -ge 3 ] || fail "ETCD_INITIAL_CLUSTER lists $MCOUNT etcd member(s); HA REQUIRES >= 3 (the DB nodes + a witness arbiter in a SEPARATE failure domain). A 2-node cluster without a witness cannot reach quorum on a partition → split-brain (ha.md §8). Add a 3rd etcd member before joining."

# ── Directionality / overwrite guard: the DB data volume must be EMPTY ────────
# A joining node is CLONED by Patroni into a clean volume; a populated volume means
# this host already holds data and must not be re-bootstrapped as a replica.
PG_VOLUME="$(docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.ha.yml config --volumes 2>/dev/null | grep -E '^pg_data$' || true)"
VOL="taranac_pg_data"   # compose project `taranac` + volume `pg_data`
if docker volume inspect "$VOL" >/dev/null 2>&1 && \
   [ -n "$(docker run --rm -v "${VOL}:/d" postgres:16-alpine sh -c 'ls -A /d 2>/dev/null')" ]; then
  fail "Postgres volume '${VOL}' is NOT empty. A joining node must start from a CLEAN volume (Patroni clones it from the primary). If you really mean to re-seed this node, remove the volume first (DESTROYS its data): docker volume rm ${VOL}"
fi

echo "ha-join: joining '${NODE_NAME}' (${NODE_ADDRESS}) to cluster '$(getenv TARANAC_CLUSTER_NAME)'…"

# ── Provision this node's identity + MASTER_KEY into .env ─────────────────────
setenv TARANAC_NODE_NAME "$NODE_NAME"
setenv NODE_ADDRESS "$NODE_ADDRESS"
setenv ETCD_NAME "$ETCD_NAME"
setenv MASTER_KEY "$MASTER_KEY"
# Authoritative HA marker — the bundle tooling (./taranac, install.sh, taranac-update.sh)
# reads this to ALWAYS merge docker-compose.ha.yml on this node (never base-only, which
# would start a 2nd writable Postgres on the Patroni PGDATA → split-brain). ha.md §13 A.
setenv TARANAC_HA 1

# ── Bring up the stack WITH the HA overlay → Patroni clones this node ─────────
echo "ha-join: starting the stack with the HA overlay (Patroni will clone this node from the primary)…"
${COMPOSE} pull >/dev/null 2>&1 || true
${COMPOSE} up -d

# ── Wait until the local Postgres is a streaming replica ─────────────────────
echo "ha-join: waiting for Patroni to clone + stream this node…"
streaming=""
for _ in $(seq 1 60); do
  if docker exec taranac-db psql -U taranac -d taranac -tAc "select pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
    streaming=1; break
  fi
  sleep 5
done
[ -n "$streaming" ] || fail "this node did not come up as a streaming replica within the timeout. Check: docker logs taranac-db (Patroni), the primary is reachable on DB_HOSTS, and POSTGRES_REPLICATION_PASSWORD matches the primary."

# ── Redeem the join token so the node registers in the roster ────────────────
echo "ha-join: redeeming the join token…"
for _ in $(seq 1 30); do
  if ${COMPOSE} exec -T api python -m app.scripts.cluster register --token "${JOIN_TOKEN}" 2>/dev/null; then
    echo "ha-join: done. Verify with: ./taranac cluster status"
    exit 0
  fi
  sleep 3
done
fail "the node is streaming but the token redeem did not complete. Once the api is up, run:
       ./taranac cluster register --token ${JOIN_TOKEN}"
