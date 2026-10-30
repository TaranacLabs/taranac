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
#
# WHAT THE CONTAINERS' LOGS ALREADY SAY IS READ — AND ONLY WHAT THEY SAID BEFORE T0
#   The 1.3.2 field bundles carried the cause in their own logs (etcd's `cluster ID
#   mismatch`, the primary's `Role "replicator" does not exist.`, the api's start-up
#   TimeoutError) while the verdict sent the operator elsewhere. Each log is now
#   matched against ha-probe.sh's signature table (one literal per line, one line per
#   finding — see ha_sig_rows) and written to signatures.txt. T0 is taken before this
#   collector probes anything, and the logs are read with `--until T0`: a login this
#   run attempts, a connection it opens, can never come back to it as a finding.
#   A match is LIVE when its last line is at most 5 minutes old, or the container has
#   stopped and the line is from its last run; otherwise PAST. Not "after the current
#   start" for a running container: a crash-looping one (restart: unless-stopped) logs
#   its cause a moment BEFORE Docker starts it again, every time. Only live
#   signatures choose the next step; past ones are reported.
#   Current evidence beats a line's age: where the fault a line names can be asked
#   now (after T0), it is — replicator logs in to this node's database with .env's
#   password, the WAL receiver streams, the api is healthy since — and a fault seen
#   gone makes its line past, the reason printed beside it.
#
# THE ONE NEXT STEP — rules in order, the first that applies wins (next_for below)
#   1. a standalone host: nothing to do;
#   2. a container Docker could not start because its port is taken, or a live ETCD
#      signature on THIS node: its cure;
#   3. the ring has no majority: next_for the first member down (below) — ranked
#      above the database's signatures, because a stray node's wrong-password
#      retries in this database's log must not replace "the ring is frozen";
#   3a. this node's own :2379 or :8008 times out (or is filtered) from its Docker
#      network while the host reaches it — the hairpin: the firewall cure, one rule
#      for both ports. Above the db/api signatures, which are what that cut path
#      produces;
#   4. a live database or api signature on THIS node: its cure. The role cures
#      (NO-ROLE, REPL-PASSWORD, NOLOGIN, NO-REPLICATION) and CLONE-AUTH are aimed at
#      the leader Patroni names — a role is changed on the primary only — never at an
#      address parsed out of a log line;
#   5. the ring cannot be read from here: run this on another member;
#   5b. Patroni reports X streaming as a replica and the roster has no active row
#      for X: `./taranac up -d` on X — its api registers it — then its version
#      record (ha-probe.sh, ha_finish_join);
#   6. the verdict names a member X → next_for X: Patroni lists X → X runs, read its
#      own bundle's signatures (never `up -d` on a node whose Patroni is cloning or
#      starting); not listed and its ports refuse → `./taranac up -d` on X; nothing
#      answers and no ping → is X powered on (or, without ping here, check it); some
#      ports answer and one is dropped → the firewall cure (the Docker subnet for
#      this host's own address — the hairpin); every port open → run this on X;
#   7. no replica, and no other database node declared → add one;
#   8. otherwise the verdict's own step.
#   The next step never contradicts what was observed: it is computed from the same
#   probes the bundle records.
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

# T0 — before ANY probe this run makes (Patroni, etcd, psql, TCP, the api's login
# matrix). Every log is read up to here and no further; see the header.
T0="$(date -u +%s)"
LIVE_WINDOW=300          # a running container's match is live when this fresh
SCAN_TAIL=20000          # lines per container log scanned at most (the api's can be ~1 GB)

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
# The same timeout as the Docker-network probes (ha-probe.sh, 5s; 3s without it), so
# the two columns and the cure that quotes the number agree.
# The class, not just yes/no: bash says "Connection refused" for an RST (the host is
# there, nothing listens or a firewall REJECTs), `timeout` exits 124 when nothing came
# back at all (a DROP, or no host) — two faults with two different cures.
tcp_class() {  # <host> <port> → ok | refused | timeout | filtered | other
  local out rc=0
  out="$(timeout "${HA_PROBE_TIMEOUT:-3}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)" || rc=$?
  if [ "${rc}" -eq 0 ]; then printf 'ok'; return 0; fi
  if [ "${rc}" -eq 124 ]; then printf 'timeout'; return 0; fi
  case "${out}" in
    *"Connection refused"*) printf 'refused' ;;
    *"No route to host"*|*"Network is unreachable"*|*"Host is unreachable"*) printf 'filtered' ;;
    *) printf 'other' ;;
  esac
}
tcp_open() { [ "$(tcp_class "$1" "$2")" = ok ]; }  # <host> <port>

# RFC 3339 (docker's timestamps, Patroni's dates) → epoch; 0 when unparseable.
epoch_of() { date -u -d "$1" +%s 2>/dev/null || printf '0'; }
utc_of()   { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || printf '%s' "$1"; }

# Every log and every sample that reaches the archive goes through this. Neither the
# daemons nor our tooling print a secret by design; this is the defensive layer for
# the day one does. Case-insensitive, and for the shapes seen in the logs we collect:
#   KEY=value · KEY: value · KEY = 'a b' · {"KEY":"value"} (JSON, quote before the
#   colon) · Authorization: Bearer|Basic … · --password value · SQL PASSWORD 'x',
#   PASSWORD E'x', PASSWORD 'it''s' · a DSN's inline password (scheme://user:pw@).
# KEY is any name containing password, secret, master_key, token, api_key, jwt or
# refresh. Not etcd's initial-cluster-token: it is topology (it is what tells two
# rings apart in an ETCD-ID finding), so it is shielded first and restored last.
REDACT_KEYS='(password|secret|master_key|token|api_key|jwt|refresh)[a-z_]*'
redact() {
  sed -E \
    -e 's/(initial[-_]cluster[-_]t)(oken)/\1\x01\2/gI' \
    -e 's/(authorization"?[[:space:]]*[=:][[:space:]]*"?(bearer|basic)[[:space:]]+)[^"[:space:],}]+/\1<redacted>/gI' \
    -e 's/(--[a-z-]*(password|secret|token)[[:space:]]+)[^-[:space:]][^[:space:]]*/\1<redacted>/gI' \
    -e 's/(password[[:space:]]+E?'\'')([^'\''\\]|\\.|'\'''\'')*'\''/\1<redacted>'\''/gI' \
    -e "s/(${REDACT_KEYS}\"?[[:space:]]*[=:][[:space:]]*\")[^\"]*/\\1<redacted>/gI" \
    -e "s/(${REDACT_KEYS}\"?[[:space:]]*[=:][[:space:]]*')[^']*/\\1<redacted>/gI" \
    -e "s/(${REDACT_KEYS}\"?[[:space:]]*[=:][[:space:]]*)[^\"'[:space:]<][^[:space:],}]*/\\1<redacted>/gI" \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@[:space:]]+:)[^@[:space:]]+@#\1<redacted>@#g' \
    -e 's/\x01//g'
}

bundle_version() {
  local v; v="$(cat "${BASE_DIR}/VERSION" "${HERE}/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
  printf '%s' "${v:-unknown}"
}

# ha-probe.sh: the signature table and the Docker-network probes. A bundle caught
# half-updated without it still collects everything else, and says what it lacks.
HAVE_PROBE=0
if [ -f "${HERE}/ha-probe.sh" ]; then
  # shellcheck source=ha-probe.sh
  . "${HERE}/ha-probe.sh" && HAVE_PROBE=1
fi

FINDINGS=()
NOTES=()
finding() { FINDINGS+=("$*"); }
note()    { NOTES+=("$*"); }

# ── Step 0: where does this run, and what is it ─────────────────────────────
STAMP="$(date -u +%Y%m%d-%H%M%S)"
HOSTNAME_S="$(hostname 2>/dev/null || echo unknown)"

# Where this host's .env and config/ live. Normally beside this script. On a WITNESS
# the collector can be run from another directory than the one witness-join.sh set
# up (an appliance's product bundle, an old copy) — so, when the .env here is not a
# witness's and this host runs no database, the witness's own directory is found:
# the compose working directory of taranac-witness-etcd, else the appliance's module
# directory. config/etcd-tls is read from the same place.
BASE_DIR="${HERE}"
_role_here="$(grep -E '^[[:space:]]*TARANAC_ROLE[[:space:]]*=' "${HERE}/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' "' || true)"
if [ "${_role_here}" != witness ] && ! docker inspect taranac-db >/dev/null 2>&1; then
  _wd="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' taranac-witness-etcd 2>/dev/null || true)"
  _mod="${TARANAC_MODULES_DIR:-/opt/taranac/modules}/witness"
  if [ -n "${_wd}" ] && [ "${_wd}" != "${HERE}" ] && [ -r "${_wd}/.env" ]; then
    BASE_DIR="${_wd}"
  elif [ ! -r "${HERE}/.env" ] && [ -r "${_mod}/.env" ]; then
    BASE_DIR="${_mod}"
  fi
  if [ "${BASE_DIR}" != "${HERE}" ]; then
    ENV_FILE="${BASE_DIR}/.env"
    note "this witness's .env and config/ were read from ${BASE_DIR} (where its etcd was set up), not from ${HERE}"
  fi
fi

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
  echo "bundle version      : $(bundle_version)"
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

# ── Step 1b: what the containers' logs already say (up to T0) ──────────────
# See the header: one literal per line, one line per finding, read only up to T0.
# The window: from shortly before the container's CURRENT start (the last lines of
# the run before it, which is often why it restarted), at most 24 h back for a
# running container, and never more than SCAN_TAIL lines. A stopped container's
# window is its last run, however long ago that was — its last words are the point.
SIG_ID=(); SIG_KIND=(); SIG_CT=(); SIG_COUNT=(); SIG_FIRST=(); SIG_LAST=(); SIG_STATE=(); SIG_SAMPLE=()
SIG_LAST_EPOCH=(); SIG_WHY=()
SIG_WINDOWS=""
scan_container() {  # <container> <kind>
  local ct="$1" kind="$2" started st_epoch running since raw
  local id cnt first last sample last_epoch state
  docker inspect "${ct}" >/dev/null 2>&1 || return 0
  started="$(docker inspect -f '{{.State.StartedAt}}' "${ct}" 2>/dev/null || true)"
  st_epoch="$(epoch_of "${started}")"
  running="$(container_running "${ct}")"
  since=$(( st_epoch - 120 ))
  if [ "${running}" = true ] && [ "${since}" -lt $(( T0 - 86400 )) ]; then since=$(( T0 - 86400 )); fi
  [ "${since}" -gt 0 ] || since=$(( T0 - 86400 ))
  raw="${WORK}/.scan-${kind}.log"
  docker logs --timestamps --since "${since}" --until "${T0}" --tail "${SCAN_TAIL}" "${ct}" > "${raw}" 2>&1 || true
  SIG_WINDOWS="${SIG_WINDOWS}  ${ct} (${kind}): $(utc_of "${since}") … $(utc_of "${T0}"), at most ${SCAN_TAIL} lines; running=${running}, started $(utc_of "${st_epoch}")"$'\n'
  [ "${HAVE_PROBE}" = 1 ] || { rm -f "${raw}"; return 0; }
  while IFS=$'\t' read -r id cnt first last sample; do
    [ -n "${id}" ] || continue
    last_epoch="$(epoch_of "${last}")"
    state=past
    if [ "${last_epoch}" -ge $(( T0 - LIVE_WINDOW )) ] \
       || { [ "${running}" != true ] && [ "${last_epoch}" -ge "${st_epoch}" ]; }; then
      state=live
    fi
    SIG_ID+=("${id}"); SIG_KIND+=("${kind}"); SIG_CT+=("${ct}"); SIG_COUNT+=("${cnt}"); SIG_STATE+=("${state}")
    SIG_LAST_EPOCH+=("${last_epoch}"); SIG_WHY+=("")
    SIG_FIRST+=("$(utc_of "$(epoch_of "${first}")")"); SIG_LAST+=("$(utc_of "${last_epoch}")")
    SIG_SAMPLE+=("$(printf '%s\n' "${sample}" | redact)")
  done < <(ha_sig_scan "${raw}" "${kind}")
  rm -f "${raw}"
}
if [ "${HAVE_PROBE}" = 1 ]; then
  step "reading what the containers' logs already say (up to $(utc_of "${T0}"))"
fi
scan_container "${ETCD_REAL}" etcd
scan_container "${DB_CT}" db
scan_container "${API_CT}" api
# ── Current evidence beats a line's age ─────────────────────────────────────
# A line five minutes old is "live" by the clock, and in the hostile run a NO-ROLE
# line 90 s old was the Next step after the role had been recreated by its own printed
# cure (finding 5). So where the fault a line names can be ASKED now, it is: after T0
# (so nothing asked here is read back as a line), and a fault seen to be gone makes
# its line past, with the reason printed beside it.
#   · the role rows (NO-ROLE, NOLOGIN, NO-REPLICATION — never REPL-PASSWORD, whose
#     line is about whichever client connected) — replicator logs in to this node's own database, from its own
#     Docker network (Patroni's hba admits its own subnet: postgres-ha/entrypoint.sh),
#     with .env's POSTGRES_REPLICATION_PASSWORD;
#   · CLONE-AUTH — this node's WAL receiver is streaming;
#   · API-DB-TIMEOUT — the api is running, healthy, and started after the line.
SELF_LOGIN=""
if [ "${HAVE_PROBE}" = 1 ] && [ "${DB_RUNNING}" = true ] && [ -n "$(getenv POSTGRES_REPLICATION_PASSWORD)" ] \
   && docker image inspect "${HA_PROBE_IMAGE}" >/dev/null 2>&1 && docker network inspect taranac_default >/dev/null 2>&1; then
  HA_PROBE_NET=taranac_default
  HA_PROBE_PASSWORD="$(getenv POSTGRES_REPLICATION_PASSWORD)"
  if ha_probe_login "${DB_CT}" 5432 >/dev/null 2>&1; then SELF_LOGIN=ok; else SELF_LOGIN="${PROBE_CLASS}"; fi
  unset HA_PROBE_PASSWORD
fi
WAL_RECEIVER=""
if [ "${DB_RUNNING}" = true ]; then
  WAL_RECEIVER="$(docker exec "${DB_CT}" psql -U taranac -d taranac -tAc \
    "select status from pg_stat_wal_receiver" 2>/dev/null | tr -d '[:space:]' || true)"
fi
# Running and started after the line is not enough on its own: a crash-looping api
# is exactly that between two deaths. Healthy says its start-up got past the database.
API_SINCE=0
if [ "$(container_running "${API_CT}")" = true ] \
   && [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${API_CT}" 2>/dev/null)" = healthy ]; then
  API_SINCE="$(epoch_of "$(docker inspect -f '{{.State.StartedAt}}' "${API_CT}" 2>/dev/null)")"
fi
for _i in "${!SIG_ID[@]}"; do
  case "${SIG_ID[$_i]}" in
    # Properties of the ROLE, which this login proves. Not REPL-PASSWORD: the server
    # writes that line for whichever client presented a password — typically a peer
    # whose .env differs — and this node logging in with ITS password says nothing
    # about that peer. It stays live by the age rule.
    NO-ROLE|NOLOGIN|NO-REPLICATION)
      [ "${SELF_LOGIN}" = ok ] && SIG_WHY[_i]="replicator logs in with .env's password now" ;;
    CLONE-AUTH)
      [ "${WAL_RECEIVER}" = streaming ] && SIG_WHY[_i]="this node's WAL receiver is streaming now" ;;
    API-DB-TIMEOUT)
      [ "${API_SINCE}" -gt "${SIG_LAST_EPOCH[$_i]}" ] && SIG_WHY[_i]="the api is healthy since — started $(utc_of "${API_SINCE}")" ;;
  esac
  [ -n "${SIG_WHY[$_i]}" ] && SIG_STATE[_i]=past
done

# The first LIVE signature in table order (etcd, then the database, then the api) is
# the one the next step acts on.
SIG_LIVE_I=""
for _i in "${!SIG_ID[@]}"; do
  [ "${SIG_STATE[$_i]}" = live ] && { SIG_LIVE_I="${_i}"; break; }
done
# ETCD-ID: the two cluster ids and the peer, as etcd logged them.
etcd_id_field() {  # <sample> <json key>
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([0-9a-f]*\\)\".*/\\1/p" | head -1
}

# A container Docker could not START because its host port is taken: not a log line
# (the container never ran), but the daemon's own record of the last start attempt.
# Every container of this node's compose project — not etcd, db and api only: the
# port a squatter takes is as often 443, and that is taranac-edge's (the hostile run,
# finding 4).
BIND_CT=""; BIND_ERR=""
for _c in $(docker ps -a --filter label=com.docker.compose.project=taranac --format '{{.Names}}' 2>/dev/null | sort); do
  _e="$(docker inspect -f '{{.State.Error}}' "${_c}" 2>/dev/null || true)"
  case "${_e}" in *"address already in use"*) BIND_CT="${_c}"; BIND_ERR="${_e}"; break ;; esac
done
BIND_PORT="$(printf '%s' "${BIND_ERR}" | sed -n 's/.*:\([0-9][0-9]*\): bind: address already in use.*/\1/p' | head -1)"

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
  if [ -f "${BASE_DIR}/config/cluster.yml" ]; then
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
    cat "${BASE_DIR}/config/cluster.yml" 2>/dev/null || echo "(unreadable)"
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
if [ "${ETCD_CLIENT_SCHEME}" = "https" ] && [ -s "${BASE_DIR}/config/etcd-tls/ca.crt" ]; then
  ETCD_CTL_MOUNT=(-v "${BASE_DIR}/config/etcd-tls:/tls:ro")
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
peers = []
for m in members:
    for u in m.get("peerURLs", []):
        host = u.split("://", 1)[-1].rsplit(":", 1)[0].strip("[]")
        if host:
            peers.append(host)
print(len(members))
print(" ".join(unstarted))
print(" ".join(learners))
print(" ".join(peers))
PY
)"
  ETCD_MEMBER_COUNT="$(printf '%s' "${ETCD_FACTS}" | sed -n 1p | tr -d '[:space:]')"
  ETCD_UNSTARTED="$(printf '%s' "${ETCD_FACTS}" | sed -n 2p)"
  ETCD_LEARNERS="$(printf '%s' "${ETCD_FACTS}" | sed -n 3p)"
  ETCD_LIVE_PEERS=" $(printf '%s' "${ETCD_FACTS}" | sed -n 4p) "
fi
case "${ETCD_MEMBER_COUNT}" in ''|*[!0-9]*) ETCD_MEMBER_COUNT=0 ;; esac
# A declared member the live ring does not hold: a node declared at `init` that has not
# joined yet, or the witness `remove-witness` took out while this node's .env still
# names it (only the node a command ran on is rewritten). Neither is unreachable —
# there is nothing there to reach — so it is not probed and not counted as a voter.
in_live_ring() {  # <address> → 0 when the live ring holds it, or when the ring was not read
  [ "${ETCD_MEMBER_COUNT}" -gt 0 ] || return 0
  case "${ETCD_LIVE_PEERS:-}" in *" $1 "*) return 0 ;; esac
  return 1
}

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
for _ca in "${BASE_DIR}/config/etcd-tls/ca.crt" "${BASE_DIR}/config/etcd-ca/ca.crt"; do
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
    echo "(the member list could not be read from this host — see etcd.txt. etcdctl 3.5's"
    echo " member list has no serializable mode: without a quorum it cannot answer.)"
    echo
    echo "Each DECLARED member asked about itself instead (serializable — no quorum needed):"
    for i in "${!MEMBER_NAMES[@]}"; do
      _h="$(member_health "${ETCD_CLIENT_SCHEME}://${MEMBER_ADDRS[$i]}:2379")"
      printf '  %-22s %-16s %-9s %s\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "${_h%%|*}" \
        "$([ "${_h#*|}" != "${_h}" ] && printf '%s' "${_h#*|}")"
    done
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
#
# TWO columns, because the product dials from two places. FROM HOST is this
# machine's own stack. FROM DOCKER is a throwaway container on the network this
# node's etcd is attached to (ha-probe.sh's ha_probe_tcp) — where Patroni and the
# api dial from. Probed to THIS node's own address too: a host firewall that admits
# the LAN and nothing else drops the Docker network's traffic to its own host (the
# "hairpin") while every host-side check passes (1.3.2, in the field). Each cell is
# a class — ok, refused (an RST: nothing listens, or a REJECT), timeout (nothing
# came back: a DROP, or no host), filtered (host-unreachable) — not a yes/no.
step "probing reachability to every declared member (from this host, and from the Docker network)"
UNREACH=""; NOT_IN_RING=""
declare -A HOSTC=() DOCKC=() PING_OK=()
DOCK_NET=""; DOCK_SUBNET=""; DOCK_WHY=""
if [ "${HAVE_PROBE}" != 1 ]; then
  DOCK_WHY="ha-probe.sh is not in this bundle"
elif ! docker image inspect "${HA_PROBE_IMAGE}" >/dev/null 2>&1; then
  DOCK_WHY="the probe image ${HA_PROBE_IMAGE} is not on this host (a diagnostic does not download)"
else
  # The network(s) of the etcd container — on a DB node taranac_default, on the
  # witness its own compose network (the witness etcd is bridged; only its agent
  # is host-network). Without an etcd container: ha_probe_network's choice.
  for _n in $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${ETCD_REAL}" 2>/dev/null); do
    case "${_n}" in host|none) ;; *) DOCK_NET="${_n}"; break ;; esac
  done
  if [ -n "${DOCK_NET}" ]; then HA_PROBE_NET="${DOCK_NET}"; else ha_probe_network 2>/dev/null; DOCK_NET="${HA_PROBE_NET}"; fi
  # The IPv4 one only (ha-probe.sh): the cure names it in a firewall rule.
  DOCK_SUBNET="$(ha_probe_docker_subnet "${DOCK_NET}")"
fi
# From the Docker network, THIS node's own address is asked on the ports a container
# here dials it by (ha-probe.sh, HA_SELF_PORTS): 2379 — the api and Patroni →
# ETCD_HOSTS, own address included — and, on a database node, 8008 — Patroni → its
# own api_url, which a switchover to this node checks (with 2379 admitted and 8008
# dropped, `cluster switchover --to <this node>` was refused while this said [ok]:
# 1.3.3-rc3, live). Its own database and etcd peer port are reached over the Docker
# network itself, never through the host's LAN address — so a "drop" on them is no
# fault, and once listed as one it became the Next step (run 3).
member_ports() {  # <index> <host|docker>
  if [ "$2" = docker ] && is_self "$1"; then
    [ "${MEMBER_ROLES[$1]}" = db ] && echo "2379 8008" || echo "2379"
  elif [ "${MEMBER_ROLES[$1]}" = db ]; then
    [ "$2" = host ] && echo "2379 2380 5432 8008 443" || echo "2379 2380 5432 8008"
  else
    echo "2379 2380"
  fi
}
{
  echo "Reachability — FROM this node (${NODE_NAME}) TO each declared member"
  echo "===================================================================="
  echo "Ports: 2379 etcd client · 2380 etcd peer · 5432 Postgres · 8008 Patroni REST · 443 api"
  echo "A witness legitimately has ONLY the etcd ports open."
  echo "Classes: ok · refused (an RST — nothing listens, or a firewall REJECTs) ·"
  echo "timeout (nothing came back — a firewall DROPs, or no host) · filtered (host-unreachable)."
  echo "FROM DOCKER is a container on ${DOCK_NET:-(not probed: ${DOCK_WHY})}${DOCK_SUBNET:+ (${DOCK_SUBNET})} — where"
  echo "Patroni and the api dial from; to this node's OWN address it is the hairpin check, asked on"
  echo "2379 and 8008 (the ports a container here dials through the LAN address; 8008 on a database node)."
  echo
  if [ "${DECLARED_MEMBERS}" -eq 0 ]; then
    echo "(no members are declared on this node — nothing to probe)"
  else
    printf '%-22s %-16s %-6s %-10s %s\n' NAME ADDRESS PORT "FROM HOST" "FROM DOCKER"
    # Probed ONCE, with the findings accumulated in the same pass. A brace group
    # does not fork, so the arrays survive the redirection — and on the partitioned
    # cluster this is written for, a second pass would double the slowest part of
    # the run (every dropped port costs the full timeout).
    for i in "${!MEMBER_ADDRS[@]}"; do
      if ! in_live_ring "${MEMBER_ADDRS[$i]}"; then
        printf '%-22s %-16s %s\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "declared here, not in the live ring — not probed"
        NOT_IN_RING="${NOT_IN_RING}${MEMBER_NAMES[$i]} (${MEMBER_ADDRS[$i]}) "
        continue
      fi
      for port in $(member_ports "${i}" host); do
        HOSTC["${i}:${port}"]="$(tcp_class "${MEMBER_ADDRS[$i]}" "${port}")"
        _d="—"
        if [ -n "${DOCK_NET}" ] && printf ' %s ' $(member_ports "${i}" docker) | grep -qF " ${port} "; then
          ha_probe_tcp "${MEMBER_ADDRS[$i]}" "${port}" >/dev/null 2>&1 || true
          _d="${PROBE_CLASS}"; DOCKC["${i}:${port}"]="${_d}"
        fi
        printf '%-22s %-16s %-6s %-10s %s\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "${port}" "${HOSTC[${i}:${port}]}" "${_d}"
        # A witness has no database, api or Patroni: those ports are not probed
        # there at all — calling them unreachable would be a manufactured fault.
        if [ "${HOSTC[${i}:${port}]}" != ok ] && ! is_self "${i}"; then
          UNREACH="${UNREACH}${MEMBER_NAMES[$i]}:${port} (${HOSTC[${i}:${port}]}) "
        fi
      done
      echo "  (${MEMBER_ROLES[$i]})"
    done
  fi
  echo
  echo "--- round-trip time ---"
  if have ping; then
    for i in "${!MEMBER_ADDRS[@]}"; do
      _p="$(ping -c 3 -W 2 "${MEMBER_ADDRS[$i]}" 2>/dev/null | tail -1)"
      case "${_p}" in *rtt*|*round-trip*) PING_OK["${i}"]=1 ;; *) _p="no reply" ;; esac
      printf '%-22s %s\n' "${MEMBER_NAMES[$i]}" "${_p}"
    done
  else
    echo "(ping is not available on this host)"
  fi
  echo
  echo "--- replicator login, every ordered pair (the api's own continuous probe) ---"
  echo "'stale' and 'unknown' are NOT successes. A red cell is usually a PG_ALLOW_CIDR"
  echo "on the SOURCE node that does not cover the target."
  if [ "$(container_running "${API_CT}")" = true ]; then
    docker compose --env-file "${ENV_FILE}" -f "${HERE}/docker-compose.yml" exec -T api \
      python -m app.scripts.cluster connectivity 2>&1 || echo "(connectivity check unavailable)"
  else
    echo "(the api container is not running on this node — the matrix is the api's)"
  fi
} > "${WORK}/reachability.txt" 2>&1

# The api is down, so its login matrix is not there: this node logs in as replicator
# to every declared database node itself — from the Docker network, as Patroni will,
# the password through the environment only (ha-probe.sh). After T0 by construction,
# so a refusal it causes in a database's log is never read back as a signature.
LOGIN_FAIL=""
if [ "$(container_running "${API_CT}")" != true ] && [ -n "${DOCK_NET}" ] \
   && [ -n "$(getenv POSTGRES_REPLICATION_PASSWORD)" ] && [ "${DECLARED_MEMBERS}" -gt 0 ]; then
  HA_PROBE_PASSWORD="$(getenv POSTGRES_REPLICATION_PASSWORD)"
  {
    echo
    echo "--- replicator login from this node's Docker network (the api is not running here) ---"
    for i in "${!MEMBER_ADDRS[@]}"; do
      [ "${MEMBER_ROLES[$i]}" = db ] || continue
      ha_probe_login "${MEMBER_ADDRS[$i]}" 5432 >/dev/null 2>&1 || true
      printf '%-22s %-16s %s\n' "${MEMBER_NAMES[$i]}" "${MEMBER_ADDRS[$i]}" "${PROBE_CLASS}"
      case "${PROBE_CLASS}" in
        auth|hba|nologin)
          _src="${NODE_ADDRESS}"; is_self "${i}" && _src="${DOCK_SUBNET:-the Docker network}"
          LOGIN_FAIL="${LOGIN_FAIL}             ${MEMBER_NAMES[$i]} (${MEMBER_ADDRS[$i]}): ${PROBE_CLASS}
$(ha_probe_cure "${MEMBER_ADDRS[$i]}" 5432 "${_src}" | sed 's/^/               /')
$([ "${PROBE_CLASS}" = auth ] && ha_probe_auth_cure "${MEMBER_NAMES[$i]}" | sed 's/^/               /')
" ;;
      esac
    done
  } >> "${WORK}/reachability.txt" 2>&1
  unset HA_PROBE_PASSWORD
fi
# From the Docker network a port is dropped that the host itself reaches: the path
# Patroni and the api use is cut while every host-side check passes.
DOCK_GAPS=""
for _k in "${!DOCKC[@]}"; do
  case "${DOCKC[$_k]}" in timeout|filtered) ;; *) continue ;; esac
  _i="${_k%%:*}"; _p="${_k#*:}"
  [ "${HOSTC[$_k]:-}" = ok ] || continue
  PROBE_CLASS="${DOCKC[$_k]}"
  if is_self "${_i}"; then
    _cure="$(ha_probe_self_cure "${MEMBER_ADDRS[$_i]}" "${DOCK_SUBNET}")"
  else
    _cure="$(ha_probe_cure "${MEMBER_ADDRS[$_i]}" "${_p}" "${NODE_ADDRESS:-this node}")"
  fi
  DOCK_GAPS="${DOCK_GAPS}             ${MEMBER_NAMES[$_i]}:${_p} — ${PROBE_CLASS} from ${DOCK_NET}, ok from the host:
               ${_cure}
"
done

# ── Step 8: certificates ────────────────────────────────────────────────────
# The SAN check is the one that earns its place: a node whose address changed
# (or was mistyped into .env and then ingested into cluster state) keeps a leaf
# that does not cover the address it now advertises, and every TLS client fails
# with an error about a name rather than about an address.
step "checking the etcd certificates"
CERT_END_EPOCH=""
# The trusted bundle holds ONE CA, except while `cluster rotate-ca` runs (or after it
# stopped part way): then two. `openssl x509` reads only the first certificate of a
# file, so the bundle is split and every CA is shown — the second one is exactly what
# a stopped rotation looks like. Public certificates and fingerprints only; the CA
# key files are named, never read.
CA_SPLIT="${WORK}/.ca-split"; mkdir -p "${CA_SPLIT}"
ca_split() {  # <pem file> <prefix> → one file per certificate under CA_SPLIT, names on stdout
  [ -s "$1" ] || return 0
  awk -v d="${CA_SPLIT}" -v p="$2" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%s-%d.pem", d, p, n) }
    f != "" { print > f }
    /-----END CERTIFICATE-----/ { close(f); print f; f = "" }' "$1"
}
ca_fp() {  # <pem> → SHA-256 fingerprint, lower-case hex without colons ("" when unreadable)
  have openssl || return 0
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}
TRUSTED_FPS=""; TRUSTED_N=0
while IFS= read -r _pem; do
  [ -n "${_pem}" ] || continue
  TRUSTED_N=$((TRUSTED_N + 1)); TRUSTED_FPS="${TRUSTED_FPS} $(ca_fp "${_pem}")"
done < <(ca_split "${BASE_DIR}/config/etcd-tls/ca.crt" trusted)
SIGNER_FP=""; NEXT_FP=""
[ -s "${BASE_DIR}/config/etcd-ca/ca.crt" ] && SIGNER_FP="$(ca_fp "${BASE_DIR}/config/etcd-ca/ca.crt")"
[ -s "${BASE_DIR}/config/etcd-ca/next.crt" ] && NEXT_FP="$(ca_fp "${BASE_DIR}/config/etcd-ca/next.crt")"
NEXT_FILES=""
for _f in next.crt next.key; do [ -e "${BASE_DIR}/config/etcd-ca/${_f}" ] && NEXT_FILES="${NEXT_FILES:+${NEXT_FILES}, }${_f}"; done
{
  echo "etcd client-TLS material"
  echo "========================"
  if [ -s "${BASE_DIR}/config/etcd-tls/ca.crt" ]; then
    echo "CAs this member trusts (config/etcd-tls/ca.crt) — compare across nodes; one CA,"
    echo "the same everywhere, except while ./taranac cluster rotate-ca runs:"
    for _pem in "${CA_SPLIT}"/trusted-*.pem; do
      [ -s "${_pem}" ] || continue
      echo "  SHA-256 $(ca_fp "${_pem}")"
      openssl x509 -in "${_pem}" -noout -subject -dates 2>/dev/null | sed 's/^/    /' || echo "    (openssl could not read it)"
    done
  else
    echo "(no config/etcd-tls/ca.crt — client TLS is off, or this node was never provisioned)"
  fi
  echo
  echo "The CA this member signs with (config/etcd-ca):"
  if [ -n "${SIGNER_FP}" ]; then
    echo "  ca.crt   SHA-256 ${SIGNER_FP}$([ -s "${BASE_DIR}/config/etcd-ca/ca.key" ] && echo ' (its key is here)' || echo ' (no ca.key here)')"
  else
    echo "  (no config/etcd-ca/ca.crt)"
  fi
  if [ -n "${NEXT_FILES}" ]; then
    echo "  ${NEXT_FILES}: present — the next CA of a rotation${NEXT_FP:+, SHA-256 ${NEXT_FP}}"
  fi
  ls -d "${BASE_DIR}"/config/etcd-ca.restored-* 2>/dev/null | sed "s|^${BASE_DIR}/|  set aside by a restore: |"
  echo
  if [ -s "${BASE_DIR}/config/etcd-tls/etcd-server.crt" ]; then
    echo "This node's etcd leaf:"
    openssl x509 -in "${BASE_DIR}/config/etcd-tls/etcd-server.crt" -noout -subject -dates 2>/dev/null | sed 's/^/  /' || true
    echo "  SANs:"
    openssl x509 -in "${BASE_DIR}/config/etcd-tls/etcd-server.crt" -noout -ext subjectAltName 2>/dev/null \
      | tail -n +2 | sed 's/^/    /' || echo "    (none)"
  else
    echo "(this node has no etcd leaf at config/etcd-tls/etcd-server.crt)"
  fi
} > "${WORK}/certs.txt" 2>&1

if [ -s "${BASE_DIR}/config/etcd-tls/etcd-server.crt" ] && have openssl; then
  not_after="$(openssl x509 -in "${BASE_DIR}/config/etcd-tls/etcd-server.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
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
    if ! openssl x509 -in "${BASE_DIR}/config/etcd-tls/etcd-server.crt" -noout -ext subjectAltName 2>/dev/null \
         | grep -qF -- "${NODE_ADDRESS}"; then
      finding "[CERT]     This node advertises ${NODE_ADDRESS}, but its etcd certificate does NOT
           cover that address in its SANs (see certs.txt). Every TLS client will
           reject it — usually reported as a name mismatch rather than as a wrong
           address. This is what a changed or mistyped node address looks like."
    fi
  fi
fi

# ── Step 8b: the etcd CA — one, everywhere, or a rotation to finish ─────────
# `cluster rotate-ca` marks its attempt at /taranac/tls/rotation and clears the mark
# only when every member is on one CA again; it holds the cluster lock (op=rotate-ca)
# only while it runs. A mark without the lock is a rotation that stopped: the cure is
# the same command again. Without a mark, a member trusting two CAs or holding next.*
# is debris of one — the same command puts it right. A signer that is not among the
# CAs this member trusts is a config/etcd-ca from somewhere else (an old archive).
ROTATION_MARK=""; ROTATION_LOCK=""
if [ -s "${WORK}/etcd-members.json" ]; then
  ROTATION_MARK="$(etcdctl_run get /taranac/tls/rotation --print-value-only 2>/dev/null | head -1 || true)"
  case "${ROTATION_MARK}" in '{'*) ;; *) ROTATION_MARK="" ;; esac
  if [ -n "${ROTATION_MARK}" ]; then
    ROTATION_LOCK="$(etcdctl_run get /taranac/update/lock --print-value-only 2>/dev/null | head -1 || true)"
  fi
fi
json_str() {  # <json> <field>
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}
if [ -n "${ROTATION_MARK}" ]; then
  _by="$(json_str "${ROTATION_MARK}" by)"; _at="$(json_str "${ROTATION_MARK}" at)"
  printf 'rotation mark (/taranac/tls/rotation): %s\n' "${ROTATION_MARK}" >> "${WORK}/certs.txt"
  case ";${ROTATION_LOCK};" in
    *";op=rotate-ca;"*)
      note "An etcd CA rotation (started by ${_by:-?} at ${_at:-?}) is running right now. Let it end; add-node and add-witness wait for it." ;;
    *)
      finding "[CA ROTATION] An etcd CA rotation started by ${_by:-?} at ${_at:-?} has not finished.
           Until it has, the members may not agree on one CA: add-node and add-witness
           refuse, and a member that restarts may not verify the others. Finish it —
           on a database node (it completes the rotation or puts every member back on
           the old CA, and says which):  ./taranac cluster rotate-ca" ;;
  esac
elif [ -s "${WORK}/etcd-members.json" ] && { [ "${TRUSTED_N}" -gt 1 ] || [ -n "${NEXT_FILES}" ]; }; then
  _what="${NEXT_FILES:+config/etcd-ca holds ${NEXT_FILES}}"
  [ "${TRUSTED_N}" -gt 1 ] && _what="${_what:+${_what}, and }config/etcd-tls/ca.crt trusts ${TRUSTED_N} CAs"
  finding "[CA ROTATION] This member is part way through an etcd CA rotation (${_what}),
           but the cluster has no rotation marked — one stopped and its mark is gone.
           Put every member back on one CA — on a database node:  ./taranac cluster rotate-ca"
fi
# A settle cut short trusts only the next CA while ca.crt is still the old one — the
# rotation's state (said above), not a foreign config/etcd-ca.
if [ -n "${SIGNER_FP}" ] && [ "${TRUSTED_N}" -gt 0 ] && [ -n "${TRUSTED_FPS// /}" ] \
   && { [ -z "${NEXT_FP}" ] || [ "${TRUSTED_FPS# }" != "${NEXT_FP}" ]; }; then
  case " ${TRUSTED_FPS} " in
    *" ${SIGNER_FP} "*) ;;
    *) finding "[CA]       config/etcd-ca/ca.crt is not a CA this member trusts (config/etcd-tls/ca.crt):
           the two directories belong to different CAs. Usually config/etcd-ca was
           restored from an archive older than a CA rotation (see certs.txt). This
           member cannot renew its certificate or admit a node from it. Re-join it —
           on another database node:  ./taranac cluster remove-node --node ${NODE_NAME:-<this node>}
           (remove-witness for the witness), then add it again." ;;
  esac
fi
rm -rf "${CA_SPLIT}"

# ── Step 8c: the EAP-TLS CRL directory, as a fingerprint ────────────────────
# Every node writes its own certs/crl/ from the shared database, so the CRL a
# revocation depends on can differ between nodes: one node's deploy failed, or
# its download is a fetch interval behind. A client sent to that node is then
# accepted where another node refuses it — a fault visible only by comparing.
# So, like the cluster-fingerprint: one line per node, a 12-hex hash over every
# CRL (file name, CRL Number, sha256 of its DER) and every CA certificate in the
# directory. Identical on every database node ⇒ they enforce the same CRLs.
# Read INSIDE the nac container by the same crl-inventory.sh `diagnose --protocol
# nac` uses; mtimes and hash links are left out of the hash (they legitimately
# differ). A difference younger than one crl_fetch interval can be a deploy in
# flight — collect again before concluding.
CRL_FP=""
CRL_COUNT=0
NAC_CT="$(resolve_container taranac-nac)"
if [ -f "${HERE}/crl-inventory.sh" ] && [ "$(container_running "${NAC_CT}")" = true ]; then
  step "fingerprinting the EAP-TLS CRL directory"
  docker exec -i "${NAC_CT}" sh -s -- /etc/raddb/certs/crl \
    < "${HERE}/crl-inventory.sh" > "${WORK}/crl-inventory.tsv" 2>/dev/null || true
  {
    echo "EAP-TLS CRL directory on this node (/etc/raddb/certs/crl in ${NAC_CT})"
    echo "======================================================================"
    echo "(compare across database nodes — the CRL lines MUST be identical everywhere)"
    awk -F'\t' '
      $1 == "DIR" && $3 == "missing" { print "(directory missing)" }
      $1 == "CRL"  { printf "CRL   %-56s number %-10s DER sha256 %s  nextUpdate %s\n", $2, $7, substr($9, 1, 12), $6 }
      $1 == "CERT" { cert[$2] = 1 }
      $1 == "FILE" { sha[$2] = substr($5, 1, 12) }
      $1 == "LINK" && $4 == "broken" { printf "BROKEN LINK %s -> %s\n", $2, $3 }
      END { for (n in cert) printf "CERT  %-56s sha256 %s\n", n, sha[n] }
    ' "${WORK}/crl-inventory.tsv" 2>/dev/null | sort
  } > "${WORK}/crl.txt" 2>&1
  CRL_FP="$(awk -F'\t' '
      $1 == "CRL"  { print "CRL " $2 " " $7 " " $9 }
      $1 == "FILE" { sha[$2] = $5 }
      $1 == "CERT" { cert[$2] = 1 }
      END { for (n in cert) print "CERT " n " " sha[n] }
    ' "${WORK}/crl-inventory.tsv" 2>/dev/null | LC_ALL=C sort | sha256sum | cut -c1-12)"
  CRL_COUNT="$(awk -F'\t' '$1 == "CRL"' "${WORK}/crl-inventory.tsv" 2>/dev/null | wc -l | tr -d '[:space:]')"
  if grep -q '^BROKEN LINK' "${WORK}/crl.txt" 2>/dev/null; then
    finding "[CRL]      A hash link in this node's EAP-TLS CRL directory points at a missing
           file (see crl.txt). OpenSSL finds CRLs through those links; a dangling one
           hides the CRL or CA certificate it should lead to."
  fi
fi

# ── Step 9: logs ────────────────────────────────────────────────────────────
step "collecting component logs (last ${LOG_LINES} lines each)"
for ct in taranac-db "${ETCD_CT}" taranac-api taranac-etcd-agent; do
  real_ct="$(resolve_container "${ct}")"
  if docker inspect "${real_ct}" >/dev/null 2>&1; then
    docker logs --tail "${LOG_LINES}" "${real_ct}" 2>&1 | redact > "${WORK}/logs/${ct#taranac-}.log" || true
  fi
done
# What the log scan found, beside the excerpts it was read from.
{
  echo "Signatures — lines in this node's container logs that name a known cause"
  echo "========================================================================"
  echo "Read up to T0 = $(utc_of "${T0}"), before this collector probed anything, so"
  echo "none of these lines can be an echo of this run. Table and cures: ha-probe.sh."
  echo "live = the last match is at most $((LIVE_WINDOW / 60)) minutes old, or the container has stopped and"
  echo "the match is from its last run. past = still reported, never acted on."
  echo
  echo "windows read:"
  printf '%s' "${SIG_WINDOWS:-  (no etcd, database or api container on this host)
}"
  [ "${HAVE_PROBE}" = 1 ] || echo "  (ha-probe.sh is not in this bundle — the logs were not matched; refresh the bundle: ./taranac update)"
  echo
  if [ "${#SIG_ID[@]}" -eq 0 ]; then
    echo "(no signature matched)"
  fi
  for _i in "${!SIG_ID[@]}"; do
    printf '%-15s %-5s %6s×  %s … %s  in %s\n' "${SIG_ID[$_i]}" "${SIG_STATE[$_i]}" "${SIG_COUNT[$_i]}" \
      "${SIG_FIRST[$_i]}" "${SIG_LAST[$_i]}" "${SIG_CT[$_i]}"
    printf '    sample: %s\n' "${SIG_SAMPLE[$_i]}"
    if [ "${SIG_ID[$_i]}" = ETCD-ID ]; then
      printf '    local-member-cluster-id=%s remote-peer-cluster-id=%s remote-peer=%s\n' \
        "$(etcd_id_field "${SIG_SAMPLE[$_i]}" local-member-cluster-id)" \
        "$(etcd_id_field "${SIG_SAMPLE[$_i]}" remote-peer-cluster-id)" \
        "$(etcd_id_field "${SIG_SAMPLE[$_i]}" remote-peer-id)$(etcd_id_field "${SIG_SAMPLE[$_i]}" remote-peer-server-name)"
    fi
  done
  if [ -n "${BIND_CT}" ]; then
    echo
    echo "BIND   ${BIND_CT} could not start: ${BIND_ERR}"
  fi
} > "${WORK}/signatures.txt" 2>&1

# The update finisher (a DB node mid-update hands the rest of its start to it) and
# the updater's own trail — through redact() like every other log (see its comment).
FINISHER_STATE="$(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}}, started {{.State.StartedAt}})' taranac-update-finisher 2>/dev/null || true)"
if [ -n "${FINISHER_STATE}" ]; then
  docker logs --tail "${LOG_LINES}" taranac-update-finisher 2>&1 | redact > "${WORK}/logs/update-finisher.log" || true
fi
if [ -r "${BASE_DIR}/.taranac-update.log" ]; then
  tail -n "${LOG_LINES}" "${BASE_DIR}/.taranac-update.log" 2>/dev/null | redact > "${WORK}/logs/taranac-update.log" || true
fi
{
  echo "update finisher container : ${FINISHER_STATE:-(none on this host)}"
  echo "updater trail             : $([ -r "${BASE_DIR}/.taranac-update.log" ] && echo "${BASE_DIR}/.taranac-update.log (tail in logs/taranac-update.log)" || echo '(none)')"
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

# Quorum arithmetic: the "fewer than 3" check from the DECLARED ring — it works even
# with etcd down, which is when the question is most likely to be asked; the even-count
# one from the live ring whenever it was read.
if [ "${DECLARED_MEMBERS}" -gt 0 ]; then
  if [ "${DECLARED_MEMBERS}" -lt 3 ]; then
    finding "[QUORUM]   Only ${DECLARED_MEMBERS} etcd member(s) are declared on this node. HA needs at
           least 3 (the database nodes plus an arbiter in a SEPARATE failure domain).
           With fewer, a partition has no majority and failover is unsafe."
  else
    # The voters are the live ring's when it was read — this node's .env lags behind
    # every add and remove made on another node (remove-witness left three voters and
    # a declaration of four, which this used to call "4 voters … remove the witness").
    voters="${DECLARED_MEMBERS}"; [ "${ETCD_MEMBER_COUNT}" -gt 0 ] && voters="${ETCD_MEMBER_COUNT}"
    # Which voters are witnesses. A database node knows from DB_HOSTS; a witness has no
    # DB_HOSTS, so every member would read as a witness there — but the build makes ONE
    # witness, and on a witness host it is this host.
    witnesses=0
    if [ "${ROLE_GUESS}" = "witness (etcd only)" ] && [ -z "${DB_HOSTS}" ]; then
      witnesses=1
    else
      for i in "${!MEMBER_ADDRS[@]}"; do
        [ "${MEMBER_ROLES[$i]}" = witness ] && in_live_ring "${MEMBER_ADDRS[$i]}" && witnesses=$((witnesses + 1))
      done
    fi
    # Declared here and not in the live ring yet: a build in progress (`init` declares
    # every node, `add-node` joins them one at a time). Its two-member ring after
    # add-witness is the step HA.md prescribes, not a design someone chose.
    pending=0
    for i in "${!MEMBER_ADDRS[@]}"; do
      [ "${MEMBER_ROLES[$i]}" = db ] && ! in_live_ring "${MEMBER_ADDRS[$i]}" && pending=$((pending + 1))
    done
    if [ $(( voters % 2 )) -eq 0 ]; then
      if [ "${witnesses}" = 1 ] && [ $(( voters - 1 )) -ge 3 ]; then
        # Three or more database nodes and their witness is the shape the build makes:
        # `init` refuses without a witness whatever the node count (HA.md §2). It is not
        # a fault, so it is not a finding — the witness can simply go now.
        note "${voters} etcd voters: $(( voters - 1 )) database nodes and the witness. A majority of
           ${voters} survives one loss, as the database nodes alone do — the witness adds
           nothing at this size. To take it out, on any database node:
               ./taranac cluster remove-witness"
      elif [ "${pending}" -gt 0 ]; then
        note "${voters} etcd voters so far, and ${pending} declared database node(s) not joined yet —
           the build is part-way. Until they join, the ring survives no loss. Add them, on
           a database node (HA.md §3.3):
               ./taranac cluster add-node --address <node>"
      else
        finding "[QUORUM]   An EVEN number of etcd voting members (${voters}). A majority of ${voters}
           survives no more losses than a majority of $(( voters - 1 )) does, and there is one more
           member that can fail. Prefer an odd count."
      fi
    fi
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
    note "This witness's .env declares ${DECLARED_MEMBERS} etcd member(s), but the live ring
           reports ${ETCD_MEMBER_COUNT}. On a witness this is not urgent — its running etcd
           takes the ring from Raft, and the list is read only when it bootstraps.
           It matters if this host is ever rebuilt: re-point it at the cluster and
           the list is rewritten from the live ring —
               ./witness-join.sh --broker … --token … --pin …
           (\`cluster sync\` is a DATABASE-node command; this wrapper refuses it here.)"
  else
    # Not a finding: it is the state every by-the-book build leaves on the nodes
    # add-node did not run on, and nothing reads the list on a running member.
    # add-node rewrites its own list before handing it to a joiner, and `update`
    # rewrites it before it restarts anything (HA.md §3.5) — so the finding that
    # was here told the operator to fix what the product fixes itself.
    note "This node's .env declares ${DECLARED_MEMBERS} etcd member(s); the live ring reports ${ETCD_MEMBER_COUNT}.
           The ordinary state after a node is added or removed elsewhere: a running etcd
           takes its ring from Raft, add-node rewrites this list before handing it to a
           joining node, and the next update rewrites it. Nothing to do by hand; to bring
           it up to date now, without restarting anything:
               ./taranac cluster sync"
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
           form makes every 2379 check look perfectly healthy.
           refused = the host answered and nothing listens (or a REJECT): start it there.
           timeout = nothing came back (a DROP, or no host): a firewall or route."
fi
if [ -n "${DOCK_GAPS}" ]; then
  finding "[DOCKER PATH] From the Docker network (${DOCK_NET}) — where Patroni and the api dial
           from — these member ports are dropped, while the host itself reaches them:
${DOCK_GAPS%$'\n'}"
fi
if [ -n "${LOGIN_FAIL}" ]; then
  finding "[LOGIN]    replicator could not log in, from this node's Docker network:
${LOGIN_FAIL%$'\n'}"
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
  if printf '%s' "${DB_COMPOSE_FILES}" | grep -q 'docker-compose.ha.yml'; then
    finding "[NOT CONVERTED] This node's database was started WITH the Patroni overlay
           (docker-compose.ha.yml), but TARANAC_HA is absent from .env. The tooling
           decides which compose files to apply from that marker: the next
           ./taranac up -d drops the overlay — a plain, writable Postgres on Patroni's
           data directory. Set the marker now:
               printf '\\nTARANAC_HA=1\\n' >> .env"
  else
    finding "[NOT CONVERTED] This node declares a cluster topology (DB_HOSTS and an etcd ring are
           set) but TARANAC_HA is absent. The tooling decides which compose files to
           apply from that marker, so this node will be started WITHOUT the Patroni
           overlay — see the split-brain verdict. Either finish the conversion or
           clear the topology."
  fi
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
PAT_KNOWN=0; PAT_LEADER=""; PAT_SPARE=""; PAT_STUCK=""; PAT_MEMBERS=""
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
# Every member Patroni lists, with the state it reports — what next_for reads.
for m in members:
    print("{}\t{}\t{}\t{}".format(m.get("name", "?"), m.get("host", ""), m.get("state", "?"), m.get("role", "")))
PY
)"
  if [ -n "${_pat}" ]; then
    PAT_KNOWN=1
    _head="$(printf '%s\n' "${_pat}" | head -1)"
    PAT_MEMBERS="$(printf '%s\n' "${_pat}" | tail -n +2)"
    PAT_LEADER="${_head%%|*}"; _rest="${_head#*|}"
    PAT_SPARE="${_rest%%|*}"; PAT_STUCK="${_rest#*|}"
  fi
fi
# The state Patroni reports for a member, by its name or its address ("" = not listed).
pat_state_of() {  # <name> <address>
  [ -n "${PAT_MEMBERS}" ] || return 0
  printf '%s\n' "${PAT_MEMBERS}" | awk -F'\t' -v n="$1" -v a="$2" \
    '$1 == n || (a != "" && $2 == a) { print $3; exit }'
}
# A DECLARED database member that Patroni does not list at all is down, not spare —
# matched by name or by address, since the ring's name and Patroni's may differ. The
# declared list (DB_HOSTS) and the ring's database members both count: on a witness
# DB_HOSTS is empty and the ring is the only list.
if [ "${PAT_KNOWN}" = 1 ]; then
  _cands=""
  for i in "${!MEMBER_NAMES[@]}"; do
    [ "${MEMBER_ROLES[$i]}" = db ] && _cands="${_cands}${MEMBER_NAMES[$i]}|${MEMBER_ADDRS[$i]} "
  done
  for i in "${!RING_N[@]}"; do
    [ "${RING_KIND[$i]}" = db ] && _cands="${_cands}${RING_N[$i]}|${RING_ADDR[$i]} "
  done
  for _c in ${_cands}; do
    _n="${_c%%|*}"; _a="${_c#*|}"
    [ -n "$(pat_state_of "${_n}" "${_a}")" ] && continue
    case ",${PAT_LEADER},${PAT_SPARE},${PAT_STUCK}," in *",${_n},"*) continue ;; esac
    PAT_STUCK="${PAT_STUCK:+${PAT_STUCK},}${_n}"
  done
fi
first_of() { printf '%s' "$1" | cut -d, -f1 | tr -d ' '; }

addr_of() {  # <member name> → its address, from the declaration, the ring, or Patroni
  local i
  for i in "${!MEMBER_NAMES[@]}"; do [ "${MEMBER_NAMES[$i]}" = "$1" ] && { printf '%s' "${MEMBER_ADDRS[$i]}"; return 0; }; done
  for i in "${!RING_N[@]}"; do [ "${RING_N[$i]}" = "$1" ] && { printf '%s' "${RING_ADDR[$i]}"; return 0; }; done
  printf '%s\n' "${PAT_MEMBERS}" | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'
}

# Rule 4 of the header: the one step for a member the verdict names. Computed from
# what was observed — Patroni's list and this run's probes — never from the verdict's
# wording alone: `up -d` is never said to a node whose Patroni is running.
next_for() {  # <member name>
  local x="$1" a st i=-1 j port c n_ok=0 n_ref=0 n_drop=0 d_port="" d_class="" src
  a="$(addr_of "${x}")"
  st="$(pat_state_of "${x}" "${a}")"
  if [ -n "${st}" ]; then
    if [ "${x}" = "${NODE_NAME}" ] || { [ -n "${a}" ] && [ "${a}" = "${NODE_ADDRESS}" ]; }; then
      printf "this node's Patroni runs, its database is %s, and no known cause is in its logs (signatures.txt) — read logs/db.log in this bundle" "${st}"
    else
      printf "%s's Patroni runs, its database is %s: on %s run ./taranac diagnose --ha and read its signatures" "${x}" "${st}" "${x}"
    fi
    return 0
  fi
  for j in "${!MEMBER_NAMES[@]}"; do
    { [ "${MEMBER_NAMES[$j]}" = "${x}" ] || { [ -n "${a}" ] && [ "${MEMBER_ADDRS[$j]}" = "${a}" ]; }; } && { i="${j}"; break; }
  done
  if [ "${i}" -lt 0 ]; then
    printf 'on %s%s:  ./taranac diagnose --ha' "${x}" "${a:+ (${a})}"; return 0
  fi
  for port in $(member_ports "${i}" host); do
    c="${HOSTC[${i}:${port}]:-}"
    # This node's own address: the Docker network's answer is the one that matters.
    if is_self "${i}"; then
      case "${DOCKC[${i}:${port}]:-}" in timeout|filtered) c="${DOCKC[${i}:${port}]}" ;; esac
    fi
    case "${c}" in
      ok) n_ok=$((n_ok + 1)) ;;
      refused) n_ref=$((n_ref + 1)) ;;
      timeout|filtered) n_drop=$((n_drop + 1)); [ -n "${d_port}" ] || { d_port="${port}"; d_class="${c}"; } ;;
    esac
  done
  if [ "${n_drop}" -gt 0 ] && { [ $((n_ok + n_ref)) -gt 0 ] || [ -n "${PING_OK[${i}]:-}" ]; }; then
    PROBE_CLASS="${d_class}"
    src="${NODE_ADDRESS:-this node}"; is_self "${i}" && src="${DOCK_SUBNET:-the Docker network ${DOCK_NET:-taranac_default}}"
    if [ "${HAVE_PROBE}" = 1 ] && is_self "${i}"; then
      printf '%s answers, but %s:%s is %s from here: %s' "${x}" "${a}" "${d_port}" "${d_class}" "$(ha_probe_self_cure "${a}" "${DOCK_SUBNET}")"
    elif [ "${HAVE_PROBE}" = 1 ]; then
      printf '%s answers, but %s:%s is %s from here: %s' "${x}" "${a}" "${d_port}" "${d_class}" "$(ha_probe_cure "${a}" "${d_port}" "${src}")"
    else
      printf '%s answers, but %s:%s is %s from here: admit %s to tcp/%s on %s' "${x}" "${a}" "${d_port}" "${d_class}" "${src}" "${d_port}" "${a}"
    fi
  elif [ "${n_ref}" -gt 0 ]; then
    printf 'on %s:  ./taranac up -d   (%s answers, nothing listens on its refused ports — then ./taranac diagnose --ha on it)' "${x}" "${a}"
  elif [ "${n_ok}" -eq 0 ] && [ -z "${PING_OK[${i}]:-}" ]; then
    if have ping; then
      printf '%s (%s) does not answer at all — no port, no ping: is it powered on and reachable?' "${x}" "${a}"
    else
      printf '%s (%s) answers on no port, and this host has no ping to ask further: check it is up and reachable' "${x}" "${a}"
    fi
  else
    printf 'on %s:  ./taranac diagnose --ha' "${x}"
  fi
}

# ETCD-ID, said for THIS machine: the literal, then the recipe per member that can
# be reached on its peer port (a member that cannot is not the other ring's half —
# or cannot be told so from here).
etcd_id_cure() {  # <sample>
  local smp="$1" peer i any=""
  peer="$(etcd_id_field "${smp}" remote-peer-id)"; [ -n "${peer}" ] || peer="$(etcd_id_field "${smp}" remote-peer-server-name)"
  if [ "${ROLE_GUESS}" = "witness (etcd only)" ]; then
    if [ -z "$(getenv TARANAC_CLUSTER_ID)" ]; then
      echo "this witness's .env has no TARANAC_CLUSTER_ID, so its etcd bootstrapped with a"
      echo "token of its own and formed a ring of its own. Join it again — on the leader:"
      echo "  ./taranac cluster add-witness --address ${NODE_ADDRESS:-<this witness>}"
      echo "and run the witness-join.sh command it prints here."
    else
      echo "this witness's etcd volume holds an earlier ring (cluster $(etcd_id_field "${smp}" local-member-cluster-id))."
      ha_sig_witness_wipe "${NODE_ADDRESS}"
    fi
    return 0
  fi
  echo "this etcd (cluster $(etcd_id_field "${smp}" local-member-cluster-id)) and peer ${peer:-?} (cluster $(etcd_id_field "${smp}" remote-peer-cluster-id)) belong to different rings."
  for i in "${!MEMBER_NAMES[@]}"; do
    is_self "${i}" && continue
    [ "${HOSTC[${i}:2380]:-}" = ok ] || continue
    any=1
    echo "${MEMBER_NAMES[$i]} (${MEMBER_ADDRS[$i]}) answers on 2380:"
    if [ "${MEMBER_ROLES[$i]}" = db ]; then
      ha_sig_db_readd "${MEMBER_ADDRS[$i]}" | sed 's/^/  /'
    else
      ha_sig_witness_wipe "${MEMBER_ADDRS[$i]}" | sed 's/^/  /'
    fi
    echo "  then on ${MEMBER_NAMES[$i]}:  ./taranac diagnose --ha"
  done
  [ -n "${any}" ] || echo "no other member answers on 2380 from here — run ./taranac diagnose --ha on each of them."
}
sig_cure_of() {  # <index into SIG_*>
  if [ "${SIG_ID[$1]}" = ETCD-ID ]; then etcd_id_cure "${SIG_SAMPLE[$1]}"; return 0; fi
  case "${SIG_ID[$1]}" in
    CLONE-AUTH) ha_sig_cure CLONE-AUTH "${PAT_LEADER:-the leader}" ;;
    # A role is changed on the primary only: on any other node, aim it there.
    NO-ROLE|REPL-PASSWORD|NOLOGIN|NO-REPLICATION)
      if [ -n "${PAT_LEADER}" ] && [ "${PAT_LEADER}" != "${NODE_NAME}" ] && [ "${PAT_LEADER}" != "${ETCD_NAME_ENV}" ]; then
        ha_sig_cure "${SIG_ID[$1]}" "${PAT_LEADER}"
      else
        ha_sig_cure "${SIG_ID[$1]}"
      fi ;;
    *)          ha_sig_cure "${SIG_ID[$1]}" ;;
  esac
}

# Every signature is a finding — live or past, each with its cure — and they come
# FIRST: the literal line a daemon wrote outranks anything inferred from state.
SIG_FINDINGS=()
for _i in "${!SIG_ID[@]}"; do
  _when="live"
  [ "${SIG_STATE[$_i]}" = live ] || _when="past — older than $((LIVE_WINDOW / 60)) min while it runs, or before its last start: reported, not acted on"
  [ -n "${SIG_WHY[$_i]}" ] && _when="past (${SIG_WHY[$_i]})"
  SIG_FINDINGS+=("[${SIG_ID[$_i]}] ${SIG_COUNT[$_i]}× in ${SIG_CT[$_i]}'s log, ${SIG_FIRST[$_i]} … ${SIG_LAST[$_i]} (${_when})
             | $(printf '%s' "${SIG_SAMPLE[$_i]}" | cut -c1-200)
$(sig_cure_of "${_i}" | sed 's/^/           /')")
done
if [ -n "${BIND_CT}" ]; then
  SIG_FINDINGS+=("[BIND]     Docker could not start ${BIND_CT}: a port it publishes is taken on this host.
             | ${BIND_ERR}
           Find what holds it, stop that, then start the stack:
               sudo ss -ltnp 'sport = :${BIND_PORT:-<port>}'
               ./taranac up -d")
fi
[ "${#SIG_FINDINGS[@]}" -eq 0 ] || FINDINGS=("${SIG_FINDINGS[@]}" "${FINDINGS[@]+"${FINDINGS[@]}"}")

# Rule 3a: this node's own :2379 or :8008 is dropped from its Docker network while the
# host reaches it — the hairpin. Ranked above the live db/api signatures: those are what
# the cut path produces (an api that cannot reach etcd, a Patroni that cannot hold
# its lease, a switchover to this node refused), and in the hostile run a stale role
# line was Next while this was the fault (finding 5). Every dropped port is named; the
# cure is one rule for both (ha_probe_self_cure).
HAIRPIN=""
for i in "${!MEMBER_ADDRS[@]}"; do
  is_self "${i}" || continue
  _hp=""
  for _p in $(member_ports "${i}" docker); do
    case "${DOCKC[${i}:${_p}]:-}" in timeout|filtered) ;; *) continue ;; esac
    [ "${HOSTC[${i}:${_p}]:-}" = ok ] || continue
    _hp="${_hp:+${_hp}, }${MEMBER_NAMES[$i]}:${_p} is ${DOCKC[${i}:${_p}]}"
  done
  [ -n "${_hp}" ] || continue
  HAIRPIN="${_hp} from ${DOCK_NET}, ok from the host (the hairpin): $(ha_probe_self_cure "${MEMBER_ADDRS[$i]}" "${DOCK_SUBNET}")"
  break
done

# Rule 5b: a member Patroni reports streaming that the roster has no active row for —
# a join stopped after the clone and before its api started. Its api registers it
# (ha-probe.sh, ha_finish_join), so `up -d` there is the step; rule 6's ban on `up -d`
# stays for a member that is cloning or starting. Read only where this host has a
# roster to read (a database node).
UNREG_NAME=""; UNREG_ADDR=""; UNREG_FINISH=""
if [ "${HAVE_PROBE}" = 1 ] && [ -n "${PAT_MEMBERS}" ] && [ -n "${ROSTER_ROWS}" ]; then
  while IFS=$'\t' read -r _n _h _st _r; do
    [ -n "${_n}" ] || continue
    case "${_r}" in replica|sync_standby) ;; *) continue ;; esac
    case "${_st}" in streaming|running) ;; *) continue ;; esac
    roster_has "${_n}" "${_h}" && continue
    UNREG_NAME="${_n}"; UNREG_ADDR="${_h}"
    UNREG_FINISH="$(ha_finish_join "${_n}" "${_h}" "$(getenv TARANAC_VERSION)" "${_h}" "on the leader (${PAT_LEADER:-the primary})")"
    finding "[UNREGISTERED] ${_n} (${_h}) streams (Patroni: ${_st}) but has no active roster row — its join stopped
           after the clone and before its api registered it. The cluster cannot name it.
$(printf '%s\n' "${UNREG_FINISH}" | sed 's/^/           /')"
    break
  done <<< "${PAT_MEMBERS}"
fi

if [ "${ROLE_GUESS}" = "standalone (not part of a cluster)" ]; then
  VERDICT="Standalone — one machine, no failover. Losing it stops the service."
elif [ "${RING_READ}" -ne 1 ]; then
  VERDICT="Unknown — the etcd ring could not be read from this host, so no machine can be judged from here."
elif [ "${RING_HEALTHY}" -lt "${RING_MAJORITY}" ]; then
  VERDICT="FROZEN — only ${RING_HEALTHY} of ${RING_VOTERS} machines of the etcd ring answer (${RING_DOWN:-?} down). Without a majority no leader can hold the cluster lock, so writes stop until one returns."
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_LEADER}" ]; then
  VERDICT="FROZEN — no writable primary right now. Writes are refused until a leader returns; a failover may be in progress."
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_SPARE}" ]; then
  if [ -n "${PAT_STUCK}" ]; then
    # Each with the state Patroni reports for it — "creating replica" and "not listed"
    # are different faults, and the next step below differs with them.
    _desc=""
    for _n in $(printf '%s' "${PAT_STUCK}" | tr ',' ' '); do
      _st="$(pat_state_of "${_n}" "$(addr_of "${_n}")")"
      _desc="${_desc:+${_desc}, }${_n} (${_st:-not listed by Patroni})"
    done
    VERDICT="Degraded — ${_desc} cannot take over (down, or too far behind to be promoted). Losing ${PAT_LEADER} now stops writes."
  else
    VERDICT="Degraded — there is no replica to take over. Losing ${PAT_LEADER} now stops writes."
  fi
elif [ $((RING_HEALTHY - 1)) -lt "${RING_MAJORITY}" ]; then
  if [ -n "${RING_DOWN}" ]; then
    VERDICT="Degraded — ${RING_DOWN} is down. One more loss stops writes."
  else
    VERDICT="Degraded — the etcd ring has ${RING_VOTERS} voting machines (${RING_MACHINES}) and needs ${RING_MAJORITY}, so losing any one stops writes."
  fi
elif [ "${PAT_KNOWN}" = 1 ]; then
  VERDICT="Healthy — any one machine (${RING_MACHINES}) can be lost and writes continue."
  [ -n "${RING_DOWN}" ] && VERDICT="${VERDICT} ${RING_DOWN} is down — that redundancy is already spent."
else
  VERDICT="Ring healthy — any one machine (${RING_MACHINES}) can be lost without losing etcd quorum. Whether a replica can take over could not be seen from here: no Patroni answered."
fi
[ -n "${RING_UNKNOWN}" ] && VERDICT="${VERDICT} (Not asked from here: ${RING_UNKNOWN}.)"

# The next step — the header's rules, in order; the first that applies wins.
if [ "${ROLE_GUESS}" = "standalone (not part of a cluster)" ]; then                       # 1
  NEXT_CMD="nothing to do: this host is not part of a cluster."
elif [ -n "${BIND_CT}" ]; then                                                             # 2
  NEXT_CMD="[BIND] free port ${BIND_PORT:-?} on this host (sudo ss -ltnp 'sport = :${BIND_PORT:-<port>}'), then ./taranac up -d"
elif [ -n "${SIG_LIVE_I}" ] && [ "${SIG_KIND[$SIG_LIVE_I]}" = etcd ]; then                 # 2
  NEXT_CMD="[${SIG_ID[$SIG_LIVE_I]}] $(sig_cure_of "${SIG_LIVE_I}" | sed '2,$s/^/        /')"
elif [ "${RING_READ}" -eq 1 ] && [ "${RING_HEALTHY}" -lt "${RING_MAJORITY}" ]; then         # 3
  NEXT_CMD="$(next_for "$(first_of "${RING_DOWN}")")"
elif [ -n "${HAIRPIN}" ]; then                                                             # 3a
  NEXT_CMD="[DOCKER PATH] ${HAIRPIN}"
elif [ -n "${SIG_LIVE_I}" ]; then                                                          # 4
  NEXT_CMD="[${SIG_ID[$SIG_LIVE_I]}] $(sig_cure_of "${SIG_LIVE_I}" | sed '2,$s/^/        /')"
elif [ "${RING_READ}" -ne 1 ]; then                                                        # 5
  NEXT_CMD="./taranac diagnose --ha   (on another member of the ring — see etcd.txt for why this one could not ask)"
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_LEADER}" ]; then                                # 8
  NEXT_CMD="./taranac cluster status   (on a database node, in a minute — then logs/db.log here)"
elif [ -n "${UNREG_NAME}" ]; then                                                          # 5b
  NEXT_CMD="[UNREGISTERED] ${UNREG_NAME} (${UNREG_ADDR}) streams with no active roster row — $(printf '%s\n' "${UNREG_FINISH}" | sed '2,$s/^/        /')"
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_SPARE}" ] && [ -n "${PAT_STUCK}" ]; then        # 6
  NEXT_CMD="$(next_for "$(first_of "${PAT_STUCK}")")"
elif [ "${PAT_KNOWN}" = 1 ] && [ -z "${PAT_SPARE}" ]; then                                 # 7
  NEXT_CMD="./taranac cluster add-node --address <a second database machine>   (on the leader, ${PAT_LEADER})"
elif [ $((RING_HEALTHY - 1)) -lt "${RING_MAJORITY}" ] && [ -n "${RING_DOWN}" ]; then       # 6
  NEXT_CMD="$(next_for "$(first_of "${RING_DOWN}")")"
elif [ $((RING_HEALTHY - 1)) -lt "${RING_MAJORITY}" ]; then                                # 8
  NEXT_CMD="./taranac cluster add-witness --address <a third machine>   (on the leader)"
elif [ "${PAT_KNOWN}" = 1 ]; then                                                          # 8
  NEXT_CMD="nothing to fix from this host's view — compare the bundles from the other machines."
else                                                                                       # 8
  NEXT_CMD="./taranac cluster status   (on a database node)"
fi

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
  echo "version    : $(bundle_version)"
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
    echo "TARANAC_CLUSTER_ID  : $([ -n "$(getenv TARANAC_CLUSTER_ID)" ] && echo set || echo 'ABSENT — its etcd bootstraps with a token of its own')  (.env: ${ENV_FILE})"
  else
    echo "cluster-fingerprint : ${CLUSTER_FP}"
    echo "  ^ Compare this ONE string across every DATABASE node's bundle. Identical on"
    echo "    all of them means every cluster-wide secret agrees. If it differs, the"
    echo "    per-key block in config.txt names the value that drifted."
  fi
  if [ -n "${CRL_FP}" ]; then
    echo "crl-fingerprint     : ${CRL_FP}  (${CRL_COUNT} CRL file(s) in the EAP-TLS CRL directory)"
    echo "  ^ Compare across every DATABASE node too. Different means the nodes enforce"
    echo "    different CRLs — crl.txt names the file. Within one CRL download interval"
    echo "    of a new CRL that can be a deploy in flight: collect again before concluding."
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
      crl.txt)               echo "  ${item}           — EAP-TLS CRLs on this node: number + DER sha256 per file (compare across nodes)" ;;
      crl-inventory.tsv)     echo "  ${item} — the CRL directory as data: what crl.txt is computed from" ;;
      clock-skew.txt)        echo "  ${item}    — measured clock difference against each reachable peer" ;;
      etcd-members.json)     echo "  ${item} — the ring as data: what every etcd verdict is computed from" ;;
      signatures.txt)        echo "  ${item}    — lines in this node's container logs that name a known cause (read up to T0)" ;;
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
