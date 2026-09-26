#!/usr/bin/env bash
# collector-join.sh — stand up a Taranac standalone collector on THIS remote site.
#
# A collector dials home to the core over a request-signed channel
# (docs/spec/backend/ncm/standalone-collector.md): it claims dispatched jobs,
# runs them against the site's devices, and posts results back through a durable
# outbox. It holds NO database and serves no API. This script is the thin
# operator wrapper around bringing that container up:
#
#   1. Validate inputs (core URL, enrollment token).
#   2. Write ./collector.env (core URL + poll cadence) next to the compose file
#      and the one-shot ./enrollment-token.
#   3. `docker compose up -d` the collector.
#
# The image is the published one for this version. To run a locally built image
# (development, or an air-gapped host that loaded one), name it:
#   COLLECTOR_IMAGE=taranac-collector:local ./collector-join.sh --core … --enrollment-token …
#
# TWO THINGS TO SUPPLY, AND THE CORE HANDS YOU BOTH. The enrollment dialog
# (Settings -> System -> Collectors -> Issue enrollment token) prints this command with the core's real URL
# already filled in — copy it there, paste it here:
#
#   ./collector-join.sh \
#       --core https://core.example/api/v1 \
#       --enrollment-token <secret>
#
# Edit the URL if this site reaches the core by a different name (NAT, a public
# FQDN, another port) — the core fills in the address YOU are using it from,
# which is not always the address a remote site must dial.
#
# The enrollment token is ONE-TIME: the daemon redeems it on first boot, pins the
# returned identity fingerprint on the core (TOFU), then blanks the token file.
# Re-running with a FRESH token re-enrolls an already-attached collector (which
# is how you re-attach one that was deleted on the core); the collector rotates
# its keypair and enrolls again.
#
# TRUST — no file needed by default. The collector pins the core's certificate on
# first contact and accepts only that one afterwards. Two alternatives:
#   --ca-file <path>   verify against a CA bundle instead (strictest; behind an
#                      nginx edge this is the EDGE CA, not the internal one)
#   --trust-any        verify nothing (a lab setting — this channel carries
#                      device credentials, so do not ship it)
#
# If the core's certificate is legitimately replaced later, the collector stops
# and says so. Re-pin without a new token and without losing its identity:
#   ./collector-join.sh --reset-trust
#   ./collector-join.sh --status                 # what it is doing, locally
#   ./collector-join.sh --update [--check]       # move to the version the core runs
#   ./collector-join.sh --update --version <ver> # …to a version you name (skip the ask)
#   ./collector-join.sh --update --from <tar>    # …from an image tarball (air-gapped)
#   ./collector-join.sh --uninstall [--force]    # remove it from THIS host
#
# Usage (from the repo root, on the collector host):
#   ./collector-join.sh --core <url> --enrollment-token <secret>
#       [--ca-file <path>] [--trust-any] [--collector-id <label>]
#       [--poll-interval 30] [--with-nmap]
#   ./collector-join.sh --reset-trust
#   ./collector-join.sh --status                 # what it is doing, locally
#   ./collector-join.sh --update [--check]       # move to the version the core runs
#   ./collector-join.sh --update --version <ver> # …to a version you name (skip the ask)
#   ./collector-join.sh --update --from <tar>    # …from an image tarball (air-gapped)
#   ./collector-join.sh --uninstall [--force]    # remove it from THIS host
set -euo pipefail

# Anchored on THIS script's own directory, which is where its compose file lives —
# the unpacked bundle for an operator, deploy/dist/ in a checkout. Anchoring on a
# repo root is what made the bundle and the appliance behave differently.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

COMPOSE_FILE="docker-compose.collector.yml"
ENV_FILE="collector.env"
DOTENV_FILE=".env.collector"
CA_DEST="ca.crt"
TOKEN_DEST="enrollment-token"
PIN_PATH="/var/lib/taranac-collector/identity/core.pem"

CORE=""; TOKEN=""; CA_FILE=""; COLLECTOR_ID=""; POLL_INTERVAL=""
WITH_NMAP=0
TRUST_ANY=0; RESET_TRUST=0; UNINSTALL=0; FORCE=0; STATUS=0; UPDATE=0; CHECK=0; FROM_TAR=""; WANT_VER=""

usage() { sed -n '2,48p' "$0"; }
fail()  { echo "collector-join: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --core)             CORE="$2"; shift 2 ;;
    --enrollment-token) TOKEN="$2"; shift 2 ;;
    --ca-file)          CA_FILE="$2"; shift 2 ;;   # optional: strict CA verification
    --trust-any)        TRUST_ANY=1; shift ;;      # optional: verify nothing (lab)
    --reset-trust)      RESET_TRUST=1; shift ;;    # re-pin after the core's cert changed
    --uninstall)        UNINSTALL=1; shift ;;      # remove this collector from THIS host
    --status)           STATUS=1; shift ;;         # what this collector is doing, locally
    --update)           UPDATE=1; shift ;;         # move to the version the core runs
    --check)            CHECK=1; shift ;;          # with --update: report only, change nothing
    --from)             FROM_TAR="$2"; shift 2 ;;  # with --update: docker load this image tar first
    --version)          WANT_VER="$2"; shift 2 ;;  # with --update: move to THIS version, don't ask
    --force)            FORCE=1; shift ;;          # with --uninstall: discard a non-empty outbox
    --collector-id)     COLLECTOR_ID="$2"; shift 2 ;;   # optional display label
    --poll-interval)    POLL_INTERVAL="$2"; shift 2 ;;   # seconds between job polls
    --scan-interfaces)
      # Gone: the collector reports every interface and the operator chooses what to scan
      # in the core. Refused rather than ignored, so a pasted old command says so.
      fail "--scan-interfaces is no longer used. Install without it: the collector reports every interface of this host, and you choose where to listen and scan in the core (NAC -> Discovery Sources -> Scanner)." ;;
    --with-nmap)        WITH_NMAP=1; shift ;;          # build a derived image that adds nmap (never asks)
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# Compose interpolates ${COLLECTOR_CA_FILE} from an env file. Point it at OUR OWN
# file rather than letting it default to the repo-root `.env`: that file belongs to
# the monorepo (Compose auto-reads it and it overrides --env-file, which is exactly
# why the project never uses it), and writing — let alone deleting — it from a
# collector install would clobber something that has nothing to do with us.
COMPOSE="docker compose --env-file ${DOTENV_FILE} -f ${COMPOSE_FILE}"

[ -f "$COMPOSE_FILE" ] || fail "no ${COMPOSE_FILE} in $(pwd) — the compose file must sit beside this script ( ${ENV_FILE})."
[ -f "$DOTENV_FILE" ] || printf '# Compose interpolation for the Taranac collector — written by collector-join.sh\n' > "$DOTENV_FILE"

# Peek inside the collector's state volume.
#
# NOT `docker compose run`: the service declares a fixed container_name, and a `run`
# against it conflicts with the container already using that name — compose stops the
# running daemon to make room. A read-only status command that kills the thing it is
# reporting on is worse than no status command at all. So exec into the live container
# when there is one, and only fall back to a throwaway container when there is not.
peek() {  # <shell snippet>
  if [ "$(docker inspect -f '{{.State.Running}}' taranac-collector 2>/dev/null)" = "true" ]; then
    docker exec taranac-collector sh -c "$1" 2>/dev/null
  else
    ${COMPOSE} run --rm --no-deps --entrypoint sh collector -c "$1" 2>/dev/null
  fi
}

# ── --update [--check]: move to the version THIS CORE runs ───────────────────
# The oracle is the core, never a public release feed, and that is the whole point:
#  * a collector must match ITS core — the capability contract fail-closes on skew,
#    so "update to the newest release" is precisely wrong when the core is behind;
#  * a remote site can always reach its core (that is its entire job) while it
#    frequently cannot reach the internet at all.
# The core's version arrives on every authenticated answer and the daemon records it
# beside its identity, so this reads it locally — no network call, like --status.
#
# That record is REMEMBERED, not measured, and one case makes the difference visible: a
# core older than 1.2.7 dropped the version header from the 409 it fail-closes a skewed
# collector with (the exception handler built a fresh response and the header set by the
# auth dependency went with the old one). So exactly when the collector stops collecting
# and needs to move, the record stops being refreshed — it holds the pre-upgrade value
# and this command answers "already in step with the core". Hence two things below: the
# reply is refused when the collector is visibly being refused by the core, and
# `--version <ver>` names the target by hand, no oracle involved.
if [ "$UPDATE" -eq 1 ]; then
  [ -f "$COMPOSE_FILE" ] || fail "no collector is installed here (${COMPOSE_FILE} not found)."

  HAVE_VER="$(grep -E '^TARANAC_VERSION=' "$DOTENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)"

  # Is the core fail-closing this collector RIGHT NOW on a contract mismatch? Same scan
  # --status uses (errors only from after the last successful start), because the answer
  # decides whether the recorded core version can be believed at all — see below.
  # (An `if`, not `cmd && VAR=1`: under `set -e` a false &&-list would abort the script.)
  MISMATCH=0
  if ${COMPOSE} logs --no-color --tail 500 collector 2>/dev/null \
       | awk '/collector started \(/ { err=""; next } /version mismatch \(409\)/ { err=$0 } END { exit (err == "") }'
  then
    MISMATCH=1
  fi

  if [ -n "$WANT_VER" ]; then
    CORE_VER="$WANT_VER"
    echo "collector-join: moving to ${CORE_VER} because you asked for it — the core was not consulted."
  else
    CORE_VER="$(peek 'cat /var/lib/taranac-collector/identity/core-version' | tr -d '[:space:]' || true)"
    [ -n "$CORE_VER" ] || fail "this collector has not heard from the core yet, so there is nothing to
  compare against. Let it attach first ($0 --status), then retry.
  If it cannot attach, name the version yourself:  $0 --update --version <ver>"
    echo "collector-join: this collector runs ${HAVE_VER:-<unset>}; the core runs ${CORE_VER}."
  fi

  if [ "$HAVE_VER" = "$CORE_VER" ]; then
    # "Nothing to do" is only true if the collector is actually working. If the core is
    # fail-closing it on a contract mismatch, these two versions CANNOT both be current —
    # and the one we print is not measured, it is REMEMBERED: the daemon records the
    # version the core reports on its answers, and a core older than 1.2.7 dropped that
    # header from the very answer that fails (the exception handler built a fresh
    # response). So after the core is upgraded the record freezes at the pre-upgrade
    # value, and this command used to reply "already in step with the core" to a
    # collector that had been collecting nothing for hours. The one door out was locked
    # by the failure it exists for. Observed on a customer's collector, 1.2.6.
    if [ "$MISMATCH" -eq 1 ] && [ -z "$WANT_VER" ]; then
      fail "this collector is being REFUSED by the core on a contract mismatch (409), so it
  cannot also be in step with it — the version above is the last one the core TOLD us,
  which a core older than 1.2.7 stops repeating exactly when it starts refusing.
  Read the core's real version on the core itself ('./taranac version', or the web UI),
  then move this collector to it explicitly:
      $0 --update --version <ver>
  (Everything else about the update is unchanged: it still pulls, swaps, waits for the
  collector to attach, and rolls back if it does not.)"
    fi
    echo "collector-join: already in step with the core — nothing to do."
    exit 0
  fi
  if [ "$CHECK" -eq 1 ]; then
    echo "collector-join: an update is available. Apply it with:  $0 --update${WANT_VER:+ --version ${WANT_VER}}"
    exit 0
  fi

  NEW_IMAGE="${COLLECTOR_IMAGE:-ghcr.io/taranaclabs/taranac/collector:${CORE_VER}}"
  if [ -n "$FROM_TAR" ]; then
    [ -r "$FROM_TAR" ] || fail "--from '${FROM_TAR}' is not readable."
    echo "collector-join: loading ${FROM_TAR}…"
    docker load -i "$FROM_TAR" || fail "could not load ${FROM_TAR}."
  fi
  if ! docker image inspect "$NEW_IMAGE" >/dev/null 2>&1; then
    [ -n "$FROM_TAR" ] && fail "${FROM_TAR} did not contain ${NEW_IMAGE}."
    echo "collector-join: ${NEW_IMAGE} is not on this host — fetching…"
    docker pull "$NEW_IMAGE" || fail "could not obtain ${NEW_IMAGE}. On a host with no registry
  access, bring the image over and name it:  $0 --update --from <image.tar>"
  fi

  # Remember what we are leaving BEFORE the swap. A remote collector that fails to
  # come back is unreachable — it listens on nothing and nobody is standing next to
  # it — so the way back has to be arranged in advance, not looked for afterwards.
  PREV_VER="$HAVE_VER"
  SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "collector-join: switching to ${NEW_IMAGE}…"
  if grep -qE '^TARANAC_VERSION=' "$DOTENV_FILE" 2>/dev/null; then
    sed -i -E "s|^TARANAC_VERSION=.*|TARANAC_VERSION=${CORE_VER}|" "$DOTENV_FILE"
  else
    printf 'TARANAC_VERSION=%s\n' "$CORE_VER" >> "$DOTENV_FILE"
  fi
  ${COMPOSE} up -d || fail "could not start the new image."

  echo "collector-join: waiting for it to attach again…"
  ATTACHED=0; WAITED=0; LOG=""
  while [ "$WAITED" -lt 60 ]; do
    LOG="$(${COMPOSE} logs --since "$SINCE" --no-color collector 2>&1 || true)"
    case "$LOG" in *"collector started ("*|*"collector enrolled;"*) ATTACHED=1; break ;; esac
    sleep 3; WAITED=$((WAITED + 3))
  done

  if [ "$ATTACHED" -eq 1 ]; then
    echo "collector-join: updated to ${CORE_VER} and attached."
    exit 0
  fi

  echo "collector-join: it did NOT come back — rolling back to ${PREV_VER:-the previous version}." >&2
  printf '%s\n' "$LOG" | tail -12 | sed 's/^/  /' >&2
  if [ -n "$PREV_VER" ]; then
    sed -i -E "s|^TARANAC_VERSION=.*|TARANAC_VERSION=${PREV_VER}|" "$DOTENV_FILE"
    ${COMPOSE} up -d >/dev/null 2>&1 || true
  fi
  fail "the update was rolled back; the collector is running its previous version again."
fi

# ── --status: what this collector is doing, answered from LOCAL state only ───
# Deliberately makes no network call. This is the command an operator runs when
# the core is unreachable — having it hang on the very connection under suspicion
# would be the opposite of useful. Everything below is on this host already.
if [ "$STATUS" -eq 1 ]; then
  [ -f "$COMPOSE_FILE" ] || fail "no collector is installed here (${COMPOSE_FILE} not found)."
  echo "Core:      $(grep -E '^COLLECTOR_CORE_BASE_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo '(unknown)')"
  echo "Trust:     $(grep -E '^COLLECTOR_(TLS_TRUST|CA_CERT_PATH)=' "$ENV_FILE" 2>/dev/null | tr '\n' ' ' || echo '(unknown)')"
  echo "Container: $(docker inspect taranac-collector --format '{{.State.Status}} (health: {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}})' 2>/dev/null || echo 'not created')"

  # Enrolment, the pin and the last poll all live in the state volume, which only a
  # container can read — so ask one, briefly, with no daemon running.
  peek '
      d=/var/lib/taranac-collector
      if [ -f "$d/identity/fingerprint" ]; then
        echo "Enrolled:  yes (key-id $(cut -c1-16 "$d/identity/fingerprint")…)"
      else
        echo "Enrolled:  NO — it has not attached to the core yet"
      fi
      if [ -f "$d/identity/core.pem" ]; then
        echo "Core cert: pinned $(openssl x509 -in "$d/identity/core.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ":" | tr "A-F" "a-f" | cut -c1-16)…"
      fi
      if [ -f "$d/alive" ]; then
        echo "Last poll: $(( $(date +%s) - $(date -r "$d/alive" +%s) ))s ago"
      else
        echo "Last poll: never"
      fi
      [ -f "$d/outbox.sqlite3" ] && python -c "
import sqlite3,sys
try: print(\"Outbox:    %d result(s) waiting to upload\" % sqlite3.connect(sys.argv[1]).execute(\"select count(*) from outbox\").fetchone()[0])
except Exception: pass" "$d/outbox.sqlite3"
  ' || echo "(could not read the state volume)"

  # Only errors from AFTER the last successful start. A collector that failed twice
  # and then attached is HEALTHY, and showing its last historical failure as though
  # it were the current state is worse than showing nothing — that is exactly the
  # sort of "report something stale as if it were now" this whole tool exists to
  # stop doing.
  LAST_ERR="$(${COMPOSE} logs --no-color --tail 500 collector 2>/dev/null \
    | awk '/collector started \(/ { err=""; next } /ERROR/ { err=$0 } END { if (err != "") print err }' || true)"
  if [ -n "$LAST_ERR" ]; then
    echo "Last error (since it last started):"
    printf '  %s\n' "$LAST_ERR"
  else
    echo "Errors:    none since it last started"
  fi
  exit 0
fi

# ── --uninstall: remove this collector from THIS host ────────────────────────
# Local only, on purpose. It does NOT delete the collector on the core: a box
# being decommissioned frequently cannot reach the core any more, and an
# uninstall that fails exactly when the core is down is an uninstall that does
# not work. The two halves are independent and each reminds you of the other.
if [ "$UNINSTALL" -eq 1 ]; then
  [ -f "$COMPOSE_FILE" ] || fail "no collector is installed here (${COMPOSE_FILE} not found)."

  # The outbox holds results already COLLECTED but not yet accepted by the core.
  # Dropping the volume discards them, and nothing else has a copy — the devices
  # were read, the configurations are here and nowhere else. Refuse rather than
  # lose history silently; --force is the operator saying they accept the loss.
  PENDING="$(peek "python -c \"
import sqlite3
try: print(sqlite3.connect('/var/lib/taranac-collector/outbox.sqlite3').execute('select count(*) from outbox').fetchone()[0])
except Exception: print(0)\"" | tr -dc '0-9' || true)"
  if [ "${PENDING:-0}" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    fail "the outbox still holds ${PENDING} collected result(s) that the core has not accepted.
  They exist only here — removing this collector discards them. Let it drain (it retries
  on its own), or accept the loss explicitly:  $0 --uninstall --force"
  fi

  echo "collector-join: removing the collector, its state volume and its config…"
  ${COMPOSE} down -v || fail "could not bring the collector down."
  rm -f "$ENV_FILE" "$DOTENV_FILE" "$TOKEN_DEST" "$CA_DEST" 2>/dev/null \
    || sudo rm -f "$ENV_FILE" "$DOTENV_FILE" "$TOKEN_DEST" "$CA_DEST" 2>/dev/null || true
  cat <<EOF

collector-join: removed from this host — container, state volume (identity, pinned
certificate, outbox) and config files are gone.

The collector still EXISTS on the core: delete it there too, or it will sit in the
list for ever as offline —  Settings -> System -> Collectors -> <this one> -> Delete.
EOF
  exit 0
fi

# ── --reset-trust: forget the pinned core certificate, then restart ───────────
# Done by deleting the pin INSIDE the state volume rather than by setting a
# COLLECTOR_RESET_TRUST env var, because a variable left set would re-learn the
# pin on every restart — a pin that reconsiders itself protects nothing. This is
# a one-shot action with no residue. `run --rm` lets compose resolve the volume,
# so no volume name is hardcoded, and it works while the collector is crash-
# looping on the very mismatch we are clearing.
if [ "$RESET_TRUST" -eq 1 ]; then
  echo "collector-join: clearing the pinned core certificate…"
  ${COMPOSE} run --rm --no-deps --entrypoint rm collector -f "$PIN_PATH" \
    || fail "could not clear the pin (is the collector installed here?)"
  echo "collector-join: restarting the collector — it will pin whatever the core presents next."
  ${COMPOSE} up -d
  echo "collector-join: done. Watch it re-pin: ${COMPOSE} logs -f collector"
  exit 0
fi

# ── Guards ────────────────────────────────────────────────────────────────────
[ -n "$CORE" ]  || fail "missing --core <url> (the core collector gateway base, e.g. https://core.example/api/v1). The core's enrollment dialog prints this command with it filled in."
[ -n "$TOKEN" ] || fail "missing --enrollment-token <secret> (issue one on the core: Settings -> System -> Collectors -> Issue enrollment token; it is single-use)."
case "$CORE" in https://*) ;; *) fail "--core must be an https:// URL; got '${CORE}'." ;; esac

if [ -n "$POLL_INTERVAL" ]; then
  case "$POLL_INTERVAL" in
    ''|*[!0-9]*) fail "--poll-interval must be a whole number of seconds; got '${POLL_INTERVAL}'." ;;
  esac
  [ "$POLL_INTERVAL" -ge 5 ] || fail "--poll-interval must be at least 5 seconds; got '${POLL_INTERVAL}'."
fi

if [ -n "$CA_FILE" ] && [ "$TRUST_ANY" -eq 1 ]; then
  fail "--ca-file and --trust-any contradict each other — pick one (or neither, to pin on first contact)."
fi
if [ -n "$CA_FILE" ]; then
  [ -r "$CA_FILE" ] || fail "--ca-file '${CA_FILE}' is not readable."
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1 \
      || fail "--ca-file '${CA_FILE}' does not parse as a PEM certificate."
  fi
fi

# A common misconfiguration: the collector gateway mounts under /api/v1 and the
# request signature covers the FULL path — so --core MUST include the /api/v1
# prefix (unless an edge strips it). Warn if it looks absent.
case "$CORE" in *"/api/v1"*|*"/api/v1/") ;; *)
  echo "collector-join: NOTE — --core '${CORE}' has no /api/v1 segment. The core mounts the collector gateway under /api/v1; unless a proxy strips it, the base URL should end in /api/v1 (e.g. ${CORE%/}/api/v1). Proceeding as given." >&2 ;;
esac

# ── Pre-flight: nothing is written or pulled until the core, the token and the
# scan interfaces check out ───────────────────────────────────────────────────
# Without this the first contact with the core happened from inside a container,
# after the config was written and an image pulled: a wrong address or a dead token
# surfaced minutes later as an attach timeout. Asked here, the answer arrives while
# the operator is still looking at the command they typed.

# One field out of a small JSON answer. python3 when the host has it; the sed
# fallback is enough for the flat, quote-free values these answers carry.
_json_field() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$1" "$2"
  else
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1"
  fi
}

# POST a JSON body to a gateway path. Sets _code (HTTP status, empty on a transport
# failure), _rc (curl's exit code), _err (curl's own message) and fills _body.
# This check establishes no trust — pinning happens in the collector on first
# contact — so a certificate is verified only when --ca-file names one.
_post() {
  _tls="-k"; [ -n "$CA_FILE" ] && _tls="--cacert ${CA_FILE}"
  # shellcheck disable=SC2086  # _tls is one or two words on purpose
  # `&& || ` rather than a bare assignment: under `set -e` a failed curl would end the
  # script here, before it could say which of the failures below it was.
  _code="$(curl -sS --max-time 15 $_tls -o "$_body" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' --data "$2" "${CORE%/}$1" 2>"$_errf")" && _rc=0 || _rc=$?
  _err="$(head -c 300 "$_errf")"
  [ "$_rc" -eq 0 ] || _code=""
}

preflight_core_and_token() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "collector-join: NOTE — curl is not installed, so the core and the token are not checked before" \
         "installing; the collector will report either problem itself once it starts." >&2
    return 0
  fi
  _body="$(mktemp)"; _errf="$(mktemp)"
  trap 'rm -f "$_body" "$_errf"' EXIT

  echo "collector-join: checking the core at ${CORE%/} and the enrollment token…"
  _post /ncm/collector/enroll/check "{\"token\":\"${TOKEN}\"}"

  if [ "$_rc" -ne 0 ]; then
    case "$_rc" in
      6)  fail "cannot resolve the core's name in '${CORE}'. Check the address — it must be a name or IP this host can reach." ;;
      7)  case "$CORE" in
            *://localhost[:/]*|*://127.*|*://\[::1\]*)
                fail "nothing answers at '${CORE}'. 'localhost' here means this collector host, not the core — use the core's address as seen from this site." ;;
            *)  fail "nothing answers at '${CORE}' (connection refused or no route). Check the address and the port." ;;
          esac ;;
      28) fail "the core at '${CORE}' did not answer within 15 seconds. Check the address, the port and any firewall between this site and the core." ;;
      35|56|58|59|60|77|80|83|90|91)
          fail "the TLS handshake with '${CORE}' failed: ${_err}. Something answers there, but not as https — or, with --ca-file, not with a certificate that CA signed." ;;
      *)  fail "could not reach the core at '${CORE}': ${_err}" ;;
    esac
  fi

  case "$_code" in
    200)
      echo "collector-join: core reachable; token valid for collector '$(_json_field "$_body" collector_name)'" \
           "until $(_json_field "$_body" expires_at)."
      ;;
    404)
      # 404 is either "no such route" or "the token's collector was deleted". Only the
      # second is a Taranac answer with its own code and a sentence; a missing route
      # reads HTTP_ERROR, and a foreign server answers with no JSON at all.
      _detail="$(_json_field "$_body" detail)"; _ecode="$(_json_field "$_body" code)"
      if [ -n "$_detail" ] && [ -n "$_ecode" ] && [ "$_ecode" != "HTTP_ERROR" ]; then
        fail "the core refused the token: ${_detail}"
      fi
      # No such route: a core older than this check, or not a collector gateway at all.
      # /enroll answers 422 to an empty body on every version that can enroll anybody.
      _post /ncm/collector/enroll '{}'
      if [ "$_code" = "422" ]; then
        echo "collector-join: core reachable (it predates the token check — the collector will check the token itself)."
      else
        fail "'${CORE}' answers, but not as a Taranac collector gateway (HTTP 404). The address most likely lacks the /api/v1 suffix, or points at the wrong service."
      fi
      ;;
    422|400|409|410)
      fail "the core refused the token: $(_json_field "$_body" detail)"
      ;;
    *)
      _detail="$(_json_field "$_body" detail)"
      fail "the core at '${CORE}' answered HTTP ${_code}${_detail:+: ${_detail}}."
      ;;
  esac
}

preflight_core_and_token

# ── Materialise the collector's config next to the compose file ───────────────
echo "collector-join: writing ${ENV_FILE}, ${TOKEN_DEST}…"

# collector.env — the operator-editable config (compose env_file). Container
# paths for token / identity / outbox / liveness are pinned in the compose file;
# here we write the site-specific values, including the trust choice.
{
  echo "# Written by collector-join.sh — Taranac standalone collector config."
  echo "# Edit + \`docker compose -f ${COMPOSE_FILE} up -d\` to apply."
  echo "COLLECTOR_CORE_BASE_URL=${CORE%/}"
  if [ -n "$CA_FILE" ]; then
    echo "COLLECTOR_CA_CERT_PATH=/etc/taranac-collector/ca.crt"
  elif [ "$TRUST_ANY" -eq 1 ]; then
    echo "COLLECTOR_TLS_TRUST=any"
  else
    echo "COLLECTOR_TLS_TRUST=pin"
  fi
  [ -n "$COLLECTOR_ID" ]   && echo "COLLECTOR_COLLECTOR_DISPLAY_ID=${COLLECTOR_ID}"
  if [ -n "$POLL_INTERVAL" ]; then
    echo "COLLECTOR_POLL_INTERVAL_S=${POLL_INTERVAL}"
    # The image's healthcheck compares the liveness file's age against
    # COLLECTOR_HEALTH_MAX_AGE_S (default 130s) and the daemon touches that file
    # once per poll, so widening one without the other leaves a working collector
    # permanently `unhealthy`. Derive it here so the two cannot drift.
    # Floored at the image default so the common 30s answer keeps exactly
    # today's slack — this widens for slow sites, it never tightens.
    _max_age=$(( POLL_INTERVAL * 3 + 30 )); [ "$_max_age" -lt 130 ] && _max_age=130
    echo "COLLECTOR_HEALTH_MAX_AGE_S=${_max_age}"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# The CA bind mount is optional; compose reads its source from COLLECTOR_CA_FILE in
# our own env file (see DOTENV_FILE above) and falls back to /dev/null when no CA
# was supplied.
# TARANAC_VERSION must be in here too. The compose file resolves the image as
# ${COLLECTOR_IMAGE:-…/collector:${TARANAC_VERSION:-latest}}, and pointing compose
# at our OWN env file (so we never write the bundle's .env) cut it off from the
# version — every install silently fell back to the `latest` tag and PULLED it,
# on an appliance that is supposed to need no registry at all and already has the
# right image on disk. Read it from VERSION, the same single source of truth the
# golden image bakes from.
VERSION_FILE="${HERE}/VERSION"
TARANAC_VERSION=""
[ -f "$VERSION_FILE" ] && TARANAC_VERSION="$(head -1 "$VERSION_FILE" | tr -d '[:space:]')"
{
  echo "# Compose interpolation for the Taranac collector — written by collector-join.sh"
  [ -n "$TARANAC_VERSION" ] && printf 'TARANAC_VERSION=%s\n' "$TARANAC_VERSION"
  # An explicit override wins over the version-derived default (a locally built
  # or hand-loaded image on an air-gapped host).
  [ -n "${COLLECTOR_IMAGE:-}" ] && printf 'COLLECTOR_IMAGE=%s\n' "$COLLECTOR_IMAGE"
  [ -n "$CA_FILE" ] && printf 'COLLECTOR_CA_FILE=./%s\n' "$CA_DEST"
} > "$DOTENV_FILE"

if [ -z "$TARANAC_VERSION" ] && [ -z "${COLLECTOR_IMAGE:-}" ]; then
  echo "collector-join: NOTE — no VERSION file beside this script and no COLLECTOR_IMAGE set;" >&2
  echo "  compose will fall back to the ':latest' tag, which may not be the build you expect." >&2
fi
# These two files have TWO writers and that is by design, so neither may assume it
# owns them. The container's entrypoint chowns its config mount to the collector
# user (999) — it has to, or the daemon could not blank the spent token — and that
# chown reaches THROUGH the bind mount to the file here on the host. A second run
# of this script then cannot truncate a 0600 file owned by somebody else, and the
# operator gets `Permission denied` while merely retrying with a fresh token.
#
# So replace by RENAME rather than write in place: renaming needs permission on
# the DIRECTORY, which we have, and never on the file, which we may not own. It is
# also atomic — no window where the token file exists but is empty or half-written.
replace_file() {  # <destination> <mode> ; content on stdin
  _dst="$1"; _mode="$2"; _tmp="${_dst}.tmp.$$"
  ( umask 077; cat > "$_tmp" ) || fail "cannot write next to ${_dst} — is $(pwd) writable?"
  chmod "$_mode" "$_tmp"
  mv -f "$_tmp" "$_dst" || { rm -f "$_tmp"; fail "cannot replace ${_dst}."; }
}

if [ -n "$CA_FILE" ]; then
  replace_file "$CA_DEST" 644 < "$CA_FILE"
fi

# One-shot enrollment token — 0600, blanked by the daemon after redeeming.
printf '%s' "$TOKEN" | replace_file "$TOKEN_DEST" 600

# ── Optional: give this scanner nmap ──────────────────────────────────────────
#
# Taranac does not ship nmap and will not: redistributing it commercially needs a
# paid OEM agreement with its authors. So the package is fetched from this host's
# own distribution mirrors, into an image built on this host, and never travels in
# anything we hand out.
#
# It is offered rather than assumed. Every collector can be a scanner — where it scans
# is chosen later, in the core — so the question is asked of every interactive install.
# Without nmap a zone can still Discover (who is on the subnet) and Identify (what
# each host calls itself); nmap is what adds the Deep level — service versions and
# an operating-system guess.
if [ "$WITH_NMAP" -eq 0 ] && [ -t 0 ]; then
  printf 'collector-join: install nmap on this scanner? It enables the Deep scan level. [y/N] '
  read -r _answer || _answer=""
  case "$_answer" in [Yy]*) WITH_NMAP=1 ;; esac
fi

if [ "$WITH_NMAP" -eq 1 ]; then
  [ -f "Dockerfile.nmap" ] || fail "Dockerfile.nmap is missing from $(pwd) — it ships beside this script."
  # Derived from whatever image this install is pinned to, so an --update that moves
  # the base does not silently leave the scanner on last release's code.
  _base="$(${COMPOSE} config --images 2>/dev/null | head -1)"
  [ -n "$_base" ] || fail "could not work out which collector image this install uses."
  case "$_base" in *-nmap) _base="${_base%-nmap}" ;; esac
  _derived="${_base}-nmap"
  echo "collector-join: building ${_derived} (adds nmap from this host's package mirrors)…"
  docker build --quiet --build-arg "BASE_IMAGE=${_base}" -t "$_derived" -f Dockerfile.nmap . >/dev/null \
    || fail "could not build ${_derived}. Install nmap by hand, or re-run without --with-nmap."
  # A build that succeeded is not an nmap that runs, and the difference has already cost a
  # release: the image carried a capability the container could not grant, the kernel
  # refused the exec, and `nmap --version` answered "Operation not permitted" — discovered
  # weeks later by somebody pressing Deep and getting nothing. So the image is asked to
  # prove itself here, AS THE USER THE COLLECTOR RUNS AS, which is the only run that counts.
  echo "collector-join: checking that nmap runs in ${_derived}…"
  _nmap_check="$(docker run --rm --entrypoint sh "$_derived" -c \
    'su collector -s /bin/sh -c "nmap --version" 2>&1 | head -1' 2>&1)" || _nmap_check=""
  case "$_nmap_check" in
    *"Nmap version"*) echo "collector-join: ${_nmap_check}" ;;
    *) fail "nmap was installed into ${_derived} but will not run there: ${_nmap_check:-no output}.
    This is the image, not the network. Check the setcap line in Dockerfile.nmap — a file
    capability the container cannot grant stops the program starting at all." ;;
  esac
  # Recorded in our own env file so `up -d` and every later --update keep using it.
  grep -v '^COLLECTOR_IMAGE=' "$DOTENV_FILE" > "${DOTENV_FILE}.tmp.$$" 2>/dev/null || true
  printf 'COLLECTOR_IMAGE=%s\n' "$_derived" >> "${DOTENV_FILE}.tmp.$$"
  mv -f "${DOTENV_FILE}.tmp.$$" "$DOTENV_FILE"
  # And exported, because writing the file is not enough. Compose prefers a variable
  # already in the SHELL over the one in --env-file, and the way this script documents
  # itself for a lab is `COLLECTOR_IMAGE=... ./collector-join.sh …` — so the operator's
  # own variable silently shadows the image we just built and verified. The collector
  # then runs without nmap having been told, twice, that nmap is there.
  COLLECTOR_IMAGE="$_derived"
  export COLLECTOR_IMAGE
fi

# ── Bring the collector up ────────────────────────────────────────────────────
echo "collector-join: starting the collector…"
# The log window starts BEFORE the container does, in UTC with an explicit Z:
# `docker compose logs --since` reads a zoneless stamp as the daemon's local
# time, and would then surface a previous attempt's error as this one's.
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# --force-recreate, and it is not belt and braces. Compose decides whether to
# replace a container by comparing the SERVICE definition, and the contents of an
# `env_file:` are not part of it — so re-running this on a host that already has a
# collector leaves the old container running with the old configuration, and the
# join we just performed reaches nothing. Worse, the attach check below then waits
# for start-up markers from a process that never restarted and tells the operator
# their token is stale, which sends them to fix the one thing that was fine.
#
# Found by running this end to end rather than by reading it: the collector was
# plainly talking to the core in the log the script printed as evidence of failure.
${COMPOSE} up -d --force-recreate

# Wait for the collector to actually attach before claiming anything. Reporting
# a success we have not seen is the worst outcome available here: the container
# restart-loops out of sight and the collector never appears in the core, while
# the operator has already moved on.
echo "collector-join: waiting for the collector to attach to the core…"
ATTACHED=0; FAILURE=""; WAITED=0
while [ "$WAITED" -lt 60 ]; do
  LOG="$(${COMPOSE} logs --since "$SINCE" --no-color collector 2>&1 || true)"
  case "$LOG" in
    *"collector enrolled;"*|*"collector started ("*) ATTACHED=1; break ;;
  esac
  # `cannot start:` is the daemon's own worded refusal. But a rejected config dies
  # inside pydantic before logging exists — a bare traceback with no marker at all,
  # which is exactly when an operator most needs to be shown the log rather than
  # told there is no reason in it.
  FAILURE="$(printf '%s\n' "$LOG" | grep -m1 -E 'cannot start:|ValidationError|Traceback' || true)"
  [ -n "$FAILURE" ] && [ "$WAITED" -ge 15 ] && break
  sleep 3
  WAITED=$((WAITED + 3))
done

if [ -n "$CA_FILE" ]; then
  TRUST_LINE="CA bundle ${CA_FILE} → ./${CA_DEST} (strict)"
elif [ "$TRUST_ANY" -eq 1 ]; then
  TRUST_LINE="NONE — the core's certificate is not verified (--trust-any)"
else
  TRUST_LINE="pinned on first contact (the fingerprint appears in the log below)"
fi

if [ "$ATTACHED" -eq 1 ]; then
  cat <<EOF

collector-join: the collector is attached to ${CORE%/}.
  Trust:       ${TRUST_LINE}
  Core UI:     Settings -> System -> Collectors — it is there now.

  ${COMPOSE} logs -f collector     # follow it
  ${COMPOSE} ps                    # health = 'healthy' once polling

If the log ever says the core's certificate CHANGED, and you know it was replaced:
  ./collector-join.sh --reset-trust
EOF
  exit 0
fi

cat >&2 <<EOF

collector-join: the collector started but did NOT attach to the core.
  Core:        ${CORE%/}
  Trust:       ${TRUST_LINE}

${FAILURE:-$(printf '%s\n' "$LOG" | tail -12 | sed 's/^/  /')}

It keeps retrying, so fixing the cause is enough — nothing to uninstall. The
usual cause is a token that was already used or superseded by a newer one:
issue a FRESH token on the core and run this command again.

  ${COMPOSE} logs -f collector
EOF
exit 1
