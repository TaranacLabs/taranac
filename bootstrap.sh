#!/usr/bin/env bash
# =============================================================================
# Taranac prerequisites bootstrap — installs Docker Engine + compose plugin and
# grants the invoking user access to the Docker socket.
#
# Run ONCE on a fresh host, with root:
#     sudo bash bootstrap.sh
#
# Idempotent: skips anything already present. After it adds you to the `docker`
# group you must start a new login shell (log out/in, or `newgrp docker`) for
# group membership to take effect — then run ./install.sh as your normal user.
# =============================================================================
set -euo pipefail

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_reset} $*"; }
ok()   { printf '%s\n' "${c_green}✓${c_reset} $*"; }
warn() { printf '%s\n' "${c_yellow}!${c_reset} $*"; }
die()  { printf '%s\n' "${c_red}✗ $*${c_reset}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash bootstrap.sh"

# The non-root user to grant Docker access to (the one who ran sudo).
TARGET_USER="${SUDO_USER:-root}"

# ── Docker Engine + compose plugin ───────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version)"
else
    info "Installing Docker Engine via get.docker.com ..."
    command -v curl >/dev/null 2>&1 || die "curl is required but missing."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
fi

if docker compose version >/dev/null 2>&1; then
    ok "Compose plugin present: $(docker compose version | head -1)"
else
    die "Docker is installed but the compose plugin is missing. Install 'docker-compose-plugin' for your distro and re-run."
fi

# ── Ensure the engine is enabled + running ───────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable/start docker via systemd — start it manually if needed."
fi

# ── Grant the user Docker socket access ──────────────────────────────
# Track whether we just added the user this run — if so, THIS shell (and any shell the
# user already has open) cannot use Docker until they start a new login session. That is
# the single most-missed step, so we shout about it in a box at the very end.
NEEDS_RELOGIN=0
if [ "${TARGET_USER}" != "root" ]; then
    if id -nG "${TARGET_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        ok "User '${TARGET_USER}' already in the docker group."
    else
        usermod -aG docker "${TARGET_USER}"
        ok "Added '${TARGET_USER}' to the docker group."
        NEEDS_RELOGIN=1
    fi
fi

# ── openssl (needed by install.sh for secret generation) ─────────────
command -v openssl >/dev/null 2>&1 && ok "openssl present." || warn "openssl missing — install it (apt-get install -y openssl) before ./install.sh."

echo
ok "Prerequisites ready."
echo

if [ "${NEEDS_RELOGIN}" -eq 1 ]; then
    printf '%s\n' "${c_yellow}${c_bold}╔══════════════════════════════════════════════════════════════════╗${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║  ⚠  ONE MORE STEP — YOU ARE NOT DONE YET                          ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}╠══════════════════════════════════════════════════════════════════╣${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║  You were just added to the 'docker' group, but THIS terminal     ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║  cannot use Docker until you start a NEW login session.           ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║                                                                  ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║  Do ONE of these, THEN run  ./install.sh :                        ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║     • log out and log back in, or                                ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║     • run:   newgrp docker                                        ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║                                                                  ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}║  If you skip this, ./install.sh will stop and remind you again.   ║${c_reset}"
    printf '%s\n' "${c_yellow}${c_bold}╚══════════════════════════════════════════════════════════════════╝${c_reset}"
else
    ok "Next:  cd into the bundle and run ./install.sh"
fi
