#!/usr/bin/env bash
# ha-join.sh — join THIS host to an existing Taranac HA cluster as a new node
# (docs/ops/ha.md, docs/spec/backend/infra/cluster.md). Patroni does the
# heavy lifting: with an empty data volume and the cluster already in the DCS,
# Patroni CLONES this node from the current primary (its own basebackup/pg_rewind)
# and streams it — there is NO manual pg_basebackup here (that was the Phase-1 path;
# two replication mechanisms would fight). This script is the orchestration around it.
#
# ── TWO WAYS IN, AND THEY COEXIST ────────────────────────────────────────────
#
# A) --broker  (the HA wizard; what `./taranac cluster add-node` prints for you)
#
#      ./ha-join.sh --broker 10.0.0.1:9443 --token <secret> --pin sha256:<fp>
#
#    A one-shot broker on the primary's HOST hands this machine everything it
#    needs: the cluster-wide .env values, a SIGNED etcd certificate in exchange for
#    a CSR (so no TLS file is ever copied by hand), and the cluster's MASTER_KEY +
#    shared mfa key, wrapped. Nothing is supplied out-of-band — not even MASTER_KEY.
#
#    Trust is established by explicit PINNING, not trust-on-first-use: the broker
#    prints its certificate fingerprint on the primary's console and you type it
#    here. Both consoles are in front of the same operator within the same minute,
#    so a pin is both stronger and cheaper than TOFU.
#
#    The token does DOUBLE DUTY with domain separation — HKDF(token,"…auth-v1") is
#    what we present, HKDF(token,"…wrap-v1") is what decrypts the key material. The
#    RAW TOKEN IS NEVER TRANSMITTED. Without that split the value presented as a
#    bearer credential *is* the decryption key, and one proxy log or traffic capture
#    would put the cluster KEK in someone's transcript.
#
#    Node name and address are NOT arguments here: they are what the operator named
#    when issuing the token on the primary, and the etcd certificate is signed for
#    THAT address. Taking them from this side would let the two disagree silently.
#
# B) --primary  (the pre-wizard flow, unchanged and still supported)
#
#      MASTER_KEY=<the cluster master key>  \
#      ./ha-join.sh --node-name node-2 --node-address 10.0.0.2 \
#        --primary <an existing node's address> --join-token <secret>
#
#    Fetches the cluster-wide config from an existing node over the token-
#    authenticated API. MASTER_KEY and this node's etcd leaf are provided
#    out-of-band. (`./taranac cluster join-token` prints this exact command.)
#    Without --primary the cluster-wide settings must be hand-copied into .env
#    first — the same on every node: TARANAC_CLUSTER_NAME, DB_HOSTS, ETCD_HOSTS,
#    ETCD_INITIAL_CLUSTER, POSTGRES_PASSWORD, POSTGRES_REPLICATION_PASSWORD,
#    PG_ALLOW_CIDR, SECRET_KEY. (POSTGRES_PASSWORD/REPLICATION must MATCH the
#    primary — they are the cluster's app + replication credentials. SECRET_KEY must
#    MATCH too: it signs the app's JWTs, so a per-node value breaks login sessions
#    and MFA-setup links across nodes, #36.)
#
# ── A NODE THAT IS ALREADY RUNNING IS THE NORMAL CASE ────────────────────────
# You installed Taranac the ordinary way, ran it, and now want replication. That
# node has a populated database, and a joining replica's local database CANNOT be
# preserved — Patroni clones it from the primary, and two independently seeded
# Postgres instances cannot be merged. That is physics, not policy. So this script
# does not refuse: it COUNTS what the node holds, says what will be lost, takes a
# backup, and asks for an explicit confirmation when there is real content:
#
#      ./ha-join.sh --broker … --token … --pin … --confirm DISCARD-LOCAL-DATA
#
# You never type a `docker volume` command. A node that was installed but never
# configured proceeds with a printed notice and no confirmation.
#
# Other flags:
#   --etcd-name <n>   this node's etcd member name (defaults to the node name)
#   --client-tls      force etcd client-TLS on a MANUAL (no --primary) join
#   --no-backup       skip the pre-discard safety backup (you took one another way)
#   --print-auth      with --token: print the X-Taranac-Join-Auth value this token
#                     derives, then exit. A diagnostic for "the broker says my
#                     credentials are invalid" — compare it with the broker's.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ENV_FILE=.env

# ── The volume probe image ───────────────────────────────────────────────────
# NOT busybox. An appliance and any air-gapped host bake a FIXED image set and
# busybox is not in it, so `docker run … busybox` fails there and cannot be pulled.
# A probe that errors yields an empty listing, and an empty listing reads as "the
# volume is clean" — the exact fail-open that would hand a populated volume to
# Patroni. postgres:16-alpine is already in the appliance's preloaded set
# (deploy/ova/preload-images.sh) and on every Taranac node by construction, and it
# carries a shell. Same image the pg_data probe has always used.
PROBE_IMAGE="postgres:16-alpine"
COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

# The command line exactly as the operator typed it. Kept so that a refusal can
# print the SAME command back with --confirm appended, instead of describing it.
ORIG_ARGV=("$@")

NODE_NAME=""; NODE_ADDRESS=""; JOIN_TOKEN=""; ETCD_NAME=""; PRIMARY=""; CLIENT_TLS_FLAG=""
BROKER=""; TOKEN=""; PIN=""; CONFIRM=""; NO_BACKUP=""; PRINT_AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node-name)    NODE_NAME="$2"; shift 2 ;;
    --node-address) NODE_ADDRESS="$2"; shift 2 ;;
    --join-token)   JOIN_TOKEN="$2"; shift 2 ;;
    --etcd-name)    ETCD_NAME="$2"; shift 2 ;;   # defaults to the node name
    --primary)      PRIMARY="$2"; shift 2 ;;     # an existing node's address to fetch cluster config from
    --client-tls)   CLIENT_TLS_FLAG=1; shift ;;  # force etcd client-TLS (manual/no-primary joins)
    --broker)       BROKER="$2"; shift 2 ;;      # host:port of the primary's one-shot join broker
    --token)        TOKEN="$2"; shift 2 ;;       # the join token (broker path); never transmitted raw
    --pin)          PIN="$2"; shift 2 ;;         # sha256:<hex> of the broker's certificate (DER)
    --confirm)      CONFIRM="$2"; shift 2 ;;     # DISCARD-LOCAL-DATA — see the header
    --no-backup)    NO_BACKUP=1; shift ;;        # skip the pre-discard safety backup
    --print-auth)   PRINT_AUTH=1; shift ;;       # diagnostic: print the derived auth value
    -h|--help)      sed -n '2,71p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Narration: every step says what it is about to do, before it does it ──────
# A join touches a dozen subsystems on two machines. When it fails, the ONE thing
# that shortens the diagnosis is knowing which step was running — so failures
# reprint the step by name rather than leaving a bare exit code. (No "N of total":
# the number of steps genuinely depends on what this node turns out to hold, and a
# total that is wrong half the time is worse than no total at all.)
STEP_N=0; STEP=""
step() { STEP_N=$((STEP_N + 1)); STEP="$*"; printf 'ha-join: [%d] %s…\n' "$STEP_N" "$STEP"; }
ok()   { printf 'ha-join:     ✓ %s\n' "$*"; }
note() { printf 'ha-join:     · %s\n' "$*"; }

# ── Progress on the long waits ───────────────────────────────────────────────
# Cloning a database and waiting for a stack to come up take minutes, and a console
# that prints nothing for minutes is indistinguishable from one that has hung — the
# operator's only options are to wait blindly or to Ctrl-C something that was working.
# So every wait longer than a few seconds reports elapsed time and what it is waiting
# FOR, in place on one line. No spinner characters: this output is also read from
# logs and over ssh, where a spinner is just noise.
progress() {  # <elapsed-seconds> <budget-seconds> <what>
  local e="$1" b="$2" what="$3" filled width=24 pct
  pct=$(( e * 100 / (b > 0 ? b : 1) )); [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * width / 100 ))
  printf '\rha-join:     [%s%s] %3d%%  %ds/%ds  %s' \
    "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' "$((width - filled))" '')" \
    "$pct" "$e" "$b" "$what"
}
progress_done() { printf '\r%*s\r' 80 ''; }   # wipe the line so the ✓ lands clean


fail() {
  [ -n "$STEP" ] && echo "ha-join: FAILED at step [${STEP_N}] ${STEP}" >&2
  echo "ha-join: $*" >&2
  exit 1
}
# An ABSENT key is an empty value, not an error. Without `|| true` this pipeline exits 1
# when grep matches nothing, and under `set -euo pipefail` a bare assignment —
# VAR="$(getenv MISSING)" — kills the script SILENTLY, mid-step, with no message at
# all. Fixed in the sibling scripts after it cost an afternoon; missed here until the
# wrong-terminal guard read a key a fresh node does not have and the join just died.
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true ; }
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

# ═════════════════════════════════════════════════════════════════════════════
# The broker protocol — this machine's half
# ═════════════════════════════════════════════════════════════════════════════
# The server half is deploy/dist/cluster-broker.py; its docstring is the contract.
# Everything below must match it bit-for-bit, so the constants are spelled out here
# rather than derived, and the HKDF is the same textbook construction.

INFO_AUTH="taranac-ha-join-auth-v1"
INFO_WRAP="taranac-ha-join-wrap-v1"

WORK=""              # private scratch dir (curl configs, the fetched cert, blobs)
BROKER_READY=0       # 1 once the certificate is pinned and we may speak to it
BROKER_SPKI=""       # base64 sha256 of the pinned cert's public key, for curl
AUTH_B64=""          # X-Taranac-Join-Auth value (HKDF of the token, never the token)
COMPLETE_SENT=0      # /join/complete is mandatory and must be sent exactly once

# RFC 5869 HKDF-SHA256 with an empty salt — the construction in cluster-broker.py's
# hkdf(). Implemented on hmac+hashlib (stdlib only) so it works on a machine whose
# package set we do not control; `cryptography` is needed ONLY for the AES-GCM
# unwrap. The token goes through the ENVIRONMENT, never argv: argv is world-readable
# in /proc on a multi-user box, and this one secret opens the whole cluster.
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

# AES-256-GCM under HKDF(token,"…wrap-v1") over base64(nonce || ciphertext || tag) —
# cluster-broker.py::wrap_secret. Writes RAW BYTES to stdout: the mfa enckey is
# binary and may contain NULs, which a $(...) capture would silently mangle, so
# every caller redirects this into a file.
#
# The derivation is repeated here instead of calling hkdf_b64: handing a decryption
# key back through the shell would put it in another process's argv/environment for
# no benefit, and this function has to be readable on its own to be trusted.
unwrap_secret() {  # <token> <base64-blob>  → plaintext bytes on stdout
  UNWRAP_TOKEN="$1" UNWRAP_BLOB="$2" python3 - <<'PY'
import base64, hashlib, hmac, os, sys

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    sys.stderr.write(
        "python3-cryptography is not installed on this host, and the cluster's master\n"
        "key is delivered wrapped. Install it, then re-run the join:\n"
        "    sudo apt install -y python3-cryptography     # Debian / Ubuntu\n"
        "    sudo dnf install -y python3-cryptography     # RHEL / Fedora / Rocky\n"
    )
    raise SystemExit(3)

token = os.environ["UNWRAP_TOKEN"].encode()
info = b"taranac-ha-join-wrap-v1"
prk = hmac.new(b"\x00" * hashlib.sha256().digest_size, token, hashlib.sha256).digest()
out, block, counter = b"", b"", 1
while len(out) < 32:
    block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
    out += block
    counter += 1

try:
    blob = base64.b64decode(os.environ["UNWRAP_BLOB"], validate=True)
    if len(blob) < 12 + 16:
        raise ValueError("blob shorter than nonce+tag")
    plain = AESGCM(out[:32]).decrypt(blob[:12], blob[12:], None)
except Exception:
    # GCM authenticates: a failure here is a WRONG TOKEN or a tampered payload, not
    # a corrupt file. Say so, because the operator's instinct will be to retry.
    sys.stderr.write(
        "the wrapped secret did not decrypt or did not authenticate. The token on this\n"
        "machine does not match the one the broker was started with — copy the command\n"
        "the primary printed again, in full.\n"
    )
    raise SystemExit(4)
sys.stdout.buffer.write(plain)
PY
}

# ── Pinning: prove WHO we are talking to before saying anything to it ─────────
# Nothing derived from the token is transmitted until this passes. The pin covers
# the certificate's DER, exactly as cluster-broker.py computes and prints it.
#
# The connection itself is then bound to the SAME key with curl's --pinnedpubkey
# rather than to a CA or a hostname: the operator is explicitly invited to edit the
# broker address (NAT, a different FQDN, another port), so hostname verification
# would reject the very thing the design asks for, while the fingerprint stays true.
broker_pin() {
  local host="${BROKER%:*}" port="${BROKER##*:}" got want
  local -a sni=()
  # SNI is a DNS extension: sending an IP literal in it is malformed and some
  # stacks drop the handshake. Only offer it when the operator gave us a name.
  case "$host" in
    *[!0-9.]*) sni=(-servername "$host") ;;
  esac
  openssl s_client -connect "${host}:${port}" ${sni[0]+"${sni[@]}"} </dev/null 2>/dev/null \
    | openssl x509 -outform DER > "${WORK}/broker.der" 2>/dev/null || true
  [ -s "${WORK}/broker.der" ] || fail \
    "could not read a TLS certificate from ${BROKER}.
  Is the broker still running on the primary? It is one-shot and exits when it times
  out. Re-run './taranac cluster add-node --address <this node>' there, and check that
  this machine can reach ${BROKER} (firewall?)."

  got="$(sha256sum "${WORK}/broker.der" | cut -d' ' -f1)"
  want="$(printf '%s' "$PIN" | sed -e 's/^sha256://I' -e 's/[: ]//g' | tr 'A-Z' 'a-z')"
  if [ "$got" != "$want" ]; then
    cat >&2 <<EOF
ha-join: FAILED at step [${STEP_N}] ${STEP}
ha-join: the certificate presented by ${BROKER} does NOT match --pin.

  expected (--pin) : sha256:${want}
  presented        : sha256:${got}

  Nothing was sent — this machine has not disclosed the join token or anything
  derived from it, and nothing on this node was changed.

  Exactly two things cause this:
    • the address is not the machine you think it is — check --broker against the
      command the primary printed, including the port;
    • something is terminating TLS between here and there (a proxy, a load
      balancer, an inspecting firewall) and re-signing the connection.
  Neither is safe to click through: this channel carries the cluster's master key.
EOF
    exit 1
  fi

  # Bind every later request to the key we just validated.
  BROKER_SPKI="$(openssl x509 -inform DER -in "${WORK}/broker.der" -pubkey -noout \
                 | openssl pkey -pubin -outform DER 2>/dev/null \
                 | openssl dgst -sha256 -binary | base64 | tr -d '\n')"
  [ -n "$BROKER_SPKI" ] || fail "could not extract the broker certificate's public key (openssl too old?)."
  AUTH_B64="$(hkdf_b64 "$TOKEN" "$INFO_AUTH")"
  [ -n "$AUTH_B64" ] || fail "could not derive the join authenticator (is python3 installed?)."
  BROKER_READY=1
}

# One POST. The URL, the auth header and the request body all go through a curl
# CONFIG FILE (mode 0600) rather than argv, so none of them is visible in `ps` to
# any other user on this box while the join runs.
#
# Sets BROKER_RESP to the response body file. Non-2xx is a hard failure carrying
# the broker's own error text, which is written to be read by a human.
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
    printf 'max-time = 300\n'    # signing + wrapping are fast; a clone is not in here
  } >> "$cfg"
  : > "$BROKER_RESP"
  code="$(curl -K "$cfg" 2>"${WORK}/curl.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      90|60|58|35|77) fail "the broker at ${BROKER} no longer presents the pinned certificate (curl exit ${rc}).
  A one-shot broker mints a FRESH certificate every time it starts, so this is what
  a second 'add-node' on the primary looks like. Use the --pin from the command that
  is on the primary's console NOW.
  $(cat "${WORK}/curl.err" 2>/dev/null)" ;;
      *) fail "could not reach ${BROKER}${path} (curl exit ${rc}).
  $(cat "${WORK}/curl.err" 2>/dev/null)
  The broker is one-shot: if it timed out, run './taranac cluster add-node' on the
  primary again — it issues a fresh token and prints a fresh command." ;;
    esac
  fi
  case "$code" in
    2??) return 0 ;;
    401) fail "the broker rejected our credentials (401).
  The token on this machine is not the one the broker was started with. Copy the
  whole command the primary printed — the token is long and easy to truncate.
  To compare without guessing: ./ha-join.sh --token <secret> --print-auth" ;;
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

# ── The mandatory ending ─────────────────────────────────────────────────────
# The broker's ONLY truthful ending is this machine reporting an outcome. If we
# merely exited, the broker would sit until its timer ran out and then report a
# timeout — i.e. "I do not know what happened", for a failure we knew about. So a
# failure is REPORTED, not merely exited on, and the EXIT trap below guarantees it
# even for a `set -e` abort deep inside a helper.
broker_complete() {  # <true|false> [detail]
  [ -n "$BROKER" ] && [ "$BROKER_READY" -eq 1 ] && [ "$COMPLETE_SENT" -eq 0 ] || return 0
  COMPLETE_SENT=1
  local body detail="${2:-}"
  body="$(OKV="$1" DET="$detail" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"ok": os.environ["OKV"] == "true", "detail": os.environ["DET"]}))
')"
  # Best effort by design: a broker that already gave up must not turn a successful
  # join into a failure, nor a failure into a confusing second error.
  broker_post /join/complete "$body" >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    broker_complete false "failed at step [${STEP_N}] ${STEP:-startup} (exit ${rc})" || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  # Everything this script has to clean up goes HERE. `trap … EXIT` REPLACES any
  # previous EXIT trap rather than adding to it, so a second `trap` anywhere below
  # silently disables the failure report above — the join dies and the primary's
  # broker is never told, so it waits out its whole timeout for a machine that has
  # already given up. Caught exactly that way by tests/test_ha_join_broker.sh.
  [ -n "${BACKUP_ERR_FILE:-}" ] && rm -f "$BACKUP_ERR_FILE"
  return 0
}
trap on_exit EXIT

# ── --print-auth: a diagnostic, and nothing else ──────────────────────────────
# Answers exactly one question — "does my token derive what the broker expects?" —
# without a join, a container or a .env. It reveals nothing the join itself would
# not put on the wire, and it is derived from a token the caller already holds.
if [ -n "$PRINT_AUTH" ]; then
  [ -n "$TOKEN" ] || { echo "ha-join: --print-auth needs --token <secret>." >&2; exit 2; }
  hkdf_b64 "$TOKEN" "$INFO_AUTH"; echo
  exit 0
fi

# ── Argument validation ──────────────────────────────────────────────────────
if [ -n "$BROKER" ] && [ -n "$PRIMARY" ]; then
  fail "--broker and --primary are two different ways to join and cannot be combined.
  Use --broker with the command './taranac cluster add-node' printed on the primary;
  use --primary only for the older hand-driven flow (MASTER_KEY supplied by you)."
fi

if [ -n "$BROKER" ]; then
  case "$BROKER" in
    *:[0-9]*) ;;
    *) fail "--broker must be <host>:<port>, e.g. --broker 10.0.0.1:9443 (got '${BROKER}')." ;;
  esac
  [ -n "$TOKEN" ] || fail "missing --token <secret> — it is in the command './taranac cluster add-node' printed on the primary."
  [ -n "$PIN" ]   || fail "missing --pin sha256:<fingerprint>.
  The broker prints it on the primary's console; it is what makes this channel safe
  to carry the cluster's master key. Copy the whole printed command."
  case "$PIN" in
    sha256:*|SHA256:*) ;;
    *) fail "--pin must look like 'sha256:<64 hex chars>' (got '${PIN}')." ;;
  esac
  printf '%s' "$PIN" | sed -e 's/^sha256://I' -e 's/[: ]//g' | grep -qiE '^[0-9a-f]{64}$' \
    || fail "--pin does not contain a 64-character sha256 hex digest (got '${PIN}')."
  [ -z "$JOIN_TOKEN" ] || fail "--join-token belongs to the --primary flow. On the broker path the SAME --token both authenticates the channel and registers this node in the roster."
  if [ -n "$NODE_NAME" ] || [ -n "$NODE_ADDRESS" ]; then
    fail "--node-name / --node-address are not accepted with --broker.
  The primary already recorded this node's name and address when it issued the
  token, and it signs this node's etcd certificate for THAT address. Letting the two
  sides name the node independently is how they end up disagreeing silently. To
  change either, re-run './taranac cluster add-node --address <addr>' on the primary."
  fi
  # The broker path supplies the master key over the wrapped channel; requiring it
  # in the environment as well would defeat the point of the whole exercise.
  [ -z "${MASTER_KEY:-}" ] || note "MASTER_KEY is set in this environment; the broker path ignores it and uses the cluster's own."
else
  [ -z "$TOKEN" ]   || fail "--token is the broker path's credential. For --primary (or a manual join), pass --join-token instead."
  [ -z "$PIN" ]     || fail "--pin only means something with --broker (it pins the broker's certificate)."
fi

if [ -n "$CONFIRM" ] && [ "$CONFIRM" != "DISCARD-LOCAL-DATA" ]; then
  fail "--confirm takes exactly DISCARD-LOCAL-DATA (got '${CONFIRM}'). Nothing was changed."
fi

# ── Guards ───────────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — run './install.sh' on this node first (it writes .env; a node that has already been installed and used is fine — this script tells you what it holds before discarding it)."
command -v docker >/dev/null 2>&1 || fail "docker is not installed on this host. Run: sudo bash bootstrap.sh"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed on this host. Run: sudo bash bootstrap.sh"
if [ -z "$BROKER" ]; then
  [ -n "$NODE_NAME" ]    || fail "missing --node-name (this node's unique cluster name)"
  [ -n "$NODE_ADDRESS" ] || fail "missing --node-address (this node's routable host/IP the other nodes reach)"
  [ -n "$JOIN_TOKEN" ]   || fail "missing --join-token (issue it on the primary: ./taranac cluster join-token --name ${NODE_NAME} --address ${NODE_ADDRESS})"
  [ -n "${MASTER_KEY:-}" ] || fail "MASTER_KEY must be provided out-of-band (env). It is NEVER replicated as data; the wrong/missing key makes every stored secret undecryptable."
fi

# `--etcd-name` has always been documented as defaulting to the node name, and up
# to 1.2.2 this line sat exactly here. The broker work moved it in beside the
# broker's own identity handling, so a join that did not go through a broker
# registered its etcd member under an EMPTY name. Nothing said so — the first
# defect on this path killed the script long before it could be reached.
ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ha-join.XXXXXX")"
chmod 700 "$WORK"

# ═════════════════════════════════════════════════════════════════════════════
# BROKER PATH — steps 1..3 (everything before this node is touched at all)
# ═════════════════════════════════════════════════════════════════════════════
if [ -n "$BROKER" ]; then
  step "checking this host has what the join needs"
  command -v openssl >/dev/null 2>&1 || fail "openssl is not installed on this host, and the broker's certificate cannot be pinned without it. Run: sudo bash bootstrap.sh"
  command -v curl >/dev/null 2>&1 || fail "curl is not installed on this host. Run: sudo bash bootstrap.sh"
  curl --help all 2>/dev/null | grep -q -- '--pinnedpubkey' \
    || fail "this host's curl is too old: it has no --pinnedpubkey, so requests after the
  fingerprint check could not be bound to the certificate we validated. Upgrade curl
  (>= 7.39), or use the --primary flow with an out-of-band MASTER_KEY."
  # Checked BEFORE anything is contacted: discovering the missing package after the
  # database has been discarded would be the worst possible moment for it.
  python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM' 2>/dev/null \
    || fail "python3-cryptography is not installed on this host, and the cluster's master key
  arrives wrapped (AES-256-GCM). Install it, then re-run:
    sudo apt install -y python3-cryptography     # Debian / Ubuntu
    sudo dnf install -y python3-cryptography     # RHEL / Fedora / Rocky"
  [ -f docker-compose.yml ] && [ -f docker-compose.ha.yml ] \
    || fail "docker-compose.yml / docker-compose.ha.yml are missing from $(pwd). Run this from the unpacked Taranac bundle directory on the node you are adding."
  [ -x ./ha-etcd-ca.sh ] || fail "./ha-etcd-ca.sh is missing or not executable in $(pwd) — this node generates its own etcd key with it. Refresh the bundle and retry."
  ok "docker, curl (--pinnedpubkey), openssl, python3-cryptography, compose files"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SHARED — every join runs what follows, broker or not
# ═════════════════════════════════════════════════════════════════════════════
# This block used to sit INSIDE the broker branch above, which is why it is
# written at column 0 while that branch's own lines are indented: it was never
# meant to be in there. The effect was that a join which did not go through a
# broker never defined any of it and died on the first use — `PG_POPULATED:
# unbound variable`, a bash error, before a single check could speak. Shipped
# that way in 1.2.3; the guard tests caught it, and they are the reason the
# branch is now closed here and reopened for the one step that is genuinely the
# broker's, so the broker path runs in exactly the order it did.

# Everything the inventory and the gate below call must be DEFINED first: bash
# resolves a function at CALL time from what it has already read, so a helper left
# further down is simply "command not found" — and under `set -u` the next line dies
# on the variable it was meant to set. Cost an afternoon once already; not twice.
PG_VOL="taranac_pg_data"
PG_CONTAINER="taranac-db"
BASE_COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml"

PG_POPULATED=0        # 1 = the volume holds a database
DB_STARTED_BY_US=0    # 1 = we started postgres purely to look inside it
LOCAL_DEVICES=""      # "" throughout means "could not be counted", never "zero"
LOCAL_ADMINS=""
LOCAL_LOGS=""
LOCAL_LOGS_EXACT=0

# Ask THIS node's Postgres directly rather than its API. On a node being joined the
# api may be down, mid-upgrade or refusing logins, and the question "what would be
# lost" still has to get an answer. psql -tAqc yields a bare scalar; anything that
# cannot be answered (stopped DB, missing table) yields "" and is reported as
# unknown — which the gate below treats as "assume there is something".
pg_scalar() {  # <sql> → scalar on stdout, "" when unanswerable
  docker exec "$PG_CONTAINER" psql -U taranac -d taranac -tAqc "$1" 2>/dev/null | head -1 | tr -d '[:space:]'
}

pg_volume_populated() {  # 0 = holds data, 1 = empty, 2 = could not tell
  docker volume inspect "$PG_VOL" >/dev/null 2>&1 || return 1
  local listing rc=0
  listing="$(docker run --rm -v "${PG_VOL}:/d" "$PROBE_IMAGE" sh -c 'ls -A /d 2>/dev/null')" || rc=$?
  # A failed probe is NOT an empty volume. Reporting "empty" because the probe image could
  # not be pulled would hand a populated volume to Patroni and wedge the join.
  [ "$rc" -eq 0 ] || return 2
  [ -n "$listing" ] || return 1
  return 0
}

ensure_db_running() {  # 0 = taranac-db answers queries
  [ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null || echo false)" = true ] && return 0
  # Base compose only, deliberately: at this point the node is still standalone, and
  # starting it under the HA overlay would put Patroni on a PGDATA it has never seen.
  ${BASE_COMPOSE} up -d postgres >/dev/null 2>&1 || return 1
  DB_STARTED_BY_US=1
  local i
  for i in $(seq 1 30); do
    docker exec "$PG_CONTAINER" pg_isready -U taranac -d taranac >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# The log tables. Counted separately from configuration because they are what makes
# a node "big", and because they are the one thing the safety backup does NOT carry.
LOG_TABLES="tacacs_authn_logs tacacs_authz_logs tacacs_acct_logs radius_auth_logs radius_acct_logs nac_auth_logs"

inventory_local_data() {
  local admin_user t present rows est any_unknown=0 total=0 exact=1
  admin_user="$(getenv INITIAL_ADMIN_USERNAME)"; admin_user="${admin_user:-admin}"

  LOCAL_DEVICES="$(pg_scalar "select count(*) from devices")"
  # "Beyond the default" is the honest measure: every install has the seeded admin,
  # and reporting it as a loss would cry wolf on a node that holds nothing.
  LOCAL_ADMINS="$(pg_scalar "select count(*) from users where username <> '$(printf '%s' "$admin_user" | sed "s/'/''/g")'")"

  for t in $LOG_TABLES; do
    present="$(pg_scalar "select to_regclass('public.${t}') is not null")"
    [ "$present" = t ] || { [ -n "$present" ] || any_unknown=1; continue; }
    # Exact existence (instant, LIMIT 1) decides the gate; the magnitude is the
    # planner's estimate, because count(*) over 5M+ rows on a 100 GB node is a
    # multi-minute seq scan and nobody needs the last digit to decide this.
    rows="$(pg_scalar "select coalesce((select 1 from ${t} limit 1), 0)")"
    [ -n "$rows" ] || { any_unknown=1; continue; }
    [ "$rows" = 1 ] || continue
    est="$(pg_scalar "select greatest(reltuples, 0)::bigint from pg_class where oid = 'public.${t}'::regclass")"
    case "$est" in *[!0-9]*|"") est=0 ;; esac
    if [ "$est" -eq 0 ]; then
      # Non-empty but never ANALYZEd: say "some", never "0". Under-reporting here
      # would downgrade a node with real traffic history to "nothing configured".
      exact=0; est=1
    fi
    total=$((total + est))
  done
  if [ "$any_unknown" -eq 1 ]; then LOCAL_LOGS=""; else LOCAL_LOGS="$total"; LOCAL_LOGS_EXACT="$exact"; fi
}

# The decision, kept deliberately free of docker, SQL and printing so it can be read
# — and tested — on its own. Each argument is a count, or "" for "could not count".
local_data_is_material() {  # 0 = requires a typed confirmation
  local devices="$1" admins="$2" logs="$3"
  # An unanswerable question is not a "no". If the node would not tell us what it
  # holds, the safe reading is "something" — the alternative is discarding a
  # customer's database because a container refused to start.
  if [ -z "$devices" ] || [ -z "$admins" ] || [ -z "$logs" ]; then return 0; fi
  [ "$devices" -gt 0 ] 2>/dev/null && return 0
  [ "$admins" -gt 0 ] 2>/dev/null && return 0
  [ "$logs" -gt 0 ] 2>/dev/null && return 0
  return 1
}

  # 🔑 The local inventory and the discard gate run BEFORE the broker is contacted.
  # They need nothing from it — the counts come from this node's own database — and
  # putting them after cost the operator a working token: the run that only asked
  # "may I discard this?" had already opened the channel, so stopping at the gate
  # reported a failure to the broker, which is ONE-SHOT and closed. The cure it
  # printed ("re-run the same command with --confirm") could then never work, because
  # the token and the channel it names are gone. Seen on the stand.
  #
  # Asking a question must not consume the thing the answer is for.
fmt_count() {  # "" → "could not be counted"; otherwise the number, ≈ when estimated
  if [ -z "$1" ]; then printf 'could not be counted'; elif [ "${2:-1}" = 0 ]; then printf '≈%s' "$1"; else printf '%s' "$1"; fi
}

step "inspecting what this node currently holds"
PG_PROBE=0; pg_volume_populated || PG_PROBE=$?
case "$PG_PROBE" in
  1) ok "the Postgres volume '${PG_VOL}' is empty — nothing on this node to lose" ;;
  2) PG_POPULATED=1
     note "could not read the Postgres volume '${PG_VOL}' (is dockerd healthy?)"
     note "treating this node as if it holds data — see the confirmation below" ;;
  0) PG_POPULATED=1
     if ensure_db_running; then
       [ "$DB_STARTED_BY_US" -eq 1 ] && note "started this node's Postgres read-only to count what it holds"
       inventory_local_data
     else
       note "this node's Postgres would not start, so its contents could not be counted"
       note "  (look at:  docker logs ${PG_CONTAINER}  before deciding)"
     fi
     ;;
esac

if [ "$PG_POPULATED" -eq 1 ]; then
  step "deciding whether this node's local data may be discarded"
  printf '\n'
  printf '  This node already holds a database of its own:\n\n'
  printf '      devices                %s\n' "$(fmt_count "$LOCAL_DEVICES")"
  printf '      administrators         %s   (beyond the default account)\n' "$(fmt_count "$LOCAL_ADMINS")"
  printf '      AAA / NAC log records  %s\n' "$(fmt_count "$LOCAL_LOGS" "$LOCAL_LOGS_EXACT")"
  printf '\n'
  printf '  Joining DISCARDS all of it. A replica is cloned from the cluster'"'"'s primary by\n'
  printf '  Patroni; two separately seeded databases cannot be merged, so no variant of\n'
  printf '  this operation keeps the local copy.\n\n'

  if local_data_is_material "$LOCAL_DEVICES" "$LOCAL_ADMINS" "$LOCAL_LOGS"; then
    if [ "$CONFIRM" != "DISCARD-LOCAL-DATA" ]; then
      printf '  Nothing has been changed. If that is what you want, re-run the SAME command\n'
      printf '  with the confirmation appended:\n\n      %s' "$0"
      # %q, not %s: an argument that happens to contain a space or a quote has to come
      # back as something the shell will parse into the SAME argument. A re-run command
      # that is subtly not the original is worse than no suggestion at all.
      printf ' %q' "${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}"
      printf ' \\\n          --confirm DISCARD-LOCAL-DATA\n\n'
      printf '  A configuration backup is taken first and left on this node. Note that it is a\n'
      printf '  CONFIGURATION backup: devices, users and settings come back from it — log\n'
      printf '  records do not. Export anything you need from Reports before confirming.\n\n'
      # Leave the node exactly as we found it. Counting may have started a Postgres
      # that was deliberately stopped, and a refusal that quietly leaves a service
      # running is a change made by a command that promised it changed nothing.
      if [ "$DB_STARTED_BY_US" -eq 1 ]; then
        ${BASE_COMPOSE} stop postgres >/dev/null 2>&1 || true
        note "the Postgres this script started for counting has been stopped again"
      fi
      # Reported, not merely exited on: the operator is standing at the primary's
      # console too, and it must say why this stopped rather than time out.
      broker_complete false "the node holds local data and the operator has not confirmed discarding it"
      exit 1
    fi
    ok "--confirm DISCARD-LOCAL-DATA given — proceeding, after a backup"
  else
    # Installed, started, never configured. Real, common, and not worth a prompt.
    ok "nothing configured on this node beyond the fresh-install state — proceeding"
  fi
fi

# ── Applying a fetched cluster config (shared by --primary and --broker) ─────
apply_cluster_config() {
  # Append THIS node to the membership lists if the primary did not already list it.
  # The peer scheme MUST match the existing cluster. Secure etcd (peer + client TLS) is
  # the DEFAULT now (#30, ha.md §7), but this node FOLLOWS whatever the cluster actually
  # advertises — so it derives the peer scheme from the https:// in the primary's member
  # list (a plaintext cluster reports http:// → this node stays http, back-compat intact),
  # falling back to ETCD_PEER_SCHEME. ETCD_HOSTS entries (self_etcd) are scheme-less
  # host:port — the client scheme is applied separately below via CLIENT_SCHEME.
  case ",$CFG_ETCD_INITIAL_CLUSTER," in *"=https://"*) PEER_SCHEME=https ;; *) PEER_SCHEME="${ETCD_PEER_SCHEME:-http}" ;; esac
  self_db="${NODE_ADDRESS}:5432"; self_etcd="${NODE_ADDRESS}:2379"; self_peer="${NODE_NAME}=${PEER_SCHEME}://${NODE_ADDRESS}:2380"
  case ",$CFG_DB_HOSTS,"             in *",$self_db,"*)   ;; *) CFG_DB_HOSTS="${CFG_DB_HOSTS:+$CFG_DB_HOSTS,}$self_db" ;; esac
  case ",$CFG_ETCD_HOSTS,"           in *",$self_etcd,"*) ;; *) CFG_ETCD_HOSTS="${CFG_ETCD_HOSTS:+$CFG_ETCD_HOSTS,}$self_etcd" ;; esac
  case ",$CFG_ETCD_INITIAL_CLUSTER," in *",$self_peer,"*) ;; *) CFG_ETCD_INITIAL_CLUSTER="${CFG_ETCD_INITIAL_CLUSTER:+$CFG_ETCD_INITIAL_CLUSTER,}$self_peer" ;; esac
  setenv TARANAC_CLUSTER_NAME "$CFG_TARANAC_CLUSTER_NAME"
  # The ring's identity (etcd's cluster token), independent of the cluster's NAME.
  # etcd derives its ClusterID from it, so this node MUST hold the cluster's value
  # or its etcd bootstraps a ring of its own and never joins. Guarded non-empty so
  # a primary that predates the key cannot blank it: both sides then fall back to
  # the cluster name, exactly as before, and the ring still forms.
  [ -n "${CFG_TARANAC_CLUSTER_ID:-}" ] && setenv TARANAC_CLUSTER_ID "$CFG_TARANAC_CLUSTER_ID"
  setenv DB_HOSTS "$CFG_DB_HOSTS"
  setenv ETCD_HOSTS "$CFG_ETCD_HOSTS"
  setenv ETCD_INITIAL_CLUSTER "$CFG_ETCD_INITIAL_CLUSTER"
  setenv PG_ALLOW_CIDR "$CFG_PG_ALLOW_CIDR"
  setenv DB_CONNECT_TIMEOUT "${CFG_DB_CONNECT_TIMEOUT:-3}"
  setenv POSTGRES_PASSWORD "$CFG_POSTGRES_PASSWORD"
  setenv POSTGRES_REPLICATION_PASSWORD "$CFG_POSTGRES_REPLICATION_PASSWORD"
  # SECRET_KEY signs the app's JWTs (login sessions, MFA-setup links, invite/reset). It is
  # per-node from install.sh, so a joining node MUST adopt the cluster's — else its JWTs are
  # rejected on every other node (silent 401s / "Invalid setup link" behind a balancer, #36).
  # Guarded non-empty so an older primary that doesn't yet return it can't blank this node's key.
  [ -n "$CFG_SECRET_KEY" ] && setenv SECRET_KEY "$CFG_SECRET_KEY"
  # taranac-mfa API key (backend↔mfa auth). Per-node from install.sh; the backend setting that
  # references it replicates cluster-wide, so this node's taranac-mfa MUST adopt the cluster key
  # or backend→mfa calls 401 and Push/TOTP MFA fails here for every protocol (#13). Guarded
  # non-empty so an older primary that doesn't return it can't blank this node's key.
  [ -n "${CFG_TARANAC_MFA_API_KEY:-}" ] && setenv TARANAC_MFA_API_KEY "$CFG_TARANAC_MFA_API_KEY"
  # Patroni REST password. Authentication on port 8008 is unconditional — this node's
  # postgres-ha entrypoint REFUSES to start without it — and it must MATCH the cluster,
  # else this node's Patroni 401s every control call (switchover/restart) the cluster
  # makes to it. install.sh generated a per-node value here; adopt the cluster's over it.
  # Guarded non-empty so an older primary that does not return it cannot blank this node's.
  [ -n "${CFG_PATRONI_REST_PASSWORD:-}" ] && setenv PATRONI_REST_PASSWORD "$CFG_PATRONI_REST_PASSWORD"
  # The node's images MUST match the cluster's version; adopt it (warn if it changed).
  prev_ver="$(getenv TARANAC_VERSION)"
  if [ -n "$CFG_TARANAC_VERSION" ]; then
    [ -n "$prev_ver" ] && [ "$prev_ver" != "$CFG_TARANAC_VERSION" ] && \
      echo "ha-join: NOTE — adopting cluster version ${CFG_TARANAC_VERSION} (this node's .env had ${prev_ver})." >&2
    setenv TARANAC_VERSION "$CFG_TARANAC_VERSION"
  fi
  echo "ha-join: cluster config applied (cluster '${CFG_TARANAC_CLUSTER_NAME}', version ${CFG_TARANAC_VERSION})."
}

if [ -n "$BROKER" ]; then
  step "verifying the broker's certificate fingerprint against --pin"
  broker_pin
  ok "${BROKER} presents exactly the certificate the primary printed"
fi

# ═════════════════════════════════════════════════════════════════════════════
# WHAT THIS NODE ALREADY HOLDS — inspect, say it plainly, then decide
# ═════════════════════════════════════════════════════════════════════════════
# The normal case is a node that was installed the ordinary way and RUN. Its
# database cannot survive the join — Patroni clones a replica from the primary and
# two independently seeded Postgres instances cannot be merged — so the question is
# never "can we keep it" but "does anyone care about it". We answer that by
# counting, not by looking at whether a directory is empty.

# The archive helper has to be DEFINED before the block below calls it. The reorder
# that moved the backup ahead of the config fetch left the call above this
# definition, and bash resolves functions at CALL time from what it has already
# read — so it failed with `take_pre_join_backup: command not found`, the safety
# net silently did not exist, and only the fail-closed branch below kept a node
# with real data from being discarded without one. Caught on the stand.
BACKUP_DIR="${HERE}/pre-join-backup"

take_pre_join_backup() {  # 0 = an archive exists on this host, 1 = none was taken
  local out file path rc=0 i
  # The archive is produced by the product's own Backup & Recovery machinery — the
  # same one `taranac reset` uses before it wipes — so it is restorable by
  # `./taranac restore` with no special case for this situation.
  ${BASE_COMPOSE} up -d postgres api >/dev/null 2>&1 || return 1
  # The api's own healthcheck is the readiness signal — it already means "migrated,
  # seeded, serving". Re-deriving readiness here would be a second, weaker opinion.
  for i in $(seq 1 40); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' taranac-api 2>/dev/null || echo unknown)" = healthy ]; then break; fi
    progress $(( (i - 1) * 3 )) 120 "waiting for this node's api to be ready to take the backup"
    sleep 3
  done
  progress_done
  # stderr is CAPTURED, not inherited: a failure in here surfaces as a Python
  # traceback, and a traceback at an operator is never an answer — it is noise that
  # buries the one line that matters. We keep it, distil the last meaningful line
  # into BACKUP_ERROR for the caller to print, and leave the full text on disk.
  BACKUP_ERROR=""
  out="$(${BASE_COMPOSE} exec -T api python - 2>"${BACKUP_ERR_FILE}" <<'PY'
import asyncio


async def main() -> None:
    import app.models  # noqa: F401 — register every module's models in Base.metadata
    from app.config import settings as app_settings
    from app.core.audit.service import AuditService
    from app.core.crypto import load_master_key
    from app.database import async_session_factory
    from app.modules.core.settings.service import SettingsService
    from app.modules.infra.backup.service import BackupService

    load_master_key(app_settings)
    async with async_session_factory() as session:
        audit = AuditService(session)
        service = BackupService(session, SettingsService(session, audit=audit), audit)
        info = await service.create_backup(trigger="pre-ha-join", actor_username="ha-join")
        await session.commit()
        cfg = await service._cfg_service.load()  # noqa: SLF001 — where the archive landed
        print("%s\t%s/%s" % (info.filename, str(cfg.storage_path).rstrip("/"), info.filename))


asyncio.run(main())
PY
)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The last non-empty line of a Python traceback is the exception itself, which is
    # where the real cause lives ("pg_dump failed …: password authentication failed").
    BACKUP_ERROR="$(grep -vE '^\s*(File "|\s+\^+\s*$|Traceback)' "${BACKUP_ERR_FILE}" 2>/dev/null \
                     | sed '/^[[:space:]]*$/d' | tail -1 | cut -c1-200)"
    return 1
  fi
  file="$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E '^taranac-backup-.*\t' || true)"
  [ -n "$file" ] || return 1
  path="${file#*$'\t'}"; file="${file%%$'\t'*}"
  # Copy it OUT of the container's volume onto the host. The volume survives the
  # join, but a stack that is about to be re-created around a cloned database is a
  # poor place to leave the only copy of what it replaced.
  mkdir -p "$BACKUP_DIR"
  docker cp "taranac-api:${path}" "${BACKUP_DIR}/${file}" >/dev/null 2>&1 || return 1
  PRE_JOIN_BACKUP="${BACKUP_DIR}/${file}"
  return 0
}

# ── Safety archive — BEFORE any cluster value touches this node's .env ────────
# 🔑 ORDER IS LOAD-BEARING, and getting it wrong hangs the join with a misleading
# error. Applying the cluster configuration rewrites POSTGRES_PASSWORD in this .env
# to the CLUSTER's value, while this node's LOCAL Postgres still has its own. The
# backup runs through this node's api container, which reads that .env — so a backup
# attempted after the config is applied authenticates with the wrong password
# against its own database and retries until it gives up:
#     boot_migrate: DB not ready (attempt N/30): password authentication failed
# Found exactly that way on the stand. The archive is of the LOCAL database, needs
# nothing from the cluster, and so belongs here — before the first cluster value is
# written, and after the operator has confirmed the discard.
PRE_JOIN_BACKUP=""
BACKUP_ERROR=""
BACKUP_ERR_FILE="$(mktemp)"
if [ "$PG_POPULATED" -eq 1 ]; then
  if [ -n "$NO_BACKUP" ]; then
    note "--no-backup given: no safety archive is being taken"
  else
    step "backing this node up before discarding its database"
    if take_pre_join_backup; then
      ok "archive left on this node: ${PRE_JOIN_BACKUP}"
      note "restore it later with:  ./taranac restore ${PRE_JOIN_BACKUP}"
      note "it carries configuration (devices, users, settings) — not log records"
    elif local_data_is_material "$LOCAL_DEVICES" "$LOCAL_ADMINS" "$LOCAL_LOGS"; then
      # Refusing to destroy a node's real data without a net is the whole point of
      # taking one. --no-backup exists for the operator who took one another way.
      fail "the safety backup did not complete, and this node holds data that the join
  will discard. Nothing has been changed.
    ${BACKUP_ERROR:+reason: ${BACKUP_ERROR}}
    • look at what went wrong:  ${BASE_COMPOSE} logs --tail 50 api
    • or take one yourself in the UI (System → Backup), then re-run with --no-backup"
    else
      note "no backup was taken (this node holds nothing configured) — proceeding"
      [ -n "$BACKUP_ERROR" ] && note "reason: ${BACKUP_ERROR}"
    fi
  fi
fi

# ── Auto-fetch the cluster-wide config from an existing node (--primary) ──────
# So the operator does NOT hand-copy ~9 identical values (topology + shared
# secrets) into this .env. The join token authenticates the fetch over the API's
# TLS; the token already grants a full DB clone, so returning the DB creds + the JWT
# signing key (SECRET_KEY, #36) to its bearer is not new exposure. MASTER_KEY is the ONE thing never fetched — it stays
# strictly out-of-band (provided above). Self is appended to the membership lists.
if [ -n "$PRIMARY" ]; then
  echo "ha-join: fetching cluster config from ${PRIMARY} (authenticated by the join token)…"
  cfg="$(curl -fsSk --max-time 15 -X POST "https://${PRIMARY}/api/v1/cluster/join-config" \
           -H 'Content-Type: application/json' -d "{\"token\":\"${JOIN_TOKEN}\"}")" \
    || fail "could not fetch cluster config from ${PRIMARY}. Is its API up, reachable on 443, and the join token valid/unexpired?"
  eval "$(printf '%s' "$cfg" | python3 -c '
import json, sys, shlex
d = json.load(sys.stdin)
m = {"TARANAC_CLUSTER_NAME":"cluster_name","TARANAC_CLUSTER_ID":"cluster_id",
     "DB_HOSTS":"db_hosts","ETCD_HOSTS":"etcd_hosts",
     "ETCD_INITIAL_CLUSTER":"etcd_initial_cluster","PG_ALLOW_CIDR":"pg_allow_cidr",
     "DB_CONNECT_TIMEOUT":"db_connect_timeout","TARANAC_VERSION":"version",
     "ETCD_CLIENT_SCHEME":"etcd_client_scheme",
     "POSTGRES_PASSWORD":"postgres_password","POSTGRES_REPLICATION_PASSWORD":"postgres_replication_password",
     "SECRET_KEY":"secret_key","TARANAC_MFA_API_KEY":"taranac_mfa_api_key",
     "PATRONI_REST_PASSWORD":"patroni_rest_password"}
for env, field in m.items():
    print("CFG_%s=%s" % (env, shlex.quote(str(d.get(field, "")))))
')" || fail "could not parse the cluster config returned by ${PRIMARY}."
  apply_cluster_config
fi

# ── Broker path: the same values, over the pinned channel ────────────────────
# The broker serves EXACTLY the API's _JOIN_CONFIG_KEYS set and nothing wider (see
# cluster-broker.py::CONFIG_KEYS) plus the identity the operator declared on the
# primary — so from here down the two routes are indistinguishable, and they share
# apply_cluster_config() above rather than each growing their own copy of it.
if [ -n "$BROKER" ]; then
  step "fetching the cluster configuration from the broker"
  broker_post /join/config '{}'
  eval "$(JSON_FILE="$BROKER_RESP" python3 - <<'PY'
import json, os, shlex, sys

with open(os.environ["JSON_FILE"], encoding="utf-8") as fh:
    cfg = json.load(fh).get("config") or {}
# Every key the shell reads is emitted, present or not, so `set -u` catches a broker
# that answered with a shape we did not expect instead of silently using "".
for key in (
    "TARANAC_CLUSTER_NAME", "TARANAC_CLUSTER_ID",
    "DB_HOSTS", "ETCD_HOSTS", "ETCD_INITIAL_CLUSTER",
    "ETCD_CLIENT_SCHEME", "PG_ALLOW_CIDR", "DB_CONNECT_TIMEOUT", "TARANAC_VERSION",
    "POSTGRES_PASSWORD", "POSTGRES_REPLICATION_PASSWORD", "SECRET_KEY",
    "TARANAC_MFA_API_KEY", "PATRONI_REST_PASSWORD",
):
    sys.stdout.write("CFG_%s=%s\n" % (key, shlex.quote(str(cfg.get(key, "")))))
for key in ("NODE_NAME", "NODE_ADDRESS", "NODE_ROLE",
            # Not config — narration. "1" means the wizard is driving on the
            # primary, so this host prints no next-step commands of its own.
            "WIZARD_DRIVEN"):
    sys.stdout.write("BRK_%s=%s\n" % (key, shlex.quote(str(cfg.get(key, "")))))
PY
)" || fail "the broker's configuration response could not be parsed. Check the broker's console on the primary."

  [ -n "$BRK_NODE_NAME" ] && [ -n "$BRK_NODE_ADDRESS" ] \
    || fail "the broker did not say who this node is meant to be (NODE_NAME/NODE_ADDRESS empty).
  Re-run './taranac cluster add-node --address <this node>' on the primary."
  # ── Is this the machine the token was issued FOR? ─────────────────────────
  # 🔑 A join token is a bearer credential: whoever holds it, the broker serves. With
  # eight terminals open it is not hard to paste the command meant for one node into
  # another — and the consequence is not a harmless error. Observed on the stand: the
  # command for 10.0.0.4 was run on 10.0.0.2, a HEALTHY member; it accepted an
  # identity that was not its own and discarded its database before anything stopped
  # it. The node itself is the only party that can catch this, because it is the only
  # one that knows where it is standing.
  #
  # Two independent signals, checked before anything is touched:
  #   · this machine already carries a cluster identity that DISAGREES — unambiguous,
  #     both values are the cluster's own naming, and no NAT can explain it away;
  #   · the address does not belong to any interface here — strong, but a node behind
  #     NAT is reached at an address it does not itself hold, so this one is a refusal
  #     the operator can override rather than a hard stop.
  local_name="$(getenv TARANAC_NODE_NAME)"
  local_addr="$(getenv NODE_ADDRESS)"
  if [ -n "$local_addr" ] && [ "$local_addr" != "$BRK_NODE_ADDRESS" ]; then
    fail "this command was issued for a DIFFERENT machine — nothing has been changed.
  the token names:   ${BRK_NODE_NAME} (${BRK_NODE_ADDRESS})
  this host is:      ${local_name:-<unnamed>} (${local_addr})
  You are on the wrong terminal. Run it on ${BRK_NODE_ADDRESS}, or issue a command for
  THIS host on the primary:
    ./taranac cluster add-node --address ${local_addr}"
  fi
  if [ -z "$local_addr" ] && ! ip -o addr show 2>/dev/null | grep -qw "${BRK_NODE_ADDRESS}"; then
    if [ -z "${ADDRESS_NOT_LOCAL_OK:-}" ]; then
      fail "the token names ${BRK_NODE_NAME} (${BRK_NODE_ADDRESS}), but no interface on this
  host has that address — nothing has been changed.
  Almost always this means the command was pasted on the wrong machine. Run it on
  ${BRK_NODE_ADDRESS} instead.
  If this host really is reached at ${BRK_NODE_ADDRESS} from the cluster (it is behind
  NAT, or the address is on a router in front of it), say so explicitly and re-run:
    ADDRESS_NOT_LOCAL_OK=1 ./ha-join.sh --broker … --token … --pin …"
    fi
    note "${BRK_NODE_ADDRESS} is not an address of this host — proceeding because ADDRESS_NOT_LOCAL_OK is set"
  fi
  ok "this host is ${BRK_NODE_NAME} (${BRK_NODE_ADDRESS}), as the token says"

  # A witness runs etcd only — no Postgres, no master key. Sending it down the replica
  # path would clone a database onto a machine that is not supposed to have one.
  if [ "$BRK_NODE_ROLE" = witness ]; then
    fail "the primary issued this token for a WITNESS, not a replica. On the witness host run:
    ./witness-join.sh --broker ${BROKER} --token <the same token> --pin ${PIN}"
  fi
  NODE_NAME="$BRK_NODE_NAME"
  NODE_ADDRESS="$BRK_NODE_ADDRESS"
  JOIN_TOKEN="$TOKEN"       # the same secret registers this node in the roster
  ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"
  ok "this node joins as '${NODE_NAME}' (${NODE_ADDRESS}) of cluster '${CFG_TARANAC_CLUSTER_NAME}', version ${CFG_TARANAC_VERSION}"
  apply_cluster_config
fi


# Its own step, because it is its own decision. Left inside the previous step, a
# refusal here reported "failed at step: fetching the cluster configuration" — which
# is a lie about a fetch that succeeded, and sends the operator to the wrong machine.
step "checking the cluster is safe for this node to join"

# Cluster-wide HA settings must be present now — either fetched via --primary above,
# or hand-copied from the primary's .env (the manual path).
for k in TARANAC_CLUSTER_NAME DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER POSTGRES_REPLICATION_PASSWORD; do
  [ -n "$(getenv "$k")" ] || fail "$k is not set in .env. Pass --primary <an existing node's address> to fetch the cluster config automatically, or copy the cluster-wide HA settings from the primary's .env by hand (see this script's header)."
done

# ── Witness guard (ha.md §8) — REFUSE a 2-node cluster with no arbiter ────────
# etcd must have >= 3 voting members. For 2 DB nodes that means a 3rd arbiter in a
# SEPARATE failure domain. We can verify the COUNT here; the separate-domain part
# is a runbook MUST (a co-located arbiter is useless).
MEMBERS=$(getenv ETCD_INITIAL_CLUSTER); MCOUNT=$(printf '%s' "$MEMBERS" | tr ',' '\n' | grep -c '=')
[ "$MCOUNT" -ge 3 ] || fail "ETCD_INITIAL_CLUSTER lists $MCOUNT etcd member(s); HA REQUIRES >= 3 (the DB nodes + a witness arbiter in a SEPARATE failure domain). A 2-node cluster without a witness cannot reach quorum on a partition → split-brain (ha.md §8). Add a 3rd etcd member before joining.
  With the wizard, that is a single command on the primary, run BEFORE this one:
    ./taranac cluster add-witness --address <a third host>"
ok "cluster '$(getenv TARANAC_CLUSTER_NAME)' declares ${MCOUNT} etcd members — quorum is possible"

if [ -n "$BROKER" ]; then
  step "receiving the cluster's wrapped key material"
  broker_post /join/secrets '{}'
  MK_BLOB="$(json_field "$BROKER_RESP" master_key)"
  [ -n "$MK_BLOB" ] || fail "the broker returned no master key.
  Its .env has no usable MASTER_KEY, which means the primary itself cannot decrypt
  its own stored secrets. Fix that on the primary before adding nodes."
  # Straight into a file, never a $(...) capture: the wrap is binary and the plaintext
  # must not become an argv or an environment value in any other process.
  unwrap_secret "$TOKEN" "$MK_BLOB" > "${WORK}/master.key" \
    || fail "the cluster's master key could not be unwrapped (see the message above)."
  MASTER_KEY="$(cat "${WORK}/master.key")"
  [ -n "$MASTER_KEY" ] || fail "the unwrapped master key is empty — refusing to join with a key that would make every stored secret undecryptable on this node."
  ok "master key unwrapped (it was never in plaintext on the wire)"

  MFA_BLOB="$(json_field "$BROKER_RESP" mfa_enckey)"
  if [ -n "$MFA_BLOB" ]; then
    unwrap_secret "$TOKEN" "$MFA_BLOB" > "${WORK}/mfa.enckey" \
      || fail "the shared mfa key could not be unwrapped (see the message above)."
    # base64 here rather than in the unwrap: the mfa key is raw bytes and may contain
    # NULs, which a shell capture would truncate. The .env carries it base64-encoded.
    TARANAC_MFA_ENCKEY="$(base64 -w0 "${WORK}/mfa.enckey" 2>/dev/null || base64 "${WORK}/mfa.enckey" | tr -d '\n')"
    ok "shared mfa key unwrapped (Push tokens enrolled on any node decrypt here)"
  else
    note "the primary carries no shared mfa key — this node's Push MFA key stays node-local (ha.md §12)"
  fi

  # ── The etcd CA, so THIS node can admit the next one ──────────────────────
  # The CA used to live on exactly one disk and was not in the backup, so losing
  # that machine meant the cluster could never grow or replace a node again — a
  # single point of failure inside the feature whose whole purpose is surviving one.
  # Every node now carries it, which is what makes "any node can act as the primary"
  # true in practice rather than only on the status line.
  CA_KEY_BLOB="$(json_field "$BROKER_RESP" etcd_ca_key)"
  CA_CRT_BLOB="$(json_field "$BROKER_RESP" etcd_ca_crt)"
  if [ -n "$CA_KEY_BLOB" ] && [ -n "$CA_CRT_BLOB" ]; then
    mkdir -p "$HERE/config/etcd-ca"
    umask 077
    unwrap_secret "$TOKEN" "$CA_KEY_BLOB" > "$HERE/config/etcd-ca/ca.key" \
      || fail "the etcd CA key could not be unwrapped (see the message above)."
    unwrap_secret "$TOKEN" "$CA_CRT_BLOB" > "$HERE/config/etcd-ca/ca.crt" \
      || fail "the etcd CA certificate could not be unwrapped (see the message above)."
    chmod 600 "$HERE/config/etcd-ca/ca.key"; chmod 644 "$HERE/config/etcd-ca/ca.crt"
    ok "etcd CA received — this node can admit further nodes on its own"
  else
    note "the primary served no etcd CA — only IT will be able to admit further nodes"
  fi
fi

# ── The local database: back it up, then discard it ──────────────────────────
# 🔑 DELIBERATELY LAST among the remote steps. Everything this node needs from the
# broker — the configuration, the identity check, the wrapped key material — has
# already been fetched and verified by the time anything here is destroyed. The
# reverse order looked harmless and was not: a run that discarded the database and
# THEN failed to reach the broker left a node with no data, no cluster and no way
# forward, from a channel that is one-shot and already closed. Seen on the stand.
# Nothing irreversible happens until every reversible thing has succeeded.
# A joining node is CLONED by Patroni into a clean volume, so the volume has to be
# empty before the stack comes up. It was already inspected and (when it holds
# anything) explicitly confirmed at the top of this script — what is left here is
# the WORK, and the operator never types a `docker volume` command to get it done.

if [ "$PG_POPULATED" -eq 1 ]; then
  step "discarding this node's local database so Patroni can clone it"
  # The whole stack goes down, not just postgres: the api/daemons hold connections to
  # a database that is about to cease to exist, and the HA overlay is included so a
  # retry after a partially finished join also stops the etcd this script started.
  ${COMPOSE} down --remove-orphans >/dev/null 2>&1 || ${BASE_COMPOSE} down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm "$PG_VOL" >/dev/null 2>&1 || true
  # Observable outcome, asserted: the volume is gone. `docker volume rm` is quietly
  # a no-op when a stopped container still references the volume, and a half-emptied
  # PGDATA is exactly what makes a Patroni clone fail in a confusing way an hour later.
  if docker volume inspect "$PG_VOL" >/dev/null 2>&1; then
    fail "the Postgres volume '${PG_VOL}' could not be removed — something is still using it.
  Find it with:   docker ps -a --filter volume=${PG_VOL}
  Remove those containers, then re-run this command (the backup above is kept)."
  fi
  ok "'${PG_VOL}' removed — this node starts from a clean data directory"
  PG_POPULATED=0
fi

# ── etcd data volume must be EMPTY too — reconcile stale membership (#32) ──────
# Symmetric to the pg_data guard above: a joining node's etcd must BOOTSTRAP FRESH into
# the running cluster (member add + ETCD_INITIAL_CLUSTER_STATE=existing, set below). A
# leftover taranac_etcd_data from a PRIOR cluster makes this node's etcd resume that old
# member — its stored cluster-id will NOT match the cluster we are joining, so etcd
# refuses to start / never joins quorum and the whole join wedges with no obvious cause.
# Unlike pg_data (which may hold real data → hard refuse), etcd_data on a joining node is
# pure membership state with nothing to preserve, AND we only get here once pg_data is
# confirmed empty — i.e. there was no successful prior join, so no live local cluster to
# protect. So RECONCILE rather than refuse: clear a non-empty volume so etcd starts clean
# (same class as the mfa enckey reconcile below, #35).
ETCD_VOL="taranac_etcd_data"
if docker volume inspect "$ETCD_VOL" >/dev/null 2>&1 && \
   [ -n "$(docker run --rm -v "${ETCD_VOL}:/d" "$PROBE_IMAGE" sh -c 'ls -A /d 2>/dev/null')" ]; then
  echo "ha-join: reconciling etcd data — '${ETCD_VOL}' is not empty (stale membership from a prior cluster); clearing it so this node's etcd bootstraps fresh into the running cluster (its cluster-id would otherwise mismatch and the join would wedge)."
  docker stop taranac-etcd >/dev/null 2>&1 || true
  docker run --rm -v "${ETCD_VOL}:/d" "$PROBE_IMAGE" sh -c 'rm -rf /d/* /d/.[!.]* /d/..?* 2>/dev/null; exit 0' \
    || fail "could not clear the stale etcd data volume '${ETCD_VOL}'. Remove it manually and re-run: docker volume rm ${ETCD_VOL}"
fi

# ── Broker path: the wrapped cluster secrets ─────────────────────────────────
# MASTER_KEY (the Fernet KEK) and the shared taranac-mfa key travel AES-256-GCM'd
# under HKDF(token,"…wrap-v1") — under the TLS, not instead of it. TLS protects the

echo "ha-join: joining '${NODE_NAME}' (${NODE_ADDRESS}) to cluster '$(getenv TARANAC_CLUSTER_NAME)'…"

# ── Provision this node's identity + MASTER_KEY into .env ─────────────────────
setenv TARANAC_NODE_NAME "$NODE_NAME"
setenv NODE_ADDRESS "$NODE_ADDRESS"
setenv ETCD_NAME "$ETCD_NAME"
setenv MASTER_KEY "$MASTER_KEY"

# Shared taranac-mfa enckey — OOB like MASTER_KEY, so Push tokens enrolled on ANY node
# decrypt on THIS one (#13, ha.md §12). Prefer the env, else the seed's carried
# cluster-secrets/mfa.enckey. Optional: absent ⇒ this node's mfa self-generates a
# node-local key (cross-node Push won't work; a warning, not a hard failure — mfa stays
# runtime-decoupled and DMZ-standalone-safe).
MFA_ENCKEY_B64="${TARANAC_MFA_ENCKEY:-}"
if [ -z "$MFA_ENCKEY_B64" ] && [ -s "$HERE/config/cluster-secrets/mfa.enckey" ]; then
  MFA_ENCKEY_B64="$(base64 -w0 "$HERE/config/cluster-secrets/mfa.enckey" 2>/dev/null || base64 "$HERE/config/cluster-secrets/mfa.enckey" | tr -d '\n')"
fi
if [ -n "$MFA_ENCKEY_B64" ]; then
  setenv TARANAC_MFA_ENCKEY "$MFA_ENCKEY_B64"
  echo "ha-join: shared mfa enckey provisioned (Push tokens decrypt on every node)."
  # The mfa entrypoint provisions the key ABSENT-ONLY (byte-for-byte unchanged, so a
  # DMZ-standalone mfa keeps self-generating its own key — D4, ha.md §12). On the intended
  # join flow this node's mfa has never started (install.sh --no-start), the volume is
  # empty, and the shared key lands. But if this node was EVER started standalone first,
  # mfa already self-generated a node-local enckey; absent-only then PINS that stale key
  # and the shared one never takes → the setup-link / Push tokens minted on another node
  # fail to decrypt here ("Invalid setup link"). A joining node is cloned fresh and holds
  # NO legitimate local Push tokens, so — symmetric to the pg_data guard above (#32, which
  # refuses a dirty DB volume) — ha-join RECONCILES the mfa enckey: if the volume holds a
  # DIFFERENT key, drop it so the entrypoint adopts the shared cluster key on the up -d below.
  if docker volume inspect taranac_mfa_data >/dev/null 2>&1 && \
     [ -n "$(docker run --rm -v taranac_mfa_data:/d "$PROBE_IMAGE" sh -c 'ls -A /d/enckey 2>/dev/null')" ]; then
    existing_enckey_b64="$(docker run --rm -v taranac_mfa_data:/d "$PROBE_IMAGE" base64 /d/enckey 2>/dev/null | tr -d '\n' || true)"
    if [ "$existing_enckey_b64" = "$MFA_ENCKEY_B64" ]; then
      echo "ha-join:   taranac_mfa_data already holds the shared mfa enckey — nothing to reconcile."
    else
      echo "ha-join: reconciling mfa enckey — taranac_mfa_data holds a DIFFERENT (node-local) key; removing it so the shared cluster key takes effect. This drops any Push tokens enrolled locally on THIS node, which a freshly-joining node must not keep."
      # Stop the mfa container first if it is running (a prior standalone start), then clear
      # the stale key. The up -d at the end of this script recreates mfa → entrypoint sees
      # no key → provisions the shared one from TARANAC_MFA_ENCKEY.
      docker stop taranac-mfa >/dev/null 2>&1 || true
      docker run --rm -v taranac_mfa_data:/d "$PROBE_IMAGE" rm -f /d/enckey \
        || fail "could not remove the stale mfa enckey from taranac_mfa_data. Remove it manually and re-run: docker run --rm -v taranac_mfa_data:/d "$PROBE_IMAGE" rm -f /d/enckey"
    fi
  fi
else
  echo "ha-join: NOTE — no shared mfa enckey (pass TARANAC_MFA_ENCKEY or place config/cluster-secrets/mfa.enckey); this node's Push MFA key stays node-local (ha.md §12)."
fi

# ── Reconcile the daemons' master_key volume (Fernet KEK) — same class as the enckey above ──
# The tacacs/radius/nac daemons read the KEK from a FILE in the shared `master_key` volume,
# provisioned ABSENT-ONLY by their entrypoint from the MASTER_KEY env (set into .env above). If
# this node was EVER started standalone first, that volume already holds this node's ORIGINAL
# (node-local) key; the absent-only entrypoint then PINS it and the cluster MASTER_KEY never
# takes — so the daemons decrypt every Fernet field (device secrets, enable passwords) with the
# WRONG key while the API (which reads MASTER_KEY from env directly) is fine. A joining node is
# cloned fresh and holds NO legitimate local secrets, so — symmetric to the pg_data + enckey
# guards — if the volume holds a DIFFERENT key, drop it so the entrypoints re-provision the
# cluster KEK on the up -d below. (Volume name = compose project `taranac` + `master_key`.)
MK_VOL=taranac_master_key
if docker volume inspect "$MK_VOL" >/dev/null 2>&1 && \
   [ -n "$(docker run --rm -v "${MK_VOL}:/d" "$PROBE_IMAGE" sh -c 'ls -A /d/master_key 2>/dev/null')" ]; then
  existing_mk="$(docker run --rm -v "${MK_VOL}:/d" "$PROBE_IMAGE" cat /d/master_key 2>/dev/null | tr -d '\r\n' || true)"
  if [ "$existing_mk" = "$MASTER_KEY" ]; then
    echo "ha-join:   ${MK_VOL} already holds the cluster MASTER_KEY — nothing to reconcile."
  else
    echo "ha-join: reconciling daemon KEK — ${MK_VOL} holds a DIFFERENT (node-local) master key; removing it so the tacacs/radius/nac entrypoints adopt the cluster MASTER_KEY on the up -d below. (Without this, those daemons decrypt device/enable secrets with the wrong key — Push MFA works via the API but enable-password auth and device-key reads fail on this node.)"
    docker stop taranac-tacacs taranac-radius taranac-nac >/dev/null 2>&1 || true
    docker run --rm -v "${MK_VOL}:/d" "$PROBE_IMAGE" rm -f /d/master_key \
      || fail "could not remove the stale master key from ${MK_VOL}. Remove it manually and re-run: docker run --rm -v ${MK_VOL}:/d "$PROBE_IMAGE" rm -f /d/master_key"
  fi
fi
# Authoritative HA marker — the bundle tooling (./taranac, install.sh, taranac-update.sh)
# reads this to ALWAYS merge docker-compose.ha.yml on this node (never base-only, which
# would start a 2nd writable Postgres on the Patroni PGDATA → split-brain). ha.md §13 A.
setenv TARANAC_HA 1

# ── etcd client-TLS (one-way) — must MATCH the cluster (secure default, ha.md §7.3) ────
# Secure etcd (client TLS) is the DEFAULT for a new cluster (#30), but a joining node
# always FOLLOWS the cluster it is joining: the client scheme is derived from what the
# primary reported (--primary fetches etcd_client_scheme), or forced with --client-tls for
# a MANUAL (no --primary) join to a TLS cluster. Joining a plaintext cluster stays http
# (back-compat). An http node CANNOT speak to an https-client cluster, so if the cluster is
# https we REQUIRE this node's OOB-carried leaf to be in place and persist the knobs +
# point etcdctl at the CA.
CLIENT_SCHEME=http
if [ "${CFG_ETCD_CLIENT_SCHEME:-}" = https ] || [ -n "$CLIENT_TLS_FLAG" ]; then CLIENT_SCHEME=https; fi
ETCDCTL_MOUNT=""; ETCDCTL_TLS_ARGS=""

# ── Broker path: a CSR instead of the SCP ────────────────────────────────────
# This node generates its OWN key and asks the seed to sign a request for it. The
# private key never travels, and a signed
# certificate is not a secret — which is what removes the "copy three TLS files to
# every node by hand" step entirely (docs/spec/backend/infra/cluster.md, "CSR instead of SCP").
#
# We do NOT send a SAN: the addresses a certificate may carry are the SIGNER's
# decision. A CSR is authored by the party being authenticated, so honouring its
# subjectAltName would let a joining node mint itself a certificate for the
# primary's address. `ha-etcd-ca.sh sign-csr` ignores anything the request embeds.
if [ -n "$BROKER" ] && [ "$CLIENT_SCHEME" = https ]; then
  step "obtaining this node's etcd certificate (key stays here, only a request travels)"
  TLS_SRC="$HERE/config/etcd-tls"
  mkdir -p "$TLS_SRC" 2>/dev/null || true
  [ -w "$TLS_SRC" ] || fail "cannot write to '${TLS_SRC}' — it is not writable by $(id -un) (uid $(id -u)).
  Docker most likely created it as root on an earlier stack start. Fix it and re-run:
    sudo chown -R \"\$(id -u):\$(id -g)\" '${TLS_SRC}'"
  CSR_PATH="$(./ha-etcd-ca.sh make-csr "$TLS_SRC" "taranac-etcd-${NODE_NAME}")" \
    || fail "could not generate this node's etcd key/CSR in ${TLS_SRC}."
  [ -s "$CSR_PATH" ] || fail "ha-etcd-ca.sh make-csr produced no request at '${CSR_PATH}'."
  CSR_BODY="$(CSR_FILE="$CSR_PATH" python3 -c '
import json, os, sys
with open(os.environ["CSR_FILE"], encoding="utf-8") as fh:
    sys.stdout.write(json.dumps({"csr": fh.read()}))
')"
  broker_post /join/sign-csr "$CSR_BODY"
  json_field "$BROKER_RESP" certificate > "${TLS_SRC}/etcd-server.crt"
  json_field "$BROKER_RESP" ca          > "${TLS_SRC}/ca.crt"
  chmod 644 "${TLS_SRC}/etcd-server.crt" "${TLS_SRC}/ca.crt"
  # Observable outcome: a certificate that actually matches the key we kept, signed
  # by the CA we were handed. Writing two files proves nothing — a truncated
  # response would produce two files and an etcd that fails its TLS handshake hours
  # later, which is the worst way to learn about it.
  grep -q 'BEGIN CERTIFICATE' "${TLS_SRC}/etcd-server.crt" \
    || fail "the broker's answer did not contain a certificate. Check its console on the primary."
  openssl verify -CAfile "${TLS_SRC}/ca.crt" "${TLS_SRC}/etcd-server.crt" >/dev/null 2>&1 \
    || fail "the signed certificate does not verify against the CA the broker returned."
  [ "$(openssl x509 -noout -pubkey -in "${TLS_SRC}/etcd-server.crt" 2>/dev/null)" \
    = "$(openssl pkey -pubout -in "${TLS_SRC}/etcd-server.key" 2>/dev/null)" ] \
    || fail "the signed certificate does not match this node's private key in ${TLS_SRC}/etcd-server.key.
  Delete that key and re-run so a fresh request is made for a fresh key."
  rm -f "$CSR_PATH"
  ok "etcd certificate signed for $(openssl x509 -noout -ext subjectAltName -in "${TLS_SRC}/etcd-server.crt" 2>/dev/null | tail -1 | tr -d ' ')"
fi

if [ "$CLIENT_SCHEME" = https ]; then
  TLS_SRC="$HERE/config/etcd-tls"
  for f in ca.crt etcd-server.crt etcd-server.key; do
    [ -s "$TLS_SRC/$f" ] || fail "this cluster uses etcd client-TLS but $TLS_SRC/$f is missing (ha.md §7.3). Provision this node's leaf into config/etcd-tls/ (OOB) BEFORE joining:
    • if this member was in ETCD_INITIAL_CLUSTER at convert time, the seed pre-issued it —
      copy the seed's  config/cluster-secrets/etcd/${NODE_NAME}/  into THIS node's  config/etcd-tls/ ;
    • if you are ADDING this node later, issue its leaf ON THE SEED first, then carry it here:
      ./ha-etcd-ca.sh issue config/etcd-ca /tmp/${NODE_NAME}-tls taranac-etcd-${NODE_NAME} ${NODE_ADDRESS},127.0.0.1,localhost
    then re-run this command."
  done
  setenv ETCD_CLIENT_SCHEME https
  setenv ETCD_SERVER_CERT_FILE /etc/etcd/tls/etcd-server.crt
  setenv ETCD_SERVER_KEY_FILE  /etc/etcd/tls/etcd-server.key
  setenv ETCD_CLIENT_CACERT    /etc/etcd/tls/ca.crt
  # The host-side etcdctl calls below run in a throwaway container (local etcd isn't up
  # yet) so they don't inherit the etcd service's ETCDCTL_* env — mount the CA + pass it.
  ETCDCTL_MOUNT="-v $TLS_SRC:/tls:ro"; ETCDCTL_TLS_ARGS="--cacert=/tls/ca.crt"
  echo "ha-join: etcd client channel = https (one-way, CA-verified)."
else
  setenv ETCD_CLIENT_SCHEME http
  # Diagnostics gap (secure-default UX): if the client scheme resolved to http but the peer
  # channel looks https (member URLs carry =https://), this is very likely a secure-default
  # cluster where a MANUAL join forgot --client-tls (or --primary, which auto-detects the
  # scheme). Left as-is, the etcdctl health probe below would talk http to an https-client
  # etcd and die with a misleading "no reachable etcd endpoint" — blaming reachability, not
  # the missing flag. So HINT loudly up front. (We do NOT auto-enable: a legacy peer-https /
  # client-http cluster is legitimate, so the client scheme must stay operator-chosen.)
  case ",$(getenv ETCD_INITIAL_CLUSTER)," in
    *"=https://"*)
      echo "ha-join: NOTE — etcd client scheme is http, but the cluster's peer URLs are https. If this is a secure-etcd (TLS) cluster, this manual join needs --client-tls (with this node's OOB leaf in config/etcd-tls/), or use --primary <a node> to auto-detect the scheme. Proceeding http — if the next step fails with 'no reachable etcd endpoint', this is why." >&2 ;;
  esac
fi

# ── Register in etcd: GROW the running cluster (don't re-declare it whole) ─────
# ha-convert drops members that have not started yet (a declared-but-absent member
# pins the etcd cluster version at the 3.0.0 default → Patroni refuses the DCS as
# "too old" and never comes up). So this node is NOT in the running cluster yet: add
# it to the LIVE cluster now, and start our etcd as an EXISTING member (joining the
# running quorum) rather than bootstrapping a second cluster. Idempotent — if we are
# already a member (a re-run), leave membership as-is.
ETCD_IMAGE="quay.io/coreos/etcd:v3.5.17"
step "registering '${ETCD_NAME}' (${NODE_ADDRESS}) as a member of the running etcd cluster"
ETCD_EP=""
for hp in $(getenv ETCD_HOSTS | tr ',' ' '); do
  case "$hp" in *"${NODE_ADDRESS}"*) continue ;; esac   # skip our own endpoint (not up yet)
  if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="${CLIENT_SCHEME}://${hp}" $ETCDCTL_TLS_ARGS endpoint health >/dev/null 2>&1; then
    ETCD_EP="${CLIENT_SCHEME}://${hp}"; break
  fi
done
[ -n "$ETCD_EP" ] || fail "no reachable etcd endpoint in ETCD_HOSTS to add this member — is the primary or the witness up?"
# Peer scheme for this node's own member URL. The --primary path already set PEER_SCHEME
# from the fetched cluster config; a manual (no --primary) join derives it from the .env
# member list (https:// ⇒ https), falling back to ETCD_PEER_SCHEME. Secure etcd is the
# default (#30) but this node matches whatever the cluster's member URLs advertise (§7.2).
if [ -z "${PEER_SCHEME:-}" ]; then
  case ",$(getenv ETCD_INITIAL_CLUSTER)," in *"=https://"*) PEER_SCHEME=https ;; *) PEER_SCHEME="${ETCD_PEER_SCHEME:-http}" ;; esac
fi
# Persist the peer-TLS opt-in into THIS node's .env so its overlay compose brings etcd
# up with the same scheme as the cluster (https ⇒ auto-TLS on; http ⇒ off). Without this
# an https cluster would get an http etcd from the default and the Raft ring would break.
setenv ETCD_PEER_SCHEME "$PEER_SCHEME"
if [ "$PEER_SCHEME" = https ]; then setenv ETCD_PEER_AUTO_TLS true; else setenv ETCD_PEER_AUTO_TLS false; fi
# Idempotency check is scheme-agnostic (match host:2380) so a scheme change never causes
# a duplicate add against an existing member.
if docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$ETCD_EP" $ETCDCTL_TLS_ARGS member list 2>/dev/null | grep -q "${NODE_ADDRESS}:2380"; then
  echo "ha-join:   already an etcd member — leaving membership as-is."
else
  docker run --rm $ETCDCTL_MOUNT "$ETCD_IMAGE" etcdctl --endpoints="$ETCD_EP" $ETCDCTL_TLS_ARGS \
    member add "$ETCD_NAME" --peer-urls="${PEER_SCHEME}://${NODE_ADDRESS}:2380" >/dev/null \
    || fail "etcdctl member add failed via ${ETCD_EP} — check etcd reachability and that ${ETCD_NAME}/${NODE_ADDRESS} is not already a member with a different peer URL."
fi
# Our etcd must JOIN the existing cluster, not bootstrap a new one.
setenv ETCD_INITIAL_CLUSTER_STATE existing

# ── Bring up the stack WITH the HA overlay → Patroni clones this node ─────────
step "starting the stack with the HA overlay (Patroni will clone this node from the primary)"
${COMPOSE} pull >/dev/null 2>&1 || true
${COMPOSE} up -d

# ── Wait until the local Postgres is a streaming replica ─────────────────────
# The observable outcome of a join. NOT "the container is up" and not "the node is
# in the roster": a node that looks healthy while it cannot actually follow the
# primary is worse than one that failed loudly, because nobody finds out until the
# failover. pg_is_in_recovery() on the local Postgres is the cheapest true proof.
step "waiting for Patroni to clone and stream this node"
streaming=""
PROGRESS_I=0
for _ in $(seq 1 60); do
  progress $(( PROGRESS_I * 5 )) 300 "Patroni is cloning this node from the primary"
  PROGRESS_I=$((PROGRESS_I + 1))
  if docker exec taranac-db psql -U taranac -d taranac -tAc "select pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
    streaming=1; progress_done; break
  fi
  sleep 5
done
progress_done
[ -n "$streaming" ] || fail "this node did not come up as a streaming replica within the timeout. Check: docker logs taranac-db (Patroni), the primary is reachable on DB_HOSTS, and POSTGRES_REPLICATION_PASSWORD matches the primary."
ok "this node is in recovery and streaming from the primary"

# ── Redeem the join token so the node registers in the roster ────────────────
step "redeeming the join token so this node appears in the cluster roster"
registered=""
for _ in $(seq 1 30); do
  if ${COMPOSE} exec -T api python -m app.scripts.cluster register --token "${JOIN_TOKEN}" 2>/dev/null; then
    registered=1; break
  fi
  sleep 3
done
[ -n "$registered" ] || fail "the node is streaming but the token redeem did not complete. Once the api is up, run:
       ./taranac cluster register --token ${JOIN_TOKEN}"
ok "registered in the roster"

# ── Tell the broker, because it cannot see any of the above ──────────────────
step "reporting the outcome to the broker"
broker_complete true "streaming replica, registered in the roster"
[ -n "$BROKER" ] && ok "the primary's console now shows this join as complete"

# What to print at the end. A printed command means "there is something for you to
# do". When the wizard is driving, there is nothing: the primary verifies this join
# on its own console and tells the operator what comes next. Repeating a "verify
# with…" here would send them to a second console to re-check a result the first one
# is already asserting. The backup path is NOT a command and always stays — it is a
# fact about this machine that exists nowhere else.
if [ "${BRK_WIZARD_DRIVEN:-}" = "1" ]; then
  echo "ha-join: done — this node is a streaming replica of the cluster."
else
  echo "ha-join: done. Verify with: ./taranac cluster status"
fi
[ -n "$PRE_JOIN_BACKUP" ] && echo "ha-join: the pre-join backup of this node's previous database is at ${PRE_JOIN_BACKUP}"
exit 0
