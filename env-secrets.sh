#!/usr/bin/env bash
# ============================================================================
# env-secrets.sh — declarative registry of auto-generated .env secrets, plus an
# idempotent, forward-only reconciler shared by install.sh (fresh install) and
# taranac-update.sh (upgrade).
#
# Why a registry instead of per-version steps: adding a generated secret in a
# future release is ONE line in MANAGED_SECRETS below, and the reconciler
# backfills it on ANY upgrade path — 1.1.2 → 1.3.5 in a single jump lands every
# intervening secret in one pass. Secret *additions commute* (there is no order
# to replay, only a target set to converge to), so an idempotent "ensure present"
# pass is the correct, skip-safe analogue of an Alembic upgrade for the .env.
#
# Existing keys are NEVER touched — regenerating MASTER_KEY (or any live secret)
# would brick every value already encrypted with it.
# ============================================================================

# Generator used by the registry. Guarded so sourcing this never clobbers a
# generator the caller (install.sh) already defined with the same name.
type gen_hex >/dev/null 2>&1 || gen_hex() { openssl rand -hex "${1:-32}"; }

# One line per managed generated secret:  KEY:generator-command
MANAGED_SECRETS=(
    "REPORTS_RENDERER_API_KEY:gen_hex 32"   # shared api↔renderer auth key (added 1.2.0)
)

# reconcile_env_secrets <env-file>
# Append every managed secret that is absent from <env-file>, generating its
# value. Idempotent and forward-only: a key already present (in any form —
# leading spaces or an `export` prefix) is left exactly as-is. Prints one line
# per addition through the caller's ok() if defined, else plain echo.
reconcile_env_secrets() {
    local env_file="$1" entry key gen
    [ -f "$env_file" ] || return 0
    for entry in "${MANAGED_SECRETS[@]}"; do
        key="${entry%%:*}"
        gen="${entry#*:}"
        if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$env_file"; then
            continue
        fi
        printf '%s=%s\n' "$key" "$($gen)" >> "$env_file"
        if type ok >/dev/null 2>&1; then
            ok "Added ${key} to .env (generated)"
        else
            echo "Added ${key} to .env (generated)"
        fi
    done
    return 0
}

# ── .env readability for the api container ──────────────────────────────────
# The api mounts this .env read-only at /app/host/env and puts it in the backup
# archive (it is the record of how the installation was configured). That process
# runs as uid/gid 999, while the .env is written under `umask 077` as the
# operator — so a 0600 operator-owned file is unreadable inside the container and
# every backup dies with EACCES before an archive is written.
#
# Nothing in the container can repair it: unlike /app/backups (a Docker volume the
# entrypoint chowns at boot), this is a read-only bind mount of a HOST file. The
# fix has to happen here, on the host.
#
# 0640 + group 999 grants exactly that one reader. 0644 is not an option — the
# file carries MASTER_KEY, the database password and the initial admin password.
TARANAC_CONTAINER_GID=999   # keep in sync with backend/Dockerfile (`groupadd -r -g 999 taranac`)

# secure_env_file <env-file>
# Best-effort, idempotent, never fatal. Changing a file's group needs root, and
# install.sh deliberately supports a non-root operator in the docker group, so a
# failure prints the one command to run rather than aborting the install. The
# backup itself stays functional either way: an unreadable .env degrades the
# archive (host_files reported missing + the backup:incomplete alert) instead of
# aborting it — see backend/app/modules/infra/backup/service.py::_add_host_files.
#
# Three attempts, because the common install shape is the one that needs all three:
# a non-root operator in the docker group whose sudo asks for a password. Plain
# chgrp covers root; `sudo -n` covers NOPASSWD; and an interactive run may prompt
# once — but only with a TTY and only after saying why, since an unexplained
# password prompt from an installer is how operators learn to distrust it. An
# unattended run (no TTY) never blocks: it drops straight to the warning.
secure_env_file() {
    local env_file="$1" secured=0 msg
    [ -f "$env_file" ] || return 0

    if chgrp "$TARANAC_CONTAINER_GID" "$env_file" 2>/dev/null; then
        secured=1
    elif command -v sudo >/dev/null 2>&1; then
        if sudo -n chgrp "$TARANAC_CONTAINER_GID" "$env_file" 2>/dev/null; then
            secured=1
        elif [ -t 0 ]; then
            if type info >/dev/null 2>&1; then
                info "Backups include .env, and the api container (gid ${TARANAC_CONTAINER_GID}) must be able to read it — sudo is needed once."
            fi
            sudo chgrp "$TARANAC_CONTAINER_GID" "$env_file" 2>/dev/null && secured=1
        fi
    fi

    if [ "$secured" = "1" ]; then
        # The operator still owns the file, so this needs no privileges of its own.
        chmod 640 "$env_file" 2>/dev/null || true
        if type ok >/dev/null 2>&1; then
            ok ".env is readable by the api container (group ${TARANAC_CONTAINER_GID}, mode 640)."
        fi
        return 0
    fi

    msg=".env could not be made readable by the api container — backups will not
   be able to include it (the archive is still written, with host_files reported
   missing). Run:  sudo chgrp ${TARANAC_CONTAINER_GID} '${env_file}' && sudo chmod 640 '${env_file}'"
    if type warn >/dev/null 2>&1; then
        warn "$msg"
    else
        echo "WARNING: $msg" >&2
    fi
    return 0
}
