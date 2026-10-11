#!/usr/bin/env bash
# =============================================================================
# container-names.sh — keep every container under the name the tooling uses for it,
# and make sure no script of this bundle can die without saying where. Sourced,
# never executed.
#
# WHY THIS EXISTS
#   docker compose v2 replaces a container in four moves: create the new one under
#   a TEMPORARY name `<first 12 hex of the OLD container's id>_<container_name>`,
#   stop the old one, remove it, rename the new one to its real name. Interrupt the
#   last move and the replacement is left under the temporary name — and the next
#   `up -d` simply starts it there. Seen in the field on an HA primary: Postgres
#   ran for five weeks as `fa320f530188_taranac-db`, healthy and leading, while
#   every tool in this bundle that says `docker exec taranac-db` failed. Two
#   consequences, both worse than the name itself:
#     · `cluster remove-node` died on that exec under `set -e` with NO message at
#       all, and `add-node --reinstall` reported only "could not evict";
#     · the next recreate of that service can never succeed: compose builds the
#       temporary name from the running container's id, which is the name the
#       container already has → "Conflict. The container name … is already in use".
#       So the following `./taranac update` would have failed too.
#   Compose itself finds containers by LABEL and does not care. The bundle — and
#   every `docker exec taranac-db` that HA.md teaches an operator to type — does.
#
# WHY HEAL THE NAME RATHER THAN LOOK CONTAINERS UP BY LABEL
#   A label lookup would fix the scripts and leave the state broken: the documented
#   commands would still fail, and the next recreate would still conflict. Renaming
#   the container back fixes all three at once. `docker rename` does not restart
#   anything, and nothing addresses a container by its name on the network that the
#   rename could break: the apps reach Postgres as `postgres`, a service alias that
#   compose attaches and a rename keeps (verified against a live daemon).
#
# WHEN IT IS SAFE — and when it is not
#   The temporary name carries the id of the container it was replacing, and that
#   is what tells the three states apart:
#     HEAL        nothing holds the real name and the container it replaced is
#                 gone — the replacement finished everything but its rename.
#                 Renamed back, and said so.
#     INTERRUPTED the real name is held by the very container being replaced (its
#                 id starts with the prefix): the recreate stopped after creating
#                 the replacement. The replacement never ran; the data lives in a
#                 NAMED volume both mount, so the one holding the real name is the
#                 database. NOT acted on — the cure is printed: remove the leftover.
#                 Never `start` it: two postmasters on one data directory in two
#                 PID namespaces is exactly the case postmaster.pid cannot catch.
#     CONFLICT    anything else — the real name held by some other container, or
#                 two leftovers for one name. Printed with both sides, not touched.
#   And never while a recreate may be in flight: a temporary name is legitimate for
#   the seconds compose needs, so nothing younger than a minute is renamed, and
#   nothing at all while a `docker compose` process is running on this host.
#
# WHO CALLS WHAT
#   heal_container_names     every script that drives containers by name, before
#                            it does. Changes only the HEAL case; always returns 0,
#                            so it can never be the thing that stops a script.
#   container_name_problems  read-only report, for the diagnostic collectors — they
#                            promise to change nothing.
#   resolve_container NAME   the container that really is NAME right now: NAME
#                            itself, or the leftover standing in for it.
#   loud_death LABEL         an ERR trap for `set -e` scripts: a death prints the
#                            line and the command instead of nothing.
# =============================================================================

TARANAC_COMPOSE_PROJECTS="${TARANAC_COMPOSE_PROJECTS:-taranac taranac-witness taranac-collector}"
TARANAC_HEAL_MIN_AGE="${TARANAC_HEAL_MIN_AGE:-60}"

_cn_say() { printf '%s\n' "$@" >&2; }

# awk over "<id>\t<name>\t…" with real_of(name): the name a leftover stands in for,
# or "" when it is not one. Spelled without {12}: mawk, Ubuntu's default awk, has
# no interval expressions on every release we support.
_cn_awk() {  # [awk options…] <program>
  local prog="${*: -1}"
  set -- "${@:1:$#-1}"
  awk -F'\t' "$@" 'function real_of(x) { if (length(x) > 13 && substr(x, 13, 1) == "_" && substr(x, 1, 12) ~ /^[0-9a-f]+$/) return substr(x, 14); return "" } '"${prog}"
}

# Every container of our compose projects: "<full id>\t<name>\t<state>".
_cn_containers() {
  local p
  for p in ${TARANAC_COMPOSE_PROJECTS}; do
    docker ps -a --no-trunc --filter "label=com.docker.compose.project=${p}" \
      --format '{{.ID}}	{{.Names}}	{{.State}}' 2>/dev/null || true
  done
}

# One line per leftover: "<verdict>\t<id>\t<leftover name>\t<real name>\t<state>\t<holder name>\t<holder state>"
# verdict ∈ HEAL INTERRUPTED CONFLICT DUPLICATE.
_cn_classify() {
  local all ids line id name state prefix real holder hid hname hstate verdict dups
  all="$(_cn_containers)"
  [ -n "${all}" ] || return 0
  ids="$(docker ps -a --no-trunc -q 2>/dev/null || true)"
  while IFS='	' read -r id name state; do
    [[ "${name}" =~ ^([0-9a-f]{12})_(.+)$ ]] || continue
    prefix="${BASH_REMATCH[1]}"; real="${BASH_REMATCH[2]}"
    holder="$(printf '%s\n' "${all}" | awk -F'\t' -v n="${real}" '$2 == n' | head -1)"
    # The real name may also be held by a container outside our projects.
    if [ -z "${holder}" ] && docker inspect --type container "${real}" >/dev/null 2>&1; then
      holder="$(docker inspect --type container -f '{{.Id}}	{{.Name}}	{{.State.Status}}' "${real}" 2>/dev/null | sed 's|	/|	|')"
    fi
    hid=""; hname=""; hstate=""
    [ -n "${holder}" ] && IFS='	' read -r hid hname hstate <<<"${holder}"
    dups="$(printf '%s\n' "${all}" | _cn_awk -v n="${real}" '$2 != n && real_of($2) == n { c++ } END { print c+0 }')"
    if [ "${dups}" -gt 1 ]; then
      verdict=DUPLICATE
    elif [ -z "${hid}" ]; then
      if printf '%s\n' "${ids}" | grep -q "^${prefix}"; then verdict=CONFLICT; else verdict=HEAL; fi
    elif [ "${hid#"${prefix}"}" != "${hid}" ]; then
      verdict=INTERRUPTED
    else
      verdict=CONFLICT
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${verdict}" "${id}" "${name}" "${real}" "${state}" "${hname}" "${hstate}"
  done <<<"${all}"
}

# The cure for a case we do not act on, as lines an operator can follow.
_cn_explain() {  # <verdict> <leftover> <real> <state> <holder> <holder state>
  local v="$1" left="$2" real="$3" state="$4" hname="$5" hstate="$6"
  case "${v}" in
    INTERRUPTED)
      # Which of the two is serving decides the cure. Usually the original, holding
      # the real name, still runs and the replacement was never started. But a
      # recreate that stopped the original and was then followed by an `up -d`
      # leaves the REPLACEMENT serving and the original exited — and removing the
      # running one would be exactly wrong.
      if [ "${state}" = running ] && [ "${hstate}" != running ]; then
        _cn_say "  ! '${left}' is the container serving as '${real}'; the old '${real}' (${hstate})" \
                "    is the one it replaced and was never removed. Its data is in a named volume." \
                "    Remove the old one, then give the serving one its name (no restart):" \
                "      docker rm ${real}" \
                "      docker rename ${left} ${real}"
        return 0
      fi
      _cn_say "  ! '${left}' (${state}) is a half-finished replacement of '${real}' (${hstate})." \
              "    The recreate stopped after creating it; '${real}' is the container in use and" \
              "    its data is in a named volume, so nothing is lost by removing the leftover." \
              "    It blocks the next recreate of this service until it is gone. Do NOT start it." \
              "    Cure, if '${left}' is not running:  docker rm ${left}"
      ;;
    DUPLICATE)
      _cn_say "  ! more than one container is waiting to become '${real}' (one of them: '${left}', ${state})." \
              "    That is not a state compose leaves by itself, so nothing was changed. Inspect them:" \
              "      docker ps -a --filter name=${real}"
      ;;
    *)
      _cn_say "  ! '${left}' (${state}) should be called '${real}', but that name is held by" \
              "    '${hname:-a container that is being replaced}' (${hstate:-present}). Nothing was changed. Inspect both:" \
              "      docker ps -a --filter name=${real}"
      ;;
  esac
}

heal_container_names() {
  command -v docker >/dev/null 2>&1 || return 0
  local rows verdict id left real state hname hstate created age now
  rows="$(_cn_classify 2>/dev/null || true)"
  [ -n "${rows}" ] || return 0
  while IFS='	' read -r verdict id left real state hname hstate; do
    if [ "${verdict}" != HEAL ]; then
      _cn_explain "${verdict}" "${left}" "${real}" "${state}" "${hname}" "${hstate}"
      continue
    fi
    if [ -z "${TARANAC_HEAL_IGNORE_COMPOSE:-}" ] \
       && { pgrep -f 'docker[- ]compose( |$)' >/dev/null 2>&1 || pgrep -x docker-compose >/dev/null 2>&1; }; then
      _cn_say "  ! '${left}' should be called '${real}'; not renaming it while a docker compose" \
              "    command is running here (it may be mid-recreate). Run this again once it has finished."
      continue
    fi
    created="$(docker inspect -f '{{.Created}}' "${id}" 2>/dev/null || true)"
    now="$(date +%s)"
    age=$(( now - $(date -d "${created}" +%s 2>/dev/null || echo "${now}") ))
    if [ "${age}" -lt "${TARANAC_HEAL_MIN_AGE}" ]; then
      _cn_say "  ! '${left}' was created ${age}s ago — too recent to tell from a recreate in" \
              "    progress. Not renamed; run this again in a minute."
      continue
    fi
    if docker rename "${left}" "${real}" >/dev/null 2>&1; then
      _cn_say "  ↻ '${left}' renamed back to '${real}' — compose had left it under a temporary" \
              "    name after an interrupted recreate. Nothing was restarted."
    else
      _cn_say "  ! could not rename '${left}' to '${real}'. Do it by hand, then retry:" \
              "      docker rename ${left} ${real}"
    fi
  done <<<"${rows}"
  return 0
}

# Read-only: one paragraph per leftover, on stdout, or nothing.
container_name_problems() {
  command -v docker >/dev/null 2>&1 || return 0
  local rows verdict id left real state hname hstate
  rows="$(_cn_classify 2>/dev/null || true)"
  [ -n "${rows}" ] || return 0
  while IFS='	' read -r verdict id left real state hname hstate; do
    if [ "${verdict}" = HEAL ]; then
      printf '%s\n' "'${left}' (${state}) is '${real}' under the temporary name compose gives a" \
        "container while recreating it — the rename that ends a recreate never happened." \
        "Every tool that addresses '${real}' by name fails on this host, and the next" \
        "recreate of the service fails with a name conflict. ./taranac ps (or any ./taranac" \
        "command that acts on the stack) renames it back without restarting it; or by hand:" \
        "  docker rename ${left} ${real}"
    else
      _cn_explain "${verdict}" "${left}" "${real}" "${state}" "${hname}" "${hstate}" 2>&1
    fi
  done <<<"${rows}"
}

resolve_container() {  # <real name> → the container that is it now
  # The one RUNNING wins: the real name may be held by an exited original while a
  # leftover replacement serves (see INTERRUPTED), and a collector reading the
  # stopped one would report "running=false" about a database that is serving.
  local real="$1" left real_up=""
  [ "$(docker inspect --type container -f '{{.State.Running}}' "${real}" 2>/dev/null)" = true ] && real_up=1
  if [ -n "${real_up}" ]; then printf '%s' "${real}"; return 0; fi
  left="$(_cn_containers | _cn_awk -v n="${real}" '$2 != n && real_of($2) == n && $3 == "running" { print $2 }' | head -1)"
  if [ -n "${left}" ]; then printf '%s' "${left}"; return 0; fi
  if docker inspect --type container "${real}" >/dev/null 2>&1; then printf '%s' "${real}"; return 0; fi
  left="$(_cn_containers | _cn_awk -v n="${real}" '$2 != n && real_of($2) == n { print $2 }' | head -1)"
  printf '%s' "${left:-${real}}"
}

# `set -e` kills a script at the first failing command and says nothing; with
# stderr routed to /dev/null, as half the probes here are, the operator sees a
# script that simply stops. That is the field bug above, and it had happened
# before (getenv, cluster-wizard.sh). The trap is printed by the top-level shell
# only: under errtrace a failure inside $(…) fires once in the subshell and again
# on the assignment that receives it, and only the second one is where it matters.
loud_death() {  # <what the script is called, for the message>
  _CN_SCRIPT="$1"
  set -E
  trap '_cn_rc=$?; if [ "${BASH_SUBSHELL}" -eq 0 ]; then printf "\n\033[31m✗ %s stopped unexpectedly (exit %s) at line %s:\033[0m\n    %s\n  This is a failure the script does not handle, so it stopped before doing anything\n  further. Please send this message together with  ./taranac diagnose --ha\n" "${_CN_SCRIPT}" "${_cn_rc}" "${LINENO}" "${BASH_COMMAND}" >&2; fi' ERR
}
