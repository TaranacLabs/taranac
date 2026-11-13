#!/usr/bin/env bash
# =============================================================================
# Taranac prerequisites bootstrap — installs Docker Engine + compose plugin and
# grants the invoking user access to the Docker socket.
#
# Run ONCE on a fresh host, with root:
#     sudo bash bootstrap.sh
#
# On a host without Docker and without /etc/docker/daemon.json it first writes one
# that starts Docker's default bridge (docker0) on 10.255.255.193/28, not on
# 172.17.0.0/16 — devices a site keeps in that range would never get an answer.
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

# What the stack needs from this host (host-checks.sh): asked below, once Docker is here.
HC_LOADED=""
# shellcheck source=host-checks.sh
if [ -f "$(dirname "${BASH_SOURCE[0]}")/host-checks.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/host-checks.sh"
    HC_LOADED=1
fi

# ── Docker Engine + compose plugin ───────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version)"
else
    command -v curl >/dev/null 2>&1 || die "curl is required but missing."
    # Docker's default bridge (docker0) takes 172.17.0.0/16 and routes it into itself,
    # so devices a site keeps in that range never get an answer. Taranac does not use
    # docker0: set before the first start, moving it restarts nothing.
    if [ -n "${HC_LOADED}" ]; then
        _rc=0; hc_docker0_bip_preset || _rc=$?
        case "${_rc}" in
            0) ok "Docker's default bridge docker0 will use ${HC_DOCKER0_BIP} (/etc/docker/daemon.json): 172.17.0.0/16 stays free for your network." ;;
            1) ok "/etc/docker/daemon.json is already there — left as it is." ;;
            *) warn "Could not write /etc/docker/daemon.json — docker0 keeps Docker's default 172.17.0.0/16." ;;
        esac
    fi
    info "Installing Docker Engine via get.docker.com ..."
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

# ── What the stack needs from this host (host-checks.sh) ─────────────
# Docker 28.0 or newer, and a kernel with IPv6. A Docker installed just now by
# get.docker.com is the current release and passes; one that was already here may
# not, and is refused with the way to update it — before anything else is changed.
if [ -n "${HC_LOADED}" ]; then
    hc_require bootstrap || exit 1
    _v="$(hc_docker_version)"
    ok "Docker ${_v:-(the daemon did not say its version)} and an IPv6-capable kernel."
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
