#!/usr/bin/env bash
# portal-join.sh — stand up a Taranac standalone captive portal on THIS host.
#
# A standalone portal serves the Registration VLAN on its own (nginx + optional
# DHCP/DNS) and reaches the core for two things only: the guest-API proxy that
# carries a BYOD user's login, and a heartbeat. It holds no database. This script
# is the thin operator wrapper around bringing that container up:
#
#   1. Validate inputs (core URL, portal API token).
#   2. Establish trust in the core (pin on first contact, or a CA bundle).
#   3. FETCH this portal's deployment bundle from the core with the token —
#      the same archive the UI's "Download bundle" button produces, with the
#      token already filled in — and unpack it into the install directory.
#   4. `docker compose up -d`.
#
# ONE THING TO SUPPLY, AND THE CORE HANDS IT OVER. The deployment tab
# (NAC -> Captive Portals -> <portal> -> Deployment -> Generate Token) prints
# this command with the core's real URL already filled in — copy it there,
# paste it here:
#
#   ./portal-join.sh \
#       --core https://core.example \
#       --token <portal-token>
#
# Edit the URL if this host reaches the core by a different name (NAT, a public
# FQDN, another port) — the core fills in the address YOU are using it from,
# which is not always the address a DMZ host must dial. Whatever you use has to
# appear in the core certificate's SANs: the portal verifies the name, so a core
# reached by IP needs an IP SAN (the appliance's self-signed certificate has one).
#
# The API token is NOT one-shot — it is this portal's standing credential, and it
# ends up in the bundle's .env. Re-running with a fresh token re-deploys the
# portal against the new one.
#
# TRUST — no file needed by default. The portal pins the chain the core presents
# on first contact and accepts only that afterwards. Two alternatives:
#   --ca-file <path>   verify against a CA bundle instead (strictest; behind an
#                      nginx edge this is the EDGE CA, not the internal one)
#   --trust-any        verify nothing (a lab setting — this channel carries the
#                      guest's username and password, so do not ship it)
#
# If the core's certificate is legitimately replaced later, the portal stops and
# says so. Re-pin without a new token:
#   ./portal-join.sh --reset-trust
#
# Usage (on the portal host):
#   ./portal-join.sh --core <url> --token <portal-token>
#       [--ca-file <path>] [--trust-any] [--dir <install dir>]
#   ./portal-join.sh --reset-trust [--dir <install dir>]
#   ./portal-join.sh --status [--dir <install dir>]      # what it is doing, locally
#   ./portal-join.sh --uninstall [--dir <install dir>]   # remove it from THIS host
set -euo pipefail

# Absolute by default so `--reset-trust` finds the installation from any working
# directory — unlike the collector, this script does not live next to its compose
# file (the bundle brings its own).
DEFAULT_DIR="/opt/taranac/captive-portal"
ANCHOR_NAME="certs/core-ca.pem"
PIN_STATE="/app/data/core-ca.pem"   # inside the container's portal-data volume

CORE=""; TOKEN=""; CA_FILE=""; DIR=""; TRUST_ANY=0; RESET_TRUST=0; UNINSTALL=0; STATUS=0

usage() { sed -n '2,49p' "$0"; }
fail()  { echo "portal-join: $*" >&2; exit 1; }
info()  { echo "portal-join: $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --core)        CORE="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --ca-file)     CA_FILE="$2"; shift 2 ;;   # optional: strict CA verification
    --trust-any)   TRUST_ANY=1; shift ;;      # optional: verify nothing (lab)
    --reset-trust) RESET_TRUST=1; shift ;;    # re-pin after the core's cert changed
    --uninstall)   UNINSTALL=1; shift ;;      # remove this portal from THIS host
    --status)      STATUS=1; shift ;;         # what it is doing, locally
    --dir)         DIR="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

DIR="${DIR:-$DEFAULT_DIR}"

command -v docker >/dev/null 2>&1 || fail "docker is not installed on this host."
command -v curl >/dev/null 2>&1   || fail "curl is not installed on this host."
command -v openssl >/dev/null 2>&1 || fail "openssl is not installed on this host (needed to learn the core's certificate)."

# ── Trust helpers ─────────────────────────────────────────────────────────────
# Learn the core's certificate the only way there is to learn it: ask, and keep
# what comes back. Deliberately unverified — this is the input to a pin decision,
# never a substitute for one.
#
# The WHOLE chain is kept, not just the leaf. OpenSSL accepts a leaf found in the
# trust store on its own, so a leaf would usually do — but carrying the issuers
# costs nothing and does not lean on that property of the verifier. (For a
# self-signed core the chain IS one certificate.) What no anchor can paper over
# is the NAME: nginx checks the proxied host against the certificate, so --core
# must name something in the core certificate's SANs.
probe_core_chain() {
  local url="$1" hostport host port rest sni=()
  hostport="${url#*://}"; hostport="${hostport%%/*}"
  if [ "${hostport#\[}" != "$hostport" ]; then       # bracketed IPv6 literal
    host="${hostport%%]*}"; host="${host#[}"
    rest="${hostport##*]}"; port="${rest#:}"
  else
    host="${hostport%%:*}"; port="${hostport##*:}"
    [ "$port" = "$host" ] && port=""
  fi
  [ -n "$port" ] || port=443
  # SNI carries host NAMES only — an IP literal there is invalid and some stacks
  # reject the handshake for it.
  case "$host" in *[a-zA-Z]*) sni=(-servername "$host") ;; esac
  openssl s_client -showcerts "${sni[@]}" -connect "${host}:${port}" </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/'
}

leaf_fingerprint() {  # SHA-256 of the FIRST certificate in a PEM file
  awk '/BEGIN CERTIFICATE/{c++} c==1{print} /END CERTIFICATE/{if (c==1) exit}' "$1" \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

core_root() {  # the core's base URL without a trailing /api/v1 (we append it)
  local u="${1%/}"
  printf '%s' "${u%/api/v1}"
}

# ── --status: what this portal is doing, from LOCAL state only ───────────────
# No network call: this is what an operator runs when the core is unreachable, and
# depending on the connection under suspicion would defeat the point. The portal
# has no liveness file like the collector, so the signal is its own heartbeat
# transitions in the log — the same line the installer waits for.
if [ "$STATUS" -eq 1 ]; then
  [ -f "${DIR}/docker-compose.yml" ] || fail "no portal is installed in ${DIR} (use --dir)."
  COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"
  info "Core:      $(grep -E '^BACKEND_API_URL=' "${DIR}/.env" 2>/dev/null | cut -d= -f2-)"
  info "Portal:    $(grep -E '^PORTAL_SLUG=' "${DIR}/.env" 2>/dev/null | cut -d= -f2-)"
  info "Trust:     $(grep -E '^PORTAL_TLS_TRUST=' "${DIR}/.env" 2>/dev/null | cut -d= -f2- || echo 'pin (default)')"
  [ -f "${DIR}/${ANCHOR_NAME}" ] && info "Core cert: pinned $(leaf_fingerprint "${DIR}/${ANCHOR_NAME}" | cut -c1-16)…"
  info "Container: $(${COMPOSE} ps --format '{{.State}} ({{.Health}})' portal 2>/dev/null | head -1 || echo 'not created')"
  # Heartbeat acceptance is the only proof the WHOLE path works — trust, token and
  # route — so report the last transition rather than a generic "it is running".
  LAST_HB="$(${COMPOSE} logs --no-color --tail 500 portal 2>/dev/null \
    | grep -E 'Heartbeat (accepted|failed|stopped)' | tail -1)"
  [ -n "$LAST_HB" ] && info "Heartbeat: ${LAST_HB##*] }" || info "Heartbeat: nothing in the recent log"
  exit 0
fi

# ── --uninstall: remove this portal from THIS host ───────────────────────────
# Local only, like the collector's: a box being decommissioned frequently cannot
# reach the core any more, and an uninstall that fails exactly then does not work.
# Unlike the collector there is nothing here to lose — a portal holds no collected
# data of its own; everything it runs on came from the core and can be fetched
# again. So no --force guard: there is no history to discard.
if [ "$UNINSTALL" -eq 1 ]; then
  [ -f "${DIR}/docker-compose.yml" ] || fail "no portal is installed in ${DIR} (use --dir)."
  COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"
  info "removing the portal, its data volume and its bundle…"
  ${COMPOSE} down -v || fail "could not bring the portal down."
  rm -rf "${DIR}" 2>/dev/null || sudo rm -rf "${DIR}" 2>/dev/null || true
  cat <<EOF

portal-join: removed from this host — container, data volume (pinned certificate,
instance id) and the unpacked bundle are gone.

The portal still EXISTS on the core, and its instance row with it: delete or
re-deploy it there —  NAC -> Captive Portals -> <this one>.
EOF
  exit 0
fi

# ── --reset-trust: forget the pinned core certificate, re-learn, restart ──────
# The pin exists in two places — the container's state volume (what the portal
# compares against) and ./certs/core-ca.pem (what nginx verifies with). Both are
# cleared, and the anchor is re-learned HERE rather than left to the container,
# because a bundle carrying its own portal certificate mounts ./certs read-only
# and the container could not write the new anchor even if it wanted to.
if [ "$RESET_TRUST" -eq 1 ]; then
  [ -f "${DIR}/docker-compose.yml" ] || fail "no portal is installed in ${DIR} (use --dir)."
  COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"

  info "clearing the pinned core certificate…"
  ${COMPOSE} run --rm --no-deps --entrypoint rm portal -f "$PIN_STATE" \
    || fail "could not clear the pin (is the portal installed here?)"
  rm -f "${DIR}/${ANCHOR_NAME}"

  # The core URL is not re-asked: it is already in the bundle's .env.
  CORE=$(grep -E '^BACKEND_API_URL=' "${DIR}/.env" | head -1 | cut -d= -f2-)
  if [ -n "$CORE" ]; then
    CHAIN=$(probe_core_chain "$CORE" || true)
    if [ -n "$CHAIN" ]; then
      printf '%s\n' "$CHAIN" > "${DIR}/${ANCHOR_NAME}"
      chmod 644 "${DIR}/${ANCHOR_NAME}"
      info "re-pinned ${CORE}: $(leaf_fingerprint "${DIR}/${ANCHOR_NAME}")"
    else
      info "NOTE — ${CORE} did not answer; the portal will pin on its own once it can reach the core."
    fi
  fi

  info "restarting the portal…"
  ${COMPOSE} up -d
  info "done. Watch it re-pin: ${COMPOSE} logs -f portal"
  exit 0
fi

# ── Guards ────────────────────────────────────────────────────────────────────
[ -n "$CORE" ]  || fail "missing --core <url> (the core's base URL, e.g. https://core.example). The portal's Deployment tab prints this command with it filled in."
[ -n "$TOKEN" ] || fail "missing --token <portal-token> (generate one on the core: NAC -> Captive Portals -> <portal> -> Deployment -> Generate Token)."
case "$CORE" in https://*) ;; *) fail "--core must be an https:// URL; got '${CORE}'." ;; esac

if [ -n "$CA_FILE" ] && [ "$TRUST_ANY" -eq 1 ]; then
  fail "--ca-file and --trust-any contradict each other — pick one (or neither, to pin on first contact)."
fi
if [ -n "$CA_FILE" ]; then
  [ -r "$CA_FILE" ] || fail "--ca-file '${CA_FILE}' is not readable."
  openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1 \
    || fail "--ca-file '${CA_FILE}' does not parse as a PEM certificate."
fi

CORE_ROOT="$(core_root "$CORE")"

# ── Establish trust, then fetch the bundle through it ─────────────────────────
# The archive carries this portal's API token, so the fetch itself is a channel
# worth verifying — the trust decision is made BEFORE the first request, not after.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ANCHOR="${WORK}/core-ca.pem"

if [ -n "$CA_FILE" ]; then
  cp "$CA_FILE" "$ANCHOR"
  TRUST_PARAM="ca"
  TRUST_LINE="CA bundle ${CA_FILE} -> ${DIR}/${ANCHOR_NAME} (strict)"
  CURL_TLS=(--cacert "$ANCHOR")
elif [ "$TRUST_ANY" -eq 1 ]; then
  TRUST_PARAM="any"
  TRUST_LINE="NONE — the core's certificate is not verified (--trust-any)"
  CURL_TLS=(-k)
else
  info "learning the core's TLS certificate (trust on first use)…"
  probe_core_chain "$CORE_ROOT" > "$ANCHOR" || true
  [ -s "$ANCHOR" ] || fail "could not reach ${CORE_ROOT} to read its TLS certificate — check the URL, the route and the firewall."
  TRUST_PARAM="pin"

  # Re-running the join on a host that already has a pin must NOT quietly adopt a
  # different certificate. Re-running is a normal thing to do — a fresh token, a
  # changed poll setting, a repeat of the install — and it is the one moment where
  # silently trusting something new would undo every check made since the first
  # install. Same refusal the collector makes; clearing a pin stays a deliberate act.
  if [ -f "${DIR}/${ANCHOR_NAME}" ]; then
    existing="$(leaf_fingerprint "${DIR}/${ANCHOR_NAME}")"
    presented="$(leaf_fingerprint "$ANCHOR")"
    if [ "$existing" != "$presented" ]; then
      echo "portal-join: the core presented a different TLS certificate than the one pinned here." >&2
      echo "  pinned now: ${existing}" >&2
      echo "  presented:  ${presented}" >&2
      fail "if the core's certificate was legitimately replaced, re-pin deliberately: $0 --reset-trust --dir ${DIR}. If it was not, someone is answering for the core — do not clear the pin."
    fi
    info "the core's certificate still matches the pin (${existing})"
    cp "${DIR}/${ANCHOR_NAME}" "$ANCHOR"
  fi

  TRUST_LINE="pinned ($(leaf_fingerprint "$ANCHOR"))"
  CURL_TLS=(--cacert "$ANCHOR")
fi

BUNDLE="${WORK}/bundle.tar.gz"
BUNDLE_URL="${CORE_ROOT}/api/v1/captive-portal/bootstrap-bundle?trust=${TRUST_PARAM}"

info "fetching this portal's deployment bundle from the core…"
HTTP_CODE=$(curl -sS "${CURL_TLS[@]}" -o "$BUNDLE" -w '%{http_code}' \
  -H "X-Portal-Token: ${TOKEN}" "$BUNDLE_URL" 2>"${WORK}/curl.err") || {
    # Exit 60 is curl's certificate-verification failure. Under `pin` that almost
    # always means the name in --core is not in the certificate's SANs, because
    # the certificate itself is by definition the one we just read off the wire.
    if grep -qi 'certificate' "${WORK}/curl.err"; then
      echo "portal-join: the core's certificate did not verify:" >&2
      sed 's/^/  /' "${WORK}/curl.err" >&2
      fail "the address in --core must appear in the core certificate's SANs (an appliance reached by IP needs an IP SAN). Use --ca-file for a CA-issued certificate, or --trust-any in a lab."
    fi
    sed 's/^/  /' "${WORK}/curl.err" >&2
    fail "could not fetch the bundle from ${CORE_ROOT}. If this site has no route to the core, download the bundle in the UI and deploy it by hand (see the bundle's README)."
  }

case "$HTTP_CODE" in
  200) ;;
  401|403) fail "the core rejected this token (HTTP ${HTTP_CODE}) — generate a fresh one: NAC -> Captive Portals -> <portal> -> Deployment -> Generate Token." ;;
  404) fail "the core has no bootstrap-bundle endpoint (HTTP 404) — it is older than this script. Download the bundle in the UI instead." ;;
  *)   fail "the core answered HTTP ${HTTP_CODE} for the bundle." ;;
esac
tar tzf "$BUNDLE" >/dev/null 2>&1 || fail "what the core returned is not a readable .tar.gz."

# ── Unpack ────────────────────────────────────────────────────────────────────
# Remember whether this is a re-install: portal.conf is a bind-mounted FILE, so a
# fresh one is not picked up by `up -d` (nothing about the container changed) and
# nginx would keep serving the old config. See the restart below.
REINSTALL=0
[ -f "${DIR}/docker-compose.yml" ] && REINSTALL=1
mkdir -p "$DIR"
tar xzf "$BUNDLE" -C "$DIR" --strip-components=1 || fail "could not unpack the bundle into ${DIR}."
[ -f "${DIR}/docker-compose.yml" ] && [ -f "${DIR}/.env" ] \
  || fail "the archive is not a portal bundle (no docker-compose.yml/.env inside)."

# The core fills the token into the bundle's .env. Repair it if it did not —
# the operator supplied the token, there is no reason to send them back for it.
if grep -qE '^PORTAL_API_TOKEN=(<YOUR_API_TOKEN>)?$' "${DIR}/.env"; then
  sed -i "s|^PORTAL_API_TOKEN=.*|PORTAL_API_TOKEN=${TOKEN}|" "${DIR}/.env"
fi

# Record the trust choice for the container. The bundle's portal.conf already
# encodes it for nginx; this is the same decision for the heartbeat sender and
# for the pin check at startup. It wins over the deprecated BACKEND_TLS_VERIFY.
# In `ca` mode the container REQUIRES PORTAL_CA_FILE and exits 1 without it, so
# the mode and the path have to be written together — writing only the mode put
# the portal into a restart loop, and only in the strict mode people pick for
# production. The path is the container's view of the anchor this script just
# installed (./certs is mounted at /etc/nginx/certs).
if [ "$TRUST_PARAM" = "ca" ]; then
  if grep -qE '^PORTAL_CA_FILE=' "${DIR}/.env"; then
    sed -i "s|^PORTAL_CA_FILE=.*|PORTAL_CA_FILE=/etc/nginx/${ANCHOR_NAME}|" "${DIR}/.env"
  else
    printf 'PORTAL_CA_FILE=/etc/nginx/%s\n' "${ANCHOR_NAME}" >> "${DIR}/.env"
  fi
fi
if grep -qE '^PORTAL_TLS_TRUST=' "${DIR}/.env"; then
  sed -i "s|^PORTAL_TLS_TRUST=.*|PORTAL_TLS_TRUST=${TRUST_PARAM}|" "${DIR}/.env"
else
  printf '\n# Written by portal-join.sh — how this portal verifies the core.\nPORTAL_TLS_TRUST=%s\n' \
    "$TRUST_PARAM" >> "${DIR}/.env"
fi
chmod 600 "${DIR}/.env"

# Drop the anchor where the generated portal.conf looks for it. Done here rather
# than left to the container because a bundle with an embedded portal certificate
# mounts ./certs read-only.
if [ "$TRUST_PARAM" != "any" ]; then
  mkdir -p "${DIR}/certs"
  install -m 0644 "$ANCHOR" "${DIR}/${ANCHOR_NAME}"
fi

# ── The image must already be here ────────────────────────────────────────────
# The bundle pins PORTAL_IMAGE to the version the CORE reports, and that is right:
# a portal should run the same release as the server it talks to. But it means a
# core running an image that no registry has — a local build, a custom tag — hands
# out a bundle that cannot start, and the failure lands HERE, at a remote site,
# minutes later.
#
# Which is what happened: a core reporting `1.2.3-rc3-node` (built by hand on that
# box) produced a bundle asking for a tag nobody published. `docker compose up`
# then spent 50 seconds timing out against a registry this appliance cannot reach
# and failed with a DNS error — sending the operator to check the network while
# the right image sat on the disk all along.
#
# So: look before dialling out. This mirrors what taranac-module already does for
# every module it installs; the rule "an appliance downloads nothing" was simply
# never applied on this path.
# An explicit override is applied FIRST, so the check below judges the image that
# will actually be used. Persisted into .env so the next `up -d` — a reboot, a
# restart — resolves to the same one instead of reverting to the tag that was not
# there.
if [ -n "${PORTAL_IMAGE:-}" ]; then
  sed -i "s|^PORTAL_IMAGE=.*|PORTAL_IMAGE=${PORTAL_IMAGE}|" "${DIR}/.env"
  info "using the image named on the command line: ${PORTAL_IMAGE}"
fi

WANT_IMAGE="$(grep -E '^PORTAL_IMAGE=' "${DIR}/.env" | head -1 | cut -d= -f2-)"
if [ -n "$WANT_IMAGE" ] && ! docker image inspect "$WANT_IMAGE" >/dev/null 2>&1; then
  echo "portal-join: the image this bundle asks for is not on this host:" >&2
  echo "portal-join:     ${WANT_IMAGE}" >&2
  echo "portal-join:" >&2
  echo "portal-join: captive-portal images present here:" >&2
  docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -i captive-portal | sort -u | sed 's/^/portal-join:     /' >&2 \
    || echo "portal-join:     (none)" >&2
  echo "portal-join:" >&2
  echo "portal-join: The tag comes from the version the CORE reports, so a core running" >&2
  echo "portal-join: an unpublished build asks for an image that does not exist. Point this" >&2
  echo "portal-join: portal at one you have and re-run:" >&2
  echo "portal-join:     sudo PORTAL_IMAGE=<image> $0 $*" >&2
  fail "refusing to reach for a registry — this appliance installs offline."
fi

# ── Bring the portal up ───────────────────────────────────────────────────────
info "starting the portal…"
COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"
# UTC with an explicit Z — a zoneless stamp is read as the daemon's LOCAL time by
# `docker compose logs --since`, which on a box that is not on UTC would show a
# previous attempt's error as this one's.
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
${COMPOSE} up -d
# On a re-install `up -d` sees an unchanged container definition and leaves the
# running one alone — so the freshly fetched portal.conf, the new trust anchor and
# the new .env would all sit on disk unread. Restart so what was fetched is what
# is actually serving; otherwise the operator "reinstalled" and nothing changed.
if [ "$REINSTALL" -eq 1 ]; then
  info "restarting the portal so the refetched config takes effect…"
  ${COMPOSE} restart portal
fi

# nginx can serve a perfectly good page while the channel to the core is refused,
# so the signal worth waiting for is the FIRST ACCEPTED HEARTBEAT — the only one
# that proves trust, token and route all work. Claiming success before that would
# leave an operator believing guests can register when they cannot.
info "waiting for the portal to reach the core…"
REACHED=0; FAILURE=""; WAITED=0
while [ "$WAITED" -lt 90 ]; do
  LOG="$(${COMPOSE} logs --since "$SINCE" --no-color portal 2>&1 || true)"
  case "$LOG" in
    *"Heartbeat accepted by the core"*) REACHED=1; break ;;
  esac
  FAILURE="$(printf '%s\n' "$LOG" | grep -m1 -E 'Heartbeat failed|certificate .*(changed|does not)|\[emerg\]' || true)"
  # A heartbeat fires every HEARTBEAT_INTERVAL (30s by default) — give it two
  # full beats before believing a failure is permanent.
  [ -n "$FAILURE" ] && [ "$WAITED" -ge 45 ] && break
  sleep 3
  WAITED=$((WAITED + 3))
done

if [ "$REACHED" -eq 0 ]; then
  cat >&2 <<EOF

portal-join: the portal started but is NOT reaching the core.
  Core:        ${CORE_ROOT}
  Trust:       ${TRUST_LINE}
  Installed:   ${DIR}

${FAILURE:-$(printf '%s\n' "$LOG" | tail -12 | sed 's/^/  /')}

Guests may still see the portal page, but registrations will not reach the core
and it will not appear under NAC -> Captive Portals -> Instances.

  ${COMPOSE} logs -f portal
EOF
  exit 1
fi

cat <<EOF

portal-join: the portal is up and reaching the core.
  Core:        ${CORE_ROOT}
  Trust:       ${TRUST_LINE}
  Installed:   ${DIR}
  Token:       written to ${DIR}/.env (0600) — this portal's standing credential

Verify:
  ${COMPOSE} logs -f portal        # watch it pin, load portal.conf and heartbeat
  ${COMPOSE} ps                    # health = 'healthy' once nginx answers
  curl -k https://localhost/portal/

Core UI: NAC -> Captive Portals -> Instances — this one appears on its first heartbeat.

If the log says the core's certificate CHANGED, and you know it was replaced:
  ./portal-join.sh --reset-trust --dir ${DIR}
EOF
