#!/usr/bin/env bash
# =============================================================================
# Taranac self-update — refreshes BOTH the container images AND the bundle files
# (this wrapper, docker-compose.yml, install.sh, docs, .env.example).
#
# `docker compose pull` only updates images; new operator-facing features often
# also change the bundle scripts/compose, so an image-only upgrade silently
# leaves them stale. This tool closes that gap.
#
#   ./taranac version            # show current version + check for a newer one
#   ./taranac update             # update to the latest published version
#   ./taranac update --version X # update to a specific version
#   ./taranac update --from F    # update from a local bundle tarball (air-gapped)
#   ./taranac update --check     # report only; change nothing
#   ./taranac update --keep-images  # do not remove the superseded image versions
#
# After a successful update the superseded Taranac images are removed, keeping the
# installed version and the one before it (the rollback target). Only images under this
# install's IMAGE_PREFIX are ever considered — never anything else on the host.
#
# Air-gapped / protected environments: a failed online check is a NOTICE, not an
# error — normal operation never reaches the network, only `version`/`update`
# do. To update offline, copy taranac-bundle-<ver>.tar.gz onto the host and run
# `./taranac update --from taranac-bundle-<ver>.tar.gz` (then `docker load` any
# saved images, or point IMAGE_PREFIX at a reachable mirror).
# =============================================================================
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${BUNDLE_DIR}/.env"
VERSION_FILE="${BUNDLE_DIR}/VERSION"
# NOTE: the compose -f arguments are computed per-action by ha_compose_files (it
# merges the HA overlay under HA), so there is no single fixed COMPOSE_FILE here.

# Override points (kept as env so tests and mirrors can redirect them).
GITHUB_REPO="${TARANAC_GITHUB_REPO:-taranaclabs/taranac}"
RELEASE_LATEST_API="${TARANAC_RELEASE_API:-https://api.github.com/repos/${GITHUB_REPO}/releases/latest}"
RELEASE_DL_BASE="${TARANAC_RELEASE_DL_BASE:-https://github.com/${GITHUB_REPO}/releases/download}"
CURL_TIMEOUT="${TARANAC_CURL_TIMEOUT:-6}"

# The updater refreshes EVERYTHING the fresh bundle carries and protects only the few
# operator-owned paths below. This is a blocklist, not an allowlist, on purpose: a
# hand-maintained "framework files" allowlist silently DROPS every newly-shipped file
# an operator never asked to keep stale (#29 — e.g. ha-etcd-ca.sh, added in a later
# release, was invisible to the old list). The set of framework files is defined in
# exactly one place — the bundle's own contents (deploy/build-bundle.sh) — and the
# updater derives from that, so the two can never drift.
#
# Operator-owned — NEVER overwritten or removed by an update (state, not framework):
#   .env      the real environment (the bundle ships .env.example, never .env).
#   config/   operator secrets + TLS material: certs, Firebase key, and — under HA —
#             the etcd CA (config/etcd-ca), this node's leaf (config/etcd-tls) and the
#             cluster secret set (config/cluster-secrets). The bundle ships an EMPTY
#             config/ placeholder; blindly copying it would WIPE all of the above.
# Docker volumes (pg_data, etc.) live outside the bundle dir and are never touched.
OPERATOR_OWNED=(
    .env
    config
)

# 0 = this bundle entry is operator-owned (skip it); 1 = framework (refresh it).
is_operator_owned() {  # $1 = basename of a top-level bundle entry
    local p
    for p in "${OPERATOR_OWNED[@]}"; do [ "$1" = "${p}" ] && return 0; done
    case "$1" in .taranac-backup-*) return 0 ;; esac   # our own rollback backups
    return 1
}

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
info()   { printf '%s\n' "${c_bold}==>${c_reset} $*"; }
ok()     { printf '%s\n' "${c_green}✓${c_reset} $*"; }
warn()   { printf '%s\n' "${c_yellow}!${c_reset} $*"; }
notice() { printf '%s\n' "${c_dim}· $*${c_reset}"; }
die()    { printf '%s\n' "${c_red}✗ $*${c_reset}" >&2; exit 1; }

# ── HA overlay awareness (split-brain guard) ─────────────────────────
# Under HA the database is Patroni-managed via docker-compose.ha.yml (applied on top
# of the base compose). `pull`/`up -d` on the BASE compose alone would start a plain
# `postgres` on the Patroni-managed data dir — on the primary a 2nd writable
# standalone → split-brain / data loss, from a routine `./taranac update`. So when HA
# is configured we ALWAYS merge the overlay for the bundle at $1. update always
# (re)starts containers, so a missing overlay under HA is a hard refusal — never
# base-only. Sets COMPOSE_FILES (full paths) + HA_ACTIVE.
#
# Detection (ha.md §13 A) fails TOWARD the overlay: the explicit TARANAC_HA=1 marker
# (written by ha-convert.sh / ha-join.sh) is authoritative; ANY uncommented non-empty
# DB_HOSTS is the defense-in-depth fallback (robust to `export `/spaces/quotes; the
# value is never parsed). Mirrors the helper in ./taranac (kept self-contained).
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

ha_compose_files() {
    local dir="$1"
    COMPOSE_FILES=(-f "${dir}/docker-compose.yml")
    HA_ACTIVE=0
    ha_is_configured "${dir}/.env" || return 0    # standalone → base compose only
    [ -f "${dir}/docker-compose.ha.yml" ] || die "HA is configured in .env but docker-compose.ha.yml is missing in ${dir} — refusing to pull/restart on the base compose alone (under HA that starts a 2nd writable Postgres on the Patroni data dir → split-brain). Update --from a full bundle tarball that ships the HA overlay."
    COMPOSE_FILES=(-f "${dir}/docker-compose.yml" -f "${dir}/docker-compose.ha.yml")
    HA_ACTIVE=1
}

# ── Read one value out of a .env ─────────────────────────────────────────────
# Trailing whitespace/CR and surrounding quotes are stripped: .env is hand-edited
# on real installs and a CRLF file copied from Windows is not exotic. Every read
# goes through here, because a value that silently carries a \r compares equal to
# nothing — and the comparisons it feeds decide what gets DELETED below.
env_value() {  # $1 = env file, $2 = key
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -1 \
        | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# ── Which kind of host is this? (one bundle installs three) ──────────────────
# The same tarball is unpacked on a full product node, on an HA WITNESS (etcd arbiter,
# set up by witness-join.sh) and on a standalone NCM COLLECTOR (collector-join.sh) —
# that is how those hosts get their own scripts. So `./taranac update` exists on all
# three, and it used to run the PRODUCT's update on every one of them: pull + `up -d`
# against docker-compose.yml, plus edits to a .env that belongs to a different stack.
#
# On a witness that is not a no-op, it is the entire product trying to start on the
# arbiter. Observed on a customer's witness (1.2.3 → 1.2.6): the witness .env carries
# none of the product's variables, so compose interpolated an empty IMAGE_PREFIX and
# TARANAC_VERSION and died on `unable to get image '/radius:'`, after two dozen
# "variable is not set" warnings. The crash was luck. An .env that DID carry those two
# keys would instead have started Postgres, the API and the AAA daemons on a node whose
# entire purpose is to be cheap to lose — and taken its .env with it.
#
# Detection uses POSITIVE signals only and fails TOWARD the product, because "product"
# is what every earlier release did unconditionally: a host we cannot classify keeps
# exactly the old behaviour, and only a host that positively looks like a satellite
# gets the new one.

# Is a key present AND non-empty? (tolerates `export `, spaces and quotes; the value
# itself is never parsed — only its existence decides.)
env_has_value() {  # $1 = env file, $2 = ERE alternation of key names
    [ -f "$1" ] || return 1
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?($2)[[:space:]]*=[[:space:]]*\"?[^\"[:space:]#]" "$1"
}

# A product node's .env always carries at least one of these. A witness .env carries
# none of them by construction: witness-join.sh deliberately writes NO cluster
# credentials, because an arbiter that cannot decrypt anything is one you can afford
# to lose. IMAGE_PREFIX is in the list as the weakest signal — a witness has no
# product images to name, so its presence still means "the stack lives here".
install_is_product() {  # $1 = env file
    env_has_value "$1" 'SECRET_KEY|MASTER_KEY|MASTER_KEY_FILE|POSTGRES_PASSWORD|IMAGE_PREFIX'
}

install_is_witness() {  # $1 = env file
    local env="$1"
    if install_is_product "${env}"; then return 1; fi
    # 1.2.7+ marker written by witness-join.sh — unforgeable, nothing to mis-parse.
    if [ "$(env_value "${env}" TARANAC_ROLE)" = "witness" ]; then return 0; fi
    # Witnesses joined by an earlier release have no marker; their .env is still
    # unmistakable — it is written whole from the compose file's variable list.
    if env_has_value "${env}" 'ETCD_NAME' && env_has_value "${env}" 'ETCD_INITIAL_CLUSTER'; then return 0; fi
    # Last resort for a hand-rolled or unreadable .env: ask the daemon. A witness runs
    # the arbiter's etcd and NO database — the pair is what makes the answer safe.
    if docker inspect taranac-witness-etcd >/dev/null 2>&1 && ! docker inspect taranac-db >/dev/null 2>&1; then return 0; fi
    return 1
}

# The collector keeps its own env files and its own compose file, written by
# collector-join.sh — it never shares the product's .env, so it can (and here does)
# coexist with a witness on the same host.
install_has_collector() {  # $1 = bundle dir
    [ -f "$1/collector.env" ] && [ -f "$1/docker-compose.collector.yml" ]
}

# ── Reclaim disk: drop image versions we no longer need ──────────────────────
# `docker compose pull` + `up -d` NEVER removes the images it supersedes, so every
# update left a full set on disk forever: ~4.5 GB per release across the 10 service
# images. Thirteen releases = 30 GB of dead weight — enough to fill an OVA appliance's
# disk and take the stack down, months after the update that caused it, with nothing
# pointing back at the cause.
#
# What this deliberately does NOT do is `docker system/image prune -a`. The host may
# run containers that are not ours; a blanket prune would delete their images too, and
# an updater has no business touching software it did not install. So we enumerate only
# ${IMAGE_PREFIX}/* and remove tags by name.
#
# Kept: the version just installed AND the one before it — the rollback path this very
# script advertises ("restore files from ${backup}") is worthless if the previous
# images are gone and the registry is unreachable.
#
# Safety: `docker rmi <tag>` refuses to delete an image any container still references
# (running or stopped), so a live collector/portal/HA peer on another version survives
# on its own. Every failure is non-fatal — the stack is already updated and healthy by
# the time we get here, and an un-reclaimed gigabyte must never turn a good update bad.
prune_old_images() {  # $1 = env file, $2 = version just installed, $3 = previous version
    local env_file="$1" keep_new="$2" keep_old="$3"
    local prefix="" tag stale=()

    prefix="$(env_value "${env_file}" IMAGE_PREFIX)"
    # No prefix pinned (hand-rolled .env, mirror set only in the environment) → we
    # cannot tell our images from anyone else's, so we remove nothing at all.
    [ -n "${prefix}" ] || { notice "IMAGE_PREFIX is not set in .env — skipping image cleanup."; return 0; }
    [ -n "${keep_new}" ] || return 0

    while IFS= read -r tag; do
        case "${tag}" in
            "${prefix}/"*) ;;                       # ours
            *) continue ;;                          # someone else's — never touch
        esac
        case "${tag}" in
            *:"${keep_new}"|*:"${keep_old}") continue ;;   # current + rollback target
            *:'<none>') continue ;;                        # untagged; not ours to judge
        esac
        stale+=("${tag}")
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)

    [ "${#stale[@]}" -gt 0 ] || return 0

    info "Removing superseded images (keeping ${keep_new}${keep_old:+ and ${keep_old}}) ..."
    local removed=0
    for tag in "${stale[@]}"; do
        if docker rmi "${tag}" >/dev/null 2>&1; then
            removed=$((removed + 1))
        fi
    done
    if [ "${removed}" -gt 0 ]; then
        ok "Reclaimed disk from ${removed} superseded image tag(s)."
    else
        notice "No superseded images could be removed (all still in use) — nothing to reclaim."
    fi
    local skipped=$(( ${#stale[@]} - removed ))
    [ "${skipped}" -gt 0 ] && notice "${skipped} tag(s) left in place — still referenced by a container."
    return 0
}

# ── Belt-and-suspenders: re-resolve the reverse-proxy upstreams (#19a) ───────
# `docker compose up -d` recreates only containers whose own image/config changed.
# When the api (or frontend) image is bumped, that container gets a NEW docker-network
# IP — but the edge/frontend nginx in front of it did NOT change, so its worker keeps
# the upstream's OLD IP and every request 502s until the proxy is recreated (a plain
# `restart` re-runs the same workers and does NOT help — only a recreate does). The
# baked nginx now re-resolves upstreams through the Docker DNS resolver (edge +
# frontend templates), which fixes this in steady state — but an operator upgrading
# FROM an older, pre-resolver image would still hit the stale-IP 502 on the very first
# update. Force-recreating the two stateless proxy containers after up -d closes that
# gap regardless of image vintage; --no-deps keeps it from cascading into api/postgres.
refresh_proxy_dns() {
    local env_file="$1"
    info "Re-resolving reverse-proxy upstreams (edge, frontend) ..."
    docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" \
        up -d --force-recreate --no-deps edge frontend \
        || warn "Could not recreate edge/frontend. If you see 502s after this update, run: ./taranac up -d --force-recreate --no-deps edge frontend"
}

# Is THIS node the cluster primary (Patroni leader)? Best-effort, node-local: ask the
# local Postgres directly — pg_is_in_recovery()=false ⇒ primary/leader. No etcd/quorum
# call (matches am_i_leader in the app + the sibling ha scripts). Any error (db down, not
# up yet, wrong creds) ⇒ "unknown" so we degrade to the generic guidance, never suppress
# it. Echoes exactly one of: leader | replica | unknown.
node_role() {
    local out
    out="$(docker exec taranac-db psql -U taranac -d taranac -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '[:space:]')" || out=""
    case "${out}" in
        f) echo leader ;;
        t) echo replica ;;
        *) echo unknown ;;
    esac
}

# Remind the operator of the one-node-at-a-time discipline when restarting an HA node,
# and — leader-aware (#21) — call out when THIS node is the primary so it is updated LAST.
ha_upgrade_notice() {
    [ "${HA_ACTIVE:-0}" = "1" ] || return 0
    echo
    warn "HA node — the database comes up under the Patroni overlay."
    notice "Upgrade ONE node at a time: replicas FIRST, the primary LAST (recreating the"
    notice "primary's container triggers a failover). Back up first. (HA.md §6 / ha.md §6)"
    local role; role="$(node_role)"
    case "${role}" in
        leader)
            echo
            warn "THIS node is the cluster PRIMARY (Patroni leader)."
            notice "Update every REPLICA node FIRST and this primary LAST. Restarting the primary"
            notice "here triggers a failover; doing it before the replicas are on the new version"
            notice "can strand the cluster split across versions. If the replicas are not updated"
            notice "yet, Ctrl-C now and update them first." ;;
        replica)
            notice "This node is a REPLICA — safe to update ahead of the primary." ;;
        *)
            notice "(Could not determine whether this node is primary or replica — check"
            notice " './taranac cluster status' and update the primary last.)" ;;
    esac
    echo
}

# ── Version helpers ──────────────────────────────────────────────────
current_version() {
    # The deployed version is whatever .env pins; fall back to the bundle VERSION.
    local v=""
    v="$(env_value "${ENV_FILE}" TARANAC_VERSION)"
    [ -z "${v}" ] && [ -f "${VERSION_FILE}" ] && v="$(head -1 "${VERSION_FILE}")"
    printf '%s' "${v:-unknown}"
}

# Fetch the latest published version tag, or empty on any failure (offline-safe).
fetch_latest_version() {
    local json
    json="$(curl -fsS --max-time "${CURL_TIMEOUT}" "${RELEASE_LATEST_API}" 2>/dev/null)" || return 1
    # Parse "tag_name": "v1.2.3" without requiring jq, then strip the leading v.
    printf '%s' "${json}" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/'
}

# ── `version` / `--check` ────────────────────────────────────────────
cmd_check() {
    local cur latest
    cur="$(current_version)"
    info "Installed version: ${c_bold}${cur}${c_reset}"
    if ! latest="$(fetch_latest_version)" || [ -z "${latest}" ]; then
        notice "Could not check for updates (offline or restricted network) — this is not an error."
        notice "To update without internet: ./taranac update --from taranac-bundle-<ver>.tar.gz"
        return 0
    fi
    if [ "${latest}" = "${cur}" ]; then
        ok "Up to date (${cur})."
    else
        warn "A different version is available: ${c_bold}${latest}${c_reset} (installed: ${cur})."
        printf '%s\n' "    Update with:  ${c_bold}./taranac update${c_reset}"
    fi
}

# ── Download + verify a bundle tarball for a target version ──────────
# Echoes the path to the verified tarball on stdout.
# Return codes (so the caller can tell "can't reach it" from "it's tampered"):
#   0 = bundle downloaded (and checksum verified, if SHA256SUMS was published)
#   2 = bundle UNREACHABLE (404 / offline / blocked network) — the caller ABORTS.
#       There is no degraded "images-only" mode: see cmd_update.
#   1 = checksum MISMATCH — hard failure; caller MUST abort (never mask tampering).
# On success the tarball is at ${workdir}/taranac-bundle-${ver}.tar.gz.
download_bundle() {
    local ver="$1" workdir="$2"
    local tarball="taranac-bundle-${ver}.tar.gz"
    local out="${workdir}/${tarball}"
    info "Downloading ${tarball} ..." >&2
    # --retry rides out transient CDN hiccups (a single slow/dropped request would
    # otherwise abort the whole update — and skip checksum verification below).
    if ! curl -fSL --retry 3 --retry-delay 2 --max-time 120 -o "${out}" "${RELEASE_DL_BASE}/v${ver}/${tarball}" >&2; then
        warn "Could not download ${tarball} (offline, private-repo asset, or blocked network)." >&2
        if [ -n "${SUDO_USER:-}" ]; then
            warn "  You ran under 'sudo', which drops your shell environment — including any" >&2
            warn "  http_proxy/https_proxy your user relies on. If this host reaches the internet" >&2
            warn "  through a proxy, retry with 'sudo -E ./taranac update' (keeps your environment)," >&2
            warn "  or run WITHOUT sudo — docker-group membership is enough to update." >&2
        fi
        return 2
    fi
    # Verify against SHA256SUMS when published (skip gracefully if absent).
    if curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -o "${workdir}/SHA256SUMS" "${RELEASE_DL_BASE}/v${ver}/SHA256SUMS" 2>/dev/null; then
        ( cd "${workdir}" && grep " ${tarball}\$" SHA256SUMS | sha256sum -c - >&2 ) \
            || return 1
        ok "Checksum verified." >&2
    else
        warn "No SHA256SUMS published for v${ver} — skipping checksum verification." >&2
    fi
    return 0
}

# ── A witness after the file refresh: nothing to pull, something to know ─────
# The witness runs ONE container, from a pinned upstream image (quay.io/coreos/etcd)
# that a Taranac release never changes. So there is no image to pull and no restart to
# perform — and we must not invent one: recreating the arbiter's etcd is a quorum
# event, and doing it silently inside a routine update is how a two-node cluster loses
# its majority to housekeeping. What CAN change between releases is the witness compose
# file, so we compare the copy we just replaced with the one we installed and hand the
# operator the exact command, to run deliberately on a cluster they have checked.
witness_post_update() {  # $1 = dest bundle dir, $2 = backup dir
    local dest="$1" backup="$2"
    echo
    info "This host is an HA ${c_bold}WITNESS${c_reset} — an etcd arbiter, not a Taranac node."
    notice "Refreshed the bundle's files only (witness-join.sh, the witness compose file,"
    notice "diagnose.sh, HA.md). Your .env was neither read for settings nor edited — a"
    notice "witness holds none of the product's — and no product container was started here."
    notice "Its etcd runs a pinned upstream image, so a release brings nothing to pull."
    if [ -f "${backup}/docker-compose.witness.yml" ] \
       && ! cmp -s "${backup}/docker-compose.witness.yml" "${dest}/docker-compose.witness.yml"; then
        echo
        warn "docker-compose.witness.yml CHANGED in this version. Apply it deliberately:"
        printf '%s\n' "      docker compose --env-file .env -f docker-compose.witness.yml up -d"
        notice "That recreates this arbiter's etcd. Do it only while the cluster is healthy"
        notice "('./taranac cluster status' on a DB node), and never together with a DB node."
    else
        notice "docker-compose.witness.yml is unchanged in this version — nothing to apply."
    fi
}

# ── A collector after the file refresh: its version follows the CORE ─────────
# A standalone NCM collector must run the version ITS CORE runs — so "update to the
# newest release" is precisely wrong whenever the core is a release behind, which is
# the normal state of affairs while an operator upgrades one host at a time.
# collector-join.sh --update is the tool that knows this (it asks the core, and rolls
# the collector back if the new container fails to attach), so we never touch the
# collector's containers from here: we say so, and point at it.
collector_post_update() {
    echo
    info "This host also runs a standalone NCM ${c_bold}collector${c_reset}."
    notice "Its container was NOT touched: a collector must match the version its CORE runs,"
    notice "which is not necessarily this bundle's. Its own tool resolves that from the core:"
    printf '%s\n' "      ./collector-join.sh --status          # what it is doing, locally"
    printf '%s\n' "      ./collector-join.sh --update --check  # is it behind its core?"
    printf '%s\n' "      ./collector-join.sh --update          # move it to the core's version"
}

# ── Apply an extracted bundle over the current one (runs from temp) ───
# Invoked as a fresh process from the NEW updater. Because this process executes
# from the temp extract dir, overwriting the installed bundle's own
# taranac-update.sh while it runs is safe. `dest` is the REAL installed bundle
# dir, passed explicitly — it must never be confused with `src` (the extract).
cmd_apply() {
    local src="$1" dest="$2" target_ver="$3" do_restart="$4" do_prune="${5:-1}"
    [ -d "${src}" ] || die "internal: extracted bundle dir not found: ${src}"
    [ -d "${dest}" ] || die "internal: target bundle dir not found: ${dest}"
    local env_file="${dest}/.env"

    # The version being REPLACED — read now, while .env still holds it (the pin below
    # overwrites it). Kept on disk as the rollback target by prune_old_images. Read from
    # ${dest} explicitly, never via current_version(): we re-exec from the temp extract,
    # so the global ENV_FILE points at the tarball, not at the real install.
    local prev_ver=""
    prev_ver="$(env_value "${env_file}" TARANAC_VERSION)"

    local stamp backup
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
    backup="${dest}/.taranac-backup-${stamp}"
    mkdir -p "${backup}"

    # Enumerate what the FRESH bundle carries (every top-level entry, dotfiles too:
    # .env.example, .gitignore) and refresh all of it except operator-owned paths.
    # `[ -e ]` makes the globs nullglob-safe if a pattern matches nothing.
    info "Backing up current bundle files → ${backup}"
    local entry name
    for entry in "${src}"/* "${src}"/.[!.]*; do
        [ -e "${entry}" ] || continue
        name="$(basename "${entry}")"
        is_operator_owned "${name}" && continue
        [ -e "${dest}/${name}" ] && cp -a "${dest}/${name}" "${backup}/" || true
    done

    info "Updating bundle files (operator .env and config/ are left untouched)"
    for entry in "${src}"/* "${src}"/.[!.]*; do
        [ -e "${entry}" ] || continue
        name="$(basename "${entry}")"
        is_operator_owned "${name}" && continue
        rm -rf "${dest:?}/${name}"
        cp -a "${entry}" "${dest}/${name}"
    done
    # Restore exec bits by glob, not a hand list — a newly-shipped *.sh must never come
    # up non-executable just because someone forgot to add it here. `taranac` (the
    # extensionless wrapper) is the one non-.sh entrypoint, so name it explicitly.
    chmod +x "${dest}/taranac" 2>/dev/null || true
    chmod +x "${dest}"/*.sh 2>/dev/null || true
    ok "Bundle files updated."

    # ── Satellite hosts are done here ────────────────────────────────────────
    # Everything below this point is the PRODUCT's update: it reads and rewrites the
    # product's .env and drives docker-compose.yml. A witness and a standalone
    # collector own neither, so on those hosts refreshing the files IS the whole
    # update — and running the rest would start a stack that was never meant to live
    # there (see install_is_witness above for what that cost a customer).
    if install_is_witness "${env_file}"; then
        witness_post_update "${dest}" "${backup}"
        if install_has_collector "${dest}"; then collector_post_update; fi
        echo
        ok "Update complete → ${target_ver:-unknown}"
        notice "Rollback if needed: restore files from ${backup}"
        return 0
    fi
    if install_has_collector "${dest}" && ! install_is_product "${env_file}"; then
        collector_post_update
        echo
        ok "Update complete → ${target_ver:-unknown}"
        notice "Rollback if needed: restore files from ${backup}"
        return 0
    fi

    # Backfill any auto-generated secret introduced since the operator's current
    # version — idempotent and forward-only, sourced from the freshly-extracted
    # bundle, so a multi-version jump (e.g. 1.1.2 → 1.3.5) lands every intervening
    # secret in one pass. cmd_update re-execs THIS (new) updater, so the registry
    # that runs is the target version's. Existing keys are never touched.
    # shellcheck source=/dev/null
    [ -f "${src}/env-secrets.sh" ] && . "${src}/env-secrets.sh" && reconcile_env_secrets "${env_file}"

    # Surface any remaining new .env settings (non-secret, compose-defaulted) —
    # never edits the operator's .env silently.
    report_new_env_keys "${src}/.env.example" "${env_file}"

    # Bump the pinned image tag in .env so `pull` fetches the new version. This
    # is the ONE version knob — the app's reported version is baked into the
    # images (from VERSION at build) and is never carried in .env.
    if [ -n "${target_ver}" ] && [ -f "${env_file}" ]; then
        # NOT `sed -i`: that writes a new file and renames it over this one, so
        # the .env comes out with a fresh inode owned by the operator's primary
        # group — losing the group 999 that lets the api container read it. A
        # non-root operator cannot put that group back, so every single update
        # asked for a sudo password, under a message promising it was needed
        # once. Writing THROUGH the existing file keeps its inode, and with it
        # the ownership and mode, so the group survives and the prompt is
        # genuinely one-time.
        _pin_tmp="$(mktemp "${env_file}.XXXXXX")" || _pin_tmp=""
        if [ -n "${_pin_tmp}" ]; then
            chmod 600 "${_pin_tmp}"
            if sed -E "s/^TARANAC_VERSION=.*/TARANAC_VERSION=${target_ver}/" "${env_file}" > "${_pin_tmp}" \
               && grep -q "^TARANAC_VERSION=${target_ver}$" "${_pin_tmp}"; then
                # Only now, with a complete and verified replacement in hand:
                # `>` truncates, and a failure here would leave the operator
                # with a half-written .env.
                cat "${_pin_tmp}" > "${env_file}"
                ok "Pinned TARANAC_VERSION=${target_ver} in .env"
            else
                warn "Could not pin TARANAC_VERSION in .env — it is unchanged. Set it by hand: TARANAC_VERSION=${target_ver}"
            fi
            rm -f "${_pin_tmp}"
        else
            sed -i -E "s/^TARANAC_VERSION=.*/TARANAC_VERSION=${target_ver}/" "${env_file}"
            ok "Pinned TARANAC_VERSION=${target_ver} in .env"
        fi
    fi

    # Make .env readable by the api container (uid 999) — installs made before
    # 1.2.3 left it 0600 operator-owned, and every backup on them dies with
    # EACCES on /app/host/env. THIS is what repairs them: customers update with
    # `pull` + `up -d` and never re-run install.sh, exactly as the /app/backups
    # volume in 1.1.3 could only be repaired at runtime, not by a new image.
    # Runs LAST of the .env edits on purpose: `sed -i` above replaces the file
    # (rename), and a non-root operator cannot restore a group it is not in — so
    # any earlier fix-up would be silently undone right here.
    type secure_env_file >/dev/null 2>&1 && secure_env_file "${env_file}"

    if [ "${do_restart}" = "1" ]; then
        ha_compose_files "${dest}"                 # merges the just-refreshed HA overlay under HA
        ha_upgrade_notice
        info "Pulling images and restarting (migrations run automatically on api start) ..."
        docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" pull
        docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d
        refresh_proxy_dns "${env_file}"
        ok "Stack updated."
        # LAST, and only once the stack is up: reclaiming disk is housekeeping, and
        # housekeeping must never be in a position to fail an update that worked.
        if [ "${do_prune}" = "1" ]; then
            prune_old_images "${env_file}" "${target_ver}" "${prev_ver}" || true
        else
            notice "Kept superseded images (--keep-images)."
        fi
    else
        notice "Skipped image pull / restart (--no-restart). Apply later with: ./taranac up -d"
    fi

    # A core host may also run a collector beside it — same rule as on a collector-only
    # host: its version follows the core, through its own tool, never from here.
    if install_has_collector "${dest}"; then collector_post_update; fi

    echo
    ok "Update complete → ${target_ver:-unknown}"
    notice "Rollback if needed: restore files from ${backup}"
}

# Compare keys present in the new .env.example against the operator's .env and
# list anything new, so the operator can opt into added settings.
report_new_env_keys() {
    local new_example="$1" env_file="$2"
    [ -f "${new_example}" ] || return 0
    [ -f "${env_file}" ] || return 0
    local keys_new keys_have missing
    keys_new="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${new_example}" | sort -u)"
    keys_have="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${env_file}" | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "${keys_new}") <(printf '%s\n' "${keys_have}") | sed 's/=$//')"
    if [ -n "${missing}" ]; then
        echo
        warn "New settings exist in this version's .env.example that your .env does not have:"
        printf '      %s\n' ${missing}
        notice "Defaults apply automatically; add them to .env only if you want non-defaults."
        notice "(e.g. TRUSTED_PROXY_HOPS=2 when the API sits behind two reverse proxies)."
        echo
    fi
}

# ── `update` orchestration ───────────────────────────────────────────
cmd_update() {
    local target="" from="" do_restart=1 assume_yes=0 check_only=0 do_prune=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) target="${2:-}"; shift 2 ;;
            --from)    from="${2:-}"; shift 2 ;;
            --no-restart) do_restart=0; shift ;;
            --keep-images) do_prune=0; shift ;;
            --yes|-y)  assume_yes=1; shift ;;
            --check)   check_only=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done

    if [ "${check_only}" = "1" ]; then
        cmd_check
        return 0
    fi

    command -v curl >/dev/null 2>&1 || [ -n "${from}" ] || die "curl is required for online updates (or use --from)."
    command -v tar  >/dev/null 2>&1 || die "tar is required."

    local workdir tarball
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${workdir}'" EXIT

    if [ -n "${from}" ]; then
        [ -f "${from}" ] || die "bundle tarball not found: ${from}"
        tarball="${from}"
        # Derive the version from the filename if not given explicitly.
        [ -z "${target}" ] && target="$(basename "${from}" | sed -E 's/^taranac-bundle-(.+)\.tar\.gz$/\1/')"
        info "Using local bundle: ${tarball} (version ${target:-unknown})"
    else
        if [ -z "${target}" ]; then
            target="$(fetch_latest_version)" || die "Could not reach the update server. Use --from for an offline update."
            [ -n "${target}" ] || die "Could not determine the latest version."
        fi
        local cur; cur="$(current_version)"
        if [ "${target}" = "${cur}" ] && [ "${assume_yes}" != "1" ]; then
            ok "Already on ${cur}. Nothing to do (use --version to force a specific version)."
            return 0
        fi
        info "Updating ${cur} → ${target}"
        local dlrc=0
        download_bundle "${target}" "${workdir}" || dlrc=$?
        if [ "${dlrc}" -eq 2 ]; then
            # No half-updates. A release is not only its images: the same fix can
            # live in docker-compose.yml (a mount removed, a volume dropped, a new
            # env key), and the images may DEPEND on that change. Pulling images
            # over a stale framework produces the worst possible outcome — an
            # update that reports success while the part that mattered never
            # landed, which is unfalsifiable from the operator's side. So an
            # unreachable bundle stops the update with nothing changed.
            echo
            die "Could not fetch the ${target} bundle — update ABORTED, nothing was changed.
  The bundle carries docker-compose.yml, the taranac wrapper, install.sh and the
  docs; a release may need them as much as the new images, so we never update one
  half of it. Check network/proxy access to GitHub releases and re-run
  ./taranac update, or fetch taranac-bundle-${target}.tar.gz on a machine that can
  reach it, copy it here and run:  ./taranac update --from taranac-bundle-${target}.tar.gz"
        elif [ "${dlrc}" -ne 0 ]; then
            die "Checksum verification FAILED — refusing to apply. Bundle left untouched."
        fi
        tarball="${workdir}/taranac-bundle-${target}.tar.gz"
    fi

    if [ "${assume_yes}" != "1" ]; then
        printf '%s' "Proceed with update to ${target:-this version}? [y/N] "
        read -r reply
        case "${reply}" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
    fi

    info "Extracting bundle ..."
    local extract="${workdir}/extract"
    mkdir -p "${extract}"
    tar -xzf "${tarball}" -C "${extract}"
    # Tarball may be flat or contain a single top-level dir — normalise.
    if [ ! -e "${extract}/taranac-update.sh" ]; then
        local inner; inner="$(find "${extract}" -maxdepth 2 -name taranac-update.sh -printf '%h\n' 2>/dev/null | head -1)"
        [ -n "${inner}" ] && extract="${inner}"
    fi
    [ -e "${extract}/taranac-update.sh" ] || die "bundle does not contain taranac-update.sh — wrong tarball?"

    # Re-exec the NEW updater to apply, so it never overwrites the file it is
    # currently executing. Pass src (extract), dest (this installed bundle), the
    # resolved version, and the restart flag through.
    # NOTE: the updater that runs cmd_apply is the NEW one, invoked by the OLD one — so
    # trailing arguments must stay optional on the receiving side. A pre-cleanup updater
    # passes only four; cmd_apply defaults do_prune to 1, which is what we want: the very
    # first update onto this version also clears whatever earlier releases piled up.
    exec bash "${extract}/taranac-update.sh" --apply-internal "${extract}" "${BUNDLE_DIR}" "${target}" "${do_restart}" "${do_prune}"
}

# ── Entry point ──────────────────────────────────────────────────────
case "${1:-}" in
    check|version) cmd_check ;;
    update)        shift; cmd_update "$@" ;;
    --apply-internal)  # internal: invoked by the freshly-extracted updater (src dest ver restart [prune])
        cmd_apply "$2" "$3" "$4" "$5" "${6:-1}" ;;
    *) die "usage: taranac-update.sh {version|update [--version X|--from FILE|--check|--no-restart|--keep-images|--yes]}" ;;
esac
