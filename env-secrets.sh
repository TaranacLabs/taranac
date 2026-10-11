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

# _container_chgrp [-R] <path>
# The privilege ladder, shared by every "make this readable by the api" helper.
# Changing a file's group needs root, and install.sh deliberately supports a
# non-root operator in the docker group, so a failure returns 1 and lets the
# caller print one actionable command instead of aborting the install.
#
# Three attempts, because the common install shape is the one that needs all
# three: a non-root operator in the docker group whose sudo asks for a password.
# Plain chgrp covers root; `sudo -n` covers NOPASSWD; and an interactive run may
# prompt once — but only with a TTY and only after saying why, since an
# unexplained password prompt from an installer is how operators learn to
# distrust it. An unattended run (no TTY) never blocks: it returns 1 straight
# away and the caller warns.
_container_chgrp() {
    local recurse="" path
    if [ "$1" = "-R" ]; then recurse="-R"; shift; fi
    path="$1"
    # shellcheck disable=SC2086  # $recurse is a controlled literal, never user input
    chgrp $recurse "$TARANAC_CONTAINER_GID" "$path" 2>/dev/null && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2086
    sudo -n chgrp $recurse "$TARANAC_CONTAINER_GID" "$path" 2>/dev/null && return 0
    [ -t 0 ] || return 1
    if type info >/dev/null 2>&1; then
        info "Backups must be able to read this file, and the api container runs as gid ${TARANAC_CONTAINER_GID} — sudo is needed once."
    fi
    # shellcheck disable=SC2086
    sudo chgrp $recurse "$TARANAC_CONTAINER_GID" "$path" 2>/dev/null
}

# secure_env_file <env-file>
# Best-effort, idempotent, never fatal. The backup itself stays functional either
# way: an unreadable .env degrades the archive (host_files reported missing + the
# incomplete-backup alert) instead of aborting it — see
# backend/app/modules/infra/backup/service.py::_add_host_files.
secure_env_file() {
    local env_file="$1" msg
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

    if _container_chgrp "$env_file"; then
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


# ── config/ material the backup archive carries ─────────────────────────────
# Same uid problem as .env, one directory over, and it stayed invisible far
# longer. `config/tls/tls.key`, `config/firebase/*.json` and `config/etcd-ca/ca.key`
# are written 0600 by their generators (`umask 077` in ha-etcd-ca.sh / ha-join.sh)
# or dropped 0600 by the operator, while `./config` is bind-mounted read-only into
# the api at /app/host/config so the backup can carry them.
#
# Found on a customer's 1.2.7 HA deployment (2026-08-23): HA.md promises the archive
# carries `config/etcd-ca` — the key that signs a joining node's certificate, and the
# reason losing one machine cannot leave a cluster unable to add or replace a node.
# It had never reached a single archive. Unlike .env, the miss was also SILENT:
# host_config is an opportunistic component, so no `missing` entry and no alert.
# The backend now reports every unreadable path; this is the half that stops it
# happening.
#
# Whole subdirectories, not a hand-listed set of filenames: the operator chooses
# what to drop in config/tls and config/firebase, and a list would only ever cover
# the names we happened to think of.
TARANAC_HOST_CONFIG_SUBDIRS="tls firebase etcd-ca"

# True iff <dir> holds anything other than the placeholders every bundle ships.
_host_config_has_content() {
    find "$1" -type f ! -name .gitkeep ! -name README.md -print -quit 2>/dev/null | grep -q .
}

# True iff something under <dir> is still out of reach for the container group.
_host_config_needs_fix() {
    find "$1" ! -gid "$TARANAC_CONTAINER_GID" -print -quit 2>/dev/null | grep -q . && return 0
    find "$1" -type f ! -perm -g=r -print -quit 2>/dev/null | grep -q . && return 0
    return 1
}

# secure_host_dir <dir> [label]
# Make ONE directory tree readable by the container group. Returns 1 if it could
# not (the caller decides whether that is worth a message). Idempotent and silent
# when the tree is already reachable — this runs on every update, and a helper
# that asks for sudo it does not need is a helper operators start bypassing.
#
# Called directly by ha-etcd-ca.sh and ha-join.sh at the moment the CA key is
# written, which is the only point where the right permissions cost nothing: the
# process is already standing over the file it just created.
secure_host_dir() {
    local dir="$1" label="${2:-$1}"
    [ -d "$dir" ] || return 0
    _host_config_has_content "$dir" || return 0
    _host_config_needs_fix "$dir" || return 0

    _container_chgrp -R "$dir" || return 1
    # g+rX, not a flat 640: capital X adds execute to DIRECTORIES only, so the
    # group can traverse the tree without any file becoming executable. Nothing
    # here widens beyond the group — a 0600 key becomes 0640, and a world-readable
    # certificate the operator chose to leave that way is not narrowed behind
    # their back.
    chmod -R g+rX "$dir" 2>/dev/null || true
    if type ok >/dev/null 2>&1; then
        ok "${label} is readable by the api container (group ${TARANAC_CONTAINER_GID}) — backups can carry it."
    fi
    return 0
}

# _etcd_tls_traversable <etcd-tls-dir>
# The leader's etcd ring check reads config/etcd-tls/ca.crt (0644) as uid 999
# through the read-only mount. A node that joined under umask 077/027 has the
# DIRECTORY at 0700/0750, which hides the certificate; ha-etcd-ca.sh fixes that
# only for sets it issues from now on, and nodes in the field never re-issue.
# Widens the directory alone (a+rx, the mode ha-etcd-ca.sh gives it): never -R,
# never a file — etcd-server.key inside stays 0600. Silent and never fatal: a
# directory this user does not own is left as it is, and the api then falls back
# to config/etcd-ca/ca.crt, the same CA.
_etcd_tls_traversable() {
    local dir="$1" mode
    [ -d "$dir" ] || return 0
    mode="$(stat -c %a "$dir" 2>/dev/null)" || return 0
    # Already r-x for others: nothing to do (and no chmod on every update).
    case "$mode" in *[57]) return 0 ;; esac
    chmod a+rx "$dir" 2>/dev/null || true
    return 0
}

# secure_host_config <config-dir>
# Best-effort, idempotent, never fatal — same contract as secure_env_file.
secure_host_config() {
    local config_dir="$1" name failed="" msg
    [ -d "$config_dir" ] || return 0

    for name in $TARANAC_HOST_CONFIG_SUBDIRS; do
        # An empty tls/ or firebase/ is the normal shape of an install with no
        # certificate and no Push MFA — secure_host_dir returns 0 without asking
        # for anything.
        secure_host_dir "${config_dir}/${name}" "config/${name}" || failed="${failed} config/${name}"
    done

    _etcd_tls_traversable "${config_dir}/etcd-tls"

    [ -n "$failed" ] || return 0

    # ONE message with ONE command, however many directories are involved: a
    # warning per file is how an installer teaches operators to scroll past it.
    msg="these files cannot be read by the api container, so backups will not carry them
   (the archive is still written, and the backup report names each file):${failed}
   Run:  sudo chgrp -R ${TARANAC_CONTAINER_GID}${failed// config\// ${config_dir}/} && sudo chmod -R g+rX${failed// config\// ${config_dir}/}"
    if type warn >/dev/null 2>&1; then
        warn "$msg"
    else
        echo "WARNING: $msg" >&2
    fi
    return 0
}
