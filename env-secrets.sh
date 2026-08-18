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

# ── Secrets that must be IDENTICAL on every node of a cluster ────────────────
# A generated value is the right answer for a node-local secret and the WRONG
# answer for a cluster-wide one. Two nodes that each generate their own
# PATRONI_REST_PASSWORD authenticate nothing to each other: every /switchover,
# /failover and /restart the cluster sends that node comes back 401, and it comes
# back 401 quietly — the node looks healthy right up to the failover that needs
# it. So a cluster-wide secret is DERIVED, not drawn.
#
# The derivation is an HMAC over MASTER_KEY, which every node of a cluster
# already shares by construction (it is distributed at join, wrapped, and is the
# one value that cannot differ between members). Same key + same label ⇒ same
# result on every node, with no coordination, no ordering and nothing new on the
# wire. The label keeps this value independent of any other one derived the same
# way, and MASTER_KEY itself is not weakened: SHA-256 does not run backwards.
#
# It is computed only when the key is ABSENT — an existing value is never
# recomputed, so a cluster that already has one (converted or joined by 1.2.3+)
# is untouched, and a later `./taranac rotate-key` cannot move it.
derive_cluster_secret() {  # <label> [hex-chars] → deterministic per MASTER_KEY
    local label="$1" width="${2:-48}" kek="" key_file=""
    # $env_file is the reconciler's local, visible here by bash's dynamic scope —
    # deliberate, so the registry below stays one line per secret.
    kek="$(_env_secret_value "${env_file:-}" MASTER_KEY)"
    if [ -z "${kek}" ]; then
        key_file="$(_env_secret_value "${env_file:-}" MASTER_KEY_FILE)"
        [ -n "${key_file}" ] && [ -r "${key_file}" ] && kek="$(tr -d '\r\n' < "${key_file}")"
    fi
    # No master key to derive from means this is not an installation yet, and a
    # random value is then both safe (there is no cluster to disagree with) and
    # correct (install.sh generates one at this point anyway).
    [ -n "${kek}" ] || { gen_hex $((width / 2)); return 0; }
    printf '%s' "taranac:${label}" \
        | openssl dgst -sha256 -mac HMAC -macopt "key:${kek}" -r 2>/dev/null \
        | cut -c1-"${width}"
}

_env_secret_value() {  # <env-file> <key> → raw value, or empty
    [ -n "${1:-}" ] && [ -f "$1" ] || return 0
    grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" 2>/dev/null \
        | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"'\r'
}

# One line per managed generated secret:  KEY:generator-command
MANAGED_SECRETS=(
    "REPORTS_RENDERER_API_KEY:gen_hex 32"   # shared api↔renderer auth key (added 1.2.0)
    # Patroni's control API credential. Authentication on 8008 became unconditional
    # in 1.2.3 — the postgres-ha entrypoint REFUSES to start without it — and every
    # path that creates a node has provisioned it since: install.sh on a fresh
    # install, ha-convert.sh on conversion, ha-join.sh on join. The path that was
    # missed is the one every EXISTING cluster takes: a cluster converted before
    # 1.2.3 carries no such key, and the upgrade used to hand it a database image
    # that will not start. The failure then surfaced three steps later, as a
    # container in a restart loop, instead of here where it is one line of .env.
    "PATRONI_REST_PASSWORD:derive_cluster_secret patroni-rest-api 48"
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

    # Already right? Then say nothing and ask for nothing.
    #
    # Checked FIRST because this runs on every update, and without it the
    # function reaches for `chgrp` even when the file is already exactly as it
    # should be — which on the common install shape (a non-root operator whose
    # sudo asks for a password) means a password prompt on every single update.
    # The message says "sudo is needed once", and it has to be true.
    if command -v stat >/dev/null 2>&1 \
       && [ "$(stat -c %g "$env_file" 2>/dev/null)" = "$TARANAC_CONTAINER_GID" ] \
       && [ "$(stat -c %a "$env_file" 2>/dev/null)" = "640" ]; then
        return 0
    fi

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
