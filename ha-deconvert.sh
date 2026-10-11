#!/usr/bin/env bash
# ha-deconvert.sh — the REVERSE of the HA lifecycle, in two guarded modes
# (docs/ops/ha.md). It codifies the manual runbooks exercised on the stand so
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
# REQUIRES this node to be the PRIMARY and the LAST database node — no other member in the
# live etcd ring or the node roster (a STOPPED replica is still a member), and none streaming —
# shrinking a replica would strand it read-only, and shrinking with live replicas would
# orphan them (their DB_HOSTS still points here but HA, and the primary they clone from,
# is gone). Take every other node out FIRST: ./taranac cluster remove-node --node <name>.
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
# A death under `set -e` prints where it happened, and a container compose left
# under a temporary name is renamed back before anything addresses it by name.
# Guarded: a bundle caught half-updated must still run (container-names.sh).
if [ -f "$HERE/container-names.sh" ]; then
  . "$HERE/container-names.sh"
  loud_death "ha-deconvert.sh"
  heal_container_names
fi
ENV_FILE=.env
BASE_COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml"
HA_COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

MODE="shrink"; NODE_NAME=""; NODE_ADDRESS=""; ASSUME_YES=""; FORCE=""; CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --decommission-dead) MODE="decommission-dead"; shift ;;
    --abandon)           MODE="abandon"; shift ;;
    --node-name)         NODE_NAME="$2"; shift 2 ;;
    --node-address)      NODE_ADDRESS="$2"; shift 2 ;;
    --yes|-y)            ASSUME_YES=1; shift ;;
    --force)             FORCE=1; shift ;;
    --confirm)           CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)           sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "ha-deconvert: $*" >&2; exit 1; }
# An ABSENT key is an empty value, not an error. Without `|| true` this pipeline exits 1
# when grep matches nothing, and under `set -euo pipefail` a bare assignment —
# VAR="$(getenv MISSING)" — then kills the script SILENTLY, before it prints anything.
# rotate-key.sh:157 already works around this per-call; fixed here at the source.
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true ; }
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

# One topology change at a time, cluster-wide: the update's lock in etcd
# (cluster-versions.sh) — a node added while this shrink reads the ring would be
# stranded by it.
TOPOLOGY_LOCKED=""
topology_lock() {  # <op>
  [ -z "${TARANAC_TOPOLOGY_LOCK_HELD:-}" ] || return 0
  [ -f "$HERE/cluster-versions.sh" ] || return 0
  # shellcheck source=cluster-versions.sh
  . "$HERE/cluster-versions.sh"
  cv_init "$HERE" "$ENV_FILE" db
  cv_topology_lock "$1" || fail "another command is changing this cluster right now: ${CV_LOCK_HOLDER}.
  Nothing was changed. Run this again once it has finished (if that command died, the lock
  frees itself within ${CV_LOCK_TTL_S}s)."
  [ -z "${CV_TOPOLOGY_NOTE}" ] || echo "ha-deconvert: ⚠  ${CV_TOPOLOGY_NOTE}" >&2
  TOPOLOGY_LOCKED=1
  export TARANAC_TOPOLOGY_LOCK_HELD=1
  trap 'topology_unlock' EXIT
}
topology_unlock() {
  [ -n "${TOPOLOGY_LOCKED}" ] || return 0
  TOPOLOGY_LOCKED=""
  cv_lock_release >/dev/null 2>&1 || true
  unset TARANAC_TOPOLOGY_LOCK_HELD
}

# ══════════════════════════════════════════════════════════════════════════════
# (C) --abandon: a cluster declared here that this node never became part of
# ══════════════════════════════════════════════════════════════════════════════
# The seed between `cluster init` and `add-witness`, or a joiner whose ha-join.sh
# stopped before its last step: .env declares the cluster, TARANAC_HA=1 was never
# written, and neither Patroni nor etcd has run here — so the data directory is still
# a standalone one (the seed's own, or the joiner's fresh one). Going back is only
# taking the declaration out of .env; nothing else was changed to undo.
if [ "$MODE" = abandon ]; then
  [ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — run this from the bundle directory of the node."
  [ "$(getenv TARANAC_HA)" != "1" ] || fail "this node IS a cluster member (TARANAC_HA=1) — --abandon is only for a join or an init that never finished.
  To take a member out:  ./taranac cluster remove-node --node <name>  (on a database node)
  To shrink the last database node back to standalone:  ./ha-deconvert.sh"
  [ -n "$(getenv DB_HOSTS)$(getenv ETCD_INITIAL_CLUSTER)" ] || fail "this node declares no cluster in .env — it is standalone already. Start it:  ./taranac up -d"
  if docker volume inspect taranac_etcd_data >/dev/null 2>&1; then
    fail "etcd has already run on this node (docker volume taranac_etcd_data), so its database may
  already be Patroni's — this is past what --abandon can undo. Nothing was changed.
  Finish what was started instead — on the seed:  ./taranac cluster add-witness --address <the witness>
  — or ask:  ./taranac diagnose --ha"
  fi
  echo "ha-deconvert: ABANDON — taking the unfinished cluster declaration out of this node's .env."
  confirm "Run this node standalone again?"
  cp -a "$ENV_FILE" "${ENV_FILE}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  setenv DB_HOSTS ""
  for k in ETCD_HOSTS ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE ETCD_NAME \
           ETCD_PEER_SCHEME ETCD_PEER_AUTO_TLS ETCD_CLIENT_SCHEME \
           ETCD_SERVER_CERT_FILE ETCD_SERVER_KEY_FILE ETCD_CLIENT_CACERT \
           TARANAC_CLUSTER_ID TARANAC_CLUSTER_FORMED_AT; do
    grep -qE "^${k}=" "$ENV_FILE" && setenv "$k" ""
  done
  if [ -f config/cluster.yml ]; then
    mv config/cluster.yml "config/cluster.yml.abandoned-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  echo "ha-deconvert: ✅ the declaration is gone (previous .env kept as ${ENV_FILE}.bak-*). Start the node:"
  echo "    ./taranac up -d"
  echo "  If a witness host was already set up for this cluster, on THAT host:"
  echo "    ./witness-join.sh --leave --confirm NOT-A-MEMBER"
  exit 0
fi

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
  topology_lock decommission-dead

  # 1) etcd member remove FIRST — the dead member's key never expires on its own (it is
  #    a voting member, not a lease), so it must be removed or it drags quorum math down
  #    forever. First, because the roster step below is refused while the node is still
  #    a ring member: the backend will not drop the row of a machine the ring counts.
  etcd_client_setup
  # A node that answers is not dead: taking a LIVE member out by this path skips every
  # guard remove-node has (the leader, the quorum left). Said, not done.
  if [ -n "$NODE_ADDRESS" ] && docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" \
       etcdctl --endpoints="${ETCD_SCHEME}://${NODE_ADDRESS}:2379" $ETCDCTL_TLS_ARGS endpoint health >/dev/null 2>&1; then
    fail "'${NODE_NAME}' (${NODE_ADDRESS}) answers — it is not dead. Nothing was changed.
  Take a live node out with the command that checks the leader and the quorum first:
    ./taranac cluster remove-node --node ${NODE_NAME}"
  fi
  local_ep="$(etcd_reachable_endpoint "${NODE_ADDRESS:-__none__}")"
  if [ -z "$local_ep" ]; then
    fail "no reachable etcd endpoint — the dead node cannot be taken out of the ring from here,
  and nothing was changed. Bring a surviving member's etcd back (./taranac up -d etcd),
  check it with ./taranac cluster status, then run the same command again."
  fi
  mid="$(docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$local_ep" $ETCDCTL_TLS_ARGS member list 2>/dev/null \
          | awk -F',' -v n="$NODE_NAME" '{name=$3; gsub(/^[ \t]+|[ \t]+$/,"",name); if(name==n){id=$1; gsub(/ /,"",id); print id}}')"
  if [ -n "$mid" ]; then
    echo "ha-deconvert: removing etcd member '${NODE_NAME}' (id ${mid})…"
    docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$local_ep" $ETCDCTL_TLS_ARGS member remove "$mid" >/dev/null \
      || fail "etcdctl member remove failed for '${NODE_NAME}' (id ${mid}) via ${local_ep}. Nothing else was changed; retry once etcd is healthy."
  else
    echo "ha-deconvert:   no etcd member named '${NODE_NAME}' (already removed?) — skipping."
  fi

  # 2) Roster soft-delete (routes to the primary via the api's DB_HOSTS). Non-fatal if the
  #    row is already gone — this step is idempotent and we still want .env cleaned.
  echo "ha-deconvert: soft-deleting the roster row…"
  if "$HERE/taranac" cluster decommission --name "$NODE_NAME" --evicted; then :; else
    echo "ha-deconvert:   (roster decommission returned non-zero — read the reason above; continuing with the .env cleanup.)" >&2
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
  [ -n "$FORCE" ] || fail "this node is NOT the primary (or its DB is unreachable). Shrink the PRIMARY, not a replica — a replica would come up read-only. Run this on the primary, or pass --force if you are certain this node holds the authoritative data.
  (The last survivor of a cluster whose other machines are gone for good is demoted by
  Patroni for lack of quorum — for it, the whole command is:
      ./ha-deconvert.sh --force --confirm NO-OTHER-NODES )"
  echo "ha-deconvert: ⚠  --force: proceeding though this node does not look like the primary." >&2
fi

# ── Must be the LAST database node — asked of the RING and the ROSTER ──────────
# 🔑 pg_stat_replication alone is not the answer, and that cost a split-brain (seen
# live on 1.3.2-rc2): a replica that is merely STOPPED does not stream, so the old
# check waved the shrink through; the replica came back, found itself and the witness
# — two of the three members of the ring this node had just left — elected itself,
# and promoted. Two writable databases, one password, the roster still routing writes
# to both. A stopped member is still a member: what decides is the ring and the roster.
#
# The witness may stay: alone it holds one vote of two and can promote nothing. Every
# OTHER database member must be taken out first, by the command that does it properly.
# --force does not waive this; only an explicit, typed statement that the ring is gone
# does, and only when the ring cannot be read at all.
topology_lock deconvert
self_name="$(getenv ETCD_NAME)"; [ -n "$self_name" ] || self_name="$(getenv TARANAC_NODE_NAME)"
self_addr="$(getenv NODE_ADDRESS)"
ring_rows=""
if ring_rows="$(docker exec taranac-etcd etcdctl member list 2>/dev/null)" && [ -n "$ring_rows" ]; then :; else
  ring_rows=""
  etcd_client_setup
  ring_ep="$(etcd_reachable_endpoint "__none__")"
  if [ -n "$ring_ep" ]; then
    ring_rows="$(docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$ring_ep" $ETCDCTL_TLS_ARGS member list 2>/dev/null || true)"
  fi
fi
roster_rows="$(docker exec taranac-db psql -U taranac -d taranac -tA -F"$(printf '\t')" -c \
  "SELECT name, address FROM cluster_nodes WHERE status = 'active' AND address IS NOT NULL ORDER BY created_at" 2>/dev/null)" \
  || roster_rows="__unreadable__"
if [ -z "$ring_rows" ] || [ "$roster_rows" = "__unreadable__" ]; then
  if [ "$CONFIRM" != "NO-OTHER-NODES" ]; then
    fail "the $([ -z "$ring_rows" ] && echo 'etcd ring' || echo 'node roster') cannot be read from this node, so it cannot be
  checked that no other database node is still a member. Nothing was changed.
  A member that is only stopped comes back, finds the witness and promotes itself —
  two writable databases. Check the cluster first:
      ./taranac cluster status
  If every other machine of this cluster is gone for good (wiped, or never coming back),
  say so explicitly and run again:
      ./ha-deconvert.sh${FORCE:+ --force} --confirm NO-OTHER-NODES"
  fi
  echo "ha-deconvert: ⚠  --confirm NO-OTHER-NODES: the ring/roster could not be read; proceeding on your word." >&2
else
  others=""
  # Ring members other than this node. One that matches an active roster row (by name
  # or by address) is a database node; one that matches none is the witness — the rule
  # remove-node and the backend use.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    m_name="$(printf '%s' "$line" | awk -F', ' '{print $3}')"
    m_peer="$(printf '%s' "$line" | awk -F', ' '{print $4}')"; m_peer="${m_peer#*://}"; m_peer="${m_peer%:*}"
    { [ -n "$m_name" ] && [ "$m_name" = "$self_name" ]; } && continue
    [ -n "$self_addr" ] && [ "$m_peer" = "$self_addr" ] && continue
    if [ -z "$m_name" ] || printf '%s\n' "$roster_rows" | awk -F'\t' -v n="$m_name" -v a="$m_peer" '$1 == n || $2 == a { f = 1 } END { exit !f }'; then
      others="${others}${m_name:-unstarted}	${m_peer}
"
    fi
  done <<RING
${ring_rows}
RING
  # Active roster rows other than this node that the ring does not hold: a member whose
  # etcd entry was removed by hand, or a stale name. Either way remove-node clears it.
  while IFS="$(printf '\t')" read -r r_name r_addr; do
    [ -n "$r_name" ] || continue
    { [ "$r_name" = "$(getenv TARANAC_NODE_NAME)" ] || [ "$r_addr" = "$self_addr" ]; } && continue
    printf '%s' "$others" | awk -F'\t' -v n="$r_name" '$1 == n { f = 1 } END { exit !f }' && continue
    others="${others}${r_name}	${r_addr}
"
  done <<ROSTER
${roster_rows}
ROSTER
  if [ -n "$others" ]; then
    echo "ha-deconvert: refusing — this cluster still has other database node(s):" >&2
    # A refusal is not a failure: every loop body below ends in a command that succeeds,
    # or the pipeline's status trips `set -e` and the ERR trap calls it "unexpected".
    while IFS="$(printf '\t')" read -r o_name o_addr; do
      if [ -n "$o_name" ]; then printf '    %-24s %s\n' "$o_name" "$o_addr" >&2; fi
    done <<OTHERS
${others}
OTHERS
    echo "  Nothing was changed. A member that is only stopped is still a member: when it comes" >&2
    echo "  back it finds the witness, holds two votes of three and promotes itself — and this" >&2
    echo "  node would be a second writable database next to it (split-brain)." >&2
    echo "  Take each one out of the cluster first, here on this node, then run this again:" >&2
    while IFS="$(printf '\t')" read -r o_name _a; do
      case "$o_name" in
        "")        ;;
        unstarted) echo "      ./taranac cluster remove-node --address ${_a}" >&2 ;;
        *)         echo "      ./taranac cluster remove-node --node ${o_name}" >&2 ;;
      esac
    done <<OTHERS
${others}
OTHERS
    echo "      ./ha-deconvert.sh" >&2
    exit 1
  fi
  echo "ha-deconvert: ✓ no other database node is in the ring or the roster."
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

# 0) A pending update finisher (taranac-update-finisher, left by an update that was
#    waiting for the leader's schema) would bring the HA stack back up the moment the
#    api turned healthy — undoing this. It goes first, and is said.
if docker inspect taranac-update-finisher >/dev/null 2>&1; then
  docker rm -f taranac-update-finisher >/dev/null 2>&1 || true
  echo "ha-deconvert: removed the pending update finisher (taranac-update-finisher) — it would have restarted the HA stack."
fi
# The ring is about to stop; the lock goes first, while etcd still answers.
topology_unlock
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
# TARANAC_CLUSTER_ID is in this list for a reason the others are not: clearing it
# is what makes a LATER rebuild a genuinely new cluster. etcd derives the ring's
# ClusterID from that token, so leaving the old value behind would hand the rebuilt
# cluster the identity of the one being dismantled here — and any machine still
# holding the old cluster's etcd data would rejoin it without a word.
for k in ETCD_HOSTS ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE ETCD_NAME \
         ETCD_PEER_SCHEME ETCD_PEER_AUTO_TLS ETCD_CLIENT_SCHEME \
         ETCD_SERVER_CERT_FILE ETCD_SERVER_KEY_FILE ETCD_CLIENT_CACERT \
         TARANAC_CLUSTER_ID TARANAC_CLUSTER_FORMED_AT; do
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
echo "  • The witness host is no longer needed. The ring it belonged to is gone, so on THAT host:"
echo "        ./witness-join.sh --leave --confirm NOT-A-MEMBER"
echo "  • EVERY OTHER MACHINE that was ever pointed at this cluster must be physically torn"
echo "    down and its volumes wiped — not only the nodes that became replicas."
echo "    A machine whose join FAILED never became a replica and is the one most often left"
echo "    standing, yet it already holds the cluster's key material and an etcd data volume."

# The machines, BY ADDRESS, read out of the manifest.
#
# The paragraph above used to be the whole of this advice, and it named a
# CATEGORY: "not only the nodes that became replicas". Nobody can act on a
# category. The operator has to recall which machines were ever pointed at this
# cluster — which is precisely the thing config/cluster.yml has been remembering
# for them all along, half-finished joins included, flagged `pending` by the
# wizard that started them. The one machine this advice exists for is the one
# they are most likely to have forgotten, so it is printed rather than described.
#
# NODE_ADDRESS is read here and not earlier because step 2 above leaves it alone
# (it strips the ETCD_* keys and the cluster id, not this node's own address),
# and config/cluster.yml is deliberately not deleted by the shrink.
self_addr="$(getenv NODE_ADDRESS)"
if [ -f config/cluster.yml ] && command -v python3 >/dev/null 2>&1; then
  manifest_rows="$(python3 ./cluster-manifest.py list --file config/cluster.yml 2>/dev/null || true)"
  pending_addrs="$(python3 ./cluster-manifest.py pending --file config/cluster.yml 2>/dev/null | cut -f2 || true)"
  listed=0
  while IFS="$(printf '\t')" read -r m_name m_addr m_role; do
    if [ -z "${m_addr}" ]; then continue; fi
    if [ "${m_addr}" = "${self_addr}" ]; then continue; fi
    if [ "${listed}" = 0 ]; then
      echo "    This cluster declared the machines below. Each one needs it:"
      listed=1
    fi
    m_note=""
    if printf '%s\n' "${pending_addrs}" | grep -qxF -- "${m_addr}"; then
      m_note="  ← its join never finished — the one most often left standing"
    fi
    printf '        %-15s  %-20s %s%s\n' "${m_addr}" "${m_name}" "${m_role}" "${m_note}"
  done <<MANIFEST
${manifest_rows}
MANIFEST
  if [ "${listed}" = 0 ]; then
    echo "    (config/cluster.yml declares no machine other than this one.)"
  fi
else
  echo "    ⚠  config/cluster.yml is not readable here, so the machines cannot be listed."
  echo "       Check your own records for every host that ever ran ha-join.sh or witness-join.sh."
fi
echo "    On each of them:"
echo "        ./taranac down  &&  docker volume rm taranac_pg_data taranac_etcd_data taranac_master_key"
echo "    (Under the OLD identity scheme a cluster rebuilt with the same name reproduced the"
echo "     same etcd ClusterID, and such a machine could rejoin the replacement in silence."
echo "     A cluster built from here on draws a fresh TARANAC_CLUSTER_ID, so it would now be"
echo "     refused — but it still holds this cluster's data and master key, which is reason"
echo "     enough to wipe it.)"
