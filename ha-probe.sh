#!/usr/bin/env bash
# =============================================================================
# ha-probe.sh — "can THIS host reach THAT port, the way the product will?" asked
# by DOING it, from the network the product's containers use. Sourced by
# cluster-wizard.sh, ha-convert.sh, ha-join.sh, witness-join.sh, cluster-remove.sh and
# diagnose-ha.sh; never run on its own.
#
# WHY A CHECK IS AN ACTION HERE
# -----------------------------
# Every reachability failure seen in the field was invisible to a check that
# READ something instead of trying it:
#   · a replica's clone looped on `password authentication failed for user
#     "replicator"` AFTER its database had been discarded — the role's password on
#     the primary was not the one in .env, and nothing had ever logged in with it;
#   · a host firewall that admitted the LAN and nothing else dropped the Docker
#     network's own traffic to this host's LAN address (the "hairpin"): the api
#     and Patroni dial ETCD_HOSTS — this node's own NODE_ADDRESS:2379 among them —
#     from that network, and a probe from the host itself would have passed; the
#     same for NODE_ADDRESS:8008, where Patroni asks itself for its state during a
#     switchover to this node (ha_probe_self_cure);
#   · add-node's "can reach N" was a CIDR comparison: no packet ever left.
# So each function here starts a throwaway container on `taranac_default` (the
# network the api and the database are on) and performs the real operation: a
# psql login, a TCP connect, an HTTP GET, an etcd health call.
#
# THE CONTRACT
# ------------
# Every probe sets two variables and returns 0 only when the answer is "ok":
#   PROBE_CLASS   ok | refused | timeout | filtered | auth | hba | nologin | other
#   PROBE_DETAIL  what the tool said, verbatim — printed with every refusal, so
#                 an "other" is never a guess dressed up as a diagnosis
# ha_probe_cure turns a class into ONE line of cure (plus the auth/hba recipes).
# Nothing here decides what a failure MEANS for the caller — that is the
# caller's call (a refusal, a warning, a note).
#
# The probe image is postgres:16-alpine — the standalone database image, present
# on every node by construction and in the appliance's preloaded set; busybox is
# not (see ha-join.sh's PROBE_IMAGE). It carries psql, busybox nc and wget.
# The etcd probe runs in the image the local taranac-etcd runs.
#
# Passwords travel ONLY in the environment: `PGPASSWORD=… docker run -e PGPASSWORD`
# names the variable on the command line and never its value, so it is in no
# argv, no `ps` listing and no shell history. It IS in the probe container's
# environment, so `docker inspect` shows it for that container's ~5 s of life —
# to someone who can run docker on this host, i.e. root here already.
# =============================================================================

HA_PROBE_IMAGE="${HA_PROBE_IMAGE:-postgres:16-alpine}"
HA_PROBE_TIMEOUT=5            # seconds — every probe, every protocol
HA_PROBE_NET=""               # resolved once, by ha_probe_network
HA_PROBE_NET_WARNED=""
HA_PROBE_LISTENER="taranac-probe-listener"
PROBE_CLASS=""; PROBE_DETAIL=""

# The network the product's containers dial from. On a node that has run its
# stack it is `taranac_default` (docker-compose.yml, project `taranac`). On a
# host where it does not exist (a stack that was taken `down`, a bare witness)
# the default bridge is the nearest thing — and it is NOT the same thing: a
# firewall rule written for one subnet passes or drops the other. Said loudly,
# once, so a pass from the wrong network is never mistaken for the real answer.
ha_probe_network() {
  ha_probe_v4only
  [ -n "$HA_PROBE_NET" ] && return 0
  if docker network inspect taranac_default >/dev/null 2>&1; then
    HA_PROBE_NET=taranac_default
  else
    HA_PROBE_NET=bridge
    if [ -z "$HA_PROBE_NET_WARNED" ]; then
      HA_PROBE_NET_WARNED=1
      printf '%s\n' \
        "ha-probe: ⚠ the Docker network 'taranac_default' does not exist on this host — probing" \
        "ha-probe:   from Docker's default bridge instead. That is NOT the network this node's" \
        "ha-probe:   api and database use: a firewall that treats the two subnets differently" \
        "ha-probe:   passes here and fails later. Start the stack (./taranac up -d) for the real answer." >&2
    fi
  fi
}

# The addresses a Docker network (taranac_default unless named) hands out, for a cure
# that has to name them: its ip_range when it has one (the source of every container
# that dials this node's own address, docker-compose.yml), else its subnet. IPv4
# ONLY, and one: the network also carries an IPv6 subnet for the client-facing
# services, but every container that dials this node's own address is kept off IPv6,
# so the source a host firewall sees is IPv4 — and a cure printing both would be a
# `ufw allow … from <v4> <v6> …` that ufw rejects. Empty when the network does not
# exist — the caller then says "the Docker network".
ha_probe_docker_subnet() {  # [network]
  docker network inspect "${1:-taranac_default}" \
    -f '{{range .IPAM.Config}}{{if .IPRange}}{{.IPRange}}{{else}}{{.Subnet}}{{end}} {{end}}' 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if (index($i, ":") == 0) { print $i; exit } }' || true
}

# Every probe container is kept off IPv6, like every stack container that is not
# client-facing (docker-compose.yml, x-ipv4-only): on the IPv6-carrying stack network
# it would otherwise get an IPv6 address, resolve names to AAAA first and publish the
# listener's port over IPv6 DNAT — a probe that does not take the path the api and
# Patroni take. Only where the kernel has IPv6: without it the sysctl does not exist
# and docker would refuse the container (a witness host may run such a kernel).
HA_PROBE_V4ONLY=()
ha_probe_v4only() {
  HA_PROBE_V4ONLY=()
  [ -e "${TARANAC_HOST_ROOT:-}/proc/net/if_inet6" ] && HA_PROBE_V4ONLY=(--sysctl net.ipv6.conf.all.disable_ipv6=1)
  return 0
}

# Text → class. Matched case-insensitively, most specific first: etcdctl wraps a
# refusal inside "context deadline exceeded", so "refused" must win over
# "timeout". Every phrase below is quoted from a captured run
# (tests/fixtures/ha-probe/): psql, busybox nc/wget and etcdctl word the same
# kernel error differently ("Network unreachable" vs "Network is unreachable").
ha_probe_classify() {  # <text>
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *"password authentication failed"*)                 PROBE_CLASS=auth ;;
    *"pg_hba.conf"*)                                    PROBE_CLASS=hba ;;
    *"is not permitted to log in"*)                     PROBE_CLASS=nologin ;;
    *"connection refused"*)                             PROBE_CLASS=refused ;;
    *"no route to host"*|*"host is unreachable"*|*"network is unreachable"*|*"network unreachable"*)
                                                        PROBE_CLASS=filtered ;;
    *"timeout expired"*|*"timed out"*|*"deadline exceeded"*)
                                                        PROBE_CLASS=timeout ;;
    *)                                                  PROBE_CLASS=other ;;
  esac
}
# Docker could not attach the probe container at all because the network has no
# address left in its pool. Until 1.3.3 that pool was the whole /28 and the full HA
# stack filled it; docker-compose.yml now gives the containers that never dial this
# node's own address fixed ones outside it, but an older network or extra containers
# attached to it can still fill it. Class `other` — nothing was learned about
# the target — but with its own cure (ha_probe_cure), never "read the words above".
ha_probe_network_full() {  # <text> → 0 when docker's words say the network is full
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"no available ipv4 addresses"*|*"no available addresses"*|*"available, non-overlapping ipv4 address pool"*) return 0 ;;
  esac
  return 1
}

# ── psql: an ORDINARY login as replicator ────────────────────────────────────
# Not a replication connection: an ordinary login checks the password, LOGIN and
# — by asking the server — REPLICATION, and it does so whether or not the
# `host replication replicator …` hba line covers us. Patroni renders
# `host all all <cidr>` beside every replication line (postgres-ha/entrypoint.sh),
# so the same PG_ALLOW_CIDR scope admits both. The password comes from
# HA_PROBE_PASSWORD (a shell variable the caller sets; never exported by us).
ha_probe_login() {  # <host> <port>
  local host="$1" port="$2" out rc=0
  ha_probe_network
  out="$(PGPASSWORD="${HA_PROBE_PASSWORD:-}" docker run --rm --network "$HA_PROBE_NET" ${HA_PROBE_V4ONLY[@]+"${HA_PROBE_V4ONLY[@]}"} \
           -e PGPASSWORD -e PGCONNECT_TIMEOUT="$HA_PROBE_TIMEOUT" "$HA_PROBE_IMAGE" \
           psql "host=${host} port=${port} user=replicator dbname=postgres" -tAqc \
           "SELECT rolreplication FROM pg_roles WHERE rolname = current_user" </dev/null 2>&1)" || rc=$?
  PROBE_DETAIL="$out"
  if [ "$rc" -eq 0 ]; then
    case "$(printf '%s' "$out" | tr -d '[:space:]')" in
      t) PROBE_CLASS=ok; return 0 ;;
      f) PROBE_CLASS=nologin
         PROBE_DETAIL="logged in as replicator, but the role lacks REPLICATION"
         return 1 ;;
    esac
  fi
  ha_probe_classify "$out"
  [ "$PROBE_CLASS" = ok ] && PROBE_CLASS=other   # never ok from text alone
  return 1
}

# ── TCP: busybox nc ──────────────────────────────────────────────────────────
# busybox nc exits 1 for EVERY failure and prints NOTHING for a refused
# connection (captured: tests/fixtures/ha-probe/nc-refused.*), so its exit code
# says nothing and its silence says something. Success is the word "open" that
# -v prints; the elapsed time is measured INSIDE the container, so the
# container's own start-up is not mistaken for a slow answer.
ha_probe_tcp() {  # <host> <port>
  local host="$1" port="$2" out body el
  ha_probe_network
  out="$(docker run --rm --network "$HA_PROBE_NET" ${HA_PROBE_V4ONLY[@]+"${HA_PROBE_V4ONLY[@]}"} "$HA_PROBE_IMAGE" sh -c \
           's=$(date +%s); nc -v -w "$2" "$0" "$1" </dev/null 2>&1; echo "elapsed=$(( $(date +%s) - s ))"' \
           "$host" "$port" "$HA_PROBE_TIMEOUT" </dev/null 2>&1)" || true
  ha_probe_tcp_judge "$out"
}
ha_probe_tcp_judge() {  # <what the container printed> — split out so the fixtures can be judged
  local out="$1" body el
  el="$(printf '%s\n' "$out" | sed -n 's/^elapsed=\([0-9][0-9]*\)$/\1/p' | tail -1)"
  body="$(printf '%s\n' "$out" | grep -v '^elapsed=' || true)"
  PROBE_DETAIL="$body"
  case "$body" in *" open"*) PROBE_CLASS=ok; return 0 ;; esac
  ha_probe_classify "$body"
  if [ "$PROBE_CLASS" = other ] && [ -n "$el" ]; then
    if [ "$el" -ge "$HA_PROBE_TIMEOUT" ]; then
      PROBE_CLASS=timeout; PROBE_DETAIL="no answer within ${HA_PROBE_TIMEOUT}s"
    elif [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
      PROBE_CLASS=refused; PROBE_DETAIL="connection refused (immediately, after ${el}s)"
    fi
  fi
  return 1
}

# ── HTTP: busybox wget; the body goes to stdout on success ───────────────────
ha_probe_http() {  # <host> <port> <path>
  local host="$1" port="$2" path="$3" body rc=0 errf
  ha_probe_network
  errf="$(mktemp)"
  body="$(docker run --rm --network "$HA_PROBE_NET" ${HA_PROBE_V4ONLY[@]+"${HA_PROBE_V4ONLY[@]}"} "$HA_PROBE_IMAGE" \
            wget -qO- -T "$HA_PROBE_TIMEOUT" "http://${host}:${port}${path}" </dev/null 2>"$errf")" || rc=$?
  PROBE_DETAIL="$(cat "$errf")"; rm -f "$errf"
  if [ "$rc" -eq 0 ] && [ -n "$body" ]; then
    PROBE_CLASS=ok; printf '%s\n' "$body"; return 0
  fi
  ha_probe_classify "$PROBE_DETAIL"
  [ "$PROBE_CLASS" = ok ] && PROBE_CLASS=other
  return 1
}

# ── etcd: `etcdctl endpoint health` against ONE client URL ───────────────────
# Run as the image's own command (it has no shell), in the image the local
# taranac-etcd runs, so the client is the one Patroni's etcd speaks to. The CA,
# when given, is mounted read-only the way diagnose-ha.sh does it.
ha_probe_etcd() {  # <url> [cafile]
  local url="$1" ca="${2:-}" image out rc=0
  local -a mount=() tls=()
  ha_probe_network
  image="$(docker inspect -f '{{.Config.Image}}' taranac-etcd 2>/dev/null || true)"
  [ -n "$image" ] || image="quay.io/coreos/etcd:v3.5.17"
  if [ -n "$ca" ]; then
    mount=(-v "$(cd "$(dirname "$ca")" && pwd)/$(basename "$ca"):/probe-ca.crt:ro")
    tls=(--cacert=/probe-ca.crt)
  fi
  out="$(docker run --rm --network "$HA_PROBE_NET" ${HA_PROBE_V4ONLY[@]+"${HA_PROBE_V4ONLY[@]}"} "${mount[@]+"${mount[@]}"}" "$image" \
           etcdctl endpoint health --dial-timeout="${HA_PROBE_TIMEOUT}s" \
           --command-timeout="${HA_PROBE_TIMEOUT}s" --endpoints="$url" \
           "${tls[@]+"${tls[@]}"}" </dev/null 2>&1)" || rc=$?
  PROBE_DETAIL="$out"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'is healthy'; then
    PROBE_CLASS=ok; return 0
  fi
  ha_probe_classify "$out"
  [ "$PROBE_CLASS" = ok ] && PROBE_CLASS=other
  return 1
}

# ── A listener on this host's port, for the hairpin probe ────────────────────
# Before this node's own etcd exists, nothing answers on its 2379 — so a probe of
# NODE_ADDRESS:2379 from the Docker network would fail whatever the firewall
# says. A throwaway container publishes the port the way the overlay will
# (`-p 2379:2379`) and accepts every connection (busybox nc: -lk needs -e).
# Returns 0 started · 2 the host port is already taken · 1 any other failure,
# with docker's words in PROBE_DETAIL. Always pair with ha_probe_listen_stop.
# 🔑 On the PROBE's network, where the overlay's etcd will sit. Docker DNATs a
# published port only for traffic NOT arriving on the container's own bridge
# (`! -i br-…`): a listener on the default bridge would be reached from
# taranac_default through FORWARD and pass whatever the host firewall's INPUT
# says — a false pass. On taranac_default, as etcd, the probe's packet goes
# through INPUT to the published port, exactly as Patroni's and the api's will.
ha_probe_listen_start() {  # <host port>
  local port="$1" out rc=0
  ha_probe_network
  docker rm -f "$HA_PROBE_LISTENER" >/dev/null 2>&1 || true
  out="$(docker run -d --rm --name "$HA_PROBE_LISTENER" --network "$HA_PROBE_NET" ${HA_PROBE_V4ONLY[@]+"${HA_PROBE_V4ONLY[@]}"} \
           -p "${port}:${port}" "$HA_PROBE_IMAGE" \
           nc -lk -p "$port" -e true </dev/null 2>&1)" || rc=$?
  PROBE_DETAIL="$out"
  [ "$rc" -eq 0 ] && return 0
  case "$out" in *"already allocated"*|*"address already in use"*) return 2 ;; esac
  return 1
}
ha_probe_listen_stop() { docker rm -f "$HA_PROBE_LISTENER" >/dev/null 2>&1 || true; }

# ── The one host-firewall rule HA needs beyond the LAN ───────────────────────
# Two things on a node dial its OWN LAN address from the Docker network: the api
# and Patroni → ETCD_HOSTS (own NODE_ADDRESS:2379 among them), and Patroni → its
# own api_url (NODE_ADDRESS:8008) — a switchover asks every candidate's Patroni
# for its state at api_url, this node included, and api_url is what the peers use,
# so it cannot point anywhere else. A host firewall that admits only the LAN drops
# both. ONE rule cures both, so ONE line says it, wherever it is printed: a cure
# naming one port is the next refusal waiting on the other (1.3.3-rc3, live: the
# rule for 2379 was in, and `cluster switchover --to <this node>` was refused).
HA_SELF_PORTS="2379 8008"
ha_probe_self_cure() {  # <this node's address> [docker subnet]
  local a="$1" s="${2:-}"
  [ -n "$s" ] || s="the taranac_default subnet (docker network inspect taranac_default)"
  echo "the host firewall drops the Docker network's traffic to this node's own address: admit ${s} to ${a} on tcp/2379 and tcp/8008 — with ufw:  sudo ufw allow proto tcp from ${2:-<that subnet>} to ${a} port 2379,8008"
}

# ── The cure, one class at a time ────────────────────────────────────────────
# <src> is the address the TARGET sees the probe arrive from: this node's address
# for a remote target, the Docker subnet for this host's own address. Printed
# lines carry no prefix; the caller indents them.
ha_probe_cure() {  # <host> <port> <src>
  local h="$1" p="$2" src="$3"
  case "$PROBE_CLASS" in
    refused)  echo "nothing listens on ${h}:${p}, or a firewall REJECTs: admit ${src} to tcp/${p} on ${h}" ;;
    timeout)  echo "${h}:${p} did not answer in ${HA_PROBE_TIMEOUT}s: a firewall DROPs ${src}, or there is no route — admit ${src} to tcp/${p} on ${h}" ;;
    filtered) echo "a firewall REJECTs ${src} with host-unreachable, or there is no route to ${h}: admit ${src} to tcp/${p} on ${h}" ;;
    auth)     echo "${h} refused replicator's password — the role's password is not POSTGRES_REPLICATION_PASSWORD:" ;;
    hba)      echo "${h}'s PG_ALLOW_CIDR does not cover ${src}. Widen it on that node and restart ONLY its database there" \
                   "(on the leader, hand leadership away first — restarting its database is a failover):"
              ha_probe_hba_widen "$h" "$src" ;;
    nologin)  echo "${h}'s replicator role cannot replicate — on the node holding the database:"
              echo "  docker exec -it taranac-db psql -U taranac -c 'ALTER ROLE replicator REPLICATION LOGIN'" ;;
    *)        if ha_probe_network_full "$PROBE_DETAIL"; then
                echo "the probe could not attach to ${HA_PROBE_NET:-taranac_default} because that network has no free address —" \
                     "stop any extra containers attached to it (docker network inspect ${HA_PROBE_NET:-taranac_default}), then retry"
              else
                echo "unrecognised answer from ${h}:${p} — read the tool's own words above"
              fi ;;
  esac
}

# PG_ALLOW_CIDR widened by <src> — with the value, never a placeholder: a cure that
# says "<its value>" is a sentence for the operator to complete, and a typo in it is
# a database that admits nobody. On THIS node the value is read from .env here; on a
# peer it cannot be, so the line that prints it there comes first. A bare address
# becomes a /32; a subnet (the Docker network's) is taken as it is.
ha_probe_hba_widen() {  # <host> <src>
  local h="$1" src="$2" add cur self=""
  case "$src" in
    */*|*" "*) add="$src" ;;
    *) add="${src}/32" ;;
  esac
  case "$h" in
    postgres|taranac-db|127.0.0.1|localhost) self=1 ;;
    *) [ -n "${NODE_ADDRESS:-}" ] && [ "$h" = "${NODE_ADDRESS}" ] && self=1 ;;
  esac
  if [ -n "$self" ]; then
    cur=""
    declare -F getenv >/dev/null 2>&1 && cur="$(getenv PG_ALLOW_CIDR)"
    echo "  PG_ALLOW_CIDR=${cur:+${cur},}${add}   in .env on this node"
    echo "  ./taranac up -d --no-deps postgres"
  else
    echo "  on ${h}:  grep '^PG_ALLOW_CIDR=' .env"
    echo "  append ,${add} to the line it prints (PG_ALLOW_CIDR=…,${add}) in that .env, then on ${h}:"
    echo "  ./taranac up -d --no-deps postgres"
  fi
}

# The replicator password cure — ONE text, wherever it is printed. No password on
# any command line: `\password` prompts for it. Asked of this host's own database
# when it is the one that holds the role (<on> empty); for another machine both
# lines are printed, and the first one simply says "already exists" if it does.
ha_probe_auth_cure() {  # [on — the machine to run it on; empty = this one]
  local on="${1:-}" exists=""
  if [ -z "$on" ]; then
    exists="$(docker exec taranac-db psql -U taranac -tAc \
                "select rolreplication from pg_roles where rolname='replicator'" 2>/dev/null \
              | tr -d '[:space:]' || true)"
    on="this node"
  fi
  echo "on ${on}:"
  if [ "$exists" != t ] && [ "$exists" != f ]; then
    echo "  docker exec -it taranac-db psql -U taranac -c 'CREATE ROLE replicator REPLICATION LOGIN'"
  fi
  echo "  docker exec -it taranac-db psql -U taranac -c '\\password replicator'"
  echo "and enter the value of POSTGRES_REPLICATION_PASSWORD from .env (the node that runs the cluster commands)."
}

# =============================================================================
# passive: what a container's log already says
# =============================================================================
# Every fault the 1.3.2 field bundles carried was NAMED in a log the bundle had
# collected — etcd's `cluster ID mismatch`, the primary's `Role "replicator" does
# not exist.`, the api's start-up TimeoutError — and nothing read them: the verdict
# was computed from state alone and sent the operator elsewhere. So the lines that
# name a cause are a table, and each row is a LITERAL match on ONE line mapped to
# ONE finding. No regex, no counting across lines, no inference: a row with two
# literals matches only a line that carries BOTH. The table's order is the
# precedence — a line is claimed by the first row it matches, and the first live
# row is the one a caller acts on.
#
#   ID|kind|literal[|literal2]      kind = the container: etcd | db | api
#
# Every literal is quoted from a captured line (tests/fixtures/diagnose-ha/):
#   · ETCD-*  etcd 3.5.17's own words; the last five are the config refusals
#             witness-join.sh used to grep for (this table replaced that grep).
#   · NO-ROLE  the SERVER's DETAIL line under its "password authentication
#             failed" when the role is missing — which client asked is not on it.
#   · CLONE-AUTH  the CLIENT side (pg_basebackup in this node's Patroni) — note
#             the two spaces after FATAL:, and "failed: " which the server never
#             prints. It precedes REPL-PASSWORD because its line CONTAINS that
#             row's literal: the first row a line matches claims it.
#   · REPL-PASSWORD  the SERVER's own FATAL line. Under SCRAM (every Taranac node)
#             PostgreSQL 16 writes no "Password does not match" DETAIL — that is
#             md5's wording — only this FATAL and the hba line it matched. A
#             missing role writes the same FATAL, so NO-ROLE sits above it.
#   · NOLOGIN / NO-REPLICATION  PostgreSQL 16's refusals of a role without LOGIN
#             or without REPLICATION. All five db rows are captured from
#             postgres:16-alpine 16.15 (db-server-refusals.txt says how).
#   No HBA row: Patroni's own start-up on an adopted data directory writes
#   `no pg_hba.conf entry for replication connection from host "127.0.0.1"` a few
#   times before its hba is rendered, so the line is noise exactly when a node is
#   being converted. Whether PG_ALLOW_CIDR covers a peer is asked by DOING it — the
#   login probe's `hba` class (ha_probe_login), which carries its own cure.
#   · API-DB-TIMEOUT  a line of our own: the api's start-up writes it when it cannot
#             open a database connection — timed out, refused, or a database still
#             starting (backend app/main.py, NO_DATABASE_LOG, pinned by
#             backend/tests/test_startup_no_database_log.py). In 1.3.2 the only
#             trace was the last line of a traceback, a bare `TimeoutError`, inside
#             a uvicorn record whose shape is uvicorn's — not a thing to match.
ha_sig_rows() {
  cat <<'ROWS'
ETCD-ID|etcd|cluster ID mismatch
ETCD-COUNT|etcd|member count is unequal
ETCD-PEERURL|etcd|error validating peerURLs
ETCD-PEM|etcd|failed to find any PEM data
ETCD-TLS|etcd|tls: 
ETCD-INVALID|etcd|invalid value
NO-ROLE|db|Role "replicator" does not exist.
CLONE-AUTH|db|failed: FATAL:  password authentication failed for user "replicator"
REPL-PASSWORD|db|FATAL:  password authentication failed for user "replicator"
NOLOGIN|db|role "replicator" is not permitted to log in
NO-REPLICATION|db|permission denied to start WAL sender
API-DB-TIMEOUT|api|startup: no database connection (
ROWS
}

# <logfile> <kind> → one line per row that matched, in TABLE order:
#   ID<TAB>count<TAB>first<TAB>last<TAB>sample
# first/last are the line's `docker logs --timestamps` prefix (RFC 3339, UTC) or
# "-" when the line has none; the sample is the LAST matching line without that
# prefix, tabs flattened, cut at 2000 characters. awk's index() is a fixed-string
# search — the same thing grep -F does — and the literals are read from the table
# as data, never through -v (which would turn a backslash in a literal into an escape).
ha_sig_scan() {
  local log="$1" kind="$2"
  [ -r "$log" ] || return 0
  ha_sig_rows | awk -F'|' -v kind="$kind" '
    NR == FNR { if ($2 == kind) { n++; id[n] = $1; a[n] = $3; b[n] = $4 } ; next }
    {
      for (i = 1; i <= n; i++) {
        if (index($0, a[i]) == 0) continue
        if (b[i] != "" && index($0, b[i]) == 0) continue
        ts = "-"; line = $0
        if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]*Z /) {
          sp = index($0, " "); ts = substr($0, 1, sp - 1); line = substr($0, sp + 1)
        }
        if (!(i in cnt)) first[i] = ts
        cnt[i]++; last[i] = ts
        gsub(/\t/, " ", line); sample[i] = substr(line, 1, 2000)
        break
      }
    }
    END { for (i = 1; i <= n; i++) if (i in cnt) printf "%s\t%d\t%s\t%s\t%s\n", id[i], cnt[i], first[i], last[i], sample[i] }
  ' - "$log"
}

# The witness's etcd, wiped and joined again — ONE text wherever it is printed.
# The volume holds nothing but this member's Raft state for a ring it no longer
# belongs to; the join command re-creates it (witness-join.sh), on the leader.
ha_sig_witness_wipe() {  # [witness address]
  echo "on the witness${1:+ (${1})}:"
  echo "  docker rm -f taranac-witness-etcd && docker volume rm taranac-witness_etcd_data"
  echo "then on the leader run the join again and paste the command it prints on the witness:"
  echo "  ./taranac cluster add-witness --address ${1:-<witness>}"
}
# A database node's etcd in the wrong ring: re-added from the leader. The join clears
# the stale etcd volume itself (HA.md §7a item 2) — no volume is removed by hand.
ha_sig_db_readd() {  # <address>
  echo "a database node is re-added from the leader (the join clears its stale etcd volume):"
  echo "  ./taranac cluster add-node --address ${1:-<address>} --reinstall"
}

# A database node that streams but is not registered — the join's last steps, ONE
# text wherever it is printed (ha-join.sh, the wizard, remove-node, diagnose).
# Registered = an active roster row AND a join token consumed for it, and the node's
# own api does both when it starts (NodeIdentityService.ensure_self consumes the
# pending, unexpired token that names this node's name AND address). So the finish
# is starting that api — `up -d` when it has no row yet (the api is not up), `restart
# api` when the api already minted its row without a token — then `update --version
# V`, which writes the version record a killed join never wrote and restarts nothing.
# A token that expired is replaced, not re-cloned around: `join-token` for the same
# name and address issues a new one (the backend lets an expired, unconsumed join be
# invited again), and the api takes it at that start. A re-clone is the last resort.
# Read from the roster's own tables: the replica's copy answers once it streams. An
# unreadable table says so in words rather than inventing a time.
ha_finish_join() {  # <name> <address> <version> <on: "this node" | where it runs> <where add-node runs>
  local n="$1" a="$2" v="$3" on="$4" prim="$5" until="" row="" node_cmd
  # Interpolated into SQL below, so only the shapes a node name and an address have.
  if printf '%s' "$n" | grep -qE '^[A-Za-z0-9._-]+$' && printf '%s' "$a" | grep -qE '^[0-9A-Fa-f.:]+$'; then
    until="$(docker exec taranac-db psql -U taranac -d taranac -tAc \
      "select coalesce(to_char(max(expires_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'none') from cluster_join_tokens where node_name = '${n}' and node_address = '${a}' and status = 'pending' and expires_at > now()" \
      2>/dev/null | tr -d '\r' | grep -E '^([0-9]{4}-[0-9]{2}-[0-9]{2} |none$)' | head -1 || true)"
    row="$(docker exec taranac-db psql -U taranac -d taranac -tAc \
      "select exists (select 1 from cluster_nodes where name = '${n}' and status = 'active')" \
      2>/dev/null | tr -d '[:space:]' || true)"
  fi
  node_cmd="./taranac up -d"
  [ "${row}" = t ] && node_cmd="./taranac restart api"
  if [ "${until}" = none ]; then
    echo "its join token is no longer pending (expired or revoked) — issue a new one for the same name and address, ${prim}:"
    echo "  ./taranac cluster join-token --name ${n} --address ${a}"
    echo "then on ${on} (its api takes the new token when it starts):"
    echo "  ${node_cmd}"
    echo "  ./taranac update --version ${v}"
    echo "only if that does not register it, re-clone it — ${prim}:"
    echo "  ./taranac cluster add-node --address ${a} --reinstall"
    return 0
  fi
  echo "finish the join — on ${on}, before its join token expires (${until:-an hour after the add command was run, unless --ttl-minutes said otherwise}):"
  echo "  ${node_cmd}"
  echo "  ./taranac update --version ${v}"
  echo "(the api registers it with that token when it starts; update --version writes its version record and restarts nothing)"
  echo "once the token has expired — a new one for the same name and address, ${prim}, then the same two lines on ${on}:"
  echo "  ./taranac cluster join-token --name ${n} --address ${a}"
}

# <ID> [on — the machine to run it on] → what the line means, then the cure.
ha_sig_cure() {
  local id="$1" on="${2:-}"
  case "$id" in
    ETCD-ID)
      echo "this etcd and a peer belong to DIFFERENT rings — one side kept an etcd volume from an earlier attempt."
      ha_sig_witness_wipe
      ha_sig_db_readd ;;
    ETCD-COUNT)
      echo "this member was given a ring that is not the live one (the declared list of the node add-node ran on had drifted)."
      echo "on that node:  ./taranac cluster sync   then repeat the add" ;;
    ETCD-PEERURL)
      echo "the peer URL this member starts with is not the one the ring holds for its name (ETCD_INITIAL_CLUSTER vs the live member list)."
      echo "take it out of the ring and add it again — on a database node:"
      echo "  ./taranac cluster remove-node --node <name>    (remove-witness for the witness), then add it again" ;;
    ETCD-PEM)
      echo "a certificate or key under config/etcd-tls is empty or not PEM."
      echo "on that member:  ./taranac cluster renew-cert" ;;
    ETCD-TLS)
      echo "a TLS handshake between etcd members or clients failed — a certificate the other side does not trust, or http on one side and https on the other."
      echo "compare ETCD_CLIENT_SCHEME / ETCD_PEER_SCHEME and certs.txt across members, then on the member that fails:  ./taranac cluster renew-cert" ;;
    ETCD-INVALID)
      echo "etcd refused a value of its configuration — the line names it."
      echo "correct that key in .env on this host, then:  ./taranac up -d" ;;
    NO-ROLE)
      echo "a node asked this database for the replicator role, and the role does not exist here."
      ha_probe_auth_cure "$on" ;;
    REPL-PASSWORD)
      echo "a node logged in as replicator with a password this database's role does not have. The line does not say which node:"
      echo "compare POSTGRES_REPLICATION_PASSWORD in config.txt (the per-key block under cluster-fingerprint) across every database node's bundle,"
      echo "then give the role the .env value:"
      ha_probe_auth_cure "$on" ;;
    NOLOGIN|NO-REPLICATION)
      echo "the replicator role exists but may not log in or replicate (PostgreSQL 16 says \"permission denied to start WAL sender\" for a role without REPLICATION)."
      echo "on ${on:-the node holding the database}:"
      echo "  docker exec -it taranac-db psql -U taranac -c 'ALTER ROLE replicator REPLICATION LOGIN'" ;;
    CLONE-AUTH)
      echo "this node's clone (pg_basebackup) was refused by the leader: the leader's replicator password is not POSTGRES_REPLICATION_PASSWORD."
      ha_probe_auth_cure "${on:-the leader}" ;;
    API-DB-TIMEOUT)
      echo "the api could not open a database connection at start-up (DB_HOSTS, DB_CONNECT_TIMEOUT) and exited."
      echo "once a database in DB_HOSTS answers on 5432 (the db findings above say why it does not):  ./taranac up -d" ;;
    *) echo "no cure is recorded for ${id}" ;;
  esac
}

# ── The images an HA step runs: their files, not only their digests ─────────
# The 1.3.3 OVA carried an etcd image whose /usr/local/bin/etcd was 0 bytes: the
# digest matched, `docker image inspect` was content, and the first add-witness died
# on `exec format error` with a cure aimed at the witness. image-verify.py reads the
# files a container would see against the image's layers and, with --repair, removes
# a damaged copy and pulls it again (stopped containers of it included; a running one
# is named, never stopped). Only images already on this host are read: one that is
# not here is pulled fresh by the step itself.
# A third-party image as this bundle's compose files pin it (`name:tag@sha256:…` in a
# release bundle), so a repair pulls the release's build, not whatever the tag is now.
ha_pinned_ref() {  # <name:tag> <bundle dir>
  local ref
  ref="$(grep -hoE "^[[:space:]]*image:[[:space:]]*$(printf '%s' "$1" | sed 's/[.]/\\./g')@sha256:[0-9a-f]{64}" \
           "$2"/docker-compose*.yml 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*image:[[:space:]]*//')"
  printf '%s' "${ref:-$1}"
}

ha_images_here() {  # <env file> → the HA images present on this host, one per line
  local env="$1" dir prefix ver img
  dir="$(cd "$(dirname "$env")" && pwd)"
  prefix="$(sed -n 's/^IMAGE_PREFIX=//p' "$env" 2>/dev/null | tail -1 | tr -d "\"' ")"
  ver="$(sed -n 's/^TARANAC_VERSION=//p' "$env" 2>/dev/null | tail -1 | tr -d "\"' ")"
  for img in "$(ha_pinned_ref quay.io/coreos/etcd:v3.5.17 "$dir")" "$(ha_pinned_ref "$HA_PROBE_IMAGE" "$dir")" \
             ${prefix:+${ver:+"${prefix}/postgres-ha:${ver}" "${prefix}/etcd-agent:${ver}"}}; do
    docker image inspect "$img" >/dev/null 2>&1 && printf '%s\n' "$img"
  done
  return 0
}

# 0 = intact (or repaired); 1 = damaged and not repaired — image-verify.py said which,
# why and the cure on stderr; 2 = could not be read (said too, not a verdict).
ha_images_intact() {  # <image>…
  [ $# -gt 0 ] || return 0
  local verifier
  verifier="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/image-verify.py"
  if [ ! -f "$verifier" ]; then
    echo "ha-probe: ⚠ image-verify.py is missing from this bundle — the images' files were NOT checked." >&2
    return 2
  fi
  echo "ha-probe: checking the files of $# image(s) against their layers ($*) …" >&2
  python3 "$verifier" --repair "$@" >/dev/null
}
