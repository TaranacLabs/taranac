#!/usr/bin/env bash
# =============================================================================
# diagnose-ha.sh — a snapshot of what THIS node believes about the cluster.
#
#   ./taranac diagnose --ha
#
# Run it on EVERY machine in the cluster — each database node AND the witness —
# and send all the archives together. There is no primary/peer mode, no flag to
# get wrong and no merge step: the same command everywhere.
#
# WHY IT IS COLLECTED PER NODE AND COMPARED AFTERWARDS
#   Almost every HA fault is a DISAGREEMENT between hosts: a timeline that
#   forked, a secret that differs, a ring one node knows and another does not, a
#   version that was upgraded on one machine only. A disagreement cannot be seen
#   from one side of it. Some of it IS visible cluster-wide from a single host —
#   etcd and Patroni's REST are cluster APIs — and that part is collected here
#   too. The rest (this node's .env, its containers, its clock, its disk) exists
#   only locally, which is exactly why the command runs everywhere.
#
#   To make the comparison a glance rather than a diff, every bundle prints one
#   `cluster-fingerprint` line: a hash over the fingerprints of every value that
#   MUST be identical cluster-wide. Same string on every node ⇒ the cluster-wide
#   secrets agree, question closed. Different ⇒ the per-key block below it names
#   the one that drifted.
#
# THIS IS A SNAPSHOT, NOT A CAPTURE
#   The protocol collectors record a window while you reproduce a fault. HA
#   faults are state, not events: there is nothing to reproduce and nothing on
#   the wire to decode. So this reads current state and stops.
#
# IT MUST WORK WHEN THE NODE IS BROKEN — that is when it is called
#   `set -e` is deliberately NOT used. This script is run on a node whose
#   database will not start, whose etcd is down, or which was never converted at
#   all. Every probe is independently fail-soft and records WHY it could not
#   answer; one dead subsystem must never cost the bundle the other eight. In
#   particular:
#     · .env is read from the HOST, never through a container
#     · the timeline is read from the data volume with a throwaway container
#       when taranac-db itself will not run
#     · Patroni and etcd are asked LOCALLY first, then at every declared member,
#       so a node with a dead stack still reports the cluster's real state
#
# NO SECRET IS EVER WRITTEN TO THE ARCHIVE. Secrets appear only as the 12-hex
# fingerprint Taranac already uses elsewhere (sha256, first 12) — enough to prove
# two nodes disagree about a key, useless to whoever intercepts the archive.
# Topology (addresses, member lists, node names) is NOT secret and is recorded
# verbatim: it is the entire point of the bundle.
# =============================================================================

# No `-e`: see the header. `-u` and `pipefail` stay — they catch our own bugs
# without punishing a probe for the subsystem it is probing being down.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${HERE}" || { echo "✗ cannot enter ${HERE}" >&2; exit 1; }

ENV_FILE="${HERE}/.env"
OUT_DIR="${HERE}/diagnostics"
LOG_LINES=400

# Same probe image as ha-join's data-volume probe, and for the same reason: an
# appliance and any air-gapped host bake a FIXED image set that busybox is not in,
# so a busybox probe fails there and a failed probe reads as "nothing found".
# postgres:16-alpine is on every Taranac node by construction.
PROBE_IMAGE="postgres:16-alpine"
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.17"

PG_VOL="taranac_pg_data"
ETCD_VOL="taranac_etcd_data"

# Thresholds. Deliberately generous — a diagnostic that cries wolf gets ignored,
# and the numbers are printed alongside every verdict so the reader can disagree.
LAG_WARN_BYTES=$((64 * 1024 * 1024))   # 64 MiB of unreplayed WAL
CLOCK_WARN_SEC=5                       # Patroni leases are time-based
CERT_WARN_DAYS=30

usage() {
  cat <<'USAGE'
Collect an HA cluster-state snapshot from this node.

  ./taranac diagnose --ha [options]

Run it on EVERY node — each database node and the witness — and send all the
archives. One command, no roles, no flags to get wrong: the faults worth finding
are disagreements between nodes, so the bundles are compared against each other.

Options:
  --out DIR         where to write the archive (default: ./diagnostics)
  --log-lines N     lines of each component log to include (default: 400)
  -h, --help        this text

It is safe to run at any time and on any node, including one whose database will
not start, one that is not part of a cluster at all, and the witness. It reads
state and changes nothing.

No secret is written to the archive — only 12-hex fingerprints.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       OUT_DIR="${2:-}"; shift 2 ;;
    --log-lines) LOG_LINES="${2:-}"; shift 2 ;;
    --ha)        shift ;;              # tolerated: diagnose.sh already consumed it
    -h|--help)   usage; exit 0 ;;
    *) echo "✗ Unknown option '$1' for 'diagnose --ha'." >&2; usage >&2; exit 1 ;;
  esac
done
case "${LOG_LINES}" in
  ''|*[!0-9]*) echo "✗ --log-lines takes a number (got '${LOG_LINES}')." >&2; exit 1 ;;
esac

# ── Small helpers ───────────────────────────────────────────────────────────
have()   { command -v "$1" >/dev/null 2>&1; }
say()    { printf '%s\n' "$*"; }
step()   { printf '→ %s\n' "$*"; }

# An ABSENT key is an empty value, not an error — the same `|| true` guard
# ha-deconvert documents: without it a bare assignment under pipefail can kill
# the script silently, before it prints anything.
getenv() {
  [ -r "${ENV_FILE}" ] || return 0
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" "${ENV_FILE}" 2>/dev/null \
    | tail -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' || true
}

# sha256, first 12 — byte-identical to backend key_fingerprint(), so a value can
# be compared across a bundle and an application log without conversion.
fp() {
  local v="$1"
  [ -n "${v}" ] || { printf 'EMPTY'; return 0; }
  printf '%s' "${v}" | sha256sum 2>/dev/null | cut -c1-12
}

# TCP reachability with no external dependency (nc/nmap are not on every host).
# A 3s timeout: anything slower is a finding in itself on a cluster interconnect.
tcp_open() {  # <host> <port>
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

FINDINGS=()
NOTES=()
finding() { FINDINGS+=("$*"); }
note()    { NOTES+=("$*"); }

# ── Step 0: where does this run, and what is it ─────────────────────────────
STAMP="$(date -u +%Y%m%d-%H%M%S)"
HOSTNAME_S="$(hostname 2>/dev/null || echo unknown)"

HA_MARK="$(getenv TARANAC_HA)"
NODE_NAME="$(getenv TARANAC_NODE_NAME)"
NODE_ADDRESS="$(getenv NODE_ADDRESS)"
ETCD_NAME_ENV="$(getenv ETCD_NAME)"
CLUSTER_NAME="$(getenv TARANAC_CLUSTER_NAME)"
DB_HOSTS="$(getenv DB_HOSTS)"
ETCD_HOSTS="$(getenv ETCD_HOSTS)"
ETCD_RING="$(getenv ETCD_INITIAL_CLUSTER)"
ETCD_STATE="$(getenv ETCD_INITIAL_CLUSTER_STATE)"
ETCD_CLIENT_SCHEME="$(getenv ETCD_CLIENT_SCHEME)"; ETCD_CLIENT_SCHEME="${ETCD_CLIENT_SCHEME:-http}"
ETCD_PEER_SCHEME="$(getenv ETCD_PEER_SCHEME)"; ETCD_PEER_SCHEME="${ETCD_PEER_SCHEME:-http}"

# The etcd container is not called the same thing on both kinds of machine: a
# database node runs `taranac-etcd` (docker-compose.ha.yml) and a witness runs
# `taranac-witness-etcd` (docker-compose.witness.yml). Every reference in this
# script was the database node's name, so on a witness the report stated
# "taranac-etcd: running=false" about a container that host is not supposed to
# have — an operator reading it sees the arbiter's etcd reported as DOWN, on the
# one machine whose only job is to run it. Only the `docker run --rm etcdctl`
# fallback kept the ring readable there at all, which is why it went unnoticed.
ETCD_CT=taranac-etcd
if ! docker inspect "${ETCD_CT}" >/dev/null 2>&1 && docker inspect taranac-witness-etcd >/dev/null 2>&1; then
  ETCD_CT=taranac-witness-etcd
fi

# Containers are read under the name they REALLY have. compose can leave one under
# its temporary recreate name (`<12 hex>_taranac-db`, see container-names.sh), and
# this collector then reported a healthy, leading database as "running=false, no
# such container" — in the one bundle sent because something was wrong. It reads
# the leftover, and names it as a finding; it does NOT rename it, because this
# collector promises to change nothing. Without the helper (a half-updated
# bundle) every name resolves to itself, which is what this did before.
if [ -f "${HERE}/container-names.sh" ]; then
  . "${HERE}/container-names.sh"
else
  resolve_container() { printf '%s' "$1"; }
  container_name_problems() { :; }
fi
DB_CT="$(resolve_container taranac-db)"
API_CT="$(resolve_container taranac-api)"
# ETCD_CT stays the NAME (it labels the report and names the log file); ETCD_REAL is
# the container to talk to. A leftover witness etcd is found here too.
ETCD_REAL="$(resolve_container "${ETCD_CT}")"
if ! docker inspect "${ETCD_REAL}" >/dev/null 2>&1; then
  _w="$(resolve_container taranac-witness-etcd)"
  if docker inspect "${_w}" >/dev/null 2>&1; then ETCD_CT=taranac-witness-etcd; ETCD_REAL="${_w}"; fi
fi
CN_PROBLEMS="$(container_name_problems 2>/dev/null || true)"

# A witness host has no .env of its own in some layouts — its identity lives in
# the etcd container's environment. Falling back to it is what lets the SAME
# command work on the third machine, which is a third of the cluster.
if [ -z "${ETCD_RING}" ] && docker inspect "${ETCD_REAL}" >/dev/null 2>&1; then
  ETCD_RING="$(docker inspect "${ETCD_REAL}" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^ETCD_INITIAL_CLUSTER=' | head -1 | cut -d= -f2- || true)"
  [ -n "${ETCD_NAME_ENV}" ] || ETCD_NAME_ENV="$(docker inspect "${ETCD_REAL}" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^ETCD_NAME=' | head -1 | cut -d= -f2- || true)"
  [ -n "${ETCD_RING}" ] && note "this host has no usable .env — identity read from the etcd container instead (normal on a witness)"
fi

[ -n "${NODE_NAME}" ] || NODE_NAME="${ETCD_NAME_ENV}"
[ -n "${NODE_NAME}" ] || NODE_NAME="${HOSTNAME_S}"

# Role by construction, before anything is asked of any daemon: a name that is in
# the etcd ring but has no Postgres in DB_HOSTS is a witness. This is what stops
# the collector from reporting a healthy arbiter as a database node with every
# database probe failing.
ROLE_GUESS="unknown"
if [ "${HA_MARK}" = "1" ]; then
  ROLE_GUESS="database node"
elif [ -n "${ETCD_RING}" ] && [ -z "${DB_HOSTS}" ]; then
  ROLE_GUESS="witness (etcd only)"
elif [ -z "${ETCD_RING}" ] && [ -z "${DB_HOSTS}" ]; then
  ROLE_GUESS="standalone (not part of a cluster)"
fi
if [ "${HA_MARK}" != "1" ] && [ -n "${ETCD_RING}" ] && [ -n "${DB_HOSTS}" ]; then
  ROLE_GUESS="database node, HA marker MISSING"
fi

BUNDLE="taranac-diag-ha-$(printf '%s' "${NODE_NAME}" | tr -c 'A-Za-z0-9_.-' '_')-${STAMP}"
WORK="${OUT_DIR}/${BUNDLE}"
mkdir -p "${WORK}/logs" || { echo "✗ cannot write to ${OUT_DIR}" >&2; exit 1; }

say "Taranac diagnostic collector"
say "  mode     : ha (cluster-state snapshot)"
say "  node     : ${NODE_NAME}${NODE_ADDRESS:+ (${NODE_ADDRESS})}"
say "  cluster  : ${CLUSTER_NAME:-(not declared)}"
say "  looks like: ${ROLE_GUESS}"
say ""

if [ ! -r "${ENV_FILE}" ]; then
  if [ -f "${ENV_FILE}" ]; then
    note ".env exists but is not readable by $(id -un) — run this as the operator who owns the bundle, or the configuration section will be blank"
  else
    note "no .env in ${HERE} — this is normal on a witness host, and expected nowhere else"
  fi
fi

# ── The declared topology, parsed once ──────────────────────────────────────
# Members come from ETCD_INITIAL_CLUSTER (name=scheme://addr:2380, comma
# separated) because it is the ONLY list that names the witness. DB_HOSTS then
# says which of them carry a database. Everything below iterates these two.
MEMBER_NAMES=(); MEMBER_ADDRS=(); MEMBER_ROLES=()
if [ -n "${ETCD_RING}" ]; then
  OLD_IFS="${IFS}"; IFS=,
  for tok in ${ETCD_RING}; do
    [ -n "${tok}" ] || continue
    m_name="${tok%%=*}"
    m_url="${tok#*=}"
    m_addr="${m_url#*://}"; m_addr="${m_addr%%:*}"
    [ -n "${m_name}" ] && [ -n "${m_addr}" ] || continue
    MEMBER_NAMES+=("${m_name}")
    MEMBER_ADDRS+=("${m_addr}")
    if [ -n "${DB_HOSTS}" ] && printf '%s' "${DB_HOSTS}" | grep -qF -- "${m_addr}:5432"; then
      MEMBER_ROLES+=("db")
    else
      MEMBER_ROLES+=("witness")
    fi
  done
  IFS="${OLD_IFS}"
fi
DECLARED_MEMBERS="${#MEMBER_NAMES[@]}"

# A witness carries ETCD_NAME but no NODE_ADDRESS, so "am I this member?" cannot be
# answered by address alone — and answering it wrong makes the node report ITSELF
# as unreachable, which is the first thing anyone reading the bundle would trip on.
# The ring already knows where each name lives; take our address from there.
if [ -z "${NODE_ADDRESS}" ] && [ "${DECLARED_MEMBERS}" -gt 0 ]; then
  for i in "${!MEMBER_NAMES[@]}"; do
    if [ "${MEMBER_NAMES[$i]}" = "${NODE_NAME}" ]; then
      NODE_ADDRESS="${MEMBER_ADDRS[$i]}"
      note "NODE_ADDRESS is not set here — taken as ${NODE_ADDRESS} from this node's entry in the declared ring"
      break
    fi
  done
fi

# Is member $1 this very node? By name first (always known), address second.
is_self() {  # <index>
  [ "${MEMBER_NAMES[$1]}" = "${NODE_NAME}" ] && return 0
  [ -n "${NODE_ADDRESS}" ] && [ "${MEMBER_ADDRS[$1]}" = "${NODE_ADDRESS}" ] && return 0
  return 1
}

# ── Step 1: this node — containers, images, and WHICH COMPOSE FILES ─────────
# The compose `config_files` label is the point of this step. An HA node whose
# database container was created WITHOUT docker-compose.ha.yml is running a
# plain, writable Postgres directly on Patroni's data directory — the split-brain
# shape. The image name alone only hints at it; this label states it outright.
step "reading this node's containers"
{
  echo "Node"
  echo "===="
  echo "hostname            : ${HOSTNAME_S}"
  echo "node name           : ${NODE_NAME}"
  echo "node address        : ${NODE_ADDRESS:-(not set)}"
  echo "cluster name        : ${CLUSTER_NAME:-(not declared)}"
  echo "role (by config)    : ${ROLE_GUESS}"
  echo "TARANAC_HA          : ${HA_MARK:-(absent)}"
  echo "bundle version      : $(cat "${HERE}/VERSION" 2>/dev/null || echo unknown)"
  echo "host time           : $(date '+%Y-%m-%d %H:%M:%S %Z %z')"
  echo "host time (UTC)     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "uptime              : $(uptime -p 2>/dev/null || echo unknown)"
  echo "docker              : $(docker --version 2>/dev/null || echo 'NOT AVAILABLE')"
  echo
  echo "Clock synchronisation"
  echo "---------------------"
  if have timedatectl; then
    timedatectl show -p NTP -p NTPSynchronized -p Timezone 2>/dev/null || timedatectl 2>/dev/null || echo "(unavailable)"
  elif have chronyc; then
    chronyc tracking 2>/dev/null || echo "(unavailable)"
  else
    echo "(no timedatectl/chronyc on this host)"
  fi
  echo
  echo "Containers"
  echo "----------"
  docker ps -a --filter "name=taranac-" \
    --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "(docker not answering)"
  echo
  echo "Which compose files each container was created from"
  echo "---------------------------------------------------"
  echo "(an HA node's taranac-db MUST list docker-compose.ha.yml — see Findings)"
  for ct in taranac-db "${ETCD_CT}" taranac-api; do
    real_ct="$(resolve_container "${ct}")"
    if docker inspect "${real_ct}" >/dev/null 2>&1; then
      printf '%-16s %s\n' "${ct}" \
        "$(docker inspect "${real_ct}" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || echo unknown)"
    else
      printf '%-16s %s\n' "${ct}" "(no such container)"
    fi
  done
  echo
  echo "Volumes"
  echo "-------"
  for v in "${PG_VOL}" "${ETCD_VOL}"; do
    if docker volume inspect "${v}" >/dev/null 2>&1; then
      echo "${v}: present"
    else
      echo "${v}: ABSENT"
    fi
  done
  echo
  echo "Node-id marker (what THIS machine's daemons stamp on their log rows)"
  echo "-------------------------------------------------------------------"
  # node_id.conf is a per-node artefact — a file in each daemon's config volume,
  # read once at init. It is the one piece of the cluster's state that no other
  # node can see or repair, so a bundle collected from three machines was the only
  # place a wrong one could be noticed, and it was not collected. A replica whose
  # marker is missing writes AAA/NAC rows with node_id NULL; one that survived a
  # convert-from-standalone names a roster row that no longer exists, and every
  # insert is then rejected by the foreign key with the rows dropped. Both are
  # silent on the node itself. The value is compared with the roster below.
  # Read at each daemon's OWN mount path, not the api's. The api container mounts
  # the same three volumes at /etc/tac_plus, /mnt/radius_config and /mnt/nac_config
  # — those are where it WRITES — while the daemons mount them at /etc/tac_plus and
  # /etc/raddb. Asking the daemons about the api's paths reported "no marker" on a
  # node whose markers were all present and correct, which is the wrong answer in
  # the more dangerous direction.
  for _d in taranac-tacacs:/etc/tac_plus taranac-radius:/etc/raddb taranac-nac:/etc/raddb; do
    _ct="${_d%%:*}"; _path="${_d#*:}"
    if docker inspect "${_ct}" >/dev/null 2>&1; then
      _seen="$(docker exec "${_ct}" cat "${_path}/node_id.conf" 2>/dev/null | tr -d '[:space:]' || true)"
      printf '%-18s %s\n' "${_ct}" "${_seen:-(NO MARKER — this daemon stamps node_id NULL)}"
    else
      printf '%-18s %s\n' "${_ct}" "(not running here)"
    fi
  done
  echo "roster says this node is:"
  docker exec "${DB_CT}" psql -U taranac -d taranac -tAc \
    "select id || '  ' || name || '  ' || status from cluster_nodes where name = '${NODE_NAME}'" 2>/dev/null \
    | sed 's/^/  /' || echo "  (database not reachable from here)"
  echo
  echo "Disk"
  echo "----"
  df -h "${HERE}" /var/lib/docker 2>/dev/null | sort -u || echo "(unavailable)"
} > "${WORK}/node.txt" 2>&1

DB_COMPOSE_FILES="$(docker inspect "${DB_CT}" \
  --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)"
DB_IMAGE="$(docker inspect "${DB_CT}" --format '{{.Config.Image}}' 2>/dev/null || true)"
# Normalised to exactly "true" or "false". `docker inspect … || echo false` on a
# container that does not exist yields a BLANK line plus the fallback, and the
# two-line value then prints as `running=` followed by a stray `false`.
container_running() {  # <name>
  local v
  v="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | tr -d '[:space:]')"
  [ "${v}" = "true" ] && printf 'true' || printf 'false'
}
DB_RUNNING="$(container_running "${DB_CT}")"
ETCD_RUNNING="$(container_running "${ETCD_REAL}")"

# ── Step 2: configuration — topology verbatim, secrets as fingerprints ──────
# Two classes, and the split is the whole diagnostic value. Cluster-wide values
# MUST be byte-identical everywhere (a differing SECRET_KEY breaks logins across
# nodes, a differing replication password breaks every join, #36). Per-node
# values MUST differ. Printing both classes in a fixed order makes two bundles
# diff cleanly; the cluster-fingerprint below collapses the first class to one
# line so they usually need not be diffed at all.
step "reading the declared configuration"
CLUSTER_WIDE_KEYS="TARANAC_CLUSTER_NAME TARANAC_CLUSTER_ID POSTGRES_PASSWORD POSTGRES_REPLICATION_PASSWORD SECRET_KEY MASTER_KEY TARANAC_MFA_API_KEY PATRONI_REST_PASSWORD"
CLUSTER_FP_INPUT=""
{
  echo "Declared topology (verbatim — none of this is secret)"
  echo "===================================================="
  for k in TARANAC_HA TARANAC_CLUSTER_NAME TARANAC_NODE_NAME NODE_ADDRESS \
           DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE \
           ETCD_NAME ETCD_CLIENT_SCHEME ETCD_PEER_SCHEME ETCD_PEER_AUTO_TLS \
           ETCD_SERVER_CERT_FILE ETCD_SERVER_KEY_FILE ETCD_CLIENT_CACERT \
           PG_ALLOW_CIDR DB_CONNECT_TIMEOUT PATRONI_REST_USERNAME TARANAC_VERSION \
           TARANAC_CLUSTER_FORMED_AT; do
    v="$(getenv "${k}")"
    printf '%-32s %s\n' "${k}" "${v:-(absent)}"
  done
  echo
  echo "Cluster-wide values — MUST be identical on every node"
  echo "===================================================="
  echo "(12-hex sha256 fingerprints; the values themselves are never collected)"
  for k in ${CLUSTER_WIDE_KEYS}; do
    v="$(getenv "${k}")"
    f="$(fp "${v}")"
    printf '%-32s %s\n' "${k}" "${f}"
    CLUSTER_FP_INPUT="${CLUSTER_FP_INPUT}${k}=${f};"
  done
  echo
  echo "Per-node values — MUST differ between nodes"
  echo "==========================================="
  for k in TARANAC_NODE_NAME NODE_ADDRESS ETCD_NAME; do
    printf '%-32s %s\n' "${k}" "$(getenv "${k}")"
  done
} > "${WORK}/config.txt" 2>&1

CLUSTER_FP="$(printf '%s' "${CLUSTER_FP_INPUT}" | sha256sum 2>/dev/null | cut -c1-12)"

# ── Step 3: the manifest — what this node DECLARES the cluster to be ────────
step "reading config/cluster.yml"
{
  echo "config/cluster.yml"
  echo "=================="
  if [ -f "${HERE}/config/cluster.yml" ]; then
    if [ -x "${HERE}/cluster-manifest.py" ] && have python3; then
      echo "--- validate ---"
      python3 "${HERE}/cluster-manifest.py" validate 2>&1 || true
      echo
      echo "--- list ---"
      python3 "${HERE}/cluster-manifest.py" list 2>&1 || true
    else
      echo "(cluster-manifest.py not usable here — raw file follows)"
    fi
    echo
    echo "--- raw ---"
    cat "${HERE}/config/cluster.yml" 2>/dev/null || echo "(unreadable)"
  else
    echo "(absent — this node declares no topology of its own)"
  fi
} > "${WORK}/manifest.txt" 2>&1

# ── Step 4: Patroni — the authority on roles, timelines and lag ─────────────
# Asked LOCALLY first, then at every declared database member. On a node whose
# own database will not start, a peer's REST still returns the whole ring —
# including the timeline history that explains why this node will not start.
# Reads need no credential (ha.md §13.3), which is what makes this possible
# without ever handling PATRONI_REST_PASSWORD.
step "asking Patroni for the cluster's real state"
PATRONI_SOURCE=""
patroni_try() {  # <host> ; 0 if it answered
  local h="$1" body
  body="$(curl -fsS --max-time 5 "http://${h}:8008/cluster" 2>/dev/null)" || return 1
  [ -n "${body}" ] || return 1
  printf '%s' "${body}" > "${WORK}/patroni-cluster.json"
  curl -fsS --max-time 5 "http://${h}:8008/config"  2>/dev/null > "${WORK}/patroni-config.json"  || true
  curl -fsS --max-time 5 "http://${h}:8008/history" 2>/dev/null > "${WORK}/patroni-history.json" || true
  PATRONI_SOURCE="${h}"
  return 0
}
if have curl; then
  patroni_try 127.0.0.1 || true
  if [ -z "${PATRONI_SOURCE}" ]; then
    for i in "${!MEMBER_ADDRS[@]}"; do
      # A witness's .env has no DB_HOSTS, so by config every member looks etcd-only
      # there; its own ring view needs Patroni's answer too, so it asks every peer.
      if [ "${MEMBER_ROLES[$i]}" != "db" ]; then
        [ "${ROLE_GUESS}" = "witness (etcd only)" ] && ! is_self "${i}" || continue
      fi
      patroni_try "${MEMBER_ADDRS[$i]}" && break
    done
  fi
else
  note "curl is not installed on this host — Patroni's view could not be collected"
fi

# The local node's own Patroni opinion, which is a different question from the
# ring's: "what does THIS node think it is" vs "what does the cluster think".
if have curl; then
  curl -fsS --max-time 5 "http://127.0.0.1:8008/patroni" 2>/dev/null > "${WORK}/patroni-local.json" || true
fi

# patronictl, when the container is up — it renders what the operator sees in the
# playbook, and having both makes a REST/CLI disagreement visible.
if [ "${DB_RUNNING}" = "true" ]; then
  docker exec "${DB_CT}" patronictl -c /tmp/patroni.yml list \
    > "${WORK}/patronictl-list.txt" 2>&1 || true
fi

# Cross-node clock skew, for free: an HTTP Date header from a peer's Patroni,
# compared with ours. Patroni's leases are time-based, so skew is not cosmetic —
# and this is the only cross-node measurement a single bundle can make honestly.
CLOCK_REPORT=""
if have curl && [ "${DECLARED_MEMBERS}" -gt 0 ]; then
  for i in "${!MEMBER_ADDRS[@]}"; do
    [ "${MEMBER_ROLES[$i]}" = "db" ] || continue
    is_self "${i}" && continue
    # GET /patroni, not HEAD / — and both halves of that were wrong before, which
    # is why this file was never produced on a primary. `/` is Patroni's LEADER
    # endpoint: it answers 503 on every replica, and `curl -f` then threw the
    # response away, so a primary (whose peers are all replicas) measured nothing
    # and wrote no file at all. And `-I` sends HEAD, which Patroni answers without
    # a Date header on any node — so even the leader's reply carried nothing to
    # compare. /patroni answers 200 on any running member and carries the header.
    # Measured on the stand: HEAD / → no Date; GET /patroni → Date, on both roles.
    peer_date="$(curl -fsS -D - -o /dev/null --max-time 5 "http://${MEMBER_ADDRS[$i]}:8008/patroni" 2>/dev/null \
      | grep -i '^date:' | head -1 | cut -d' ' -f2- | tr -d '\r' || true)"
    [ -n "${peer_date}" ] || continue
    peer_epoch="$(date -d "${peer_date}" +%s 2>/dev/null || true)"
    [ -n "${peer_epoch}" ] || continue
    now_epoch="$(date +%s)"
    skew=$(( peer_epoch - now_epoch )); skew=${skew#-}
    CLOCK_REPORT="${CLOCK_REPORT}${MEMBER_NAMES[$i]} ${skew}s"$'\n'
    if [ "${skew}" -gt "${CLOCK_WARN_SEC}" ]; then
      finding "[CLOCK]    This node's clock differs from ${MEMBER_NAMES[$i]} (${MEMBER_ADDRS[$i]}) by ${skew}s.
           Patroni's leader lease is time-based: a skew of this size makes lease
           expiry and renewal disagree between nodes, which shows up as failovers
           that should not have happened. Put both hosts on the same NTP source."
    fi
  done
fi
[ -n "${CLOCK_REPORT}" ] && printf '%s' "${CLOCK_REPORT}" > "${WORK}/clock-skew.txt"

# ── Step 5: etcd — the ring, and whether it agrees with .env ────────────────
step "asking etcd about the ring"
ETCD_CTL_MOUNT=(); ETCD_CTL_TLS=()
if [ "${ETCD_CLIENT_SCHEME}" = "https" ] && [ -s "${HERE}/config/etcd-tls/ca.crt" ]; then
  ETCD_CTL_MOUNT=(-v "${HERE}/config/etcd-tls:/tls:ro")
  ETCD_CTL_TLS=(--cacert=/tls/ca.crt)
fi
etcdctl_run() {  # everything after the endpoint flags
  if [ "${ETCD_RUNNING}" = "true" ]; then
    # The container carries ETCDCTL_ENDPOINTS + ETCDCTL_CACERT already, so this
    # is correct under client-TLS with no flags of our own.
    docker exec "${ETCD_REAL}" etcdctl "$@" 2>&1 && return 0
  fi
  local i
  for i in "${!MEMBER_ADDRS[@]}"; do
    docker run --rm "${ETCD_CTL_MOUNT[@]+"${ETCD_CTL_MOUNT[@]}"}" "${ETCD_IMAGE}" etcdctl \
      --endpoints="${ETCD_CLIENT_SCHEME}://${MEMBER_ADDRS[$i]}:2379" \
      "${ETCD_CTL_TLS[@]+"${ETCD_CTL_TLS[@]}"}" "$@" 2>&1 && return 0
  done
  return 1
}
{
  echo "etcd"
  echo "===="
  echo "local container running : ${ETCD_RUNNING}"
  echo "client scheme           : ${ETCD_CLIENT_SCHEME}"
  echo "peer scheme             : ${ETCD_PEER_SCHEME}"
  echo "initial cluster state   : ${ETCD_STATE:-(absent)}"
  echo
  echo "--- member list ---"
  echo "(a member with no client URL is DECLARED BUT NOT RUNNING — etcd calls it"
  echo " 'unstarted'. A 'learner' is present but does NOT vote.)"
  etcdctl_run member list -w table || echo "(no etcd endpoint could be reached from this node)"
  echo
  echo "--- endpoint health (whole ring) ---"
  etcdctl_run endpoint health --cluster || echo "(unavailable)"
  echo
  echo "--- endpoint status (raft term/index per member) ---"
  etcdctl_run endpoint status --cluster -w table || echo "(unavailable)"
} > "${WORK}/etcd.txt" 2>&1

# The SAME listing again as json, and every etcd verdict below is computed from
# THIS file rather than from the human table above. Grepping the rendered table
# for words like "unstarted" also matches the sentence that EXPLAINS what
# unstarted means — a collector that reports a fault because of its own help text
# is worse than one that reports nothing. (Found exactly that way on a stand where
# all four members were started.)
etcdctl_run member list -w json > "${WORK}/etcd-members.json" 2>/dev/null || true

ETCD_MEMBER_COUNT=0; ETCD_UNSTARTED=""; ETCD_LEARNERS=""
if [ -s "${WORK}/etcd-members.json" ] && have python3; then
  ETCD_FACTS="$(python3 - "${WORK}/etcd-members.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
members = d.get("members", [])
# A member that has never started has no clientURLs (and usually no name yet):
# etcd counts it for quorum regardless, which is the whole point of reporting it.
unstarted = [m.get("name") or "(unnamed)" for m in members if not m.get("clientURLs")]
learners = [m.get("name") or "(unnamed)" for m in members if m.get("isLearner")]
print(len(members))
print(" ".join(unstarted))
print(" ".join(learners))
PY
)"
  ETCD_MEMBER_COUNT="$(printf '%s' "${ETCD_FACTS}" | sed -n 1p | tr -d '[:space:]')"
  ETCD_UNSTARTED="$(printf '%s' "${ETCD_FACTS}" | sed -n 2p)"
  ETCD_LEARNERS="$(printf '%s' "${ETCD_FACTS}" | sed -n 3p)"
fi
case "${ETCD_MEMBER_COUNT}" in ''|*[!0-9]*) ETCD_MEMBER_COUNT=0 ;; esac

# ── Step 5b: the ring as MACHINES — the witness included ─────────────────────
# `cluster status` on a database node now shows every machine of the ring as a
# row, the witness among them, and judges "can any one machine be lost". A witness
# has no api to run that on, and a database node whose api is down cannot run it
# either — so the same judgement is made here from what this host can read itself:
# the live member list, each member's OWN health (serializable — an election does
# not read as a whole-ring outage), the updater's version record of each member
# (/taranac/update/members/*) and the departed-witness records (/taranac/departed/*).
# No python: the witness does not promise one. Records are flat key=value strings
# the updater writes about its own member — versions, states, addresses; no secret.
step "reading every ring member's own health and version record"
ETCD_CA_FILE=""
for _ca in "${HERE}/config/etcd-tls/ca.crt" "${HERE}/config/etcd-ca/ca.crt"; do
  [ -r "${_ca}" ] && [ -s "${_ca}" ] && { ETCD_CA_FILE="${_ca}"; break; }
done

etcd_kv_prefix() {  # <prefix> → "key<TAB>value" lines
  etcdctl_run get --prefix "$1" 2>/dev/null | awk -v p="$1" '
    index($0, p) == 1 { k = $0; next }
    k != "" { print k "\t" $0; k = "" }'
}
record_field() {  # <record> <field>
  printf '%s' ";$1;" | sed -n "s/.*;$2=\([^;]*\);.*/\1/p"
}
member_health() {  # <client url> → prints "healthy" or "down|<reason>"
  local url="$1" body opts=()
  if have curl && { [ "${url#https://}" = "${url}" ] || [ -n "${ETCD_CA_FILE}" ]; }; then
    [ -n "${ETCD_CA_FILE}" ] && opts=(--cacert "${ETCD_CA_FILE}")
    if body="$(curl -sS --max-time 3 "${opts[@]+"${opts[@]}"}" "${url}/health?serializable=true" 2>&1)"; then
      case "${body}" in
        *'"health":"true"'*) printf 'healthy'; return 0 ;;
        *) printf 'down|%s' "$(printf '%s' "${body}" | tr -d '\n' | cut -c1-160)"; return 0 ;;
      esac
    fi
    printf 'down|%s' "$(printf '%s' "${body}" | tr -d '\n' | sed 's/^curl: ([0-9]*) //' | cut -c1-160)"
    return 0
  fi
  if [ "${ETCD_RUNNING}" = "true" ]; then
    body="$(docker exec "${ETCD_REAL}" etcdctl --endpoints="${url}" --command-timeout=3s endpoint health 2>&1)"
    case "${body}" in
      *"is healthy"*) printf 'healthy' ;;
      *) printf 'down|%s' "$(printf '%s' "${body}" | grep -v '^{' | tail -1 | cut -c1-160)" ;;
    esac
    return 0
  fi
  printf 'unknown|no way to ask it from this host (no curl with the etcd CA, no local etcd container)'
}

# The roster, where this host has one (a database node): who is a database node.
ROSTER_ROWS=""
if [ "${DB_RUNNING}" = "true" ]; then
  ROSTER_ROWS="$(docker exec "${DB_CT}" psql -U taranac -d taranac -tAc \
    "select name || '|' || coalesce(address, '') from cluster_nodes where status = 'active' order by name" \
    2>/dev/null || true)"
fi
roster_has() {  # <name> <address>
  [ -n "${ROSTER_ROWS}" ] || return 1
  printf '%s\n' "${ROSTER_ROWS}" | grep -qE "^$1\|" && return 0
  [ -n "$2" ] && printf '%s\n' "${ROSTER_ROWS}" | grep -qE "\|$2\$"
}

# Only asked when the ring answered the json listing above: on a node that reaches
# no member every etcdctl call costs a container start and a timeout per member,
# and these three would only repeat that "no".
UPDATE_RECORDS=""; DEPARTED_RECORDS=""; RING_LIST=""
if [ -s "${WORK}/etcd-members.json" ]; then
  UPDATE_RECORDS="$(etcd_kv_prefix /taranac/update/members/ || true)"
  DEPARTED_RECORDS="$(etcd_kv_prefix /taranac/departed/ || true)"
  RING_LIST="$(etcdctl_run member list -w simple 2>/dev/null || true)"
fi
RING_READ=0
RING_N=(); RING_ADDR=(); RING_KIND=(); RING_LEARNER=(); RING_HEALTH=(); RING_REASON=(); RING_VERSION=()
while IFS= read -r line; do
  # id, status, name, peer-url(s), client-url(s), is-learner
  printf '%s' "${line}" | grep -qE '^[0-9a-f]+, (started|unstarted),' || continue
  RING_READ=1
  IFS=',' read -r _id _st _name _peer _client _learner <<< "${line}"
  _name="$(printf '%s' "${_name}" | tr -d ' ')"; _peer="$(printf '%s' "${_peer}" | tr -d ' ')"
  # The learner flag is the LAST field whatever came before it.
  _client="$(printf '%s' "${_client}" | tr -d ' ')"; _learner="$(printf '%s' "${line##*,}" | tr -d ' ')"
  _addr="${_peer#*://}"; _addr="${_addr%%:*}"
  _rec=""
  [ -n "${_name}" ] && _rec="$(printf '%s\n' "${UPDATE_RECORDS}" | awk -F'\t' -v k="/taranac/update/members/${_name}" '$1 == k { print $2; exit }')"
  _role="$(record_field "${_rec}" role)"
  if [ -z "${_name}" ]; then
    _kind="unstarted"
  elif [ "${_role}" = "db" ] || [ "${_role}" = "witness" ]; then
    _kind="${_role}"
  elif roster_has "${_name}" "${_addr}" || { [ -n "${DB_HOSTS}" ] && printf '%s' "${DB_HOSTS}" | grep -qF -- "${_addr}:"; }; then
    _kind="db"
  else
    _kind="witness"
  fi
  if [ -z "${_client}" ]; then
    _h="down|never started (no client URL)"
  else
    _h="$(member_health "${_client%%;*}")"
  fi
  RING_N+=("${_name:-(unstarted)}"); RING_ADDR+=("${_addr}"); RING_KIND+=("${_kind}")
  RING_LEARNER+=("${_learner}"); RING_HEALTH+=("${_h%%|*}"); RING_REASON+=("$([ "${_h#*|}" != "${_h}" ] && printf '%s' "${_h#*|}")")
  RING_VERSION+=("$(record_field "${_rec}" version)")
done <<< "${RING_LIST}"

RING_VOTERS=0; RING_HEALTHY=0; RING_DOWN=""; RING_UNKNOWN=""; RING_MACHINES=""; RING_DB_NAMES=""
for i in "${!RING_N[@]}"; do
  [ "${RING_KIND[$i]}" = "db" ] && RING_DB_NAMES="${RING_DB_NAMES}${RING_N[$i]} "
  [ "${RING_LEARNER[$i]}" = "true" ] && continue
  RING_VOTERS=$((RING_VOTERS + 1))
  case "${RING_HEALTH[$i]}" in
    healthy) RING_HEALTHY=$((RING_HEALTHY + 1)); RING_MACHINES="${RING_MACHINES:+${RING_MACHINES}, }${RING_N[$i]}" ;;
    unknown) RING_UNKNOWN="${RING_UNKNOWN:+${RING_UNKNOWN}, }${RING_N[$i]}" ;;
    *)       RING_DOWN="${RING_DOWN:+${RING_DOWN}, }${RING_N[$i]}" ;;
  esac
done
RING_MAJORITY=$((RING_VOTERS / 2 + 1))

{
  echo "The ring as machines — seen from ${NODE_NAME}"
  echo "=============================================="
  echo "Each member is asked about ITSELF (/health?serializable=true), so an etcd"
  echo "election does not read as every member being down. Kind: db = a database"
  echo "node, witness = etcd only. VERSION is the member's own updater record."
  echo
  if [ "${RING_READ}" -ne 1 ]; then
    echo "(the member list could not be read from this host — see etcd.txt)"
  else
    printf '%-22s %-16s %-9s %-8s %-9s %s\n' NAME ADDRESS KIND VOTING HEALTH VERSION
    for i in "${!RING_N[@]}"; do
      _vote="yes"; [ "${RING_LEARNER[$i]}" = "true" ] && _vote="learner"
      printf '%-22s %-16s %-9s %-8s %-9s %s\n' "${RING_N[$i]}" "${RING_ADDR[$i]:-?}" "${RING_KIND[$i]}" \
        "${_vote}" "${RING_HEALTH[$i]}" "${RING_VERSION[$i]:-—}"
      [ -n "${RING_REASON[$i]}" ] && printf '    └ %s\n' "${RING_REASON[$i]}"
    done
    echo
    echo "voting members: ${RING_VOTERS}   answering: ${RING_HEALTHY}   majority needed: ${RING_MAJORITY}"
  fi
  echo
  echo "--- updater records (/taranac/update/members/*) ---"
  if [ -n "${UPDATE_RECORDS}" ]; then printf '%s\n' "${UPDATE_RECORDS}" | sed 's/\t/  /'; else echo "(none, or not readable)"; fi
  echo
  echo "--- departed witnesses (/taranac/departed/*) — removed from the ring by remove-witness ---"
  if [ -n "${DEPARTED_RECORDS}" ]; then printf '%s\n' "${DEPARTED_RECORDS}" | sed 's/\t/  /'; else echo "(none)"; fi
} > "${WORK}/ring.txt" 2>&1

if [ "${RING_READ}" -eq 1 ]; then
  for i in "${!RING_N[@]}"; do
    [ "${RING_HEALTH[$i]}" = "down" ] || continue
    _what="database node"; [ "${RING_KIND[$i]}" = "witness" ] && _what="witness"
    [ "${RING_KIND[$i]}" = "unstarted" ] && _what="member that was added and never started"
    if [ "${RING_KIND[$i]}" = "unstarted" ]; then
      finding "[RING]     An etcd member at ${RING_ADDR[$i]:-?} was added but never started (an interrupted add).
           It counts against quorum while doing nothing. Take it out of the ring, on a
           database node:
               ./taranac cluster remove-node --node ${RING_ADDR[$i]:-<address>}"
    else
      finding "[RING]     ${RING_N[$i]} (${_what}, ${RING_ADDR[$i]:-?}) does not answer its own etcd health check:
             ${RING_REASON[$i]:-no reason given}
           ${RING_HEALTHY} of ${RING_VOTERS} voting members answer; ${RING_MAJORITY} are needed for writes.
           On that machine:  ./taranac up -d   — then run this collector there too."
    fi
  done
fi
# A departed witness is reported by the leader from its record: alive=1 (it was
# running when it was removed) until --leave deletes the record. This collector
# says the same, and also names one recorded dead that answers now (it came back).
while IFS=$'\t' read -r _k _v; do
  [ -n "${_k}" ] || continue
  _a="$(record_field "${_v}" address)"; _a="${_a:-${_k#/taranac/departed/}}"
  if [ "$(record_field "${_v}" alive)" = 1 ] || tcp_open "${_a}" 2379 || tcp_open "${_a}" 2380; then
    finding "[DEPARTED] ${_a} was removed from the ring (remove-witness) while its etcd ran, and that
           host has not left yet. It holds no vote and no data, but it is still set up as a
           witness and keeps restarting its etcd. On that host:
               ./witness-join.sh --leave
           If that machine is gone for good, on any database node:
               ./taranac cluster remove-witness --forget ${_a}"
  fi
done <<< "${DEPARTED_RECORDS}"

# ── Step 6: Postgres — timeline, lag, slots, WAL ────────────────────────────
# pg_controldata comes from the DATA VOLUME with a throwaway container, not from
# taranac-db. That is deliberate: the timeline of a node whose database refuses
# to start is precisely the number that explains why, and asking the dead
# container for it would return nothing at the moment it matters most.
step "reading this node's database state"
LOCAL_TIMELINE=""
LOCAL_CHECKPOINT=""
{
  echo "Postgres (this node)"
  echo "===================="
  echo "taranac-db running : ${DB_RUNNING}"
  echo "image              : ${DB_IMAGE:-(no container)}"
  echo
  echo "--- pg_controldata (read from the ${PG_VOL} volume, works with the DB down) ---"
  if docker volume inspect "${PG_VOL}" >/dev/null 2>&1; then
    docker run --rm -v "${PG_VOL}:/d" "${PROBE_IMAGE}" pg_controldata /d 2>&1 \
      | grep -Ei 'state|timeline|checkpoint location|REDO location|system identifier|Latest checkpoint.s (TimeLineID|NextXID)' \
      || echo "(pg_controldata could not read the volume)"
  else
    echo "(the ${PG_VOL} volume does not exist on this host)"
  fi
  echo
  echo "--- WAL directory size ---"
  if docker volume inspect "${PG_VOL}" >/dev/null 2>&1; then
    docker run --rm -v "${PG_VOL}:/d" "${PROBE_IMAGE}" du -sh /d/pg_wal 2>/dev/null || echo "(unavailable)"
  fi
  echo
  if [ "${DB_RUNNING}" = "true" ]; then
    echo "--- in recovery? (t = replica, f = primary) ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -tAc 'select pg_is_in_recovery()' 2>&1 || echo "(query failed)"
    echo
    echo "--- pg_stat_replication (rows only on the primary) ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -c \
      "select application_name, state, sync_state, write_lag, flush_lag, replay_lag,
              pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as behind_bytes
         from pg_stat_replication order by application_name" 2>&1 || echo "(query failed)"
    echo
    echo "--- replication slots (an inactive slot pins WAL forever) ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -c \
      "select slot_name, slot_type, active,
              pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained
         from pg_replication_slots order by slot_name" 2>&1 || echo "(query failed)"
    echo
    echo "--- synchronous_standby_names ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -tAc 'show synchronous_standby_names' 2>&1 || echo "(query failed)"
    echo
    echo "--- receive / replay position (a replica reports both; a primary neither) ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -c \
      "select pg_last_wal_receive_lsn() as received, pg_last_wal_replay_lsn() as replayed" 2>&1 \
      || echo "(query failed)"
  else
    echo "--- live queries skipped: taranac-db is not running ---"
    echo "That is not necessarily wrong — but if this node is meant to be serving,"
    echo "its container log (logs/db.log in this bundle) says why it stopped."
  fi
} > "${WORK}/postgres.txt" 2>&1

LOCAL_TIMELINE="$(grep -iE "Latest checkpoint's TimeLineID" "${WORK}/postgres.txt" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '[:space:]' || true)"
LOCAL_CHECKPOINT="$(grep -iE "Latest checkpoint location" "${WORK}/postgres.txt" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '[:space:]' || true)"

# ── Step 6b: write routing — where each node sends its writes, against the roster ─
# Every member routes writes to the addresses in its copy of the roster (the api
# publishes the list as EFFECTIVE_DB_HOSTS in its heartbeat and writes it into each
# daemon's volume as write_hosts.conf). A node whose list lacks a member stops
# writing the moment that member leads. The heartbeat rows are read cluster-wide
# from this node's database; the files are this host's own.
WRITE_GAPS=""
if [ "${DB_RUNNING}" = "true" ]; then
  step "comparing every node's write routing with the roster"
  {
    echo "Write routing vs roster"
    echo "======================="
    echo "roster (active):"
    if [ -n "${ROSTER_ROWS}" ]; then printf '%s\n' "${ROSTER_ROWS}" | sed 's/|/  /; s/^/  /'; else echo "  (unreadable)"; fi
    echo
    echo "--- each node's published list (heartbeat: EFFECTIVE_DB_HOSTS) ---"
    docker exec "${DB_CT}" psql -U taranac -d taranac -tAc \
      "select n.name || '  ' || coalesce(r.config_values->>'EFFECTIVE_DB_HOSTS', '(not published — an older version, or silent)')
              || '  (' || coalesce(extract(epoch from (now() - r.updated_at))::int || 's ago', 'never') || ')'
         from cluster_nodes n left join node_config_reports r on r.node_id = n.id
        where n.status = 'active' order by n.name" 2>/dev/null | sed 's/^/  /' || echo "  (query failed)"
    echo
    echo "--- this host's daemons (write_hosts.conf) ---"
    for _d in taranac-tacacs:/etc/tac_plus taranac-radius:/etc/raddb taranac-nac:/etc/raddb taranac-mfa:/opt/taranac/certs; do
      _ct="${_d%%:*}"; _path="${_d#*:}"
      if docker inspect "${_ct}" >/dev/null 2>&1; then
        _wh="$(docker exec "${_ct}" cat "${_path}/write_hosts.conf" 2>/dev/null | tr -d '[:space:]' || true)"
        printf '  %-16s %s\n' "${_ct}" "${_wh:-(no write_hosts.conf — it routes by DB_HOSTS from .env)}"
        if [ -n "${_wh}" ] && [ -n "${ROSTER_ROWS}" ]; then
          while IFS='|' read -r _rn _ra; do
            [ -n "${_ra}" ] || continue
            case ",${_wh}," in *",${_ra}:"*) ;; *) WRITE_GAPS="${WRITE_GAPS}${_ct} misses ${_rn} (${_ra}); " ;; esac
          done <<< "${ROSTER_ROWS}"
        fi
      else
        printf '  %-16s %s\n' "${_ct}" "(not running here)"
      fi
    done
  } > "${WORK}/write-routing.txt" 2>&1
fi
if [ -n "${WRITE_GAPS}" ]; then
  finding "[ROUTING]  On this node, a daemon's write list does not name every roster member:
             ${WRITE_GAPS}
           When that member leads, this daemon cannot write (accounting, sessions).
           The api rewrites the file every 15s from the roster; if it stays short, the
           api here is not running or cannot read the roster. Restart it:
               ./taranac up -d api"
fi

# ── Step 7: reachability — this node to every declared member ──────────────
# Directional on purpose. Run on every node, N of these bundles ARE the full N×N
# matrix, asymmetry included — and asymmetric reachability (A sees B, B does not
# see A) is a different fault from a host being down, with a different cure.
#
# 2380 is probed as well as 2379. The peer port is the one the join tooling has
# never checked, and a ring whose members cannot reach each other's peer port
# forms no quorum while every client-port check looks perfect.
step "probing reachability to every declared member"
UNREACH=""
{
  echo "Reachability — FROM this node (${NODE_NAME}) TO each declared member"
  echo "===================================================================="
  echo "Ports: 2379 etcd client · 2380 etcd peer · 5432 Postgres · 8008 Patroni REST · 443 api"
  echo "A witness legitimately has ONLY the etcd ports open."
  echo
  if [ "${DECLARED_MEMBERS}" -eq 0 ]; then
    echo "(no members are declared on this node — nothing to probe)"
  else
    printf '%-22s %-16s %-6s %-6s %-6s %-6s %-6s\n' NAME ADDRESS 2379 2380 5432 8008 443
    # Probed ONCE, with the findings accumulated in the same pass. A brace group
    # does not fork, so UNREACH survives the redirection — and on the partitioned
    # cluster this is written for, a second pass would double the slowest part of
    # the run (every closed port costs the full timeout).
    for i in "${!MEMBER_ADDRS[@]}"; do
      row=""
      for port in 2379 2380 5432 8008 443; do
        # A witness has no database, api or Patroni: those ports being shut is
        # correct there, and calling it unreachable would be a manufactured fault.
        expected="yes"
        if [ "${MEMBER_ROLES[$i]}" != "db" ] && [ "${port}" != "2379" ] && [ "${port}" != "2380" ]; then
          expected="no"
        fi
        if tcp_open "${MEMBER_ADDRS[$i]}" "${port}"; then
          row="${row} open  "
        else
          row="${row} --    "
          if [ "${expected}" = "yes" ] && ! is_self "${i}"; then
            UNREACH="${UNREACH}${MEMBER_NAMES[$i]}:${port} "
          fi
        fi
      done
      printf '%-22s %-16s%s  (%s)\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "${row}" "${MEMBER_ROLES[$i]}"
    done
  fi
  echo
  echo "--- round-trip time ---"
  if have ping; then
    for i in "${!MEMBER_ADDRS[@]}"; do
      printf '%-22s %s\n' "${MEMBER_NAMES[$i]}" \
        "$(ping -c 3 -W 2 "${MEMBER_ADDRS[$i]}" 2>/dev/null | tail -1 || echo 'no reply')"
    done
  else
    echo "(ping is not available on this host)"
  fi
  echo
  echo "--- replicator login, every ordered pair (the api's own continuous probe) ---"
  echo "'stale' and 'unknown' are NOT successes. A red cell is usually a PG_ALLOW_CIDR"
  echo "on the SOURCE node that does not cover the target."
  if docker inspect -f '{{.State.Running}}' "${API_CT}" >/dev/null 2>&1; then
    docker compose --env-file "${ENV_FILE}" -f "${HERE}/docker-compose.yml" exec -T api \
      python -m app.scripts.cluster connectivity 2>&1 || echo "(connectivity check unavailable)"
  else
    echo "(the api container is not running on this node — skipped)"
  fi
} > "${WORK}/reachability.txt" 2>&1

# ── Step 8: certificates ────────────────────────────────────────────────────
# The SAN check is the one that earns its place: a node whose address changed
# (or was mistyped into .env and then ingested into cluster state) keeps a leaf
# that does not cover the address it now advertises, and every TLS client fails
# with an error about a name rather than about an address.
step "checking the etcd certificates"
CERT_END_EPOCH=""
{
  echo "etcd client-TLS material"
  echo "========================"
  if [ -s "${HERE}/config/etcd-tls/ca.crt" ]; then
    echo "CA fingerprint (compare across nodes — it MUST be the same everywhere):"
    openssl x509 -in "${HERE}/config/etcd-tls/ca.crt" -noout -fingerprint -sha256 2>/dev/null \
      | sed 's/^/  /' || echo "  (openssl could not read it)"
    echo "CA validity:"
    openssl x509 -in "${HERE}/config/etcd-tls/ca.crt" -noout -dates 2>/dev/null | sed 's/^/  /' || true
  else
    echo "(no config/etcd-tls/ca.crt — client TLS is off, or this node was never provisioned)"
  fi
  echo
  if [ -s "${HERE}/config/etcd-tls/etcd-server.crt" ]; then
    echo "This node's etcd leaf:"
    openssl x509 -in "${HERE}/config/etcd-tls/etcd-server.crt" -noout -subject -dates 2>/dev/null | sed 's/^/  /' || true
    echo "  SANs:"
    openssl x509 -in "${HERE}/config/etcd-tls/etcd-server.crt" -noout -ext subjectAltName 2>/dev/null \
      | tail -n +2 | sed 's/^/    /' || echo "    (none)"
  else
    echo "(this node has no etcd leaf at config/etcd-tls/etcd-server.crt)"
  fi
} > "${WORK}/certs.txt" 2>&1

if [ -s "${HERE}/config/etcd-tls/etcd-server.crt" ] && have openssl; then
  not_after="$(openssl x509 -in "${HERE}/config/etcd-tls/etcd-server.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [ -n "${not_after}" ]; then
    CERT_END_EPOCH="$(date -d "${not_after}" +%s 2>/dev/null || true)"
    if [ -n "${CERT_END_EPOCH}" ]; then
      days_left=$(( (CERT_END_EPOCH - $(date +%s)) / 86400 ))
      if [ "${days_left}" -lt "${CERT_WARN_DAYS}" ]; then
        finding "[CERT]     This node's etcd certificate expires in ${days_left} day(s) (${not_after}).
           When it does, this member drops out of the ring and Patroni loses its
           DCS on this node. Re-issue it from the seed before then."
      fi
    fi
  fi
  if [ -n "${NODE_ADDRESS}" ]; then
    if ! openssl x509 -in "${HERE}/config/etcd-tls/etcd-server.crt" -noout -ext subjectAltName 2>/dev/null \
         | grep -qF -- "${NODE_ADDRESS}"; then
      finding "[CERT]     This node advertises ${NODE_ADDRESS}, but its etcd certificate does NOT
           cover that address in its SANs (see certs.txt). Every TLS client will
           reject it — usually reported as a name mismatch rather than as a wrong
           address. This is what a changed or mistyped node address looks like."
    fi
  fi
fi

# ── Step 9: logs ────────────────────────────────────────────────────────────
step "collecting component logs (last ${LOG_LINES} lines each)"
for ct in taranac-db "${ETCD_CT}" taranac-api; do
  real_ct="$(resolve_container "${ct}")"
  if docker inspect "${real_ct}" >/dev/null 2>&1; then
    docker logs --tail "${LOG_LINES}" "${real_ct}" > "${WORK}/logs/${ct#taranac-}.log" 2>&1 || true
  fi
done

# The update finisher (a DB node mid-update hands the rest of its start to it) and
# the updater's own trail. Neither carries a secret by construction; a defensive
# filter masks anything shaped like KEY=value for a sensitive key all the same.
# A DSN carries its password inline (postgresql://user:pass@host) — masked too.
redact() { sed -E -e 's/((PASSWORD|SECRET|MASTER_KEY|TOKEN|API_KEY)[A-Z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1<redacted>/g' \
                  -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@[:space:]]+:)[^@[:space:]]+@#\1<redacted>@#g'; }
FINISHER_STATE="$(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}}, started {{.State.StartedAt}})' taranac-update-finisher 2>/dev/null || true)"
if [ -n "${FINISHER_STATE}" ]; then
  docker logs --tail "${LOG_LINES}" taranac-update-finisher 2>&1 | redact > "${WORK}/logs/update-finisher.log" || true
fi
if [ -r "${HERE}/.taranac-update.log" ]; then
  tail -n "${LOG_LINES}" "${HERE}/.taranac-update.log" 2>/dev/null | redact > "${WORK}/logs/taranac-update.log" || true
fi
{
  echo "update finisher container : ${FINISHER_STATE:-(none on this host)}"
  echo "updater trail             : $([ -r "${HERE}/.taranac-update.log" ] && echo "${HERE}/.taranac-update.log (tail in logs/taranac-update.log)" || echo '(none)')"
} >> "${WORK}/node.txt"
# What to do next while a finisher runs — from the cluster's own update plan (the
# same order the updater enforces: every replica, then the leader), never a generic
# "see --check": the operator reading this needs the one machine to go to, or to be
# told that there is nothing to run and how to watch it finish.
case "${FINISHER_STATE}" in
  running*)
    _self_name="${ETCD_NAME_ENV:-${NODE_NAME}}"
    _rec_of() { printf '%s\n' "${UPDATE_RECORDS}" | awk -F'\t' -v k="/taranac/update/members/$1" '$1 == k { print $2; exit }'; }
    _self_rec="$(_rec_of "${_self_name}")"
    _self_ver="$(record_field "${_self_rec}" version)"
    _leader="$(etcdctl_run get --print-value-only "/service/${CLUSTER_NAME:-taranac}/leader" 2>/dev/null | grep -v '^{' | head -1 | tr -d '[:space:]' || true)"
    _watch="Watch it finish here:  docker logs -f taranac-update-finisher"
    _next=""; _next_addr=""; _leader_on=""; _self_is_leader=0
    if [ -n "${_leader}" ] && { [ "${_leader}" = "${_self_name}" ] || [ "${_leader}" = "${NODE_NAME}" ]; }; then _self_is_leader=1; fi
    for i in "${!RING_N[@]}"; do
      [ "${RING_KIND[$i]}" = "db" ] || continue
      _rn="$(record_field "$(_rec_of "${RING_N[$i]}")" node)"
      if [ -n "${_leader}" ] && { [ "${RING_N[$i]}" = "${_leader}" ] || [ "${_rn}" = "${_leader}" ]; }; then
        [ "${RING_VERSION[$i]}" = "${_self_ver}" ] && _leader_on=1
        continue
      fi
      [ "${RING_VERSION[$i]}" = "${_self_ver}" ] && continue
      [ -n "${_next}" ] || { _next="${RING_N[$i]}"; _next_addr="${RING_ADDR[$i]}"; }
    done
    if [ "$(record_field "${_self_rec}" state)" != "awaiting-schema" ] || [ -z "${_self_ver}" ]; then
      finding "[UPDATE]   The update finisher is running here (${FINISHER_STATE}), and this node's
           update record says '$(record_field "${_self_rec}" state)' rather than awaiting-schema —
           so it is about to finish or to stand down. Nothing to run on this node.
           ${_watch}
           (logs/update-finisher.log is its trail so far.)"
    elif [ "${_self_is_leader}" = 1 ]; then
      finding "[UPDATE]   This node is the leader, updated to ${_self_ver}: its api is migrating the
           schema, and the finisher (${FINISHER_STATE}) starts the rest of the stack
           as soon as the api is healthy. Nothing to run.
           ${_watch}    (and  ./taranac logs -f api)"
    elif [ -n "${_next}" ]; then
      finding "[UPDATE]   This node is updated to ${_self_ver} and waits for the leader's schema
           (finisher: ${FINISHER_STATE}). Every replica goes before the leader, and
           ${_next} is not on ${_self_ver} yet. Next — on ${_next}${_next_addr:+ (${_next_addr})}:
               ./taranac update --version ${_self_ver}
           then the leader${_leader:+, ${_leader}}. This node's stack starts by itself after that."
    elif [ -n "${_leader}" ] && [ -z "${_leader_on}" ]; then
      finding "[UPDATE]   This node is updated to ${_self_ver} and waits for the leader's schema: its
           finisher (${FINISHER_STATE}) starts the rest of the stack once the
           leader has migrated. The leader, ${_leader}, is next. On ${_leader}:
               ./taranac update --version ${_self_ver}
           (logs/update-finisher.log is this node's side of it.)"
    elif [ -n "${_leader}" ]; then
      finding "[UPDATE]   Nothing to run: the leader, ${_leader}, is on ${_self_ver} already. Wait — the
           finisher on this node (${FINISHER_STATE}) starts the stack once the
           leader's schema arrives, usually within minutes of the leader's update.
           ${_watch}"
    else
      finding "[UPDATE]   This node is updated to ${_self_ver} and waits for the leader's schema, but
           Patroni has no leader right now (an election, or the ring could not be
           read from here). Nothing to run on this node; the finisher
           (${FINISHER_STATE}) starts the stack once a leader on ${_self_ver} migrates.
           ${_watch}
           If no leader appears within a minute, see the [RING] findings above."
    fi ;;
esac

# Leader changes in the collected window — the cheap flapping detector. Patroni
# announces every promotion and demotion, so counting them costs nothing and
# turns "it sometimes drops connections" into a number.
# No `|| echo 0` on a `grep -c`: grep already prints 0 when it matches nothing and
# THEN exits 1, so the fallback appends a second line and the count becomes "0\n0"
# — which every later [ … -gt … ] rejects as "integer expression expected".
LEADER_EVENTS=0
if [ -f "${WORK}/logs/db.log" ]; then
  LEADER_EVENTS="$(grep -ciE 'promoted|demoting|new leader|acquired session lock|lost leader' "${WORK}/logs/db.log" 2>/dev/null | head -1 | tr -d '[:space:]')"
  case "${LEADER_EVENTS}" in ''|*[!0-9]*) LEADER_EVENTS=0 ;; esac
fi

# ── Findings ────────────────────────────────────────────────────────────────
# Each verdict below exists because the fault behind it has actually happened to
# a cluster in the field or on the stand. Nothing here is hypothetical.

# The 1.2.3 upgrade trap: the entrypoint refuses to start without this, three
# steps after the point where it could have been fixed calmly.
if [ "${HA_MARK}" = "1" ] && [ -z "$(getenv PATRONI_REST_PASSWORD)" ]; then
  finding "[WILL NOT START] TARANAC_HA=1 but PATRONI_REST_PASSWORD is empty in .env.
           This node's database container REFUSES to start without it — Patroni's
           REST API accepts /switchover, /failover and /restart, so it is never
           started unauthenticated. The value is CLUSTER-WIDE: copy it from a node
           that already has it (never generate a new one on a live cluster), or on
           a brand-new cluster generate one with:  openssl rand -hex 24"
fi

if [ -n "${CN_PROBLEMS}" ]; then
  finding "[RENAMED] A container is not under the name the tooling uses for it:
$(printf '%s\n' "${CN_PROBLEMS}" | sed 's/^/           /')"
fi

# The split-brain shape: an HA node whose database was started from the base
# compose alone is a second writable Postgres on Patroni's data directory.
if [ "${HA_MARK}" = "1" ] && [ -n "${DB_COMPOSE_FILES}" ] \
   && ! printf '%s' "${DB_COMPOSE_FILES}" | grep -q 'docker-compose.ha.yml'; then
  finding "[SPLIT-BRAIN RISK] This node is marked HA (TARANAC_HA=1), but taranac-db was
           created WITHOUT the Patroni overlay — from: ${DB_COMPOSE_FILES}
           That starts an ordinary, WRITABLE Postgres directly on Patroni's data
           directory, which is how two write histories are created. Bring the node
           down and start it through the wrapper, which applies the overlay itself:
               ./taranac down  &&  ./taranac up -d
           Never  docker compose up  directly on an HA node."
fi
if [ "${HA_MARK}" = "1" ] && [ -n "${DB_IMAGE}" ] \
   && ! printf '%s' "${DB_IMAGE}" | grep -q 'postgres-ha'; then
  finding "[SPLIT-BRAIN RISK] This node is marked HA, but taranac-db runs the plain image
           '${DB_IMAGE}' instead of the Patroni-supervised postgres-ha image. Same
           cause and same cure as above: the HA overlay was not applied."
fi

# Two leaders at once. The single worst state a cluster can be in, and the one
# that most deserves to be stated in one line rather than inferred from a table.
if [ -f "${WORK}/patroni-cluster.json" ] && have python3; then
  LEADERS="$(python3 - "${WORK}/patroni-cluster.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
print(" ".join(m.get("name", "?") for m in d.get("members", []) if m.get("role") == "leader"))
PY
)"
  LEADER_COUNT="$(printf '%s' "${LEADERS}" | wc -w | tr -d '[:space:]')"
  if [ "${LEADER_COUNT}" -gt 1 ]; then
    finding "[SPLIT-BRAIN]  Patroni reports MORE THAN ONE leader at once: ${LEADERS}
           Two nodes are accepting writes. Stop writing to this cluster and contact
           support before restarting anything — which history survives is a decision,
           not a default."
  fi

  # Timeline divergence — the fault this collector was built for.
  #
  # 🔑 The node's OWN timeline is taken from Patroni, and the verdict is refused
  # outright while Patroni reports this node streaming. The control file is not a
  # safe source here: a healthy replica's "Latest checkpoint's TimeLineID" lags
  # until it performs a restartpoint, so for minutes after any failover EVERY
  # replica looks a timeline behind. Reported as [DIVERGED] on a lab node that
  # was streaming with zero lag — a false alarm of the exact kind that teaches an
  # operator to stop reading the findings. The control file is used ONLY as the
  # fallback for a node Patroni cannot see, which is the case that matters: a node
  # whose database will not start has no Patroni to ask.
  DIVERGE="$(python3 - "${WORK}/patroni-cluster.json" "${WORK}/patroni-history.json" "${LOCAL_TIMELINE:-}" "${NODE_NAME}" "${LOCAL_CHECKPOINT:-}" <<'PY' 2>/dev/null || true
import json, sys

def to_int(v):
    """'0/17719F78' or an int -> int; None if it is neither."""
    if isinstance(v, int):
        return v
    try:
        hi, lo = str(v).strip().split("/")
        return (int(hi, 16) << 32) + int(lo, 16)
    except Exception:
        return None

def to_lsn(n):
    return "{:X}/{:08X}".format(n >> 32, n & 0xFFFFFFFF)

cluster_f, history_f, ctl_tl, me, ctl_lsn = sys.argv[1:6]
try:
    cluster = json.load(open(cluster_f))
except Exception:
    raise SystemExit(0)

members = cluster.get("members", [])
leader_tl = next((m.get("timeline") for m in members if m.get("role") == "leader"), None)
if leader_tl is None:
    raise SystemExit(0)

mine = next((m for m in members if m.get("name") == me), None)
if mine is not None:
    # Patroni can see this node. Streaming or leading means it is on the cluster's
    # history by definition, whatever the control file has got round to writing.
    if mine.get("state") in ("running", "streaming") or mine.get("role") == "leader":
        raise SystemExit(0)
    local_tl = mine.get("timeline")
    if local_tl is None:
        local_tl = ctl_tl
else:
    local_tl = ctl_tl

try:
    local_tl = int(local_tl)
    leader_tl = int(leader_tl)
except (TypeError, ValueError):
    raise SystemExit(0)
if local_tl >= leader_tl:
    raise SystemExit(0)

# Patroni's /history is [[timeline, switch-LSN, reason, …], …] — the LSN at which
# each timeline ENDED. The row for our timeline is where the leader forked away.
fork = None
try:
    for row in json.load(open(history_f)):
        if row and int(row[0]) == local_tl:
            fork = to_int(row[1])
except Exception:
    pass

lost = ""
here = to_int(ctl_lsn)
if fork is not None and here is not None and here > fork:
    lost = "{:,} bytes".format(here - fork)
print("{}|{}|{}|{}".format(local_tl, leader_tl, to_lsn(fork) if fork is not None else "", lost))
PY
)"
  if [ -n "${DIVERGE}" ]; then
    d_local="${DIVERGE%%|*}"; d_rest="${DIVERGE#*|}"
    d_leader="${d_rest%%|*}"; d_rest="${d_rest#*|}"
    d_fork="${d_rest%%|*}"; extra="${d_rest#*|}"
    # Built up in plain variables rather than with ${x:+…} inside the message.
    # Bash parses the word after `:+` even inside double quotes, so an apostrophe
    # there ("the leader's history") opens a quoted section and swallows the rest
    # of the script — a syntax error reported hundreds of lines later, at EOF.
    fork_line="."
    [ -n "${d_fork}" ] && fork_line=", which forked away at ${d_fork}."
    lost_line=""
    [ -n "${extra}" ] && lost_line="
           This node holds ${extra} of WAL that the leader's history never contained."
    finding "[DIVERGED]     This node's data is on timeline ${d_local}; the cluster's leader is on
           timeline ${d_leader}${fork_line}${lost_line}
           A node that has written history the leader never had cannot fast-forward:
           Postgres refuses rather than silently discarding it. The cure is to re-clone
           this node from the leader, which discards exactly that much and nothing else.
           Do NOT start this node's database on the base compose while it is in this
           state — see the split-brain verdict above."
  fi

  # Lag, in bytes. Seconds can look small on a replica that has stopped replaying
  # entirely, and the byte figure is the one that says what a forced promotion
  # would throw away.
  LAGGY="$(python3 - "${WORK}/patroni-cluster.json" "${LAG_WARN_BYTES}" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
limit = int(sys.argv[2])
for m in d.get("members", []):
    lag = m.get("lag")
    if isinstance(lag, int) and lag > limit:
        print("{} is {:,} bytes behind".format(m.get("name", "?"), lag))
    elif lag == "unknown" or (m.get("role") == "replica" and m.get("state") not in ("running", "streaming")):
        print("{} is not streaming (state: {})".format(m.get("name", "?"), m.get("state")))
PY
)"
  if [ -n "${LAGGY}" ]; then
    finding "[LAG]      Patroni reports member(s) that are not keeping up:
$(printf '%s' "${LAGGY}" | sed 's/^/             /')
           A replica that is behind is not a spare: a failover to it loses whatever
           it has not replayed, and past 45s it also freezes daemon-config reloads."
  fi
fi

# Quorum arithmetic, from the DECLARED ring — it works even with etcd down, which
# is when the question is most likely to be asked.
if [ "${DECLARED_MEMBERS}" -gt 0 ]; then
  if [ "${DECLARED_MEMBERS}" -lt 3 ]; then
    finding "[QUORUM]   Only ${DECLARED_MEMBERS} etcd member(s) are declared on this node. HA needs at
           least 3 (the database nodes plus an arbiter in a SEPARATE failure domain).
           With fewer, a partition has no majority and failover is unsafe."
  elif [ $(( DECLARED_MEMBERS % 2 )) -eq 0 ]; then
    finding "[QUORUM]   An EVEN number of etcd voting members (${DECLARED_MEMBERS}) is declared. That
           tolerates no more failures than ${DECLARED_MEMBERS} minus 1 while adding one more
           thing that can fail. Prefer an odd count."
  fi
fi
if [ -n "${ETCD_UNSTARTED}" ]; then
  finding "[QUORUM]   The ring contains UNSTARTED member(s): ${ETCD_UNSTARTED}
           Declared, counted for quorum, and not running — it drags the quorum
           arithmetic down until it either starts or is removed. See etcd.txt."
fi
if [ -n "${ETCD_LEARNERS}" ]; then
  finding "[QUORUM]   The ring contains LEARNER(s): ${ETCD_LEARNERS}
           A learner replicates but does NOT vote, so it does not count toward
           quorum — a ring that looks like 3 members may be voting with 2."
fi
if [ "${ETCD_MEMBER_COUNT}" -gt 0 ] && [ "${DECLARED_MEMBERS}" -gt 0 ] \
   && [ "${ETCD_MEMBER_COUNT}" != "${DECLARED_MEMBERS}" ]; then
  # The cure differs by what kind of machine this is, and printing the wrong one
  # is not a small thing: `./taranac cluster sync` is REFUSED on a witness — the
  # wrapper turns away every cluster subcommand there, because a witness holds no
  # roster and no database to read the truth from. This finding printed it anyway,
  # and a witness drifts exactly like a database node does (add-node updates only
  # the node it runs on), so the machine was being told to run a command it
  # answers by explaining why it will not. Seen on the stand, on a cluster built
  # from scratch an hour earlier.
  if [ "${ROLE_GUESS}" = "witness (etcd only)" ]; then
    finding "[QUORUM]   This witness's .env declares ${DECLARED_MEMBERS} etcd member(s), but the live ring
           reports ${ETCD_MEMBER_COUNT}. On a witness this is not urgent — its running etcd
           takes the ring from Raft, and the list is read only when it bootstraps.
           It matters if this host is ever rebuilt: re-point it at the cluster and
           the list is rewritten from the live ring —
               ./witness-join.sh --broker … --token … --pin …
           (\`cluster sync\` is a DATABASE-node command; this wrapper refuses it here.)"
  else
    finding "[QUORUM]   This node's .env declares ${DECLARED_MEMBERS} etcd member(s), but the live ring
           reports ${ETCD_MEMBER_COUNT}. The declaration and reality have drifted apart — a joining
           node would be handed this node's stale list, and its etcd would refuse it.
           This is the ordinary state after a node is added or removed: only the
           machine the command ran on has its list rewritten. Reconcile it:
               ./taranac cluster sync        (run it ON this node)"
  fi
fi

# An inactive slot pins WAL forever. This is the classic "the disk filled up and
# nobody knows why" outage, and it is one grep away.
if grep -qE '\| *f *\|' "${WORK}/postgres.txt" 2>/dev/null \
   && grep -q 'slot_name' "${WORK}/postgres.txt" 2>/dev/null; then
  finding "[SLOT]     An INACTIVE replication slot is present (see postgres.txt, active = f).
           An inactive physical slot pins WAL on the primary indefinitely — the disk
           fills and the cluster stops. If the node it belonged to is gone for good,
           drop the slot; the eviction commands do this for you."
fi

if [ -n "${UNREACH}" ]; then
  finding "[UNREACHABLE] From this node, these member ports do not answer:
             ${UNREACH}
           Collect this bundle on the OTHER nodes too: if the reverse direction
           works, this is asymmetric filtering on the path (a firewall rule or a
           route), which is a different fault from a host being down. Remember that
           BOTH etcd ports matter — the ring forms over 2380, and a ring that cannot
           form makes every 2379 check look perfectly healthy."
fi

if [ "${LEADER_EVENTS}" -gt 4 ]; then
  finding "[FLAPPING] ${LEADER_EVENTS} leadership events appear in the last ${LOG_LINES} lines of the database
           log. Leadership should be a rare event. Repeated promotions and demotions
           usually mean the DCS is unreliable from this node — clock skew, a slow or
           lossy interconnect, or etcd under load. See logs/db.log and clock-skew.txt."
fi

# Not faults — states worth naming so the reader is not left inferring them.
if [ "${HA_MARK}" != "1" ] && [ -z "${ETCD_RING}" ]; then
  note "this node is a STANDALONE install — it is not part of a cluster, and none of the cluster verdicts apply"
elif [ "${HA_MARK}" != "1" ] && [ -n "${ETCD_RING}" ] && [ -n "${DB_HOSTS}" ]; then
  finding "[NOT CONVERTED] This node declares a cluster topology (DB_HOSTS and an etcd ring are
           set) but TARANAC_HA is absent. The tooling decides which compose files to
           apply from that marker, so this node will be started WITHOUT the Patroni
           overlay — see the split-brain verdict. Either finish the conversion or
           clear the topology."
fi
if [ "${ROLE_GUESS}" = "witness (etcd only)" ]; then
  note "this is the WITNESS: it runs etcd and nothing else, so every database and api probe above is legitimately empty"
fi
[ -z "${PATRONI_SOURCE}" ] && [ "${HA_MARK}" = "1" ] \
  && note "no Patroni REST endpoint answered — not this node's and not any declared member's; the role/timeline/lag verdicts could not be computed"

# ── The verdict — the same machine-level judgement `cluster status` makes ────
# Two halves, both needed for "any one machine can be lost": the etcd ring keeps a
# majority without that machine (read above, member by member — the witness is one
# of them), and Patroni has a replica it may promote should it be the leader
# (patroni-cluster.json, against maximum_lag_on_failover from patroni-config.json).
# Made here too because the witness has no api to run `cluster status` on, and a
# database node in trouble may have none either. One sentence, then one command.
PAT_KNOWN=0; PAT_LEADER=""; PAT_SPARE=""; PAT_STUCK=""
if [ -s "${WORK}/patroni-cluster.json" ] && have python3; then
  _pat="$(python3 - "${WORK}/patroni-cluster.json" "${WORK}/patroni-config.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    members = json.load(open(sys.argv[1])).get("members", [])
except Exception:
    raise SystemExit(0)
bar = 1048576
try:
    bar = int(json.load(open(sys.argv[2])).get("maximum_lag_on_failover", bar))
except Exception:
    pass
leader = next((m.get("name", "") for m in members if m.get("role") in ("leader", "standby_leader")), "")
spare, stuck = [], []
for m in members:
    if m.get("role") in ("leader", "standby_leader"):
        continue
    lag = m.get("lag")
    ok = m.get("state") in ("running", "streaming") and isinstance(lag, int) and lag <= bar
    (spare if ok else stuck).append(m.get("name", "?"))
print("{}|{}|{}".format(leader, ",".join(spare), ",".join(stuck)))
PY
)"
  if [ -n "${_pat}" ]; then
    PAT_KNOWN=1
    PAT_LEADER="${_pat%%|*}"; _rest="${_pat#*|}"
    PAT_SPARE="${_rest%%|*}"; PAT_STUCK="${_rest#*|}"
    # A database member of the ring that Patroni does not list at all is down, not spare.
    for _db in ${RING_DB_NAMES}; do
      case ",${PAT_LEADER},${PAT_SPARE},${PAT_STUCK}," in *",${_db},"*) ;; *) PAT_STUCK="${PAT_STUCK:+${PAT_STUCK},}${_db}" ;; esac
    done
  fi
fi
first_of() { printf '%s' "$1" | cut -d, -f1 | tr -d ' '; }
if [ "${ROLE_GUESS}" = "standalone (not part of a cluster)" ]; then
  VERDICT="Standalone — one machine, no failover. Losing it stops the service."
  NEXT_CMD="nothing to do: this host is not part of a cluster."
elif [ "${RING_READ}" -ne 1 ]; then
  VERDICT="Unknown — the etcd ring could not be read from this host, so no machine can be judged from here."
  NEXT_CMD="./taranac diagnose --ha   (on another member of the ring — see etcd.txt for why this one could not ask)"
elif [ "${RING_HEALTHY}" -lt "${RING_MAJORITY}" ]; then
  VERDICT="FROZEN — only ${RING_HEALTHY} of ${RING_VOTERS} machines of the etcd ring answer (${RING_DOWN:-?} down). Without a majority no leader can hold the cluster lock, so writes stop until one returns."
  NEXT_CMD="on $(first_of "${RING_DOWN}"):  ./taranac up -d"
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_LEADER}" ]; then
  VERDICT="FROZEN — no writable primary right now. Writes are refused until a leader returns; a failover may be in progress."
  NEXT_CMD="./taranac cluster status   (on a database node, in a minute — then logs/db.log here)"
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_SPARE}" ]; then
  VERDICT="Degraded — ${PAT_STUCK:-no replica} cannot take over (down, or too far behind to be promoted). Losing ${PAT_LEADER} now stops writes."
  NEXT_CMD="on $(first_of "${PAT_STUCK}"):  ./taranac up -d   (then ./taranac diagnose --ha there)"
elif [ $((RING_HEALTHY - 1)) -lt "${RING_MAJORITY}" ]; then
  if [ -n "${RING_DOWN}" ]; then
    VERDICT="Degraded — ${RING_DOWN} is down. One more loss stops writes."
    NEXT_CMD="on $(first_of "${RING_DOWN}"):  ./taranac up -d"
  else
    VERDICT="Degraded — the etcd ring has ${RING_VOTERS} voting machines (${RING_MACHINES}) and needs ${RING_MAJORITY}, so losing any one stops writes."
    NEXT_CMD="./taranac cluster add-witness --address <a third machine>   (on the leader)"
  fi
elif [ "${PAT_KNOWN}" = 1 ]; then
  VERDICT="Healthy — any one machine (${RING_MACHINES}) can be lost and writes continue."
  [ -n "${RING_DOWN}" ] && VERDICT="${VERDICT} ${RING_DOWN} is down — that redundancy is already spent."
  NEXT_CMD="nothing to fix from this host's view — compare the bundles from the other machines."
else
  VERDICT="Ring healthy — any one machine (${RING_MACHINES}) can be lost without losing etcd quorum. Whether a replica can take over could not be seen from here: no Patroni answered."
  NEXT_CMD="./taranac cluster status   (on a database node)"
fi
[ -n "${RING_UNKNOWN}" ] && VERDICT="${VERDICT} (Not asked from here: ${RING_UNKNOWN}.)"

# ── Summary ─────────────────────────────────────────────────────────────────
SUMMARY="${WORK}/summary.txt"
{
  echo "Taranac HA diagnostic bundle"
  echo "============================"
  echo
  echo "node       : ${NODE_NAME}${NODE_ADDRESS:+ (${NODE_ADDRESS})}"
  echo "hostname   : ${HOSTNAME_S}"
  echo "cluster    : ${CLUSTER_NAME:-(not declared)}"
  echo "role       : ${ROLE_GUESS}"
  echo "version    : $(cat "${HERE}/VERSION" 2>/dev/null || echo unknown)"
  echo "collected  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "Verdict (from this host)"
  echo "------------------------"
  echo "  ${VERDICT}"
  echo "  Next: ${NEXT_CMD}"
  echo
  if [ "${RING_READ}" -eq 1 ]; then
    echo "machines of the ring (each asked about itself; the witness is one of them):"
    for i in "${!RING_N[@]}"; do
      _vote=""; [ "${RING_LEARNER[$i]}" = "true" ] && _vote=" (learner, not voting)"
      _me=""; [ "${RING_N[$i]}" = "${ETCD_NAME_ENV:-${NODE_NAME}}" ] && _me="   ← this host"
      printf '  %-22s %-16s %-9s %-8s %s%s%s\n' "${RING_N[$i]}" "${RING_ADDR[$i]:-?}" "${RING_KIND[$i]}" \
        "${RING_HEALTH[$i]}" "${RING_VERSION[$i]:-—}" "${_vote}" "${_me}"
    done
    echo
  fi
  if [ "${ROLE_GUESS}" = "witness (etcd only)" ]; then
    # A witness holds none of the cluster's secrets by design (witness-join.sh), so
    # its fingerprint is a hash of empties and ALWAYS differs from a database node's.
    # Printed with the line below, that difference read as "a secret drifted" — on
    # the one host that has no secret to drift.
    echo "cluster-fingerprint : not comparable — a witness carries no cluster secrets"
    echo "  ^ Compare the database nodes' bundles with each other instead."
  else
    echo "cluster-fingerprint : ${CLUSTER_FP}"
    echo "  ^ Compare this ONE string across every DATABASE node's bundle. Identical on"
    echo "    all of them means every cluster-wide secret agrees. If it differs, the"
    echo "    per-key block in config.txt names the value that drifted."
  fi
  echo
  echo "declared members    : ${DECLARED_MEMBERS}"
  if [ "${DECLARED_MEMBERS}" -gt 0 ]; then
    for i in "${!MEMBER_NAMES[@]}"; do
      printf '  %-22s %-16s %s\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "${MEMBER_ROLES[$i]}"
    done
  fi
  echo
  echo "taranac-db  : running=${DB_RUNNING}  image=${DB_IMAGE:-none}"
  [ "${DB_CT}" != "taranac-db" ] && echo "              ⚠ running under the name '${DB_CT}' — see Findings [RENAMED]"
  echo "              compose=${DB_COMPOSE_FILES:-unknown}"
  echo "${ETCD_CT}: running=${ETCD_RUNNING}"
  if [ -n "${PATRONI_SOURCE}" ]; then
    echo "patroni view: taken from ${PATRONI_SOURCE}"
  else
    echo "patroni view: not available from this node"
  fi
  echo "control file: timeline ${LOCAL_TIMELINE:-unknown}${LOCAL_CHECKPOINT:+, last checkpoint ${LOCAL_CHECKPOINT}}"
  echo "              (a streaming replica's checkpoint timeline legitimately lags"
  echo "               the cluster's until its next restartpoint — see patroni-cluster.json"
  echo "               for the timeline Patroni actually has this node on)"
  echo
  echo "Findings"
  echo "--------"
  if [ "${#FINDINGS[@]}" -eq 0 ]; then
    echo "  [ok]      Nothing wrong was detected from this node."
    echo
    echo "            That is not the same as a healthy cluster: a disagreement between"
    echo "            nodes is invisible from one side. Collect this on every node and"
    echo "            compare the cluster-fingerprint lines before concluding."
  else
    for f in "${FINDINGS[@]}"; do
      printf '  %s\n\n' "${f}"
    done
  fi
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo "Notes"
    echo "-----"
    for n in "${NOTES[@]}"; do
      printf '  [note]    %s\n' "${n}"
    done
    echo
  fi
  echo "Contents"
  echo "--------"
  ( cd "${WORK}" && find . -type f ! -name summary.txt | sed 's|^\./||' | sort ) | while read -r item; do
    case "${item}" in
      node.txt)              echo "  ${item}          — this host: containers, images, compose files, clock, disk" ;;
      config.txt)            echo "  ${item}        — declared topology verbatim; secrets as fingerprints only" ;;
      manifest.txt)          echo "  ${item}      — config/cluster.yml: what this node declares the cluster to be" ;;
      patroni-cluster.json)  echo "  ${item} — the ring as Patroni sees it (roles, timelines, lag)" ;;
      patroni-history.json)  echo "  ${item} — timeline history: where each timeline forked" ;;
      patroni-config.json)   echo "  ${item}  — the cluster's Patroni configuration" ;;
      patroni-local.json)    echo "  ${item}   — what THIS node thinks it is" ;;
      patronictl-list.txt)   echo "  ${item}  — the same view from patronictl inside the container" ;;
      etcd.txt)              echo "  ${item}          — ring membership, health, raft term/index" ;;
      postgres.txt)          echo "  ${item}      — timeline, checkpoint, replication, slots, WAL size" ;;
      reachability.txt)      echo "  ${item}  — this node → every member, per port (run everywhere = the full matrix)" ;;
      certs.txt)             echo "  ${item}         — etcd CA and this node's leaf: fingerprint, dates, SANs" ;;
      clock-skew.txt)        echo "  ${item}    — measured clock difference against each reachable peer" ;;
      etcd-members.json)     echo "  ${item} — the ring as data: what every etcd verdict is computed from" ;;
      ring.txt)              echo "  ${item}          — every ring member (witness included): own health, version record; departed records" ;;
      write-routing.txt)     echo "  ${item} — each node's write list (heartbeat + this host's daemons) against the roster" ;;
      logs/*)                printf '  %-21s — last %s lines\n' "${item}" "${LOG_LINES}" ;;
      *)                     echo "  ${item}" ;;
    esac
  done
  echo
  echo "Note on secrets: no password, key or token is in this archive. Values that"
  echo "must match across nodes appear only as 12-hex fingerprints, which prove"
  echo "agreement or disagreement without carrying the secret."
  echo
  echo "This bundle describes ONE node. Send one from every node — each database"
  echo "node and the witness — or the comparison that finds the fault cannot be made."
} > "${SUMMARY}"

ARCHIVE="${OUT_DIR}/${BUNDLE}.tar.gz"
tar -czf "${ARCHIVE}" -C "${OUT_DIR}" "${BUNDLE}" 2>/dev/null

say ""
cat "${SUMMARY}"
rm -rf "${WORK}"
say ""
say "Archive: ${ARCHIVE}  ($(du -h "${ARCHIVE}" 2>/dev/null | cut -f1))"
say ""
say "Run the SAME command on every other node — including the witness — and send"
say "all the archives together. Most HA faults are disagreements between nodes,"
say "and a disagreement cannot be seen from one side of it."
exit 0
