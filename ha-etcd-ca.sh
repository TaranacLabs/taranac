#!/usr/bin/env bash
# ha-etcd-ca.sh — the etcd client-TLS certificate authority for a Taranac HA cluster.
#
# Client TLS (Patroni ↔ etcd, port 2379) is ONE-WAY (server-only): every etcd member
# presents a CA-signed server cert; clients (Patroni, etcdctl, the healthcheck, the
# entrypoint DCS probe) VERIFY it against the shared CA and present NO client cert
# (docs/spec/backend/infra/cluster.md). That needs exactly one shared secret provisioned out-of-band
# BEFORE etcd starts: the etcd CA. This tool is that CA.
#
# It is part of the unified "cluster secret set" (ha.md §12): the seed (ha-convert)
# generates the CA + its own leaf; a joining node's leaf is ISSUED ON THE SEED (the CA
# key never leaves the seed) and carried out-of-band with the rest of the set. The CA
# key (ca.key) is the highest-value secret here — keep it OFF the data nodes and archive
# it OOB like MASTER_KEY.
#
# Two ways to get a node its leaf:
#   * `issue`  — the seed makes the key AND the cert, and the operator SCPs both over.
#                Still used by `ha-convert.sh --prepare` to pre-issue leaves.
#   * `make-csr` + `sign-csr` — the JOINING node makes its own key and a CSR, the seed
#                signs it. The private key never travels; a signed cert is not a secret.
#                This is what the HA wizard's broker uses (docs/spec/backend/infra/cluster.md, "CSR instead of
#                SCP") and it is the reason the witness no longer needs an SCP step.
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
#   ha-etcd-ca.sh make-csr <out-dir> <cn>
#       RUNS ON THE JOINING NODE (no CA needed, none present). Generates
#       <out-dir>/etcd-server.key (2048, mode 0600 — it stays here forever) and
#       <out-dir>/etcd-server.csr, and prints the CSR path on stdout (status goes to
#       stderr, so a caller can capture the path with $(...)). Re-running reuses an
#       existing key rather than clobbering it — a new key would silently invalidate a
#       leaf that has already been signed.
#       Takes NO SAN list ON PURPOSE: the addresses a cert may carry are the SIGNER's
#       decision, not the requester's (see sign-csr).
#
#   ha-etcd-ca.sh sign-csr <ca-dir> <csr-file> <out-file> <san-csv>
#       RUNS ON THE SEED. Signs <csr-file> with the CA in <ca-dir> and writes the leaf
#       to <out-file>. 825-day leaf, same extensions as `issue`.
#       The SANs come from <san-csv> — the signer's argument — and NEVER from the CSR.
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
# The archive carries config/etcd-ca (HA.md §7): losing one machine must never
# leave a cluster unable to admit or replace a node. That only works if the api
# container can READ the key — it runs as gid 999, while everything here is written
# 0600 under the operator's own uid. Granting it at creation is the only moment
# that costs nothing; leaving it for the operator is what produced an HA install
# whose every backup silently skipped the CA (found at a customer, 1.2.7).
#
# Sourced, not reimplemented: one definition of "readable by the api" (group + mode
# + the sudo ladder for a non-root operator) shared with install.sh and the updater.
_secure_for_backup() {  # <dir>
  local helper="${SCRIPT_DIR:-$(dirname "$0")}/env-secrets.sh"
  [ -f "$helper" ] || return 0
  # shellcheck source=/dev/null
  . "$helper" 2>/dev/null || return 0
  type secure_host_dir >/dev/null 2>&1 || return 0
  secure_host_dir "$1" "$(basename "$1")" || true
}

# The deployed set's directory (config/etcd-tls) must be traversable by the api
# container (uid/gid 999): the leader's ring reconcile reads ca.crt from it through
# the read-only ./config mount to verify each member over client TLS. A directory
# created under a strict umask — the operator's, or one a calling script set earlier
# and never restored — would be 0700 and hide a world-readable ca.crt behind it.
# Only the directory is widened: etcd-server.key inside stays 0600.
_traversable_dir() {  # <dir>
  chmod a+rx "$1" 2>/dev/null || true
}

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
  _secure_for_backup "$cadir"
  echo "ha-etcd-ca: generated a new etcd CA in $cadir (ca.crt + ca.key). Every node receives a copy when it joins, so the cluster can still admit nodes after any single machine is lost."
}

issue() {  # <ca-dir> <out-dir> <cn> <san-csv>
  local cadir="$1" outdir="$2" cn="$3" sans="$4" cnf tok dn=0 ip=0
  [ -n "$cadir" ] && [ -n "$outdir" ] && [ -n "$cn" ] && [ -n "$sans" ] \
    || die "issue: usage: issue <ca-dir> <out-dir> <cn> <san-csv>"
  [ -s "$cadir/ca.crt" ] && [ -s "$cadir/ca.key" ] || die "issue: no CA in $cadir — run 'init-ca $cadir' first."
  mkdir -p "$outdir"
  _traversable_dir "$outdir"
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

# ─────────────────────────────────────────────────────────────────────────────────────
# CSR flow (docs/spec/backend/infra/cluster.md, "CSR instead of SCP"): key on the node, CA on the seed.
# ─────────────────────────────────────────────────────────────────────────────────────

# make-csr runs on the JOINING node, which has no CA and never will. It produces a key
# that stays put and a request that is safe to hand to anyone.
#
# It deliberately writes NO subjectAltName into the request. Not because openssl would
# honour one (it would not — see sign_csr), but because putting a SAN here would tell
# every future reader that the requester gets a say in its own identity. It does not.
make_csr() {  # <out-dir> <cn>
  local outdir="$1" cn="$2" cnf
  [ -n "$outdir" ] && [ -n "$cn" ] \
    || die "make-csr: usage: make-csr <out-dir> <cn>"
  mkdir -p "$outdir" || die "make-csr: cannot create $outdir — check the path and permissions."
  _traversable_dir "$outdir"
  cnf="$(mktemp)"; trap 'rm -f "$cnf"' RETURN
  {
    echo "[req]"; echo "distinguished_name=dn"; echo "prompt=no"
    echo "[dn]"; echo "CN=$cn"
  } > "$cnf"
  umask 077
  # Reuse an existing key. Regenerating it would leave the node holding a key that does
  # not match the certificate the seed already signed for it — a failure that shows up
  # only as an etcd TLS handshake error hours later, which is a miserable way to find it.
  if [ -s "$outdir/etcd-server.key" ]; then
    echo "ha-etcd-ca: reusing the existing private key in $outdir (a new one would orphan any leaf already signed for it)." >&2
  else
    run_openssl genrsa -out "$outdir/etcd-server.key" 2048
  fi
  run_openssl req -new -key "$outdir/etcd-server.key" -config "$cnf" -out "$outdir/etcd-server.csr"
  chmod 600 "$outdir/etcd-server.key"; chmod 644 "$outdir/etcd-server.csr"
  # stdout = the path (machine), stderr = the story (human). The broker captures $(...).
  echo "ha-etcd-ca: CN=$cn — private key stays in $outdir/etcd-server.key (never copy it anywhere); send only the CSR." >&2
  echo "$outdir/etcd-server.csr"
}

sign_csr() {  # <ca-dir> <csr-file> <out-file> <san-csv>
  local cadir="$1" csr="$2" out="$3" sans="$4" cnf tok dn=0 ip=0 subj alg bits min outdir
  [ -n "$cadir" ] && [ -n "$csr" ] && [ -n "$out" ] && [ -n "$sans" ] \
    || die "sign-csr: usage: sign-csr <ca-dir> <csr-file> <out-file> <san-csv>"
  [ -s "$cadir/ca.crt" ] && [ -s "$cadir/ca.key" ] || die "sign-csr: no CA in $cadir — run 'init-ca $cadir' first."
  [ -s "$csr" ] || die "sign-csr: '$csr' is missing or empty — the joining node produces it with 'ha-etcd-ca.sh make-csr'."

  # A CSR is UNTRUSTED INPUT — it arrives over the network from a machine that is not
  # yet a cluster member. Parse it defensively before the CA key is anywhere near it.
  # `req -verify` checks the request's self-signature, i.e. that the sender actually
  # holds the private key for the public key it is asking us to certify.
  openssl req -in "$csr" -noout -verify >/dev/null 2>&1 \
    || die "sign-csr: '$csr' is not a valid PKCS#10 request, or its self-signature does not verify. Have the node regenerate it with 'ha-etcd-ca.sh make-csr'."

  # Refuse a weak key. The requester chooses its own key strength, so this is the only
  # place it can be policed; signing a 512-bit key would produce a CA-blessed cert that
  # is trivially forgeable and would then be trusted by every member of the cluster.
  alg="$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public Key Algorithm: *//p' | head -1)"
  bits="$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: *(\([0-9]*\) bit).*/\1/p' | head -1)"
  case "$alg" in
    rsaEncryption|dsaEncryption) min=2048 ;;
    id-ecPublicKey)              min=256 ;;
    *) die "sign-csr: unsupported public key algorithm '${alg:-unknown}' in '$csr'. Regenerate the request with 'ha-etcd-ca.sh make-csr' (RSA-2048)." ;;
  esac
  [ -n "$bits" ] && [ "$bits" -ge "$min" ] 2>/dev/null \
    || die "sign-csr: refusing to sign a ${bits:-?}-bit $alg key (minimum $min). Regenerate the request with 'ha-etcd-ca.sh make-csr'."

  # The subject is read for the LOG LINE ONLY. It is whatever the requester typed; it
  # carries no authority and is not used to derive anything.
  subj="$(openssl req -in "$csr" -noout -subject 2>/dev/null | sed 's/^subject= *//')"

  outdir="$(dirname "$out")"
  mkdir -p "$outdir" || die "sign-csr: cannot create $outdir — check the path and permissions."

  # ══ THE LOAD-BEARING RULE ═════════════════════════════════════════════════════════
  # The SANs are written HERE, from the <san-csv> the SIGNER passed, and are never read
  # out of the CSR. Client TLS is one-way: a member's identity IS the set of addresses
  # in its certificate. Honouring a requester-supplied subjectAltName would let a
  # joining node mint itself a cert for any address it names — including an existing
  # member's — and then impersonate that member to every Patroni/etcdctl client in the
  # cluster, which verifies only "signed by our CA, address matches". The seed already
  # knows the right address: it issued the join token FOR that address.
  # openssl's default is on our side (`x509 -req` copies no extensions from the CSR),
  # but "the default protects us" is not a security control — the -extfile below is the
  # control, and -copy_extensions none locks the default down explicitly where the
  # installed openssl is new enough to accept the flag.
  # ══════════════════════════════════════════════════════════════════════════════════
  cnf="$(mktemp)"; trap 'rm -f "$cnf"' RETURN
  {
    echo "[v3]"
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=serverAuth"       # one-way TLS: etcd is the server; no clientAuth
    echo "subjectAltName=@san"
    echo "[san]"
  } > "$cnf"
  # Same SAN classification as issue() — IPv4 → IP SAN, everything else → DNS SAN, no
  # IPv6 literals. Duplicated rather than factored out on purpose: issue() is the path
  # `ha-convert.sh --prepare` depends on and it works; a shared helper would put a
  # working production path at risk to save nine lines. test_ha_etcd_ca_csr.sh asserts
  # that both paths still emit identical extensions, so a divergence cannot go unseen.
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
  [ $((ip+dn)) -gt 0 ] || die "sign-csr: <san-csv> '$sans' yielded no usable names. Pass the node's address, e.g. '10.0.0.2,127.0.0.1,localhost'."

  # -copy_extensions exists from OpenSSL 3.0; on 1.1.1 the behaviour is the same (no
  # copying) but the flag is not accepted, so probe instead of assuming.
  local nocopy=()
  if openssl x509 -help 2>&1 | grep -q -- '-copy_extensions'; then nocopy=(-copy_extensions none); fi

  run_openssl x509 -req -in "$csr" -CA "$cadir/ca.crt" -CAkey "$cadir/ca.key" \
    -CAcreateserial -days "$LEAF_DAYS" -sha256 -extensions v3 -extfile "$cnf" \
    ${nocopy[@]+"${nocopy[@]}"} \
    -out "$out"
  chmod 644 "$out"
  echo "ha-etcd-ca: signed CSR [$subj] → $out (SAN=$sans, chosen by this signer; any SAN in the request was ignored)."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init-ca)  init_ca "${1:-}" ;;
  issue)    issue "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  make-csr) make_csr "${1:-}" "${2:-}" ;;
  sign-csr) sign_csr "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  ""|-h|--help|help)
    # The header block above IS the help text — keep this range covering it (2..55).
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command '$cmd' (expected: init-ca | issue | make-csr | sign-csr). See --help." ;;
esac
