#!/usr/bin/env bash
# =============================================================================
# stack-network.sh — the stack's Docker network brought to the plan the compose files
# declare, BEFORE the containers are recreated on it. Sourced by taranac-update.sh and
# by install.sh's upgrade path (an existing .env), never executed.
#
# WHY
#   The stack network grew from a /28 to a /27 in 1.3.3, and gained an IPv6 subnet
#   beside its IPv4 one when the client-facing services started taking IPv6 with the
#   client's own address (docker-compose.yml). Docker never changes the address plan
#   of an existing network, and whether `up` replaces one that differs depends on the
#   Compose release: recent ones do, but reattach the containers WITHOUT their fixed
#   ipv4_address, older ones keep the old network and the fixed addresses outside it
#   fail. So a network whose plan is not the one the compose files declare is taken
#   down here, with the containers on it (the caller's very next step recreates
#   them), before the recreate. Volumes stay.
#
#   install.sh is the documented upgrade command too, so it needs this as much as the
#   updater: one copy, here, shipped beside both.
#
#   The plan is compared as a SET of subnets in canonical form: `inspect` prints
#   Docker's canonical text in Docker's order, `compose config` prints the file's text
#   in the file's order, and an IPv6 prefix has many spellings (fd64:…:0::/64 is
#   fd64:…::/64). Compared as strings, every update would take the stack down for
#   nothing.
# =============================================================================

_sn_info() {
    if type info >/dev/null 2>&1; then info "$@"; else printf '==> %s\n' "$*"; fi
}

# <env-file> <target version, or "" for the one .env pins> <compose -f args…>
# 0 = nothing needed, nothing could be read, or done; 1 = the down failed.
stack_network_reconcile() {
    local env_file="$1" target="$2" project want have
    shift 2
    local -a pre=(); [ -n "${target}" ] && pre=("TARANAC_VERSION=${target}")
    project="$(docker compose --env-file "${env_file}" --project-directory "$(dirname "${env_file}")" "$@" config 2>/dev/null \
        | awk '/^name:[[:space:]]/ { print $2; exit }' || true)"
    [ -n "${project}" ] || return 0
    have="$(docker network inspect "${project}_default" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)" \
        || return 0
    # shellcheck disable=SC2086  # one subnet per word, on purpose
    have="$(python3 -c 'import ipaddress, sys
print(" ".join(sorted({ipaddress.ip_network(s, strict=False).compressed for s in sys.argv[1:]})))' ${have} 2>/dev/null)" \
        || return 0
    want="$(env ${pre[@]+"${pre[@]}"} docker compose --env-file "${env_file}" "$@" config --format json 2>/dev/null \
        | python3 -c 'import ipaddress, json, sys
cfg = json.load(sys.stdin)["networks"]["default"]["ipam"]["config"]
print(" ".join(sorted({ipaddress.ip_network(c["subnet"], strict=False).compressed for c in cfg if c.get("subnet")})))' 2>/dev/null)" \
        || return 0
    [ -n "${have}" ] && [ -n "${want}" ] && [ "${have}" != "${want}" ] || return 0
    _sn_info "The stack's Docker network changes from ${have} to ${want} — replacing it (the containers are recreated next; data volumes stay) ..."
    env ${pre[@]+"${pre[@]}"} docker compose --env-file "${env_file}" "$@" down || return 1
}
