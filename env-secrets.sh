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
