#!/usr/bin/env bash
# ============================================================================
# rotate-key.sh — rotate the master encryption key (KEK).
#
# Driven by  ./taranac rotate-key  — see docs/spec/backend/core/crypto.md.
#
# The KEK encrypts every secret Taranac stores: device and group shared secrets,
# enable passwords, the internal CA's private keys, NCM credentials, TOTP
# secrets, the LDAP bind password, the license. Rotation happens on a STOPPED
# system, in ONE database transaction, so "half the data on the old key" cannot
# happen.
#
#   ./taranac rotate-key --confirm LOCAL-ACCESS-VERIFIED            # generate a new key
#   ./taranac rotate-key --confirm LOCAL-ACCESS-VERIFIED \
#       --new-key-file /path/to/key                                 # supply your own
#
# You will be asked for the CURRENT key. That is not a formality: it proves you
# still hold the key that opens every archive taken so far. If you cannot
# produce it, do not rotate — you would be locking yourself out of your own
# backups this minute.
#
# WHAT STOPS, AND WHY THE TYPED CONFIRMATION:
#   TACACS+ goes down with everything else, so during the window nobody can log
#   in to the switches — and the admin UI that would fix that is down too. If
#   the local fallback accounts on your network gear are not known-good, you can
#   lock yourself OUT OF YOUR OWN NETWORK. No tool can check that for you, which
#   is why --confirm LOCAL-ACCESS-VERIFIED must be typed in full.
# ============================================================================
set -euo pipefail

# Defaults are the shipped bundle's layout. The four TARANAC_* overrides exist so
# this script can be exercised against a dev/CI stack, whose compose file, env file
# and volume names differ (e.g. docker-compose.dev.yml + .env.dev, and a volume
# named master_key_dev rather than master_key). A rotation tool that can only run
# on a production-shaped install is a tool that never gets rehearsed before it is
# needed. Operators never set these.
HERE="${TARANAC_BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "${HERE}" || { echo "rotate-key: cannot enter ${HERE}" >&2; exit 1; }

ENV_FILE="${TARANAC_ENV_FILE:-.env}"
COMPOSE_FILE="${TARANAC_COMPOSE_FILE:-docker-compose.yml}"
RETIRED_DIR="config/retired-keys"
WORK_DIR="config/.rotate"          # transient; wiped on exit
CONFIRM_PHRASE="LOCAL-ACCESS-VERIFIED"
DAEMONS=(tacacs radius nac)

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_reset} $*"; }
ok()   { printf '%s\n' "${c_green}✓${c_reset} $*"; }
warn() { printf '%s\n' "${c_yellow}!${c_reset} $*"; }
fail() { printf '%s\n' "${c_red}✗${c_reset} rotate-key: $*" >&2; exit 1; }

gen_fernet() { openssl rand -base64 32 | tr '+/' '-_'; }
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- ; }
setenv() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    local esc; esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ── Compose plumbing (mirrors ./taranac) ──────────────────────────────────────
ha_is_configured() {
  [ -f "${ENV_FILE}" ] || return 1
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?TARANAC_HA[[:space:]]*=[[:space:]]*"?1"?[[:space:]]*$' "${ENV_FILE}" && return 0
  grep -Eiq '^[[:space:]]*(export[[:space:]]+)?DB_HOSTS[[:space:]]*=[[:space:]]*"?[^"[:space:]#]' "${ENV_FILE}" && return 0
  return 1
}
COMPOSE_FILES=(-f "${COMPOSE_FILE}")
if ha_is_configured; then
  [ -f docker-compose.ha.yml ] || fail "HA is configured but docker-compose.ha.yml is missing — run './taranac update' first."
  COMPOSE_FILES=(-f "${COMPOSE_FILE}" -f docker-compose.ha.yml)
fi
dc() { docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}" "$@"; }

# The rotation runs in a THROWAWAY api container (--no-deps) so it can work while
# the api service itself is stopped. Keys travel as files on a mounted directory,
# never on the command line: argv shows up in `ps` and in shell history.
#
# --entrypoint is overridden for two reasons. (1) The image's entrypoint ends with
# `gosu taranac`, i.e. uid 999, which cannot read key files that are mode 0400 and
# owned by the operator running this script — the tool would die on "permission
# denied" reading a key it was just handed. Overriding runs as the image's default
# user (root), which reads the mount regardless of the host uid, and avoids
# chown-ing the operator's own key files to a container uid. (2) That entrypoint
# also generates TLS certs and runs `alembic upgrade head`; rotation needs neither
# and must not do schema work as a side effect of a key operation.
run_tool() {
  dc run --rm --no-deps --entrypoint python \
     -v "${HERE}/${WORK_DIR}:/run/rotate:ro" api "$@"
}

# ── Arguments ─────────────────────────────────────────────────────────────────
CONFIRM=""; NEW_KEY_FILE=""; CURRENT_KEY_FILE=""; SKIP_BACKUP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm)           CONFIRM="${2:-}"; shift 2 ;;
    --new-key-file)      NEW_KEY_FILE="${2:-}"; shift 2 ;;
    --current-key-file)  CURRENT_KEY_FILE="${2:-}"; shift 2 ;;
    --no-backup)         SKIP_BACKUP=1; shift ;;
    -h|--help)           sed -n '2,27p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -f "${ENV_FILE}" ] || fail "no .env found — run ./install.sh first."

if [ "${CONFIRM}" != "${CONFIRM_PHRASE}" ]; then
  cat >&2 <<EOF
${c_red}✗${c_reset} rotate-key needs an explicit, typed confirmation.

  Rotating the master key stops the whole stack, including TACACS+ and RADIUS.
  While it is down:
    • nobody can log in to switches through TACACS+ (the admin UI is down too);
    • new 802.1X authentications fail — switches apply their dead-server policy;
    • established 802.1X sessions survive until they re-authenticate.

  Before you continue, confirm that every device managed through TACACS+ has a
  known-good LOCAL account with enable access. Taranac cannot verify this: those
  accounts live on the devices, not here. If they are not in place, this window
  can lock you out of your own network.

  When you are sure, re-run with:

      ./taranac rotate-key --confirm ${CONFIRM_PHRASE}
EOF
  exit 2
fi

# ── Work dir + cleanup ────────────────────────────────────────────────────────
umask 077
rm -rf "${WORK_DIR}"; mkdir -p "${WORK_DIR}" "${RETIRED_DIR}"
chmod 700 "${WORK_DIR}" "${RETIRED_DIR}"
cleanup() { rm -rf "${HERE:?}/${WORK_DIR}"; }
trap cleanup EXIT

# ── The current key: proof of possession ──────────────────────────────────────
if [ -n "${CURRENT_KEY_FILE}" ]; then
  [ -f "${CURRENT_KEY_FILE}" ] || fail "current key file not found: ${CURRENT_KEY_FILE}"
  tr -d '\r\n' < "${CURRENT_KEY_FILE}" > "${WORK_DIR}/current.key"
else
  echo
  info "Enter the CURRENT master key (input is hidden)."
  echo "    It is MASTER_KEY in ${ENV_FILE}. Being asked for it is deliberate: if you cannot"
  echo "    produce it, every backup archive you hold is already unreadable, and rotating now"
  echo "    would only make that permanent."
  read -r -s -p "    Current key: " typed_key; echo
  printf '%s' "${typed_key}" > "${WORK_DIR}/current.key"
  unset typed_key
fi
chmod 400 "${WORK_DIR}/current.key"

# Cross-check against .env before touching the database: catches a typo instantly.
env_key="$(getenv MASTER_KEY || true)"
if [ -n "${env_key}" ] && [ "${env_key}" != "$(cat "${WORK_DIR}/current.key")" ]; then
  fail "the key you entered does not match MASTER_KEY in ${ENV_FILE}. Nothing has been changed."
fi

# ── The new key ───────────────────────────────────────────────────────────────
if [ -n "${NEW_KEY_FILE}" ]; then
  [ -f "${NEW_KEY_FILE}" ] || fail "new key file not found: ${NEW_KEY_FILE}"
  tr -d '\r\n' < "${NEW_KEY_FILE}" > "${WORK_DIR}/new.key"
else
  gen_fernet | tr -d '\n' > "${WORK_DIR}/new.key"
  ok "Generated a new Fernet key."
fi
chmod 400 "${WORK_DIR}/new.key"
[ "$(cat "${WORK_DIR}/current.key")" != "$(cat "${WORK_DIR}/new.key")" ] \
  || fail "the new key is identical to the current one — nothing to do."

# ── Resolve the daemons' master_key volume, and PROVE it exists ───────────────
# The tacacs/radius/nac daemons read the KEK from a file in this shared volume.
# Its real name is "<compose project>_master_key", and the project defaults to the
# bundle directory's name — so hardcoding "taranac_master_key" is a guess that is
# wrong for anyone who renamed the directory. Guessing wrong here is the worst
# possible failure mode: the database would move to the new key while the daemons
# kept reading the old one, and every device-secret lookup would start failing
# minutes later, far from the cause. So the name is derived and then VERIFIED —
# before anything is stopped, while a failure still costs nothing.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "${HERE}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')}"
MK_VOL="${TARANAC_MK_VOLUME:-${PROJECT}_master_key}"
if ! docker volume inspect "${MK_VOL}" >/dev/null 2>&1; then
  fail "cannot find the daemons' master-key volume '${MK_VOL}'.
    Rotating without updating it would leave tacacs/radius/nac on the OLD key while the
    database moves to the new one. Find the right name and re-run with COMPOSE_PROJECT_NAME set:
        docker volume ls | grep master_key
        COMPOSE_PROJECT_NAME=<project> ./taranac rotate-key --confirm ${CONFIRM_PHRASE}"
fi
ok "Daemon key volume: ${MK_VOL}"

# ── Preflight (system still running) ──────────────────────────────────────────
echo
info "Preflight — verifying the key and counting what would move..."
PREFLIGHT_ARGS=(-m app.scripts.rotate_key preflight --current-key-file /run/rotate/current.key)
[ "${SKIP_BACKUP}" -eq 1 ] && PREFLIGHT_ARGS+=(--no-backup)
run_tool "${PREFLIGHT_ARGS[@]}" || fail "preflight failed — nothing has been changed."

# ── Stop, rotate, restart ─────────────────────────────────────────────────────
echo
info "Stopping the stack..."
dc stop api "${DAEMONS[@]}"
ok "Stopped (Postgres stays up)."

OLD_FP="$(sha256sum "${WORK_DIR}/current.key" | cut -c1-16)"
RETIRED_PATH="${RETIRED_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${OLD_FP}.key"
cp "${WORK_DIR}/current.key" "${RETIRED_PATH}"
chmod 400 "${RETIRED_PATH}"
ok "Previous key kept at ${RETIRED_PATH}"

# The key must be durable on disk BEFORE the commit — a key that exists only in
# memory was the original bug. Written to both places the runtime reads it from:
# .env (the api) and the shared master_key volume (the tacacs/radius/nac
# daemons, whose entrypoints provision it absent-only and will NOT overwrite).
write_key() {  # $1 = key file to publish
  setenv MASTER_KEY "$(cat "$1")"
  docker run --rm -v "${MK_VOL}:/d" -v "${HERE}/$1:/in:ro" busybox \
    sh -c 'cp /in /d/master_key && chmod 400 /d/master_key' >/dev/null
}
info "Publishing the new key to .env and the daemon volume..."
write_key "${WORK_DIR}/new.key"

echo
info "Re-encrypting (one transaction)..."
if ! run_tool -m app.scripts.rotate_key apply \
        --current-key-file /run/rotate/current.key \
        --new-key-file /run/rotate/new.key; then
  warn "Rotation failed — the database was NOT changed (the transaction rolled back)."
  info "Restoring the previous key and restarting..."
  write_key "${WORK_DIR}/current.key"
  dc up -d api "${DAEMONS[@]}"
  fail "rotation aborted; the system is back on the previous key (${OLD_FP})."
fi

echo
info "Starting the stack..."
dc up -d api "${DAEMONS[@]}"

NEW_FP="$(sha256sum "${WORK_DIR}/new.key" | cut -c1-16)"
cat <<EOF

${c_green}✓${c_reset} ${c_bold}Master key rotated.${c_reset}   ${OLD_FP} → ${NEW_FP}

  The previous key is kept at:
      ${HERE}/${RETIRED_PATH}
  ${c_bold}Keep it.${c_reset} Every backup archive taken before now is encrypted with it, and
  restoring one needs it:
      python -m app.scripts.restore host <archive.tar> --master-key <previous key>

  The new key is now in ${ENV_FILE} — back that up somewhere safe and offline.
EOF

if ha_is_configured; then
  cat <<EOF

  ${c_yellow}HA — one more step.${c_reset} The database is shared and now holds ONE key version,
  so every node needs the new key. Copy it to each replica out of band, exactly
  as MASTER_KEY was carried at join time, then start them:

      # on each replica, in the bundle directory:
      #   set MASTER_KEY=<the new key> in .env
      #   docker run --rm -v taranac_master_key:/d busybox rm -f /d/master_key
      ./taranac up -d

  Until a replica has the new key it will ${c_bold}refuse to start${c_reset} — that is the KEK
  canary doing its job, and it is how you find a node the key has not reached.
EOF
fi
