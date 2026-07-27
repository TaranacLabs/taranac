#!/usr/bin/env bash
# ha-deconvert.sh — the REVERSE of the HA lifecycle, in two guarded modes
# (docs/guide/ha.md §10.2). It codifies the manual runbooks exercised on the stand so
# they become one command each instead of a hand-typed sequence you can get wrong.
#
#   ./ha-deconvert.sh                                   # (A) shrink THIS node back to standalone
#   ./ha-deconvert.sh --decommission-dead \             # (B) remove a DEAD node from the live cluster
#       --node-name node-2 --node-address 10.0.0.2
#
# ── (A) shrink-to-standalone ──────────────────────────────────────────────────
# Turn the surviving single node back into a plain (non-HA) install. It stops the HA
# overlay, strips the HA markers from .env, brings the stack up on the BASE compose so
# the standalone Postgres image ADOPTS the Patroni PGDATA in place (symmetric to
# ha-convert, no re-init — same stock /var/lib/postgresql/data layout, async repl so no
# sync-standby wait), drops the now-orphan replication slots + resets
# synchronous_standby_names, and removes the orphan etcd data volume.
# REQUIRES this node to be the PRIMARY and the LAST node (no replicas still streaming) —
# shrinking a replica would strand it read-only, and shrinking with live replicas would
# orphan them (their DB_HOSTS still points here but HA, and the primary they clone from,
# is gone). Decommission/stop the other nodes FIRST (mode B, then physically wipe them).
#
# ── (B) decommission a DEAD node ──────────────────────────────────────────────
# A node died permanently and you want it out of the still-HA cluster cleanly: soft-delete
# its roster row, remove it from etcd membership, and prune it from THIS node's .env
# topology lists. Run it on a SURVIVING node. Then run the same command on every OTHER
# surviving node so their .env lists match (etcd + roster are cluster-wide and only need
# it once; the .env prune is per-node). Warns if the remaining etcd voting count is EVEN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ENV_FILE=.env
BASE_COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml"
HA_COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

MODE="shrink"; NODE_NAME=""; NODE_ADDRESS=""; ASSUME_YES=""; FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --decommission-dead) MODE="decommission-dead"; shift ;;
    --node-name)         NODE_NAME="$2"; shift 2 ;;
    --node-address)      NODE_ADDRESS="$2"; shift 2 ;;
    --yes|-y)            ASSUME_YES=1; shift ;;
    --force)             FORCE=1; shift ;;
    -h|--help)           sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "ha-deconvert: $*" >&2; exit 1; }
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- ; }
setenv() {  # set or replace KEY=VALUE in .env
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    local esc; esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}
delenv() { sed -i "/^$1=.*/d" "$ENV_FILE"; }   # remove a KEY= line entirely

confirm() {  # $1 = prompt
  [ -z "$ASSUME_YES" ] || return 0
  printf '%s [y/N] ' "$1"
  local reply; read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) fail "aborted." ;; esac
}

# Is THIS node the primary (Patroni leader)? pg_is_in_recovery()=false ⇒ primary.
am_i_primary() {
  docker exec taranac-db psql -U taranac -d taranac -tAc 'select not pg_is_in_recovery()' 2>/dev/null | grep -qi t
}

# Remove one element from a comma-separated list. $1 = list, $2 = exact item to drop.
prune_csv() {
  local list="$1" drop="$2" out="" tok
  local IFS=,
  for tok in $list; do
    [ -n "$tok" ] || continue
    [ "$tok" = "$drop" ] && continue
    out="${out:+$out,}$tok"
  done
  printf '%s' "$out"
}

# Remove the `name=...` element (any scheme/addr) from an ETCD_INITIAL_CLUSTER string.
prune_member_by_name() {
  local list="$1" name="$2" out="" tok
  local IFS=,
  for tok in $list; do
    [ -n "$tok" ] || continue
    [ "${tok%%=*}" = "$name" ] && continue
    out="${out:+$out,}$tok"
  done
  printf '%s' "$out"
}

# A reachable etcd endpoint (skip a given address), honouring client-TLS. Echoes
# "scheme://host:port" or empty. Sets ETCDCTL_MOUNT / ETCDCTL_TLS_ARGS as a side effect.
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.17"
ETCDCTL_MOUNT=""; ETCDCTL_TLS_ARGS=""
etcd_client_setup() {
  local scheme; scheme="$(getenv ETCD_CLIENT_SCHEME)"; scheme="${scheme:-http}"
  ETCD_SCHEME="$scheme"
  if [ "$scheme" = https ]; then
    local tls="$HERE/config/etcd-tls"
    [ -s "$tls/ca.crt" ] || fail "etcd client-TLS is on (ETCD_CLIENT_SCHEME=https) but $tls/ca.crt is missing — cannot talk to etcd to remove the member."
    ETCDCTL_MOUNT="-v $tls:/tls:ro"; ETCDCTL_TLS_ARGS="--cacert=/tls/ca.crt"
  fi
}
etcd_reachable_endpoint() {  # $1 = address to skip (the dead one)
  local skip="$1" hp ep=""
  for hp in $(getenv ETCD_HOSTS | tr ',' ' '); do
    case "$hp" in *"${skip}"*) continue ;; esac
    if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" \
         etcdctl --endpoints="${ETCD_SCHEME}://${hp}" $ETCDCTL_TLS_ARGS endpoint health >/dev/null 2>&1; then
      ep="${ETCD_SCHEME}://${hp}"; break
    fi
  done
  printf '%s' "$ep"
}

# ── Shared guards ─────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — run this from the bundle directory of an HA node."
[ "$(getenv TARANAC_HA)" = "1" ] || fail "this node is not marked HA (TARANAC_HA=1 is absent in .env). ha-deconvert operates on a converted HA node; there is nothing to undo on a standalone install."

# ══════════════════════════════════════════════════════════════════════════════
# (B) Decommission a DEAD node
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "decommission-dead" ]; then
  [ -n "$NODE_NAME" ] || fail "--node-name <the dead node's cluster name> is required for --decommission-dead."
  echo "ha-deconvert: decommissioning DEAD node '${NODE_NAME}'${NODE_ADDRESS:+ (${NODE_ADDRESS})} from cluster '$(getenv TARANAC_CLUSTER_NAME)'."
  echo "  This removes it from the roster + etcd membership and prunes it from THIS node's .env topology."
  echo "  ⚠  Run the SAME command on every other surviving node too (the .env prune is per-node)."
  confirm "Proceed?"

  # 1) Roster soft-delete (routes to the primary via the api's DB_HOSTS). Non-fatal if the
  #    row is already gone — this step is idempotent and we still want etcd/.env cleaned.
  echo "ha-deconvert: soft-deleting the roster row…"
  if "$HERE/taranac" cluster decommission --name "$NODE_NAME"; then :; else
    echo "ha-deconvert:   (roster decommission returned non-zero — perhaps already decommissioned; continuing with etcd + .env cleanup.)" >&2
  fi

  # 2) etcd member remove — the dead member's key never expires on its own (it is a voting
  #    member, not a lease), so it must be removed or it drags quorum math down forever.
  etcd_client_setup
  local_ep="$(etcd_reachable_endpoint "${NODE_ADDRESS:-__none__}")"
  if [ -z "$local_ep" ]; then
    echo "ha-deconvert: ⚠  no reachable etcd endpoint found — SKIPPING etcd member remove. Remove it by hand once etcd is reachable:" >&2
    echo "    docker run --rm $ETCDCTL_MOUNT $ETCD_IMAGE etcdctl --endpoints=${ETCD_SCHEME}://<a-live-etcd>:2379 $ETCDCTL_TLS_ARGS member list" >&2
    echo "    # find the '${NODE_NAME}' row, then: … member remove <hex-id>" >&2
  else
    mid="$(docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$local_ep" $ETCDCTL_TLS_ARGS member list 2>/dev/null \
            | awk -F',' -v n="$NODE_NAME" '{name=$3; gsub(/^[ \t]+|[ \t]+$/,"",name); if(name==n){id=$1; gsub(/ /,"",id); print id}}')"
    if [ -n "$mid" ]; then
      echo "ha-deconvert: removing etcd member '${NODE_NAME}' (id ${mid})…"
      docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$local_ep" $ETCDCTL_TLS_ARGS member remove "$mid" >/dev/null \
        || echo "ha-deconvert: ⚠  etcdctl member remove failed — remove it by hand (member id ${mid} via ${local_ep})." >&2
    else
      echo "ha-deconvert:   no etcd member named '${NODE_NAME}' (already removed?) — skipping."
    fi
  fi

  # 3) Prune THIS node's .env topology lists.
  echo "ha-deconvert: pruning '${NODE_NAME}' from this node's .env topology…"
  setenv ETCD_INITIAL_CLUSTER "$(prune_member_by_name "$(getenv ETCD_INITIAL_CLUSTER)" "$NODE_NAME")"
  if [ -n "$NODE_ADDRESS" ]; then
    setenv DB_HOSTS   "$(prune_csv "$(getenv DB_HOSTS)"   "${NODE_ADDRESS}:5432")"
    setenv ETCD_HOSTS "$(prune_csv "$(getenv ETCD_HOSTS)" "${NODE_ADDRESS}:2379")"
  else
    echo "ha-deconvert:   (no --node-address given — pruned ETCD_INITIAL_CLUSTER by name only. Edit DB_HOSTS/ETCD_HOSTS by hand to drop the dead node's host:port.)" >&2
  fi

  # 4) Even-quorum warn — an even voting count tolerates the SAME failures as one fewer
  #    (2 tolerates 0, 4 tolerates 1) while doubling the surfaces that can fail.
  members="$(getenv ETCD_INITIAL_CLUSTER)"; mcount="$(printf '%s' "$members" | tr ',' '\n' | grep -c '=' || true)"
  echo "ha-deconvert: etcd now has ${mcount} member(s) in this .env."
  if [ "$mcount" -lt 3 ]; then
    echo "ha-deconvert: ⚠  fewer than 3 etcd members — a 2-node cluster cannot fail over safely (§8). Add a replacement node or a witness arbiter." >&2
  elif [ $((mcount % 2)) -eq 0 ]; then
    echo "ha-deconvert: ⚠  an EVEN number of etcd voting members (${mcount}) — it tolerates no more failures than ${mcount} minus 1 while adding failure surface. Prefer an odd count (add/remove one member or a witness)." >&2
  fi
  echo "ha-deconvert: done. Re-run this on every OTHER surviving node so their .env matches, then restart them so etcd picks up the shrunk membership."
  echo "ha-deconvert: if '${NODE_NAME}' ever returns, WIPE its pg_data + etcd_data volumes before re-joining (ha-join guards this, #32)."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# (A) Shrink this node back to standalone
# ══════════════════════════════════════════════════════════════════════════════
echo "ha-deconvert: SHRINK — turning this node back into a standalone (non-HA) install."

# Must be the PRIMARY: a replica has no independent writable data and would come up
# read-only waiting for a primary that is going away.
if ! am_i_primary; then
  [ -n "$FORCE" ] || fail "this node is NOT the primary (or its DB is unreachable). Shrink the PRIMARY, not a replica — a replica would come up read-only. Run this on the primary, or pass --force if you are certain this node holds the authoritative data."
  echo "ha-deconvert: ⚠  --force: proceeding though this node does not look like the primary." >&2
fi

# Must be the LAST node: refuse if replicas are still streaming from us, else they get
# orphaned (their DB_HOSTS/clone source vanishes). pg_stat_replication is the ground truth.
streamers="$(docker exec taranac-db psql -U taranac -d taranac -tAc \
  "select count(*) from pg_stat_replication where state is not null" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$streamers" ] && [ "$streamers" != "0" ]; then
  [ -n "$FORCE" ] || fail "${streamers} replica(s) are still streaming from this node. Shrinking now would orphan them. Decommission + physically tear down the other nodes FIRST (./ha-deconvert.sh --decommission-dead … on a survivor, then stop + wipe each departing node), then re-run. Pass --force to override (the other nodes will be left stranded)."
  echo "ha-deconvert: ⚠  --force: shrinking with ${streamers} replica(s) still attached — they will be orphaned." >&2
fi

echo "ha-deconvert: ⚠  Back up first (in-app Backup & Recovery). This stops HA and adopts the Patroni data dir into the standalone Postgres image in place."
confirm "Shrink this node to standalone now?"

# 1) Stop the HA stack (Patroni + etcd + app) — keep volumes.
echo "ha-deconvert: stopping the HA overlay stack…"
${HA_COMPOSE} down || fail "could not bring the HA stack down. Resolve the docker error and retry."

# 2) Strip the HA markers from .env so the bundle tooling stops merging the overlay.
#    TARANAC_HA (the authoritative marker) and DB_HOSTS (the discriminator) are what flip
#    ./taranac + install.sh + taranac-update.sh back to base-only; the ETCD_* keys are
#    HA-only and blanked for tidiness (inert on the base compose anyway).
echo "ha-deconvert: removing the HA markers from .env…"
delenv TARANAC_HA
setenv DB_HOSTS ""
for k in ETCD_HOSTS ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE ETCD_NAME \
         ETCD_PEER_SCHEME ETCD_PEER_AUTO_TLS ETCD_CLIENT_SCHEME \
         ETCD_SERVER_CERT_FILE ETCD_SERVER_KEY_FILE ETCD_CLIENT_CACERT; do
  grep -qE "^${k}=" "$ENV_FILE" && setenv "$k" ""
done

# 3) Bring the stack up on the BASE compose — the standalone Postgres image adopts the
#    existing PGDATA in place (same /var/lib/postgresql/data layout as the HA image).
echo "ha-deconvert: starting the stack on the base compose (standalone Postgres adopts the data dir)…"
${BASE_COMPOSE} pull >/dev/null 2>&1 || true
${BASE_COMPOSE} up -d

# Wait until Postgres is up and WRITABLE (adopted as a plain primary).
echo "ha-deconvert: waiting for the standalone database to accept writes…"
writable=""
for _ in $(seq 1 60); do
  if docker exec taranac-db psql -U taranac -d taranac -tAc 'select not pg_is_in_recovery()' 2>/dev/null | grep -qi t; then
    writable=1; break
  fi
  sleep 5
done
[ -n "$writable" ] || fail "the standalone database did not come up writable within the timeout. Check: docker logs taranac-db (it should NOT be in recovery). The HA markers are already removed from .env; once it is healthy this node is standalone."

# 4) Drop the now-orphan physical replication slots (the departed replicas' Patroni slots)
#    and reset synchronous_standby_names, so nothing pins WAL or waits on a gone standby.
echo "ha-deconvert: dropping orphan replication slots + resetting synchronous_standby_names…"
docker exec taranac-db psql -U taranac -d taranac -tAc \
  "select pg_drop_replication_slot(slot_name) from pg_replication_slots where slot_type='physical'" >/dev/null 2>&1 || true
docker exec taranac-db psql -U taranac -d taranac -tAc "alter system reset synchronous_standby_names" >/dev/null 2>&1 || true
docker exec taranac-db psql -U taranac -d taranac -tAc "select pg_reload_conf()" >/dev/null 2>&1 || true

# 5) Remove the orphan etcd data volume (etcd no longer runs; a stale volume would trip
#    ha-join's #32 guard if this node is ever re-converted/joined later).
if docker volume inspect taranac_etcd_data >/dev/null 2>&1; then
  echo "ha-deconvert: removing the orphan etcd data volume…"
  docker volume rm taranac_etcd_data >/dev/null 2>&1 \
    || echo "ha-deconvert: ⚠  could not remove taranac_etcd_data (a container may still reference it). Remove it manually: docker volume rm taranac_etcd_data" >&2
fi

echo
echo "ha-deconvert: ✅ done — this node is now a STANDALONE install (HA removed)."
echo "  • The etcd CA / leaf / cluster-secret material under config/ is left in place (harmless); delete it if you want a clean standalone."
echo "  • The witness host is no longer needed — stop it (docker-compose.witness.yml down) and reclaim it."
echo "  • Any former replica nodes must be physically torn down + their volumes wiped (they hold a full DB copy + MASTER_KEY)."
