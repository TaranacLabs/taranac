#!/usr/bin/env bash
# cluster-remove.sh — take a node OUT of the cluster, in the two shapes that exist.
#
#   ./cluster-remove.sh --node <name|address>        # on the PRIMARY: evict it
#   ./cluster-remove.sh --address <address>          # the same, said the other way
#   ./cluster-remove.sh --detach                     # on the NODE: become standalone
#
# WHY THIS EXISTS ALONGSIDE ha-deconvert.sh
# -----------------------------------------
# ha-deconvert already implements both halves and implements them correctly. What it
# cannot do is finish the job, and its own header admits it:
#
#     "Then run the same command on every OTHER surviving node so their .env lists match
#      (etcd + roster are cluster-wide and only need it once; the .env prune is per-node)."
#
# So today removing one node from a four-node cluster is four hand-typed commands on
# four machines, and forgetting one leaves that machine's DB_HOSTS pointing at a host
# that is gone. This script keeps ha-deconvert's proven mechanics and adds the part the
# wizard owes the operator: doing the remaining members' half for them, and refusing
# the removals that are unsafe rather than discovering them afterwards.
#
# ── (A) evict, on the primary ────────────────────────────────────────────────
# Refuses only ONE thing outright: evicting the CURRENT LEADER (switch over first — that
# is an outage you did not ask for, and the database it would clone from is the one it is
# serving). Everything else it REPORTS and asks about, because an operator who typed
# remove-node has a reason and the command's job is to make sure they are deciding with
# the real consequence in front of them — not to overrule them.
#
# The consequence of dropping below 3 etcd voters differs sharply by what is left, and one
# sentence cannot describe both:
#   · 1 database node + witness → NOT split-brain (nothing to split). A 2-member ring
#     needs BOTH for quorum, so losing the witness demotes the last database node to
#     read-only — strictly worse than plain standalone. The end state wanted here is
#     usually ./ha-deconvert.sh.
#   · 2 database nodes + no arbiter → the classic split-brain shape: on a partition
#     neither side holds a majority, so neither may promote and failover stops working.
# Then: etcd member remove, roster decommission, replication-slot cleanup, manifest
# update, and the .env prune on THIS node.
#
# ── (B) detach, on the node itself ───────────────────────────────────────────
# Turns a live replica back into a standalone install. Note what this actually is:
#
#     🔑 A DETACHED NODE KEEPS A FULL COPY OF EVERYTHING — every device secret, every
#        credential, every log — and with the same MASTER_KEY it is a complete, working
#        clone of the product. This is a database FORK, not a decommission.
#
# That is legitimate (salvaging data after losing the primary; splitting a lab) but it is
# not what "remove a node" sounds like, so the script says it out loud and requires the
# operator to type their acknowledgement. ha-deconvert's shrink mode deliberately refuses
# this case — it requires the node to be the PRIMARY and the LAST one — because shrinking
# a replica while the cluster still runs strands it read-only. We allow it, but only after
# the eviction in (A) has happened, which is what makes the node's local Postgres free to
# be promoted rather than stranded.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
# A death under `set -e` prints where it happened, and a container compose left
# under a temporary name is renamed back before anything addresses it by name.
# Guarded: a bundle caught half-updated must still run (container-names.sh).
if [ -f "$HERE/container-names.sh" ]; then
  . "$HERE/container-names.sh"
  loud_death "cluster-remove.sh"
  heal_container_names
fi
ENV_FILE=.env
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.17"

MODE=""; TARGET=""; ASSUME_YES=""; CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node)     MODE="evict"; TARGET="$2"; shift 2 ;;
    # --address is the same thing said the other way, and it is what several cure
    # texts in this product print (cluster-manifest's remedy among them). Refusing it
    # sends an operator who followed a printed instruction to "Unknown argument".
    --address)  MODE="evict"; TARGET="$2"; shift 2 ;;
    --detach)   MODE="detach"; shift ;;
    # Repeatable: a detach with no ring to ask needs two acknowledgements.
    --confirm)  CONFIRM="${CONFIRM:+${CONFIRM} }${2:-}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "cluster-remove: $*" >&2; exit 1; }
confirmed() { case " ${CONFIRM} " in *" $1 "*) return 0 ;; esac; return 1; }
say()  { printf '  %s\n' "$*"; }
step() { printf '  [%s] %s\n' "$1" "$2"; }
ok()   { printf '        ✓ %s\n' "$*"; }

# An ABSENT key is an empty value, not an error. Without the `|| true` this pipeline
# exits 1 when grep matches nothing, and under `set -euo pipefail` a bare assignment
# — VAR="$(getenv MISSING)" — then kills the script instantly and SILENTLY, before it
# has printed a single line. Found exactly that way: the detach path died with no
# output at all because ETCD_CLIENT_SCHEME is unset on a plaintext cluster.
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true ; }
setenv() {
  local k="$1" v="$2" esc
  if grep -qE "^${k}=" "$ENV_FILE"; then
    esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}
# Without a terminal there is nobody to answer. Reading /dev/tty then fails, the
# empty answer reads as "no", and the operator who ran this over `ssh host cmd` was
# told "aborted" — with a "/dev/tty: No such device" line above it and no hint that
# --yes exists. Said plainly instead, before anything is asked.
confirm() {
  [ -n "$ASSUME_YES" ] && return 0
  if [ ! -t 0 ] && ! { : </dev/tty; } 2>/dev/null; then
    fail "refusing to proceed without confirmation: there is no terminal to ask on.
    Nothing was changed. Read the plan above, then re-run with --yes to confirm it."
  fi
  printf '  %s [y/N] ' "$1"; read -r a </dev/tty || a=""
  case "$a" in y|Y|yes|YES) return 0 ;; *) fail "aborted. Nothing was changed." ;; esac
}

[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — run this from the bundle directory of a cluster node."
[ -n "$MODE" ] || fail "say what to do: --node <name|address> (evict it, run on the primary) or --detach (turn THIS node standalone)."
# 🔑 A HALF-FINISHED detach must stay resumable, and the plain marker check makes it
# the opposite. Detach clears TARANAC_HA early and promotes the data directory late;
# if it stops in between — the exact case its own failure text calls retryable
# ("nothing was destroyed … you can retry") — the marker is already gone, so a retry
# is refused by this guard. The node is then stuck: read-only, out of the cluster, and
# out of reach of the one command that finishes the job. Seen on the stand.
#
# So the question is not "is the marker set" but "is there anything left to do". A data
# directory still carrying standby.signal is unfinished work no matter what .env says.
if [ "$(getenv TARANAC_HA)" != "1" ]; then
  _unfinished=""
  if [ "$MODE" = detach ] && docker volume inspect taranac_pg_data >/dev/null 2>&1; then
    docker run --rm -v taranac_pg_data:/d postgres:16-alpine \
      sh -c 'ls /d/standby.signal >/dev/null 2>&1' && _unfinished=1
  fi
  if [ -n "$_unfinished" ]; then
    say "this node's HA markers are already cleared, but its data directory is still a"
    say "replica (standby.signal is present) — an earlier detach did not finish."
    say "Resuming it: nothing is removed from any cluster, only this node is completed."
    echo
  else
    fail "this node is not part of an HA cluster (TARANAC_HA=1 absent from .env). There is nothing to remove."
  fi
fi

# etcd client plumbing, honouring client-TLS exactly as ha-deconvert does.
ETCDCTL_MOUNT=""; ETCDCTL_TLS_ARGS=""; ETCD_SCHEME="$(getenv ETCD_CLIENT_SCHEME)"; ETCD_SCHEME="${ETCD_SCHEME:-http}"
if [ "$ETCD_SCHEME" = https ]; then
  [ -s "$HERE/config/etcd-tls/ca.crt" ] \
    || fail "etcd client-TLS is on but config/etcd-tls/ca.crt is missing — cannot reach etcd to change membership. Restore this node's etcd material, then retry."
  ETCDCTL_MOUNT="-v $HERE/config/etcd-tls:/tls:ro"; ETCDCTL_TLS_ARGS="--cacert=/tls/ca.crt"
fi

psql_count() {  # <sql> → a number on stdout, "" when unanswerable
  # Never fails: "unanswerable" is an answer the CALLER must act on. Without the
  # `|| true` a stopped or misnamed database container killed the script at the
  # assignment, under set -e, with stderr already discarded — the eviction just
  # stopped at step 3 without a word (seen in the field).
  docker exec taranac-db psql -U taranac -d taranac -tAqc "$1" 2>/dev/null | tr -dc '0-9' || true
}

etcdctl_run() { docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$1" $ETCDCTL_TLS_ARGS "${@:2}"; }
reachable_endpoint() {  # $1 = address to skip
  local hp
  for hp in $(getenv ETCD_HOSTS | tr ',' ' '); do
    case "$hp" in *"${1:-__none__}"*) continue ;; esac
    if etcdctl_run "${ETCD_SCHEME}://${hp}" endpoint health >/dev/null 2>&1; then
      printf '%s' "${ETCD_SCHEME}://${hp}"; return 0
    fi
  done
  printf ''
}

# ══════════════════════════════════════════════════════════════════════════════
# (A) EVICT — on the primary
# ══════════════════════════════════════════════════════════════════════════════
# One topology change at a time, cluster-wide: the update's lock in etcd
# (cluster-versions.sh). Inherited by a command this one hands over to.
TOPOLOGY_LOCKED=""
topology_lock() {  # <op>
  [ -z "${TARANAC_TOPOLOGY_LOCK_HELD:-}" ] || return 0
  [ -f "$HERE/cluster-versions.sh" ] || return 0
  # shellcheck source=cluster-versions.sh
  . "$HERE/cluster-versions.sh"
  cv_init "$HERE" "$ENV_FILE" db
  cv_topology_lock "$1" || fail "another command is changing this cluster right now: ${CV_LOCK_HOLDER}.
    Nothing was changed. Run this again once it has finished (if that command died, the
    lock frees itself within ${CV_LOCK_TTL_S}s)."
  [ -z "${CV_TOPOLOGY_NOTE}" ] || say "! ${CV_TOPOLOGY_NOTE}"
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

if [ "$MODE" = evict ]; then
  TOTAL=7
  echo
  say "Removing '${TARGET}' from cluster '$(getenv TARANAC_CLUSTER_NAME)'."
  echo
  topology_lock remove-node

  step "1/$TOTAL" "asking the LIVE etcd ring who its members are…"
  # 🔑 Both guards below read the RUNNING cluster, never this node's .env. The declared
  # ring (ETCD_INITIAL_CLUSTER) is exactly the value the wizard's preflight exists to
  # catch drifting: a node whose .env is stale would compute the wrong survivor count
  # and either wave through a removal that really does break quorum, or refuse a
  # legitimate one. A guard that trusts the same file it is meant to protect against
  # is not a guard.
  EVICT_EP="$(reachable_endpoint "")"
  [ -n "$EVICT_EP" ] || fail "no reachable etcd endpoint — cannot read the live ring, so the safety
    checks below cannot be answered and nothing will be changed.
    Check the cluster is up (./taranac cluster status) and that this node can reach
    2379 on the other members, then retry."
  live_members="$(etcdctl_run "$EVICT_EP" member list 2>/dev/null || true)"
  [ -n "$live_members" ] || fail "etcd answered at ${EVICT_EP} but returned no member list.
    Nothing was changed. Inspect it directly, then retry:
      docker run --rm $ETCDCTL_MOUNT $ETCD_IMAGE etcdctl --endpoints=$EVICT_EP $ETCDCTL_TLS_ARGS member list"
  live_count="$(printf '%s\n' "$live_members" | grep -c 'started\|unstarted' || true)"
  ok "the live ring has ${live_count} member(s)"

  # ── Is the target the WITNESS? Asked of the ring, never of the roster ────────
  # The witness is taken out by its own command (no leader check, no roster row, a
  # different quorum question, a different ending), and remove-node given its name
  # or address hands over to it. Resolved against the LIVE ring first: an address
  # can belong to a decommissioned database node in the roster AND be the witness's
  # in the ring, and only the ring says which machine answers there now. The ring
  # member is the witness when it matches no roster row by name or by address — the
  # rule the backend's ring alert uses.
  _member="$(printf '%s\n' "$live_members" | awk -F', ' -v t="$TARGET" '{
      peer = $4; sub(/^[a-z]+:\/\//, "", peer); sub(/:[0-9]+$/, "", peer)
      if ($3 == t || peer == t) { print $3 "\t" peer; exit }
    }')"
  if [ -n "$_member" ]; then
    _mname="${_member%%$'\t'*}"; _mhost="${_member#*$'\t'}"
    # Names of every row, addresses of ACTIVE rows only: a witness may sit on the
    # address of a since-decommissioned database node, and that stale row must not
    # make the arbiter look like a database node (the wizard's classify_ring).
    _names="$(docker exec taranac-db psql -U taranac -d taranac -tA -c \
      "select name from cluster_nodes" 2>/dev/null || true)"
    _addrs="$(docker exec taranac-db psql -U taranac -d taranac -tA -c \
      "select address from cluster_nodes where status = 'active'" 2>/dev/null || true)"
    if [ -n "$_names" ] \
       && ! { [ -n "$_mname" ] && printf '%s\n' "$_names" | grep -qxF -- "$_mname"; } \
       && ! printf '%s\n' "$_addrs" | grep -qxF -- "$_mhost"; then
      say "'${TARGET}' is this cluster's WITNESS (${_mhost}) — handing over to remove-witness."
      [ -f "$HERE/cluster-wizard.sh" ] || fail "cluster-wizard.sh is missing from the bundle — refresh it once ('./taranac update'), then retry."
      topology_unlock   # remove-witness takes it itself
      exec bash "$HERE/cluster-wizard.sh" remove-witness --address "$_mhost" ${ASSUME_YES:+--yes}
    fi
  fi

  # Not a ring member at all: a roster row with no machine behind it (a name left by
  # a rename, a join that never completed — what `cluster status` lists as a stale
  # row), or a node whose etcd member was removed already. Taking it out changes no
  # vote, so the quorum arithmetic below must not count it as one.
  IN_RING=0; [ -n "$_member" ] && IN_RING=1

  step "2/$TOTAL" "checking that '${TARGET}' is not the current leader…"
  # Patroni is the authority on who leads — so ASK Patroni, rather than grepping the
  # human-readable table `./taranac cluster status` prints. That table is written for a
  # person and may be re-worded at any time; parsing it means a cosmetic change to a
  # column silently turns this guard off. GET /cluster is JSON, is unauthenticated by
  # Patroni's own design (only unsafe methods need credentials), and answers the same
  # DCS-derived payload from any member.
  leader_name="$(curl -fsS --max-time 10 "http://127.0.0.1:8008/cluster" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in d.get("members", []):
    if m.get("role") in ("leader", "standby_leader"):
        print(m.get("name", ""))
        break' 2>/dev/null || true)"
  [ -n "$leader_name" ] || fail "could not read the current leader from Patroni on this node
    (http://127.0.0.1:8008/cluster). Refusing to continue: without knowing who leads, this
    command cannot tell a safe eviction from one that drops the cluster's write path.
    Check the local database container is up (./taranac ps) and retry."
  ok "the cluster's leader is '${leader_name}'"
  if [ "$leader_name" = "$TARGET" ]; then
    fail "'${TARGET}' is the CURRENT LEADER — evicting it would drop the cluster's write path.
    Hand leadership to another node first, then remove it:
      ./taranac cluster switchover --to <another node>
      ./taranac cluster remove-node --node ${TARGET}"
  fi
  ok "'${TARGET}' is not the leader"

  step "3/$TOTAL" "checking what the surviving cluster would look like…"
  # An operator who typed `remove-node` has a reason, so this REPORTS the consequence
  # and asks — it does not forbid. But the consequence differs sharply by what is left,
  # and a single "needs at least 3" sentence describes the wrong hazard half the time.
  # So work out which case this actually is and say THAT.
  remaining=$((live_count - 1)); [ "$IN_RING" = 1 ] || remaining="$live_count"
  db_now="$(psql_count "select count(*) from cluster_nodes where status='active'")"
  # No default. Guessing "1" here used to pick the hazard text for ONE database node
  # whatever the cluster really was — a warning computed from nothing is worse than
  # none, because it reads like an answer.
  [ -n "$db_now" ] || fail "cannot read the cluster roster from this node's database, so the
    consequence of this removal cannot be stated. Nothing was changed.
    The local database must answer before a member is removed:
      docker exec taranac-db psql -U taranac -d taranac -tAc 'select 1'
    If that says the container does not exist, look for it under another name:
      docker ps -a --filter name=taranac-db"
  db_after=$(( db_now - 1 ))

  if [ "$IN_RING" = 0 ]; then
    ok "'${TARGET}' is not a member of the etcd ring — removing it changes no vote (${remaining} voting members stay)"
  elif [ "$remaining" -ge 3 ]; then
    ok "${remaining} voting members remain — quorum and failover stay intact"
  elif [ "$db_after" -le 1 ]; then
    # ONE database node + a witness. The danger is NOT split-brain (there is nothing
    # to split); it is that a 2-member etcd needs BOTH to have quorum. Lose the
    # witness and Patroni demotes the only database node to read-only — strictly
    # worse than not running HA at all, because a standalone node would just serve.
    say ""
    say "  This leaves ONE database node (${db_after}) plus the witness — 2 etcd members."
    say "  What that means, concretely: a 2-member ring needs BOTH to have quorum. If the"
    say "  witness then goes down, Patroni demotes the surviving database node to"
    say "  READ-ONLY and the product stops accepting writes — worse than not running HA,"
    say "  because a plain standalone node would keep serving."
    say ""
    say "  If the goal is to go back to a single server, finish the job afterwards on"
    say "  this node — it adopts the data in place, no re-init:"
    say "      ./ha-deconvert.sh"
    say ""
    confirm "Remove '${TARGET}' anyway?"
  else
    # TWO database nodes and no arbiter — the classic split-brain shape.
    say ""
    say "  This leaves ${db_after} database nodes with only ${remaining} etcd voting member(s) and no"
    say "  arbiter. On a network partition neither side can hold a majority, so neither"
    say "  may safely become the primary — failover stops working, which is the one"
    say "  thing HA exists to provide (ha.md §8)."
    say ""
    say "  Add a witness on a separate host first, and this stops being a problem:"
    say "      ./taranac cluster add-witness --address <a third host>"
    say ""
    confirm "Remove '${TARGET}' anyway?"
  fi

  say ""
  say "This will remove '${TARGET}' from etcd membership and from the cluster roster."
  say "The node's own data is NOT touched by this command — it stays on that machine."
  confirm "Proceed?"

  step "4/$TOTAL" "updating the cluster manifest, and publishing it first…"
  # 🔑 BEFORE the ring changes, and fatal. Every node takes the cluster's published
  # copy of config/cluster.yml whole, so a removal that reached the ring but not the
  # copy would come back on the next command anywhere. Done by the wizard's helper —
  # the same rule as every topology command: a node that never held the file (one
  # that joined late) takes the cluster's copy first, edits it, publishes it.
  [ -f "$HERE/cluster-wizard.sh" ] || fail "cluster-wizard.sh is missing from the bundle — refresh it once ('./taranac update'), then retry. Nothing was changed."
  bash "$HERE/cluster-wizard.sh" manifest-remove --name "$TARGET" --address "$TARGET" \
    || fail "the cluster manifest could not be updated (above), so '${TARGET}' was NOT removed.
    Nothing was changed. Fix what it names, then run the same command again."

  step "5/$TOTAL" "removing '${TARGET}' from etcd membership…"
  ep="$(reachable_endpoint "$TARGET")"
  [ -n "$ep" ] || fail "no reachable etcd endpoint (other than '${TARGET}') — cannot change membership now.
    Bring another member up and retry; nothing has been changed."
  mid="$(etcdctl_run "$ep" member list 2>/dev/null \
        | awk -F',' -v n="$TARGET" '{name=$3; gsub(/^[ \t]+|[ \t]+$/,"",name); if(name==n){id=$1; gsub(/ /,"",id); print id}}')"
  if [ -n "$mid" ]; then
    etcdctl_run "$ep" member remove "$mid" >/dev/null \
      || fail "etcdctl member remove failed for '${TARGET}' (id ${mid}) via ${ep}. Nothing else was changed; retry once etcd is healthy."
    ok "etcd member removed (id ${mid})"
  else
    ok "no etcd member named '${TARGET}' — already removed"
  fi

  step "6/$TOTAL" "decommissioning the roster row…"
  # Soft-delete: the row is retained so historical node_id references in the logs keep
  # resolving (models.py — ids are never reused). Non-fatal, because etcd is already
  # changed and leaving the roster stale is the lesser of the two inconsistencies.
  # --evicted: the node is out of the ring now (step 5), so a Patroni that still runs
  # there for a moment is not a reason to refuse. The backend still refuses the leader
  # and any ring member — which is what keeps the UI's and the CLI's decommission from
  # being a way around this command.
  if ./taranac cluster decommission --name "$TARGET" --evicted >/dev/null 2>&1; then
    ok "roster row decommissioned"
  else
    say "      ! the roster row could not be decommissioned (already gone?). Continuing —"
    say "        etcd membership is authoritative for quorum. Check later: ./taranac cluster status"
  fi

  step "7/$TOTAL" "pruning '${TARGET}' from this node's .env topology…"
  # `|| true` inside: grep -v that keeps no line exits 1, and under pipefail that
  # killed the step on a .env without the key (or with the target as its only entry).
  ic="$(printf '%s' "$(getenv ETCD_INITIAL_CLUSTER)" | tr ',' '\n' | { grep -v "^${TARGET}=" || true; } | paste -sd, -)"
  setenv ETCD_INITIAL_CLUSTER "$ic"
  for key in DB_HOSTS ETCD_HOSTS; do
    pruned="$(printf '%s' "$(getenv "$key")" | tr ',' '\n' | { grep -v "^${TARGET}:" || true; } | paste -sd, -)"
    setenv "$key" "$pruned"
  done
  ok ".env topology pruned"

  echo
  say "'${TARGET}' is out of the cluster."
  say ""
  say "The other surviving nodes need nothing: membership is in etcd, write routing follows"
  say "the replicated roster, and the manifest was published — all changed once, cluster-wide."
  say ""
  if [ "$IN_RING" = 0 ]; then
    say "'${TARGET}' was not in the etcd ring, so no machine was voting under that name. If one"
    say "still runs as '${TARGET}' somewhere, it holds a copy of the data — on THAT machine:"
    say "      ./taranac cluster detach        (keep it as a standalone install)"
    say "  or wipe it. Otherwise there is nothing further to do."
  else
    say "That machine still holds a full copy of the data and is still running. Decide:"
    say "  • wipe it            — it is finished with; nothing further to do here"
    say "  • keep it as its own — on THAT machine:  ./cluster-remove.sh --detach"
  fi
  echo
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# (B) DETACH — on the node itself
# ══════════════════════════════════════════════════════════════════════════════
TOTAL=6
NODE_NAME="$(getenv TARANAC_NODE_NAME)"
echo
say "Detaching '${NODE_NAME}' from its cluster and turning it into a standalone install."
echo

step "1/$TOTAL" "checking this node was evicted from the cluster first…"
# Order is mandatory: if the cluster still lists this node as a member, its etcd keeps
# trying to rejoin the ring and its Postgres keeps being a follower of a primary that
# still counts on it. Evicting first is what frees this node's data directory to be
# promoted rather than stranded read-only.
ep="$(reachable_endpoint "$(getenv NODE_ADDRESS)")"
if [ -n "$ep" ] && etcdctl_run "$ep" member list 2>/dev/null | grep -q "$(getenv NODE_ADDRESS):2380"; then
  fail "this node is STILL a member of the cluster — detaching now would strand it.
    Run this on the primary FIRST, then come back here:
      ./taranac cluster remove-node --node ${NODE_NAME}"
fi
# 🔑 No member answered: whether this node is still in the ring is UNKNOWN, not "no".
# It used to print "not a cluster member any more" here and go on — turning a member
# of a cluster that is merely unreachable from here into a writable fork of it. Only
# a node still marked HA asks this; a resumed detach (markers already cleared) passed
# this step in its first run.
if [ -z "$ep" ] && [ "$(getenv TARANAC_HA)" = "1" ] && ! confirmed NOT-A-MEMBER; then
  fail "no other member of the cluster answers from here, so it cannot be checked that this
    node was taken out of it first. Nothing was changed.
    If the cluster is merely unreachable, fix that, take this node out on the primary,
    and come back:
      ./taranac cluster remove-node --node ${NODE_NAME}
    If that cluster is gone for good (every other machine wiped or lost), say so too:
      ./taranac cluster detach --confirm NOT-A-MEMBER --confirm FORK-MY-DATA"
fi
if [ -n "$ep" ]; then ok "not a cluster member any more"
else ok "no member answers — proceeding on your word (--confirm NOT-A-MEMBER)"; fi

cat <<'BANNER'

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  READ THIS BEFORE CONFIRMING                                             │
  │                                                                          │
  │  This machine holds a COMPLETE COPY of the cluster's database: every      │
  │  device shared secret, every enable password, every credential, every     │
  │  log. Detaching does not erase any of it — it makes this machine a        │
  │  second, fully working Taranac carrying all of it.                        │
  │                                                                          │
  │  That is a FORK of your data, not a decommission. Anyone with access to   │
  │  this machine and its master key has everything the cluster had.          │
  │                                                                          │
  │  If you meant to retire this machine, do NOT detach — wipe it instead.    │
  └──────────────────────────────────────────────────────────────────────────┘

BANNER

if ! confirmed FORK-MY-DATA; then
  fail "this needs an explicit acknowledgement of the line above. If you have read it and
    you do want a second, independent Taranac carrying a full copy of the data, re-run:
      ./cluster-remove.sh --detach --confirm FORK-MY-DATA"
fi

step "2/$TOTAL" "taking a backup before changing anything…"
# The same reflex `taranac reset` has (system_reset.py::_backup): reuse the normal
# Backup & Recovery archive rather than inventing a second mechanism. A detach rewrites
# .env and recreates containers; if any of that goes wrong the operator must not be left
# with neither a cluster nor a working node. Invoked through the same service the CLI
# reset uses, so the archive is an ordinary restorable one with a recorded trigger.
backup_out="$(docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.ha.yml exec -T api python - <<'PY' 2>&1 || true
import asyncio


async def main() -> None:
    # Register EVERY module's models before touching the ORM. Without it SQLAlchemy
    # configures mappers from a half-populated registry and dies on the first
    # cross-module relationship — "expression 'UserMfa' failed to locate a name" —
    # which reads like a code bug and is really a missing import. The product's own
    # CLI scripts all do this first; this snippet did not, so the pre-detach backup
    # failed on a live node and the operator was told there is no archive.
    import app.models  # noqa: F401
    from app.core.audit.service import AuditService
    from app.database import async_session_factory
    from app.modules.core.settings.service import SettingsService
    from app.modules.infra.backup.service import BackupService

    async with async_session_factory() as session:
        audit = AuditService(session)
        settings_svc = SettingsService(session, audit=audit)
        info = await BackupService(session, settings_svc, audit).create_backup(
            trigger="pre-detach", actor_username="cli-detach"
        )
        await session.commit()
        print(info.filename)


asyncio.run(main())
PY
)"
archive="$(printf '%s' "$backup_out" | tail -1)"
case "$archive" in
  taranac-backup-*.tar)
    ok "backup created: ${archive} (in the backups volume — copy it off this machine if it matters)" ;;
  *)
    say "      ! could not take an automatic backup. Reason:"
    printf '        %s\n' "$(printf '%s' "$backup_out" | tail -3)"
    say "        Continuing WITHOUT a fresh archive for this machine. Stop now (Ctrl-C) if"
    say "        that matters — the data itself is untouched at this point." ;;
esac

step "3/$TOTAL" "stopping the HA stack…"
# A pending update finisher (taranac-update-finisher, left by an update that was
# waiting for the leader's schema) would bring the HA stack back up on its version
# the moment the api turned healthy — undoing exactly this. It goes first.
if docker inspect taranac-update-finisher >/dev/null 2>&1; then
  docker rm -f taranac-update-finisher >/dev/null 2>&1 || true
  say "      removed the pending update finisher (taranac-update-finisher) — it would have restarted the HA stack"
fi
docker compose --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.ha.yml down >/dev/null 2>&1 || true
ok "stopped"

step "4/$TOTAL" "clearing the HA markers from .env…"
# Symmetric to what ha-convert/ha-join wrote. TARANAC_HA is the authoritative marker the
# wrapper reads to decide whether to merge the HA overlay; DB_HOSTS is its fallback, and
# a leftover value there would keep this standalone node trying to write-route to a
# primary that is no longer its own.
setenv TARANAC_HA 0
setenv DB_HOSTS ""
for k in ETCD_HOSTS ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE ETCD_NAME; do setenv "$k" ""; done
ok "markers cleared"

step "5/$TOTAL" "promoting this node's data directory out of replication…"
# 🔑 Clearing the .env markers is NOT enough. Patroni left `standby.signal` in the data
# directory, and that file — not any environment variable — is what makes Postgres a
# replica. The stock image reads it, dutifully stays read-only, and spends forever
# trying to reach a primary this node no longer follows:
#     FATAL: could not connect to the primary server … Connection refused
# Nothing times out, because nothing failed: it is a replica doing its job. The wait
# for a writable database then cannot end. Seen on the stand.
#
# `pg_ctl promote` is the supported way out, but the server has to be RUNNING for it,
# and it is not — so the file is removed directly while everything is stopped. That is
# the same decision `ha-deconvert` makes for the shrink path, and it is safe here for
# the same reason: this node has already been evicted, nothing streams to it, and the
# WAL it holds is its own.
PG_VOL=taranac_pg_data
if docker volume inspect "$PG_VOL" >/dev/null 2>&1; then
  if docker run --rm -v "${PG_VOL}:/d" postgres:16-alpine \
       sh -c 'ls /d/standby.signal >/dev/null 2>&1'; then
    docker run --rm -v "${PG_VOL}:/d" postgres:16-alpine \
      sh -c 'rm -f /d/standby.signal' \
      || fail "could not remove standby.signal from '${PG_VOL}'.
    Until it is gone this node's Postgres stays a read-only replica of a cluster it has
    left. Remove it and re-run:
      docker run --rm -v ${PG_VOL}:/d postgres:16-alpine rm -f /d/standby.signal"
    ok "standby.signal removed — the data directory is this node's own again"
  else
    ok "no standby.signal — the data directory is already standalone"
  fi
fi

# ── The etcd state goes too, or the NEXT cluster inherits this one's ghosts ──
# 🔑 Detach clears the .env markers and promotes the database, but the etcd volume
# holds this node's membership in the cluster it just left. Left behind, a later
# `cluster init` starts etcd on top of it and the "new" ring comes up already
# believing in members that no longer exist — one live node out of two declared is
# not a majority, so the ring is unusable and every add fails with "unhealthy
# cluster", blaming the machine being added. Seen exactly that way on the stand.
# A witness's etcd volume is dropped for the same reason on its own re-join.
#
# Nothing of value is lost: etcd here holds Raft membership for a cluster this node
# is leaving, and the application data lives in Postgres.
if docker volume inspect taranac_etcd_data >/dev/null 2>&1; then
  step "5a/$TOTAL" "removing this node's etcd membership state"
  docker rm -f taranac-etcd >/dev/null 2>&1 || true
  docker volume rm taranac_etcd_data >/dev/null 2>&1 \
    && ok "etcd state removed — a future cluster starts from a clean ring" \
    || say "      ! could not remove taranac_etcd_data. Remove it before building a new
        cluster here, or its ring will inherit this one's members:
          docker volume rm taranac_etcd_data"
fi

step "5b/$TOTAL" "starting this node standalone (its Postgres adopts the data in place)…"
# Base compose only. The stock postgres image adopts the Patroni data directory as-is —
# same stock /var/lib/postgresql/data layout, no re-init — which is the mirror image of
# what ha-convert does when it adopts a standalone PGDATA into Patroni.
docker compose --env-file "$ENV_FILE" -f docker-compose.yml up -d
ok "stack starting"

step "6/$TOTAL" "waiting for the database to accept writes…"
# The observable outcome. "The container started" is not it: a Postgres that came up
# still in recovery would leave the operator with a read-only install and a script that
# claimed success. We wait for the real thing.
writable=""
for _ in $(seq 1 40); do
  if docker exec taranac-db psql -U taranac -d taranac -tAc "select not pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
    writable=1; break
  fi
  sleep 3
done
[ -n "$writable" ] || fail "the database did not come up writable within the timeout.
    It is still in recovery, which means this node has not finished leaving the cluster.
    Look at:  docker logs taranac-db
    Nothing was destroyed — the data directory is intact and you can retry."
ok "database is writable — this node is standalone"

# ── The roster came with the data, and it now describes a cluster that is not ours ──
# 🔑 A detached node carries a FULL copy of the database, and `cluster_nodes` is data
# like everything else. So `./taranac cluster status` on this machine cheerfully lists
# its former peers, names a leader it does not follow, and reports a cluster it left —
# read from its own fork. Nothing is broken; it is simply answering with inherited
# rows. But an operator cannot tell the difference between that and a real cluster,
# and this command has just spent six steps insisting the relationship is severed.
#
# So the roster is reduced to the one node this genuinely is. The others are
# soft-deleted, never hard-deleted: log rows carry node_id references, and a dangling
# id resolves to nothing at all where it used to resolve to a name.
# Two arguments, like every other call: `step` prints "$2" and this one passed only
# a message. Under `set -euo pipefail` that is fatal — so the detach died HERE, one
# line into the cleanup it had spent six steps earning, leaving the roster it meant
# to prune and exiting non-zero after an operation that had in fact succeeded.
step "6b/$TOTAL" "cleaning this node's inherited copy of the cluster roster"
_self_name="${NODE_NAME:-$(getenv TARANAC_NODE_NAME)}"
if [ -n "$_self_name" ] && docker exec taranac-db psql -U taranac -d taranac -tAc "select 1" >/dev/null 2>&1; then
  _pruned="$(docker exec taranac-db psql -U taranac -d taranac -tAqc \
    "UPDATE cluster_nodes SET status='decommissioned', decommissioned_at=now()
      WHERE status='active' AND name <> '${_self_name}' RETURNING 1" 2>/dev/null | grep -c 1 || true)"
  if [ "${_pruned:-0}" -gt 0 ]; then
    ok "${_pruned} former peer(s) marked decommissioned — 'cluster status' now shows this node alone"
  else
    ok "the roster already lists this node only"
  fi
else
  say "      ! could not reach this node's database to clean the roster. Harmless, but"
  say "        './taranac cluster status' will keep listing the former peers until it is"
  say "        done. Retry later:  ./taranac cluster detach --confirm FORK-MY-DATA"
fi

echo
say "'${NODE_NAME}' is now an independent Taranac install with its own copy of the data."
say "It has NO relationship to its former cluster: nothing replicates in either direction."
echo
exit 0
