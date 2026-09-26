#!/usr/bin/env bash
# =============================================================================
# taranac-restore.sh — guided disaster recovery from a Taranac backup archive.
#
# Normally invoked as:  ./taranac restore <archive-filename.tar>
#
# WHAT RECOVERY IS
#   Deploy the same version fresh, overlay the handful of secrets that must
#   survive the rebuild, recreate the containers, then load the database dump.
#   In that order — the database is full of Fernet ciphertext, so the key has to
#   be in place before the data means anything.
#
# WHY THE .env IS NOT COPIED BACK
#   The archive carries the old host's .env whole (it is the record of how that
#   install was configured, and the only place MASTER_KEY ever existed). But
#   restoring it wholesale would carry the OLD host onto the NEW one: the image
#   tag (TARANAC_VERSION — a silent rollback), the HA topology (NODE_ADDRESS,
#   DB_HOSTS, ETCD_INITIAL_CLUSTER, TARANAC_NODE_NAME, PG_ALLOW_CIDR), the
#   domains, ports, TLS paths and all three database connection settings. And an
#   archive cut by an older release simply has no line for a key added since —
#   restoring a 1.1.2 archive over 1.2.1 would drop REPORTS_RENDERER_API_KEY and
#   break the report renderer. The list of things to EXCLUDE would grow with every
#   release; the list of things that must SURVIVE is short and stable, so that is
#   the list we keep. Same shape as MANAGED_SECRETS in env-secrets.sh.
#
# Prerequisites:
#   * A freshly deployed, HEALTHY Taranac of the archive's version (log in as the
#     default admin once — that separates "the deploy failed" from "recovery
#     failed").
#   * The archive present in ./backups/ (copy it back if the host was rebuilt).
#   * The ORIGINAL master key. If the fresh install does not already run with it,
#     pass it: --master-key <key>. Without it the archive cannot be opened at all.
#
# Usage:
#   ./taranac restore taranac-backup-YYYYMMDDTHHMMSSZ.tar [--master-key KEY] [--yes]
#
# In the source repo (dev/prod layouts) point it at the right pair explicitly:
#   TARANAC_ENV_FILE=.env.dev TARANAC_COMPOSE_FILE=docker-compose.dev.yml \
#     deploy/dist/taranac-restore.sh <archive.tar>
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${HERE}"

ENV_FILE="${TARANAC_ENV_FILE:-.env}"
COMPOSE_FILE="${TARANAC_COMPOSE_FILE:-docker-compose.yml}"

ARCHIVE_NAME=""
MASTER_KEY_ARG=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --master-key) MASTER_KEY_ARG="${2:-}"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    -*)           echo "✗ unknown option: $1" >&2; exit 1 ;;
    *)            ARCHIVE_NAME="$1"; shift ;;
  esac
done

[ -n "${ARCHIVE_NAME}" ] || { echo "Usage: ./taranac restore <archive-filename.tar> [--master-key KEY] [--yes]" >&2; exit 1; }
[ -f "${ENV_FILE}" ] || { echo "✗ ${ENV_FILE} not found — deploy a fresh install first (./install.sh)." >&2; exit 1; }

# ── HA awareness ────────────────────────────────────────────────────────────
# Under HA the database is Patroni-managed via the overlay. Acting on the base
# compose alone would start a SECOND writable Postgres on the Patroni data
# directory — split-brain, on a host we are in the middle of recovering. Same
# detection as the `taranac` wrapper (docs/ops/ha.md): fail toward the
# overlay, never silently base-only.
COMPOSE_FILES=(-f "${COMPOSE_FILE}")
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?TARANAC_HA[[:space:]]*=[[:space:]]*"?1"?[[:space:]]*$' "${ENV_FILE}" \
   || grep -Eiq '^[[:space:]]*(export[[:space:]]+)?DB_HOSTS[[:space:]]*=[[:space:]]*"?[^"[:space:]#]' "${ENV_FILE}"; then
  [ -f docker-compose.ha.yml ] || {
    echo "✗ HA is configured but docker-compose.ha.yml is missing. Refusing to act on the" >&2
    echo "  base compose alone — that would start a second writable Postgres on the" >&2
    echo "  Patroni-managed data directory. Restore the overlay ('./taranac update') first." >&2
    exit 1
  }
  COMPOSE_FILES=(-f "${COMPOSE_FILE}" -f docker-compose.ha.yml)
  echo "! HA detected — using the Patroni overlay."
  echo "  Recovery runs on the LEADER. Other nodes rejoin afterwards (see HA.md)."
fi
COMPOSE=(docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}")

ARCHIVE_IN_CONTAINER="/app/backups/${ARCHIVE_NAME}"
RESTORE_OUT_CONTAINER="/app/backups/restore"

# The values that must survive the rebuild. Everything else in a .env describes
# the host, and a rebuilt host has its own. Mirrored by RECOVERY_KEYS in
# backend/app/scripts/restore.py (a unit test asserts the two stay identical).
MANAGED_RECOVERY_KEYS=(
    MASTER_KEY                 # decrypts every secret in the database dump
    SECRET_KEY                 # signs sessions
    TARANAC_MFA_API_KEY        # paired — the other half is a row in the restored DB
    INTERNAL_API_KEY           # paired — daemons ↔ api
    REPORTS_RENDERER_API_KEY   # paired — api ↔ taranac-renderer
)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { echo "✗ $1" >&2; exit 1; }

# ── Phase 1: verify the key, extract the host material ──────────────────────
say "Phase 1: verify master key + extract host files, certificates"
HOST_ARGS=()
[ -n "${MASTER_KEY_ARG}" ] && HOST_ARGS=(--master-key "${MASTER_KEY_ARG}")
"${COMPOSE[@]}" exec -T api python -m app.scripts.restore host \
  "${ARCHIVE_IN_CONTAINER}" --out "${RESTORE_OUT_CONTAINER}" "${HOST_ARGS[@]}" \
  || fail "phase 1 failed — nothing has been changed."

# The api mounts ./backups, so what the container wrote is readable right here.
RESTORE_OUT_HOST="./backups/restore"
RESTORED_ENV="${RESTORE_OUT_HOST}/env/env"

if [ ! -f "${RESTORED_ENV}" ]; then
  echo
  echo "! This archive carries no env-file snapshot (taken before the host-files mount"
  echo "  was fixed, or with 'include host files' switched off). The five recovery keys"
  echo "  cannot be read from it — the master key you are restoring WITH is the only one"
  echo "  that matters for the database, and it is already in ${ENV_FILE}. The paired API"
  echo "  keys (MFA, renderer) may end up mismatched; re-pair them from the UI afterwards."
  MANAGED_RECOVERY_KEYS=()
fi

# ── Overlay the recovery keys onto THIS install's .env ──────────────────────
if [ "${#MANAGED_RECOVERY_KEYS[@]}" -gt 0 ]; then
  say "Overlaying the recovery keys onto ${ENV_FILE}"
  cp -a "${ENV_FILE}" "${ENV_FILE}.pre-restore"
  echo "  (previous file kept as ${ENV_FILE}.pre-restore)"
  CHANGED=0
  for key in "${MANAGED_RECOVERY_KEYS[@]}"; do
    # Read the archived value verbatim: first assignment wins, no interpolation.
    value="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "${RESTORED_ENV}" | sed -E "s/^[^=]*=//" || true)"
    if [ -z "${value}" ]; then
      echo "  - ${key}: absent from the archived env-file — left as deployed"
      continue
    fi
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "${ENV_FILE}"; then
      # Rewrite the first matching line, replacing everything after the first '='.
      # Done with awk substr rather than sed s/// because the values are base64url
      # and hex — a '/' or '&' in a sed replacement would be interpreted, and
      # silently corrupting MASTER_KEY here is unrecoverable.
      # The value travels through the ENVIRONMENT, not -v: awk expands backslash
      # escapes in a -v assignment, and a mangled MASTER_KEY is unrecoverable.
      TARANAC_RESTORE_VALUE="${value}" awk -v re="^[[:space:]]*(export[[:space:]]+)?${key}=" '
        { if (!done && $0 ~ re) { eq = index($0, "="); $0 = substr($0, 1, eq) ENVIRON["TARANAC_RESTORE_VALUE"]; done = 1 } print }
      ' "${ENV_FILE}" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "${ENV_FILE}"
    else
      printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
    echo "  - ${key}: restored from the archive"
    CHANGED=1
  done
  [ "${CHANGED}" -eq 1 ] || echo "  (nothing changed — this install already runs the archived secrets)"
fi

# ── Reconcile the daemons' master_key volume ────────────────────────────────
# tacacs/radius/nac read the KEK from a FILE in the shared master_key volume, and
# their entrypoint provisions it ABSENT-ONLY — an existing file is never updated.
# A fresh install has already pinned its OWN generated key there, so without this
# the daemons would decrypt device secrets with the wrong key while the api is
# fine: enable-password and shared-secret reads fail on a system that otherwise
# looks healthy. Same reconciliation ha-join.sh does when a node joins a cluster.
say "Reconciling the daemons' master_key volume"
# Resolve the volume by asking a daemon container what is mounted at /run/secrets,
# rather than guessing the compose project prefix (COMPOSE_PROJECT_NAME may differ).
MK_VOL=""
TACACS_ID="$("${COMPOSE[@]}" ps -q tacacs 2>/dev/null || true)"
if [ -n "${TACACS_ID}" ]; then
  MK_VOL="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/run/secrets"}}{{.Name}}{{end}}{{end}}' "${TACACS_ID}")"
fi
if [ -n "${MK_VOL}" ]; then
  docker run --rm -v "${MK_VOL}:/d" busybox rm -f /d/master_key \
    || fail "could not clear the stale master key from ${MK_VOL}. Remove it manually: docker run --rm -v ${MK_VOL}:/d busybox rm -f /d/master_key"
  echo "  cleared ${MK_VOL} — the daemon entrypoints will adopt the restored MASTER_KEY on the next start."
else
  echo "  daemons are not running on this node — nothing to reconcile."
  echo "  If they are added later, clear their master_key volume once so the entrypoint"
  echo "  adopts the restored MASTER_KEY (it provisions absent-only and never updates)."
fi

# ── Certificates + operator files ───────────────────────────────────────────
say "Restoring certificates into the taranac_certs volume"
"${COMPOSE[@]}" exec -T api sh -c \
  "cp -a ${RESTORE_OUT_CONTAINER}/certs/. /opt/taranac/certs/ 2>/dev/null || true"

if [ -d "${RESTORE_OUT_HOST}/host_config" ] && [ -d ./config ]; then
  say "Restoring the operator's TLS certificate, Firebase key and etcd CA into ./config"
  cp -a "${RESTORE_OUT_HOST}/host_config/." ./config/
  echo "  restored: $(ls "${RESTORE_OUT_HOST}/host_config" | tr '\n' ' ')"
  # Re-apply the group the api needs, so THIS node's next backup carries them too.
  # `cp -a` preserves what the archive holds, which is right when the archive was
  # written by 1.2.8+ and wrong for every older one — and a restore run as root
  # produces root-owned files either way. Getting this wrong is silent: the node
  # comes up fine and its archives quietly stop carrying the cluster CA.
  if [ -f "${HERE}/env-secrets.sh" ]; then
    # shellcheck source=/dev/null
    . "${HERE}/env-secrets.sh" 2>/dev/null || true
    type secure_host_config >/dev/null 2>&1 && secure_host_config "./config" || true
  fi
elif [ -d "${RESTORE_OUT_HOST}/host_config" ]; then
  echo
  echo "! The archive carries host_config/ (TLS cert / Firebase key) but this layout has"
  echo "  no ./config directory. Place them by hand from ${RESTORE_OUT_HOST}/host_config/."
fi

# ── Recreate the stack with the restored secrets ────────────────────────────
say "Recreating the services that read the restored secrets"
# Only the containers whose environment or key volume changed. Postgres (and etcd
# under HA) are deliberately left alone: their data is what we are about to restore
# INTO, and force-recreating a Patroni-managed primary mid-recovery would invite a
# leader election at the worst possible moment. Intersected with the compose file's
# own service list so a layout without, say, the renderer does not error out.
SERVICES="$("${COMPOSE[@]}" config --services)"
TARGETS=()
for svc in api tacacs radius nac taranac-mfa taranac-renderer; do
  printf '%s\n' "${SERVICES}" | grep -qx "${svc}" && TARGETS+=("${svc}")
done
"${COMPOSE[@]}" up -d --force-recreate "${TARGETS[@]}" \
  || fail "the stack did not come back up — fix that before phase 2."
echo "  waiting for the api to become healthy…"
for _ in $(seq 1 60); do
  "${COMPOSE[@]}" exec -T api python -c "import app.main" >/dev/null 2>&1 && break
  sleep 2
done

# ── Phase 2: the database ───────────────────────────────────────────────────
say "Phase 2: load the configuration dump (DESTRUCTIVE — replaces current config)"
DB_ARGS=()
[ "${ASSUME_YES}" -eq 1 ] && DB_ARGS=(--yes)
"${COMPOSE[@]}" exec -T api python -m app.scripts.restore db "${ARCHIVE_IN_CONTAINER}" "${DB_ARGS[@]}" \
  || fail "phase 2 failed. The stack is up with the restored secrets; re-run once the cause is fixed."

say "Restarting every service so it re-reads the restored configuration"
"${COMPOSE[@]}" restart

cat <<EOF

✓ Recovery complete.

Verify by VERDICT, not by the absence of errors in a log:
  * log in to the UI with a pre-disaster account;
  * authenticate a real device over TACACS+ (proves the device shared secret
    survived — it is Fernet ciphertext in the dump, decrypted with the key you
    just restored);
  * authenticate a real endpoint over 802.1X (proves the PKI survived).

Two things this archive deliberately does not carry:
  * MFA enrollments — taranac-mfa has its own database and its own crypto.
    Users with Push/TOTP re-enroll unless you protected that side separately.
  * The Active Directory machine account — Samba rotates its password weekly, so a
    restored one would be a broken trust. Re-join the domain from
    System → Authentication if MS-CHAPv2 is used.

The previous env-file is kept at ${ENV_FILE}.pre-restore; the archive's own copy is
at ${RESTORED_ENV} if you want to compare how the old host was configured. Delete
${RESTORE_OUT_HOST} when you are done — it holds decrypted secrets.
EOF
