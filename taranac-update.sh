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

# The product's own notion of "recent": three missed 30s heartbeats
# (service_health.STALE_AFTER_SECONDS). There must be ONE such number in the
# product, so this reads the same as the wizard's preflight rather than inventing
# a second window that could quietly be wider.
HA_REPORT_STALE_AFTER=90

# How long to WAIT for a peer whose answer is merely out of date, before refusing.
#
# Found by the lifecycle scenario, not by reasoning: upgrading the replica first —
# the correct order — restarts its api, and the primary is then upgraded moments
# later, while that replica's next heartbeat has not landed. The guard refused, so
# the primary never upgraded, and the run ended with a cluster split across
# versions BECAUSE of the thing meant to prevent exactly that. A refusal that fires
# on the correct sequence is not a safety feature.
#
# Generous on purpose: it costs nothing when the cluster is healthy (the loop
# breaks the moment every peer is fresh) and everything when it is too short — a
# peer whose api is still coming back from ITS upgrade is the normal case here,
# not an exception, and the machine that has to wait for it is the one whose
# upgrade must come last anyway.
HA_REPORT_WAIT_S="${TARANAC_UPDATE_ORDER_WAIT_S:-180}"

# Every OTHER active member, with the version it is RUNNING and how old that
# answer is.
#
# The version comes from node_config_reports, which every node UPSERTs on its own
# heartbeat from its own process environment — so it is what that node is running,
# not what its .env says on disk. That distinction is the point: an upgrade writes
# the pin before it pulls, so a node whose pin moved but whose containers were
# never recreated still reports the OLD version here, which is the truth.
#
# The row is replicated, so any member can read every other member's without a
# peer request that could hang exactly when a node is in trouble.
# `-tA` and psql's DEFAULT `|` separator, deliberately — no -F at all.
#
# This first read `-tAF'\t'`, and bash hands psql the two characters backslash-t,
# not a tab: psql does not interpret escapes there. Every row then came back as
# one unsplittable field, every peer was classified "never reported", and the
# primary refused its own upgrade forever. The unit tests did not see it because
# their psql stub printed REAL tabs — a stub more capable than the thing it stood
# in for. The lifecycle scenario, which runs the real psql, caught it.
#
# `|` cannot occur in a node name (cluster-manifest.py's NAME_RE is letters,
# digits, dot, dash, underscore) nor in a version, so the default separator needs
# no quoting and there is nothing left to get wrong.
ha_peer_versions() {  # <env-file> → name|version|age_seconds, one per peer
    local env_file="$1" self
    self="$(env_value "${env_file}" TARANAC_NODE_NAME)"
    docker exec taranac-db psql -U taranac -d taranac -tA -c "
        SELECT n.name,
               COALESCE(r.config_values->>'TARANAC_VERSION', ''),
               COALESCE(EXTRACT(EPOCH FROM (now() - r.updated_at))::int, -1)
          FROM cluster_nodes n
          LEFT JOIN node_config_reports r ON r.node_id = n.id
         WHERE n.status = 'active' AND n.name <> '${self}'
         ORDER BY n.name" 2>/dev/null
}

# ── The gate that replaces a warning about ORDER ─────────────────────────────
# What it used to ask was "am I the primary?", and print "update the replicas
# first, Ctrl-C now" if so. Three things were wrong with that, and a customer met
# all three at once on 15 August:
#
#   * it asked about the order of ACTIONS, and an order warning is powerless the
#     moment an earlier action lied about having succeeded — his replica's upgrade
#     had died silently, so he had done the right thing and it had not taken;
#   * it was a notice, not a refusal: safety rested on a human reading fast enough
#     to press Ctrl-C;
#   * and it ran AFTER the bundle files and the version pin were written, so
#     obeying it left a half-updated node.
#
# The question safety actually turns on is "is every other member already on the
# target version?" — and that one is answerable, from a replicated table, before
# anything is written.
ha_require_upgrade_order() {  # <env-file> <target-version> <allow-override 0|1>
    local env_file="$1" target="$2" allow="$3"
    # Asked of the .env, not of HA_ACTIVE: that global is set by ha_compose_files,
    # which runs in the restart block far below this gate. Depending on it would
    # make the guard silently inert if the order ever changed.
    ha_is_configured "${env_file}" || return 0
    [ -n "${target}" ] || return 0

    local role; role="$(node_role)"
    # A replica is never blocked: replicas first is the correct order, and blocking
    # one would block the only sequence that works.
    if [ "${role}" = "replica" ]; then
        notice "This node is a REPLICA — the correct one to update first."
        return 0
    fi
    # Refuse only on POSITIVE evidence. If the local database did not answer, this
    # node's role is unknown — and so, very likely, is the health of the cluster the
    # operator is trying to repair by upgrading. Blocking there would turn the guard
    # into the obstacle, and it would block replicas too (an unreachable database
    # answers "unknown", not "replica"). Say what did not happen, and let it run.
    if [ "${role}" != "leader" ]; then
        warn "Could not tell whether this node is the primary — the local database did not answer."
        notice "The cluster-readiness check did NOT run. Update the PRIMARY last, and confirm the"
        notice "other members are already on ${target} first:  ./taranac cluster status"
        return 0
    fi

    # Polled, not slept through, and only while the ONLY thing missing is freshness.
    # A peer that is definitively on the wrong version needs no waiting — that answer
    # will not improve.
    local rows="" waited=0 announced=0
    local -a behind=() unknown=()
    local name ver age
    while :; do
        rows="$(ha_peer_versions "${env_file}")"
        behind=(); unknown=()
        while IFS='|' read -r name ver age extra; do
            [ -n "${name}" ] || continue
            # A row that does not split into exactly three fields is not a peer we
            # know nothing about — it is an answer we failed to READ, and saying so
            # is the difference between a useful refusal and a mystifying one.
            if [ -n "${extra}" ] || [ -z "${age}" ]; then
                unknown+=("${name}|its row could not be parsed — report this")
            elif [ -z "${ver}" ] || [ "${age}" = "-1" ]; then
                unknown+=("${name}|never reported")
            elif [ "${age}" -gt "${HA_REPORT_STALE_AFTER}" ] 2>/dev/null; then
                unknown+=("${name}|last reported ${ver} — ${age}s ago, too old to trust")
            elif [ "${ver}" != "${target}" ]; then
                behind+=("${name}|${ver}")
            fi
        done <<EOF
${rows}
EOF
        # Wait on BOTH conditions, not just staleness. A peer that was upgraded a
        # moment ago has a report that is perfectly FRESH and still carries the old
        # version — it published just before its api was recreated. Waiting only for
        # staleness therefore refused instantly in the one sequence the runbook
        # prescribes, which the lifecycle scenario caught: node-2's row read
        # `9.9.1 | 56s`, fresh and behind, so the loop never waited and the primary
        # never upgraded. Costs nothing when the cluster is ready — the loop breaks
        # on the first pass — and turns a false refusal into a bounded pause.
        [ ${#unknown[@]} -gt 0 ] || [ ${#behind[@]} -gt 0 ] || break
        [ "${waited}" -lt "${HA_REPORT_WAIT_S}" ] || break
        if [ "${announced}" = "0" ]; then
            notice "Waiting up to ${HA_REPORT_WAIT_S}s for every member to report ${target}."
            notice "A node publishes every 30s, and one that was just updated is briefly still"
            notice "announcing the version it ran a moment ago:"
            local _e
            for _e in ${behind[@]+"${behind[@]}"} ${unknown[@]+"${unknown[@]}"}; do
                printf '      %-24s %s\n' "${_e%%|*}" "${_e#*|}"
            done
            announced=1
        fi
        sleep 10; waited=$((waited + 10))
    done

    # A cluster whose members cannot be enumerated at all is the same answer as a
    # member that will not say: not "everything is fine".
    if [ -z "${rows}" ]; then
        unknown+=("(the cluster)|the roster could not be read from the local database")
    fi

    [ ${#behind[@]} -eq 0 ] && [ ${#unknown[@]} -eq 0 ] && return 0

    echo >&2
    printf '\033[31m✗ NOT updating: this node is the cluster PRIMARY and the cluster is not ready for it.\033[0m\n' >&2
    local entry
    if [ ${#behind[@]} -gt 0 ]; then
        echo "  These members are not on ${target} yet:" >&2
        for entry in "${behind[@]}"; do printf '      %-24s running %s\n' "${entry%%|*}" "${entry#*|}" >&2; done
    fi
    if [ ${#unknown[@]} -gt 0 ]; then
        echo "  These members could not be confirmed:" >&2
        for entry in "${unknown[@]}"; do printf '      %-24s %s\n' "${entry%%|*}" "${entry#*|}" >&2; done
        echo "  An out-of-date answer is not an answer. A node reports every 30s, so if one was" >&2
        echo "  just restarted, wait half a minute and run this again." >&2
    fi
    cat >&2 <<'WHY'
  Restarting the primary triggers a failover. If a node with the OLD code takes the
  lead, the upgraded machine becomes a replica running NEW code — and a replica does
  not migrate, while the old leader has no such migration to make. Both then wait
  forever, and switching leadership back does not help: the schema check is exact in
  both directions.

  Update those nodes first, then run this again. If you are certain — for instance
  because you are repairing exactly the state above — re-run with:
      ./taranac update --allow-out-of-order
WHY
    [ "${allow}" = "1" ] || return 1
    echo >&2
    printf '\033[33m! --allow-out-of-order: continuing anyway.\033[0m\n' >&2
    return 0
}

# Remind the operator of the one-node-at-a-time discipline when restarting an HA node.
# The LEADER case is no longer here: it is a refusal now, taken before anything is
# written (ha_require_upgrade_order), not a sentence printed after the fact.
ha_upgrade_notice() {
    [ "${HA_ACTIVE:-0}" = "1" ] || return 0
    echo
    warn "HA node — the database comes up under the Patroni overlay."
    notice "Upgrade ONE node at a time: replicas FIRST, the primary LAST (recreating the"
    notice "primary's container triggers a failover). Back up first. (HA.md §6)"
    echo
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
# They agree after a finished upgrade and disagree after an interrupted one — the
# pin is written last. Reading the pin therefore made the node report the version
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
    # An upgrade writes the files first and the pin last, so a disagreement here
    # means exactly one thing: the last one stopped in between. Said plainly, with
    # both numbers and the one command that finishes it — the node cannot repair
    # itself and the operator cannot see this from anywhere else.
    if [ -n "${pinned}" ] && [ "${pinned}" != "${cur}" ]; then
        warn "The image tag pinned in .env is ${pinned}, but the bundle here is ${cur}."
        warn "An update did not run to the end. Finish it with:  ./taranac update --version ${cur}"
    fi
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

    # ── Before the backup, before the file swap, before the pin ──────────────
    # The guard this replaces ran after all three and said "Ctrl-C now", so
    # obeying it left the node half-updated. A refusal is only a refusal if
    # nothing has happened yet.
    ha_require_upgrade_order "${env_file}" "${target_ver}" "${allow_out_of_order}" || exit 1

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
    # Everything below runs under `set -euo pipefail`, and everything below is
    # past the point of no return: the bundle's files are replaced first and the
    # version pin is written several steps later. A command that exits non-zero
    # anywhere in between ends the script with the last thing printed being a
    # green "✓ Bundle files updated." — which is how an upgrade that never
    # happened came to look like one that had, on a customer's cluster.
    #
    # The three inputs that used to do it are fixed at report_new_env_keys. This
    # trap is for the fourth: it makes the class impossible to hit silently
    # rather than the three instances impossible to hit.
    #
    # `set -E` because without errtrace an ERR trap is not inherited by shell
    # functions, and most of the work below happens inside them.
    set -E
    # The phase, so the message can say what is actually true rather than what is
    # usually true. The first version of this trap asserted "the files are
    # replaced, the pin is not" — and the first real failure it caught on the
    # stand was a `docker compose pull`, which happens AFTER the pin. A message
    # that overstates is the same kind of fault as no message: the operator acts
    # on it.
    _apply_phase="preparing"
    trap 'rc=$?; printf "\n\033[31m✗ update DID NOT FINISH (exit %s) while %s. The previous bundle files are in %s; re-run  ./taranac update  to complete it, or restore from there to go back.\033[0m\n" "${rc}" "${_apply_phase}" "${backup}" >&2' ERR

    # Enumerate what the FRESH bundle carries (every top-level entry, dotfiles too:
    # .env.example, .gitignore) and refresh all of it except operator-owned paths.
    # `[ -e ]` makes the globs nullglob-safe if a pattern matches nothing.
    _apply_phase="replacing the bundle files"
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

    _apply_phase="pulling images and restarting the stack"

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

    # The window is closed: the pin is written and the stack is up, so a later
    # failure is no longer the half-done kind this trap exists to announce.
    trap - ERR

    echo
    ok "Update complete → ${target_ver:-unknown}"
    notice "Rollback if needed: restore files from ${backup}"
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

# ── `update` orchestration ───────────────────────────────────────────
cmd_update() {
    local target="" from="" do_restart=1 assume_yes=0 check_only=0 do_prune=1 allow_out_of_order=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) target="${2:-}"; shift 2 ;;
            --from)    from="${2:-}"; shift 2 ;;
            --no-restart) do_restart=0; shift ;;
            --keep-images) do_prune=0; shift ;;
            --allow-out-of-order) allow_out_of_order=1; shift ;;
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
        # "Nothing to do" needs BOTH halves to agree with the target. After an
        # interrupted upgrade the bundle is already the new version while the pin
        # is still the old one, and a short-circuit that looked only at the bundle
        # would refuse the one command that repairs it.
        local cur pinned; cur="$(current_version)"; pinned="$(pinned_version)"
        if [ "${target}" = "${cur}" ] && [ "${target}" = "${pinned}" ] && [ "${assume_yes}" != "1" ]; then
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
    local -a apply_flags=(); [ "${allow_out_of_order}" = "1" ] && apply_flags=(--allow-out-of-order)
    exec bash "${extract}/taranac-update.sh" --apply-internal "${extract}" "${BUNDLE_DIR}" "${target}" "${do_restart}" "${do_prune}" ${apply_flags[@]+"${apply_flags[@]}"}
}

# ── Entry point ──────────────────────────────────────────────────────
case "${1:-}" in
    check|version) cmd_check ;;
    update)        shift; cmd_update "$@" ;;
    --apply-internal)  # internal: invoked by the freshly-extracted updater (src dest ver restart [prune])
        shift; cmd_apply "$@" ;;
    *) die "usage: taranac-update.sh {version|update [--version X|--from FILE|--check|--no-restart|--keep-images|--allow-out-of-order|--yes]}" ;;
esac
