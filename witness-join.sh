#!/usr/bin/env bash
# witness-join.sh — turn THIS host into the Taranac cluster's witness (arbiter), in
# one command (docs/ops/ha.md, docs/spec/backend/infra/cluster.md).
#
# A 2-node Taranac HA cluster cannot safely fail over on its own: a partition splits
# the two DB nodes 1-vs-1 with no majority, so neither may become the primary. The
# tiebreaker is a 3rd etcd VOTING member that runs NO Postgres — just etcd — in a
# SEPARATE failure domain. That is this machine.
#
# Until now, standing one up meant answering four questions in an installer and
# copying three TLS files here by scp. It is now the same gesture as adding a
# replica: run the command `./taranac cluster add-witness` printed on the primary.
#
#     ./witness-join.sh --broker 10.0.0.1:9443 --token <secret> --pin sha256:<fp>
#
# WHAT THIS DOES, AND WHY EACH PIECE IS HERE
#   1. Refuses to run on a machine that is a Taranac DB node. Co-locating the
#      arbiter with a node it is supposed to arbitrate is not a smaller deployment,
#      it is a broken one — losing that host loses a DB node AND the tiebreaker at
#      the same moment, which is the exact failure the witness exists to survive.
#   2. Pins the broker's certificate by fingerprint BEFORE saying anything to it,
#      and authenticates with HKDF(token,"…auth-v1") — the raw token never travels.
#   3. Takes the cluster's etcd topology from the broker instead of asking you for
#      it, so the member list, the cluster token and the peer scheme cannot drift
#      from the DB nodes' (an http witness cannot join an https ring; a witness
#      whose ETCD_NAME disagrees with its entry in the member list never forms one).
#   4. Generates its OWN etcd key here and sends only a CSR. The private key never
#      travels — this is what removes the scp.
#   5. Brings up docker-compose.witness.yml and then PROVES the result rather than
#      announcing it: either this member is live in the ring, or the console says
#      exactly what state it is in and what has to happen next.
#
# A witness holds no database, no MASTER_KEY and no application secret. It never
# calls the broker's /join/secrets endpoint, and this script writes none of the
# cluster's credentials into its .env — an arbiter that cannot decrypt anything is
# one less machine to protect.
#
# Other flags:
#   --env-file <path>   the compose env file to write (default: ./.env)
#   --print-auth        with --token: print the X-Taranac-Join-Auth value this token
#                       derives, then exit — a diagnostic for "invalid credentials".
#   --leave             this host STOPS being the witness: after
#                       `./taranac cluster remove-witness` on a database node, take
#                       the arbiter's etcd down here, with its state, and retire .env.
#                       Refused while the ring still lists this host.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
# A death under `set -e` prints where it happened, and a container compose left
# under a temporary name is renamed back before anything addresses it by name.
# Guarded: a bundle caught half-updated must still run (container-names.sh).
if [ -f "$HERE/container-names.sh" ]; then
  . "$HERE/container-names.sh"
  loud_death "witness-join.sh"
  heal_container_names
fi

COMPOSE_FILE="docker-compose.witness.yml"
ENV_FILE=".env"
TLS_DIR="${HERE}/config/etcd-tls"
ETCD_CONTAINER="taranac-witness-etcd"
ETCD_VOLUME="taranac-witness_etcd_data"     # compose project `taranac-witness` + `etcd_data`
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.17"    # same pin as docker-compose.witness.yml

BROKER=""; TOKEN=""; PIN=""; PRINT_AUTH=""; LEAVE=""; CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --broker)     BROKER="$2"; shift 2 ;;
    --token)      TOKEN="$2"; shift 2 ;;
    --pin)        PIN="$2"; shift 2 ;;
    --env-file)   ENV_FILE="$2"; shift 2 ;;
    --print-auth) PRINT_AUTH=1; shift ;;
    --leave)      LEAVE=1; shift ;;
    --confirm)    CONFIRM="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Narration ────────────────────────────────────────────────────────────────
# Same contract as ha-join.sh: every step says what it is about to do before it
# does it, asserts an observable outcome, and a failure names the step.
STEP_N=0; STEP=""
step() { STEP_N=$((STEP_N + 1)); STEP="$*"; printf 'witness-join: [%d] %s…\n' "$STEP_N" "$STEP"; }
ok()   { printf 'witness-join:     ✓ %s\n' "$*"; }
note() { printf 'witness-join:     · %s\n' "$*"; }
fail() {
  [ -n "$STEP" ] && echo "witness-join: FAILED at step [${STEP_N}] ${STEP}" >&2
  echo "witness-join: $*" >&2
  exit 1
}

# ═════════════════════════════════════════════════════════════════════════════
# The broker protocol — this machine's half
# ═════════════════════════════════════════════════════════════════════════════
# The server half is deploy/dist/cluster-broker.py; its docstring is the contract.
#
# This is deliberately a COPY of ha-join.sh's implementation rather than a shared
# library. A witness host is a bare third machine that holds nothing else of ours,
# and an installer that works only when a second file happens to be beside it is an
# installer with a failure mode. Two self-contained scripts is the cheaper trade;
# tests/test_ha_join_broker.sh checks both against the broker's own primitives so a
# divergence cannot go unnoticed.

INFO_AUTH="taranac-ha-join-auth-v1"

WORK=""
BROKER_READY=0
BROKER_SPKI=""
AUTH_B64=""
COMPLETE_SENT=0

# RFC 5869 HKDF-SHA256, empty salt — cluster-broker.py::hkdf(). stdlib only, so it
# runs on a machine whose package set we do not control. The token goes through the
# ENVIRONMENT, never argv: argv is world-readable in /proc.
hkdf_b64() {  # <token> <info-label> → base64 of the 32-byte derived key
  HKDF_TOKEN="$1" HKDF_INFO="$2" python3 - <<'PY'
import base64, hashlib, hmac, os, sys

token = os.environ["HKDF_TOKEN"].encode()
info = os.environ["HKDF_INFO"].encode()
prk = hmac.new(b"\x00" * hashlib.sha256().digest_size, token, hashlib.sha256).digest()
out, block, counter = b"", b"", 1
while len(out) < 32:
    block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
    out += block
    counter += 1
sys.stdout.write(base64.b64encode(out[:32]).decode())
PY
}

# Nothing derived from the token is transmitted until the fingerprint matches. The
# connection is then bound to that same key with curl's --pinnedpubkey rather than to
# a CA or a hostname: the operator is explicitly invited to edit the broker address
# (NAT, a different FQDN, another port), so hostname verification would reject the
# very thing the design asks for, while the fingerprint stays true.
broker_pin() {
  local host="${BROKER%:*}" port="${BROKER##*:}" got want
  local -a sni=()
  case "$host" in
    *[!0-9.]*) sni=(-servername "$host") ;;   # SNI is a DNS extension; never an IP
  esac
  openssl s_client -connect "${host}:${port}" ${sni[0]+"${sni[@]}"} </dev/null 2>/dev/null \
    | openssl x509 -outform DER > "${WORK}/broker.der" 2>/dev/null || true
  [ -s "${WORK}/broker.der" ] || fail \
    "could not read a TLS certificate from ${BROKER}.
  Is the broker still running on the primary? It is one-shot and exits when it times
  out. Re-run './taranac cluster add-witness --address <this host>' there, and check
  that this machine can reach ${BROKER} (firewall?)."

  got="$(sha256sum "${WORK}/broker.der" | cut -d' ' -f1)"
  want="$(printf '%s' "$PIN" | sed -e 's/^sha256://I' -e 's/[: ]//g' | tr 'A-Z' 'a-z')"
  if [ "$got" != "$want" ]; then
    cat >&2 <<EOF
witness-join: FAILED at step [${STEP_N}] ${STEP}
witness-join: the certificate presented by ${BROKER} does NOT match --pin.

  expected (--pin) : sha256:${want}
  presented        : sha256:${got}

  Nothing was sent — this machine has not disclosed the join token or anything
  derived from it, and nothing here was changed.

  Exactly two things cause this:
    • the address is not the machine you think it is — check --broker against the
      command the primary printed, including the port;
    • something is terminating TLS between here and there (a proxy, a load
      balancer, an inspecting firewall) and re-signing the connection.
EOF
    exit 1
  fi

  BROKER_SPKI="$(openssl x509 -inform DER -in "${WORK}/broker.der" -pubkey -noout \
                 | openssl pkey -pubin -outform DER 2>/dev/null \
                 | openssl dgst -sha256 -binary | base64 | tr -d '\n')"
  [ -n "$BROKER_SPKI" ] || fail "could not extract the broker certificate's public key (openssl too old?)."
  AUTH_B64="$(hkdf_b64 "$TOKEN" "$INFO_AUTH")"
  [ -n "$AUTH_B64" ] || fail "could not derive the join authenticator (is python3 installed?)."
  BROKER_READY=1
}

# One POST. URL, auth header and body all travel through a 0600 curl CONFIG FILE
# rather than argv, so none of them is visible in `ps` to another user on this box.
BROKER_RESP=""
broker_post() {  # <path> <json-body>
  local path="$1" body="$2" cfg="${WORK}/curl.cfg" req="${WORK}/req.json" rc=0 code
  BROKER_RESP="${WORK}/resp.json"
  printf '%s' "$body" > "$req"
  : > "$cfg"; chmod 600 "$cfg"
  {
    printf 'url = "https://%s%s"\n' "$BROKER" "$path"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "X-Taranac-Join-Auth: %s"\n' "$AUTH_B64"
    printf 'data-binary = "@%s"\n' "$req"
    printf 'output = "%s"\n' "$BROKER_RESP"
    printf 'write-out = "%%{http_code}"\n'
    printf 'pinnedpubkey = "sha256//%s"\n' "$BROKER_SPKI"
    printf 'insecure\n'          # the pin is the trust anchor, not a CA or a hostname
    printf 'silent\nshow-error\n'
    printf 'max-time = 120\n'
  } >> "$cfg"
  : > "$BROKER_RESP"
  code="$(curl -K "$cfg" 2>"${WORK}/curl.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      90|60|58|35|77) fail "the broker at ${BROKER} no longer presents the pinned certificate (curl exit ${rc}).
  A one-shot broker mints a FRESH certificate every time it starts, so this is what a
  second 'add-witness' on the primary looks like. Use the --pin from the command that
  is on the primary's console NOW.
  $(cat "${WORK}/curl.err" 2>/dev/null)" ;;
      *) fail "could not reach ${BROKER}${path} (curl exit ${rc}).
  $(cat "${WORK}/curl.err" 2>/dev/null)
  The broker is one-shot: if it timed out, run './taranac cluster add-witness' on the
  primary again — it issues a fresh token and prints a fresh command." ;;
    esac
  fi
  case "$code" in
    2??) return 0 ;;
    401) fail "the broker rejected our credentials (401).
  The token on this machine is not the one the broker was started with. Copy the
  whole command the primary printed — the token is long and easy to truncate.
  To compare without guessing: ./witness-join.sh --token <secret> --print-auth" ;;
    *)   fail "the broker answered ${code} for ${path}:
  $(json_field "$BROKER_RESP" error || true)" ;;
  esac
}

json_field() {  # <file> <key> → value on stdout, "" when absent
  JSON_FILE="$1" JSON_KEY="$2" python3 - <<'PY'
import json, os, sys

try:
    with open(os.environ["JSON_FILE"], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)
value = data.get(os.environ["JSON_KEY"]) if isinstance(data, dict) else None
sys.stdout.write("" if value is None else str(value))
PY
}

# The broker's only truthful ending is this machine reporting one. A failure is
# REPORTED, not merely exited on — otherwise the primary's console shows a timeout
# ("I do not know what happened") for something we knew about.
broker_complete() {  # <true|false> [detail]
  [ -n "$BROKER" ] && [ "$BROKER_READY" -eq 1 ] && [ "$COMPLETE_SENT" -eq 0 ] || return 0
  COMPLETE_SENT=1
  local body
  # Its bundle version travels with the report: the primary records it for the
  # cluster's update order when this witness bootstrapped a ring that could not yet
  # take the write itself.
  body="$(OKV="$1" DET="${2:-}" VER="$(head -1 "$HERE/VERSION" 2>/dev/null | tr -d '[:space:]' || true)" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"ok": os.environ["OKV"] == "true", "detail": os.environ["DET"], "version": os.environ["VER"]}))
')"
  broker_post /join/complete "$body" >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    broker_complete false "failed at step [${STEP_N}] ${STEP:-startup} (exit ${rc})" || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap on_exit EXIT

# ── --print-auth: a diagnostic, and nothing else ──────────────────────────────
if [ -n "$PRINT_AUTH" ]; then
  [ -n "$TOKEN" ] || { echo "witness-join: --print-auth needs --token <secret>." >&2; exit 2; }
  hkdf_b64 "$TOKEN" "$INFO_AUTH"; echo
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# --leave — this host stops being the witness
# ═════════════════════════════════════════════════════════════════════════════
# The other half of `./taranac cluster remove-witness`. That command takes this
# member out of the ring; it cannot reach in here and stop the etcd that runs on
# this machine, and must not be able to (no agent on a witness holds docker.sock).
# Left running, a removed etcd starts, is turned away by its former peers, exits,
# and is restarted by Docker, forever — harmless to the cluster, but the machine is
# still a witness that its operator believes retired, and the leader says so
# (cluster:departed_witness_running) until this has run.
#
# Refused while the ring still lists this host, exactly like `cluster-remove.sh
# --detach`: stopping a voting member is not leaving, it is a member down. The ring
# is asked on the DATABASE nodes' endpoints from this .env, never on this host's own
# etcd — a removed member's view of the ring is the stale one.
#
# There is nothing here to keep: a witness holds Raft membership and nothing else —
# no database, no MASTER_KEY, no application secret (see write_witness_env). So the
# compose project goes down WITH its volume (-v), the etcd key pair this host made
# for itself is deleted, and .env is renamed, not deleted: it is the record of which
# cluster this machine served, and it is what tells the updater and ./taranac that
# this host is no longer a witness.
if [ -n "$LEAVE" ]; then
  envv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
  if [ ! -f "$ENV_FILE" ]; then
    left="$(ls -1t "${ENV_FILE}".left-* 2>/dev/null | head -1 || true)"
    if [ -n "$left" ]; then
      echo "witness-join: this host already left its cluster — its .env was retired as $(basename "$left")."
      echo "witness-join: nothing to do."
      exit 0
    fi
    fail "there is no ${ENV_FILE} here, so this host is not a witness — there is nothing to leave.
  Run this in the bundle directory of the witness host (where docker-compose.witness.yml is)."
  fi
  if grep -Eq '^[[:space:]]*(MASTER_KEY|MASTER_KEY_FILE|SECRET_KEY|POSTGRES_PASSWORD)=' "$ENV_FILE"; then
    fail "this host is a Taranac DATABASE node, not the witness — --leave is only for the witness.
  To take a database node out of its cluster, on a node that stays:
    ./taranac cluster remove-node --node <this node's name>"
  fi
  W_SELF="$(envv NODE_ADDRESS)"; W_NAME="$(envv ETCD_NAME)"
  W_SCHEME="$(envv ETCD_CLIENT_SCHEME)"; W_SCHEME="${W_SCHEME:-http}"
  ETCDCTL_MOUNT=""; ETCDCTL_TLS_ARGS=""
  if [ "$W_SCHEME" = https ] && [ -s "${TLS_DIR}/ca.crt" ]; then
    ETCDCTL_MOUNT="-v ${TLS_DIR}:/tls:ro"; ETCDCTL_TLS_ARGS="--cacert=/tls/ca.crt"
  fi
  etcdctl_at() { docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$1" $ETCDCTL_TLS_ARGS --command-timeout=5s "${@:2}"; }

  step "asking the cluster's database nodes whether this host is still in the ring"
  LEAVE_EP=""; MEMBERS=""; TRIED=""
  for hp in $(envv ETCD_HOSTS | tr ',' ' '); do
    case "$hp" in "${W_SELF}:"*) continue ;; esac   # never this host's own (removed) etcd
    TRIED="${TRIED:+${TRIED}, }${hp}"
    if MEMBERS="$(etcdctl_at "${W_SCHEME}://${hp}" member list 2>/dev/null)" && [ -n "$MEMBERS" ]; then
      LEAVE_EP="${W_SCHEME}://${hp}"; break
    fi
  done
  if [ -n "$LEAVE_EP" ]; then
    if printf '%s\n' "$MEMBERS" | grep -qF "//${W_SELF}:2380"; then
      fail "this host (${W_SELF}) is STILL a voting member of the ring — leaving now would be a
  member going down, not leaving. Nothing was changed.
  On any database node of the cluster, first:
    ./taranac cluster remove-witness
  then run this again here."
    fi
    ok "the ring (asked at ${LEAVE_EP}) no longer lists ${W_SELF} — it is safe to go"
  elif [ "$CONFIRM" = NOT-A-MEMBER ]; then
    note "none of the database nodes answered (${TRIED:-no endpoint in ${ENV_FILE}}) — proceeding on your confirmation"
  else
    fail "none of the cluster's database nodes answered (${TRIED:-no endpoint in ${ENV_FILE}}), so
  whether this host is still a member of the ring cannot be checked. Nothing was changed.
  If the cluster is merely unreachable from here, fix that and run this again — leaving
  while still a member takes a vote away from the cluster.
  If you HAVE removed this witness (./taranac cluster remove-witness on a database node)
  or that cluster is gone for good, say so explicitly:
    ./witness-join.sh --leave --confirm NOT-A-MEMBER"
  fi

  step "stopping the witness etcd and deleting its state"
  command -v docker >/dev/null 2>&1 || fail "docker is not installed on this host, so there is nothing running to stop."
  [ -f "$COMPOSE_FILE" ] || fail "${COMPOSE_FILE} is missing from $(pwd) — run this in the witness bundle directory."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down -v --remove-orphans \
    || fail "docker compose could not take the witness down (above). Nothing else was changed; run this again."
  if docker inspect "$ETCD_CONTAINER" >/dev/null 2>&1; then
    fail "the container ${ETCD_CONTAINER} is still there after 'down'. Remove it and run this again:
    docker rm -f ${ETCD_CONTAINER}"
  fi
  if docker volume inspect "$ETCD_VOLUME" >/dev/null 2>&1; then
    docker volume rm "$ETCD_VOLUME" >/dev/null 2>&1 \
      || fail "the etcd volume ${ETCD_VOLUME} is still there and could not be removed. Remove it and run this again:
    docker volume rm ${ETCD_VOLUME}"
  fi
  ok "container ${ETCD_CONTAINER} and volume ${ETCD_VOLUME} removed"

  CLEANED_RECORD=""
  if [ -n "$LEAVE_EP" ] && [ -n "$W_SELF" ]; then
    # The departure record remove-witness left for the leader to watch: this host is
    # what it was waiting for. Deleting it resolves the alert in the leader's next cycle.
    if etcdctl_at "$LEAVE_EP" del "/taranac/departed/${W_SELF}" >/dev/null 2>&1; then
      CLEANED_RECORD=1
    fi
    [ -z "$W_NAME" ] || etcdctl_at "$LEAVE_EP" del "/taranac/update/members/${W_NAME}" >/dev/null 2>&1 || true
  fi

  step "retiring this host's witness identity"
  removed_tls=""
  for f in etcd-server.key etcd-server.crt ca.crt; do
    [ -e "${TLS_DIR}/${f}" ] || continue
    rm -f "${TLS_DIR}/${f}" 2>/dev/null && removed_tls="${removed_tls:+${removed_tls}, }${f}" \
      || note "could not delete ${TLS_DIR}/${f} (owned by root?) — delete it by hand: sudo rm -f ${TLS_DIR}/${f}"
  done
  LEFT="${ENV_FILE}.left-$(date -u +%Y%m%dT%H%M%SZ)"
  mv -f "$ENV_FILE" "$LEFT" || fail "could not rename ${ENV_FILE} to ${LEFT}. Rename it by hand: mv ${ENV_FILE} ${LEFT}"
  ok "${ENV_FILE} retired as $(basename "$LEFT")"

  # One sentence either way. (It used to be ${x:+…}${x:-…}, and with x set the
  # second half expanded to x itself: "…in config/etcd-tlsetcd-server.key, …".)
  if [ -n "$removed_tls" ]; then
    tls_line="its own etcd certificate and key in config/etcd-tls (${removed_tls})"
  else
    tls_line="no etcd certificate was left in config/etcd-tls"
  fi
  cat <<EOF

witness-join: this host is no longer the cluster's witness. Cleaned up:
  · the witness etcd container (${ETCD_CONTAINER}) and its state (${ETCD_VOLUME})
  · ${tls_line}
  · ${ENV_FILE} → $(basename "$LEFT")  (kept as the record of which cluster it served)
EOF
  if [ -n "$CLEANED_RECORD" ]; then
    echo "  · the cluster's departure record for ${W_SELF} — its alert clears within a minute"
  else
    echo "  · the cluster's departure record could not be reached from here, so the leader"
    echo "    keeps reporting ${W_SELF}. Clear it on any database node:"
    echo "        ./taranac cluster remove-witness --forget ${W_SELF}"
  fi
  cat <<EOF

  Nothing of the cluster's is left here: a witness never held its data or keys.
  This machine can be reused or switched off.
EOF
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# The witness's .env — written WHOLE, and complete by construction
# ═════════════════════════════════════════════════════════════════════════════
# docker-compose.witness.yml interpolates twelve variables. Several have a
# `${VAR:-http}`-style fallback, and every one of those fallbacks is the PLAINTEXT
# value — inert on purpose, for a deliberate `ha-convert --plaintext` cluster. On a
# secure-by-default cluster (which is every cluster the wizard builds) a variable
# that is merely *absent* therefore does not fail: it quietly produces a plaintext
# witness that can never join an https ring, and the operator is left staring at a
# healthy-looking container that nobody will talk to.
#
# So this function writes ALL TWELVE explicitly — including the ones with defaults,
# and including the ones whose right value is the empty string. Nothing here is left
# to a fallback, and tests/test_ha_join_broker.sh asserts that the generated file
# still covers every variable the compose file names.
#
# It also writes NONE of the cluster's credentials. The broker serves them (the same
# response feeds a replica), but a witness has no use for POSTGRES_PASSWORD,
# SECRET_KEY or the master key, and persisting them here would make a machine that
# is supposed to be cheap to lose expensive to lose.
W_CLUSTER_NAME=""; W_CLUSTER_ID=""; W_NODE_ADDRESS=""; W_ETCD_NAME=""; W_INITIAL_CLUSTER=""
W_CLUSTER_STATE="new"; W_PEER_SCHEME="https"; W_PEER_AUTO_TLS="true"; W_CLIENT_SCHEME="https"
W_ETCD_HOSTS=""

write_witness_env() {
  local certfile="" keyfile="" cacert="" W_VERSION=""
  W_VERSION="$(head -1 "${HERE}/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [ "$W_CLIENT_SCHEME" = https ]; then
    # Paths INSIDE the container: ./config/etcd-tls is RO-mounted at /etc/etcd/tls.
    certfile="/etc/etcd/tls/etcd-server.crt"
    keyfile="/etc/etcd/tls/etcd-server.key"
    # The compose file reads ETCD_CLIENT_CACERT (→ ETCDCTL_CACERT), NOT
    # ETCD_TRUSTED_CA_FILE. Writing the wrong name leaves the healthcheck's etcdctl
    # with no CA under client-TLS, so the container stays 'unhealthy' forever while
    # etcd itself is perfectly fine — a red herring that costs an afternoon.
    cacert="/etc/etcd/tls/ca.crt"
  fi
  cat > "$ENV_FILE" <<EOF
# =============================================================================
# Taranac HA witness — written by witness-join.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
#
# This host is an etcd ARBITER: a voting member with no Postgres and no Taranac
# application services. It exists so a 2-node cluster keeps a majority when one DB
# node is lost, so it MUST stay in a separate failure domain from both of them.
#
# Machine-written. To re-point this witness at a different cluster, run
# ./witness-join.sh again with a fresh command from the primary rather than editing
# here — the member list, the cluster token and the peer scheme have to agree with
# every other member exactly, and this file is generated from theirs.
#
#   docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} ps
#   docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f etcd
#
# ⚠️  Firewall 2379/2380 to the cluster's private interconnect. TLS is not a
#     substitute for a firewall (ha.md §7/§8).
# =============================================================================

# Not read by ${COMPOSE_FILE} — read by the bundle's own tools. It is what tells
# ./taranac and ./taranac update that THIS host is an arbiter, so they drive the
# witness stack instead of the product's: without it, a routine './taranac update'
# ran the product's update here (pull + up -d on docker-compose.yml) and tried to
# start the whole application on the node whose job is to be cheap to lose.
TARANAC_ROLE=witness

# The Taranac release this witness's bundle is on. Not read by ${COMPOSE_FILE} (its
# etcd image is pinned there) — read by ./taranac update, which rewrites this one
# line when the witness is updated, so that a re-run is recognised as nothing to do
# and the cluster's update table can say what the arbiter runs.
TARANAC_VERSION=${W_VERSION}

# Patroni scope — IDENTICAL on every member.
TARANAC_CLUSTER_NAME=${W_CLUSTER_NAME}

# The etcd cluster token — IDENTICAL on every member, and NOT the cluster's name.
# etcd derives the ring's ClusterID from it, which is what keeps a rebuilt cluster
# distinct from the one it replaced. Empty here means the primary predates the key;
# the compose file then falls back to TARANAC_CLUSTER_NAME, as that cluster does.
TARANAC_CLUSTER_ID=${W_CLUSTER_ID}

# This host's routable address, as the DB nodes reach it. It is what this member
# advertises for both Raft (2380) and clients (2379), so it can never be 127.0.0.1.
NODE_ADDRESS=${W_NODE_ADDRESS}

# This member's etcd name. It MUST match this member's key in ETCD_INITIAL_CLUSTER
# below; etcd matches members by name, and a silent 'witness' default that disagrees
# with the list produces a member that starts and never joins.
ETCD_NAME=${W_ETCD_NAME}

# Every etcd member of the cluster, this one included, with the scheme the rest of
# the ring advertises.
ETCD_INITIAL_CLUSTER=${W_INITIAL_CLUSTER}
# 'new' = this member helps bootstrap a ring that does not exist yet;
# 'existing' = the ring is already running and this member was added to it.
ETCD_INITIAL_CLUSTER_STATE=${W_CLUSTER_STATE}

# ── Peer channel (2380, cross-host Raft) ─────────────────────────────────────
# auto-TLS: this member self-signs its own peer certificate at boot, so the
# interconnect is encrypted with zero certificate management. The scheme must match
# the member URLs above and be consistent across the WHOLE ring.
ETCD_PEER_SCHEME=${W_PEER_SCHEME}
ETCD_PEER_AUTO_TLS=${W_PEER_AUTO_TLS}

# ── Client channel (2379, Patroni ↔ etcd and every etcdctl) ──────────────────
# One-way TLS: this member presents a leaf signed by the cluster's shared etcd CA
# (SAN = NODE_ADDRESS); clients verify it and present no certificate of their own.
# The key was generated on THIS host by witness-join.sh and never left it.
ETCD_CLIENT_SCHEME=${W_CLIENT_SCHEME}
ETCD_SERVER_CERT_FILE=${certfile}
ETCD_SERVER_KEY_FILE=${keyfile}
ETCD_CLIENT_CACERT=${cacert}
# One-way, so clients are NOT asked for a certificate. Written explicitly rather
# than left to the compose fallback, because "false by default" and "false because
# we decided so" read identically until someone changes the default.
ETCD_CLIENT_CERT_AUTH=false

# Not read by ${COMPOSE_FILE} — kept for the tooling and for you: the client
# endpoints of the other members, which is how this script found the live ring.
ETCD_HOSTS=${W_ETCD_HOSTS}
EOF
  # Reached through NAT at an address it does not hold: said once, here, so no later
  # check takes this .env for one copied from another machine.
  [ -z "${W_NAT:-}" ] || printf '\n# This host is reached at NODE_ADDRESS through NAT (accepted at join).\nADDRESS_NOT_LOCAL_OK=1\n' >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# Guards: the wrong machine, a database node, another cluster's witness
# ═════════════════════════════════════════════════════════════════════════════
envv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# "Is this address mine" has one definition in the bundle (cluster-versions.sh). A
# bundle without it cannot tell, and "cannot tell" never refuses.
[ -f "$HERE/cluster-versions.sh" ] && . "$HERE/cluster-versions.sh"
address_is_local() { type cv_address_is_local >/dev/null 2>&1 || return 2; cv_address_is_local "$1"; }
W_NAT=""

# A database node whose stack was stopped (`./taranac down`) has no containers left
# for the check above to see — but its .env and its database volume are still here,
# and this script would retire that .env and turn the node into an arbiter.
guard_not_a_product_host() {
  local why=""
  if [ -f "$ENV_FILE" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?(MASTER_KEY|MASTER_KEY_FILE|SECRET_KEY|POSTGRES_PASSWORD)[[:space:]]*=' "$ENV_FILE"; then
    why="its ${ENV_FILE} is a Taranac node's (it carries the product's keys)"
  elif docker volume inspect taranac_pg_data >/dev/null 2>&1; then
    # A database volume with no product .env beside it is a leftover of an earlier
    # install on this host — not a node, and no reason to refuse. Said, so it is not
    # mistaken for this witness's state.
    note "a database volume from an earlier install is still here (taranac_pg_data); the witness does not use it"
    return 0
  fi
  [ -z "$why" ] && return 0
  fail "this host is a Taranac node — ${why} — so it cannot be the witness. Nothing was changed.
  Its containers are merely stopped. If it is a cluster node, start it again:
    ./taranac up -d
  The witness belongs on a THIRD machine (a small VM is enough): run the command
  './taranac cluster add-witness' printed there instead."
}

# The command was pasted on the wrong machine. It names the host it was issued for;
# only this host knows where it is standing (ha-join.sh has the same guard).
guard_address_is_mine() {
  local mine v=0 vm=0 vw=0
  mine="$(envv NODE_ADDRESS)"
  # This host's own address changed: its .env names an address it no longer holds, the
  # primary names one it does. That is this machine, renumbered — not another one.
  if [ -n "$mine" ] && [ "$mine" != "$W_NODE_ADDRESS" ]; then
    address_is_local "$mine" || vm=$?
    address_is_local "$W_NODE_ADDRESS" || vw=$?
    if [ "$vm" = 1 ] && [ "$vw" = 0 ]; then
      note "this host's address changed (${mine} → ${W_NODE_ADDRESS}) — joining under the new one"
      mine=""
    fi
  fi
  if [ -n "$mine" ] && [ "$mine" != "$W_NODE_ADDRESS" ]; then
    fail "this command was issued for a DIFFERENT machine — nothing has been changed.
  the primary named:  ${W_ETCD_NAME} (${W_NODE_ADDRESS})
  this host is:       $(envv ETCD_NAME) (${mine}), by its ${ENV_FILE}
  Run it on ${W_NODE_ADDRESS}, or add THIS host as the witness on the primary:
    ./taranac cluster add-witness --address ${mine}"
  fi
  address_is_local "$W_NODE_ADDRESS" || v=$?
  if [ "$v" = 1 ]; then
    [ -n "${ADDRESS_NOT_LOCAL_OK:-}" ] || [ "$(envv ADDRESS_NOT_LOCAL_OK)" = 1 ] || fail "the primary named ${W_ETCD_NAME} (${W_NODE_ADDRESS}), but no interface on this host has
  that address — nothing has been changed. Almost always this means the command was
  pasted on the wrong machine: run it on ${W_NODE_ADDRESS} instead.
  If this host really is reached at ${W_NODE_ADDRESS} by the cluster (NAT in front of it),
  say so explicitly and re-run:
    ADDRESS_NOT_LOCAL_OK=1 ./witness-join.sh --broker … --token … --pin …"
    note "${W_NODE_ADDRESS} is not an address of this host — proceeding because ADDRESS_NOT_LOCAL_OK is set (kept in ${ENV_FILE})"
    W_NAT=1
  fi
}

# This host already arbitrates ANOTHER cluster (init and add-witness run on the wrong
# node, or the wrong address typed). Joining here would wipe that cluster's arbiter
# without a word to it. Decided by the cluster's identity in the .env this host
# already has, and only while that witness still serves: its etcd answers with a
# quorum behind it. A witness of a cluster that is gone has nothing left to lose.
guard_not_another_clusters_witness() {
  [ -f "$ENV_FILE" ] || return 0
  local their_id their_name
  their_id="$(envv TARANAC_CLUSTER_ID)"; their_name="$(envv TARANAC_CLUSTER_NAME)"
  [ -n "${their_id}${their_name}" ] || return 0
  if [ -n "$their_id" ] && [ -n "$W_CLUSTER_ID" ]; then
    [ "$their_id" = "$W_CLUSTER_ID" ] && return 0
  elif [ "$their_name" != "$W_CLUSTER_NAME" ]; then
    :   # another name: another cluster
  else
    # Same name and no id to compare (a witness from before 1.2.7 — and every cluster
    # was called 'taranac' by default then). Its own ring tells: the cluster asking is
    # this ring if any of its other members is in it.
    local ring_hosts h
    ring_hosts="$(docker exec "$ETCD_CONTAINER" etcdctl --command-timeout=5s member list 2>/dev/null </dev/null \
                  | awk -F', ' '{ p = $4; sub(/^[a-z]+:\/\//, "", p); sub(/:[0-9]+$/, "", p); print p }')"
    [ -n "$ring_hosts" ] || return 0     # no ring to ask: nothing it still serves
    for h in $(printf '%s' "${CFG_ETCD_INITIAL_CLUSTER:-$W_INITIAL_CLUSTER}" | tr ',' '\n' | sed -e 's/^[^=]*=[a-z]*:\/\///' -e 's/:[0-9]*$//'); do
      [ "$h" = "$W_NODE_ADDRESS" ] && continue
      printf '%s\n' "$ring_hosts" | grep -qxF -- "$h" && return 0
    done
  fi
  if docker exec "$ETCD_CONTAINER" etcdctl --command-timeout=5s endpoint health >/dev/null 2>&1 </dev/null; then
    fail "this host is the live witness of ANOTHER cluster — '${their_name:-unnamed}' (${their_id:-no id}),
  not '${W_CLUSTER_NAME}' (${W_CLUSTER_ID:-no id}). Nothing was changed. Joining here would wipe
  that cluster's arbiter without a word to it.
  If this host is meant to leave '${their_name:-that cluster}': on a database node of it first
    ./taranac cluster remove-witness
  then here
    ./witness-join.sh --leave
  and then run this command again. Otherwise, run it on the host meant to be the witness."
  fi
  note "this host was the witness of '${their_name:-another cluster}', whose ring no longer answers — taking it over"
}

# Prints why this host's etcd state must be KEPT, or nothing (see the call site).
keep_state_reason() {
  docker volume inspect "$ETCD_VOLUME" >/dev/null 2>&1 || return 0
  if [ -n "$ETCD_EP" ]; then
    if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$ETCD_EP" $ETCDCTL_TLS_ARGS member list 2>/dev/null \
         | awk -F', ' -v p="://${W_NODE_ADDRESS}:2380" '$2 == "started" && index($4, p) { f = 1 } END { exit !f }'; then
      printf 'the ring lists this host as a started member already (an earlier run got this far)'
    fi
    return 0
  fi
  local mine; mine="$(envv TARANAC_CLUSTER_ID)"
  if [ -n "$mine" ] && [ "$mine" = "$W_CLUSTER_ID" ]; then
    printf "no member answers yet, and this host's etcd state is this cluster's own (%s)" "$mine"
  fi
  return 0
}

# ── Argument validation ──────────────────────────────────────────────────────
[ -n "$BROKER" ] || fail "missing --broker <host:port>.
  Run './taranac cluster add-witness --address <this host>' on the primary; it prints
  the whole command for this machine, address included."
case "$BROKER" in
  *:[0-9]*) ;;
  *) fail "--broker must be <host>:<port>, e.g. --broker 10.0.0.1:9443 (got '${BROKER}')." ;;
esac
[ -n "$TOKEN" ] || fail "missing --token <secret> — it is in the command './taranac cluster add-witness' printed on the primary."
[ -n "$PIN" ]   || fail "missing --pin sha256:<fingerprint>.
  The broker prints it on the primary's console; it is what makes this channel safe.
  Copy the whole printed command."
case "$PIN" in
  sha256:*|SHA256:*) ;;
  *) fail "--pin must look like 'sha256:<64 hex chars>' (got '${PIN}')." ;;
esac
printf '%s' "$PIN" | sed -e 's/^sha256://I' -e 's/[: ]//g' | grep -qiE '^[0-9a-f]{64}$' \
  || fail "--pin does not contain a 64-character sha256 hex digest (got '${PIN}')."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/witness-join.XXXXXX")"
chmod 700 "$WORK"

# ═════════════════════════════════════════════════════════════════════════════
step "checking this host is a suitable witness"
command -v docker >/dev/null 2>&1 || fail "docker is not installed on this host. Run: sudo bash bootstrap.sh"
docker compose version >/dev/null 2>&1 || fail "the docker compose plugin is not available on this host. Run: sudo bash bootstrap.sh"
command -v openssl >/dev/null 2>&1 || fail "openssl is not installed on this host, and the broker's certificate cannot be pinned without it. Run: sudo bash bootstrap.sh"
command -v curl >/dev/null 2>&1 || fail "curl is not installed on this host. Run: sudo bash bootstrap.sh"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed on this host. Run: sudo bash bootstrap.sh"
curl --help all 2>/dev/null | grep -q -- '--pinnedpubkey' \
  || fail "this host's curl is too old: it has no --pinnedpubkey, so requests after the
  fingerprint check could not be bound to the certificate we validated. Upgrade curl (>= 7.39)."
[ -f "$COMPOSE_FILE" ] || fail "${COMPOSE_FILE} is missing from $(pwd). Unpack the Taranac bundle on this host and run this script from inside it."
[ -x ./ha-etcd-ca.sh ] || fail "./ha-etcd-ca.sh is missing or not executable in $(pwd) — this host generates its own etcd key with it. Refresh the bundle and retry."

# A witness on a DB node is not a smaller deployment, it is a broken one: that host's
# loss takes a database node AND the tiebreaker together, which is precisely the
# event the witness exists to survive. It also cannot physically work — both would
# publish 2379/2380 on the same host and the second one would refuse to start.
for c in taranac-db taranac-api; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    fail "this host is a Taranac node (it has a '${c}' container), so it cannot be the witness.
  The arbiter must live in a SEPARATE failure domain from both DB nodes — losing this
  host would otherwise take a database node and the tiebreaker at the same moment, and
  the cluster would lose quorum in exactly the situation the witness is for.
  It also cannot work as-is: both stacks publish etcd on 2379/2380 here.
  Run this on a third host (a small VM is enough — the witness stores kilobytes)."
  fi
done
guard_not_a_product_host
ok "no Taranac node on this host; docker, curl (--pinnedpubkey), openssl, python3, ${COMPOSE_FILE}"

step "verifying the broker's certificate fingerprint against --pin"
broker_pin
ok "${BROKER} presents exactly the certificate the primary printed"

step "fetching the cluster's etcd topology from the broker"
broker_post /join/config '{}'
eval "$(JSON_FILE="$BROKER_RESP" python3 - <<'PY'
import json, os, shlex, sys

cfg = {}
with open(os.environ["JSON_FILE"], encoding="utf-8") as fh:
    cfg = json.load(fh).get("config") or {}
# Only what a witness legitimately needs. The broker's response also carries the
# cluster's database and application credentials — a witness reads none of them, and
# what is never read cannot be written somewhere it does not belong.
for key in ("TARANAC_CLUSTER_NAME", "TARANAC_CLUSTER_ID",
            "ETCD_HOSTS", "ETCD_INITIAL_CLUSTER",
            "ETCD_CLIENT_SCHEME", "NODE_NAME", "NODE_ADDRESS", "NODE_ROLE",
            # Not config — narration. "1" means the wizard is driving on the other
            # end, so this host stays quiet about next steps the primary will do.
            "WIZARD_DRIVEN"):
    sys.stdout.write("CFG_%s=%s\n" % (key, shlex.quote(str(cfg.get(key, "")))))
PY
)" || fail "the broker's configuration response could not be parsed. Check the broker's console on the primary."

[ -n "$CFG_NODE_NAME" ] && [ -n "$CFG_NODE_ADDRESS" ] \
  || fail "the broker did not say who this witness is meant to be (NODE_NAME/NODE_ADDRESS empty).
  Re-run './taranac cluster add-witness --address <this host>' on the primary."
if [ "$CFG_NODE_ROLE" != witness ]; then
  fail "the primary issued this token for a REPLICA (role '${CFG_NODE_ROLE}'), not a witness.
  A replica runs Postgres and holds the cluster's data; this script sets up an etcd
  arbiter and nothing else. Either run './taranac cluster add-witness' on the primary,
  or — if this host really is meant to be a database node — use ./ha-join.sh here."
fi
[ -n "$CFG_TARANAC_CLUSTER_NAME" ] || fail "the primary reported no TARANAC_CLUSTER_NAME. etcd uses it as the cluster token, and a witness with a different token silently forms its own ring. Fix .env on the primary and retry."
[ -n "$CFG_ETCD_INITIAL_CLUSTER" ] || fail "the primary reported an empty ETCD_INITIAL_CLUSTER, so it has not declared its etcd topology yet.
  Run './taranac cluster init' on the future primary first — the witness is added to a
  cluster that has decided what it is, not the other way round."

W_CLUSTER_NAME="$CFG_TARANAC_CLUSTER_NAME"
# The ring's identity, and the reason it is separate from the name: etcd derives the
# ClusterID from this token, so a witness holding a different one forms a ring of its
# own — the same silent failure the cluster NAME used to produce between a cluster
# and its rebuilt replacement. Empty for a primary that predates the key, and the
# compose file then falls back to the name, which is what that cluster already uses.
W_CLUSTER_ID="$CFG_TARANAC_CLUSTER_ID"
W_NODE_ADDRESS="$CFG_NODE_ADDRESS"
W_ETCD_NAME="$CFG_NODE_NAME"

# The peer scheme FOLLOWS the ring, it is never chosen here. An http witness cannot
# join an https ring and vice versa, and the ring's own member URLs are the only
# statement of what it uses that cannot be out of date.
case ",${CFG_ETCD_INITIAL_CLUSTER}," in
  *"=https://"*) W_PEER_SCHEME=https; W_PEER_AUTO_TLS=true ;;
  *)             W_PEER_SCHEME=http;  W_PEER_AUTO_TLS=false ;;
esac
[ "$CFG_ETCD_CLIENT_SCHEME" = https ] && W_CLIENT_SCHEME=https || W_CLIENT_SCHEME=http

# Append ourselves to the member list if the primary has not listed us already.
W_INITIAL_CLUSTER="$CFG_ETCD_INITIAL_CLUSTER"
self_peer="${W_ETCD_NAME}=${W_PEER_SCHEME}://${W_NODE_ADDRESS}:2380"
case ",${W_INITIAL_CLUSTER}," in
  *",${self_peer},"*) ;;
  *) W_INITIAL_CLUSTER="${W_INITIAL_CLUSTER:+${W_INITIAL_CLUSTER},}${self_peer}" ;;
esac

# Client endpoints of the OTHER members — how we find out whether a ring is already
# running. Prefer what the primary reported; otherwise derive them from the member
# URLs, which always exist by the check above.
W_ETCD_HOSTS="$CFG_ETCD_HOSTS"
if [ -z "$W_ETCD_HOSTS" ]; then
  W_ETCD_HOSTS="$(printf '%s' "$CFG_ETCD_INITIAL_CLUSTER" | tr ',' '\n' | while IFS= read -r m; do
      [ -n "$m" ] || continue
      addr="${m#*://}"; addr="${addr%%:*}"
      if [ -n "$addr" ]; then printf '%s:2379\n' "$addr"; fi
    done | paste -sd, -)"
fi
ok "cluster '${W_CLUSTER_NAME}', this member is '${W_ETCD_NAME}' at ${W_NODE_ADDRESS} (peer ${W_PEER_SCHEME}, client ${W_CLIENT_SCHEME})"

step "checking that this host is the machine the primary named, and serves no other cluster"
guard_address_is_mine
guard_not_another_clusters_witness
ok "this host is ${W_NODE_ADDRESS}, and it is not the live witness of another cluster"

# ── This member's etcd certificate: a CSR, not an scp ────────────────────────
ETCDCTL_MOUNT=""; ETCDCTL_TLS_ARGS=""
if [ "$W_CLIENT_SCHEME" = https ]; then
  step "obtaining this witness's etcd certificate (key stays here, only a request travels)"
  mkdir -p "$TLS_DIR" 2>/dev/null || true
  [ -w "$TLS_DIR" ] || fail "cannot write to '${TLS_DIR}' — it is not writable by $(id -un) (uid $(id -u)).
  Docker most likely created it as root on an earlier start. Fix it and re-run:
    sudo chown -R \"\$(id -u):\$(id -g)\" '${TLS_DIR}'"
  CSR_PATH="$(./ha-etcd-ca.sh make-csr "$TLS_DIR" "taranac-etcd-${W_ETCD_NAME}")" \
    || fail "could not generate this witness's etcd key/CSR in ${TLS_DIR}."
  [ -s "$CSR_PATH" ] || fail "ha-etcd-ca.sh make-csr produced no request at '${CSR_PATH}'."
  CSR_BODY="$(CSR_FILE="$CSR_PATH" python3 -c '
import json, os, sys
with open(os.environ["CSR_FILE"], encoding="utf-8") as fh:
    sys.stdout.write(json.dumps({"csr": fh.read()}))
')"
  broker_post /join/sign-csr "$CSR_BODY"
  json_field "$BROKER_RESP" certificate > "${TLS_DIR}/etcd-server.crt"
  json_field "$BROKER_RESP" ca          > "${TLS_DIR}/ca.crt"
  chmod 644 "${TLS_DIR}/etcd-server.crt" "${TLS_DIR}/ca.crt"
  # Two files on disk prove nothing: a truncated response also produces two files,
  # and etcd would then fail its TLS handshake hours later with no obvious cause.
  grep -q 'BEGIN CERTIFICATE' "${TLS_DIR}/etcd-server.crt" \
    || fail "the broker's answer did not contain a certificate. Check its console on the primary."
  openssl verify -CAfile "${TLS_DIR}/ca.crt" "${TLS_DIR}/etcd-server.crt" >/dev/null 2>&1 \
    || fail "the signed certificate does not verify against the CA the broker returned."
  [ "$(openssl x509 -noout -pubkey -in "${TLS_DIR}/etcd-server.crt" 2>/dev/null)" \
    = "$(openssl pkey -pubout -in "${TLS_DIR}/etcd-server.key" 2>/dev/null)" ] \
    || fail "the signed certificate does not match this host's private key in ${TLS_DIR}/etcd-server.key.
  Delete that key and re-run so a fresh request is made for a fresh key."
  rm -f "$CSR_PATH"
  # etcdctl invocations below run in a throwaway container (the local etcd is not up
  # yet) and so do not inherit the service's ETCDCTL_* env — mount the CA, pass it.
  ETCDCTL_MOUNT="-v ${TLS_DIR}:/tls:ro"; ETCDCTL_TLS_ARGS="--cacert=/tls/ca.crt"
  ok "etcd certificate signed for $(openssl x509 -noout -ext subjectAltName -in "${TLS_DIR}/etcd-server.crt" 2>/dev/null | tail -1 | tr -d ' ')"
else
  # The mount in the compose file is unconditional. Left absent, Docker creates it as
  # root and the next (secure) run cannot write into it.
  mkdir -p "$TLS_DIR" 2>/dev/null || true
  note "this cluster runs etcd in plaintext (ha-convert --plaintext) — no certificate needed"
fi

# ── Is there already a ring, or are we the first member up? ──────────────────
# Both are normal, and they need OPPOSITE bootstrap settings:
#
#   • First member up. This is the documented order for a NEW cluster: the witness
#     must be a live etcd member BEFORE `ha-convert --continue` on the seed, because
#     convert prunes members that have not started and the seed would strand as a
#     1-member cluster. So there is nothing to join yet — we bootstrap with
#     ETCD_INITIAL_CLUSTER_STATE=new and wait for the DB nodes.
#   • The ring is already running (adding or replacing a witness later). Then we must
#     be added to the LIVE cluster and start as an EXISTING member; bootstrapping
#     'new' against a running ring forms a second cluster with a different cluster-id
#     that can never merge.
step "looking for an etcd ring that is already running"
ETCD_EP=""
for hp in $(printf '%s' "$W_ETCD_HOSTS" | tr ',' ' '); do
  case "$hp" in *"${W_NODE_ADDRESS}"*) continue ;; esac   # never probe ourselves
  if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" \
       etcdctl --endpoints="${W_CLIENT_SCHEME}://${hp}" $ETCDCTL_TLS_ARGS endpoint health >/dev/null 2>&1; then
    ETCD_EP="${W_CLIENT_SCHEME}://${hp}"; break
  fi
done

if [ -n "$ETCD_EP" ]; then
  W_CLUSTER_STATE=existing
  ok "a live ring answers at ${ETCD_EP} — this witness will be added to it"
else
  W_CLUSTER_STATE=new
  ok "no member is answering yet — this witness bootstraps the ring and waits for the DB nodes"
  note "that is the expected order for a new cluster: the witness must be live BEFORE"
  note "  './ha-convert.sh --continue' runs on the seed, or convert prunes it"
  # Said out loud because the two situations look identical from here and lead to
  # opposite outcomes: bootstrapping 'new' against a ring that is merely unreachable
  # forms a SECOND cluster with its own cluster-id, which can never merge with the
  # first. If the operator knows the DB nodes are up, they must stop and fix reach.
  note "if the DB nodes ARE already running, stop now: this probe reached none of"
  note "  ${W_ETCD_HOSTS} on ${W_CLIENT_SCHEME}, which means a firewall on 2379 or a"
  note "  client scheme that does not match — not a fresh cluster"
fi

# ── A leftover etcd volume is stale membership, never data worth keeping ─────
# A witness stores nothing but Raft state for the ring it belongs to. If this host
# was a witness for a PREVIOUS cluster, that state carries the old cluster-id and
# etcd will refuse to start against the new one — a wedge with no obvious cause.
#
# 🔑 We DROP the volume outright instead of looking inside it first, and that is the
# safer design, not the lazier one. The obvious version — list the volume in a
# throwaway busybox and clear it only when it looks used — FAILS OPEN on exactly the
# hosts a witness lives on: an air-gapped machine has no busybox and cannot pull one,
# so `docker run … busybox` errors, the command substitution yields "", the emptiness
# test passes, and a populated volume is handed to etcd as if it were clean. Verified
# empirically, not reasoned about. The etcd image cannot stand in for busybox either —
# it carries no shell and no `ls` at all.
#
# And there is nothing here worth the risk of looking: this volume holds Raft state for
# the ring this witness belonged to, and nothing else. No application data has ever been
# on a witness. Re-running this script means the operator wants this host to (re)join a
# cluster with a freshly issued token, so the old ring's state is exactly what must not
# survive. Removing the volume needs no image, so it cannot fail open.
#
# 🔑 With ONE exception, and it is the case a re-run after an interruption produces
# (an ssh drop or a reboot in the middle of `add-witness`): the state belongs to THIS
# ring, and the ring already counts this host as a started member. Wiping it then
# hands etcd an empty data directory for a member the ring knows, which etcd refuses
# for good ("has already been bootstrapped") — the ring loses its witness and the
# seed its quorum, and no command of ours could bring it back. So the state is kept
# when the live ring lists this host as started, or — with no member answering — when
# the state is this cluster's own (same TARANAC_CLUSTER_ID in the .env it came with).
# `add-witness --reinstall` takes the member out of the ring first, so a rebuild still
# starts from a clean slate.
KEEP_STATE="$(keep_state_reason)"
if [ -n "$KEEP_STATE" ]; then
  step "keeping this host's etcd state"
  ok "${KEEP_STATE} — it rejoins with the state it has"
elif docker volume inspect "$ETCD_VOLUME" >/dev/null 2>&1; then
  step "removing this host's previous etcd state"
  docker stop "$ETCD_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$ETCD_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$ETCD_VOLUME" >/dev/null 2>&1 \
    || fail "could not remove the etcd volume '${ETCD_VOLUME}' — something is still using it.
    A witness stores only Raft membership, so this is always safe to delete. Find the
    holder and stop it, then re-run:
      docker ps -a --filter volume=${ETCD_VOLUME}
      docker volume rm ${ETCD_VOLUME}"
  ok "previous etcd state removed — this member joins with a clean slate"
fi

# ── Register in the live ring (only when there is one) ───────────────────────
if [ "$W_CLUSTER_STATE" = existing ]; then
  step "registering '${W_ETCD_NAME}' (${W_NODE_ADDRESS}) as a member of the running ring"
  # Idempotent and scheme-agnostic (match host:2380), so a re-run after an
  # interrupted attempt never produces a duplicate member.
  if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" \
       etcdctl --endpoints="$ETCD_EP" $ETCDCTL_TLS_ARGS member list 2>/dev/null | grep -q "${W_NODE_ADDRESS}:2380"; then
    ok "already a declared member — leaving membership as-is"
  else
    docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" \
      etcdctl --endpoints="$ETCD_EP" $ETCDCTL_TLS_ARGS \
      member add "$W_ETCD_NAME" --peer-urls="${W_PEER_SCHEME}://${W_NODE_ADDRESS}:2380" >/dev/null \
      || fail "etcdctl member add failed via ${ETCD_EP}.
  Check that ${W_ETCD_NAME} / ${W_NODE_ADDRESS} is not already a member with a
  DIFFERENT peer URL:  docker run --rm ${ETCDCTL_MOUNT} ${ETCD_IMAGE} etcdctl --endpoints=${ETCD_EP} ${ETCDCTL_TLS_ARGS} member list"
    ok "declared in the ring; it now expects this member to start"
  fi
fi

# ── Write the .env and start ─────────────────────────────────────────────────
step "writing ${ENV_FILE} for ${COMPOSE_FILE}"
if [ -f "$ENV_FILE" ]; then
  cp -f "$ENV_FILE" "${ENV_FILE}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  note "the previous ${ENV_FILE} was kept as ${ENV_FILE}.bak-*"
fi
write_witness_env
# Assert the artefact, not the act. An unset variable does not make compose fail — it
# becomes an empty string, or the `${VAR:-http}` plaintext fallback, which is how a
# witness ends up looking perfectly healthy while being unable to join an https ring.
#
# The check reads the variable names out of the COMPOSE FILE rather than out of
# compose's warnings: the warning text is a human-facing string that has changed
# between Compose versions, and a guard that silently stops guarding when a message
# is reworded is worse than no guard.
env_missing() {  # → space-separated names the compose file needs and .env lacks
  local v out=""
  # Comment lines are stripped first: the compose file DOCUMENTS the `${VAR:-http}`
  # fallback rule in prose, and a scanner that reads its own documentation as a
  # requirement would report a variable named VAR missing forever.
  for v in $(grep -v '^[[:space:]]*#' "$COMPOSE_FILE" \
             | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${//' | sort -u); do
    grep -qE "^${v}=" "$ENV_FILE" || out="${out}${v} "
  done
  printf '%s' "${out% }"
}
UNSET="$(env_missing)"
[ -z "$UNSET" ] || fail "the generated ${ENV_FILE} does not satisfy ${COMPOSE_FILE}: ${UNSET} missing.
  This is a bug in witness-join.sh — please report it with the line above. Do not
  paper over it by hand-editing ${ENV_FILE}: the same gap comes back on the next run."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null 2>"${WORK}/compose.err" \
  || fail "docker compose cannot read ${COMPOSE_FILE} with the generated ${ENV_FILE}:
  $(cat "${WORK}/compose.err" 2>/dev/null)"
ok "every variable ${COMPOSE_FILE} interpolates is present, and the file resolves"

step "starting the witness etcd"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull >/dev/null 2>&1 || true
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d \
  || fail "docker compose could not start the witness. Read the error above; the usual
  cause is a port already in use (2379/2380) or an unreadable ${TLS_DIR}."

# ═════════════════════════════════════════════════════════════════════════════
# Proving it, instead of announcing it
# ═════════════════════════════════════════════════════════════════════════════
# 'Witness prepared' printed unconditionally is what the old installer did, and it is
# how a cluster reaches production with an arbiter that never joined anything. What
# can be PROVEN depends on which of the two cases we are in — so each is proven on
# its own terms, and neither borrows the other's claim.
container_state() { docker inspect -f '{{.State.Status}}' "$ETCD_CONTAINER" 2>/dev/null || echo missing; }
health_state()    { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ETCD_CONTAINER" 2>/dev/null || echo none; }
restart_count()   { docker inspect -f '{{.RestartCount}}' "$ETCD_CONTAINER" 2>/dev/null || echo 0; }
fatal_log_line() {
  # Config mistakes etcd rejects outright. Surfacing the line beats "it is unhealthy".
  docker logs --tail 200 "$ETCD_CONTAINER" 2>&1 \
    | grep -m1 -iE 'cluster ID mismatch|error validating peerURLs|member count is unequal|failed to find any PEM data|tls: |bind: address already in use|invalid value' || true
}

if [ "$W_CLUSTER_STATE" = existing ]; then
  step "waiting for this witness to become a live member of the ring"
  live=""
  for _ in $(seq 1 40); do
    if [ "$(health_state)" = healthy ]; then live=1; break; fi
    if [ "$(container_state)" = exited ]; then break; fi
    sleep 3
  done
  if [ -z "$live" ]; then
    fail "this witness did not become a live member within the timeout.
  container : $(container_state) (restarts: $(restart_count), health: $(health_state))
  $(fatal_log_line)
  Look at:  docker logs ${ETCD_CONTAINER}
  The usual causes are a peer/client scheme that does not match the rest of the ring,
  2380 blocked between here and the DB nodes, or a member already declared with a
  different peer URL."
  fi
  # 'healthy' means our own etcdctl got a linearizable answer — which it can only do
  # through the ring's quorum. Now confirm the ring names us, from the ring's side.
  MEMBERS="$(docker exec "$ETCD_CONTAINER" etcdctl member list 2>/dev/null || true)"
  printf '%s' "$MEMBERS" | grep -q "${W_NODE_ADDRESS}:2380" \
    || fail "this witness is healthy but the ring's member list does not contain
  ${W_NODE_ADDRESS}:2380. Something else answered our health probe.
  Check:  docker exec ${ETCD_CONTAINER} etcdctl member list"
  ok "live member of the ring, and the ring lists it:"
  printf '%s\n' "$MEMBERS" | sed 's/^/witness-join:       /'
  # This member's version, in the record the update order reads — written by the
  # member itself, the one source a record may come from.
  W_VER="$(head -1 "$HERE/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$W_VER" ]; then
    W_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker exec "$ETCD_CONTAINER" etcdctl --command-timeout=5s put "/taranac/update/members/${W_ETCD_NAME}" \
      "version=${W_VER};state=updated;role=witness;node=${W_ETCD_NAME};address=${W_NODE_ADDRESS};at=${W_NOW};hb=${W_NOW};override=0" >/dev/null 2>&1 \
      && ok "recorded this witness's version (${W_VER}) for the cluster's update order" \
      || note "could not record this witness's version in etcd; './taranac update' here writes it"
  fi
  broker_complete true "witness is a live etcd member of the ring"
  cat <<EOF

witness-join: this host is now a voting etcd member of cluster '${W_CLUSTER_NAME}'.

  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} ps
  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f etcd

  It stores kilobytes and needs no backup — but it does need to stay UP and stay in
  a different failure domain from both DB nodes. Firewall 2379/2380 to the cluster's
  private interconnect.
EOF
  exit 0
fi

# ── First member up: prove everything except the thing that cannot exist yet ──
step "confirming the witness etcd is up and waiting for the rest of the ring"
sleep 5
before_restarts="$(restart_count)"
for _ in $(seq 1 5); do
  [ "$(container_state)" = running ] || break
  sleep 3
done
[ "$(container_state)" = running ] || fail "the witness etcd is not running (state: $(container_state)).
  $(fatal_log_line)
  Read:  docker logs ${ETCD_CONTAINER}"
[ "$(restart_count)" -le "$before_restarts" ] || fail "the witness etcd is restart-looping (restarts: $(restart_count)).
  $(fatal_log_line)
  A container that keeps coming back is not a running witness; read the log above."
LINE="$(fatal_log_line)"
[ -z "$LINE" ] || fail "the witness etcd rejected its configuration:
      ${LINE}
  Nothing here can be fixed by waiting. Read:  docker logs ${ETCD_CONTAINER}"
# The peer listener is up before quorum — that is how members find each other — so it
# is the one network fact that is true and checkable at this point.
# bash's own /dev/tcp rather than nc/ss: a witness host is a bare VM and this needs no
# package. A refused connection on loopback returns immediately, so no timeout is needed.
(exec 3<>/dev/tcp/127.0.0.1/2380) 2>/dev/null \
  || fail "the witness etcd is running but nothing is listening on 2380, so the DB nodes
  cannot reach it. Check the published ports:  docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} ps"
ok "etcd is up, stable, and its Raft port 2380 is accepting connections"

# Honest wording, deliberately: this member is NOT yet part of a formed quorum, and
# it cannot be until the DB nodes come up. Saying "the witness joined the ring" here
# would be exactly the unverified success this script exists to avoid.
broker_complete true "witness etcd is up and waiting for the rest of the ring to form (bootstrap state 'new')"

# ── What to print at the end ─────────────────────────────────────────────────
# When the WIZARD is driving (the broker says so in its config response), this host
# has nothing left for the operator to do: the primary is about to convert itself and
# will report the outcome on its own console. Printing a next-step block here would
# hand out commands for the MANUAL runbook — "run ./ha-convert.sh --continue on the
# seed" — that the wizard runs by itself moments later. A printed command means
# "there is something for you to do", so when there is nothing, print none.
if [ "${CFG_WIZARD_DRIVEN:-}" = "1" ]; then
  cat <<EOF

witness-join: done — this host is now the cluster's etcd arbiter.

  The primary is finishing the conversion; watch its console for the result.
EOF
  exit 0
fi

cat <<EOF

witness-join: the witness etcd is up on this host and waiting for the ring to form.

  It is NOT a member of a working quorum yet, and it cannot be until the database
  nodes start — that is the correct state at this point, not a problem.

  Next, on the seed (the future primary):
      ./ha-convert.sh --continue        # now that this witness is live

  Watch it here while that runs:
      docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} logs -f etcd
      docker exec ${ETCD_CONTAINER} etcdctl endpoint health   # answers once quorum forms

  Firewall 2379/2380 to the cluster's private interconnect. TLS is not a substitute.
EOF
exit 0
