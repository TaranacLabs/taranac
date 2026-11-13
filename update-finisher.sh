#!/bin/sh
# =============================================================================
# update-finisher.sh — the last step of an HA DB node's update, run inside the
# taranac-update-finisher container (docker-compose.update-finisher.yml), never by
# hand.
#
#   update-finisher.sh <bundle dir> <version>
#   env: FINISHER_KEY     this node's etcd record key (/taranac/update/members/<ETCD_NAME>)
#        FINISHER_RECORD  the record's fixed fields (version=…;role=…;node=…;address=…;override=…)
#        FINISHER_ETCD    the local etcd container to write through
#
# POSIX sh, not bash: the docker:*-cli image is Alpine (busybox sh, no bash), and
# installing bash at run time would need a registry on hosts that may have none.
# So this file does only what has to happen AFTER the api is healthy, and nothing
# the bash updater already did before handing over (pull, verify, pin, recreate,
# the image-version check, the prune). Its record format must match
# cluster-versions.sh (cv_record_value).
#
# The container's restart policy is unless-stopped, so EVERY exit means "run me
# again" (a reboot, an etcd write that did not land) and the only way out is
# finish() — removing its own container. Not on-failure: measured on a real host
# (10.10.2026), a container with on-failure that was running when the machine
# rebooted came back Exited (0) and was never started again; unless-stopped came
# back up. The reboot is exactly the case this container exists to survive.
# =============================================================================
set -u

D="${1:?usage: update-finisher.sh <bundle dir> <version>}"
V="${2:?usage: update-finisher.sh <bundle dir> <version>}"
LOG="${D}/.taranac-update.log"
STARTED="${D}/.taranac-update-finisher.started"
POLL="${FINISHER_POLL_S:-15}"
CEILING="${FINISHER_CEILING_S:-86400}"
HB_EVERY="${FINISHER_HB_S:-60}"
ETCD="${FINISHER_ETCD:-taranac-etcd}"
SELF=taranac-update-finisher

# `docker stop` (and so a reboot) sends TERM. PID 1 ignores it without a handler;
# exit non-zero so the log reads as an interruption, not a finish.
trap 'exit 143' TERM INT

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { date -u +%s; }
say() { printf '%s finisher[%s]: %s\n' "$(now_iso)" "${V}" "$*" | tee -a "${LOG}"; }

# The first start for this version, carried over restarts so the ceiling is real.
START="$(awk -v v="${V}" '$2 == v { print $1 }' "${STARTED}" 2>/dev/null)"
[ -n "${START}" ] || { START="$(now)"; printf '%s %s\n' "${START}" "${V}" > "${STARTED}"; }

put() {  # <state> [reason]
    val="${FINISHER_RECORD};state=$1;at=$(now_iso);hb=$(now_iso)"
    [ -n "${2:-}" ] && val="${val};reason=$(printf '%s' "$2" | tr ';' ',')"
    i=0
    while [ "${i}" -lt 3 ]; do
        docker exec "${ETCD}" etcdctl --command-timeout=5s put "${FINISHER_KEY}" "${val}" >/dev/null 2>&1 && return 0
        i=$((i + 1)); sleep 5
    done
    return 1
}

compose() {
    # Always with the HA overlay: this finisher exists only on an HA DB node, and it
    # stands down before any call here if .env says otherwise. A missing overlay is a
    # failed call that is retried and reported — never `up -d` on the base compose,
    # which under HA starts a second writable Postgres on the Patroni data dir.
    TARANAC_VERSION="${V}" docker compose --env-file "${D}/.env" --project-directory "${D}" \
        -f "${D}/docker-compose.yml" -f "${D}/docker-compose.ha.yml" "$@"
}

# ── Still mine to finish? ────────────────────────────────────────────────────
# This node may have been taken out of the finisher's hands since it was started:
# the operator rolled it back (restored the bundle files from .taranac-backup-*,
# set the pin to the previous version, `./taranac up -d`), detached it from the
# cluster, or deconverted it. Each of those leaves its mark in the two files the
# updater itself writes — the bundle's VERSION and the pin and HA marker in .env —
# and an `up -d` on ${V} after any of them would undo the operator's work: the
# rollback re-rolled forward, a standalone node brought back up with Patroni and
# etcd. So both are read again before every write this finisher makes, and a
# mismatch ends it WITHOUT touching etcd: the record there is the updater's to
# write next time, not ours to overwrite with a state this node is not in.
# The HA test mirrors the updater's ha_is_configured (TARANAC_HA=1, else any
# DB_HOSTS) — the same rule that decided this node gets a finisher at all.
env_of() {  # <key> → its value in ${D}/.env, quotes and trailing blanks stripped
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=[[:space:]]*//p" "${D}/.env" 2>/dev/null \
        | tail -1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
superseded_why() {  # → prints why this run is no longer the finisher's, or nothing
    pin="$(env_of TARANAC_VERSION)"
    bundle="$(head -1 "${D}/VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ ! -f "${D}/.env" ]; then echo "${D}/.env is gone"; return; fi
    if [ "$(env_of TARANAC_HA)" != 1 ] && [ -z "$(env_of DB_HOSTS)" ]; then
        echo "this node is no longer configured for HA (no TARANAC_HA=1 or DB_HOSTS in .env — detached or deconverted)"; return
    fi
    [ "${pin}" = "${V}" ] || { echo "the pin in .env is now TARANAC_VERSION=${pin:-<unset>}, not ${V} (rolled back or re-updated)"; return; }
    [ "${bundle}" = "${V}" ] || { echo "the bundle files are now ${bundle:-<no VERSION>}, not ${V} (restored from a backup?)"; return; }
}
stand_down_if_superseded() {
    why="$(superseded_why)"
    [ -n "${why}" ] || return 0
    say "SUPERSEDED: ${why}. Not starting anything and not writing to etcd — this node is the operator's now. See it with  ./taranac ps  and the cluster with  ./taranac cluster status"
    finish
}

finish() {  # the only exit 0
    rm -f "${STARTED}"
    docker rm -f "${SELF}" >/dev/null 2>&1
    exit 0
}

give_up() {  # <reason with its cure>
    stand_down_if_superseded
    say "GAVE UP: $1"
    put failed "$1" || say "could not record state=failed in etcd either"
    finish
}

say "waiting for taranac-api to be healthy (then: start what is not running, check, record state=updated)"
last_hb=0
while :; do
    stand_down_if_superseded
    h="$(docker inspect --format '{{.State.Health.Status}}' taranac-api 2>/dev/null)"
    [ "${h}" = "healthy" ] && break
    if [ $(( $(now) - START )) -ge "${CEILING}" ]; then
        give_up "the api on this node was not healthy ${CEILING}s after the update (last: ${h:-no container}). Cure: ./taranac logs --tail 100 api on this node, fix what it says, then ./taranac update --version ${V} on this node"
    fi
    if [ $(( $(now) - last_hb )) -ge "${HB_EVERY}" ]; then
        put awaiting-schema || say "etcd did not take the heartbeat (will retry)"
        last_hb="$(now)"
    fi
    sleep "${POLL}"
done

# START, never recreate — and never touch a voter. The updater already recreated
# every container on ${V} (`up -d --no-start`) and started the api with its
# database and etcd; what is left is to start what is still Created. A plain
# `up -d` here recreated the running etcd, Postgres and api as well — seen live on
# 1.3.2-rc1: after the leader's update both replicas' finishers recreated their etcd
# two seconds apart, two voters of a four-member ring down together, quorum lost.
# The cause is not this file's arguments, which are the updater's own: it is the
# compose binary. This container's compose (the docker:cli image's) is not the
# host's, and compose versions normalise the same file differently (v2.33 renders a
# bind mount with create_host_path: true, v5 with an empty bind: {}), so every
# service with a bind mount gets another config hash — and to compose another hash
# means "recreate". So the call names exactly the services that are not running,
# never etcd, postgres or api (they are what the updater started and what holds the
# cluster's quorum — the api being healthy is how this got here), with
# --no-recreate and --no-deps: nothing that runs is touched, nothing is pulled in
# as a dependency. Two finishers on two nodes can then never restart a voter
# together, because neither restarts one at all.
VOTERS=" etcd postgres api "
host_compose="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.version"}}' taranac-api 2>/dev/null)"
own_compose="$(docker compose version --short 2>/dev/null)"
if [ -n "${host_compose}" ] && [ -n "${own_compose}" ] && [ "${host_compose#v}" != "${own_compose#v}" ]; then
    say "note: this stack was created by compose ${host_compose}, this finisher runs compose ${own_compose} — their config hashes differ, so it only starts what is not running (--no-recreate --no-deps) and recreates nothing"
fi

not_running() {  # → every service of this node with no running container, one per line
    running=" $(compose ps --status running --services 2>/dev/null | tr '\n' ' ') "
    compose config --services 2>/dev/null | while read -r svc; do
        [ -n "${svc}" ] || continue
        case "${running}" in *" ${svc} "*) ;; *) echo "${svc}" ;; esac
    done
}

say "taranac-api is healthy — starting the rest of the stack"
last_hb=0
while :; do
    stand_down_if_superseded
    services="$(compose config --services 2>/dev/null | wc -l)"
    down="$(not_running | tr '\n' ' ')"
    if [ -z "${down% }" ] && [ "${services}" -gt 0 ]; then
        break
    fi
    start=""; held=""
    for svc in ${down}; do
        case "${VOTERS}" in *" ${svc} "*) held="${held} ${svc}" ;; *) start="${start} ${svc}" ;; esac
    done
    if [ -n "${start}" ]; then
        # shellcheck disable=SC2086  # one service per word, on purpose
        compose up -d --no-recreate --no-deps ${start} >>"${LOG}" 2>&1 \
            || say "docker compose up -d --no-recreate --no-deps${start} failed (will retry)"
    fi
    [ -z "${held}" ] || say "not starting${held}: the database, etcd and the api are the updater's and their restart policy's, never this finisher's"
    down="$(not_running | tr '\n' ' ')"
    [ -n "${down% }" ] || break
    if [ $(( $(now) - START )) -ge "${CEILING}" ]; then
        give_up "these services did not start: ${down:-unknown}. Cure: ./taranac ps and ./taranac logs --tail 100 <service> on this node, then ./taranac update --version ${V} on this node"
    fi
    say "not running yet: ${down} — retrying in ${POLL}s"
    # Still alive, still working: the witness's gate reads a silent hb as a dead
    # finisher ("host restarted?") after three minutes, so this loop beats too.
    if [ $(( $(now) - last_hb )) -ge "${HB_EVERY}" ]; then
        put awaiting-schema || say "etcd did not take the heartbeat (will retry)"
        last_hb="$(now)"
    fi
    sleep "${POLL}"
done

stand_down_if_superseded
if ! put updated; then
    say "the stack is up, but etcd did not take state=updated — retrying after a restart"
    exit 1
fi
say "done — every service runs ${V}; recorded state=updated"
finish
