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
#       [--client-interface <if>] [--uplink-interface <if>] [--dhcp-range a-b]
#       [--nat on|off] [--client-isolation on|off] [-y|--yes]
#
#   A portal that OPENS ACCESS ITSELF asks about THIS host — which NIC faces the
#   guests, which faces the rest of the network, whether to masquerade, whether
#   to isolate. Run it on a terminal and it proposes the answers from what it
#   can see and asks you to confirm; pass the flags (or -y to take the
#   proposals) and it says nothing and proceeds.
#   ./portal-join.sh --reset-trust [--dir <install dir>]
#   ./portal-join.sh --status [--dir <install dir>]      # what it is doing, locally
#   ./portal-join.sh --update [--check] [--dir <install dir>]
#       Move this portal to the version ITS CORE runs. Needs no arguments: the
#       core's address and this portal's token are already in the install. The
#       wiring answered at install time is kept and never re-asked, and if the
#       new version does not reach the core it is rolled back to the one that
#       did. --check reports and changes nothing.
#   ./portal-join.sh --uninstall [--dir <install dir>]   # remove it from THIS host
#
# PORTALS THAT ENFORCE. A portal set to open access itself routes its own
# segment: it hands out the addresses, it is the default route, and a client that
# has not passed the portal reaches the portal and nothing else — no 802.1X and
# no dynamic VLAN is asked of the switch, because none is available where this is
# deployed. Nothing extra to type: the bundle says so, and this script then
# prepares the host to route (IPv4 forwarding, the shaping and set modules, both
# persisted) and says what it did. A firewall of your own on this host is left
# exactly as it is, and pointed out.
set -euo pipefail

# Absolute by default so `--reset-trust` finds the installation from any working
# directory — unlike the collector, this script does not live next to its compose
# file (the bundle brings its own).
#: Where the portal is installed when nobody says otherwise: a subdirectory of
#: the directory this script was unpacked into.
#:
#: Beside the script rather than in /opt, because that is where the other
#: satellite already lives — collector-join.sh writes its config next to itself
#: — and because an operator who unpacked the distribution into their home
#: should not need root to create a directory. A SUBdirectory and not the
#: distribution root: the portal's bundle carries a `docker-compose.yml` and a
#: `.env` of its own, and unpacking those over a distribution that has its own
#: pair would replace the product's compose file on a host that may also be a
#: core.
#:
#: An install made by an older version of this script is still found: see the
#: legacy fallback below, which is what keeps --status, --update and --uninstall
#: working on hosts that were set up before this changed.
HERE="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_DIR="${HERE}/captive-portal"
LEGACY_DIR="/opt/taranac/captive-portal"
ANCHOR_NAME="certs/core-ca.pem"
# The datapath's shaping device, by the name the agent gives it
# (datapath/linux.py::IFB_DEVICE). Named here so the interface table can leave
# our own plumbing out of a question about the operator's network.
IFB_DEV="tgw-ifb"
PIN_STATE="/app/data/core-ca.pem"   # inside the container's portal-data volume

CORE=""; TOKEN=""; CA_FILE=""; DIR=""; TRUST_ANY=0; RESET_TRUST=0; UNINSTALL=0; STATUS=0
UPDATE=0; CHECK_ONLY=0

# The header block, in full. The range used to be hard-coded at line 49 while
# the block grew to 74 — so --help stopped mid-usage and never showed
# --reset-trust, --status, --update or --uninstall. Ends where the comments do.
usage() { sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'; }
fail()  { echo "portal-join: $*" >&2; exit 1; }
info()  { echo "portal-join: $*"; }
# Wrong, but not wrong enough to stop: said on stderr so it survives a piped run.
warn()  { echo "portal-join: WARNING: $*" >&2; }

# ── Saying where we are ───────────────────────────────────────────────────────
# An install has a handful of stages and each can fail for its own reason, so it
# says which one it is in. Not decoration: the commonest support question about
# this script used to be "it stopped, what was it doing" — a flat stream of
# `portal-join: …` lines could not answer it, and the answer is the first thing
# needed to know what to try next.
STEP_N=0
# Five steps for a portal, six for a box: the sixth asks how this host is
# wired, which is a question only a box has. Counted rather than hidden so
# an operator watching the numbers knows there is one more thing coming.
# Six for every deployment, and the fifth is "what this host has to become".
# It differs by mode — a box is asked how it is wired, a portal that only
# shows a page has nothing to prepare — but it is the same step, so the numbers
# do not move under an operator who is watching them. A count that changes from
# 5 to 6 halfway through teaches that the count is a guess.
STEP_TOTAL=6
step() { STEP_N=$((STEP_N + 1)); printf '\n[%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$*"; }

# Interactive only when there IS somebody to ask. A missing value used to end in
# `usage` and exit 2, which is right for a script in a pipeline and wrong for a
# person who ran it by hand. `[ -t 0 ]` is the whole test: under the OVA module,
# under automation and over a pipe nothing changes, and the guards below still
# fail exactly as they did.
interactive() { [ -t 0 ]; }

# ask VAR "what it is" "where to get it"
ask() {
  local __var="$1" __label="$2" __hint="$3" __value=""
  printf '\n  %s\n' "$__label"
  [ -n "$__hint" ] && printf '  %s\n' "$__hint"
  while [ -z "$__value" ]; do
    printf '  > '
    IFS= read -r __value || return 1
    __value="${__value#"${__value%%[![:space:]]*}"}"   # a pasted value often
    __value="${__value%"${__value##*[![:space:]]}"}"   # arrives with spaces
  done
  printf -v "$__var" '%s' "$__value"
}

#: The command line as it was typed, kept for the one message that has to hand
#: it back: "run this again with sudo". The parse loop below consumes $@.
ORIGINAL_ARGS="$*"
# How to say "run that again, with sudo" in the words the operator used. When
# the wrapper invoked us it sets this, and telling them to re-run the raw script
# instead would hand back the very path the wrapper exists to hide — and a
# different command from the one the core printed for them to paste.
# The whole re-run command. When the wrapper called us it hands over exactly
# what the operator typed; otherwise we reconstruct it from our own name and
# arguments. Either way the line they read is a line they can paste back.
RERUN_CMD="${TARANAC_CP_RERUN:-$0 ${ORIGINAL_ARGS}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --core)        CORE="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --ca-file)     CA_FILE="$2"; shift 2 ;;   # optional: strict CA verification
    --trust-any)   TRUST_ANY=1; shift ;;      # optional: verify nothing (lab)
    --reset-trust) RESET_TRUST=1; shift ;;    # re-pin after the core's cert changed
    --uninstall)   UNINSTALL=1; shift ;;      # remove this portal from THIS host
    --status)      STATUS=1; shift ;;         # what it is doing, locally
    --update)      UPDATE=1; shift ;;         # move to the version this portal's core runs
    --check)       CHECK_ONLY=1; shift ;;     # …and with --update: report only
    --dir)         DIR="$2"; shift 2 ;;
    # A box's own wiring. Asked for here rather than in the console,
    # because this is the machine the answers are about — and answered
    # interactively when nobody passed them (see host_wizard).
    --client-interface)  GW_CLIENT_IF="$2"; shift 2 ;;
    --uplink-interface)  GW_UPLINK_IF="$2"; shift 2 ;;
    --nat)               GW_NAT="$2"; shift 2 ;;
    --client-isolation)  GW_ISOLATION="$2"; shift 2 ;;
    --dhcp-range)        GW_RANGE="$2"; shift 2 ;;   # "first last" or "first-last"
    --upstream-dns)      GW_DNS="$2"; shift 2 ;;
    -y|--yes)            ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# An install from before this script kept the portal beside itself is still an
# install: found, said out loud, and operated on where it actually is. Only when
# the operator named no directory and there is nothing here to work with.
if [ -z "$DIR" ] && [ ! -f "${DEFAULT_DIR}/docker-compose.yml" ] && [ -f "${LEGACY_DIR}/docker-compose.yml" ]; then
  DIR="$LEGACY_DIR"
  info "using the existing install in ${LEGACY_DIR} (new installs go beside this script)"
fi
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

enforces_here() {
  # Does the bundle in ${DIR} tell this box to open the network itself?
  #
  # One reader for one key. It used to be four separate greps for the same
  # pattern, which is three chances for a rename to leave one of them behind —
  # and the one most likely to be missed is the uninstall's, where being wrong
  # means the datapath stays on a host somebody believes they have cleaned.
  #
  # DEFINED HERE, above the subcommand handlers, because that is where it is
  # first called. It used to live below them, so --status died on its last line
  # with "command not found" and --uninstall read that same failure as "this
  # portal does not enforce" — and quietly skipped taking the datapath off the
  # host. A shell function is not hoisted; a handler that exits never reaches a
  # definition written after it.
  grep -qE '^PORTAL_DATAPATH_ENABLED=true' "${DIR}/.env" 2>/dev/null
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
  # A box has a second thing that can be broken while the page still loads:
  # the datapath. Reported from the host itself, not from the core, for the same
  # reason as everything else here — this is what you run when the core is
  # unreachable.
  if enforces_here; then
    # `grep -c` PRINTS the count and EXITS 1 when the count is zero, so the old
    # `|| echo 0` fired on top of a perfectly good "0" and the line came out
    # over two lines with a stray zero. Every site with no clients yet — that
    # is, every site on the day it is installed — printed a mangled status.
    # Asked of the CONTAINER, not of this host. It shares the host's network
    # namespace, so the answer is the same — but it is the container that carries
    # iptables and ipset, and a correctly installed host carries neither.
    #
    # That mattered more than a missing number: `set -o pipefail` makes a
    # not-found command at the head of a pipeline fail the whole pipeline, and
    # `set -e` then killed --status here, mid-report, without a word. Every
    # datapath site printed four lines and stopped, and the datapath section —
    # the reason this subcommand exists on such a host — never appeared.
    dp() { ${COMPOSE} exec -T portal "$@" 2>/dev/null || true; }
    fwd_rules=$(dp iptables -S TGW_FWD | { grep -c '^-A' || true; })
    allowed=$(dp ipset list tgw_auth | { grep -cE '^[0-9]' || true; })
    starts=$(${COMPOSE} logs --no-color --tail 200 portal 2>/dev/null | { grep -c 'reporting to' || true; })
    # Same trap as the counts above, one line further on and missed when they
    # were fixed: a grep that legitimately finds nothing exits 1, `pipefail`
    # hands that to the assignment, and `set -e` ends the report there. On a
    # site whose agent has not filed a report yet — every site for its first few
    # seconds — this killed --status without printing anything about why.
    last=$(${COMPOSE} logs --no-color --tail 50 portal 2>/dev/null \
      | { grep -oE 'datapath: [a-z].*' || true; } | tail -1 | cut -c1-60)
    info "Datapath:  agent ${starts:-0} start(s) logged, last report ${last:-none yet}"
    info "  forwarding: $([ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = 1 ] && echo on || echo 'OFF — nothing is routed')"
    info "  rules:      ${fwd_rules:-0} forward, ${allowed:-0} client(s) allowed"
  fi
  exit 0
fi

# ── --uninstall: remove this portal from THIS host ───────────────────────────
# Local only, like the collector's: a box being decommissioned frequently cannot
# reach the core any more, and an uninstall that fails exactly then does not work.
# Almost nothing here is lost — a portal holds no collected data of its own, and
# everything it runs on came from the core and can be fetched again.
#
# ONE exception, and it is the one that bites: an operator-placed TLS certificate.
# `certs/` lives inside the install directory, which this removes, so a real
# certificate — Let's Encrypt, or one from the site's own CA — goes with it. That
# is correct (the bundle owns the directory) and it is not obvious, so it is said
# out loud before anything is removed rather than discovered afterwards.
if [ "$UNINSTALL" -eq 1 ]; then
  [ -f "${DIR}/docker-compose.yml" ] || fail "no portal is installed in ${DIR} (use --dir)."
  COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"

  # Only a certificate somebody PUT here. The container writes a self-signed
  # fallback into the same directory on first start, and warning about that one
  # would be crying wolf — it is regenerated on the next install, costs nothing,
  # and a warning an operator learns to click past is worse than none. The
  # fallback names itself in its own subject; anything else was placed.
  if [ -f "${DIR}/certs/portal.crt" ] \
     && ! openssl x509 -in "${DIR}/certs/portal.crt" -noout -subject 2>/dev/null | grep -q 'CN *= *captive-portal'; then
    SUBJ="$(openssl x509 -in "${DIR}/certs/portal.crt" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    ENDS="$(openssl x509 -in "${DIR}/certs/portal.crt" -noout -enddate 2>/dev/null | cut -d= -f2-)"
    cat >&2 <<EOF

portal-join: this will DELETE a TLS certificate that was placed here by hand:
  ${DIR}/certs/portal.crt
  ${SUBJ:-<unreadable subject>}
  valid until ${ENDS:-<unknown>}

It is not the self-signed fallback, so re-installing will not bring it back —
copy it somewhere else first if you still need it.
EOF
    if interactive; then
      printf '\nType yes to remove the portal anyway, anything else to stop.\n  > ' >&2
      IFS= read -r CONFIRM || CONFIRM=""
      case "$CONFIRM" in
        yes|YES|y|Y) ;;
        *) fail "stopped; nothing was removed." ;;
      esac
    else
      echo "portal-join: continuing — no terminal to ask at." >&2
    fi
  fi
  # A box leaves its firewall, NAT and shaping on the HOST, deliberately: a
  # restart must not cut a site off for as long as it takes to come back. An
  # uninstall is the opposite statement, so the rules go first — before the
  # container that knows how to remove them is gone. Best-effort: a host whose
  # agent never started has nothing to remove, and that must not block the rest.
  if enforces_here; then
    info "removing the box's firewall, NAT and shaping from this host…"
    ${COMPOSE} exec -T portal python3 -m datapath.agent --teardown 2>/dev/null \
      || ${COMPOSE} run --rm --no-deps --entrypoint python3 portal \
           -m datapath.agent --teardown 2>/dev/null \
      || echo "portal-join: NOTE — could not run the datapath teardown; check 'iptables -S | grep TGW_' by hand." >&2
  fi
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
  info "done. Watch it re-pin: ${HERE}/taranac captive-portal logs -f portal"
  exit 0
fi

# ── Update ────────────────────────────────────────────────────────────────────
# A portal must match ITS core, not the newest public release: the core it talks
# to is the one whose contract it was built against, and a DMZ box can usually
# reach that core while it often cannot reach a release feed. So "which version"
# is not asked and not guessed — the core answers it by handing over a bundle
# that names the image for its own version.
#
# Needs no arguments at all. The address and the token are already in the
# install; asking for them again would be asking an operator to fetch a fresh
# token for a portal that is working.
#
# Two things are deliberately preserved across it. The wiring settled at install
# time — which NIC faces the guests, which addresses it hands out on it, which
# NIC faces out, NAT, isolation — because those are facts about this host that a
# new bundle knows nothing about, and re-asking them during an upgrade is how an
# upgrade becomes an outage. And the operator's own certificate in certs/, which
# the bundle does not carry.
#
# This list is every key the wizard writes, and it has to stay that way. It used
# to be four, because the other five arrived in the bundle — the console held an
# answer for them. It does not any more: a fetched bundle carries those keys
# empty, so a key missing from this list is a key an update silently blanks, and
# a box whose DHCP range went empty serves nobody. That is the failure this
# line exists to prevent, and it is a quiet one — the update reports success.
UPDATE_KEEP_KEYS="DHCP_INTERFACE DHCP_RANGE_START DHCP_RANGE_END DHCP_SUBNET_MASK
DNS_UPSTREAM PORTAL_UPLINK_INTERFACE PORTAL_NAT
PORTAL_CLIENT_ISOLATION PORTAL_HOST_OPEN_TCP PORTAL_HOST_OPEN_UDP"

env_value_of() {  # env_value_of <file> <key>
  grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true
}

if [ "$UPDATE" -eq 1 ]; then
  [ -f "${DIR}/docker-compose.yml" ] && [ -f "${DIR}/.env" ] \
    || fail "no portal is installed in ${DIR} (use --dir), so there is nothing to update."

  CORE="${CORE:-$(env_value_of "${DIR}/.env" BACKEND_API_URL)}"
  TOKEN="${TOKEN:-$(env_value_of "${DIR}/.env" PORTAL_API_TOKEN)}"
  RUNNING_IMAGE="$(env_value_of "${DIR}/.env" PORTAL_IMAGE)"
  [ -n "$CORE" ]  || fail "this install has no BACKEND_API_URL — it was not installed by this script."
  [ -n "$TOKEN" ] || fail "this install has no PORTAL_API_TOKEN — generate one in the console and re-run the install."

  CORE_ROOT="$(core_root "$CORE")"
  # Two steps here, not the install's six.
  STEP_TOTAL=2

  # What the core would hand us now. Fetched into a scratch directory so
  # --check touches nothing, and so a failed fetch cannot leave the install
  # half-replaced.
  step "Asking ${CORE_ROOT} which version this portal should be on"
  UPD_WORK="$(mktemp -d)"
  trap 'rm -rf "${UPD_WORK}"' EXIT
  CURL_TRUST_OPTS=""
  if [ "$TRUST_ANY" -eq 1 ]; then
    CURL_TRUST_OPTS="-k"
  elif [ -f "${DIR}/${ANCHOR_NAME}" ]; then
    CURL_TRUST_OPTS="--cacert ${DIR}/${ANCHOR_NAME}"
  fi
  # shellcheck disable=SC2086
  HTTP_CODE="$(curl -sS ${CURL_TRUST_OPTS} -o "${UPD_WORK}/bundle.tar.gz" -w '%{http_code}' \
      -H "X-Portal-Token: ${TOKEN}" \
      "${CORE_ROOT}/api/v1/captive-portal/bootstrap-bundle" 2>"${UPD_WORK}/curl.err")" || HTTP_CODE="000"
  case "$HTTP_CODE" in
    200) ;;
    401|403) fail "the core rejected this portal's token (HTTP ${HTTP_CODE}) — generate a fresh one and re-run the install." ;;
    000) sed 's/^/  /' "${UPD_WORK}/curl.err" >&2
         fail "could not reach ${CORE_ROOT}. An update needs the core: it is the core's version we move to." ;;
    *)   fail "the core answered HTTP ${HTTP_CODE} for the bundle." ;;
  esac
  tar xzf "${UPD_WORK}/bundle.tar.gz" -C "${UPD_WORK}" --strip-components=1 2>/dev/null \
    || fail "what the core returned is not a readable bundle."
  TARGET_IMAGE="$(env_value_of "${UPD_WORK}/.env" PORTAL_IMAGE)"
  [ -n "$TARGET_IMAGE" ] || fail "the bundle the core returned names no image."

  if [ "$RUNNING_IMAGE" = "$TARGET_IMAGE" ]; then
    info "already in step with the core: ${TARGET_IMAGE}"
    exit 0
  fi
  info "this portal runs ${RUNNING_IMAGE:-<unset>}"
  info "its core wants    ${TARGET_IMAGE}"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "--check: nothing changed."
    exit 0
  fi

  # Keep what only this host knows, and keep a copy of everything else.
  ENV_BACKUP="${DIR}/.env.before-update-$(date -u +%Y%m%d-%H%M%S)"
  # The WHOLE install, not just its .env. A rollback used to restore that one
  # file and leave docker-compose.yml, portal.conf and everything else from the
  # new bundle in place — so "rolled back" meant the old image tag running
  # against the new configuration, which is a combination nobody has ever
  # tested. Kept beside the install so it survives this shell.
  ROLLBACK_DIR="${DIR}/.rollback-$(date -u +%Y%m%d-%H%M%S)"
  cp "${DIR}/.env" "$ENV_BACKUP"
  step "Updating ${RUNNING_IMAGE:-<unset>} → ${TARGET_IMAGE}"
  for key in $UPDATE_KEEP_KEYS; do
    value="$(env_value_of "$ENV_BACKUP" "$key")"
    [ -n "$value" ] || continue
    if grep -qE "^${key}=" "${UPD_WORK}/.env"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "${UPD_WORK}/.env"
    else
      printf '%s=%s\n' "$key" "$value" >> "${UPD_WORK}/.env"
    fi
  done
  # The token, which a freshly minted bundle carries but a re-fetched one may
  # carry as a placeholder if the core rotated it.
  if grep -qE '^PORTAL_API_TOKEN=(<YOUR_API_TOKEN>)?$' "${UPD_WORK}/.env"; then
    sed -i "s|^PORTAL_API_TOKEN=.*|PORTAL_API_TOKEN=${TOKEN}|" "${UPD_WORK}/.env"
  fi

  # Everything from the new bundle EXCEPT what the host owns: certs/ is the
  # operator's (the bundle carries none when no certificate is bound) and the
  # pinned anchor was learned here.
  #
  # Piped through tar rather than a glob, because a shell glob skips dotfiles —
  # and the one file that decides everything here is `.env`. Caught by the test
  # that asserts the image actually moved: the wiring survived, the certificate
  # survived, and the version had not changed at all.
  mkdir -p "$ROLLBACK_DIR"
  ( cd "$DIR" && tar cf - --exclude=./certs --exclude="./$(basename "$ROLLBACK_DIR")" . ) \
    | ( cd "$ROLLBACK_DIR" && tar xf - ) \
    || fail "could not take a copy of the current install; refusing to update over it."

  ( cd "${UPD_WORK}" && tar cf - --exclude=./certs . ) | ( cd "$DIR" && tar xf - ) \
    || fail "could not write the new bundle into ${DIR}."
  if [ -d "${UPD_WORK}/certs" ]; then
    mkdir -p "${DIR}/certs"
    cp -a "${UPD_WORK}/certs/." "${DIR}/certs/" 2>/dev/null || true
  fi

  COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"
  SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ${COMPOSE} pull portal || fail "could not pull ${TARGET_IMAGE}. On an air-gapped host, load the image first (docker load), then run this again."
  ${COMPOSE} up -d

  # The same signal an install waits for, and for the same reason: a portal that
  # serves its page while the channel to the core is refused is the failure this
  # check exists to catch. An update that cannot prove it goes back.
  info "waiting for the new version to reach the core…"
  REACHED=0; WAITED=0; LOG=""
  while [ "$WAITED" -lt 90 ]; do
    LOG="$(${COMPOSE} logs --since "$SINCE" --no-color portal 2>&1 || true)"
    case "$LOG" in *"Heartbeat accepted by the core"*) REACHED=1; break ;; esac
    sleep 3
    WAITED=$((WAITED + 3))
  done

  if [ "$REACHED" -eq 0 ]; then
    warn "the new version did not reach the core — rolling back to ${RUNNING_IMAGE}"
    ( cd "$ROLLBACK_DIR" && tar cf - . ) | ( cd "$DIR" && tar xf - ) || true
    ${COMPOSE} up -d || true
    printf '%s\n' "$LOG" | tail -12 | sed 's/^/  /' >&2
    # NOT ${UPD_WORK}: the EXIT trap removes that directory, and `fail` exits —
    # so the old wording pointed an operator at a path that was already gone by
    # the time they finished reading the sentence.
    fail "rolled back. The install is on ${RUNNING_IMAGE} again, restored whole from ${ROLLBACK_DIR}."
  fi

  rm -rf "$ROLLBACK_DIR"
  info "updated to ${TARGET_IMAGE} and reaching the core."
  info "the previous .env is kept at ${ENV_BACKUP}"
  exit 0
fi

# ── Guards ────────────────────────────────────────────────────────────────────
cat <<'EOF'

  Taranac — standalone captive portal installer

  This host will serve the portal page for its Registration VLAN and reach the
  core for two things only: a guest's login, and a heartbeat. It holds no
  database, and nothing is installed beside it.

  It needs two things from you, and the core prints both:
    NAC -> Captive Portals -> <portal> -> Deployment -> Generate Token
EOF

# Asked rather than refused. Everything below still fails exactly as it did when
# there is nobody at the keyboard — under the OVA module, in a pipeline, over ssh
# with a here-doc — so automation is unchanged.
if interactive; then
  [ -n "$CORE" ]  || ask CORE  "The core's base URL" \
      "e.g. https://core.example — edit it if this host reaches the core by a different name."
  [ -n "$TOKEN" ] || ask TOKEN "This portal's API token" \
      "starts with cp_live_ — it is a standing credential, not a one-shot code."
fi

step "Checking this host, and what you gave it"
# What this install actually needs, checked before a token is spent and a bundle
# is fetched — the failure it replaces was `mkdir: cannot create directory
# '/opt/taranac'` at step 3 of 6, which reads as "the installer broke" rather
# than "you cannot write there".
#
# Root is NOT demanded outright. A plain portal needs a directory it can write
# and a docker it can talk to, and a member of the docker group installing into
# their own unpacked distribution has both. A DATAPATH needs more — forwarding
# and kernel modules — and is told so at the point where that is attempted,
# after the bundle has said which kind of portal this is.
if [ -e "$DIR" ]; then
  [ -w "$DIR" ] || fail "cannot write ${DIR}. Either re-run with sudo, or point --dir at a directory you own."
else
  parent="$(dirname "$DIR")"
  [ -d "$parent" ] || fail "${parent} does not exist — unpack the distribution somewhere you can write, or pass --dir."
  [ -w "$parent" ] || fail "cannot create ${DIR} (${parent} is not writable by $(id -un)). Re-run with sudo, or pass --dir <a directory you own>."
fi
docker info >/dev/null 2>&1 || fail "cannot talk to docker as $(id -un). Re-run with sudo, or add this user to the docker group and log in again."
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
step "Establishing trust in the core, and fetching this portal's bundle"
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
step "Unpacking the bundle into ${DIR}"
# Remember whether this is a re-install: portal.conf is a bind-mounted FILE, so a
# fresh one is not picked up by `up -d` (nothing about the container changed) and
# nginx would keep serving the old config. See the restart below.
REINSTALL=0
[ -f "${DIR}/docker-compose.yml" ] && REINSTALL=1

# What this host answered LAST time, read before the new bundle overwrites it.
# A re-install is the documented way to change the wiring, so these are offered
# as defaults rather than silently kept — but they are the best defaults there
# are: they describe this machine, and the console's proposals describe a
# machine somebody imagined. Without them a re-run asks every question again
# with the console's answers in the brackets, and the operator re-types what
# they settled five minutes ago.
PREV_CLIENT_IF=""; PREV_UPLINK_IF=""; PREV_NAT=""; PREV_ISOLATION=""
PREV_RANGE_START=""; PREV_RANGE_END=""; PREV_DNS_UPSTREAM=""; PREV_HOST_OPEN=""
if [ -f "${DIR}/.env" ]; then
  PREV_CLIENT_IF="$(env_value_of "${DIR}/.env" DHCP_INTERFACE)"
  PREV_UPLINK_IF="$(env_value_of "${DIR}/.env" PORTAL_UPLINK_INTERFACE)"
  PREV_NAT="$(env_value_of "${DIR}/.env" PORTAL_NAT)"
  PREV_ISOLATION="$(env_value_of "${DIR}/.env" PORTAL_CLIENT_ISOLATION)"
  PREV_RANGE_START="$(env_value_of "${DIR}/.env" DHCP_RANGE_START)"
  PREV_RANGE_END="$(env_value_of "${DIR}/.env" DHCP_RANGE_END)"
  PREV_DNS_UPSTREAM="$(env_value_of "${DIR}/.env" DNS_UPSTREAM)"
  # Not a question anybody is asked — it is set by hand, in that file, for one
  # site's cabling — so a re-install carries it across rather than losing it.
  PREV_HOST_OPEN="$(env_value_of "${DIR}/.env" PORTAL_HOST_OPEN_TCP)"
fi

# A box being re-installed takes its old datapath off the host FIRST.
#
# The chains are rebuilt whole on the next report, so those repair themselves.
# Two things do not: the traffic shaper's root qdisc, and bridge-port isolation.
# Both are attached to the interface that was answered LAST time, and a
# re-install is precisely the moment that answer changes — leaving a host with a
# shaper on a NIC nothing uses any more and ports isolated for a segment that
# has moved. Neither has a symptom on this box, which is what makes it worth
# doing rather than documenting.
#
# Best-effort and quiet: a host whose agent never came up has nothing to remove,
# and that must not stop a re-install.

mkdir -p "$DIR"
# --warning=no-timestamp: the core builds the archive at the instant it is asked
# for, and a host whose clock is a few milliseconds behind then prints a warning
# per file about timestamps "in the future". Nothing is wrong, but six warnings
# in the middle of an install read as six things going wrong.
tar xzf "$BUNDLE" -C "$DIR" --strip-components=1 --warning=no-timestamp \
  || fail "could not unpack the bundle into ${DIR}."
[ -f "${DIR}/docker-compose.yml" ] && [ -f "${DIR}/.env" ] \
  || fail "the archive is not a portal bundle (no docker-compose.yml/.env inside)."

# Root unpacked it, but root is not who lives here.
#
# A datapath install has to be run with sudo — it loads kernel modules and
# persists them — and every file it writes then belongs to root, .env at 0600.
# Docker Compose reads .env on EVERY command, so from that moment each ordinary
# `./taranac captive-portal logs|ps|status` fails with "permission denied" for
# the user who owns the directory. The installer had just finished printing
# those very commands.
#
# So the files are handed back to whoever owns the install directory. The mode
# is untouched: .env carries this portal's standing credential and stays 0600 —
# readable by its owner, which is the whole point, and by nobody else.
if [ "$(id -u)" -eq 0 ]; then
  DIR_OWNER="$(stat -c '%U:%G' "$DIR" 2>/dev/null || true)"
  case "$DIR_OWNER" in
    ""|root:*) : ;;   # nobody else to hand it to
    *) chown -R "$DIR_OWNER" "$DIR" 2>/dev/null \
         && info "install directory left to ${DIR_OWNER} — sudo was needed for the host, not for running the portal" ;;
  esac
fi


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
step "Checking the portal image and its certificate"

# The certificate, said before anything starts rather than discovered by a guest.
#
# Two silences used to look identical from here: a bundle with no certificate
# (the portal makes a self-signed one and every guest sees a warning) and a
# bundle whose certificate is for a name this deployment will not be reached
# by. The second is the common one, and it is invisible until somebody holds a
# phone — so both are said out loud, with what to do about each.
if [ -s "${DIR}/certs/portal.crt" ]; then
  CERT_SUBJECT="$(openssl x509 -in "${DIR}/certs/portal.crt" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  CERT_UNTIL="$(openssl x509 -in "${DIR}/certs/portal.crt" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  info "certificate in this bundle: ${CERT_SUBJECT:-unreadable}"
  [ -n "${CERT_UNTIL}" ] && info "  valid until ${CERT_UNTIL}"
  echo "portal-join:   Guests reach this portal by whatever name resolves to it here — if that is" >&2
  echo "portal-join:   not the name above, their browser will say so before it shows the page." >&2
else
  cat >&2 <<EOF
portal-join: no certificate in this bundle — the portal will generate a self-signed
portal-join: one on first start. The sign-in page works; a guest's browser warns
portal-join: about the name.
portal-join:
portal-join: To give it a real one, either
portal-join:   • bind a certificate from the core's PKI (portal -> General -> Server
portal-join:     certificate) and run this installer again; or
portal-join:   • put the files here yourself and restart the portal:
portal-join:       ${DIR}/certs/portal.crt   (fullchain, 0644)
portal-join:       ${DIR}/certs/portal.key   (private key, 0600)
portal-join:
portal-join: Keep your copy somewhere else: --uninstall deletes this directory.
EOF
fi

info "checking the portal image is on this host…"
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

# Offered, not chosen. The tag in the bundle comes from the version the CORE
# reports, so the commonest way to arrive here is a core running a build nobody
# published — and then the right image is very often already on this disk under
# another tag. Printing a list and asking beats printing a list and exiting,
# which is what this did.
#
# It stays an OFFER: running a portal from a different release than the core is a
# real decision, and it is the operator's. With nobody at the keyboard the block
# below is skipped entirely and the refusal is exactly what it always was.
if [ -n "$WANT_IMAGE" ] && ! docker image inspect "$WANT_IMAGE" >/dev/null 2>&1 && interactive; then
  HAVE="$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
          | grep -i captive-portal | grep -v '<none>' | sort -u || true)"
  if [ -n "$HAVE" ]; then
    printf '\n  The image this bundle asks for is not on this host:\n    %s\n' "$WANT_IMAGE"
    printf '\n  These captive-portal images ARE here:\n'
    printf '%s\n' "$HAVE" | sed 's/^/    /'
    printf '\n  Type one to use it, or press Enter to stop and load the right image.\n  > '
    IFS= read -r PICKED || PICKED=""
    PICKED="${PICKED#"${PICKED%%[![:space:]]*}"}"; PICKED="${PICKED%"${PICKED##*[![:space:]]}"}"
    if [ -n "$PICKED" ]; then
      if docker image inspect "$PICKED" >/dev/null 2>&1; then
        sed -i "s|^PORTAL_IMAGE=.*|PORTAL_IMAGE=${PICKED}|" "${DIR}/.env"
        WANT_IMAGE="$PICKED"
        info "using ${PICKED} — written to ${DIR}/.env, so a restart resolves the same one"
      else
        fail "'${PICKED}' is not an image on this host either."
      fi
    fi
  fi
fi

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

# ── Datapath wiring: asked here, because this is the host it is about ─────────
# What the console cannot know and kept being asked anyway: the names of this
# machine's network interfaces. Typed into a browser on another computer they
# were a guess, and a wrong guess produces a box that looks configured,
# reports healthy and serves nobody.
#
# So the four facts are settled here, in this order of preference: what the
# operator passed on the command line, then what they confirm from proposals we
# can justify, then a refusal that names the exact command to re-run. Never a
# silent default — a box that quietly picked the wrong NIC is the failure
# this whole arrangement exists to prevent.
#
# The proposals are derived rather than guessed:
#   uplink  — the interface carrying the default route. If the host reaches the
#             core and the internet at all, it does so through that one.
#   client  — the interface holding an address inside the DHCP range the CORE
#             configured for this portal. The range says where the clients are,
#             so the NIC that answers in that subnet is the one facing them.
#             Falls back to DHCP_INTERFACE from the bundle if it exists here.
gw_interfaces_table() {
  # NAME  ADDRESS  ROLE — everything an operator needs to answer the question,
  # and nothing else. `ip -o` because its one-line-per-record output is stable
  # across versions in a way the pretty form is not.
  local default_if; default_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | sort -u | while read -r iface; do
    [ "$iface" = "lo" ] && continue
    # Not somebody's network: the datapath's own shaping device, which this
    # installer created on an earlier run. It is absent on a fresh host and
    # present on every re-install, and picking it — which this table invites —
    # points the portal at itself.
    [ "$iface" = "$IFB_DEV" ] && continue
    local addr; addr="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    local role=""
    [ "$iface" = "$default_if" ] && role="default route"
    [ -z "$addr" ] && addr="(no address)"
    printf '    %-12s %-18s %s\n' "$iface" "$addr" "$role"
  done
}

gw_default_uplink() { ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'; }

gw_guess_client_if() {
  # The NIC whose address falls inside the portal's own DHCP range.
  local range_start="$1" mask="$2" bundle_if="$3"
  if [ -n "$range_start" ] && [ -n "$mask" ]; then
    local prefix; prefix="$(printf '%s' "$range_start" | cut -d. -f1-3)"
    local found
    found="$(ip -o -4 addr show 2>/dev/null | awk -v p="${prefix}." '$4 ~ "^"p {print $2; exit}')"
    [ -n "$found" ] && { printf '%s' "${found%%@*}"; return 0; }
  fi
  # Then whatever the core was told, if it is really here.
  if [ -n "$bundle_if" ] && ip link show "$bundle_if" >/dev/null 2>&1; then
    printf '%s' "$bundle_if"; return 0
  fi

  # And finally: is there exactly ONE candidate on this host?
  #
  # This is not a guess, it is a deduction, and it became load-bearing when the
  # console stopped storing addresses — the first branch above has nothing to
  # match against on a fresh bundle, so a two-NIC box with an obvious answer was
  # refusing to install non-interactively.
  #
  # A candidate is an interface that is up, carries an IPv4 address, is not
  # loopback, is not the default route (that is the way OUT), and is not one of
  # Docker's own — those are not wires anybody plugged a guest into. One
  # survivor is the answer; two or more and we still refuse, because at that
  # point somebody has to say which.
  local uplink candidates count
  uplink="$(gw_default_uplink)"
  candidates="$(ip -o -4 addr show 2>/dev/null \
    | awk '{print $2}' \
    | sed 's/@.*//' \
    | grep -vxE 'lo|docker[0-9]*|br-[0-9a-f]+|veth.*|virbr[0-9]*' \
    | grep -vx "${uplink:-__none__}" \
    | sort -u)"
  count="$(printf '%s\n' "$candidates" | grep -c . || true)"
  if [ "${count:-0}" = "1" ]; then
    printf '%s' "$candidates"; return 0
  fi
  printf ''
}

# ── Address arithmetic, so a typo is caught here and not by a guest ──────────
# The core validates what it stores, but three things can still be wrong on THIS
# host: the guests' NIC may have no address at all, its network may not be the
# one the core configured a range in, and the mask may disagree with the NIC's
# prefix. Every one of them installs cleanly and serves nobody, which is the
# failure this wizard exists to make impossible.
gw_cidr_of() { ip -o -4 addr show dev "${1:-}" 2>/dev/null | awk '{print $4; exit}'; }

gw_ip_int() {  # dotted quad -> integer, or nothing and a non-zero exit
  local a b c d rest part
  IFS=. read -r a b c d rest <<<"${1:-}"
  [ -n "${d:-}" ] && [ -z "${rest:-}" ] || return 1
  for part in "$a" "$b" "$c" "$d"; do
    case "$part" in ''|*[!0-9]*) return 1 ;; esac
    [ "$part" -le 255 ] || return 1
  done
  printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

gw_mask_prefix() {  # 255.255.255.0 -> 24. Refuses a mask with holes in it.
  local int bits
  int="$(gw_ip_int "${1:-}")" || return 1
  for bits in $(seq 0 32); do
    if [ "$int" -eq "$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))" ]; then
      printf '%s' "$bits"; return 0
    fi
  done
  return 1
}

gw_same_net() {  # addr_a addr_b prefix -> 0 when both are in one network
  local a b prefix mask
  a="$(gw_ip_int "${1:-}")" || return 1
  b="$(gw_ip_int "${2:-}")" || return 1
  prefix="${3:-}"
  case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
  [ "$prefix" -le 32 ] || return 1
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  [ "$(( a & mask ))" -eq "$(( b & mask ))" ]
}

gw_yesno() {  # gw_yesno "question" default(Y|n) -> echoes on|off
  local question="$1" default="$2" answer=""
  if [ "${ASSUME_YES:-0}" -eq 1 ] || ! interactive; then
    [ "$default" = "Y" ] && printf 'on' || printf 'off'
    return 0
  fi
  printf '\n  %s [%s/%s] ' "$question" "$([ "$default" = Y ] && echo Y || echo y)" "$([ "$default" = Y ] && echo n || echo N)" >&2
  IFS= read -r answer || true
  case "${answer:-}" in
    [Yy]*) printf 'on' ;;
    [Nn]*) printf 'off' ;;
    *)     [ "$default" = "Y" ] && printf 'on' || printf 'off' ;;
  esac
}

gw_normalize_switch() {  # on/off/true/false/yes/no/1/0 -> on|off, or empty
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    on|true|yes|y|1|enabled)   printf 'on' ;;
    off|false|no|n|0|disabled) printf 'off' ;;
    *) printf '' ;;
  esac
}

gw_ip_from_int() {  # integer -> dotted quad
  local n="${1:-0}"
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

gw_prefix_to_mask() {  # 24 -> 255.255.255.0
  local bits="${1:-0}"
  gw_ip_from_int $(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
}

# A range for the segment the guests' interface is actually on. Not a guess at
# what the operator wants — a usable default they are then asked about, because
# the alternative when the console's proposal does not fit this host is to hand
# out addresses nobody can use.
gw_derive_range() {  # cidr -> "start end mask"
  local cidr="${1:-}" addr prefix addr_int mask net bcast first last start end
  addr="${cidr%%/*}"; prefix="${cidr##*/}"
  addr_int="$(gw_ip_int "$addr")" || return 1
  case "$prefix" in ''|*[!0-9]*) return 1 ;; esac
  [ "$prefix" -le 30 ] || return 1
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  net=$(( addr_int & mask ))
  bcast=$(( net | (0xFFFFFFFF ^ mask) ))
  first=$(( net + 1 )); last=$(( bcast - 1 ))
  # .100–.200 of the segment where it fits, which is what an operator expects to
  # see on a /24; squeezed into whatever is available on a smaller one.
  start=$(( net + 100 )); end=$(( net + 200 ))
  [ "$start" -gt "$last" ] && start=$first
  [ "$end" -gt "$last" ] && end=$last
  [ "$start" -gt "$end" ] && start=$first
  printf '%s %s %s' "$(gw_ip_from_int "$start")" "$(gw_ip_from_int "$end")" "$(gw_prefix_to_mask "$prefix")"
}

gw_host_resolver() {  # the resolver THIS host uses, if it is one a portal can ask
  # systemd's stub (127.0.0.53) answers only for this host, and 127.x in general
  # is not reachable from the portal's container — so a stub is not an answer
  # here, and the fallback is a public resolver the operator can change.
  #
  # Every nameserver, not just the first. `exit` after the first line made the
  # filter below decorative: on a host whose resolv.conf opens with the stub and
  # names a real resolver underneath it, awk handed grep the stub, grep dropped
  # it, and the real one was never looked at.
  #
  # And `|| true`, which is load-bearing. grep exits 1 when it filters
  # everything away — the ordinary case on a plain Ubuntu host, where the stub
  # is the ONLY nameserver — and this is called from inside a `$(…)` in an
  # assignment, so that 1 became the assignment's status and `set -e` ended the
  # install. Silently, at step 5 of 6, with the next line already written to
  # handle an empty answer. Measured on .42: a standalone portal could not be
  # installed on a stock Ubuntu host at all.
  awk '/^nameserver/ {print $2}' "${RESOLV_CONF:-/etc/resolv.conf}" 2>/dev/null \
    | grep -vE '^127\.' | head -1 || true
}

gw_range_fits() {  # cidr first last -> 0 when both ends are inside it, in order
  local cidr="${1:-}" first="${2:-}" last="${3:-}" a b
  [ -n "$first" ] && [ -n "$last" ] || return 1
  gw_same_net "${cidr%%/*}" "$first" "${cidr##*/}" || return 1
  gw_same_net "${cidr%%/*}" "$last" "${cidr##*/}" || return 1
  a="$(gw_ip_int "$first")" || return 1
  b="$(gw_ip_int "$last")" || return 1
  [ "$a" -le "$b" ]
}

gw_ask_interface() {  # question default role range_start -> echoes a name that EXISTS here
  local question="$1" suggested="$2" role="$3" range="$4" answer="" tries=0 name=""
  # Three, not five: a typo is caught in one or two, and a wrong CONSOLE setting
  # is not going to become right on the fifth ask — that one needs somebody to
  # go and change it, which the message says.
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    printf '\n  %s\n' "$question" >&2
    printf '  [%s] > ' "${suggested:-?}" >&2
    IFS= read -r answer || true
    name="${answer:-$suggested}"

    if [ -z "$name" ]; then
      printf '  This host cannot tell — name one of these:\n' >&2
      gw_interfaces_table >&2
      continue
    fi
    if ! ip link show "$name" >/dev/null 2>&1; then
      printf '  There is no interface called "%s" here:\n' "$name" >&2
      gw_interfaces_table >&2
      continue
    fi
    # The guests' side has two more requirements, and both are cheaper to learn
    # now than after the install: it must have an address (it becomes their
    # default route) and that address must be in the network the core hands out
    # from (otherwise every guest gets an address it cannot use).
    if [ "$role" = "client" ]; then
      local cidr; cidr="$(gw_cidr_of "$name")"
      if [ -z "$cidr" ]; then
        printf '  %s has no IPv4 address — the guests are handed that address as\n' "$name" >&2
        printf '  their default route, and the portal binds DHCP and DNS to it.\n' >&2
        gw_interfaces_table >&2
        continue
      fi
    fi
    printf '%s' "$name"
    return 0
  done
  # Not a typo any more. The caller says what to do about it.
  return 1
}

host_wizard() {
  local env_file="${DIR}/.env"
  local bundle_if range_start range_end mask
  bundle_if="$(grep -E '^DHCP_INTERFACE=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  range_start="$(grep -E '^DHCP_RANGE_START=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  range_end="$(grep -E '^DHCP_RANGE_END=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  mask="$(grep -E '^DHCP_SUBNET_MASK=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"

  local want_client want_uplink
  want_client="${GW_CLIENT_IF:-}"
  want_uplink="${GW_UPLINK_IF:-}"

  # Nothing is read from the console about the wiring any more: the console does
  # not hold any. What was "Install defaults" — an interface, a range, an
  # uplink, two switches — described a machine it had never seen, and every one
  # of those values is either known here or asked here. The keys in .env are
  # what THIS wizard writes, and what a previous run of it wrote.

  local guess_client guess_uplink
  guess_client="${PREV_CLIENT_IF:-$(gw_guess_client_if "$range_start" "$mask" "$bundle_if")}"
  guess_uplink="${PREV_UPLINK_IF:-$(gw_default_uplink)}"
  # …and the addresses this host was serving, which are by definition a range
  # that fits the interface it was serving them on.
  if [ -n "${PREV_RANGE_START:-}" ]; then
    range_start="$PREV_RANGE_START"
    [ -n "${PREV_RANGE_END:-}" ] && range_end="$PREV_RANGE_END"
  fi

  if [ -z "$want_client" ] || { [ "${ENFORCES_HERE:-0}" -eq 1 ] && [ -z "$want_uplink" ]; }; then
    if interactive && [ "${ASSUME_YES:-0}" -eq 0 ]; then
      cat >&2 <<EOF

  ── This host serves a segment ─────────────────────────────────────────────
$(if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
    printf '  This portal OPENS ACCESS ITSELF: it hands out the guests'"'"' addresses, it is their\n'
    printf '  default route, and a guest who has not passed it reaches the portal and\n'
    printf '  nothing else.\n'
  else
    printf '  This portal serves its registration VLAN: it hands out the addresses there\n'
    printf '  and answers DNS, so that a device that has not signed in finds the portal.\n'
    printf '  It does not route — the switch decides what a signed-in device may reach.\n'
  fi)

  Only this machine knows these answers, which is why they are asked here and
  not in the console.

  Interfaces on this host:
$(gw_interfaces_table)
EOF
      if [ -n "${PREV_CLIENT_IF:-}" ]; then
        printf '\n  This host has been installed before — the answers it gave then are the\n' >&2
        printf '  defaults below. Press Enter to keep them, or type something else.\n' >&2
      fi
      [ -n "$range_start" ] && printf '\n  The core configured this portal to hand out addresses from %s.\n' "$range_start" >&2
      # Each answer is judged as it is given. Asking both and then refusing sent
      # the operator back to the start of a six-step install over one typo —
      # they had already answered the second question by the time the first was
      # called wrong.
      # `set -e` would kill the script on a failing command substitution, and
      # in the one place where that happened it killed it SILENTLY: three bad
      # answers and the shell prompt came back with no line saying why. Handled
      # here, where the reason is still known.
      if ! want_client="$(gw_ask_interface \
          "Which interface faces the GUESTS? (DHCP, DNS and the sign-in page live there)" \
          "$guess_client" "client" "$range_start")"; then
        echo "portal-join: stopping without installing anything — three answers that are not" >&2
        echo "portal-join: interfaces on this host, or are interfaces without an address." >&2
        echo "portal-join: The guests' side has to be a NIC that exists here and holds an" >&2
        echo "portal-join: address: that address is what they are handed as their box." >&2
        fail "name it on the command line instead: $0 --client-interface <if> --uplink-interface <if>"
      fi
      if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
        if ! want_uplink="$(gw_ask_interface \
            "Which interface is the way OUT (towards the rest of the network)?" \
            "$guess_uplink" "uplink" "")"; then
          echo "portal-join: stopping without installing anything." >&2
          fail "name the way out yourself: $0 --uplink-interface <if>"
        fi
      fi
    else
      want_client="${want_client:-$guess_client}"
      want_uplink="${want_uplink:-$guess_uplink}"
    fi
  fi

  # Refuse rather than pick. Both of these have a right answer that only
  # somebody on this host knows, and a wrong one is a site that serves nobody.
  if [ -z "$want_client" ]; then
    echo "portal-join: I cannot tell which interface faces the guests on this host." >&2
    echo "portal-join: Interfaces here:" >&2
    gw_interfaces_table >&2
    fail "name it: $0 --client-interface <if> --uplink-interface <if> (see --help)"
  fi
  ip link show "$want_client" >/dev/null 2>&1 || {
    echo "portal-join: there is no interface called '${want_client}' on this host." >&2
    gw_interfaces_table >&2
    fail "name one that exists."
  }
  # The way out is a box's question: a portal that does not route has no
  # second side, and asking for one would be asking about a thing that does not
  # exist in that deployment.
  if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
    if [ -z "$want_uplink" ]; then
      echo "portal-join: this host has no default route, so I cannot tell which interface" >&2
      echo "portal-join: is the way out of the guest segment." >&2
      gw_interfaces_table >&2
      fail "name it: $0 --uplink-interface <if>"
    fi
    ip link show "$want_uplink" >/dev/null 2>&1 || {
      echo "portal-join: there is no interface called '${want_uplink}' on this host." >&2
      gw_interfaces_table >&2
      fail "name one that exists."
    }
    [ "$want_client" = "$want_uplink" ] && fail "the guest side and the way out cannot be the same interface (${want_client}) — a box routes BETWEEN two segments."
  fi

  # ── The range, reconciled with the interface the HOST chose ────────────────
  # The console's range is a proposal, like everything else in Install defaults:
  # it was typed about a machine the console cannot see. The person standing
  # here has just named the interface that faces the guests, and that interface
  # decides which addresses can work. So a range that does not fit it is not a
  # reason to refuse their answer — it is a proposal this host has outgrown, and
  # the fix is offered rather than demanded.
  #
  # Whatever is settled here is written into .env exactly like the wiring, and
  # reported back to the core, which then shows the difference against what was
  # proposed. That is the whole point of the instance drawer.
  gw_ask_range() {  # <client interface> — settle the addresses the guests get
    local iface="$1" cidr derived fallback_start fallback_end mask
    local suggest_start suggest_end answer start end tries=0
    cidr="$(gw_cidr_of "$iface")"
    [ -n "$cidr" ] || return 0
    derived="$(gw_derive_range "$cidr")" || return 0
    fallback_start="${derived%% *}"
    fallback_end="$(printf '%s' "$derived" | cut -d' ' -f2)"
    mask="${derived##* }"

    # What stands in the brackets is what the CONSOLE proposed — that is what a
    # default means here, and it is offered even when this host cannot use it.
    # Pressing Enter then gets the same answer as typing it would: the range is
    # judged, not the way it arrived. Only after it has been refused once does
    # the suggestion become the one derived from this interface, so the second
    # Enter has something that works behind it.
    suggest_start="${range_start:-$fallback_start}"
    suggest_end="${range_end:-$fallback_end}"

    # A flag decides without asking, and -y means "do not ask me anything".
    #
    # Validated all the same. It used to be split and written straight into
    # .env: a typo installed cleanly, reported healthy and served nobody —
    # exactly the failure the questions below exist to prevent, walked around by
    # the one path that never sees them. Refused rather than corrected, because
    # somebody who passed the flag has an answer in mind and silently using a
    # different one is worse than stopping.
    if [ -n "${GW_RANGE:-}" ]; then
      start="${GW_RANGE%%[-,: ]*}"; end="${GW_RANGE##*[-,: ]}"
      gw_ip_int "$start" >/dev/null 2>&1 && gw_ip_int "$end" >/dev/null 2>&1 \
        || fail "--dhcp-range ${GW_RANGE}: expected two IPv4 addresses, as 'first last' or 'first-last'."
      gw_range_fits "$cidr" "$start" "$end" \
        || fail "--dhcp-range ${start} – ${end} does not fit ${iface} (${cidr}), or the two are the wrong way round."
    elif [ "${ASSUME_YES:-0}" -eq 1 ] || ! interactive; then
      if gw_range_fits "$cidr" "$suggest_start" "$suggest_end"; then
        start="$suggest_start"; end="$suggest_end"
      else
        start="$fallback_start"; end="$fallback_end"
        warn "the proposed range does not fit ${iface} (${cidr}) — handing out ${start} – ${end} instead."
      fi
    else
      while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        printf '\n  Which addresses should the guests get? (first and last)\n' >&2
        printf '  [%s %s] > ' "$suggest_start" "$suggest_end" >&2
        IFS= read -r answer || true
        if [ -z "${answer:-}" ]; then
          start="$suggest_start"; end="$suggest_end"
        else
          start="$(printf '%s' "$answer" | awk '{print $1}' | cut -d- -f1)"
          end="$(printf '%s' "$answer" | awk '{print $2}')"
          [ -n "${end:-}" ] || end="$(printf '%s' "$answer" | awk -F- '{print $2}')"
        fi
        if [ -z "${start:-}" ] || [ -z "${end:-}" ]; then
          printf '  Two addresses, please — "%s %s" or "%s-%s".\n' \
            "$fallback_start" "$fallback_end" "$fallback_start" "$fallback_end" >&2
          suggest_start="$fallback_start"; suggest_end="$fallback_end"; start=""; continue
        fi
        if gw_range_fits "$cidr" "$start" "$end"; then
          break
        fi
        printf '  That range does not fit %s, which is %s: both ends have to be inside\n' "$iface" "$cidr" >&2
        printf '  that network and in order, or the guests cannot reach the box they\n' >&2
        printf '  are handed. This host can serve %s – %s.\n' "$fallback_start" "$fallback_end" >&2
        suggest_start="$fallback_start"; suggest_end="$fallback_end"; start=""
      done
      if [ -z "${start:-}" ]; then
        start="$fallback_start"; end="$fallback_end"
        warn "using ${start} – ${end} on ${iface}."
      fi
    fi

    gw_set_env "DHCP_RANGE_START" "$start"
    gw_set_env "DHCP_RANGE_END" "$end"
    gw_set_env "DHCP_SUBNET_MASK" "$mask"
    range_start="$start"; range_end="$end"
    GW_RANGE_LINE="${start} – ${end} (mask ${mask})"
  }

  gw_ask_resolver() {  # which resolver the portal's own DNS asks upstream
    local current suggested answer
    current="$(grep -E '^DNS_UPSTREAM=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    suggested="${PREV_DNS_UPSTREAM:-${current:-$(gw_host_resolver)}}"
    [ -n "$suggested" ] || suggested="1.1.1.1"

    if [ -n "${GW_DNS:-}" ]; then
      answer="$GW_DNS"
    elif [ "${ASSUME_YES:-0}" -eq 1 ] || ! interactive; then
      answer="$suggested"
    else
      # Asked here rather than set in the console for the same reason as the
      # rest: which resolver is reachable from THIS segment is a fact about this
      # site. The default is what this host itself uses, which is the best guess
      # anyone can make from here.
      printf '\n  Which resolver should the portal ask for names it does not answer itself?\n' >&2
      printf '  [%s] > ' "$suggested" >&2
      IFS= read -r answer || true
      answer="${answer:-$suggested}"
    fi
    gw_set_env "DNS_UPSTREAM" "$answer"
    GW_DNS_LINE="$answer"
  }

  # The guests' NIC has to have an address, because that address IS their
  # default route and the one dnsmasq binds to. Without it the containers come
  # up, the console shows a healthy instance, and not one guest gets on.
  # NOT `local range_end`: it is read from the bundle and from the previous
  # install above, and re-declaring it here blanked both — so a reinstall
  # forgot the range it had just offered to keep.
  local client_cidr client_addr client_prefix
  client_cidr="$(gw_cidr_of "$want_client")"
  if [ -z "$client_cidr" ]; then
    echo "portal-join: ${want_client} has no IPv4 address, and the guests' interface needs one:" >&2
    echo "portal-join: it is what they are handed as their default route, and what the portal" >&2
    echo "portal-join: binds DHCP, DNS and the sign-in page to." >&2
    gw_interfaces_table >&2
    fail "give ${want_client} an address in the segment first (netplan, or: ip addr add <addr>/<prefix> dev ${want_client})."
  fi
  client_addr="${client_cidr%%/*}"
  client_prefix="${client_cidr##*/}"

  # …and the range the CORE configured has to be in THAT network. This is the
  # typo with no symptom on this host: the install succeeds, dnsmasq answers,
  # and every guest gets an address it cannot use, with a box it cannot
  # reach. Named on both sides so the operator can see which of the two is wrong.
  gw_ask_range "$want_client"
  gw_ask_resolver
  if [ -n "$range_end" ] && ! gw_same_net "$client_addr" "$range_end" "$client_prefix"; then
    warn "the range ends at ${range_end}, outside ${client_cidr} — dnsmasq will refuse that."
  fi
  # A mask that disagrees with the interface is not fatal for every client, so
  # it is said rather than refused — but it IS wrong, and the symptom (some
  # devices reach the box, some do not) is one nobody enjoys chasing.
  if [ -n "$mask" ]; then
    local mask_prefix
    mask_prefix="$(gw_mask_prefix "$mask")" || mask_prefix=""
    if [ -z "$mask_prefix" ]; then
      warn "the subnet mask in the bundle (${mask}) is not a valid mask — dnsmasq will refuse it."
    elif [ "$mask_prefix" != "$client_prefix" ]; then
      warn "the bundle hands out /${mask_prefix} while ${want_client} is /${client_prefix} — guests will disagree with their box about who is local."
    fi
  fi

  local nat="" isolation="" nat_default isolation_default
  # Masquerading and isolation are things a ROUTER does; a portal that does not
  # route has neither to answer for. Defaults lean on what this host answered
  # last time, and "on" for a box being installed for the first time — the safe
  # half of both choices.
  if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
    nat_default="$([ "$(gw_normalize_switch "${PREV_NAT:-on}")" = "off" ] && echo n || echo Y)"
    isolation_default="$([ "$(gw_normalize_switch "${PREV_ISOLATION:-on}")" = "off" ] && echo n || echo Y)"
    nat="$(gw_normalize_switch "${GW_NAT:-}")"
    [ -z "$nat" ] && nat="$(gw_yesno "Masquerade guest traffic behind ${want_uplink}'s address? (off only for a routed segment with real addresses)" "$nat_default")"
    isolation="$(gw_normalize_switch "${GW_ISOLATION:-}")"
    [ -z "$isolation" ] && isolation="$(gw_yesno "Stop guests on this segment from reaching each other?" "$isolation_default")"
  fi

  # Persisted into .env, exactly as PORTAL_IMAGE is: the next `up -d` — a
  # reboot, a restart — must resolve to the same wiring, and an operator
  # reading the file must find the answers they gave.
  gw_set_env "DHCP_INTERFACE" "$want_client"
  if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
    gw_set_env "PORTAL_UPLINK_INTERFACE" "$want_uplink"
    gw_set_env "PORTAL_NAT" "$([ "$nat" = on ] && echo true || echo false)"
    gw_set_env "PORTAL_CLIENT_ISOLATION" "$([ "$isolation" = on ] && echo true || echo false)"
    # Carried over rather than re-asked: nobody is asked for it in the first
    # place. It is written by hand for a site whose management cable is also the
    # guests' cable, and a re-install that dropped it would lock that operator
    # out of the box they are standing at the console of.
    [ -n "${PREV_HOST_OPEN:-}" ] && gw_set_env "PORTAL_HOST_OPEN_TCP" "${PREV_HOST_OPEN}"
  fi

  CLIENT_IFACE="$want_client"
  cat >&2 <<EOF

  ── What this host will do ─────────────────────────────────────────────────
    guests on:   ${want_client}
    addresses:   ${GW_RANGE_LINE:-${range_start:-?} – ${range_end:-?}}
    resolver:    ${GW_DNS_LINE:-upstream unset}
$(if [ "${ENFORCES_HERE:-0}" -eq 1 ]; then
    printf '    way out:     %s\n' "${want_uplink}"
    printf '    NAT:         %s\n' "${nat}"
    printf '    isolation:   %s\n' "${isolation}"
    printf '  and, once, to the host itself: enable IPv4 forwarding and load the scheduler\n'
    printf '  and ipset modules (both persisted across reboots).\n'
  fi)
EOF
  if interactive && [ "${ASSUME_YES:-0}" -eq 0 ]; then
    local go=""
    printf '\n  Continue? [Y/n] ' >&2
    IFS= read -r go || true
    # NOT "nothing has been changed": by this point the bundle is unpacked into
    # ${DIR}, the .env is written and the trust anchor is installed. Only the
    # container has not been started and the host has not been prepared — which
    # is what this now says, because an operator who reads the other sentence
    # and walks away leaves a half-installed directory they were told was clean.
    case "${go:-}" in [Nn]*)
      fail "stopped at your request. The bundle is in ${DIR} and nothing was started; re-run this command to finish, or --uninstall to remove it." ;;
    esac
  fi
}

gw_set_env() {  # key value — set or append, never duplicate
  local key="$1" value="$2" env_file="${DIR}/.env"
  if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

# ── Datapath host preparation ──────────────────────────────────────────────────
# A enforcing portal does something no other deployment of this product does: it
# routes. Three things it needs belong to the HOST and cannot be arranged from
# inside a container, so they are arranged here, once, and said out loud.
#
#   1. IPv4 forwarding. Without it nothing is routed for anyone, and no rule the
#      agent writes is at fault. /proc/sys is read-only in a container, so this
#      is not something the agent could fix even though it can see it.
#   2. The scheduler and set modules. A container with NET_ADMIN may USE them and
#      may not LOAD them (that needs CAP_SYS_MODULE in the initial namespace), so
#      a host that has never shaped traffic would report "no such file or
#      directory" from tc and lose per-client speed limits for no visible reason.
#   3. Somebody else's firewall. A default-deny INPUT policy blocks DHCP, DNS and
#      the portal page itself — traffic addressed TO this host, which none of the
#      box's forward rules can express and which therefore produces a
#      box that looks perfectly healthy and serves nobody. We do not touch
#      it: it is the operator's, and opening holes in it silently would be worse
#      than saying so.
#
# Both changes are persisted, because a box that works until the next reboot
# is a fault report waiting to happen.
#: The kernel pieces a box's datapath needs. A container with NET_ADMIN can
#: USE them and cannot LOAD them, so a host that has never shaped traffic gives
#: `tc` "No such file or directory" and the speed limits vanish with no cause on
#: screen.
DATAPATH_MODULES="sch_htb sch_fq_codel cls_flower cls_matchall act_mirred ifb ip_set ip_set_hash_ipmac ip_set_hash_net xt_set"

# Is this host able to route for the guests — and if not, is that something this
# script can fix, or something the operator has to?
#
# Asked BEFORE the wizard, not after it. The requirement was discovered at the
# end: five questions answered, the summary confirmed, and only then "a box
# needs root". Nothing was installed, but the operator had spent the whole
# conversation to be told the shape of the thing they were doing.
#
# Root is not the only way through. A host where forwarding is already on and
# the modules are already loaded needs nothing from us — an operator who
# prepared their own machine should not be sent to fetch sudo for a change that
# has already been made.
host_prep_missing() {  # echoes what is missing, empty when the host is ready
    local missing="" m
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ] || missing="forwarding"
    for m in $DATAPATH_MODULES; do
      [ -d "/sys/module/${m}" ] || missing="${missing}${missing:+ }${m}"
    done
    printf '%s' "$missing"
}

host_prep() {
  local iface="$1"
  local sysctl_file=/etc/sysctl.d/99-taranac-portal.conf
  local modules_file=/etc/modules-load.d/taranac-portal.conf
  # ifb is what makes an UPLOAD limit a queue instead of a drop: ingress is
  # redirected onto it and shaped there. act_mirred does the redirecting.
  # One list, shared with the readiness check above — two copies of "what the
  # datapath needs" is two places for a module to be forgotten.
  local modules="$DATAPATH_MODULES"

  info "this is a portal that enforces — preparing the host to route"

  # A safety net rather than the first news: the readiness check above refuses
  # long before this, so reaching here without root means the host was ready and
  # only the PERSISTING is out of reach.
  #
  # "Out of reach" is not the same as "not there". A host that carried a portal
  # before still has both files, and on that host the warning below would be a
  # flat untruth in the one line an operator is most likely to act on — so the
  # claim is made about what is on disk, not about who is running the script.
  if [ "$(id -u)" -ne 0 ]; then
    local have_fwd=0 have_mods=0
    grep -qs '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' "$sysctl_file" && have_fwd=1
    [ -f "$modules_file" ] && have_mods=1
    if [ "$have_fwd" -eq 1 ] && [ "$have_mods" -eq 1 ]; then
      info "  not root, and nothing needs writing: ${sysctl_file} and ${modules_file}"
      info "  are already in place, so this host keeps routing after a reboot"
      return 0
    fi
    warn "not root: forwarding and the modules are on NOW, but this run could not write"
    [ "$have_fwd" -eq 0 ] && warn "  ${sysctl_file} (forwarding will be off after a reboot)"
    [ "$have_mods" -eq 0 ] && warn "  ${modules_file} (the shaper's modules may be absent after a reboot)"
    warn "Re-run with sudo to fix that, or write them yourself — the portal works meanwhile."
    return 0
  fi

  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != "1" ]; then
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
      info "  enabled IPv4 forwarding"
    else
      echo "portal-join: WARNING — could not enable net.ipv4.ip_forward (need root?)." >&2
      echo "portal-join:           Nothing will be routed until it is: sysctl -w net.ipv4.ip_forward=1" >&2
    fi
  else
    info "  IPv4 forwarding already on"
  fi
  if [ -d /etc/sysctl.d ] && ! grep -qs 'net.ipv4.ip_forward' "$sysctl_file" 2>/dev/null; then
    printf '# Taranac captive portal box — this host routes its client segment.\nnet.ipv4.ip_forward=1\n' \
      > "$sysctl_file" 2>/dev/null \
      && info "  persisted forwarding in ${sysctl_file}" \
      || echo "portal-join: WARNING — could not write ${sysctl_file}; forwarding will not survive a reboot." >&2
  fi

  local loaded=0 missing=""
  for mod in $modules; do
    if modprobe "$mod" >/dev/null 2>&1; then
      loaded=$((loaded + 1))
    else
      missing="${missing} ${mod}"
    fi
  done
  [ "$loaded" -gt 0 ] && info "  loaded ${loaded} kernel module(s) for shaping and sets"
  if [ -n "$missing" ]; then
    echo "portal-join: WARNING — these kernel modules would not load:${missing}" >&2
    echo "portal-join:           Access control still works; per-client speed limits may not." >&2
  fi
  if [ -d /etc/modules-load.d ] && [ ! -f "$modules_file" ]; then
    { echo "# Taranac captive portal box — shaping and ipset support."
      for mod in $modules; do echo "$mod"; done
    } > "$modules_file" 2>/dev/null \
      && info "  persisted the module list in ${modules_file}" \
      || echo "portal-join: WARNING — could not write ${modules_file}; modules may be absent after a reboot." >&2
  fi

  if [ -n "$iface" ]; then
    if ip link show "$iface" >/dev/null 2>&1; then
      local ifip
      ifip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/ inet /{split($2,a,"/"); print a[1]; exit}')"
      if [ -n "$ifip" ]; then
        info "  client interface ${iface} is up at ${ifip} — its clients will use that as their router"
      else
        echo "portal-join: WARNING — ${iface} has no IPv4 address. Clients get a box address" >&2
        echo "portal-join:           from DHCP that has to be this interface's own; give it one." >&2
      fi
    else
      echo "portal-join: WARNING — there is no interface called '${iface}' on this host." >&2
      echo "portal-join:           Fix it on the Deployment tab (DHCP interface) and re-run." >&2
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    echo "portal-join: NOTE — ufw is active on this host. A box must accept DHCP (67/udp)," >&2
    echo "portal-join:        DNS (53) and the portal page (80/443) ON ${iface:-the client interface}," >&2
    echo "portal-join:        and must be allowed to route. Nothing here changes your firewall." >&2
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "portal-join: NOTE — firewalld is running. See the ufw note above; the same applies." >&2
  fi
}

ENFORCES_HERE=0
enforces_here && ENFORCES_HERE=1

# Said here — the bundle has just told us this portal routes, and nothing has
# been asked yet.
if [ "$ENFORCES_HERE" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  MISSING="$(host_prep_missing)"
  if [ -n "$MISSING" ]; then
    echo "portal-join: this portal is a DATAPATH, and this host is not ready to route yet:" >&2
    case "$MISSING" in
      forwarding*) echo "portal-join:   net.ipv4.ip_forward is off" >&2 ;;
    esac
    MODS="${MISSING#forwarding}"; MODS="${MODS# }"
    [ -n "$MODS" ] && echo "portal-join:   kernel modules not loaded: ${MODS}" >&2
    echo "portal-join:" >&2
    echo "portal-join: Neither can be done from inside the container: /proc/sys is read-only" >&2
    echo "portal-join: there, and loading a module needs privileges a container does not get." >&2
    echo "portal-join:" >&2
    echo "portal-join: Either re-run this installer with sudo — it turns both on and makes" >&2
    echo "portal-join: them survive a reboot — or do it yourself and run this again:" >&2
    [ "${MISSING#forwarding}" != "$MISSING" ] && echo "portal-join:   sudo sysctl -w net.ipv4.ip_forward=1" >&2
    [ -n "$MODS" ] && echo "portal-join:   sudo modprobe ${MODS}" >&2
    echo "portal-join:" >&2
    fail "nothing was asked and nothing was started: sudo ${RERUN_CMD}"
  fi
  info "this host already forwards and has the shaper's modules — no root needed."
fi
# Every portal answers the segment questions now. A standalone portal serves
# DHCP and DNS in its registration VLAN exactly as a box does — the console
# used to hold those answers, and it was holding them about a machine it had
# never seen. A box answers three more, because it also routes.
step "Asking about this host, because that is not the core's to know"
host_wizard
if [ "$ENFORCES_HERE" -eq 1 ]; then
  host_prep "$CLIENT_IFACE"
fi

# ── Bring the portal up ───────────────────────────────────────────────────────
step "Starting the portal, and proving it reaches the core"
info "starting the portal…"
COMPOSE="docker compose --project-directory ${DIR} -f ${DIR}/docker-compose.yml"
# UTC with an explicit Z — a zoneless stamp is read as the daemon's LOCAL time by
# `docker compose logs --since`, which on a box that is not on UTC would show a
# previous attempt's error as this one's.
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The previous datapath comes off HERE, and not a step earlier.
#
# It used to be removed before the bundle was even unpacked, which meant a
# failed untar or a refused image left a LIVE site with no datapath at all — the
# one outcome worse than a stale one. By this point everything has succeeded and
# the container is seconds from restarting.
#
# The chains rebuild themselves on the next report, so those need no help. Two
# things do not: the shaper's root qdisc and bridge-port isolation. Both are
# attached to the interface answered LAST time, and a re-install is precisely
# when that answer changes — leaving a shaper on a NIC nothing uses and ports
# isolated for a segment that has moved. Neither has a symptom on this box,
# which is what makes it worth doing rather than documenting.
#
# Best-effort and quiet: a host whose agent never came up has nothing to remove.
if [ "$REINSTALL" -eq 1 ] && enforces_here; then
  info "taking the previous datapath off this host before replacing it…"
  docker compose --project-directory "${DIR}" -f "${DIR}/docker-compose.yml" \
      exec -T portal python3 -m datapath.agent --teardown >/dev/null 2>&1 \
    || warn "could not remove the previous datapath; check 'iptables -S | grep TGW_' and 'tc qdisc show' afterwards."
fi

# What `up -d` did, not what we assume it did — the answer decides whether the
# restart below is needed at all. A container id that changed, or a start time
# that moved, means it read the refetched config on the way up. Defined before
# `up -d` and reassigned after, so neither is ever unset under `set -u`.
PORTAL_ID_BEFORE="$(${COMPOSE} ps -q portal 2>/dev/null || true)"
PORTAL_WAS="${PORTAL_ID_BEFORE}-$(docker inspect -f '{{.State.StartedAt}}' "${PORTAL_ID_BEFORE:-nonexistent}" 2>/dev/null || true)"
${COMPOSE} up -d
PORTAL_ID_AFTER="$(${COMPOSE} ps -q portal 2>/dev/null || true)"
PORTAL_NOW="${PORTAL_ID_AFTER}-$(docker inspect -f '{{.State.StartedAt}}' "${PORTAL_ID_AFTER:-nonexistent}" 2>/dev/null || true)"
# On a re-install `up -d` sees an unchanged container definition and leaves the
# running one alone — so the freshly fetched portal.conf, the new trust anchor and
# the new .env would all sit on disk unread. Restart so what was fetched is what
# is actually serving; otherwise the operator "reinstalled" and nothing changed.
# portal.conf is a bind-mount, so nothing about the container changes when its
# contents do and `up -d` leaves a running container exactly as it was — hence
# the restart. But when `up -d` has just started or recreated it, the file was
# read on the way up and restarting again only tears the datapath down and
# rebuilds it, dropping every guest twice for no reason.
if [ "$REINSTALL" -eq 1 ] && [ "$PORTAL_NOW" = "$PORTAL_WAS" ]; then
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

  ${HERE}/taranac captive-portal logs -f portal
EOF
  exit 1
fi

cat <<EOF

portal-join: the portal is up and reaching the core.
  Core:        ${CORE_ROOT}
  Trust:       ${TRUST_LINE}
  Installed:   ${DIR}
  Token:       written to ${DIR}/.env (0600) — this portal's standing credential

Verify — from anywhere, through the wrapper beside this installer, which knows
where the portal lives so nobody has to stand in its directory:
  ${HERE}/taranac captive-portal status          # trust, token, heartbeat, datapath
  ${HERE}/taranac captive-portal logs -f portal  # watch it pin, load portal.conf, beat
  ${HERE}/taranac captive-portal ps              # health = 'healthy' once nginx answers
  curl -k https://localhost/portal/

Its own TLS certificate:
  ${DIR}/certs/portal.crt + ${DIR}/certs/portal.key — replace both with yours, then
  ${HERE}/taranac captive-portal restart portal
  A certificate already there is kept; only a missing one is generated. It has to be
  PUBLICLY trusted to stop a guest's phone warning — one from your own CA warns
  exactly like the self-signed pair it would replace. The name on it must be the name
  guests are sent to. Keep your copy elsewhere too: --uninstall deletes this directory.

Core UI: NAC -> Captive Portals -> Instances — this one appears on its first heartbeat.
EOF

if [ "$ENFORCES_HERE" -eq 1 ]; then
  cat <<EOF
This portal OPENS ACCESS ITSELF: it routes its own segment and enforces access itself.
  Client side:   ${CLIENT_IFACE:-<unset>} (DHCP, DNS and the portal page live there)
  Enforced by:   this same container. The agent inside it pulls the allowed-client
                 list from the core every few seconds — nothing is pushed to this
                 host, and there is no second image to install or keep alive

Watch it program the datapath:
  ${HERE}/taranac captive-portal logs -f portal
See what it has applied right now — the rules, the allowed clients and the speed
limits, read from inside the container because that is where those tools live:
  ${HERE}/taranac captive-portal datapath

Core UI: NAC -> Captive Portals -> <this portal> -> Deployment shows the same
state, and NAC -> Sessions lists these clients marked 'Portal'.
EOF
fi

cat <<EOF

If the log says the core's certificate CHANGED, and you know it was replaced:
  ${HERE}/portal-join.sh --reset-trust --dir ${DIR}
EOF
