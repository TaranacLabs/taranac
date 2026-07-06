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
#   POSTGRES_PASSWORD, POSTGRES_REPLICATION_PASSWORD, PG_ALLOW_CIDR, SECRET_KEY
# (POSTGRES_PASSWORD/REPLICATION must MATCH the primary — they are the cluster's
# app + replication credentials. SECRET_KEY must MATCH too — it signs the app's JWTs;
# a per-node value means login sessions / MFA-setup links break across nodes, #36.)
#
# Usage (on the NEW node, from the bundle dir). With --primary, ha-join FETCHES the
# cluster-wide config from an existing node over the token-authenticated API, so you
# do NOT hand-copy it — the only thing you still provide out-of-band is MASTER_KEY:
#   MASTER_KEY=<the cluster master key>  \
#   ./ha-join.sh --node-name node-2 --node-address 10.0.0.2 \
#     --primary <an existing node's address> --join-token <secret>
# (The primary's `taranac cluster join-token` prints this exact command for you.)
# Without --primary, the cluster-wide settings must be hand-copied into .env first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ENV_FILE=.env
COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

NODE_NAME=""; NODE_ADDRESS=""; JOIN_TOKEN=""; ETCD_NAME=""; PRIMARY=""; CLIENT_TLS_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node-name)    NODE_NAME="$2"; shift 2 ;;
    --node-address) NODE_ADDRESS="$2"; shift 2 ;;
    --join-token)   JOIN_TOKEN="$2"; shift 2 ;;
    --etcd-name)    ETCD_NAME="$2"; shift 2 ;;   # defaults to the node name
    --primary)      PRIMARY="$2"; shift 2 ;;     # an existing node's address to fetch cluster config from
    --client-tls)   CLIENT_TLS_FLAG=1; shift ;;  # force etcd client-TLS (manual/no-primary joins)
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
m = {"TARANAC_CLUSTER_NAME":"cluster_name","DB_HOSTS":"db_hosts","ETCD_HOSTS":"etcd_hosts",
     "ETCD_INITIAL_CLUSTER":"etcd_initial_cluster","PG_ALLOW_CIDR":"pg_allow_cidr",
     "DB_CONNECT_TIMEOUT":"db_connect_timeout","TARANAC_VERSION":"version",
     "ETCD_CLIENT_SCHEME":"etcd_client_scheme",
     "POSTGRES_PASSWORD":"postgres_password","POSTGRES_REPLICATION_PASSWORD":"postgres_replication_password",
     "SECRET_KEY":"secret_key","TARANAC_MFA_API_KEY":"taranac_mfa_api_key"}
for env, field in m.items():
    print("CFG_%s=%s" % (env, shlex.quote(str(d.get(field, "")))))
')" || fail "could not parse the cluster config returned by ${PRIMARY}."
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
  # The node's images MUST match the cluster's version; adopt it (warn if it changed).
  prev_ver="$(getenv TARANAC_VERSION)"
  if [ -n "$CFG_TARANAC_VERSION" ]; then
    [ -n "$prev_ver" ] && [ "$prev_ver" != "$CFG_TARANAC_VERSION" ] && \
      echo "ha-join: NOTE — adopting cluster version ${CFG_TARANAC_VERSION} (this node's .env had ${prev_ver})." >&2
    setenv TARANAC_VERSION "$CFG_TARANAC_VERSION"
  fi
  echo "ha-join: cluster config applied (cluster '${CFG_TARANAC_CLUSTER_NAME}', version ${CFG_TARANAC_VERSION})."
fi

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
   [ -n "$(docker run --rm -v "${ETCD_VOL}:/d" busybox sh -c 'ls -A /d 2>/dev/null')" ]; then
  echo "ha-join: reconciling etcd data — '${ETCD_VOL}' is not empty (stale membership from a prior cluster); clearing it so this node's etcd bootstraps fresh into the running cluster (its cluster-id would otherwise mismatch and the join would wedge)."
  docker stop taranac-etcd >/dev/null 2>&1 || true
  docker run --rm -v "${ETCD_VOL}:/d" busybox sh -c 'rm -rf /d/* /d/.[!.]* /d/..?* 2>/dev/null; exit 0' \
    || fail "could not clear the stale etcd data volume '${ETCD_VOL}'. Remove it manually and re-run: docker volume rm ${ETCD_VOL}"
fi

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
     [ -n "$(docker run --rm -v taranac_mfa_data:/d busybox sh -c 'ls -A /d/enckey 2>/dev/null')" ]; then
    existing_enckey_b64="$(docker run --rm -v taranac_mfa_data:/d busybox base64 /d/enckey 2>/dev/null | tr -d '\n' || true)"
    if [ "$existing_enckey_b64" = "$MFA_ENCKEY_B64" ]; then
      echo "ha-join:   taranac_mfa_data already holds the shared mfa enckey — nothing to reconcile."
    else
      echo "ha-join: reconciling mfa enckey — taranac_mfa_data holds a DIFFERENT (node-local) key; removing it so the shared cluster key takes effect. This drops any Push tokens enrolled locally on THIS node, which a freshly-joining node must not keep."
      # Stop the mfa container first if it is running (a prior standalone start), then clear
      # the stale key. The up -d at the end of this script recreates mfa → entrypoint sees
      # no key → provisions the shared one from TARANAC_MFA_ENCKEY.
      docker stop taranac-mfa >/dev/null 2>&1 || true
      docker run --rm -v taranac_mfa_data:/d busybox rm -f /d/enckey \
        || fail "could not remove the stale mfa enckey from taranac_mfa_data. Remove it manually and re-run: docker run --rm -v taranac_mfa_data:/d busybox rm -f /d/enckey"
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
   [ -n "$(docker run --rm -v "${MK_VOL}:/d" busybox sh -c 'ls -A /d/master_key 2>/dev/null')" ]; then
  existing_mk="$(docker run --rm -v "${MK_VOL}:/d" busybox cat /d/master_key 2>/dev/null | tr -d '\r\n' || true)"
  if [ "$existing_mk" = "$MASTER_KEY" ]; then
    echo "ha-join:   ${MK_VOL} already holds the cluster MASTER_KEY — nothing to reconcile."
  else
    echo "ha-join: reconciling daemon KEK — ${MK_VOL} holds a DIFFERENT (node-local) master key; removing it so the tacacs/radius/nac entrypoints adopt the cluster MASTER_KEY on the up -d below. (Without this, those daemons decrypt device/enable secrets with the wrong key — Push MFA works via the API but enable-password auth and device-key reads fail on this node.)"
    docker stop taranac-tacacs taranac-radius taranac-nac >/dev/null 2>&1 || true
    docker run --rm -v "${MK_VOL}:/d" busybox rm -f /d/master_key \
      || fail "could not remove the stale master key from ${MK_VOL}. Remove it manually and re-run: docker run --rm -v ${MK_VOL}:/d busybox rm -f /d/master_key"
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
echo "ha-join: registering '${ETCD_NAME}' (${NODE_ADDRESS}) as a member of the running etcd cluster…"
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
