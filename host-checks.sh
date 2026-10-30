#!/usr/bin/env bash
# =============================================================================
# host-checks.sh — what this host must offer before the stack may run on it, asked
# by bootstrap.sh, install.sh and taranac-update.sh BEFORE they change anything, and
# shown as facts by diagnose.sh. Sourced, never executed.
#
# WHY THESE CHECKS EXIST
#   The stack network carries IPv6 for the client-facing services (edge, the AAA and
#   NAC daemons, EST/SCEP, MFA, the portal), so an IPv6 device reaches them with its
#   OWN address instead of the Docker gateway's. Every other container is kept off
#   IPv6 with `net.ipv6.conf.all.disable_ipv6=1` — and that is where the host comes in:
#
#   · Docker older than 28.0 does not honour that sysctl for the address it assigns:
#     on 27.5.1 the container still gets an IPv6 address and an AAAA record (28.0.0,
#     28.5.2 and 29.6.2 checked: none). glibc asks AAAA first, so the api, the portal
#     and every name-based path inside the stack start dialling a dead address — 3 s
#     per connection, the portal in a circle. A REQUIREMENT: install, update and
#     bootstrap refuse, with how to update Docker, before anything is changed.
#   · A kernel without IPv6 (booted with ipv6.disable=1: no /proc/net/if_inet6) cannot
#     create the network at all, and edge's `listen [::]` has not started on such a
#     kernel since cc0cab742 anyway. Install and update refuse.
#   · A new enough Docker on such a kernel can still fail to create a network with
#     IPv6 (no ip6_tables module, ip6tables held by a firewall manager). A throwaway
#     dual-stack network is created and removed first; Docker's refusal is the
#     installer's and the updater's, in Docker's own words, before anything changes.
#   · Docker 28+ with ip6tables turned off still runs, but publishes IPv6 through its
#     userland proxy, and every IPv6 client then arrives from the gateway's address
#     again. A WARNING, with where it is turned off.
#   · The first IPv6 network Docker creates sets net.ipv6.conf.all.forwarding=1. On an
#     interface whose accept_ra is 1 the kernel then IGNORES router advertisements,
#     and a host that takes its IPv6 address or its default route from them (SLAAC,
#     or a static address with the router's advertised gateway) loses that route when
#     its lifetime runs out — hours after the update, with nothing pointing at it.
#     accept_ra=2 accepts them with forwarding on. Install and update set it
#     themselves, only where it matters (accept_ra=1 AND a dynamic global IPv6
#     address or a default route learned from an advertisement), at runtime and in
#     /etc/sysctl.d, and say so.
#
# WHO CALLS WHAT
#   hc_require <install|update|bootstrap> [again]
#                                          the refusals. 0 = go; 1 = refused, the
#                                          reason and the cure already printed.
#   hc_prepare                             the warnings and the accept_ra fix. 0 = go;
#                                          1 = the fix was needed and could not be
#                                          made (cure printed, nothing changed).
#   hc_summary                             one line: what hc_require and hc_prepare
#                                          found and did (they are silent on success).
#   hc_gateway_entries <api> [net]         inventory entries an IPv6 device matched
#                                          through the gateway address until now.
#   hc_ipv6_entries <api>                  how many inventory entries are IPv6 ones.
#   hc_inventory_gate <api> <net> <again> <again-anyway>
#                                          those entries, before the network gains IPv6:
#                                          a refusal while the inventory has no IPv6
#                                          entry at all, unless the operator says go on.
#   hc_world_logins <api> [net]            addresses that logged in to TACACS+ without an
#                                          inventory entry in the last 30 days, refused
#                                          after this update: a warning, never a refusal.
#   hc_facts / hc_problems                 diagnose: what is, and what is wrong.
#   hc_gateway_finding <net> <gw> <rows>   diagnose: the gateway entries as a finding,
#                                          only while IPv6 still arrives from the gateway.
#   hc_v6_ports <container> [sudo]         diagnose: per published port, does the
#                                          daemon listen on IPv6, is there an IPv6 DNAT.
#
# TARANAC_HOST_ROOT (tests only) is put in front of every host path read or
# written here — /proc, /etc, /var/snap — so a test can stand a host in a directory.
# =============================================================================

HC_ROOT="${TARANAC_HOST_ROOT:-}"
HC_DOCKER_MIN_MAJOR=28
HC_SYSCTL_FILE="/etc/sysctl.d/99-taranac-accept-ra.conf"
HC_DAEMON_JSONS="/etc/docker/daemon.json /var/snap/docker/current/config/daemon.json"

_hc_say() { printf '%s\n' "$@" >&2; }

# What hc_require and hc_prepare found and did, for hc_summary: both are silent when all
# is well, and a run that leaves no trace of its checks cannot be told from one that
# skipped them (stand, 25.10.2026).
HC_SUM_DOCKER=""   # the server's version, as asked
HC_SUM_NET=""      # the throwaway dual-stack network: ok | overlap | "" (not asked)
HC_SUM_RA=""       # accept_ra: what was changed ("" = nothing needed)

# ── Docker ───────────────────────────────────────────────────────────────────
# The SERVER's version (the engine is what assigns addresses), or nothing when the
# daemon does not answer with one — never a guess: "unknown" refuses nothing.
hc_docker_version() {
  local v
  v="$(docker version --format '{{.Server.Version}}' 2>/dev/null | head -1 | tr -d '[:space:]')" || true
  case "${v}" in
    [0-9]*.[0-9]*) printf '%s' "${v}" ;;
  esac
}

hc_docker_ok() {  # <version> → 0 when it is new enough
  local major="${1%%.*}"
  case "${major}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${major}" -ge "${HC_DOCKER_MIN_MAJOR}" ]
}

# Podman behind the docker command (podman-docker) answers `docker version` with ITS
# own version (4.x, 5.x): "Docker 5.2 is too old" and a line that upgrades docker-ce
# would both be wrong. Docker Engine names its platform "Docker Engine - Community";
# Podman says its name in the server's platform or in `docker --version`.
hc_docker_is_podman() {
  { docker version --format '{{.Server.Platform.Name}}' 2>/dev/null; docker --version 2>/dev/null; } \
    | grep -qi podman
}

_hc_pkg_installed() {  # <deb or rpm name>
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' && return 0
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q "$1" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# How THIS host's Docker is updated — from where it came, so the line printed is the
# one that works here, not a menu.
hc_docker_update_cure() {
  if hc_docker_is_podman; then
    # The installer is fetched BEFORE podman-docker goes: a host that cannot reach
    # get.docker.com keeps what it has instead of being left with no docker command.
    echo "     Podman answers the docker command here; Taranac needs Docker Engine ${HC_DOCKER_MIN_MAJOR}.0 or newer."
    echo "     Fetch Docker's installer first, then remove podman-docker and run it:"
    echo "     curl -fsSL https://get.docker.com -o get-docker.sh"
    if command -v dnf >/dev/null 2>&1; then
      echo "     sudo dnf remove podman-docker"
    elif command -v apt-get >/dev/null 2>&1; then
      echo "     sudo apt-get remove podman-docker"
    fi
    echo "     sudo sh get-docker.sh"
  elif command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    echo "     sudo snap refresh docker"
  elif _hc_pkg_installed docker-ce && command -v apt-get >/dev/null 2>&1; then
    echo "     sudo apt-get update && sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  elif _hc_pkg_installed docker-ce && command -v dnf >/dev/null 2>&1; then
    echo "     sudo dnf upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  elif _hc_pkg_installed docker-ce && command -v yum >/dev/null 2>&1; then
    echo "     sudo yum update docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  elif _hc_pkg_installed docker.io || _hc_pkg_installed moby-engine || _hc_pkg_installed docker; then
    echo "     This is your distribution's Docker package, which lags behind. Replace it with"
    echo "     Docker's own (images, containers and volumes in /var/lib/docker stay):"
    echo "     curl -fsSL https://get.docker.com | sudo sh"
  else
    echo "     curl -fsSL https://get.docker.com | sudo sh"
  fi
  echo "     (Docker's own guide: https://docs.docker.com/engine/install/)"
}

# ── The kernel ───────────────────────────────────────────────────────────────
hc_kernel_ipv6() { [ -e "${HC_ROOT}/proc/net/if_inet6" ]; }

# ── Docker's ip6tables ───────────────────────────────────────────────────────
# 0 = turned off; HC_IP6T_WHERE says where. Docker 27+ has it on by default, so
# only an explicit "off" counts: daemon.json (the package's path, then the snap's),
# then the daemon's own command line.
HC_IP6T_WHERE=""
hc_ip6tables_off() {
  local f args
  HC_IP6T_WHERE=""
  for f in ${HC_DAEMON_JSONS}; do
    [ -r "${HC_ROOT}${f}" ] || continue
    if grep -Eq '"ip6tables"[[:space:]]*:[[:space:]]*false' "${HC_ROOT}${f}"; then
      HC_IP6T_WHERE="\"ip6tables\": false in ${f}"; return 0
    fi
  done
  args="$(ps -C dockerd -o args= 2>/dev/null || true)"
  if printf '%s\n' "${args}" | grep -Eq -- '--ip6tables(=|[[:space:]]+)(false|0|f|F|FALSE|False)([[:space:]]|$)'; then
    HC_IP6T_WHERE="dockerd runs with --ip6tables=false"; return 0
  fi
  return 1
}

# ── Router advertisements under forwarding ───────────────────────────────────
# Interfaces that take this host's IPv6 from router advertisements, as
# "<iface><TAB><what comes from them>", one per interface:
#   · a DYNAMIC global IPv6 address (scope 00, IFA_F_PERMANENT not set — what
#     `ip -6 addr show scope global dynamic` lists), from /proc/net/if_inet6;
#   · or a DEFAULT ROUTE learned from an RA (::/0 with RTF_ADDRCONF 0x40000 or
#     RTF_DEFAULT 0x10000 — what `ip -6 route` shows as "proto ra"), from
#     /proc/net/ipv6_route. A host with a static address and its gateway from the
#     router's advertisements loses that route the same way, and is the commoner case
#     on servers.
# Both read from /proc so that it needs no iproute2 and a test can stand it in.
# Docker's own bridges carry permanent addresses and no RA route: never listed.
_hc_ra_sources() {
  local f="${HC_ROOT}/proc/net/if_inet6" r="${HC_ROOT}/proc/net/ipv6_route"
  local dst dpl _src _spl _nh _metric _ref _use flags ifn
  {
    # Flags are printed as one byte in hex; PERMANENT is 0x80, so the first digit < 8.
    [ -r "${f}" ] && awk '$4 == "00" && substr($5, 1, 1) ~ /^[0-7]$/ { print $6 "\tdynamic global IPv6 address" }' "${f}"
    if [ -r "${r}" ]; then
      while read -r dst dpl _src _spl _nh _metric _ref _use flags ifn; do
        [ "${dst}" = 00000000000000000000000000000000 ] && [ "${dpl}" = 00 ] || continue
        [ -n "${ifn}" ] && [ "${ifn}" != lo ] || continue
        case "${flags}" in ''|*[!0-9a-fA-F]*) continue ;; esac
        (( (16#${flags} & 0x50000) != 0 )) || continue
        printf '%s\tdefault route from router advertisements\n' "${ifn}"
      done < "${r}"
    fi
  } | awk -F '\t' '!seen[$1]++'
  return 0
}

# Of those, the ones whose accept_ra is 1 — the ones forwarding would silence.
hc_accept_ra_ifaces() {
  local ifn _why v
  while IFS=$'\t' read -r ifn _why; do
    [ -n "${ifn}" ] || continue
    v="$(cat "${HC_ROOT}/proc/sys/net/ipv6/conf/${ifn}/accept_ra" 2>/dev/null || true)"
    [ "${v}" = 1 ] && printf '%s\n' "${ifn}"
  done < <(_hc_ra_sources | sort -u)
  return 0
}

# The sysctl key, in the form that survives a dot in the interface name (eth0.100).
_hc_ra_key() { case "$1" in *.*) printf 'net/ipv6/conf/%s/accept_ra' "$1" ;; *) printf 'net.ipv6.conf.%s.accept_ra' "$1" ;; esac; }

_hc_ra_manual() {  # <iface…> — the same change, by hand
  local i
  _hc_say "  Run these once, then run this command again:"
  for i in "$@"; do
    _hc_say "     sudo sysctl -w $(_hc_ra_key "${i}")=2" \
            "     echo '$(_hc_ra_key "${i}") = 2' | sudo tee -a ${HC_SYSCTL_FILE}"
  done
}

# 0 = nothing needed, or done and said; 1 = needed, not possible (said how, nothing changed).
hc_accept_ra_fix() {
  local -a ifs=()
  local i sudo_cmd="" body="" line keep
  mapfile -t ifs < <(hc_accept_ra_ifaces)
  [ ${#ifs[@]} -gt 0 ] || return 0
  if [ "$(id -u)" = 0 ]; then
    sudo_cmd=""
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo_cmd="sudo -n"
  elif command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
    sudo_cmd="sudo"
    _hc_say "! ${ifs[*]}: IPv6 comes from router advertisements here, and Docker's IPv6 network" \
            "  stops the kernel from accepting them (accept_ra=1 under forwarding). Setting" \
            "  accept_ra=2 needs root — sudo will ask for your password."
  else
    _hc_say "✗ ${ifs[*]}: this host takes its IPv6 address or default route from router" \
            "  advertisements (accept_ra=1). The stack's IPv6 network turns on IPv6 forwarding," \
            "  and the kernel then ignores those advertisements: the host loses its IPv6 route" \
            "  when the current one expires. accept_ra=2 keeps them, and changing it needs root," \
            "  which this run does not have (not root, no sudo without a password, no terminal)." \
            "  Nothing was changed."
    _hc_ra_manual "${ifs[@]}"
    return 1
  fi
  for i in "${ifs[@]}"; do
    if ! printf '2\n' | ${sudo_cmd} tee "${HC_ROOT}/proc/sys/net/ipv6/conf/${i}/accept_ra" >/dev/null 2>&1; then
      _hc_say "✗ could not set accept_ra=2 on ${i}. Nothing else was changed."
      _hc_ra_manual "${ifs[@]}"
      return 1
    fi
  done
  # Persisted in a file of our own: the lines already there for other interfaces stay,
  # the ones for these are written once.
  if [ -r "${HC_ROOT}${HC_SYSCTL_FILE}" ]; then
    while IFS= read -r line; do
      keep=1
      for i in "${ifs[@]}"; do
        case "${line}" in "$(_hc_ra_key "${i}") "*|"$(_hc_ra_key "${i}")="*) keep="" ;; esac
      done
      [ -n "${keep}" ] && body="${body}${line}"$'\n'
    done < "${HC_ROOT}${HC_SYSCTL_FILE}"
  else
    body="# Written by Taranac (install.sh / taranac-update.sh): the stack's IPv6 network turns on"$'\n'
    body="${body}# IPv6 forwarding, under which accept_ra=1 ignores router advertisements. 2 keeps them."$'\n'
  fi
  for i in "${ifs[@]}"; do body="${body}$(_hc_ra_key "${i}") = 2"$'\n'; done
  if ! { ${sudo_cmd} mkdir -p "$(dirname "${HC_ROOT}${HC_SYSCTL_FILE}")" \
         && printf '%s' "${body}" | ${sudo_cmd} tee "${HC_ROOT}${HC_SYSCTL_FILE}" >/dev/null; } 2>/dev/null; then
    _hc_say "! accept_ra=2 is set on ${ifs[*]} until the next reboot, but ${HC_SYSCTL_FILE} could not be" \
            "  written to keep it. Add it by hand:"
    for i in "${ifs[@]}"; do _hc_say "     echo '$(_hc_ra_key "${i}") = 2' | sudo tee -a ${HC_SYSCTL_FILE}"; done
    HC_SUM_RA="set to 2 on ${ifs[*]} until the next reboot (${HC_SYSCTL_FILE} not written)"
    return 0
  fi
  _hc_say "↻ accept_ra=2 on ${ifs[*]} (kept in ${HC_SYSCTL_FILE}): this host's IPv6 route comes from" \
          "  router advertisements, and the stack's IPv6 network would otherwise make the kernel ignore them."
  HC_SUM_RA="set to 2 on ${ifs[*]} (kept in ${HC_SYSCTL_FILE})"
  return 0
}

# ── Can Docker make the stack's network here? ────────────────────────────────
# The version and the kernel say it should; this asks Docker to DO it: a throwaway
# network with an IPv6 /64 beside an IPv4 /30, created and removed at once. It is
# what the stack's own network needs, and what fails on hosts the two checks above
# pass — the ip6_tables module missing, ip6tables broken under a firewall manager,
# a daemon option that conflicts. Without it the refusal comes later, from `compose
# up`, after the backup, the swap and the pin.
#
# The subnets are our own (the stack's ULA Global ID, a /64 none of the compose files
# use; IPv4 /30s none of them use). A candidate Docker refuses as OVERLAPPING another
# network is not an answer about IPv6, so the next one is tried; when every one
# overlaps, nothing is refused on a guess. HC_NET_ERR holds what Docker said.
HC_PREFLIGHT_NETS="10.255.255.216/30,fd64:1fbc:c16e:fff0::/64 10.255.251.248/30,fd64:1fbc:c16e:fff1::/64 172.31.255.248/30,fd64:1fbc:c16e:fff2::/64"
HC_NET_ERR=""
HC_NET_TRY=""
hc_dual_stack_ok() {  # 0 = created and removed (or cannot tell); 1 = Docker refused it
  local name="taranac-v6-preflight-$$" pair v4 v6 err
  HC_NET_ERR=""
  for pair in ${HC_PREFLIGHT_NETS}; do
    v4="${pair%%,*}"; v6="${pair#*,}"
    HC_NET_TRY="docker network create --ipv6 --subnet ${v6} --subnet ${v4} taranac-v6-test && docker network rm taranac-v6-test"
    if err="$(docker network create --ipv6 --subnet "${v6}" --subnet "${v4}" --label com.taranac.preflight=1 "${name}" 2>&1)"; then
      docker network rm "${name}" >/dev/null 2>&1 || true
      HC_SUM_NET=ok
      return 0
    fi
    docker network rm "${name}" >/dev/null 2>&1 || true
    case "$(printf '%s' "${err}" | tr '[:upper:]' '[:lower:]')" in
      *overlap*) continue ;;
    esac
    HC_NET_ERR="${err}"
    return 1
  done
  HC_SUM_NET=overlap
  return 0
}

# ── The entry points ─────────────────────────────────────────────────────────
hc_require() {  # <install|update|bootstrap> [the command that runs it again]
  local who="$1" again="${2:-}" v
  if [ -z "${again}" ]; then
    case "${who}" in
      update)    again="./taranac update" ;;
      bootstrap) again="sudo bash bootstrap.sh" ;;
      *)         again="./install.sh" ;;
    esac
  fi
  v="$(hc_docker_version)"
  HC_SUM_DOCKER="${v}"
  if [ -n "${v}" ] && hc_docker_is_podman; then
    _hc_say "✗ The docker command here is Podman ${v}, not Docker Engine." \
            "  Taranac needs Docker Engine ${HC_DOCKER_MIN_MAJOR}.0 or newer: the stack's network (IPv6 for some" \
            "  containers, kept off it for the rest) and its compose files are Docker Engine's." \
            "  Nothing was changed. Install Docker Engine, then run  ${again}  again:"
    hc_docker_update_cure >&2
    return 1
  fi
  if [ -n "${v}" ] && ! hc_docker_ok "${v}"; then
    _hc_say "✗ Docker ${v} is too old — Taranac needs Docker ${HC_DOCKER_MIN_MAJOR}.0 or newer." \
            "  On older Docker a container cannot be kept off IPv6: the stack's internal names start" \
            "  resolving to IPv6 addresses nothing answers on, and the api and the portal stall." \
            "  Nothing was changed. Update Docker, then run  ${again}  again:"
    hc_docker_update_cure >&2
    return 1
  fi
  if ! hc_kernel_ipv6; then
    _hc_say "✗ This host's kernel has IPv6 turned off (/proc/net/if_inet6 does not exist — usually" \
            "  ipv6.disable=1 on the kernel command line). Taranac's web front end and the AAA" \
            "  daemons listen on IPv6 as well as IPv4 and cannot start without it. The host needs" \
            "  no IPv6 address or route — only the kernel's IPv6 support. Nothing was changed." \
            "  Remove ipv6.disable=1 from GRUB_CMDLINE_LINUX in /etc/default/grub, then" \
            "     sudo update-grub        (RHEL family: sudo grub2-mkconfig -o /boot/grub2/grub.cfg)" \
            "     sudo reboot" \
            "  and run  ${again}  again."
    return 1
  fi
  # Only of a daemon that said what it is (a test's stand-in that does not is not asked).
  if [ -n "${v}" ] && ! hc_dual_stack_ok; then
    _hc_say "✗ Docker refused to create a network with IPv6 beside IPv4 — the kind the stack runs on." \
            "  Docker said:"
    printf '%s\n' "${HC_NET_ERR}" | sed 's/^/     /' >&2
    _hc_say "  Nothing was changed. Fix what Docker names above (often: the ip6_tables kernel module" \
            "  is not loaded —  sudo modprobe ip6_tables  — or a firewall manager holds ip6tables)," \
            "  check that this now succeeds:" \
            "     ${HC_NET_TRY}" \
            "  and run  ${again}  again."
    return 1
  fi
  return 0
}

hc_prepare() {
  # Only on a host whose Docker answers with a version: the warnings and the fix are
  # about what Docker does to this host, and a daemon that does not say what it is
  # (a test's stand-in) does nothing to it.
  [ -n "$(hc_docker_version)" ] || return 0
  if hc_ip6tables_off; then
    _hc_say "! Docker's ip6tables is turned off (${HC_IP6T_WHERE}). IPv6 devices and browsers will" \
            "  reach Taranac from the Docker gateway's address, not their own — devices are matched," \
            "  logged and blocked by that one address. To give them their own: remove that setting" \
            "  and restart Docker (sudo systemctl restart docker), then  ./taranac up -d"
  fi
  hc_accept_ra_fix
}

# One line for the output and the update's trail: what was checked and what was changed
# on the host, after hc_require and hc_prepare said go.
hc_summary() {
  local net
  if [ -z "${HC_SUM_DOCKER}" ]; then
    printf '%s\n' "Host: Docker did not say its version — the host checks were not run."
    return 0
  fi
  case "${HC_SUM_NET}" in
    ok)      net="dual-stack network test ✓" ;;
    overlap) net="dual-stack network test not run (every test subnet overlaps a network here)" ;;
    *)       net="dual-stack network test not run" ;;
  esac
  printf 'Host: Docker %s ✓, kernel IPv6 ✓, %s, %saccept_ra: %s\n' "${HC_SUM_DOCKER}" "${net}" \
    "$(hc_ip6tables_off && printf "Docker's ip6tables OFF (%s), " "${HC_IP6T_WHERE}")" \
    "${HC_SUM_RA:-nothing changed}"
}

# ── The inventory entries the gateway address used to match ──────────────────
# Until the stack network had IPv6, an IPv6 device arrived from the gateway's IPv4
# address; an inventory entry covering that address (the /27, a /8, 0.0.0.0/0 or the
# address itself) matched every IPv6 device. With the device's own address arriving,
# such an entry matches none of them any more. Asked of the api's own preflight
# (app.scripts.diag) — the one place that reads the inventory the way the daemons do.
hc_stack_gateway() {  # [network]
  local net="${1:-taranac_default}" gw
  gw="$(docker network inspect "${net}" -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if (index($i, ":") == 0) { print $i; exit } }')" || true
  printf '%s' "${gw}"
}

hc_stack_has_ipv6() {  # [network] → 0 when the network carries an IPv6 subnet
  docker network inspect "${1:-taranac_default}" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | grep -q ':'
}

# The api is asked with a ceiling: a wedged api (or a container that is "running" with
# its python stuck) must not hold the installer or the updater forever. Running out of
# it is NOT an answer — rc 2, and the callers say they could not tell.
HC_EXEC_TIMEOUT="${HC_EXEC_TIMEOUT:-30}"
hc_gateway_entries() {  # <api container> [network] → "name<TAB>address<TAB>protocols" per entry; rc 2 = the api did not answer in time
  local api="$1" net="${2:-taranac_default}" gw json rc=0
  local -a tmo=()
  gw="$(hc_stack_gateway "${net}")"
  [ -n "${gw}" ] && [ -n "${api}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v timeout >/dev/null 2>&1 && tmo=(timeout "${HC_EXEC_TIMEOUT}")
  json="$(${tmo[@]+"${tmo[@]}"} docker exec "${api}" python -m app.scripts.diag preflight --device-ip "${gw}" --protocol tacacs 2>/dev/null)" || rc=$?
  [ "${rc}" = 124 ] && return 2
  [ "${rc}" = 0 ] || return 0
  printf '%s' "${json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in d.get("matched_devices") or []:
    flags = m.get("protocol_flags") or {}
    on = [p for p in ("tacacs", "radius", "nac") if flags.get(p)]
    if on:
        print("{}\t{}\t{}".format(m.get("name", "?"), m.get("address", "?"), ", ".join(on)))
' 2>/dev/null || true
}

# How many inventory entries with TACACS+, RADIUS or NAC on hold an IPv6 address, prefix
# or range. Asked of the RUNNING api — on the update the gate below exists for, that is
# the OLD release, whose diag has no such question; so the query travels with this
# script: two tables and four columns, unchanged since devices got network objects.
# Printed behind a marker so a SQL echo on stdout cannot be read as the answer.
HC_IPV6_ENTRIES_PY="$(cat <<'PY'
import asyncio, logging
from sqlalchemy import text
from app.database import async_session_factory
for name in ("sqlalchemy", "sqlalchemy.engine", "sqlalchemy.engine.Engine", "sqlalchemy.pool"):
    logging.getLogger(name).handlers.clear()
    logging.getLogger(name).setLevel(logging.WARNING)
Q = text("""
SELECT count(*) FROM devices d JOIN network_objects n ON n.id = d.network_object_id
WHERE (family(n.network) = 6 OR family(n.range_start) = 6)
  AND (d.protocol_flags @> '{"tacacs": true}' OR d.protocol_flags @> '{"radius": true}'
       OR d.protocol_flags @> '{"nac": true}')
""")
async def main():
    async with async_session_factory() as s:
        print("TARANAC_IPV6_ENTRIES=%d" % (await s.execute(Q)).scalar_one())
asyncio.run(main())
PY
)"
hc_ipv6_entries() {  # <api container> → the count; rc 2 = no answer in time, 1 = no answer
  local api="$1" out rc=0
  local -a tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout "${HC_EXEC_TIMEOUT}")
  out="$(${tmo[@]+"${tmo[@]}"} docker exec "${api}" python -c "${HC_IPV6_ENTRIES_PY}" 2>/dev/null)" || rc=$?
  [ "${rc}" = 124 ] && return 2
  [ "${rc}" = 0 ] || return 1
  out="$(printf '%s\n' "${out}" | sed -n 's/^TARANAC_IPV6_ENTRIES=\([0-9][0-9]*\)$/\1/p' | tail -1)"
  [ -n "${out}" ] || return 1
  printf '%s' "${out}"
}

# ── Before the network gains IPv6: the entries that stop matching ────────────
# Asked by the updater and by install.sh's upgrade path while the stack network is
# still IPv4-only, before anything is changed. An entry that covers the gateway (the
# /27, a /8, 0.0.0.0/0) holds every IPv6 device today; after the change it holds none.
#
# A refusal only while the inventory has NO IPv6 entry at all: then every IPv6 device
# is refused as unknown the moment the update ends, and a warning would scroll past
# with the outage after it. One IPv6 entry is the operator having described IPv6
# devices — what the refusal asks for — so from then on the entries are a warning.
# Asking "does each IPv6 device have one" is out of reach: the inventory does not know
# which IPv6 addresses its devices have. Going on without any is a decision — typed at
# a terminal, or TARANAC_IPV6_OWN_ADDRESS_OK=1 (what --ipv6-own-address-ok sets).
#   <api> <network> <the command that runs it again> <the same, going on anyway>
# 0 = go (nothing to say, already IPv6, IPv6 entries exist, or consent); 1 = refused, all of it said.
hc_inventory_gate() {
  local api="$1" net="$2" again="$3" again_ok="$4" rows rc=0 name addr protos lines="" gw note reply=""
  local v6n="" v6rc=0
  hc_stack_has_ipv6 "${net}" && return 0
  rows="$(hc_gateway_entries "${api}" "${net}")" || rc=$?
  if [ "${rc}" = 2 ]; then
    _hc_say "! Could not check which inventory entries match IPv6 devices today:" \
            "  the api (${api}) did not answer within ${HC_EXEC_TIMEOUT} s." \
            "  After this change IPv6 devices are matched by their own address. Once the stack is up," \
            "  run  ./taranac diagnose  — it names any entry an IPv6 device no longer matches."
    return 0
  fi
  [ -n "${rows}" ] || return 0
  gw="$(hc_stack_gateway "${net}")"
  while IFS=$'\t' read -r name addr protos; do
    [ -n "${name}" ] || continue
    case "${addr}" in
      0.0.0.0/0) note="  ← every IPv4 address, never an IPv6 one" ;;
      */32|*/128) note="" ;;
      */*) note="  ← a subnet" ;;
      *) note="" ;;
    esac
    lines="${lines}      ${name} [${addr}] (${protos})${note}"$'\n'
  done <<<"${rows}"
  v6n="$(hc_ipv6_entries "${api}")" || v6rc=$?
  local body
  body="  Until now every IPv6 device reached Taranac from the Docker gateway ${gw}, and these
  inventory entries cover that address — so today they match EVERY IPv6 device, with their key:
${lines}  After this change each IPv6 device arrives with its own address and none of these entries
  matches it any more."
  if [ "${v6rc}" = 0 ] && [ "${v6n}" -gt 0 ]; then
    _hc_say "! IPv6 devices are matched by their OWN address from now on." "${body}" \
            "  The inventory already has ${v6n} IPv6 entr$([ "${v6n}" = 1 ] && echo y || echo ies) (address, prefix or range with TACACS+," \
            "  RADIUS or NAC on), so this goes on: an IPv6 device is matched by its own entry, and one" \
            "  that has none is refused as an unknown device. After the update, which entry a device" \
            "  gets:  ./taranac diagnose --protocol <tacacs|radius|nac> --device <its IPv6 address>"
    return 0
  fi
  local none
  case "${v6rc}" in
    0) none="  The inventory has no IPv6 entry at all (no IPv6 address, prefix or range with TACACS+,
  RADIUS or NAC on), so every IPv6 device is refused as an unknown device after it." ;;
    2) none="  Whether the inventory has any IPv6 entry could not be checked: the api (${api}) did not
  answer within ${HC_EXEC_TIMEOUT} s — taken as none, so every IPv6 device may be refused as unknown." ;;
    *) none="  Whether the inventory has any IPv6 entry could not be checked (the api (${api}) did not
  answer) — taken as none, so every IPv6 device may be refused as unknown." ;;
  esac
  local cond="  This stops only while such entries exist AND the inventory has no IPv6 entry at all."
  if [ "${TARANAC_IPV6_OWN_ADDRESS_OK:-0}" = 1 ]; then
    _hc_say "! IPv6 devices are matched by their OWN address from now on (going on: --ipv6-own-address-ok)." \
            "${body}" "${none}" \
            "  Give each IPv6 device an entry of its own (its IPv6 address or prefix, or ::/0) with the key."
    return 0
  fi
  if [ -t 0 ]; then
    _hc_say "! IPv6 devices will be matched by their OWN address." "${body}" "${none}" "${cond}" \
            "  To avoid that, stop here and add next to each entry an IPv6 one with the same key — the" \
            "  devices' IPv6 addresses or prefix, or ::/0 for all of them — then run  ${again}"
    printf '%s' "  Type CONTINUE to go on now (IPv6 devices refused until they have entries), anything else stops: " >&2
    read -r reply || reply=""
    [ "${reply}" = CONTINUE ] && return 0
    _hc_say "  Stopped — nothing was changed."
    return 1
  fi
  _hc_say "✗ IPv6 devices will be matched by their OWN address." "${body}" "${none}" "${cond}" \
          "  Nothing was changed. Add next to each entry an IPv6 one with the same key — the devices'" \
          "  IPv6 addresses or prefix, or ::/0 for all of them — then run:" \
          "     ${again}" \
          "  To go on now and add the IPv6 entries afterwards (IPv6 devices are refused until then):" \
          "     ${again_ok}"
  return 1
}

# ── TACACS+ logins from outside the inventory ────────────────────────────────
# Until this release `device world` held the global key: an address with no inventory
# entry logged in with it. Now TACACS+ is accepted only from inventoried devices, and
# such an address is refused after the update. The refusal shows after the fact (a
# "Not in the inventory" row, an Unknown device alert) — by then the device is locked
# out — so the operator is told BEFORE the update which addresses did that in the last
# 30 days. A warning, never a refusal (24.10.2026): the update goes on, and the log
# is where a device left out shows up.
#
# Asked of the RUNNING api — on the update this is for, the OLD release — so the query
# travels with this script, like the IPv6 count above. A successful authentication row
# without a device is such a login: up to this release the parser resolved the device
# from the same set the device blocks were rendered from (enabled, TACACS+ on), so an
# address it did not resolve met `world`. An address an enabled TACACS+ entry covers
# NOW (added since) is left out; one only a disabled entry (or one without TACACS+)
# covers is marked so. Coverage is worked out here with ipaddress, not in SQL: no
# cast of a stored string can fail the query. Behind markers, like the count above.
HC_WORLD_DAYS=30
HC_WORLD_SHOWN=20
HC_WORLD_LOGINS_PY="$(cat <<'PY'
import asyncio, ipaddress, logging, sys
from sqlalchemy import text
from app.database import async_session_factory
for name in ("sqlalchemy", "sqlalchemy.engine", "sqlalchemy.engine.Engine", "sqlalchemy.pool"):
    logging.getLogger(name).handlers.clear()
    logging.getLogger(name).setLevel(logging.WARNING)
DAYS, SHOWN = int(sys.argv[1]), int(sys.argv[2])
LOGINS = text("""
SELECT nas_ip, max(timestamp) AS last_seen FROM tacacs_authn_logs
WHERE timestamp >= now() - make_interval(days => :days)
  AND status = 'success' AND device_id IS NULL
GROUP BY nas_ip ORDER BY last_seen DESC
""")
ENTRIES = text("""
SELECT n.network::text, host(n.range_start), host(n.range_end),
       d.is_enabled AND d.protocol_flags @> '{"tacacs": true}'
FROM devices d JOIN network_objects n ON n.id = d.network_object_id
""")
def addr(value):
    try:
        a = ipaddress.ip_address((value or "").strip())
    except ValueError:
        return None
    return a.ipv4_mapped or a if a.version == 6 else a
def covers(entry, a):
    network, start, end = entry[:3]
    try:
        if network:
            return a in ipaddress.ip_network(network, strict=False)
        if start and end:
            lo, hi = ipaddress.ip_address(start), ipaddress.ip_address(end)
            return lo.version == a.version and lo <= a <= hi
    except ValueError:
        pass
    return False
async def main():
    async with async_session_factory() as s:
        logins = (await s.execute(LOGINS, {"days": DAYS})).all()
        entries = (await s.execute(ENTRIES)).all()
    found = []
    for nas_ip, _ in logins:
        a = addr(nas_ip)
        if a is None or str(a) in (f for f, _ in found):
            continue
        hits = [e for e in entries if covers(e, a)]
        if any(e[3] for e in hits):
            continue
        found.append((str(a), "listed" if hits else ""))
    print("TARANAC_WORLD_TOTAL=%d" % len(found))
    for ip, mark in found[:SHOWN]:
        print("TARANAC_WORLD_IP=%s\t%s" % (ip, mark))
asyncio.run(main())
PY
)"
hc_world_logins() {  # <api container> [network] → always 0; the warning, if any, on stderr
  local api="$1" net="${2:-taranac_default}" out rc=0 total gw ip mark lines="" more=""
  local -a tmo=()
  command -v timeout >/dev/null 2>&1 && tmo=(timeout "${HC_EXEC_TIMEOUT}")
  out="$(${tmo[@]+"${tmo[@]}"} docker exec "${api}" python -c "${HC_WORLD_LOGINS_PY}" \
         "${HC_WORLD_DAYS}" "${HC_WORLD_SHOWN}" 2>/dev/null)" || rc=$?
  total="$(printf '%s\n' "${out}" | sed -n 's/^TARANAC_WORLD_TOTAL=\([0-9][0-9]*\)$/\1/p' | tail -1)"
  if [ "${rc}" != 0 ] || [ -z "${total}" ]; then
    _hc_say "! Not checked which addresses logged in to TACACS+ without an inventory entry in the last ${HC_WORLD_DAYS} days: the api (${api}) did not answer$([ "${rc}" = 124 ] && echo " within ${HC_EXEC_TIMEOUT} s")."
    return 0
  fi
  [ "${total}" -gt 0 ] || return 0
  gw="$(hc_stack_gateway "${net}")"
  while IFS=$'\t' read -r ip mark; do
    [ -n "${ip}" ] || continue
    if [ -n "${gw}" ] && [ "${ip}" = "${gw}" ]; then
      mark="  ← the Docker gateway: IPv6 devices without an entry arrived from it"
    elif [ "${mark}" = listed ]; then
      mark="  ← in the inventory, but disabled or without TACACS+"
    else
      mark=""
    fi
    lines="${lines}      ${ip}${mark}"$'\n'
  done < <(printf '%s\n' "${out}" | sed -n 's/^TARANAC_WORLD_IP=//p' | head -n "${HC_WORLD_SHOWN}")
  [ "${total}" -gt "${HC_WORLD_SHOWN}" ] && more="      (+$((total - HC_WORLD_SHOWN)) more)"$'\n'
  _hc_say "! After this update TACACS+ accepts only devices in the inventory. In the last ${HC_WORLD_DAYS} days these" \
          "  addresses logged in with the global key without an inventory entry of their own:" \
          "${lines}${more}  Add them to the inventory (or enable their entry, with TACACS+ on): after the update each" \
          "  is refused — a \"Not in the inventory\" row in the Authentication Log and an Unknown TACACS+" \
          "  device alert."
  return 0
}

# ── diagnose: facts and problems ─────────────────────────────────────────────
hc_facts() {
  local v ifn why ra fwd any=""
  v="$(hc_docker_version)"
  echo "docker_server  : ${v:-unknown}$( [ -n "${v}" ] && ! hc_docker_ok "${v}" && echo " — TOO OLD, Taranac needs ${HC_DOCKER_MIN_MAJOR}.0+")"
  if hc_kernel_ipv6; then echo "kernel_ipv6    : yes"; else echo "kernel_ipv6    : NO (/proc/net/if_inet6 missing)"; fi
  if hc_ip6tables_off; then echo "docker_ip6tables: OFF (${HC_IP6T_WHERE})"; else echo "docker_ip6tables: on"; fi
  fwd="$(cat "${HC_ROOT}/proc/sys/net/ipv6/conf/all/forwarding" 2>/dev/null || echo unknown)"
  echo "ipv6_forwarding: ${fwd}"
  while IFS=$'\t' read -r ifn why; do
    [ -n "${ifn}" ] || continue
    ra="$(cat "${HC_ROOT}/proc/sys/net/ipv6/conf/${ifn}/accept_ra" 2>/dev/null || echo '?')"
    echo "accept_ra      : ${ifn}=${ra} (${why})$( [ "${ra}" = 1 ] && echo ' — ignores router advertisements once forwarding is on')"
    any=1
  done < <(_hc_ra_sources | sort -u)
  [ -n "${any}" ] || echo "accept_ra      : (no interface takes its IPv6 address or default route from router advertisements)"
}

hc_problems() {  # one finding per line, already worded for the summary
  local v i
  v="$(hc_docker_version)"
  if [ -n "${v}" ] && ! hc_docker_ok "${v}"; then
    echo "Docker ${v} is older than ${HC_DOCKER_MIN_MAJOR}.0: containers kept off IPv6 still get IPv6 addresses, and name lookups inside the stack stall. Update Docker."
  fi
  hc_kernel_ipv6 || echo "the kernel has IPv6 turned off (no /proc/net/if_inet6): the web front end and the IPv6 listeners cannot start."
  if [ -n "${v}" ] && hc_ip6tables_off; then
    echo "Docker's ip6tables is off (${HC_IP6T_WHERE}): IPv6 devices reach Taranac from the Docker gateway's address, not their own."
  fi
  while read -r i; do
    [ -n "${i}" ] && echo "${i} has accept_ra=1 and takes its IPv6 address or default route from router advertisements: with IPv6 forwarding on (Docker's IPv6 network) the host stops accepting them and loses its IPv6 route. ./taranac update sets accept_ra=2."
  done < <(hc_accept_ra_ifaces)
  return 0
}

# The inventory entries covering the gateway, as a diagnose FINDING — or nothing. A
# finding only while IPv6 devices still arrive from the gateway's address (the stack
# network without IPv6, Docker's ip6tables off, Docker older than 28): then those
# entries match every IPv6 device, with their key, and stop matching any of them the
# moment that changes. Once IPv6 devices arrive with their own address the entries
# match none of them for good — a fact (ipv6.txt lists them), not something to fix:
# said in every report, it was a finding nobody could ever clear (stand, 25.10.2026).
hc_gateway_finding() {  # <network> <gateway> <rows from hc_gateway_entries>
  local net="$1" gw="$2" rows="$3" names why cure v
  [ -n "${rows}" ] || return 0
  v="$(hc_docker_version)"
  if ! hc_stack_has_ipv6 "${net}"; then
    why="the stack network has no IPv6"; cure="after  ./taranac update  (it gives the network IPv6)"
  elif hc_ip6tables_off; then
    why="Docker's ip6tables is off: ${HC_IP6T_WHERE}"; cure="once ip6tables is on"
  elif [ -n "${v}" ] && ! hc_docker_ok "${v}"; then
    why="Docker ${v} is older than ${HC_DOCKER_MIN_MAJOR}.0"; cure="once Docker is updated"
  else
    return 0
  fi
  names="$(printf '%s\n' "${rows}" | awk -F'\t' 'NF { printf "%s%s [%s]", (n++ ? ", " : ""), $1, $2 }')"
  printf '%s\n' "inventory entries cover the Docker gateway ${gw}: ${names}. Every IPv6 device arrives from that address today (${why}), so these entries match all of them, with their key; ${cure} each arrives with its own address and none of these matches it — give each IPv6 device an entry of its own first (ipv6.txt)."
}

# Per published port of <container>: "<port>/<proto>  IPv6 listener: yes|no  IPv6 DNAT: yes|no|unknown".
# The listener is read inside the container (ss, else netstat): a socket on [::], ::
# or * (dual-stack) at that port and protocol. The DNAT is Docker's rule in the IPv6
# nat table (ip6tables and nft, both asked) — root only, so <sudo> is the prefix to use, and
# without root the answer is "unknown". HC_V6_FINDINGS collects what is wrong.
HC_V6_FINDINGS=()
hc_v6_ports() {  # <container> [sudo prefix]
  local ct="$1" sudo_cmd="${2:-}" pub lst nat="" can_nat="" cport proto hport lis dn
  HC_V6_FINDINGS=()
  pub="$(docker port "${ct}" 2>/dev/null | awk '{ split($1, a, "/"); n = split($3, h, ":"); print a[1] "\t" a[2] "\t" h[n] }' | sort -u)"
  [ -n "${pub}" ] || return 0
  lst="$(docker exec "${ct}" sh -c '(ss -lntu 2>/dev/null || netstat -lntu 2>/dev/null)' 2>/dev/null || true)"
  # BOTH tools, whichever answers: on a host where Docker programs nftables natively
  # (firewall-backend nftables) or through the legacy ip6tables while the tool on PATH
  # is the other one, the first one asked answers with an empty table — and "no DNAT"
  # read from it alone was a false finding.
  local out
  if [ "$(id -u)" = 0 ] || [ -n "${sudo_cmd}" ]; then
    if command -v ip6tables >/dev/null 2>&1 && out="$(${sudo_cmd} ip6tables -t nat -S 2>/dev/null)"; then
      nat="${out}"; can_nat=1
    fi
    if command -v nft >/dev/null 2>&1 && out="$(${sudo_cmd} nft list ruleset ip6 2>/dev/null)"; then
      nat="${nat}"$'\n'"${out}"; can_nat=1
    fi
  fi
  while IFS=$'\t' read -r cport proto hport; do
    [ -n "${cport}" ] || continue
    if printf '%s\n' "${lst}" | awk -v p="${cport}" -v pr="${proto}" '
         tolower($1) ~ "^" pr { for (i = 2; i <= NF; i++) if ($i == "[::]:" p || $i == ":::" p || $i == "*:" p) f = 1 }
         END { exit !f }'; then
      lis=yes
    else
      lis=no
      HC_V6_FINDINGS+=("${ct} does not listen on IPv6 on ${cport}/${proto}: IPv6 devices get no answer on that port.")
    fi
    if [ -z "${can_nat}" ]; then
      dn="unknown (needs root)"
    elif printf '%s\n' "${nat}" | grep -Ei "dport ${hport}([^0-9]|\$)" | grep -qiE 'dnat'; then
      dn=yes
    else
      dn=no
      HC_V6_FINDINGS+=("no IPv6 DNAT for published port ${hport}/${proto}: IPv6 devices reach ${ct} through Docker's proxy, from the gateway's address (ip6tables off, Docker older than 28, or the stack network has no IPv6).")
    fi
    printf '%s/%s  IPv6 listener: %s  IPv6 DNAT: %s\n' "${hport}" "${proto}" "${lis}" "${dn}"
  done <<<"${pub}"
}
