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
#   ./taranac update --skip-image-verify  # a mirror that re-pushed the images (new digests)
#   ./taranac update --skip-space-check   # pull even if free disk looks too small
#
# The order of an update, and why (27.09.2026 — a pull that failed after the pin left
# a node whose files and .env said 1.3.0 while every container ran 1.2.8, and the
# re-run answered "Already on 1.3.0. Nothing to do"):
#   1. snapshot the images the containers run now → the backup dir (images-before.txt)
#   2. check free disk for the images that are not on this host yet
#   3. pull with TARANAC_VERSION=<target> in the ENVIRONMENT, from the NEW bundle's
#      compose files — .env still pins the old version, the files are still the old ones
#   4. compare every pulled image's digest with the list the release shipped (IMAGES.lock)
#   5. only then replace the bundle files and pin TARANAC_VERSION in .env
#   6. `up -d`, and report done only when every container runs the target images
# A failure in 2-4 changes nothing but downloaded layers; after 5 a re-run finishes the
# update, because "already on X" is decided by what the containers RUN, not by two labels.
#
# On an HA cluster two things wrap that sequence (cluster-versions.sh, HA.md §6):
#   0. before step 1, the navigator decides whether THIS member is the next one to
#      update — every replica, then the leader, then the witness — from the records
#      each member's updater wrote into etcd, and refuses with nothing written if not;
#   6. on a DB node `up -d` becomes: recreate everything, start the api, and either
#      finish here or hand the rest to the taranac-update-finisher container while the
#      api waits for the leader's schema. The node's own record is written last.
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
# The cluster navigator's helpers (HA only). Sourced from the bundle this updater
# runs from — on the --apply-internal hop that is the NEW release's extract.
# shellcheck source=cluster-versions.sh
[ -f "${BUNDLE_DIR}/cluster-versions.sh" ] && . "${BUNDLE_DIR}/cluster-versions.sh"
# The one command that continues THIS update, version included: a bare
# `./taranac update` means "the latest stable", which on a release candidate or a
# pinned version is another release (a downgrade, even). Every hint goes through here.
update_cmd() {  # <version or ""> → the command, printed
    if [ -n "${1:-}" ]; then printf './taranac update --version %s' "$1"; else printf './taranac update'; fi
}
type cv_update_cmd >/dev/null 2>&1 || cv_update_cmd() { update_cmd "$@"; }
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

ha_compose_files() {  # <dir holding the compose files> [<.env deciding HA; default <dir>/.env>]
    # The .env is a separate argument because the images are pulled from the NEW
    # bundle's compose files (still in the temp extract) while HA is a fact about
    # THIS node, which only the installed .env knows.
    local dir="$1" env="${2:-$1/.env}"
    COMPOSE_FILES=(-f "${dir}/docker-compose.yml")
    HA_ACTIVE=0
    ha_is_configured "${env}" || return 0    # standalone → base compose only
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

# A former witness: `witness-join.sh --leave` retired its .env as .env.left-<time>
# and took the arbiter down. No .env and such a file = this host serves no cluster.
HOST_LEFT_ENV=""
host_left_cluster() {  # [<bundle dir>]
    local dir="${1:-${BUNDLE_DIR}}"
    HOST_LEFT_ENV=""
    [ -f "${dir}/.env" ] && return 1
    HOST_LEFT_ENV="$(ls -1t "${dir}"/.env.left-* 2>/dev/null | head -1 || true)"
    [ -n "${HOST_LEFT_ENV}" ]
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

# ── What the stack runs, and what it is supposed to run ──────────────────────
# "Which version is this node on?" had two answers on disk — the bundle's VERSION and
# the pin in .env — and neither is what the containers run. After an update whose pull
# or `up -d` failed, both said the new version while every container ran the old one,
# and the updater believed the labels. These helpers ask the daemon instead.

# The image every service of a compose set resolves to, as `service<TAB>image`.
#
# TARANAC_VERSION goes into the ENVIRONMENT of the compose command, never into .env:
# compose interpolates from the process environment in preference to --env-file (checked
# on v2 and v5; test_update.sh runs it against the real compose when one is installed),
# so the pull can fetch the target while .env still pins the version that runs. Nothing
# depends on that silently — pull_new_images refuses when the rendered tags are not the
# target, which is what a compose that ignored the environment would produce.
#
# Parsed from `config`'s canonical output (two-space service keys, `image:` four spaces
# in), which is stable across compose versions and needs no jq or python on the host.
compose_service_images() {  # <env-file> <project-dir> <version or ""> <-f files…>
    local env_file="$1" pdir="$2" ver="$3"; shift 3
    local -a pre=(); [ -n "${ver}" ] && pre=("TARANAC_VERSION=${ver}")
    env ${pre[@]+"${pre[@]}"} docker compose --env-file "${env_file}" --project-directory "${pdir}" "$@" config 2>/dev/null \
        | awk '
            /^name:[[:space:]]/        { next }
            /^services:[[:space:]]*$/  { ins = 1; next }
            /^[^[:space:]#]/           { ins = 0 }
            ins && /^  [^[:space:]#][^:]*:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
            ins && /^    image:[[:space:]]/ {
                img = $0; sub(/^    image:[[:space:]]*/, "", img); gsub(/["'\'']/, "", img)
                if (svc != "" && img != "") print svc "\t" img
            }' || true
}

compose_project_name() {  # <env-file> <project-dir> <-f files…>
    local env_file="$1" pdir="$2"; shift 2
    docker compose --env-file "${env_file}" --project-directory "${pdir}" "$@" config 2>/dev/null \
        | awk '/^name:[[:space:]]/ { print $2; exit }' || true
}

# Every container compose made for a project (one-off `run` containers excluded), as
# `service<TAB>image-id<TAB>configured image<TAB>container name`. Stopped ones count: a
# stopped container on the old image is still the old version.
stack_containers() {  # <project> → rc 1 when the daemon did not answer
    local ids
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$1" \
                        --filter "label=com.docker.compose.oneoff=False" 2>/dev/null)" || return 1
    [ -n "${ids}" ] || return 0
    # shellcheck disable=SC2086  # one id per word, on purpose
    docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{.Image}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.Name}}' ${ids} 2>/dev/null || return 1
}

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

# Does the stack run <version>? 0 = every service's container(s) run exactly the image
# the compose files name for that version; 1 = not (STACK_DRIFT says which and why);
# 2 = cannot tell (STACK_DRIFT[0] says why). Services are what `config` lists for this
# node — the HA overlay's under HA, never on a standalone node — and a service with no
# container at all is not on the version: `up -d` creates one for every service.
STACK_DRIFT=()
stack_drift() {  # <bundle-dir> <env-file> <version>
    local dir="$1" env_file="$2" ver="$3" files project wanted containers
    STACK_DRIFT=()
    command -v docker >/dev/null 2>&1 || { STACK_DRIFT=("docker is not installed"); return 2; }
    # In a subshell: ha_compose_files dies on an HA node without its overlay, and here
    # that is an answer ("cannot tell"), not a reason to end the caller.
    files="$( (ha_compose_files "${dir}" "${env_file}" && printf '%s\n' "${COMPOSE_FILES[@]}") 2>/dev/null)" \
        || { STACK_DRIFT=("the HA overlay is missing"); return 2; }
    local -a fargs=(); local l
    while IFS= read -r l; do [ -n "${l}" ] && fargs+=("${l}"); done <<<"${files}"
    wanted="$(compose_service_images "${env_file}" "${dir}" "${ver}" "${fargs[@]}")"
    [ -n "${wanted}" ] || { STACK_DRIFT=("docker compose could not render ${dir}/docker-compose.yml"); return 2; }
    project="$(compose_project_name "${env_file}" "${dir}" "${fargs[@]}")"
    containers="$(stack_containers "${project}")" || { STACK_DRIFT=("the Docker daemon did not answer"); return 2; }

    local svc img want_id c_svc c_id c_img c_name found
    while IFS=$'\t' read -r svc img; do
        [ -n "${svc}" ] || continue
        want_id="$(image_id "${img}")"
        if [ -z "${want_id}" ]; then
            STACK_DRIFT+=("${svc}: ${img} is not on this host")
            continue
        fi
        found=0
        while IFS=$'\t' read -r c_svc c_id c_img c_name; do
            [ "${c_svc}" = "${svc}" ] || continue
            found=1
            [ "${c_id}" = "${want_id}" ] || STACK_DRIFT+=("${svc}: ${c_name#/} runs ${c_img}, not ${img}")
        done <<<"${containers}"
        [ "${found}" = 1 ] || STACK_DRIFT+=("${svc}: no container")
    done <<<"${wanted}"
    [ ${#STACK_DRIFT[@]} -eq 0 ] && return 0
    return 1
}

# ── 1. The rollback record: what runs NOW ────────────────────────────────────
# Per container: the image it was created from, that image's id and its registry
# digests. Written before anything is pulled, into the same backup directory as the
# previous bundle files, so "go back" has both halves in one place. Never fatal: a
# missing record must not stop an update, it only makes a rollback less convenient.
snapshot_running_images() {  # <project> <out-file> <previous version>
    local project="$1" out="$2" prev="$3" rows svc id cimg name digests asked=1
    rows="$(stack_containers "${project}")" || { rows=""; asked=0; }
    {
        printf '# Images the %s stack ran before this update, recorded %s.\n' "${project:-taranac}" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)"
        printf '# TARANAC_VERSION=%s\n' "${prev}"
        printf '# To go back: restore the bundle files from this directory, set TARANAC_VERSION=%s\n' "${prev}"
        printf '# in .env, then ./taranac up -d. The updater keeps the previous version'"'"'s images.\n'
        printf '# service\tcontainer\timage\timage-id\trepo-digests\n'
        while IFS=$'\t' read -r svc id cimg name; do
            [ -n "${svc}" ] || continue
            digests="$(docker image inspect --format '{{join .RepoDigests " "}}' "${id}" 2>/dev/null || true)"
            printf '%s\t%s\t%s\t%s\t%s\n' "${svc}" "${name#/}" "${cimg}" "${id}" "${digests}"
        done <<<"${rows}"
    } > "${out}" 2>/dev/null || return 0
    if [ -n "${rows}" ]; then
        ok "Recorded the running images → ${out}"
    elif [ "${asked}" = 0 ]; then
        notice "Could not list the running containers (the Docker daemon did not answer) — no image record."
    else
        notice "No running containers found to record (fresh or stopped stack)."
    fi
}

# ── 2. Room for what is about to be downloaded ───────────────────────────────
# Only images NOT on this host yet count, and each is estimated by the size of the image
# its service runs now — a new release is roughly the size of the old one. Layers shared
# with what is already here make the real need smaller, never larger. Plus 1 GiB of air:
# the database lives on the same disk, and a pull that fills it takes Postgres down.
#
# Where: Docker's root AND, with the containerd image store (driver-type
# io.containerd.snapshotter.v1 — the default on fresh Docker 29 installs), containerd's
# root, which is where the layers then actually land. The smaller free space wins.
DISK_HEADROOM_KB=$((1024 * 1024))
check_disk_for_pull() {  # <wanted service\timage lines> <project> → 1 = not enough
    local wanted="$1" project="$2" rows need_kb=0 svc img c_svc c_id rest sz
    rows="$(stack_containers "${project}")" || rows=""
    while IFS=$'\t' read -r svc img; do
        [ -n "${svc}" ] || continue
        [ -z "$(image_id "${img}")" ] || continue           # already here
        sz=""
        while IFS=$'\t' read -r c_svc c_id rest; do
            [ "${c_svc}" = "${svc}" ] || continue
            sz="$(docker image inspect --format '{{.Size}}' "${c_id}" 2>/dev/null || true)"
            break
        done <<<"${rows}"
        case "${sz}" in ''|*[!0-9]*) sz=0 ;; esac
        need_kb=$(( need_kb + sz / 1024 ))
    done <<<"${wanted}"
    if [ "${need_kb}" -eq 0 ]; then
        return 0     # everything is here already, or nothing to estimate from
    fi

    local -a paths=(); local root driver p free min_free=""
    root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    [ -n "${root}" ] && [ -d "${root}" ] && paths+=("${root}")
    driver="$(docker info --format '{{.Driver}} {{json .DriverStatus}}' 2>/dev/null || true)"
    case "${driver}" in
        *io.containerd.snapshotter*) [ -d /var/lib/containerd ] && paths+=(/var/lib/containerd) ;;
    esac
    for p in ${paths[@]+"${paths[@]}"}; do
        free="$(df -Pk "${p}" 2>/dev/null | awk 'NR==2 { print $4 }')" || free=""
        case "${free}" in ''|*[!0-9]*) continue ;; esac
        if [ -z "${min_free}" ] || [ "${free}" -lt "${min_free}" ]; then min_free="${free}"; fi
    done
    if [ -z "${min_free}" ]; then
        notice "Could not measure free disk space for the Docker image store — not checked."
        return 0
    fi
    local want_kb=$(( need_kb + DISK_HEADROOM_KB ))
    if [ "${min_free}" -lt "${want_kb}" ]; then
        printf '%s\n' "${c_red}✗ Not enough free disk to pull the new images: about $(( want_kb / 1024 )) MiB needed (images + 1 GiB for the database), $(( min_free / 1024 )) MiB free under ${paths[*]}.${c_reset}" >&2
        return 1
    fi
    notice "Disk: about $(( need_kb / 1024 )) MiB to download, $(( min_free / 1024 )) MiB free."
    return 0
}

# ── 4. The images are the ones the release was built with ────────────────────
# IMAGES.lock ships in the bundle, so SHA256SUMS (checked when the bundle was
# downloaded) covers it. One line per image, `<ref>@sha256:<digest>`; our own images are
# written `${IMAGE_PREFIX}/<svc>:<ver>` with the prefix LITERAL, because the digest does
# not depend on the registry path — a digest-preserving copy (imagetools create,
# skopeo copy --all, crane copy) carries the same manifest to any mirror.
#
# The key an image is looked up by: the reference without its digest and tag, with this
# install's IMAGE_PREFIX folded back into the literal the list uses.
image_lock_key() {  # <image ref> <prefix>
    local ref="${1%%@*}" prefix="$2" last
    last="${ref##*/}"
    case "${last}" in *:*) ref="${ref%:*}" ;; esac
    if [ -n "${prefix}" ]; then
        case "${ref}" in "${prefix}/"*) ref="\${IMAGE_PREFIX}/${ref#"${prefix}"/}" ;; esac
    fi
    printf '%s' "${ref}"
}

verify_pulled_images() {  # <lock file> <prefix> <wanted service\timage lines> → 1 on any mismatch
    local lock="$1" prefix="$2" wanted="$3" line key dg svc img want have
    local -A expected=()
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(printf '%s' "${line}" | tr -d '[:space:]')"
        case "${line}" in *@sha256:*) ;; *) continue ;; esac
        key="$(image_lock_key "${line%@*}" "")"
        dg="${line##*@}"
        expected["${key}"]="${dg}"
    done < "${lock}"

    local -a bad=(); local checked=0
    while IFS=$'\t' read -r svc img; do
        [ -n "${svc}" ] || continue
        key="$(image_lock_key "${img}" "${prefix}")"
        want="${expected[${key}]:-}"
        if [ -z "${want}" ]; then
            bad+=("${svc}: ${img} — not in this release's IMAGES.lock")
            continue
        fi
        have="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${img}" 2>/dev/null || true)"
        if printf '%s\n' "${have}" | grep -qF "@${want}"; then
            checked=$((checked + 1))
        elif [ -z "$(printf '%s' "${have}" | tr -d '[:space:]')" ]; then
            bad+=("${svc}: ${img} — has no registry digest (built or loaded locally?), release lists ${want}")
        else
            bad+=("${svc}: ${img} — pulled $(printf '%s' "${have}" | head -1 | sed 's/.*@//'), release lists ${want}")
        fi
    done <<<"${wanted}"

    if [ ${#bad[@]} -gt 0 ]; then
        printf '%s\n' "${c_red}✗ Pulled images do not match the digests this release was built with:${c_reset}" >&2
        printf '      %s\n' "${bad[@]}" >&2
        return 1
    fi
    ok "Verified ${checked} image(s) against the release's IMAGES.lock."
    return 0
}

# A third-party image the compose files pin by digest (`postgres:16-alpine@sha256:…`,
# stamped at release) is stored UNTAGGED: pulling name:tag@digest sends only the digest
# to the registry. The HA and diagnostic tools start their one-shot probes by the familiar
# tag (`docker run postgres:16-alpine …`), and on an offline host an absent tag is a
# failed probe. So the tag is pointed at the verified content — which is also exactly
# what the old floating-tag pull used to leave behind. Best-effort, never fatal.
keep_pinned_tags() {  # <service\timage lines>
    local svc ref name_tag digest last
    while IFS=$'\t' read -r svc ref; do
        case "${ref}" in *@sha256:*) ;; *) continue ;; esac
        name_tag="${ref%@*}"; digest="${ref##*@}"; last="${name_tag##*/}"
        case "${last}" in *:*) ;; *) continue ;; esac
        docker tag "${name_tag%:*}@${digest}" "${name_tag}" >/dev/null 2>&1 || true
    done <<<"$1"
}

# ── Containers that exist but do not run ─────────────────────────────────────
# stack_drift answers "which IMAGE does each container run", and a container that
# compose created but never started answers that question correctly — so a node
# whose UI and AAA daemons sat in Created looked finished to it. This is the other
# half: `service<TAB>state` for every container of the project that is not running.
stack_not_running() {  # <bundle-dir> <env-file>
    local dir="$1" env_file="$2" files project ids
    files="$( (ha_compose_files "${dir}" "${env_file}" && printf '%s\n' "${COMPOSE_FILES[@]}") 2>/dev/null)" || return 0
    local -a fargs=(); local l
    while IFS= read -r l; do [ -n "${l}" ] && fargs+=("${l}"); done <<<"${files}"
    project="$(compose_project_name "${env_file}" "${dir}" "${fargs[@]}")"
    [ -n "${project}" ] || return 0
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" \
                        --filter "label=com.docker.compose.oneoff=False" 2>/dev/null)" || return 0
    [ -n "${ids}" ] || return 0
    # Only the services this node's compose set declares. A leftover container of the
    # same project that no compose file names any more (an orphan) is nobody's to
    # start, and counting it made every later run "finish the update" all over again.
    local services
    services="$(compose_service_images "${env_file}" "${dir}" "" "${fargs[@]}" | cut -f1 | paste -sd' ' -)"
    # shellcheck disable=SC2086  # one id per word, on purpose
    docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{.State.Status}}' ${ids} 2>/dev/null \
        | awk -F'\t' -v svcs=" ${services} " '$1 != "" && $2 != "running" && (svcs == "  " || index(svcs, " " $1 " "))' || true
}

# ── A node on the target with something not running: start it, recreate nothing ──
# The bundle, the pin and every container's image already say the target, so there
# is nothing to download, back up or recreate — re-applying the release did all
# three (a new backup directory, the whole stack recreated, the database restarted)
# for what was one Created or stopped container. `--no-recreate` starts what is
# Created or stopped and leaves every running container exactly as it is. On an HA
# DB node the api goes first, as in an update: what depends on it waits for its
# health, and a replica's api may wait for the leader — then the finisher takes the
# rest, never a blocking `up -d` from here.
stack_start_missing() {  # <bundle-dir> <env-file> <target> → 0 = started (or handed to the finisher); 1 = failed; 3 = refused (said)
    local dir="$1" env_file="$2" target="$3" lrc=0
    ( ha_compose_files "${dir}" "${env_file}" ) >/dev/null 2>&1 || return 1
    ha_compose_files "${dir}" "${env_file}"
    # Starting a stopped etcd or Postgres is a voter coming back — under the cluster's
    # update lock like any restart, so it never coincides with another member's.
    if [ -n "${HA_KIND}" ] && type cv_lock_acquire >/dev/null 2>&1; then
        cv_lock_acquire "${target}" || lrc=$?
        case "${lrc}" in
            0) trap 'cv_lock_release' EXIT ;;
            1) ha_refuse_locked "${target}"; return 3 ;;
            *) warn "Could not take the cluster's update lock (${CV_ETCD_ERR:-no answer}) — nothing was started."
               printf '%s\n' "      Check the ring with  ./taranac cluster status , then run:  $(update_cmd "${target}")"
               return 3 ;;
        esac
    fi
    if [ "${HA_KIND}" = db ]; then
        TARANAC_VERSION="${target}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d --no-recreate api || return 1
        local waited=0
        while [ "$(api_health)" != healthy ] && [ "${waited}" -lt "${HA_API_WAIT_S}" ]; do sleep 5; waited=$((waited + 5)); done
        if [ "$(api_health)" != healthy ]; then
            cv_start_finisher "${dir}" "${target}" || return 1
            return 0
        fi
    fi
    # No proxy refresh here: it force-recreates edge and frontend, and the api they
    # point at was not recreated — this path recreates nothing.
    TARANAC_VERSION="${target}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d --no-recreate || return 1
    return 0
}

# Remind the operator what an HA restart does. The ORDER is not here: it is decided
# by ha_navigate below, before anything is written, from the cluster's live state.
ha_upgrade_notice() {
    [ "${HA_ACTIVE:-0}" = "1" ] || return 0
    echo
    warn "HA node — the database comes up under the Patroni overlay."
    notice "Recreating this node's database container restarts its Postgres; on the leader that"
    notice "is a failover, which is why the leader comes after every replica. (HA.md §6)"
    echo
}

# ── The cluster navigator ────────────────────────────────────────────────────
# Which member of the cluster is the right one to update now — every replica, then
# the leader, then the witness — decided from the cluster's LIVE state each run
# (cluster-versions.sh), and enforced before anything is written: no backup, no file
# swap, no pin. A run on the wrong machine is told where to start, with the whole
# cluster in a table, rather than asked to know the order by heart.
#
# What the guard before it got wrong, and why this one reads etcd: it asked the
# heartbeat table, which the api of every node writes — and the api of a freshly
# updated replica is down until the leader migrates. So the leader refused on the
# correct sequence ("never reported") and needed --allow-out-of-order; the version
# records in etcd are written by the updater itself and readable with every api down.
#
# Returns 0 = go ahead, 1 = refused (printed, summary included), 2 = this witness is
# already on <target> and finished (nothing to do; printed). With <allow>=1 a
# refusal of ORDER becomes one line on stderr and a trail (.taranac-update.log, and
# override=1 in this node's record). A refusal because the ring has no quorum is
# not an order question and is passed by <allow> too, but said the same way.
HA_KIND=""   # db | witness | "" (standalone, collector) — set by ha_kind_of
ha_kind_of() {  # <dest> <env-file>
    HA_KIND=""
    if install_is_witness "$2"; then HA_KIND=witness
    elif host_is_product "$1" "$2" && ha_is_configured "$2"; then HA_KIND=db; fi
}

ha_navigate() {  # <dest> <env-file> <target> <allow 0|1>
    local dest="$1" env_file="$2" target="$3" allow="$4"
    [ -n "${HA_KIND}" ] && [ -n "${target}" ] || return 0
    if ! type cv_plan >/dev/null 2>&1; then
        warn "This bundle carries no cluster-versions.sh — the cluster order was NOT checked."
        return 0
    fi
    cv_init "${dest}" "${env_file}" "${HA_KIND}"

    local why=""
    if ! cv_plan "${target}"; then
        why="${CV_REFUSAL#*|}"
        if [ "${allow}" = 1 ]; then
            _ha_override "${dest}" "${why}"
            return 0
        fi
        echo >&2
        printf '%s\n' "${c_red}✗ NOT updating: ${why}.${c_reset}" >&2
        case "${CV_REFUSAL%%|*}" in
            quorum) printf '%s\n' "  This is a fault of the cluster itself (also raised as the etcd ring alert)." \
                                  "  See what is wrong:  ./taranac diagnose" >&2 ;;
        esac
        printf '%s\n' "  Nothing was changed here." >&2
        [ ${#M_NAME[@]} -gt 0 ] && cv_table "${target}" >&2
        return 1
    fi

    local self="${CV_SELF_IDX}"
    if [ -z "${self}" ]; then
        why="this node's etcd member '${CV_SELF_NAME:-?}' (ETCD_NAME in .env) is not in the ring's member list"
        if [ "${allow}" = 1 ]; then _ha_override "${dest}" "${why}"; return 0; fi
        _ha_not_a_member "${dest}" "${why}"
        cv_summary "${target}" >&2
        return 1
    fi

    # A witness on the target whose record says so is finished: a re-run is a no-op.
    if [ "${HA_KIND}" = witness ] && [ "${M_DONE[self]}" = 1 ] && [ "${M_STATE[self]}" = updated ] \
       && [ "$(head -1 "${dest}/VERSION" 2>/dev/null | tr -d '[:space:]')" = "${target}" ] \
       && [ "$(env_value "${env_file}" TARANAC_VERSION)" = "${target}" ]; then
        ok "Already on ${target} — this witness and its record agree. Nothing to do."
        cv_summary "${target}"
        return 2
    fi

    # Another member's run is under way: two DB nodes restarting together can cost
    # the cluster its quorum, so this one waits for that one — whatever the order says.
    # The lock is what decides (cv_lock_acquire, atomic, in the writing run); read
    # here too so a run that would lose is told before it downloads anything.
    # The LOCK decides. A member's `updating` record with the lock read FREE is a run
    # that died (a reboot, kill -9 — the lease is gone within two minutes, the record
    # is not): shown in the table, never a refusal. Only when etcd could not tell us
    # (no answer) does the record's own age stand in for it.
    local prc=0
    cv_lock_peek || prc=$?
    if [ "${prc}" = 0 ]; then
        ha_refuse_locked "${target}"
        return 1
    fi
    if [ "${prc}" = 2 ] && cv_other_running; then
        if [ "${allow}" = 1 ]; then _ha_override "${dest}" "another member is being updated: ${CV_BUSY}"; return 0; fi
        echo >&2
        printf '%s\n' "${c_red}✗ NOT updating: another member of the cluster is being updated right now — ${CV_BUSY}.${c_reset}" >&2
        printf '%s\n' "  Two members restarting together can cost the cluster its quorum, so one run at a time." >&2
        printf '%s\n' "  Let that run finish (it ends with 'Update complete' there), then re-run here:  $(cv_update_cmd "${target}")" >&2
        printf '%s\n' "  A run that died leaves this mark for at most $(( CV_UPDATING_STALE_S / 60 )) minutes. Nothing was changed here." >&2
        cv_table "${target}" >&2
        return 1
    fi

    # This node is on the target already (a re-apply, a repair) — never in the way.
    [ "${M_DONE[self]}" = 1 ] && return 0

    if ! cv_is_next "${self}"; then
        if [ "${allow}" = 1 ]; then
            _ha_override "${dest}" "$(cv_role_of "${self}") ${M_NAME[self]} before ${M_NAME[CV_NEXT[0]]:-?} ($(cv_role_of "${CV_NEXT[0]:-0}"))"
            return 0
        fi
        cv_refuse_wrong_node "${target}"
        cv_table "${target}" >&2
        return 1
    fi

    if [ "${HA_KIND}" = witness ]; then
        if ! cv_witness_gate "${target}"; then
            [ "${allow}" = 1 ] && { _ha_override "${dest}" "witness before every DB node finished"; return 0; }
            cv_summary "${target}" >&2
            return 1
        fi
        if ! _ha_witness_ring_ok "${dest}"; then
            [ "${allow}" = 1 ] && { _ha_override "${dest}" "witness with an unhealthy etcd ring"; return 0; }
            cv_summary "${target}" >&2
            return 1
        fi
    fi
    return 0
}

# Right before anything restarts: the slot must still be this run's. The lease is
# renewed in the background, and a ring that lost its quorum for longer than the
# lease (a long pull through it) lets it expire without a word — then another member
# may hold the slot and restart now. Two at once is exactly what the lock prevents.
ha_require_lock() {  # <target>
    [ -n "${HA_KIND}" ] && [ -n "${CV_LOCK_LEASE:-}" ] || return 0
    cv_lock_held && return 0
    trap - ERR
    printf '\n%s\n' "${c_red}✗ NOT restarting: this run no longer holds the cluster's update slot — ${CV_LOCK_WHY}.${c_reset}" >&2
    printf '%s\n' "  Restarting now could take this node down together with the member that holds it," \
                  "  which is what costs the cluster its quorum. Nothing was restarted here; the bundle" \
                  "  files and the pin are already $1. When no other member is being updated (see" \
                  "  ./taranac cluster status), finish here with:  $(update_cmd "$1")" >&2
    exit 1
}

# Another member holds the cluster's update lock. Never overridable: the order may
# be skipped with --allow-out-of-order, but two members restarting together is a lost
# quorum (and AAA down on both), whatever order they are in.
ha_refuse_locked() {  # <target> — CV_LOCK_HOLDER says who
    echo >&2
    printf '%s\n' "${c_red}✗ NOT updating: ${CV_LOCK_HOLDER%% (*} is being updated right now — ${CV_LOCK_HOLDER}.${c_reset}" >&2
    printf '%s\n' "  Two members restarting together can cost the cluster its quorum and take AAA down on" \
                  "  both, so one member at a time. Nothing was changed here." \
                  "  Wait for that run to end (it prints the cluster's table there), then run here:" \
                  "      $(cv_update_cmd "$1")" \
                  "  A run that died frees its slot by itself within $(( CV_LOCK_TTL_S / 60 > 0 ? CV_LOCK_TTL_S / 60 : 1 )) minute(s)." >&2
    cv_plan "$1" >/dev/null 2>&1 || true
    cv_table "$1" >&2
}

# Not in the ring: say what this host IS, from what the cluster recorded about it,
# and the one command that settles it — not "go and diagnose".
_ha_not_a_member() {  # <dest> <why>
    local why="$2" departed="" status=""
    printf '\n%s\n' "${c_red}✗ NOT updating: ${why}.${c_reset}" >&2
    if [ "${HA_KIND}" = witness ] && [ -n "${CV_SELF_ADDR}" ] \
       && cv_etcdctl get "/taranac/departed/${CV_SELF_ADDR}" --print-value-only && [ -n "${CV_OUT}" ]; then
        departed="${CV_OUT}"
    fi
    if [ "${HA_KIND}" = db ]; then
        status="$(docker exec taranac-db psql -U taranac -d taranac -tA -c \
            "SELECT status FROM cluster_nodes WHERE name = '${CV_SELF_NODE//\'/}' ORDER BY updated_at DESC LIMIT 1" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    fi
    if [ -n "${departed}" ]; then
        printf '%s\n' "  This witness was removed from the cluster ($(cv_field "${departed}" at) — remove-witness on a DB node)," \
                      "  but it still runs here. Retire it on this host:" \
                      "      ./witness-join.sh --leave" >&2
    elif [ "${HA_KIND}" = witness ]; then
        printf '%s\n' "  The ring does not count this witness. If it was removed on purpose, retire it here:" \
                      "      ./witness-join.sh --leave" \
                      "  If it should still be the arbiter, add it again: on a DB node  ./taranac cluster add-witness" >&2
    elif [ -n "${status}" ] && [ "${status}" != active ]; then
        printf '%s\n' "  This node was removed from the cluster (its roster row is '${status}'), but it still" \
                      "  runs as a cluster member. Turn it into a standalone install (it keeps its data):" \
                      "      ./taranac cluster detach" \
                      "  or, if the machine is to be retired, wipe it instead." >&2
    else
        printf '%s\n' "  See what this node is to the cluster:  ./taranac diagnose" >&2
    fi
    printf '%s\n' "  Nothing was changed here." >&2
}

_ha_override() {  # <dest> <what is being skipped>
    printf '%s\n' "${c_yellow}! --allow-out-of-order: skipping cluster order: $2${c_reset}" >&2
    CV_OVERRIDE=1
    cv_log "$1" "update --allow-out-of-order on ${CV_SELF_NAME:-this node}: skipping cluster order: $2"
}

# Recreating the arbiter's etcd is a quorum event: only on a healthy ring, and only
# when the witness compose really changes. Asked before anything is written.
_ha_witness_ring_ok() {  # <dest>
    local dest="$1" src_compose="${BUNDLE_DIR}/docker-compose.witness.yml"
    [ -f "${src_compose}" ] && ! cmp -s "${src_compose}" "${dest}/docker-compose.witness.yml" || return 0
    if cv_etcdctl endpoint health --cluster; then return 0; fi
    echo >&2
    printf '%s\n' "${c_red}✗ NOT updating the witness: this release changes docker-compose.witness.yml, which recreates this${c_reset}" >&2
    printf '%s\n' "${c_red}  arbiter's etcd — and the ring is not healthy right now, so that could cost the cluster its quorum.${c_reset}" >&2
    printf '%s\n' "${CV_OUT}" "${CV_ERR}" | grep -E 'unhealthy|^Error' | sed 's/^/      /' >&2
    printf '%s\n' "  See what is wrong:" "      ./taranac diagnose" "  Nothing was changed here." >&2
    return 1
}

# How long a DB node waits, in this shell, for its own api after the restart. A
# release without a schema change (and the leader, which migrates itself) is healthy
# well inside it, and then the update ends here with every service running; past it,
# the finisher container takes over and this shell returns.
HA_API_WAIT_S="${TARANAC_UPDATE_API_WAIT_S:-120}"

api_health() { docker inspect --format '{{.State.Health.Status}}' taranac-api 2>/dev/null || true; }

# ── An HA DB node's restart: recreate everything, start the api, hand over ───
# `up -d` on a replica used to block for half an hour: compose starts the api, then
# waits for it to be healthy before it starts anything that depends on it — and a
# replica's api is healthy only when the LEADER has migrated the schema, i.e. after
# the operator's next step on another machine. So instead:
#   1. `up -d --no-start` — every container is recreated on the new images and left
#      Created; nothing old keeps running against a schema it does not know.
#   2. the images are checked (stack_drift).
#   3. `up -d api` — only the api and what IT depends on (Postgres, etcd, …); then
#      the superseded images are pruned — no container references them any more,
#      the finisher has no bash to do it, and Postgres and etcd are already back.
#   4. up to HA_API_WAIT_S for the api: healthy → `up -d` here and done (updated);
#      not yet → state=awaiting-schema, and the finisher container runs step 4 later.
# Always this path on an HA DB node — leader included — with no guess at whether
# the release migrates: the leader's api migrates and is healthy within the wait,
# and a migration that takes longer is finished the same way a replica's is.
# ── The bootstrap topology, from the cluster, right before the planned restart ─
# DB_HOSTS, ETCD_HOSTS and ETCD_INITIAL_CLUSTER are read by containers only when
# they START: write routing follows the replicated roster at runtime and a running
# etcd takes its ring from Raft. So after `add-node`, every older member keeps the
# shorter values in .env — harmless while it runs, and this is the moment that stops
# being true: the recreate below starts Patroni and etcd from them. Recreating by
# hand at any other time is what restarts Patroni on the leader (a failover), so
# the values are refreshed HERE, where the restart is already planned, and nowhere
# else. Derived, never copied from a peer: the roster for DB_HOSTS (nodes that
# completed a join — a removed and detached node is not routed to), the live ring
# for the etcd keys (it knows the witness). A source that does not answer in full
# leaves its key exactly as it is; this never writes a SHORTER list than the truth.
env_set_value() {  # <env file> <key> <value> — in place, so owner, group and mode survive
    # Write, verify, THEN replace — the same rule as write_version_pin. This runs right
    # after the pull, when the disk is fullest, and .env (SECRET_KEY, POSTGRES_PASSWORD)
    # is operator-owned and in no backup: a short write must never reach it. The copy
    # is complete only if it has every line of the original (one more when the key is
    # appended) and the new assignment. Returns 1 with .env untouched otherwise; a
    # failure of the final copy-through (rarer still: it frees the blocks it reuses)
    # keeps the verified copy on disk and names it.
    local f="$1" tmp lines want_lines
    tmp="$(mktemp "${f}.XXXXXX")" || return 1
    chmod 600 "${tmp}" 2>/dev/null || true
    lines="$(wc -l < "${f}")"; want_lines="${lines}"
    if grep -q "^$2=" "${f}"; then
        K="$2" V="$3" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' \
            "${f}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    else
        [ -z "$(tail -c1 "${f}")" ] || want_lines=$((want_lines + 1))
        want_lines=$((want_lines + 1))
        { cat "${f}" && { [ -z "$(tail -c1 "${f}")" ] || echo; } && printf '%s=%s\n' "$2" "$3"; } > "${tmp}" \
            || { rm -f "${tmp}"; return 1; }
    fi
    if [ "$(wc -l < "${tmp}")" != "${want_lines}" ] || ! grep -qxF "$2=$3" "${tmp}"; then
        rm -f "${tmp}"; return 1
    fi
    if ! cat "${tmp}" > "${f}" || ! cmp -s "${tmp}" "${f}"; then
        printf '%s\n' "${c_red}✗ .env could not be written back in full (disk full?). Its complete, verified content is in ${tmp}.${c_reset}" \
                      "  Free space, then restore it:  cat ${tmp} > ${f} && rm ${tmp}" >&2
        return 1
    fi
    rm -f "${tmp}"
}

ha_roster_addresses() {  # → active roster addresses, one per line (empty = no answer)
    docker exec taranac-db psql -U taranac -d taranac -tA -c \
        "SELECT address FROM cluster_nodes WHERE status = 'active' AND address IS NOT NULL ORDER BY address" \
        2>/dev/null || true
}

ha_ring_rows() {  # → "name<TAB>first peerURL<TAB>client host:port,…" per member (empty = no answer)
    type cv_etcdctl >/dev/null 2>&1 || return 0
    cv_etcdctl member list || return 0
    # etcdctl's simple format, the one cv_plan reads too:
    #   "<id>, started, <name>, <peerURLs>, <clientURLs>, <isLearner>"
    # where a list of URLs is joined by a bare ",". An added-but-not-started member
    # has an empty name — kept as such, so the caller can refuse to build from it.
    printf '%s\n' "${CV_OUT}" | awk -F', ' 'NF >= 5 {
        split($4, p, ","); n = split($5, c, ","); clients = ""
        for (i = 1; i <= n; i++) { u = c[i]; sub(/^[a-z]+:\/\//, "", u); if (u != "") clients = clients (clients == "" ? "" : ",") u }
        print $3 "\t" p[1] "\t" clients
    }' || true
}

ha_refresh_bootstrap() {  # <dest> <env file>
    local env_file="$2" roster rows key have want changed=""
    roster="$(ha_roster_addresses)"
    rows="$(ha_ring_rows)"
    for key in DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER; do
        want=""
        case "${key}" in
            DB_HOSTS)
                # Each host on the port the current DB_HOSTS gives it, else on the
                # cluster's port (the most common one there), else 5432 — the rule of
                # write_routing.effective_write_hosts, so a non-default POSTGRES_PORT
                # survives the rewrite.
                [ -z "${roster}" ] || want="$(printf '%s\n' "${roster}" | awk -v old="$(env_value "${env_file}" DB_HOSTS)" '
                    BEGIN {
                        n = split(old, e, ",")
                        for (i = 1; i <= n; i++) {
                            h = e[i]; gsub(/[[:space:]]/, "", h); if (h == "") continue
                            p = 5432
                            if (match(h, /:[0-9]+$/)) { p = substr(h, RSTART + 1); h = substr(h, 1, RSTART - 1) }
                            port[h] = p; cnt[p]++
                            if (cnt[p] > best) { best = cnt[p]; cport = p }
                        }
                        if (cport == "") cport = 5432
                    }
                    NF { print $1 ":" (($1 in port) ? port[$1] : cport) }' | paste -sd, - || true)" ;;
            ETCD_HOSTS)
                [ -z "${rows}" ] || want="$(printf '%s\n' "${rows}" | cut -f3 | tr ',' '\n' \
                    | grep -E '^[^:]+:[0-9]+$' | sort -u | paste -sd, - || true)" ;;
            ETCD_INITIAL_CLUSTER)
                # Only when every member has a name and a peer URL (one added but not
                # started yet has neither) — that is the form etcd validates against.
                if [ -n "${rows}" ] && ! printf '%s\n' "${rows}" | awk -F'\t' '$1 == "" || $2 == "" { bad = 1 } END { exit !bad }'; then
                    want="$(printf '%s\n' "${rows}" | awk -F'\t' '{ print $1 "=" $2 }' | paste -sd, - || true)"
                fi ;;
        esac
        [ -n "${want}" ] || continue
        have="$(env_value "${env_file}" "${key}")"
        [ "${want}" = "${have}" ] && continue
        if ! env_set_value "${env_file}" "${key}" "${want}"; then
            # Not a warning to step over: the restart that follows starts Patroni and
            # etcd from these keys, and the failure is a full or read-only disk that
            # the restart would hit next. Stop here, with nothing recreated.
            printf '%s\n' "${c_red}✗ Could not write ${key} into .env (disk full or read-only?) — .env is unchanged and no container was recreated.${c_reset}" >&2
            return 1
        fi
        changed="${changed:+${changed}, }${key}"
    done
    if [ -n "${changed}" ]; then
        ok "Brought this node's bootstrap topology up to the cluster's (${changed}) — from the node roster and the live etcd ring"
    fi
    [ -n "${roster}" ] || notice "The node roster did not answer — DB_HOSTS left as it is."
    [ -n "${rows}" ] || notice "The etcd ring did not answer — ETCD_HOSTS / ETCD_INITIAL_CLUSTER left as they are."
    return 0
}

# ── The cluster manifest, when no node holds one at all ─────────────────────
# A cluster built before the manifest was published (or whose only copy was on a
# machine since lost) has none anywhere, and every later topology command stops at
# "publish it by hand". The updater is the one command every node runs, so it
# rebuilds it from what the cluster says about itself — the roster (DB nodes, the
# oldest one as the seed) and the live ring (an etcd member matching no roster row
# by name or address is the witness) — and publishes it. Only when BOTH this node's
# file and the published copy are absent: an existing copy, however old, is the
# operator's and is never replaced from here.
HA_REBUILT_MANIFEST=""   # built by ha_rebuild_manifest, published by ha_publish_rebuilt_manifest
ha_rebuild_manifest() {  # <dest> <env file>
    local dest="$1" env_file="$2" published nodes rows cm="${1}/cluster-manifest.py" file
    file="${dest}/config/cluster.yml"
    [ -f "${file}" ] && return 0
    [ -f "${cm}" ] || return 0
    published="$(docker exec taranac-db psql -U taranac -d taranac -tA -c \
        "SELECT count(*) FROM system_settings WHERE key = 'cluster.manifest' AND coalesce(value, '') <> ''" \
        2>/dev/null || true)"
    # Not "0" = there is one, or the database could not be asked; either way, no rebuild.
    [ "${published}" = "0" ] || return 0
    nodes="$(docker exec taranac-db psql -U taranac -d taranac -tA -F"$(printf '\t')" -c \
        "SELECT name, address FROM cluster_nodes WHERE status = 'active' AND address IS NOT NULL ORDER BY created_at" \
        2>/dev/null || true)"
    rows="$(ha_ring_rows)"
    if [ -z "${nodes}" ] || [ -z "${rows}" ]; then
        notice "No cluster manifest exists, and the roster or the ring did not answer — not rebuilt this time."
        return 0
    fi
    local work cluster cidr seed_name seed_addr name addr out
    work="$(mktemp -d)"
    cluster="$(env_value "${env_file}" TARANAC_CLUSTER_NAME)"
    cidr="$(env_value "${env_file}" PG_ALLOW_CIDR)"
    seed_name="$(printf '%s\n' "${nodes}" | head -1 | cut -f1)"
    seed_addr="$(printf '%s\n' "${nodes}" | head -1 | cut -f2)"
    if ! out="$(python3 "${cm}" init --file "${work}/cluster.yml" --cluster "${cluster:-taranac}" \
            --address "${seed_addr}" --name "${seed_name}" ${cidr:+--pg-allow-cidr "${cidr}"} 2>&1 >/dev/null)"; then
        warn "No cluster manifest exists anywhere, and rebuilding one failed: ${out##*$'\n'}"
        rm -rf "${work}"; return 0
    fi
    while IFS="$(printf '\t')" read -r name addr; do
        [ -n "${name}" ] && [ "${name}" != "${seed_name}" ] || continue
        python3 "${cm}" add-node --file "${work}/cluster.yml" --address "${addr}" --name "${name}" >/dev/null 2>&1 || true
    done <<EOF
${nodes}
EOF
    local peer host
    while IFS="$(printf '\t')" read -r name peer _; do
        host="${peer#*//}"; host="${host%%:*}"
        [ -n "${host}" ] || continue
        printf '%s\n' "${nodes}" | awk -F'\t' -v n="${name}" -v h="${host}" '$1 == n || $2 == h { f = 1 } END { exit !f }' && continue
        python3 "${cm}" add-witness --file "${work}/cluster.yml" --address "${host}" ${name:+--name "${name}"} >/dev/null 2>&1 || true
    done <<EOF
${rows}
EOF
    # Read by the navigator from here (CV_MANIFEST_FILE); published only once the
    # navigator lets this run go ahead, so a refusal really did change nothing.
    HA_REBUILT_MANIFEST="${work}/cluster.yml"
    CV_MANIFEST_FILE="${HA_REBUILT_MANIFEST}"
    return 0
}

ha_publish_rebuilt_manifest() {  # <dest>
    local dest="$1" out file="${1}/config/cluster.yml"
    [ -n "${HA_REBUILT_MANIFEST}" ] && [ -f "${HA_REBUILT_MANIFEST}" ] || return 0
    if ! out="$("${dest}/taranac" cluster manifest-publish < "${HA_REBUILT_MANIFEST}" 2>&1)"; then
        warn "Rebuilt the missing cluster manifest, but could not publish it — kept on this node only: ${out##*$'\n'}"
    else
        ok "No node held a cluster manifest — rebuilt it from the node roster and the live ring, and published it"
    fi
    mkdir -p "${dest}/config" && cp "${HA_REBUILT_MANIFEST}" "${file}" 2>/dev/null || true
    rm -rf "$(dirname "${HA_REBUILT_MANIFEST}")"
    HA_REBUILT_MANIFEST=""; CV_MANIFEST_FILE=""
    return 0
}

HA_FINAL_STATE=""
ha_db_restart() {  # <dest> <env-file> <target> <prev> <do_prune> <backup>
    local dest="$1" env_file="$2" target="$3" prev="$4" do_prune="$5" backup="$6"
    _apply_phase="recreating the containers on ${target}"
    info "Recreating every container on ${target} (nothing starts until the api is up) ..."
    TARANAC_VERSION="${target}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d --no-start

    local drc=0
    stack_drift "${dest}" "${env_file}" "${target}" || drc=$?
    if [ "${drc}" = 1 ]; then
        trap - ERR
        printf '\n%s\n' "${c_red}✗ update DID NOT FINISH: the containers were recreated, but these are not on ${target}:${c_reset}" >&2
        printf '      %s\n' "${STACK_DRIFT[@]}" >&2
        printf '%s\n' "  ${_apply_state} Re-run  $(update_cmd "${target}")  to complete it." >&2
        exit 1
    fi
    _apply_phase="starting the api on ${target}"
    info "Starting the api (and the database it needs) ..."
    TARANAC_VERSION="${target}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d api
    # Housekeeping only after the database and etcd are back: no container references
    # the superseded images any more, but the prune takes its time, and on this node
    # everything was down until the line above.
    if [ "${do_prune}" = "1" ]; then
        prune_old_images "${env_file}" "${target}" "${prev}" || true
    else
        notice "Kept superseded images (--keep-images)."
    fi

    local waited=0 h=""
    while :; do
        h="$(api_health)"
        [ "${h}" = healthy ] && break
        [ "${waited}" -lt "${HA_API_WAIT_S}" ] || break
        [ "${waited}" -gt 0 ] && [ $(( waited % 30 )) -eq 0 ] && notice "  ${waited}s: api is ${h:-not up yet}"
        sleep 5; waited=$((waited + 5))
    done

    if [ "${h}" = healthy ]; then
        _apply_phase="starting the rest of the stack on ${target}"
        info "The api is healthy — starting the rest of the stack ..."
        TARANAC_VERSION="${target}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d
        refresh_proxy_dns "${env_file}"
        if [ -z "$(stack_not_running "${dest}" "${env_file}")" ]; then
            ok "Stack updated — every container runs the ${target} images."
            cv_record_put updated "${target}"
            HA_FINAL_STATE=updated
            return 0
        fi
    fi

    # Not healthy yet: the normal case on a replica of a release that migrates.
    _apply_phase="handing over to the update finisher"
    cv_record_put awaiting-schema "${target}"
    if ! cv_start_finisher "${dest}" "${target}"; then
        trap - ERR
        printf '\n%s\n' "${c_red}✗ update DID NOT FINISH: the containers are on ${target} and the api is starting, but the finisher container could not be started.${c_reset}" >&2
        printf '%s\n' "  Without it the services that wait for the api stay in Created. See why:" \
                      "      docker compose -p taranac-update-finisher -f docker-compose.update-finisher.yml up" \
                      "  then re-run  $(update_cmd "${target}")  on this node; it starts the finisher again." >&2
        exit 1
    fi
    ok "This node runs ${target}; its api is waiting for the schema (state: awaiting-schema)."
    notice "A finisher container (taranac-update-finisher) starts the rest of the stack the moment"
    notice "the api is healthy, records 'updated' and removes itself — no second run needed."
    HA_FINAL_STATE=awaiting-schema
    return 0
}

# The closing lines of a DB node's run: what is down, and where to go next.
ha_db_epilogue() {  # <target>
    local target="$1"
    echo
    if ! cv_plan "${target}" 2>/dev/null; then
        notice "Could not read the cluster's state back (${CV_REFUSAL#*|}) — see ./taranac cluster status."
        return 0
    fi
    if [ "${HA_FINAL_STATE}" = awaiting-schema ] && [ ${#CV_NEXT[@]} -gt 0 ] && [ "${M_KIND[CV_NEXT[0]]}" = db ]; then
        local n="${CV_NEXT[0]}" who="the next node"
        [ "${n}" = "${CV_LEADER_IDX}" ] && who="the leader"
        printf '%s\n' "${c_bold}Next:${c_reset} update ${who} now: ${M_NAME[n]} (${M_ADDR[n]}) → $(cv_update_cmd "${target}")"
        warn "AAA (tacacs/radius/nac) and the UI on this node are down until the leader is updated."
        cv_table "${target}"
    else
        [ "${HA_FINAL_STATE}" = awaiting-schema ] \
            && notice "This node's remaining services start by themselves as soon as its api is healthy."
        cv_summary "${target}"
    fi
}

# On the no-op path: a DB node whose record says awaiting-schema needs its finisher,
# not another `up -d` (which would block on the api exactly as before).
ha_ensure_finisher() {  # <dest> <target> → 0 = handled (awaiting), 1 = not awaiting
    local dest="$1" target="$2"
    [ -n "${CV_SELF_IDX:-}" ] || return 1
    [ "${M_STATE[CV_SELF_IDX]}" = awaiting-schema ] && [ "${M_VER[CV_SELF_IDX]}" = "${target}" ] || return 1
    if cv_finisher_running; then
        ok "This node runs ${target} and is awaiting its schema; its finisher is running and completes it."
    elif cv_start_finisher "${dest}" "${target}"; then
        ok "This node runs ${target} and was awaiting its schema with no finisher — started it again."
    else
        warn "This node is awaiting its schema and the finisher container could not be started:"
        printf '%s\n' "      docker compose -p taranac-update-finisher -f docker-compose.update-finisher.yml up"
        return 0
    fi
    return 0
}

# ── Version helpers ──────────────────────────────────────────────────
# What is INSTALLED here is the bundle on disk, and the bundle says so in its own
# VERSION file. This used to read `.env` first, and the two are not the same
# question:
#
#   VERSION            — the scripts, compose files and runbooks in this directory.
#                        Replaced atomically with the bundle by cmd_apply.
#   TARANAC_VERSION    — which image TAG compose pulls. A pin, and the only thing
#     (in .env)          the pull may read.
#
# They agree after a finished upgrade and can disagree after an interrupted one: the
# files are replaced first and the pin is written after them — and BOTH before the
# containers are recreated, so even when they agree neither says what RUNS. That third
# answer comes from the daemon (stack_drift), and it is the one "Nothing to do" rests
# on. Reading the pin as the installed version made the node report the version
# it had FAILED to reach, and `update` then answered "Already on it. Nothing to
# do." A customer's node sat on 1.2.4 scripts insisting it was 1.2.6, which is
# also why its wrapper had never heard of `diagnose`.
#
# Every other script in this bundle already treats VERSION as authoritative —
# install.sh and collector-join.sh DERIVE the pin from it, diagnose.sh reports it.
# This function was the outlier.
current_version() {
    local v=""
    # tr -d, as install.sh and collector-join.sh both do: a VERSION file that
    # came off a Windows editor otherwise reports "1.2.7\r" and matches nothing.
    [ -f "${VERSION_FILE}" ] && v="$(head -1 "${VERSION_FILE}" | tr -d '[:space:]')"
    [ -z "${v}" ] && v="$(env_value "${ENV_FILE}" TARANAC_VERSION)"
    printf '%s' "${v:-unknown}"
}

# The image tag .env pins. Separate from the above on purpose — the two are only
# equal when the last upgrade ran to the end, and where they differ the operator
# needs both numbers, not a choice between them.
pinned_version() {
    printf '%s' "$(env_value "${ENV_FILE}" TARANAC_VERSION)"
}

# Is this bundle dir a product node (not an HA witness, not a collector-only host)?
# Same classification cmd_apply makes; only a product node has a stack to ask about.
host_is_product() {  # [<bundle dir>] [<env file>]
    local dir="${1:-${BUNDLE_DIR}}" env="${2:-${ENV_FILE}}"
    install_is_witness "${env}" && return 1
    if install_has_collector "${dir}" && ! install_is_product "${env}"; then return 1; fi
    return 0
}

# ── Which of two versions is newer ───────────────────────────────────
# Semantic-version order, pre-releases included: 1.3.1 < 1.3.2-rc1 < 1.3.2-rc2 < 1.3.2.
# "latest" on GitHub is the newest STABLE release — a pre-release never is — so a node
# on 1.3.2-rc1, or on a release the feed has not caught up with, is AHEAD of it. The
# check used to compare with `!=` and offered that node a downgrade: "a different
# version is available: 1.3.1 … Update with ./taranac update".
# Prints -1, 0 or 1 (a < b, a = b, a > b); rc 2 when either is not a version.
version_cmp() {  # <a> <b>
    local a="${1#v}" b="${2#v}" re='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
    [[ "${a}" =~ ${re} ]] && [[ "${b}" =~ ${re} ]] || return 2
    a="${a%%+*}"; b="${b%%+*}"
    local am="${a%%-*}" bm="${b%%-*}" ap="" bp=""
    [ "${a}" = "${am}" ] || ap="${a#*-}"
    [ "${b}" = "${bm}" ] || bp="${b#*-}"
    local -a x y; local i n xa ya xp xn
    IFS=. read -r -a x <<<"${am}"; IFS=. read -r -a y <<<"${bm}"
    n=${#x[@]}; [ ${#y[@]} -gt "${n}" ] && n=${#y[@]}
    for ((i = 0; i < n; i++)); do
        xa=$((10#${x[i]:-0})); ya=$((10#${y[i]:-0}))
        [ "${xa}" -lt "${ya}" ] && { echo -1; return 0; }
        [ "${xa}" -gt "${ya}" ] && { echo 1; return 0; }
    done
    # Same release number: no pre-release ranks above any pre-release of it.
    if [ -z "${ap}" ] && [ -z "${bp}" ]; then echo 0; return 0; fi
    [ -z "${ap}" ] && { echo 1; return 0; }
    [ -z "${bp}" ] && { echo -1; return 0; }
    IFS=. read -r -a x <<<"${ap}"; IFS=. read -r -a y <<<"${bp}"
    n=${#x[@]}; [ ${#y[@]} -gt "${n}" ] && n=${#y[@]}
    for ((i = 0; i < n; i++)); do
        xa="${x[i]:-}"; ya="${y[i]:-}"
        [ -z "${xa}" ] && { echo -1; return 0; }
        [ -z "${ya}" ] && { echo 1; return 0; }
        [ "${xa}" = "${ya}" ] && continue
        if [[ "${xa}" =~ ^[0-9]+$ ]] && [[ "${ya}" =~ ^[0-9]+$ ]]; then
            [ $((10#${xa})) -lt $((10#${ya})) ] && echo -1 || echo 1
        elif [[ "${xa}" =~ ^[0-9]+$ ]]; then echo -1      # numeric identifiers rank lower
        elif [[ "${ya}" =~ ^[0-9]+$ ]]; then echo 1
        elif [[ "${xa}" =~ ^([A-Za-z-]*)([0-9]+)$ ]] && xp="${BASH_REMATCH[1]}" && xn="${BASH_REMATCH[2]}" \
             && [[ "${ya}" =~ ^([A-Za-z-]*)([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "${xp}" ]; then
            # rc2 < rc10: our tags write the number into the word, and plain semver
            # would order those as text and put rc10 first.
            [ $((10#${xn})) -lt $((10#${BASH_REMATCH[2]})) ] && echo -1 || echo 1
        else local LC_ALL=C; [[ "${xa}" < "${ya}" ]] && echo -1 || echo 1
        fi
        return 0
    done
    echo 0
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
    local cur latest pinned
    cur="$(current_version)"
    pinned="$(pinned_version)"
    info "Installed version: ${c_bold}${cur}${c_reset}"
    # An upgrade writes the files first and the pin after them, so a disagreement
    # here means exactly one thing: the last one stopped in between. Said plainly,
    # with both numbers and the one command that finishes it — the node cannot repair
    # itself and the operator cannot see this from anywhere else.
    if [ -n "${pinned}" ] && [ "${pinned}" != "${cur}" ]; then
        warn "The image tag pinned in .env is ${pinned}, but the bundle here is ${cur}."
        warn "An update did not run to the end. Finish it with:  ./taranac update --version ${cur}"
    elif [ -n "${pinned}" ] && host_is_product; then
        # Both labels agree — which is exactly the state the stand was in with every
        # container on the previous release. Ask what runs.
        local drc=0
        stack_drift "${BUNDLE_DIR}" "${ENV_FILE}" "${cur}" || drc=$?
        if [ "${drc}" = 1 ]; then
            warn "The bundle and .env say ${cur}, but the stack is not running it:"
            printf '      %s\n' "${STACK_DRIFT[@]}"
            warn "An update did not run to the end. Finish it with:  ./taranac update --version ${cur}"
        elif [ "${drc}" = 2 ]; then
            notice "Could not check which images the containers run (${STACK_DRIFT[0]:-unknown})."
        fi
    fi
    if ! latest="$(fetch_latest_version)" || [ -z "${latest}" ]; then
        notice "Could not check for updates (offline or restricted network) — this is not an error."
        notice "To update without internet: ./taranac update --from taranac-bundle-<ver>.tar.gz"
        return 0
    fi
    if [ "${latest}" = "${cur}" ]; then
        ok "Up to date (${cur})."
    elif [ "$(version_cmp "${cur}" "${latest}" 2>/dev/null)" = "1" ]; then
        ok "${cur} is newer than the latest stable release (${latest})."
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
            warn "  through a proxy, retry with 'sudo -E $(update_cmd "${ver}")' (keeps your environment)," >&2
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

# ── TARANAC_VERSION=<v> into an .env, through the file's own inode ────────────
# NOT `sed -i`: that writes a new file and renames it over this one, so the .env
# comes out with a fresh inode owned by the operator's primary group — losing the
# group 999 that lets the api container read it. A non-root operator cannot put
# that group back, so every single update asked for a sudo password, under a
# message promising it was needed once. Writing THROUGH the existing file keeps
# its inode, and with it the ownership and mode, so the group survives and the
# prompt is genuinely one-time. The witness's .env goes through here too: one line
# added or replaced, every other byte as it was.
# ── A cluster node reached through NAT, said in its .env ─────────────────────
# Since 1.3.2 `./taranac up` refuses a .env whose NODE_ADDRESS is not an address of
# the host (a copied .env, a cloned VM). A node behind NAT legitimately runs so, and
# until now its join accepted that from the environment only — so the update that
# brings the refusal writes the node's own answer down first, for a member that has
# been running at that address all along. Appended (`>>`), the inode and its group kept.
persist_nat_marker() {  # <env file>
    local env_file="$1" addr v=0
    host_is_product "$(dirname "${env_file}")" "${env_file}" && ha_is_configured "${env_file}" || return 0
    [ "$(env_value "${env_file}" ADDRESS_NOT_LOCAL_OK)" = 1 ] && return 0
    addr="$(env_value "${env_file}" NODE_ADDRESS)"
    [ -n "${addr}" ] && type cv_address_is_local >/dev/null 2>&1 || return 0
    cv_address_is_local "${addr}" || v=$?
    [ "${v}" = 1 ] || return 0
    { [ -z "$(tail -c1 "${env_file}")" ] || echo; echo "ADDRESS_NOT_LOCAL_OK=1"; } >> "${env_file}"
    notice "NODE_ADDRESS=${addr} is not an address of this host (NAT) — recorded ADDRESS_NOT_LOCAL_OK=1 in .env, so ./taranac keeps starting it."
}

write_version_pin() {  # <env file> <version>
    local env_file="$1" target_ver="$2" _pin_tmp _pin_src
    _pin_tmp="$(mktemp "${env_file}.XXXXXX")" || _pin_tmp=""
    if [ -n "${_pin_tmp}" ]; then
        chmod 600 "${_pin_tmp}"
        # An .env with no TARANAC_VERSION assignment at all (hand-rolled, or a witness
        # joined before the line existed) gets the line appended — the restart below
        # would otherwise leave a stack that the next `./taranac up -d` cannot even
        # interpolate. One in any other shape (`export TARANAC_VERSION=…`) is the
        # operator's, and is not rewritten.
        _pin_src="${env_file}"
        if ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?TARANAC_VERSION[[:space:]]*=' "${env_file}"; then
            _pin_src="$(mktemp "${env_file}.XXXXXX")"
            { cat "${env_file}"; [ -z "$(tail -c1 "${env_file}")" ] || echo; echo "TARANAC_VERSION=${target_ver}"; } > "${_pin_src}"
        fi
        if sed -E "s/^TARANAC_VERSION=.*/TARANAC_VERSION=${target_ver}/" "${_pin_src}" > "${_pin_tmp}" \
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
        [ "${_pin_src}" = "${env_file}" ] || rm -f "${_pin_src}"
    else
        sed -i -E "s/^TARANAC_VERSION=.*/TARANAC_VERSION=${target_ver}/" "${env_file}"
        ok "Pinned TARANAC_VERSION=${target_ver} in .env"
    fi
}

# ── A witness after the file refresh: its version, and its compose file ──────
# The witness runs ONE container, from a pinned upstream image (quay.io/coreos/etcd)
# that a Taranac release rarely changes, so there is normally nothing to pull and
# nothing to restart. Two things do happen here now:
#
#   * its .env gets exactly one line, TARANAC_VERSION=<v>. Before, a witness had no
#     version anywhere but its bundle files, so a re-run could never be a no-op and
#     the cluster's table could not say what the arbiter runs. The key is not one
#     install_is_product looks for, and TARANAC_ROLE=witness still decides first,
#     so the host stays a witness. Nothing else in that .env is read or written: it
#     holds none of the product's settings, on purpose.
#   * a changed docker-compose.witness.yml is APPLIED, not handed to the operator as
#     a command to type. Recreating the arbiter's etcd is a quorum event, which is
#     why this happens only here: the witness is updated last, after the navigator
#     saw every DB node finished and the ring healthy (ha_navigate), so there is no
#     DB node restarting next door to lose the quorum together with.
witness_post_update() {  # <dest bundle dir> <backup dir> <version>
    local dest="$1" backup="$2" ver="$3"
    echo
    info "This host is an HA ${c_bold}WITNESS${c_reset} — an etcd arbiter, not a Taranac node."
    notice "Refreshed the bundle's files (witness-join.sh, the witness compose file, diagnose.sh,"
    notice "HA.md). No product container was started here, and of the .env only the version"
    notice "line is written."
    [ -n "${ver}" ] && write_version_pin "${dest}/.env" "${ver}"

    local state=updated reason=""
    if [ -f "${backup}/docker-compose.witness.yml" ] \
       && ! cmp -s "${backup}/docker-compose.witness.yml" "${dest}/docker-compose.witness.yml"; then
        info "docker-compose.witness.yml changed in this version — applying it (the ring was checked healthy) ..."
        if ( cd "${dest}" && docker compose --env-file .env -f docker-compose.witness.yml up -d ); then
            local waited=0 h=""
            while [ "${waited}" -lt 120 ]; do
                h="$(docker inspect --format '{{.State.Health.Status}}' taranac-witness-etcd 2>/dev/null || true)"
                [ "${h}" = healthy ] && break
                sleep 5; waited=$((waited + 5))
            done
            if [ "${h}" = healthy ]; then
                ok "The witness etcd runs the new compose file and is healthy."
            else
                state=failed
                reason="the witness etcd is ${h:-not running} 120s after its compose file was applied. Cure: ./taranac logs etcd on this host, and ./taranac cluster status on a DB node"
                warn "${reason}"
            fi
        else
            state=failed
            reason="docker compose up -d of docker-compose.witness.yml failed here. Cure: run it by hand to see why:  docker compose --env-file .env -f docker-compose.witness.yml up -d"
            warn "${reason}"
        fi
    else
        notice "docker-compose.witness.yml is unchanged in this version — nothing to restart."
    fi
    if [ -n "${HA_KIND}" ] && type cv_record_put >/dev/null 2>&1 && [ -n "${ver}" ]; then
        cv_record_put "${state}" "${ver}" "${reason}"
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

# ── The one-shot restart (standalone nodes) ──────────────────────────────────
restart_stack() {  # <dest> <env-file> <target> <prev> <do_prune>
    local dest="$1" env_file="$2" target_ver="$3" prev_ver="$4" do_prune="$5"
    info "Restarting on ${target_ver} (migrations run automatically on api start) ..."
    TARANAC_VERSION="${target_ver}" docker compose --env-file "${env_file}" "${COMPOSE_FILES[@]}" up -d
    refresh_proxy_dns "${env_file}"

    # Done is what RUNS, not what the files and the pin say.
    local drc=0
    stack_drift "${dest}" "${env_file}" "${target_ver}" || drc=$?
    case "${drc}" in
        0) ok "Stack updated — every container runs the ${target_ver} images." ;;
        1)
            trap - ERR
            printf '\n%s\n' "${c_red}✗ update DID NOT FINISH: \`up -d\` returned, but these containers are not on ${target_ver}:${c_reset}" >&2
            printf '      %s\n' "${STACK_DRIFT[@]}" >&2
            printf '%s\n' "  ${_apply_state} Re-run  $(update_cmd "${target_ver}")  to complete it." >&2
            exit 1 ;;
        *) ok "Stack updated."
           notice "Could not confirm which images the containers run (${STACK_DRIFT[0]:-unknown}) — check with: ./taranac ps" ;;
    esac
    # LAST, and only once the stack is up on the new images: reclaiming disk is
    # housekeeping, and housekeeping must never be in a position to fail an update
    # that worked — nor remove the images a failed one still runs on.
    if [ "${do_prune}" = "1" ]; then
        prune_old_images "${env_file}" "${target_ver}" "${prev_ver}" || true
    else
        notice "Kept superseded images (--keep-images)."
    fi
}

# ── Apply an extracted bundle over the current one (runs from temp) ───
# Invoked as a fresh process from the NEW updater. Because this process executes
# from the temp extract dir, overwriting the installed bundle's own
# taranac-update.sh while it runs is safe. `dest` is the REAL installed bundle
# dir, passed explicitly — it must never be confused with `src` (the extract).
cmd_apply() {
    local src="$1" dest="$2" target_ver="$3" do_restart="$4" do_prune="${5:-1}" allow_out_of_order="0"
    shift 5 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
        case "$1" in
            --allow-out-of-order) allow_out_of_order=1; shift ;;
            *) shift ;;
        esac
    done
    [ -d "${src}" ] || die "internal: extracted bundle dir not found: ${src}"
    [ -d "${dest}" ] || die "internal: target bundle dir not found: ${dest}"
    local env_file="${dest}/.env"
    # The version is what the bundle says it is. An older updater (1.3.1 and before)
    # derived it from the tarball's FILE NAME, so a renamed bundle arrives here as
    # "rc2fix.tar.gz" — a tag that does not exist. The extract's VERSION file wins.
    local bundle_ver; bundle_ver="$(head -1 "${src}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "${bundle_ver}" ] && [ "${bundle_ver}" != "${target_ver}" ]; then
        notice "The bundle is ${bundle_ver} (its VERSION file), not '${target_ver}' as the previous updater read it from the file name — installing ${bundle_ver}."
        target_ver="${bundle_ver}"
    fi

    # ── Before the backup, before the file swap, before the pin ──────────────
    # The guard this replaces ran after all three and said "Ctrl-C now", so
    # obeying it left the node half-updated. A refusal is only a refusal if
    # nothing has happened yet. This runs from the TARGET release's code even when
    # an older updater started the update (it execs this one), so the order rules
    # are always the new release's.
    ha_kind_of "${dest}" "${env_file}"
    # One run per host. The directory itself is locked (no lock file to leave
    # behind); a second `./taranac update` here while this one runs is refused.
    if command -v flock >/dev/null 2>&1 && exec 9<"${dest}" && ! flock -n 9; then
        die "Another ./taranac update is running on this host right now. Nothing was changed.
  Let it finish (its trail: ${dest}/.taranac-update.log), then re-run this one if still needed."
    fi
    # Built before the navigator, which needs a manifest to tell the witness from a
    # DB node on a cluster where no node holds one — and published only after it says
    # go, so that a refusal changes nothing at all. A no-op whenever any copy exists.
    if [ "${HA_KIND}" = db ]; then ha_rebuild_manifest "${dest}" "${env_file}"; fi
    local nrc=0
    ha_navigate "${dest}" "${env_file}" "${target_ver}" "${allow_out_of_order}" || nrc=$?
    case "${nrc}" in
        0) ;;
        2) [ -z "${HA_REBUILT_MANIFEST}" ] || rm -rf "$(dirname "${HA_REBUILT_MANIFEST}")"; return 0 ;;
        *) [ -z "${HA_REBUILT_MANIFEST}" ] || rm -rf "$(dirname "${HA_REBUILT_MANIFEST}")"; exit 1 ;;
    esac
    # The cluster's one update slot, taken ATOMICALLY before anything is written — the
    # check above only reads, and two members can read "free" in the same second.
    if [ -n "${HA_KIND}" ] && type cv_lock_acquire >/dev/null 2>&1; then
        local lrc=0
        cv_lock_acquire "${target_ver}" || lrc=$?
        if [ "${lrc}" != 0 ]; then
            [ -z "${HA_REBUILT_MANIFEST}" ] || rm -rf "$(dirname "${HA_REBUILT_MANIFEST}")"
            if [ "${lrc}" = 1 ]; then ha_refuse_locked "${target_ver}"; exit 1; fi
            die "Could not take the cluster's update lock in etcd (${CV_ETCD_ERR:-no answer}). Nothing was changed.
  One member at a time is what keeps the cluster's quorum, so this does not go ahead without it.
  Check the ring with  ./taranac cluster status , then run:  $(cv_update_cmd "${target_ver}")"
        fi
        # Freed on every exit from here on: a refusal below, a failure, a kill.
        trap 'cv_lock_release' EXIT
    fi
    if [ "${HA_KIND}" = db ]; then ha_publish_rebuilt_manifest "${dest}"; fi
    # Every run on a cluster member ends with the cluster's table — a run that dies
    # half-way (a failed pull, a full disk) included, so the operator always sees
    # where the cluster stands and which node is next.
    HA_TARGET="${target_ver}"
    trap '_ha_exit_summary $?' EXIT
    # This member's claim on the cluster's one update slot: other members refuse to
    # start while it is fresh. Replaced by this run's own record, or put back on exit.
    if [ -n "${HA_KIND}" ] && type cv_claim >/dev/null 2>&1; then cv_claim "${target_ver}"; fi

    # A container compose left under its temporary recreate name can never be
    # recreated: compose would create the replacement under that same name and stop
    # on "Conflict" — at `up -d`, AFTER the swap and the pin. So it is settled here,
    # with the NEW bundle's helper (an old bundle has none): renamed back when that is
    # safe, and otherwise the update refuses while nothing has been touched.
    if [ "${do_restart}" = "1" ] && [ -f "${src}/container-names.sh" ]; then
        ( . "${src}/container-names.sh"; heal_container_names )
        local _cn_left
        _cn_left="$( ( . "${src}/container-names.sh"; _cn_classify ) 2>/dev/null || true)"
        if [ -n "${_cn_left}" ]; then
            die "a container is still under a temporary name (see above), and the restart this
  update ends with cannot recreate it. Nothing was changed. Resolve it as printed,
  then re-run:  $(update_cmd "${target_ver}")"
        fi
    fi

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

    # ── Nothing in this function may fail QUIETLY ────────────────────────────
    # Everything below runs under `set -euo pipefail`. A command that exits non-zero
    # ends the script, and the last thing printed used to be a green "✓ Bundle files
    # updated." — which is how an upgrade that never happened came to look like one
    # that had, on a customer's cluster. This trap makes that class impossible to hit
    # silently rather than each instance impossible to hit.
    #
    # `set -E` because without errtrace an ERR trap is not inherited by shell
    # functions, and most of the work below happens inside them.
    set -E
    # The phase AND what is true on disk at that moment, so the message says what is
    # actually the case rather than what is usually the case. The first version of
    # this trap asserted "the files are replaced, the pin is not" — and the first real
    # failure it caught was a `docker compose pull`, which then ran AFTER the pin. A
    # message that overstates is the same kind of fault as no message: the operator
    # acts on it. Each state below is one a re-run of `./taranac update` really does
    # finish from: before the swap the bundle is still the old version; after it the
    # pin is still the old one; after the pin the containers are (stack_drift).
    _apply_phase="preparing"
    _apply_state="Nothing was changed yet."
    trap 'rc=$?; printf "\n\033[31m✗ update DID NOT FINISH (exit %s) while %s. %s Re-run  %s  to complete it.\033[0m\n" "${rc}" "${_apply_phase}" "${_apply_state}" "$(update_cmd "${target_ver:-}")" >&2' ERR

    # ── Pull and verify BEFORE anything on disk changes (product nodes only) ─────
    # The pull uses the NEW bundle's compose files, straight from the extract: a release
    # may add a service or rename an image, and the old files would pull the wrong set.
    # --project-directory is the installed bundle, so relative paths (env_file: .env,
    # ./config mounts) and the project name resolve exactly as they will after the swap.
    # .env is read, never written, here: the target tag reaches compose through the
    # environment. So a pull that fails — the registry or a CDN unreachable, the disk
    # full, a digest that does not match — leaves the bundle files, the pin and the
    # running containers exactly as they were, and the re-run starts from scratch.
    local is_product=1
    host_is_product "${dest}" "${env_file}" || is_product=0
    local lock="${src}/IMAGES.lock"
    if [ "${is_product}" = 1 ] && [ "${do_restart}" = "1" ]; then
        local old_project new_images prefix
        # 1. What runs now — from the INSTALLED compose files, which describe it.
        local old_files; old_files="$( (ha_compose_files "${dest}" "${env_file}" && printf '%s\n' "${COMPOSE_FILES[@]}") 2>/dev/null || true)"
        local -a old_fargs=(); local _l
        while IFS= read -r _l; do [ -n "${_l}" ] && old_fargs+=("${_l}"); done <<<"${old_files}"
        old_project=""
        [ ${#old_fargs[@]} -gt 0 ] && old_project="$(compose_project_name "${env_file}" "${dest}" "${old_fargs[@]}")"
        _apply_phase="recording the running images"
        _apply_state="Nothing was changed yet."
        snapshot_running_images "${old_project}" "${backup}/images-before.txt" "${prev_ver}"
        _apply_state="Nothing was changed yet (only a record of the running images was written to ${backup})."

        # The NEW files, merged with the NEW overlay under HA (decided by THIS node's .env).
        ha_compose_files "${src}" "${env_file}"
        new_images="$(compose_service_images "${env_file}" "${dest}" "${target_ver}" "${COMPOSE_FILES[@]}")"
        # An HA DB node may hand its last `up -d` to the finisher container, so its
        # image travels with the release's — pulled and verified here, while nothing
        # has changed, never fetched later from a registry the host may not reach.
        local fin_images=""
        if [ "${HA_KIND}" = db ] && [ -f "${src}/docker-compose.update-finisher.yml" ]; then
            fin_images="$(finisher_env compose_service_images "${env_file}" "${dest}" "" -f "${src}/docker-compose.update-finisher.yml")"
            [ -n "${fin_images}" ] && [ -n "${new_images}" ] && new_images="${new_images}"$'\n'"${fin_images}"
        fi
        prefix="${IMAGE_PREFIX:-$(env_value "${env_file}" IMAGE_PREFIX)}"
        if [ -n "${new_images}" ] && [ -n "${prefix}" ] && [ -n "${target_ver}" ]; then
            # The guard on the environment-over-.env rule this rests on: our images
            # must render with the TARGET tag. A compose that preferred .env would render
            # the old one and "pull" what is already running.
            local stale_tags
            stale_tags="$(printf '%s\n' "${new_images}" | awk -F'\t' -v p="${prefix}/" -v t=":${target_ver}" \
                'index($2, p) == 1 { i = $2; sub(/@.*/, "", i); if (substr(i, length(i) - length(t) + 1) != t) print "      " $1 ": " $2 }')"
            if [ -n "${stale_tags}" ]; then
                printf '%s\n%s\n' "${c_red}✗ docker compose did not take TARANAC_VERSION=${target_ver} from the environment — these would pull the wrong tag:${c_reset}" "${stale_tags}" >&2
                die "Refusing to pull. Nothing was changed. Update docker compose (the plugin, v2 or newer) and re-run."
            fi
        fi

        # 2. Room on disk for what is not here yet.
        if [ -n "${new_images}" ] && [ "${TARANAC_UPDATE_SKIP_SPACE_CHECK:-0}" != "1" ]; then
            check_disk_for_pull "${new_images}" "${old_project}" \
                || die "Refusing to pull. Nothing was changed. Free space in the Docker image store and re-run, or re-run with --skip-space-check if you know the layers are mostly shared."
        fi

        # 3. Pull, target tag from the environment, .env untouched.
        ha_upgrade_notice
        type cv_beat >/dev/null 2>&1 && cv_beat
        _apply_phase="pulling the ${target_ver} images"
        info "Pulling the ${target_ver} images (the running stack is not touched yet) ..."
        TARANAC_VERSION="${target_ver}" docker compose --env-file "${env_file}" --project-directory "${dest}" "${COMPOSE_FILES[@]}" pull
        if [ -n "${fin_images}" ]; then
            finisher_env docker compose -p taranac-update-finisher --project-directory "${dest}" -f "${src}/docker-compose.update-finisher.yml" pull
        fi

        # 4. The pulled images are the ones the release was built with.
        _apply_phase="verifying the pulled images"
        if [ "${TARANAC_UPDATE_SKIP_IMAGE_VERIFY:-0}" = "1" ]; then
            warn "Image verification SKIPPED (--skip-image-verify): the pulled digests were not compared with the release's list."
        elif [ ! -f "${lock}" ]; then
            warn "This bundle carries no IMAGES.lock (built without image digests) — the pulled images were NOT verified."
        elif [ -z "${new_images}" ]; then
            die "Could not list the images of the new compose files, so they cannot be verified against IMAGES.lock. Nothing was changed except downloaded images."
        else
            verify_pulled_images "${lock}" "${prefix}" "${new_images}" \
                || die "Refusing to install images that are not the release's. Nothing was changed except downloaded images: the bundle files, .env and the running containers are as before.
  A registry mirror that re-pushed the images (docker tag + push) changes their digests; copy them with
  a digest-preserving tool instead (docker buildx imagetools create, skopeo copy --all, crane copy),
  or, if you trust that mirror, re-run with --skip-image-verify."
        fi
        keep_pinned_tags "${new_images}"
        type cv_beat >/dev/null 2>&1 && cv_beat
    fi

    # Enumerate what the FRESH bundle carries (every top-level entry, dotfiles too:
    # .env.example, .gitignore) and refresh all of it except operator-owned paths.
    # `[ -e ]` makes the globs nullglob-safe if a pattern matches nothing.
    _apply_phase="replacing the bundle files"
    _apply_state="The previous bundle files are in ${backup}; the version pin in .env is unchanged."
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
    # there (see install_is_witness above for what that cost a customer). The
    # classification was made before the pull (is_product), from the same .env.
    if [ "${is_product}" = 0 ] && install_is_witness "${env_file}"; then
        _apply_phase="finishing the witness"
        _apply_state="The bundle files are ${target_ver} (the previous ones are in ${backup}); the witness .env is unchanged."
        ha_require_lock "${target_ver}"
        witness_post_update "${dest}" "${backup}" "${target_ver}"
        if install_has_collector "${dest}"; then collector_post_update; fi
        trap - ERR
        echo
        ok "Update complete → ${target_ver:-unknown}"
        notice "Rollback if needed: restore files from ${backup}"
        if [ -n "${HA_KIND}" ] && type cv_summary >/dev/null 2>&1; then
            echo
            cv_plan "${target_ver}" >/dev/null 2>&1 && cv_summary "${target_ver}"
        fi
        return 0
    fi
    if [ "${is_product}" = 0 ]; then
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

    # Surface the settings THIS release added (non-secret, compose-defaulted) — never
    # edits the operator's .env silently. The baseline is the example just backed up,
    # i.e. the version being replaced, so the list is a per-release delta and not the
    # same permanent block on every update.
    # `|| true` is the belt to the guards' braces, and it is the part that
    # generalises: this call sits between the file swap and the version pin, and
    # NOTHING advisory belongs in a position where it can abort an upgrade
    # half-done. The three inputs that used to do exactly that are fixed above;
    # this is what stops the fourth one being found by a customer.
    report_new_env_keys "${src}/.env.example" "${env_file}" "${backup}/.env.example" "${target_ver}" || true

    _apply_phase="writing the version pin into .env"

    # Pin the image tag in .env — only now, after the images are pulled and verified,
    # so a pin never names images this host does not have. This is the ONE version
    # knob — the app's reported version is baked into the images (from VERSION at
    # build) and is never carried in .env.
    if [ -n "${target_ver}" ] && [ -f "${env_file}" ]; then
        write_version_pin "${env_file}" "${target_ver}"
        persist_nat_marker "${env_file}"
        # Restarting on a pin that did not take would run the new images now and the
        # OLD ones on the next `./taranac up -d` — so with a restart ahead this is a
        # stop, said with the one line that fixes it.
        if [ "${do_restart}" = "1" ] && [ "$(env_value "${env_file}" TARANAC_VERSION)" != "${target_ver}" ]; then
            die "Could not pin TARANAC_VERSION in .env (is it written as 'export TARANAC_VERSION=…'?). The ${target_ver} images are pulled and verified and the bundle files are in place; the containers were NOT restarted.
  Set  TARANAC_VERSION=${target_ver}  in .env by hand, then re-run  $(update_cmd "${target_ver}")  to finish."
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
    # And the operator's config/ material the archive also carries — tls.key,
    # the Firebase key, and under HA the etcd CA key that is the cluster's only
    # way to admit or replace a node. Written 0600 by their generators and never
    # granted to the api's group, they were skipped by every backup, silently
    # (a customer's 1.2.7 HA deployment, 2026-08-23). The updater is again the
    # load-bearing half: installs in the field never re-run install.sh.
    type secure_host_config >/dev/null 2>&1 && secure_host_config "${dest}/config"

    if [ "${do_restart}" = "1" ]; then
        # 6. Restart on what was pulled and verified. TARANAC_VERSION goes into the
        # environment here too, so an operator shell that happens to export an older
        # one cannot start different images than the ones just checked.
        ha_compose_files "${dest}"                 # merges the just-refreshed HA overlay under HA
        _apply_phase="starting the stack on ${target_ver}"
        _apply_state="The bundle files and the pin in .env are ${target_ver}, but containers may still run the previous images (recorded in ${backup}/images-before.txt)."
        # An HA DB node starts its api first and hands the rest to a finisher when the
        # api has to wait for the leader; every other node restarts in one `up -d`.
        ha_require_lock "${target_ver}"
        if [ "${HA_KIND}" = db ] && type cv_start_finisher >/dev/null 2>&1; then
            # The bootstrap lists are read only by what this restart starts — so they
            # are brought up to the cluster's here, and only here (see above).
            if ! ha_refresh_bootstrap "${dest}" "${env_file}"; then
                trap - ERR
                printf '%s\n' "  The bundle files and the pin are ${target_ver}; the containers still run the previous version." \
                              "  Free space on this host ( df -h ${dest} ), then finish with:  $(update_cmd "${target_ver}")" >&2
                exit 1
            fi
            ha_db_restart "${dest}" "${env_file}" "${target_ver}" "${prev_ver}" "${do_prune}" "${backup}"
        else
            restart_stack "${dest}" "${env_file}" "${target_ver}" "${prev_ver}" "${do_prune}"
        fi
    else
        notice "Skipped image pull / restart (--no-restart): the containers still run the previous version."
        notice "Finish later with  ./taranac update --version ${target_ver:-<version>}  (pulls, verifies, restarts)."
    fi

    # A core host may also run a collector beside it — same rule as on a collector-only
    # host: its version follows the core, through its own tool, never from here.
    if install_has_collector "${dest}"; then collector_post_update; fi

    # The window is closed: the pin is written and the stack is up, so a later
    # failure is no longer the half-done kind this trap exists to announce.
    trap - ERR

    echo
    ok "Update complete → ${target_ver:-unknown}"
    notice "Rollback if needed: restore files from ${backup}"
    # Under HA the run ends with where to go next and the whole cluster — read back
    # from etcd after this node's own record was written, so it is the live answer.
    if [ "${HA_KIND}" = db ] && [ "${do_restart}" = "1" ] && type cv_plan >/dev/null 2>&1; then
        ha_db_epilogue "${target_ver}"
    fi
}

HA_TARGET=""
_ha_exit_summary() {  # <exit status>
    type cv_release >/dev/null 2>&1 && cv_release
    [ "$1" != 0 ] && [ -n "${HA_KIND}" ] && [ "${CV_SHOWN:-0}" != 1 ] || return 0
    type cv_plan >/dev/null 2>&1 || return 0
    echo >&2
    if cv_plan "${HA_TARGET}" >/dev/null 2>&1; then cv_summary "${HA_TARGET}" >&2; fi
    return 0
}

# Placeholders that let compose render the finisher's file outside the finisher
# (its variables are required, and only cv_start_finisher knows the real values):
# for the pull and the digest check, which need the image and nothing else.
finisher_env() {
    FINISHER_DIR="${FINISHER_DIR:-/nonexistent}" FINISHER_VERSION="${FINISHER_VERSION:-0}" \
    FINISHER_KEY="${FINISHER_KEY:-/}" FINISHER_RECORD="${FINISHER_RECORD:-none}" "$@"
}

# Keys documented inside the @ha-only markers of a .env.example — settings only a
# CLUSTER reads. Marked in the example itself so this list has ONE source of truth
# and cannot drift from the file it describes.
ha_only_env_keys() {  # $1 = a .env.example
    [ -f "$1" ] || return 0
    # An example with no @ha-only block is not an error; it is an example with no
    # cluster-only settings. Without the guard `grep` exits 1, pipefail carries it
    # to the caller's assignment, and `set -e` ends the upgrade there.
    sed -n '/^# @ha-only:begin/,/^# @ha-only:end/p' "$1" \
        | grep -oE '^[A-Z_][A-Z0-9_]*=' | sort -u || true
}

# Report the settings THIS RELEASE added that the operator's .env does not set.
#
# Deliberately a DELTA between the old and the new .env.example, not "every key the
# example has and the .env lacks". The latter is what this did until 1.2.8, and it
# never shrank: the correct operator action for a defaulted setting is to add
# NOTHING, so the same block reappeared on every single update (a demo install on
# 1.2.6 → 1.2.7 was told about 13 settings, none of which that release added — they
# had all shipped by 1.2.3). A list that repeats forever is read as a chore, then
# stops being read at all, and the one release that really does add a setting says
# it in the same breath as the noise. The previous example is the version being
# replaced — cmd_apply backed it up moments ago, before overwriting the bundle.
#
# No baseline (a hand-assembled install, or an upgrade from a bundle that predates
# .env.example) → fall back to the full comparison: showing the whole list once is
# better than silently dropping a setting the operator may need.
report_new_env_keys() {
    local new_example="$1" env_file="$2" old_example="${3:-}" target_ver="${4:-}"
    [ -f "${new_example}" ] || return 0
    [ -f "${env_file}" ] || return 0
    local keys_new keys_have keys_old missing baseline=1
    # `|| true` on every one of these. Under `set -euo pipefail` a grep that
    # matches nothing exits 1 and takes the whole assignment — and the enclosing
    # script — with it. An .env with no plain `KEY=` line (every key `export`-
    # prefixed) is enough to trigger it, and this function is INFORMATIONAL: an
    # empty answer is a legitimate answer, never a reason to stop an upgrade.
    keys_new="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${new_example}" | sort -u || true)"
    keys_have="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${env_file}" | sort -u || true)"
    if [ -n "${old_example}" ] && [ -f "${old_example}" ]; then
        keys_old="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "${old_example}" | sort -u || true)"
    else
        keys_old=""; baseline=0
    fi
    # `grep -Fxv -f`, not `comm`. comm requires BOTH inputs to be sorted in the
    # current collation and exits 1 the moment they are not — and this function
    # sorts, then strips the trailing `=` with `sed`, which under C collation can
    # reverse the order of a pair like PROXY= / PROXY2= (`2` < `=` by byte, but
    # `PROXY` < `PROXY2` once stripped). Set difference does not need an ordering,
    # so it should not have been asked for one.
    #
    # `|| true` on each: grep exits 1 when nothing survives the filter, which is
    # the ordinary "this release added no new keys" case and not an error.
    missing="$(printf '%s\n' "${keys_new}" \
               | grep -Fxv -f <(printf '%s\n' "${keys_have}") \
               | grep -Fxv -f <(printf '%s\n' "${keys_old}") | sed 's/=$//' || true)"
    [ -n "${missing}" ] || return 0

    # A standalone node is never asked to read about etcd, Patroni or pg_hba scope.
    # Counted and stated, not silently dropped — hiding is a lie, and an operator who
    # IS about to convert to HA must know the settings exist.
    local hidden=0
    if ! ha_is_configured "${env_file}"; then
        local ha_keys kept before after
        ha_keys="$(ha_only_env_keys "${new_example}" | sed 's/=$//' || true)"
        if [ -n "${ha_keys}" ]; then
            kept="$(printf '%s\n' "${missing}" | grep -Fxv -f <(printf '%s\n' "${ha_keys}") || true)"
            # `wc -l` on a here-string, never `grep -c` — grep exits 1 on zero matches
            # and this function runs under `set -e`.
            before="$(printf '%s\n' "${missing}" | sed '/^$/d' | wc -l)"
            after="$(printf '%s\n' "${kept}" | sed '/^$/d' | wc -l)"
            hidden=$(( before - after ))
            missing="${kept}"
        fi
    fi

    [ -n "${missing}" ] || [ "${hidden}" -gt 0 ] || return 0
    echo
    if [ -n "${missing}" ]; then
        notice "New optional settings in ${target_ver:-this version} — defaults already apply, nothing to do:"
        printf '      %s\n' ${missing}
        notice "Add one to .env only to override its default"
        notice "(e.g. TRUSTED_PROXY_HOPS=2 when the API sits behind two reverse proxies)."
        if [ "${baseline}" = "0" ]; then
            notice "(No previous .env.example to compare against — listing everything this version documents.)"
        fi
    fi
    if [ "${hidden}" -gt 0 ]; then
        notice "${hidden} cluster-only setting(s) not listed — this node is standalone (see .env.example, HA block)."
    fi
    echo
}

# The navigator, asked by `update` before it downloads or asks "Proceed?". Returns
# 1 for "nothing to do" (a finished witness); exits on a refusal.
ha_precheck() {  # <target> <allow 0|1>
    ha_kind_of "${BUNDLE_DIR}" "${ENV_FILE}"
    [ -n "${HA_KIND}" ] && [ "$2" != "1" ] && [ -n "$1" ] || return 0
    local nrc=0
    ha_navigate "${BUNDLE_DIR}" "${ENV_FILE}" "$1" 0 || nrc=$?
    case "${nrc}" in
        0) return 0 ;;
        2) return 1 ;;
        *) exit 1 ;;
    esac
}

# ── A plain `update` in the middle of a rollout to a newer version ───────────
# "The latest" is the latest STABLE release. During a rollout to a release candidate
# (or to a release newer than the feed) some members already run that newer version;
# a plain update here would aim this node at the older stable one, and the navigator
# would then hand the nodes already ahead a downgrade. The rollout's version is the
# only right target, and it is named.
ha_refuse_behind_rollout() {  # <target from the feed>
    local target="$1" i newest="" who=""
    ha_kind_of "${BUNDLE_DIR}" "${ENV_FILE}"
    [ -n "${HA_KIND}" ] && type cv_plan >/dev/null 2>&1 || return 0
    cv_init "${BUNDLE_DIR}" "${ENV_FILE}" "${HA_KIND}"
    cv_plan "${target}" >/dev/null 2>&1 || return 0
    for i in "${!M_NAME[@]}"; do
        [ -n "${M_VER[i]:-}" ] || continue
        if [ "$(version_cmp "${M_VER[i]}" "${target}" 2>/dev/null)" = "1" ] \
           && { [ -z "${newest}" ] || [ "$(version_cmp "${M_VER[i]}" "${newest}" 2>/dev/null)" = "1" ]; }; then
            newest="${M_VER[i]}"; who="${M_NAME[i]}"
        fi
    done
    [ -n "${newest}" ] || return 0
    echo >&2
    printf '%s\n' "${c_red}✗ NOT updating: this cluster is in the middle of a rollout to ${newest} (${who} runs it).${c_reset}" \
        "  A plain update means the latest stable release, ${target} — older than the rollout, so it" \
        "  would take this node away from the cluster's version and hand the nodes already on" \
        "  ${newest} a downgrade. Nothing was changed." \
        "  Continue the rollout:" \
        "      $(update_cmd "${newest}")" >&2
    exit 1
}

# ── A downgrade on a cluster member ──────────────────────────────────────────
# The schema is only ever migrated forwards. A release older than the one whose
# migrations already ran cannot start its api against that schema: on an HA node the
# api then waits (the finisher's 24 h ceiling) with AAA and the UI down, and nothing
# the updater can do brings it back except going forward again. The same order is
# enforced as for an upgrade, so nothing else stops it — this asks, in words.
ha_confirm_downgrade() {  # <target>
    local target="$1" cur reply
    cur="$(current_version)"
    [ "$(version_cmp "${cur}" "${target}" 2>/dev/null)" = "1" ] || return 0
    ha_is_configured "${ENV_FILE}" && host_is_product || return 0
    echo >&2
    printf '%s\n' "${c_yellow}! DOWNGRADE on an HA cluster member: ${cur} → ${target}.${c_reset}" \
        "  If ${cur} (or any release between) carried a database migration, the ${target} api cannot" \
        "  start against the newer schema: it waits forever (the finisher gives up after 24 h)," \
        "  and AAA and the UI on every node you downgrade stay down. The schema is never" \
        "  migrated backwards. Only downgrade to a release with the same schema — otherwise" \
        "  restore the backup taken before the update (Backup & Recovery) instead." >&2
    printf '%s' "  Type DOWNGRADE to continue: " >&2
    read -r reply || reply=""
    [ "${reply}" = "DOWNGRADE" ] || die "Not confirmed — nothing was changed."
}

# ── Unpack a bundle tarball into <workdir>/extract → prints the bundle's dir ──
# Flat or with one top-level dir (the release's is taranac/) — normalised here.
extract_bundle() {  # <tarball> <workdir>
    local extract="$2/extract" inner
    mkdir -p "${extract}"
    tar -xzf "$1" -C "${extract}" || die "Could not unpack $1 — not a gzip tarball, or a damaged one. Nothing was changed."
    if [ ! -e "${extract}/taranac-update.sh" ]; then
        inner="$(find "${extract}" -maxdepth 2 -name taranac-update.sh -printf '%h\n' 2>/dev/null | head -1)"
        [ -n "${inner}" ] && extract="${inner}"
    fi
    [ -e "${extract}/taranac-update.sh" ] || die "bundle does not contain taranac-update.sh — wrong tarball?"
    printf '%s' "${extract}"
}

# ── Is this node already on <target>? ────────────────────────────────
# 0 = yes, and it was handled here (said, missing containers started, the cluster
# table printed) — the caller stops; 1 = go on with the update. Shared by the
# online path and --from: a re-run with the same bundle file is the same question
# as a re-run with --version, and it used to make a new backup and swap the files
# again (rc2 acceptance, 11.10.2026).
already_on_target() {  # <target>
    local target="$1"
    # "Nothing to do" needs THREE answers to agree with the target: the bundle's
    # VERSION, the pin in .env, and what the containers actually run. The first
    # two are labels. After an upgrade whose pull or `up -d` failed they both said
    # 1.3.0 while every container ran 1.2.8, and this answered "Already on 1.3.0"
    # to the one command that would have finished it (27.09.2026). So on a product
    # node the daemon is asked; a witness or a collector-only host has no product
    # stack, and there the two labels are the whole answer.
    local cur pinned; cur="$(current_version)"; pinned="$(pinned_version)"
    [ "${target}" = "${cur}" ] && [ "${target}" = "${pinned}" ] || return 1
    local drc=0
    if host_is_product; then
        stack_drift "${BUNDLE_DIR}" "${ENV_FILE}" "${target}" || drc=$?
    fi
    # The right images are not the whole answer: a container compose created
    # and never started runs them too. Under HA that is the awaiting-schema
    # state, and what finishes it is the finisher — never a blocking `up -d`
    # from here, which would wait on the api exactly as the old update did.
    local notrun=""
    ha_kind_of "${BUNDLE_DIR}" "${ENV_FILE}"
    if [ -n "${HA_KIND}" ] && type cv_plan >/dev/null 2>&1; then
        cv_init "${BUNDLE_DIR}" "${ENV_FILE}" "${HA_KIND}"
        cv_plan "${target}" >/dev/null 2>&1 || true
    fi
    if [ "${drc}" = 0 ] && [ "${HA_KIND}" = db ] && ha_ensure_finisher "${BUNDLE_DIR}" "${target}"; then
        echo; cv_summary "${target}"
        return 0
    fi
    if [ "${drc}" = 0 ] && host_is_product; then
        notrun="$(stack_not_running "${BUNDLE_DIR}" "${ENV_FILE}")"
    fi
    # A witness whose own record is not "updated" (its compose file failed to
    # apply last time) is not finished either: run the update again.
    if [ "${drc}" = 0 ] && [ "${HA_KIND}" = witness ] && [ -n "${CV_SELF_IDX:-}" ] \
       && [ "${M_STATE[CV_SELF_IDX]:-}" != updated ]; then
        notrun="witness	its update record is '${M_STATE[CV_SELF_IDX]:-missing}'"
    fi
    # A product node whose images are right only needs its containers started:
    # never a re-apply (a new backup, the whole stack recreated, the database
    # restarted) for what is a Created or stopped container. A witness's notrun
    # is its record, not its stack — its compose file failed last time, and
    # that is re-applied below.
    if [ "${drc}" = 0 ] && [ -n "${notrun}" ] && host_is_product; then
        warn "The bundle, the pin and the images say ${cur}, but these containers are not running:"
        printf '%s\n' "${notrun}" | sed -e 's/\t/: /' -e 's/^/      /'
        info "Starting only what is not running — nothing is recreated or re-applied ..."
        local smrc=0
        stack_start_missing "${BUNDLE_DIR}" "${ENV_FILE}" "${target}" || smrc=$?
        type cv_lock_release >/dev/null 2>&1 && cv_lock_release
        [ "${smrc}" = 3 ] && exit 1
        if [ "${smrc}" = 0 ]; then
            notrun="$(stack_not_running "${BUNDLE_DIR}" "${ENV_FILE}")"
            if [ -n "${notrun}" ]; then
                if [ "${HA_KIND}" = db ] && cv_finisher_running 2>/dev/null; then
                    ok "Started the api; the finisher starts the rest once it is healthy: $(printf '%s\n' "${notrun}" | cut -f1 | paste -sd' ' -)."
                else
                    warn "Still not running: $(printf '%s\n' "${notrun}" | cut -f1 | paste -sd' ' -). See why:  ./taranac ps  then  ./taranac logs --tail 100 <service>"
                fi
                if [ -n "${HA_KIND}" ] && [ ${#M_NAME[@]} -gt 0 ] 2>/dev/null; then
                    cv_plan "${target}" >/dev/null 2>&1 || true
                    echo; cv_summary "${target}"
                fi
                return 0
            fi
            ok "Started them — every container of this node runs ${cur}."
        else
            warn "docker compose up -d --no-recreate did not start them — re-applying ${cur}."
        fi
    fi
    case "${drc}" in
        0)  if [ -z "${notrun}" ]; then
                ok "Already on ${cur} — the bundle, the pin in .env and the running containers agree. Nothing to do."
                # The one thing a finished DB node may still lack is its own
                # record in etcd (the put failed at the end of its run). It runs
                # the target — checked just above — so it says so now; this is
                # the cure that failure prints.
                if [ "${HA_KIND}" = db ] && [ -n "${CV_SELF_IDX:-}" ] \
                   && { [ "${M_VER[CV_SELF_IDX]}" != "${target}" ] || [ "${M_STATE[CV_SELF_IDX]}" != updated ]; } \
                   && cv_record_put updated "${target}" && [ "${CV_RECORD_OK}" = 1 ]; then
                    ok "Recorded this node's version in etcd (state=updated) — nothing was restarted."
                    cv_plan "${target}" >/dev/null 2>&1 || true
                fi
                notice "To re-apply ${cur} anyway:  ./taranac update --version ${cur} --repair"
                if [ -n "${HA_KIND}" ] && [ ${#M_NAME[@]} -gt 0 ] 2>/dev/null; then echo; cv_summary "${target}"; fi
                return 0
            fi
            warn "The bundle, the pin and the images say ${cur}, but these containers are not running:"
            printf '%s\n' "${notrun}" | sed -e 's/\t/: /' -e 's/^/      /'
            info "Finishing the update to ${cur}." ;;
        1)  warn "The bundle and the pin in .env say ${cur}, but the stack is not running it:"
            printf '      %s\n' "${STACK_DRIFT[@]}"
            info "Finishing the update to ${cur}." ;;
        *)  warn "Could not check which images the containers run (${STACK_DRIFT[0]:-unknown}) — re-applying ${cur} to be sure." ;;
    esac
    return 1
}

# ── `update` orchestration ───────────────────────────────────────────
cmd_update() {
    local target="" from="" do_restart=1 assume_yes=0 check_only=0 do_prune=1 allow_out_of_order=0 repair=0
    local confirm_word=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) target="${2:-}"; shift 2 ;;
            # Re-apply the version this node already runs (new backup, files swapped,
            # stack recreated). It used to be what -y did as a side effect, so a
            # script passing -y to skip the prompt re-applied a whole release.
            --repair)  repair=1; shift ;;
            --confirm) confirm_word="${2:-}"; shift 2 ;;
            --from)    from="${2:-}"; shift 2 ;;
            --no-restart) do_restart=0; shift ;;
            --keep-images) do_prune=0; shift ;;
            --allow-out-of-order) allow_out_of_order=1; shift ;;
            # Carried to the re-exec'd updater through the environment, not as new
            # --apply-internal arguments: that signature is called by OLDER updaters
            # and must only ever grow optional tails. The same variables therefore
            # work on the first hop too, where the old updater does not know the flag:
            #   TARANAC_UPDATE_SKIP_IMAGE_VERIFY=1 ./taranac update
            --skip-image-verify) export TARANAC_UPDATE_SKIP_IMAGE_VERIFY=1; shift ;;
            --skip-space-check)  export TARANAC_UPDATE_SKIP_SPACE_CHECK=1; shift ;;
            --yes|-y)  assume_yes=1; shift ;;
            --check)   check_only=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done

    # A witness that has left its cluster (witness-join.sh --leave) has no .env any
    # more, only the retired copy. Nothing of ours runs here, and without this the
    # host would classify as a PRODUCT node (no witness marker, no running witness)
    # and the update would try to bring the product stack up on it.
    if host_left_cluster; then
        ok "This host left its cluster as the witness ($(basename "${HOST_LEFT_ENV}")) — nothing of Taranac runs here, so there is nothing to update."
        notice "To make it a witness again, run the command './taranac cluster add-witness' prints on a database node."
        return 0
    fi

    if [ "${check_only}" = "1" ]; then
        cmd_check
        return 0
    fi

    # --allow-out-of-order skips the cluster's order, which exists because the wrong
    # order takes AAA down cluster-wide (a replica cannot run before its schema, a
    # leader must not migrate under replicas that cannot follow). A flag typed "just in
    # case" is not a decision; a word typed is.
    if [ "${allow_out_of_order}" = "1" ] && [ "${confirm_word}" != "OUT-OF-ORDER" ]; then
        local ooo=""
        if [ -t 0 ]; then
            printf '%s\n' "${c_yellow}! --allow-out-of-order skips the cluster's update order.${c_reset}" \
                "  The order (replicas, then the leader, then the witness) is what keeps AAA up while" \
                "  the cluster moves; skipped, a node can start on a schema it cannot run, or the leader" \
                "  migrate under replicas that cannot follow. Use it only on a cluster you are repairing." >&2
            printf '%s' "  Type OUT-OF-ORDER to continue: " >&2
            read -r ooo || ooo=""
        fi
        [ "${ooo}" = "OUT-OF-ORDER" ] || die "--allow-out-of-order needs a typed confirmation — nothing was changed.
  Run it in a terminal and type OUT-OF-ORDER, or add  --confirm OUT-OF-ORDER  to the command."
    fi

    command -v curl >/dev/null 2>&1 || [ -n "${from}" ] || die "curl is required for online updates (or use --from)."
    command -v tar  >/dev/null 2>&1 || die "tar is required."

    local workdir tarball="" extract=""
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${workdir}'" EXIT

    if [ -n "${from}" ]; then
        [ -f "${from}" ] || die "bundle tarball not found: ${from}"
        tarball="${from}"
        # The version is the bundle's own VERSION file, never its file name: an
        # air-gapped site copies and renames files, and `--from /tmp/rc2fix.tar.gz`
        # once made the target "rc2fix.tar.gz" — the pull asked for that tag and every
        # hint printed it (rc2 acceptance). So the bundle is opened first.
        info "Reading the bundle ${tarball} ..."
        extract="$(extract_bundle "${tarball}" "${workdir}")" || exit 1
        local bver; bver="$(head -1 "${extract}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
        [ -n "${bver}" ] || die "${tarball} has no VERSION file — not a Taranac bundle, or a damaged one. Nothing was changed."
        if [ -n "${target}" ] && [ "${target}" != "${bver}" ]; then
            warn "--version ${target} ignored: ${tarball} is the ${bver} bundle (its own VERSION file says so)."
        fi
        target="${bver}"
        info "Using local bundle: ${tarball} (version ${target})"
    else
        if [ -z "${target}" ]; then
            target="$(fetch_latest_version)" || die "Could not reach the update server. Use --from for an offline update."
            [ -n "${target}" ] || die "Could not determine the latest version."
            # "The latest" is the newest STABLE release; a node on a pre-release or on a
            # release newer than the feed is ahead of it, and a plain `update` must never
            # take it backwards. An explicit --version still can.
            if [ "$(version_cmp "$(current_version)" "${target}" 2>/dev/null)" = "1" ]; then
                ok "$(current_version) is newer than the latest stable release (${target}) — nothing to update."
                notice "To install a specific version anyway:  ./taranac update --version <version>"
                return 0
            fi
            ha_refuse_behind_rollout "${target}"
        fi
    fi

    # The same question for both paths: a node already on the target makes no backup,
    # swaps no file and restarts nothing — it only starts what is not running.
    # `--repair` is the way to re-apply the current version anyway; `-y` only answers
    # the prompt.
    local cur; cur="$(current_version)"
    if [ "${repair}" != "1" ] && already_on_target "${target}"; then return 0; fi

    # The cluster's order, asked BEFORE the download and the "Proceed?" — a run on
    # the wrong machine is told where to start without fetching anything. The
    # re-exec'd updater asks again (it is the one that must not write on a refusal),
    # and an --allow-out-of-order run leaves its trail there, once.
    ha_confirm_downgrade "${target}"
    ha_precheck "${target}" "${allow_out_of_order}" || return 0
    info "Updating ${cur} → ${target}"
    if [ -z "${tarball}" ]; then
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
  $(update_cmd "${target}"), or fetch taranac-bundle-${target}.tar.gz on a machine that can
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

    if [ -z "${extract}" ]; then
        info "Extracting bundle ..."
        extract="$(extract_bundle "${tarball}" "${workdir}")" || exit 1
    fi

    # Re-exec the NEW updater to apply, so it never overwrites the file it is
    # currently executing. Pass src (extract), dest (this installed bundle), the
    # resolved version, and the restart flag through.
    # NOTE: the updater that runs cmd_apply is the NEW one, invoked by the OLD one — so
    # trailing arguments must stay optional on the receiving side. A pre-cleanup updater
    # passes only four; cmd_apply defaults do_prune to 1, which is what we want: the very
    # first update onto this version also clears whatever earlier releases piled up.
    local -a apply_flags=(); [ "${allow_out_of_order}" = "1" ] && apply_flags=(--allow-out-of-order)
    exec bash "${extract}/taranac-update.sh" --apply-internal "${extract}" "${BUNDLE_DIR}" "${target}" "${do_restart}" "${do_prune}" ${apply_flags[@]+"${apply_flags[@]}"}
}

# ── Entry point ──────────────────────────────────────────────────────
case "${1:-}" in
    check|version) cmd_check ;;
    update)        shift; cmd_update "$@" ;;
    --apply-internal)  # internal: invoked by the freshly-extracted updater (src dest ver restart [prune])
        shift; cmd_apply "$@" ;;
    *) die "usage: taranac-update.sh {version|update [--version X|--from FILE|--check|--repair|--no-restart|--keep-images|--skip-image-verify|--skip-space-check|--allow-out-of-order --confirm OUT-OF-ORDER|--yes]}" ;;
esac
