#!/usr/bin/env bash
# ha-etcd-ca.sh — the etcd client-TLS certificate authority for a Taranac HA cluster.
#
# Client TLS (Patroni ↔ etcd, port 2379) is ONE-WAY (server-only): every etcd member
# presents a CA-signed server cert; clients (Patroni, etcdctl, the healthcheck, the
# entrypoint DCS probe) VERIFY it against the shared CA and present NO client cert
# (docs/guide/ha.md §7.3). That needs exactly one shared secret provisioned out-of-band
# BEFORE etcd starts: the etcd CA. This tool is that CA.
#
# It is part of the unified "cluster secret set" (ha.md §12): the seed (ha-convert)
# generates the CA + its own leaf; a joining node's leaf is ISSUED ON THE SEED (the CA
# key never leaves the seed) and carried out-of-band with the rest of the set. The CA
# key (ca.key) is the highest-value secret here — keep it OFF the data nodes and archive
# it OOB like MASTER_KEY.
#
# Layout (relative to the bundle dir):
#   config/etcd-ca/{ca.crt,ca.key}   ← CA (seed-only; ca.key NEVER mounted into a container)
#   config/etcd-tls/{ca.crt,etcd-server.crt,etcd-server.key}  ← this node's deployed set (RO-mounted)
#
# Usage:
#   ha-etcd-ca.sh init-ca  <ca-dir>
#       Create ca.key + ca.crt in <ca-dir> if absent (idempotent — never clobbers an
#       existing CA). 10-year CA. Prints nothing on success beyond a status line.
#
#   ha-etcd-ca.sh issue    <ca-dir> <out-dir> <cn> <san-csv>
#       Issue an etcd server leaf signed by the CA in <ca-dir> into <out-dir>:
#       etcd-server.crt + etcd-server.key (+ a copy of ca.crt). <san-csv> is a
#       comma-separated list of DNS names and/or IPv4 addresses that the cert must
#       cover — ALWAYS the node's routable NODE_ADDRESS, plus 127.0.0.1 + localhost for
#       the in-container healthcheck. 825-day leaf.
#
# Requires: openssl. Safe to re-run. Never touches a running container.
set -euo pipefail

CA_DAYS=3650
LEAF_DAYS=825

die() { echo "ha-etcd-ca: $*" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || die "openssl not found (required to manage etcd TLS certs)."

# Run openssl, keeping its stderr quiet on success but SURFACING it on failure (#31).
# The old code piped every openssl call to 2>/dev/null, so a real error — most often
# "permission denied" writing into a config/etcd-tls that Docker had already created
# root-owned on a prior RO mount — vanished into a bare `set -e` exit 1 that looked
# like the tool itself was broken. Capture stderr, echo it verbatim on a non-zero exit.
run_openssl() {
  local errf rc=0
  errf="$(mktemp)"
  openssl "$@" 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ha-etcd-ca: openssl failed (exit $rc): openssl $*" >&2
    sed 's/^/ha-etcd-ca:   /' "$errf" >&2
    rm -f "$errf"
    exit "$rc"
  fi
  rm -f "$errf"
}

# The CA MUST carry basicConstraints=CA:TRUE + keyUsage=keyCertSign, or Python's ssl
# layer (urllib3 — Patroni's etcd client) rejects it with "CA cert does not include key
# usage extension" and the whole cluster wedges. Proven in deploy/ha-dcs-spike.
init_ca() {  # <ca-dir>
  local cadir="$1"
  [ -n "$cadir" ] || die "init-ca: <ca-dir> required"
  mkdir -p "$cadir"
  if [ -s "$cadir/ca.crt" ] && [ -s "$cadir/ca.key" ]; then
    echo "ha-etcd-ca: CA already present in $cadir — leaving it as-is."
    return 0
  fi
  umask 077
  run_openssl genrsa -out "$cadir/ca.key" 4096
  run_openssl req -x509 -new -nodes -key "$cadir/ca.key" -sha256 -days "$CA_DAYS" \
    -subj "/CN=taranac-etcd-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$cadir/ca.crt"
  chmod 600 "$cadir/ca.key"; chmod 644 "$cadir/ca.crt"
  echo "ha-etcd-ca: generated a new etcd CA in $cadir (ca.crt + ca.key). Archive ca.key OOB; it never leaves the seed."
}

issue() {  # <ca-dir> <out-dir> <cn> <san-csv>
  local cadir="$1" outdir="$2" cn="$3" sans="$4" cnf tok dn=0 ip=0
  [ -n "$cadir" ] && [ -n "$outdir" ] && [ -n "$cn" ] && [ -n "$sans" ] \
    || die "issue: usage: issue <ca-dir> <out-dir> <cn> <san-csv>"
  [ -s "$cadir/ca.crt" ] && [ -s "$cadir/ca.key" ] || die "issue: no CA in $cadir — run 'init-ca $cadir' first."
  mkdir -p "$outdir"
  cnf="$(mktemp)"; trap 'rm -f "$cnf" "$cnf.csr"' RETURN
  {
    echo "[req]"; echo "distinguished_name=dn"; echo "req_extensions=v3"; echo "prompt=no"
    echo "[dn]"; echo "CN=$cn"
    echo "[v3]"
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=serverAuth"       # one-way TLS: etcd is the server; no clientAuth
    echo "subjectAltName=@san"
    echo "[san]"
  } > "$cnf"
  # SAN classification: IPv4 → IP SAN, everything else → DNS SAN. IPv6 literals are NOT
  # detected (they'd become a DNS SAN and fail IP verification) — client-TLS assumes an
  # IPv4 or hostname NODE_ADDRESS. IP-SAN verification via Python's ssl/urllib3 (exactly
  # Patroni's etcd client) is proven; see ha.md §7.3.
  local IFS=,
  for tok in $sans; do
    tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
    [ -n "$tok" ] || continue
    if printf '%s' "$tok" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      ip=$((ip+1)); echo "IP.$ip=$tok" >> "$cnf"
    else
      dn=$((dn+1)); echo "DNS.$dn=$tok" >> "$cnf"
    fi
  done
  unset IFS
  umask 077
  run_openssl genrsa -out "$outdir/etcd-server.key" 2048
  run_openssl req -new -key "$outdir/etcd-server.key" -config "$cnf" -out "$cnf.csr"
  run_openssl x509 -req -in "$cnf.csr" -CA "$cadir/ca.crt" -CAkey "$cadir/ca.key" \
    -CAcreateserial -days "$LEAF_DAYS" -sha256 -extensions v3 -extfile "$cnf" \
    -out "$outdir/etcd-server.crt"
  cp -f "$cadir/ca.crt" "$outdir/ca.crt"
  chmod 600 "$outdir/etcd-server.key"; chmod 644 "$outdir/etcd-server.crt" "$outdir/ca.crt"
  echo "ha-etcd-ca: issued etcd server leaf for CN=$cn (SAN=$sans) → $outdir/{etcd-server.crt,etcd-server.key,ca.crt}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init-ca) init_ca "${1:-}" ;;
  issue)   issue "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  ""|-h|--help|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command '$cmd' (expected: init-ca | issue). See --help." ;;
esac
