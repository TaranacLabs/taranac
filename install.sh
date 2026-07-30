#!/usr/bin/env bash
# =============================================================================
# Taranac installer
#
# First run:   generates every secret, asks for your domain + admin details,
#              writes .env, pulls the images and starts the stack.
# Later runs:  detects an existing .env, NEVER regenerates secrets (changing
#              MASTER_KEY would brick all stored secrets), just pulls + restarts
#              — i.e. this same script is also the upgrade command. On a converted
#              HA node it merges the Patroni overlay automatically (never base-only).
# --no-start:  write/refresh .env but do NOT start the stack — use this to prepare a
#              node that will JOIN an HA cluster (then copy the HA block + ha-join.sh).
#
# Requires: docker (with the compose plugin), openssl.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
COMPOSE_HA_FILE="${SCRIPT_DIR}/docker-compose.ha.yml"
COMPOSE_ARGS=(-f "${COMPOSE_FILE}")

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
info()  { printf '%s\n' "${c_bold}==>${c_reset} $*"; }
ok()    { printf '%s\n' "${c_green}✓${c_reset} $*"; }
warn()  { printf '%s\n' "${c_yellow}!${c_reset} $*"; }
die()   { printf '%s\n' "${c_red}✗ $*${c_reset}" >&2; exit 1; }

# ── Arguments (parsed BEFORE the prerequisite checks so `--help` works even on a
# box without docker yet) ─────────────────────────────────────────────
# --no-start: write/refresh configuration but do NOT pull or start the stack. Used to
# prepare a node that will JOIN an HA cluster — ha-join.sh needs a configured .env AND
# an EMPTY data volume, so the node must not first come up as a standalone primary
# (which would initialise the volume and trip ha-join's empty-volume guard).
NO_START=0
for arg in "$@"; do
  case "$arg" in
    --no-start)   NO_START=1 ;;
    -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
    *)            die "unknown argument: ${arg} (supported: --no-start)" ;;
  esac
done

# ── Prerequisites ────────────────────────────────────────────────────
command -v docker  >/dev/null 2>&1 || die "docker is not installed. Run:  sudo bash bootstrap.sh"
command -v openssl >/dev/null 2>&1 || die "openssl is not installed. Run:  sudo bash bootstrap.sh"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not available. Run:  sudo bash bootstrap.sh"

# `docker` on PATH does NOT prove this shell can reach the daemon. The #1 first-run
# failure: bootstrap.sh added the user to the `docker` group, but group membership only
# applies to a NEW login shell — so in the SAME shell every docker call fails with a
# permission-denied on /var/run/docker.sock. Detect that exact case and give the one
# instruction that fixes it, instead of dying midway with a cryptic socket error.
if ! docker version >/dev/null 2>&1; then
    in_group_db=0    # docker is in the user's groups per the group database (after re-login)
    in_group_now=0   # docker is in THIS shell's active groups (usable right now)
    if id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then in_group_db=1; fi
    if id -nG          2>/dev/null | tr ' ' '\n' | grep -qx docker; then in_group_now=1; fi

    if [ "$(id -u)" -ne 0 ] && [ "${in_group_db}" -eq 1 ] && [ "${in_group_now}" -eq 0 ]; then
        printf '%s\n' "${c_red}${c_bold}╔══════════════════════════════════════════════════════════════════╗${c_reset}" >&2
        printf '%s\n' "${c_red}${c_bold}║  STOP — you need to start a new login session first.              ║${c_reset}" >&2
        printf '%s\n' "${c_red}${c_bold}╚══════════════════════════════════════════════════════════════════╝${c_reset}" >&2
        printf '%s\n' "  You ARE in the 'docker' group, but THIS terminal hasn't picked it" >&2
        printf '%s\n' "  up yet — group membership only applies to a NEW login session." >&2
        printf '%s\n' "" >&2
        printf '%s\n' "  Do ONE of these, then run  ./install.sh  again:" >&2
        printf '%s\n' "     ${c_bold}• log out and log back in${c_reset}, or" >&2
        printf '%s\n' "     ${c_bold}• run:   newgrp docker${c_reset}" >&2
        exit 1
    fi
    die "Cannot reach the Docker daemon. Make sure it is installed and running, and that
   your user may access it:  sudo bash bootstrap.sh"
fi

# Merge the HA overlay when this node is configured for HA. install.sh is also the
# documented UPGRADE command, so on a converted node it must NOT bring the stack up on
# the base compose alone: that starts a 2nd writable postgres on the Patroni-managed
# PGDATA → split-brain / data loss. Mirrors ./taranac + taranac-update.sh (ha.md §13 A).
# Detection fails TOWARD the overlay: the explicit TARANAC_HA=1 marker (written by
# ha-convert.sh / ha-join.sh) is authoritative; ANY uncommented non-empty DB_HOSTS is
# the defense-in-depth fallback (robust to `export `/spaces/quotes; value not parsed).
ha_is_configured() {  # $1 = path to .env; 0 = HA, 1 = standalone
    local env="$1"
    [ -f "${env}" ] || return 1
    if grep -Eq '^[[:space:]]*(export[[:space:]]+)?TARANAC_HA[[:space:]]*=[[:space:]]*"?1"?[[:space:]]*$' "${env}"; then
        return 0
    fi
    if grep -Eiq '^[[:space:]]*(export[[:space:]]+)?DB_HOSTS[[:space:]]*=[[:space:]]*"?[^"[:space:]#]' "${env}"; then
        return 0
    fi
    return 1
}

resolve_compose_files() {
    ha_is_configured "${ENV_FILE}" || return 0    # standalone → base compose only
    [ -f "${COMPOSE_HA_FILE}" ] || die "HA is configured in .env but docker-compose.ha.yml is missing — refusing to (re)start on the base compose alone (under HA that starts a 2nd writable Postgres on the Patroni data dir → split-brain). Restore the overlay from the bundle."
    COMPOSE_ARGS=(-f "${COMPOSE_FILE}" -f "${COMPOSE_HA_FILE}")
    warn "HA node detected — using the Patroni overlay. Upgrade ONE node at a time (replicas first, primary last); back up first. (HA.md §6)"
}

compose() { docker compose --env-file "${ENV_FILE}" "${COMPOSE_ARGS[@]}" "$@"; }

# ── Secret generators ────────────────────────────────────────────────
# URL-safe (hex) — used inside connection strings.
gen_hex()    { openssl rand -hex "${1:-32}"; }
# Fernet key — urlsafe base64 of 32 random bytes (matches Fernet.generate_key()).
gen_fernet() { openssl rand -base64 32 | tr '+/' '-_'; }
# Strong admin password guaranteed to satisfy complexity (upper/lower/digit/symbol).
gen_password() { printf '%sAa1!' "$(openssl rand -base64 12 | tr -d '/+=')"; }

# Declarative registry of auto-generated secrets + an idempotent, forward-only
# reconciler, shared with taranac-update.sh so a new secret is added in exactly
# one place and backfilled on every install/upgrade path. Sourced AFTER the
# generators above so its guarded gen_hex defers to this file's definition.
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/env-secrets.sh"

# ── Upgrade path: .env already present ───────────────────────────────
# SKIP_PULL=1 — use images already present locally (offline/air-gapped installs,
# or testing freshly-built images before they are published).
pull_images() {
    if [ "${SKIP_PULL:-0}" = "1" ]; then
        warn "SKIP_PULL=1 — using local images, not pulling."
    else
        info "Pulling images..."
        compose pull
    fi
}

if [ -f "${ENV_FILE}" ]; then
    warn ".env already exists — treating this as an upgrade/restart."
    warn "Secrets (including MASTER_KEY) are left untouched."
    # Backfill any auto-generated secret a newer bundle introduced (never touches
    # existing keys). Idempotent — a no-op when the .env is already current.
    reconcile_env_secrets "${ENV_FILE}"
    resolve_compose_files          # merges the HA overlay on a converted node (or dies if missing)
    if [ "${NO_START}" = "1" ]; then
        ok "--no-start: configuration left in place; stack NOT pulled or restarted."
        exit 0
    fi
    pull_images
    info "Starting stack..."
    compose up -d
    ok "Done. Stack is up."
    exit 0
fi

# ── First run: gather input ──────────────────────────────────────────
info "First-time install. Let's configure Taranac."
echo

# Each value may be pre-seeded via the environment for a NON-INTERACTIVE install
# (the OVA first-boot wizard, CI, automation); when unset it falls back to an
# interactive prompt. Same override pattern as IMAGE_PREFIX / TARANAC_VERSION below.
if [ -z "${TARANAC_DOMAIN:-}" ]; then
    read -rp "Primary domain for the admin UI [taranac.example.com]: " TARANAC_DOMAIN
    TARANAC_DOMAIN="${TARANAC_DOMAIN:-taranac.example.com}"
fi

if [ -z "${INITIAL_ADMIN_USERNAME:-}" ]; then
    read -rp "Initial admin username [admin]: " INITIAL_ADMIN_USERNAME
    INITIAL_ADMIN_USERNAME="${INITIAL_ADMIN_USERNAME:-admin}"
fi

if [ -z "${INITIAL_ADMIN_EMAIL:-}" ]; then
    read -rp "Initial admin email [admin@${TARANAC_DOMAIN}]: " INITIAL_ADMIN_EMAIL
    INITIAL_ADMIN_EMAIL="${INITIAL_ADMIN_EMAIL:-admin@${TARANAC_DOMAIN}}"
fi

# Registry, image tag and the optional MFA-push domain are NOT prompted — they are
# bundle properties, not operator choices, and prompting for them is how the tag
# drifted from the shipped images. The version is read from the bundle's VERSION
# file (the single source of truth, stamped at release time); the registry defaults
# to the public one. All three remain overridable via the environment for mirrors /
# air-gapped installs (e.g. IMAGE_PREFIX=registry.local/taranac ./install.sh).
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/taranaclabs/taranac}"
TARANAC_MFA_DOMAIN="${TARANAC_MFA_DOMAIN:-}"
if [ -z "${TARANAC_VERSION:-}" ]; then
    [ -f "${SCRIPT_DIR}/VERSION" ] || die "VERSION file is missing from the bundle — cannot determine which image tag to install. Re-extract a complete bundle."
    TARANAC_VERSION="$(head -1 "${SCRIPT_DIR}/VERSION" | tr -d '[:space:]')"
    [ -n "${TARANAC_VERSION}" ] || die "VERSION file is empty — cannot determine which image tag to install."
fi
info "Installing Taranac ${c_bold}${TARANAC_VERSION}${c_reset} from ${IMAGE_PREFIX}"

# ── Generate secrets ─────────────────────────────────────────────────
info "Generating secrets..."
POSTGRES_PASSWORD="$(gen_hex 24)"
# Generated even on a single node so a later convert-to-HA already has a strong
# replicator password (the replicator role is created on first init; ha.md §6.7).
POSTGRES_REPLICATION_PASSWORD="$(gen_hex 24)"
SECRET_KEY="$(gen_hex 48)"
MASTER_KEY="$(gen_fernet)"
INTERNAL_API_KEY="$(gen_hex 32)"
TARANAC_MFA_API_KEY="$(gen_hex 32)"
INITIAL_ADMIN_PASSWORD="$(gen_password)"
ok "Secrets generated."

# ── Derive addressing ────────────────────────────────────────────────
CORS_ORIGINS="[\"https://${TARANAC_DOMAIN}\"]"
if [ -n "${TARANAC_MFA_DOMAIN}" ]; then
    MFA_PUSH_URL="https://${TARANAC_MFA_DOMAIN}/ttype/push"
else
    MFA_PUSH_URL="https://${TARANAC_DOMAIN}:8443/ttype/push"
fi

# ── Write .env ───────────────────────────────────────────────────────
info "Writing ${ENV_FILE}..."
umask 077
cat > "${ENV_FILE}" <<EOF
# Generated by install.sh — do not commit. Back up MASTER_KEY.
IMAGE_PREFIX=${IMAGE_PREFIX}
TARANAC_VERSION=${TARANAC_VERSION}

TARANAC_DOMAIN=${TARANAC_DOMAIN}
TARANAC_MFA_DOMAIN=${TARANAC_MFA_DOMAIN}
EDGE_HTTP_PORT=80
EDGE_HTTPS_PORT=443
TARANAC_TLS_CERT=/etc/taranac/tls/tls.crt
TARANAC_TLS_KEY=/etc/taranac/tls/tls.key

POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_URL=postgresql+asyncpg://taranac:${POSTGRES_PASSWORD}@postgres:5432/taranac
POSTGRES_REPLICATION_PASSWORD=${POSTGRES_REPLICATION_PASSWORD}

# Stable node identity (the container hostname churns on recreate). Under HA make it
# unique per node = the node's Patroni member name. See docs/guide/ha.md.
TARANAC_NODE_NAME=taranac-node-1

# ─── HA / clustering (Pro) — leave commented on a single node ───
# To go HA: uncomment + fill these (the SAME on every node except the per-node ones),
# bring up a witness on a 3rd host, then run ha-convert.sh (seed) / ha-join.sh (nodes).
# Full guidance: docs/guide/ha.md and the .env.example HA block.
#DB_HOSTS=10.0.0.1:5432,10.0.0.2:5432
#DB_CONNECT_TIMEOUT=3
#TARANAC_CLUSTER_NAME=taranac
#NODE_ADDRESS=10.0.0.1
#PG_ALLOW_CIDR=10.0.0.0/24
#ETCD_NAME=taranac-node-1
#ETCD_INITIAL_CLUSTER=taranac-node-1=https://10.0.0.1:2380,taranac-node-2=https://10.0.0.2:2380,witness=https://10.0.0.3:2380
#ETCD_INITIAL_CLUSTER_STATE=new
#ETCD_HOSTS=10.0.0.1:2379,10.0.0.2:2379,10.0.0.3:2379
# Secure etcd (peer auto-TLS + one-way client TLS) is the DEFAULT (#30). You do NOT hand-set
# the TLS knobs — 'ha-convert.sh --prepare'/'--continue' (seed) generates the CA + per-node
# certs, enables peer auto-TLS, and rewrites the member URLs above to https://; 'ha-join.sh
# --primary' makes each node follow. The etcd CA + mfa key travel OOB in the "cluster secret
# set" (ha.md §7.3/§12). To opt DOWN to plaintext, run 'ha-convert.sh --plaintext'.
# ⚠️ FIREWALL 2379/2380 to the private interconnect either way. Live migration: ha.md §7.2/§7.3.
#ETCD_PEER_SCHEME=https
#ETCD_PEER_AUTO_TLS=true
#ETCD_CLIENT_SCHEME=https

APP_HOST=0.0.0.0
APP_PORT=8000
APP_NAME=taranac
APP_ENV=production
DOCS_ENABLED=false

SECRET_KEY=${SECRET_KEY}
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7
MFA_TOKEN_EXPIRE_MINUTES=5
BCRYPT_ROUNDS=12
MAX_LOGIN_ATTEMPTS=5
LOCKOUT_DURATION_MINUTES=15
TRUSTED_PROXY_HOPS=2

MASTER_KEY_SOURCE=env
MASTER_KEY=${MASTER_KEY}
MASTER_KEY_FILE=/run/secrets/master_key

CORS_ORIGINS=${CORS_ORIGINS}
INTERNAL_TLS_VERIFY=true

LOG_LEVEL=INFO
LOG_OUTPUT=stdout
SUPPORTED_LOCALES=en,de,es,fr,pt

TACACS_PORT=49
TACACS_TLS_PORT=6049
RADIUS_AUTH_PORT=1812
RADIUS_ACCT_PORT=1813
NAC_AUTH_PORT=1814
NAC_ACCT_PORT=1815
NAC_COA_PORT=3799
FRONTEND_PORT=3000
MFA_PORT=8443
CAPTIVE_PORTAL_HTTP_PORT=8080
CAPTIVE_PORTAL_HTTPS_PORT=8444

RATE_LIMIT_ENABLED=true
RATE_LIMIT_STORAGE=memory

INITIAL_ADMIN_USERNAME=${INITIAL_ADMIN_USERNAME}
INITIAL_ADMIN_EMAIL=${INITIAL_ADMIN_EMAIL}
INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}
INITIAL_ADMIN_GROUP_NAME=Administrators

MONITORING_HOST_ROOT=/host

TARANAC_MFA_API_KEY=${TARANAC_MFA_API_KEY}
TARANAC_MFA_PUSH_REGISTRATION_URL=${MFA_PUSH_URL}

INTERNAL_API_KEY=${INTERNAL_API_KEY}
EOF
umask 022
ok ".env written (mode 600)."

# Append the auto-generated managed secrets (REPORTS_RENDERER_API_KEY, …) from the
# shared registry — the same pass that backfills them on upgrade, so fresh and
# upgraded installs converge to an identical key set.
reconcile_env_secrets "${ENV_FILE}"

# ── Prepare operator config directories ──────────────────────────────
# config/etcd-tls is the RO bind-mount source for the HA etcd client-TLS material
# (ca.crt + this node's etcd server leaf). Created empty + inert; ha-convert/ha-join
# populate it only when client-TLS is enabled (ha.md §7.3). Present-but-empty keeps the
# HA overlay's bind mount valid on an http (default) cluster.
mkdir -p "${SCRIPT_DIR}/config/tls" "${SCRIPT_DIR}/config/firebase" "${SCRIPT_DIR}/config/etcd-tls"
ok "Created config/tls/ (drop tls.crt + tls.key here), config/firebase/, and config/etcd-tls/."

# ── Pull and start ───────────────────────────────────────────────────
resolve_compose_files          # standalone here (DB_HOSTS commented) → base compose only
if [ "${NO_START}" = "1" ]; then
    echo
    ok ".env written; the stack was NOT started (--no-start)."
    info "This node is ready to JOIN an HA cluster:"
    info "  1. copy the cluster-wide HA block from the primary's .env into ${ENV_FILE}"
    info "     (TARANAC_CLUSTER_NAME, DB_HOSTS, ETCD_*, POSTGRES_PASSWORD, POSTGRES_REPLICATION_PASSWORD, PG_ALLOW_CIDR)"
    info "  2. on the primary, issue a join token: ./taranac cluster join-token --name <node> --address <addr>"
    info "  3. on this node:  MASTER_KEY=<key> ./ha-join.sh --node-name <node> --node-address <addr> --join-token <secret>"
    exit 0
fi
pull_images
info "Starting the stack..."
compose up -d

# ── Summary ──────────────────────────────────────────────────────────
echo
ok "Taranac is starting."
cat <<EOF

${c_yellow}${c_bold}╔════════════════════════════════════════════════════════════╗${c_reset}
${c_yellow}${c_bold}║  SAVE YOUR ADMIN CREDENTIALS NOW                             ║${c_reset}
${c_yellow}${c_bold}╚════════════════════════════════════════════════════════════╝${c_reset}
  URL:      https://${TARANAC_DOMAIN}
  Username: ${INITIAL_ADMIN_USERNAME}
  Password: ${c_yellow}${c_bold}${INITIAL_ADMIN_PASSWORD}${c_reset}

  Change the password right after your first login.
  (Also stored in ${ENV_FILE} as INITIAL_ADMIN_PASSWORD if you miss it.)

${c_bold}Trusted TLS certificate${c_reset}
  Put your CA-signed cert + key in:
    ${SCRIPT_DIR}/config/tls/tls.crt   (full chain)
    ${SCRIPT_DIR}/config/tls/tls.key
  then:  ./taranac restart edge
  Until then the edge serves a self-signed cert and browsers will warn.

${c_bold}MFA push (optional, paid tier)${c_reset}
  Without a Firebase key MFA runs in free poll-only mode.
  To enable push, drop your service-account JSON at:
    ${SCRIPT_DIR}/config/firebase/firebase-credentials.json
  then:  ./taranac up -d taranac-mfa

${c_bold}Back up now${c_reset}
  Keep ${ENV_FILE} safe — especially MASTER_KEY. Losing it makes every stored
  secret undecryptable.
EOF
