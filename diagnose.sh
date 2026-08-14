#!/usr/bin/env bash
# Taranac diagnostic collector.
#
#   ./taranac diagnose --protocol tacacs --device 10.0.0.5
#
# Start it, reproduce the problem on the device, press Enter. It hands back one
# archive with everything needed to explain what happened — and tells you, in
# plain words, what it noticed.
#
# WHERE EACH PIECE COMES FROM
#   traffic  — tcpdump on the HOST, not inside the daemon container. The images
#              ship without tcpdump, and installing it into a container does not
#              survive the next recreate. On the host it is one package and it
#              stays. Capturing on `any` also sees BOTH the physical interface
#              and the docker bridge, so "arrived at the host but never reached
#              the container" (firewall/NAT) is visible instead of just absent.
#   logs     — docker exec into the daemon container (/var/log/taranac).
#   config   — the generated daemon config, secrets masked before it is stored.
#   facts    — docker exec into the api container: app.scripts.diag, which is
#              the only component that touches the database or the master key.
#
# NO SHARED SECRET IS EVER WRITTEN TO THE ARCHIVE. Secrets appear only as the
# 12-hex fingerprint Taranac already uses for key-anomaly reports: enough to
# prove "the device and Taranac disagree about the key", useless to an attacker
# who intercepts the archive on its way to support.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ── --ha forks before anything else ─────────────────────────────────────────
# HA is not a protocol and takes no --device: it is a snapshot of cluster state,
# collected on EVERY node and compared afterwards. Nothing below applies to it —
# no daemon container to read, no capture, no window — so it forks here rather
# than growing a fourth branch through checks that would all have to be skipped.
for arg in "$@"; do
  case "${arg}" in
    --ha)
      [ -f "${HERE}/diagnose-ha.sh" ] || {
        echo "✗ diagnose-ha.sh is missing from the bundle." >&2
        echo "  Refresh the bundle once ('./taranac update'), then retry." >&2
        exit 1
      }
      exec bash "${HERE}/diagnose-ha.sh" "$@"
      ;;
  esac
done

PROTOCOL=""
DEVICE_IP=""
CONFIG_REF=""
FULL_TRANSCRIPT=""
DURATION=""
OUT_DIR="${HERE}/diagnostics"
SNAPLEN=0            # full packets — TACACS+ bodies are useless when truncated
MAX_FILE_MB=100

usage() {
  cat <<'USAGE'
Collect a diagnostic bundle for one device and one protocol.

  ./taranac diagnose --protocol tacacs|radius|nac --device <IP> [options]
  ./taranac diagnose --protocol ncm --config "<tracked config name>" [options]
  ./taranac diagnose --ha                                          [options]

Options:
  --protocol P      tacacs (device administration), radius (device admin over
                    RADIUS), nac (802.1X port access) or ncm (configuration
                    collection)
  --ha              a snapshot of this node's view of the HA cluster (Pro).
                    Takes no --protocol and no --device — see below.
  --device IP       the network device's IP address, as Taranac sees it
                    (tacacs/radius/nac)
  --config NAME     the tracked configuration to diagnose (ncm), by name or id
  --duration SEC    capture for SEC seconds instead of waiting for Enter
  --out DIR         where to write the archive/report (default: ./diagnostics)
  --max-size MB     stop the capture past this size (default: 100)
  --full-transcript ncm only: keep recording past the first command. INCLUDES
                    THE DEVICE CONFIGURATION in the report — share with care.
  -h, --help        this text

What it does (tacacs/radius/nac):
  1. checks the device really is configured in Taranac for that protocol
  2. checks which ports the daemons are ACTUALLY listening on
  3. captures traffic to/from that device while you reproduce the problem
  4. collects the daemon log, the generated config (secrets masked) and the
     records Taranac itself wrote during the window
  5. packs it all into one .tar.gz and prints what it found

What it does (ncm):
  Runs ONE real collection for that tracked configuration — the same engine a
  scheduled run uses, but nothing is written to the configuration history — and
  writes a single report: what driver was resolved and why, whether the device
  answered, what the SSH handshake agreed on, and the login transcript up to the
  device prompt. No packet capture: Taranac is the client here and the session
  is encrypted, so the evidence is inside the session, not on the wire.

What it does (--ha):
  Takes a snapshot of what THIS node believes about the cluster: its own role and
  timeline, the etcd ring, Patroni's view, replication and slots, reachability to
  every declared member, certificates, clocks and logs. No capture and no window —
  HA faults are state, not events.

  Run the SAME command on every node, including the witness, and send all the
  archives. Most HA faults are DISAGREEMENTS between nodes, and a disagreement
  cannot be seen from one side of it. It is safe on a node whose database will not
  start, on a node that is not clustered at all, and on the witness.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --protocol) PROTOCOL="${2:-}"; shift 2 ;;
    --device)   DEVICE_IP="${2:-}"; shift 2 ;;
    --config)   CONFIG_REF="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --out)      OUT_DIR="${2:-}"; shift 2 ;;
    --max-size) MAX_FILE_MB="${2:-}"; shift 2 ;;
    --full-transcript) FULL_TRANSCRIPT="--full-transcript"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "${PROTOCOL}" in
  tacacs|radius|nac|ncm) ;;
  "") echo "✗ --protocol is required (tacacs, radius, nac or ncm)." >&2; exit 1 ;;
  *)  echo "✗ Unknown protocol '${PROTOCOL}' — expected tacacs, radius, nac or ncm." >&2; exit 1 ;;
esac

# ── NCM: a session recorder, not a packet capture ───────────────────────────
# Handled here, before every check below it, because none of them apply: there is
# no daemon container to read, no device IP to filter on (a tracked config can
# carry a hostname), and nothing to capture — the session is encrypted and
# Taranac is the side that opens it. Everything happens inside the api container,
# which is the only place holding both the database and the master key.
if [ "${PROTOCOL}" = "ncm" ]; then
  if [ -z "${CONFIG_REF}" ]; then
    echo "✗ --config is required for ncm — the tracked configuration's name (or its id)." >&2
    echo "  Example: ./taranac diagnose --protocol ncm --config \"core-sw-01 running-config\"" >&2
    exit 1
  fi
  for candidate in taranac-api taranac-api-dev; do
    if docker inspect -f '{{.State.Running}}' "${candidate}" 2>/dev/null | grep -q true; then
      NCM_API_CT="${candidate}"; break
    fi
  done
  if [ -z "${NCM_API_CT:-}" ]; then
    echo "✗ The api container is not running — it holds the database and the master key." >&2
    exit 1
  fi
  mkdir -p "${OUT_DIR}"
  REPORT="${OUT_DIR}/ncm-diagnostics-$(date -u +%Y%m%d-%H%M%S).txt"
  echo "Taranac diagnostic collector"
  echo "  protocol : ncm"
  echo "  config   : ${CONFIG_REF}"
  echo "  api      : ${NCM_API_CT}"
  echo
  echo "Connecting to the device once. Nothing is written to the configuration history."
  echo
  # The report goes to a file rather than the terminal: it is meant to be attached
  # to a ticket whole, and a scrolled-past transcript is a transcript nobody sends.
  if docker exec "${NCM_API_CT}" python -m app.scripts.ncm_diag \
       --config "${CONFIG_REF}" ${FULL_TRANSCRIPT} > "${REPORT}"; then
    grep -E '^(verdict|  - )' "${REPORT}" || true
    echo
    echo "Report: ${REPORT}  ($(wc -l < "${REPORT}") lines)"
    if [ -n "${FULL_TRANSCRIPT}" ]; then
      echo "⚠ --full-transcript was used: this report CONTAINS THE DEVICE CONFIGURATION."
    fi
    exit 0
  fi
  echo "✗ The diagnostics run failed. Partial output:" >&2
  cat "${REPORT}" >&2
  exit 1
fi

if [ -z "${DEVICE_IP}" ]; then
  echo "✗ --device is required — the IP address of the device to diagnose." >&2
  exit 1
fi
# Validate here rather than letting tcpdump fail ten steps later with its own
# wording. A hostname is rejected on purpose: the daemons match clients by IP,
# so a name that resolves elsewhere would quietly capture the wrong traffic.
#
# The octet range is checked, not just the shape: a pattern of "one to three
# digits" accepts 10.0.0.999, which then fails deep inside tcpdump with a
# message about the filter expression rather than about the address.
valid_ip() {
  local address="$1" part
  case "${address}" in
    *:*) printf '%s' "${address}" | grep -Eq '^[0-9a-fA-F:]+$' && return 0; return 1 ;;
  esac
  printf '%s' "${address}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  local IFS=.
  for part in ${address}; do
    [ "${part}" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

if ! valid_ip "${DEVICE_IP}"; then
  echo "✗ '${DEVICE_IP}' is not an IP address. Taranac matches devices by IP, not by name." >&2
  exit 1
fi

# ── Locate the containers ───────────────────────────────────────────────────
# Production names first, then the -dev suffix, so the same script serves a
# deployed bundle and a development stack without a flag to get wrong.
find_container() {  # $1 = base name -> prints the running container name
  local base="$1" candidate
  for candidate in "${base}" "${base}-dev"; do
    if docker inspect -f '{{.State.Running}}' "${candidate}" 2>/dev/null | grep -q true; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

case "${PROTOCOL}" in
  tacacs) DAEMON_BASE="taranac-tacacs" ;;
  radius) DAEMON_BASE="taranac-radius" ;;
  nac)    DAEMON_BASE="taranac-nac" ;;
esac

if ! DAEMON_CT="$(find_container "${DAEMON_BASE}")"; then
  echo "✗ The ${PROTOCOL} daemon container (${DAEMON_BASE}) is not running." >&2
  echo "  Nothing would be captured, because nothing is listening. Start the stack first:" >&2
  echo "      ./taranac up -d ${PROTOCOL}" >&2
  exit 1
fi
API_CT="$(find_container "taranac-api" || true)"

echo "Taranac diagnostic collector"
echo "  protocol : ${PROTOCOL}"
echo "  device   : ${DEVICE_IP}"
echo "  daemon   : ${DAEMON_CT}"
echo

# ── Step 1: is this device actually configured? ─────────────────────────────
# Before capturing anything. If the device is not configured, the capture will
# show requests arriving and nothing answering — and the operator would spend
# an hour on a packet trace to learn what one query answers now.
# The renderer is a real file, not a `python3 -c` string and not a heredoc on
# python's stdin: a heredoc would occupy stdin, leaving json.load() to read
# nothing and fail on valid data (observed — it reported an empty preflight
# while preflight.json in the bundle was perfectly fine).
RENDER_PY="$(mktemp)"
PREFLIGHT_FILE="$(mktemp)"
trap 'rm -f "${RENDER_PY}" "${PREFLIGHT_FILE}"' EXIT
cat > "${RENDER_PY}" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    d = json.load(fh)
mode = sys.argv[2] if len(sys.argv) > 2 else ""
findings_only = mode == "--findings-only"

if mode == "--matches":
    # Every network object covering this address, not just the winner. One IP
    # can be inside a host entry AND two subnets at once, each with its own
    # key — support needs to see the whole set to explain which one the daemon
    # applied and why the device may be using another.
    matches = d.get("matched_devices", [])
    if not matches:
        print("  no device in Taranac covers this address")
    else:
        print("  {} object(s) in Taranac cover this address:".format(len(matches)))
        for i, m in enumerate(matches):
            marker = "  <- most specific, used by the daemon" if i == 0 else ""
            print("    {} [{}] {}{}".format(m["name"], m["address"], m["entry_type"], marker))
            print(
                "        enabled={}  protocol={}  key from {} (fp {})".format(
                    m["is_enabled"],
                    "on" if m["protocol_enabled"] else "OFF",
                    m["secret_source"],
                    m["secret_fingerprint"],
                )
            )
            if m["groups"]:
                print("        groups: {}".format(", ".join(m["groups"])))
    raise SystemExit(0)

if not findings_only:
    for m in d.get("matched_devices", []):
        state = "enabled" if m["is_enabled"] else "DISABLED"
        proto = "on" if m["protocol_enabled"] else "OFF"
        print("  device: {} [{}] - {}, protocol {}".format(m["name"], m["address"], state, proto))
        print("          secret from {}, fingerprint {}".format(m["secret_source"], m["secret_fingerprint"]))
        if m["groups"]:
            print("          groups: {}".format(", ".join(m["groups"])))
    if not d.get("matched_devices"):
        print("  device: NOT FOUND in Taranac")

prefix = "  [config] " if findings_only else "  x "
note_prefix = "  [note]   " if findings_only else "  ! "
for p in d.get("problems", []):
    print(prefix + p)
for n in d.get("notes", []):
    print(note_prefix + n)
PY

PREFLIGHT_JSON=""
if [ -n "${API_CT}" ]; then
  echo "→ Checking how ${DEVICE_IP} is configured in Taranac…"
  if PREFLIGHT_JSON="$(docker exec "${API_CT}" python -m app.scripts.diag \
        preflight --device-ip "${DEVICE_IP}" --protocol "${PROTOCOL}" 2>/dev/null)" \
     && [ -n "${PREFLIGHT_JSON}" ]; then
    printf '%s' "${PREFLIGHT_JSON}" > "${PREFLIGHT_FILE}"
    python3 "${RENDER_PY}" "${PREFLIGHT_FILE}" || echo "  (could not render the preflight result)"
  else
    echo "  ! Preflight failed — continuing with the capture anyway."
    PREFLIGHT_JSON=""
  fi
else
  echo "! The api container is not running — skipping the configuration check."
  echo "  The capture still works, but nothing will verify the device is set up."
fi
echo

# ── Step 2: which ports is the daemon ACTUALLY listening on? ────────────────
# Read them from the running process, never from the documented defaults: a
# custom port is exactly the kind of thing that makes a capture come back empty
# and get blamed on the device.
mapfile -t CONTAINER_PORTS < <(
  docker exec "${DAEMON_CT}" sh -c '(ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null)' 2>/dev/null \
    | awk '$0 ~ /LISTEN|udp/ { print $4 }' \
    | sed 's/.*://' \
    | grep -E '^[0-9]+$' \
    | sort -un
)
# Drop loopback-only helper sockets (FreeRADIUS status server, docker DNS):
# they never carry device traffic and would widen the filter for nothing.
mapfile -t LOCAL_ONLY < <(
  docker exec "${DAEMON_CT}" sh -c '(ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null)' 2>/dev/null \
    | awk '$4 ~ /^127\./ { print $4 }' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un
)
PORTS=()
for p in "${CONTAINER_PORTS[@]:-}"; do
  [ -n "${p}" ] || continue
  skip=""
  for l in "${LOCAL_ONLY[@]:-}"; do [ "${p}" = "${l}" ] && skip=1; done
  [ -n "${skip}" ] || PORTS+=("${p}")
done

# The published host ports too: with a remapped port (TACACS_PORT=4949) the
# packet carries 4949 on the physical interface and 49 on the bridge after
# docker's DNAT. Filtering on only one set silently loses half the story.
mapfile -t HOST_PORTS < <(docker port "${DAEMON_CT}" 2>/dev/null | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un)
for p in "${HOST_PORTS[@]:-}"; do
  [ -n "${p}" ] || continue
  seen=""
  for q in "${PORTS[@]:-}"; do [ "${p}" = "${q}" ] && seen=1; done
  [ -n "${seen}" ] || PORTS+=("${p}")
done

if [ ${#PORTS[@]} -eq 0 ]; then
  echo "✗ ${DAEMON_CT} is running but is not listening on any port." >&2
  echo "  Check the daemon's own log — it likely failed to load its config:" >&2
  echo "      ./taranac logs ${PROTOCOL}" >&2
  exit 1
fi

PORT_LIST="$(IFS=,; echo "${PORTS[*]}")"
echo "→ ${DAEMON_CT} is listening on: ${PORT_LIST}"

# ── Step 3: tcpdump ─────────────────────────────────────────────────────────
if ! command -v tcpdump >/dev/null 2>&1; then
  echo "✗ tcpdump is not installed on this host — it is what captures the traffic." >&2
  echo >&2
  if command -v apt-get >/dev/null 2>&1; then
    echo "    sudo apt-get install -y tcpdump" >&2
  elif command -v dnf >/dev/null 2>&1; then
    echo "    sudo dnf install -y tcpdump" >&2
  elif command -v yum >/dev/null 2>&1; then
    echo "    sudo yum install -y tcpdump" >&2
  else
    echo "    install the 'tcpdump' package with this system's package manager" >&2
  fi
  echo >&2
  echo "  Then run this command again." >&2
  exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
  else
    echo "✗ Capturing packets needs root, and this account cannot sudo without a password." >&2
    echo "  Re-run as root:   sudo $0 --protocol ${PROTOCOL} --device ${DEVICE_IP}" >&2
    exit 1
  fi
fi

# ── Step 4: prepare the bundle ──────────────────────────────────────────────
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BUNDLE="taranac-diag-${PROTOCOL}-${DEVICE_IP//[.:]/_}-${STAMP}"
WORK="${OUT_DIR}/${BUNDLE}"
mkdir -p "${WORK}"
[ -n "${PREFLIGHT_JSON}" ] && printf '%s\n' "${PREFLIGHT_JSON}" > "${WORK}/preflight.json"

# Log positions BEFORE the capture. Slicing by byte offset rather than by
# timestamp is deliberate: the daemons log in three different time formats
# (tac_plus' syslog has no year at all), and a parser for each is a parser that
# can silently return nothing. A byte offset cannot misread a date.
# Not just the top level: tac_plus files its per-day authentication,
# authorization and accounting logs under /var/log/taranac/<kind>/<YYYYMM>/, and
# the authorization log is where a request rejected before the ruleset shows up
# — the exact case a top-level-only search would miss. Restricted to files
# touched in the last day so a year of archives does not end up in the bundle.
declare -A LOG_START
mapfile -t LOG_FILES < <(docker exec "${DAEMON_CT}" sh -c \
  'find /var/log/taranac -maxdepth 3 -type f -name "*.log" -mtime -1 2>/dev/null' 2>/dev/null || true)
LOG_OFFSETS=""
for f in "${LOG_FILES[@]:-}"; do
  [ -n "${f}" ] || continue
  offset="$(docker exec "${DAEMON_CT}" sh -c "wc -c < '${f}' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')"
  # A non-numeric answer (docker hiccup, file vanished) must not silently become
  # 0 — that would quietly ship the WHOLE log and call it "the window".
  case "${offset}" in
    ''|*[!0-9]*) offset=0 ;;
  esac
  LOG_START["${f}"]="${offset}"
  LOG_OFFSETS="${LOG_OFFSETS}${f} @ ${offset}"$'\n'
done

# Capture on `any`: one process covering the physical interface AND the docker
# bridge. Yes, a packet crossing both appears twice — that duplication is the
# point. Two copies means it was forwarded; one copy on the physical interface
# alone means it never reached the container.
FILTER="host ${DEVICE_IP} and (port $(IFS=' '; echo "${PORTS[*]}" | sed 's/ / or port /g'))"
PCAP="${WORK}/capture.pcap"

echo
echo "→ Capturing on all interfaces, filter: ${FILTER}"
# -C/-W caps the size so a forgotten collector cannot fill the disk. tcpdump
# appends a rotation suffix to the name when -C is used (capture.pcap1), so the
# real file is resolved after the capture rather than assumed here.
#
# -Z is not optional: on Debian/Ubuntu tcpdump drops privileges to the unrelated
# 'tcpdump' user right after opening the socket, and that user cannot create the
# output file in an operator-owned directory — the capture dies instantly with
# "Permission denied" on a path that is plainly writable. Hand it back the
# invoking account so the file lands with the right owner.
CAPTURE_USER="$(id -un)"
# shellcheck disable=SC2086
${SUDO} tcpdump -i any -s ${SNAPLEN} -Z "${CAPTURE_USER}" -w "${PCAP}" \
  -C "${MAX_FILE_MB}" -W 1 -U "${FILTER}" >"${WORK}/tcpdump.stderr" 2>&1 &
TCPDUMP_PID=$!

# `kill -0` is the usual liveness test, but tcpdump runs under sudo as root and
# this shell does not: kill -0 then fails with EPERM on a perfectly alive
# process, which reads exactly like "it died". /proc needs no privilege.
alive() { [ -d "/proc/${1}" ]; }

cleanup() {
  if alive "${TCPDUMP_PID}"; then
    ${SUDO} kill -INT "${TCPDUMP_PID}" 2>/dev/null || true
    wait "${TCPDUMP_PID}" 2>/dev/null || true
  fi
}
trap 'cleanup; echo; echo "Interrupted — collecting what we have."' INT TERM

sleep 1
if ! alive "${TCPDUMP_PID}"; then
  echo "✗ tcpdump exited immediately:" >&2
  sed 's/^/    /' "${WORK}/tcpdump.stderr" >&2
  exit 1
fi

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "════════════════════════════════════════════════════════════════"
echo "  Capturing. Reproduce the problem on ${DEVICE_IP} now."
if [ -n "${DURATION}" ]; then
  echo "  Stopping automatically in ${DURATION}s."
  echo "════════════════════════════════════════════════════════════════"
  sleep "${DURATION}"
else
  echo "  Press Enter when you are done."
  echo "════════════════════════════════════════════════════════════════"
  read -r _ || true
fi

cleanup
trap - INT TERM
ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "→ Capture stopped."

# ── Step 5: collect everything else ─────────────────────────────────────────
mkdir -p "${WORK}/logs" "${WORK}/config"

# Resolve the file tcpdump actually wrote and give it the canonical name. Done
# here, immediately after the capture, because everything below — the decode
# above all — refers to ${PCAP} by that name.
if [ ! -f "${PCAP}" ]; then
  ROTATED="$(ls -1 "${PCAP}"* 2>/dev/null | head -1 || true)"
  [ -n "${ROTATED}" ] && ${SUDO} mv "${ROTATED}" "${PCAP}"
fi
[ -f "${PCAP}" ] && ${SUDO} chown "$(id -u):$(id -g)" "${PCAP}" 2>/dev/null || true

# Count packets here, before anything decides whether to decode: an empty
# capture is still a 24-byte file, so "the file exists" is not the same as
# "there is traffic", and acting on the file alone produced a bundle that
# announced a decode of nothing.
PKT_COUNT=0
CAPTURE_TRUNCATED=""
if [ -f "${PCAP}" ]; then
  PKT_COUNT="$(tcpdump -r "${PCAP}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  # At the cap, -W 1 wraps and overwrites from the start: the tail survived,
  # the beginning did not. Say so — a silently half-missing trace is worse
  # than a short one, because the gap looks like the device went quiet.
  size_mb=$(( $(stat -c %s "${PCAP}" 2>/dev/null || echo 0) / 1048576 ))
  [ "${size_mb}" -ge "${MAX_FILE_MB}" ] && CAPTURE_TRUNCATED=1
fi

# Files that appeared DURING the window are not in the list taken before it —
# a debug log switched on to reproduce the problem, or the first log line after
# midnight rolls to a new daily file. Those are exactly the interesting ones, so
# look again and take anything new from the beginning.
mapfile -t LOG_FILES_AFTER < <(docker exec "${DAEMON_CT}" sh -c \
  'find /var/log/taranac -maxdepth 3 -type f -name "*.log" -mtime -1 2>/dev/null' 2>/dev/null || true)
for f in "${LOG_FILES_AFTER[@]:-}"; do
  [ -n "${f}" ] || continue
  known=""
  for seen_file in "${LOG_FILES[@]:-}"; do [ "${f}" = "${seen_file}" ] && known=1; done
  if [ -z "${known}" ]; then
    LOG_FILES+=("${f}")
    LOG_START["${f}"]=0
    LOG_OFFSETS="${LOG_OFFSETS}${f} @ 0 (appeared during the capture)"$'\n'
  fi
done

ROTATED_NOTE=""
for f in "${LOG_FILES[@]:-}"; do
  [ -n "${f}" ] || continue
  start="${LOG_START[${f}]:-0}"
  now="$(docker exec "${DAEMON_CT}" sh -c "wc -c < '${f}' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')"
  case "${now}" in ''|*[!0-9]*) now=0 ;; esac
  # The file shrank: the log trimmer rotated or truncated it mid-window, so the
  # offset now points at the wrong content. Taking the file WHOLE was the first
  # instinct and it is wrong — observed live, it put seven days and 679KB of
  # unrelated log into an 18-second bundle, burying the part that mattered.
  # Take a bounded tail instead and say so, rather than pretending precision we
  # no longer have.
  if [ "${now}" -lt "${start}" ]; then
    start=$(( now > 262144 ? now - 262144 : 0 ))
    ROTATED_NOTE="${ROTATED_NOTE}${f} "
  fi
  # Flatten the path into the filename: three subdirectories can each hold a
  # file named 2026-08-12.log, and basename alone would silently keep one.
  flat="$(printf '%s' "${f#/var/log/taranac/}" | tr '/' '_')"
  # A byte offset can land mid-line, and then the slice opens with the tail of
  # a sentence — seen in a real bundle as "ser=ad_user1 rule=15 …", which reads
  # like a corrupted log. That fragment belongs to an event from BEFORE the
  # window anyway, so drop it — but only when the cut really was mid-line:
  # check whether the byte just before the slice is a newline.
  drop_partial=""
  if [ "${start}" -gt 0 ]; then
    boundary="$(docker exec "${DAEMON_CT}" sh -c \
      "tail -c +${start} '${f}' 2>/dev/null | head -c 1 | od -An -c | tr -d '[:space:]'" 2>/dev/null || true)"
    [ "${boundary}" = '\n' ] || drop_partial=1
  fi
  if [ -n "${drop_partial}" ]; then
    docker exec "${DAEMON_CT}" sh -c "tail -c +$((start + 1)) '${f}' 2>/dev/null" \
      | tail -n +2 > "${WORK}/logs/${flat}" 2>/dev/null || true
  else
    docker exec "${DAEMON_CT}" sh -c "tail -c +$((start + 1)) '${f}' 2>/dev/null" \
      > "${WORK}/logs/${flat}" 2>/dev/null || true
  fi
  # Drop the empties so the bundle shows what actually happened, not a directory
  # of zero-byte files that reads like data was collected.
  [ -s "${WORK}/logs/${flat}" ] || rm -f "${WORK}/logs/${flat}"
done

# ── Context logs from the services around the daemon ────────────────────────
# The chosen daemon's log is sliced to the window; these are short tails, and
# they earn their place for two reasons.
#
# Winbind is the one that actually verifies a DOMAIN password: MS-CHAPv2 and
# PEAP for directory accounts go out through ntlm_auth, so when a domain login
# fails the reason is in winbind's log and NOWHERE in ours — the RADIUS side
# only sees "the backend said no".
#
# The other two daemons are here because the operator may have collected the
# wrong protocol. A device sending RADIUS while `--protocol tacacs` runs
# produces an empty capture and a bundle that says "nothing arrived", when the
# truth — traffic, on the other port — is one file away.
mkdir -p "${WORK}/logs/context"
context_tail() {  # $1 = container, $2 = directory to look in
  local container="$1" directory="$2" file base
  docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -q true || return 0
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    base="$(printf '%s' "${container}_${file#"${directory}"/}" | tr '/' '_')"
    docker exec "${container}" sh -c "tail -c 65536 '${file}' 2>/dev/null" \
      > "${WORK}/logs/context/${base}" 2>/dev/null || true
    [ -s "${WORK}/logs/context/${base}" ] || rm -f "${WORK}/logs/context/${base}"
  done < <(docker exec "${container}" sh -c \
    "find '${directory}' -maxdepth 2 -type f \\( -name '*.log' -o -name 'log.*' \\) -mmin -30 2>/dev/null | head -12" 2>/dev/null || true)
}

# Winbind first — it is the one nobody thinks to ask for.
if WINBIND_CT="$(find_container "taranac-winbind" 2>/dev/null)"; then
  context_tail "${WINBIND_CT}" "/var/log/samba"
fi
for other in taranac-tacacs taranac-radius taranac-nac; do
  case "${other}" in *"${PROTOCOL}") continue ;; esac   # the chosen daemon is sliced above
  if OTHER_CT="$(find_container "${other}" 2>/dev/null)"; then
    context_tail "${OTHER_CT}" "/var/log/taranac"
  fi
done
rmdir "${WORK}/logs/context" 2>/dev/null || true

# Generated daemon config, with every secret masked. The config is the single
# place a plaintext key is legitimately written, so it is also the one file
# that must never be handed over as-is.
case "${PROTOCOL}" in
  tacacs) CONFIG_SRC="/etc/tac_plus" ;;
  *)      CONFIG_SRC="/etc/raddb" ;;
esac
docker exec "${DAEMON_CT}" sh -c "find ${CONFIG_SRC} -maxdepth 1 -type f \( -name '*.conf' -o -name '*.cfg' \) -exec cat {} + 2>/dev/null" \
  | sed -E 's/((key|secret|password|passwd)[[:space:]]*=[[:space:]]*)("?[^"[:space:]]+"?)/\1<MASKED>/Ig' \
  > "${WORK}/config/daemon-config.masked.txt" 2>/dev/null || true

# What Taranac itself recorded during the window.
if [ -n "${API_CT}" ]; then
  docker exec "${API_CT}" python -m app.scripts.diag db-logs \
    --device-ip "${DEVICE_IP}" --protocol "${PROTOCOL}" \
    --since "${STARTED_AT}" --until "${ENDED_AT}" \
    > "${WORK}/db-logs.json" 2>/dev/null || echo '{"error": "db-logs failed"}' > "${WORK}/db-logs.json"
fi

# Decode the capture. This is the whole reason the bundle can afford to omit the
# shared secret: the key stays in the api container, the capture goes in, and
# readable text comes back. For TACACS+ this is the difference between a usable
# bundle and an opaque one — its bodies are obfuscated, so without this step
# nobody outside the customer's own network could read them at all.
if [ -n "${API_CT}" ] && [ "${PKT_COUNT}" -gt 0 ]; then
  if docker cp "${PCAP}" "${API_CT}:/tmp/taranac-diag-capture.pcap" >/dev/null 2>&1; then
    # Keep the decoder's stderr instead of discarding it. Swallowing it hid a
    # crash that produced a silently missing decoded.txt, and a bundle that is
    # quietly missing its most useful file is worse than one that says why.
    docker exec "${API_CT}" python -m app.scripts.diag decode \
      --device-ip "${DEVICE_IP}" --protocol "${PROTOCOL}" \
      --pcap /tmp/taranac-diag-capture.pcap --ports "${PORT_LIST}" \
      > "${WORK}/decoded.txt" 2>"${WORK}/decode.stderr" || true
    docker exec "${API_CT}" rm -f /tmp/taranac-diag-capture.pcap >/dev/null 2>&1 || true
    if [ ! -s "${WORK}/decoded.txt" ]; then
      rm -f "${WORK}/decoded.txt"
      echo "! Decoding failed — see decode.stderr in the archive."
    else
      rm -f "${WORK}/decode.stderr"
    fi
    [ -s "${WORK}/decode.stderr" ] || rm -f "${WORK}/decode.stderr"
  fi
fi

# Environment facts — the questions support asks first.
{
  echo "collected_at   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "window         : ${STARTED_AT} .. ${ENDED_AT}"
  echo "protocol       : ${PROTOCOL}"
  echo "device_ip      : ${DEVICE_IP}"
  echo "daemon         : ${DAEMON_CT}"
  echo "listening_ports: ${PORT_LIST}"
  echo "capture_filter : ${FILTER}"
  echo "host_kernel    : $(uname -sr)"
  [ -f "${HERE}/VERSION" ] && echo "taranac_version: $(cat "${HERE}/VERSION")"
  # The daemon's own version is the first thing support asks and the last thing
  # anyone can reconstruct from a bundle afterwards.
  case "${PROTOCOL}" in
    tacacs) echo "daemon_version : $(docker exec "${DAEMON_CT}" sh -c 'tac_plus-ng -v 2>&1 | head -1' 2>/dev/null || echo unknown)" ;;
    *)      echo "daemon_version : $(docker exec "${DAEMON_CT}" sh -c 'radiusd -v 2>&1 | head -1' 2>/dev/null || echo unknown)" ;;
  esac
  # Timestamps in this bundle come from three clocks in two zones: the capture
  # window is UTC, tac_plus' syslog is UTC, and the FreeRADIUS log is container
  # local time. Seen in a real bundle as a three-hour "gap" that was purely a
  # timezone difference, so both clocks are recorded explicitly.
  echo "host_time      : $(date '+%Y-%m-%d %H:%M:%S %Z %z')"
  echo "daemon_time    : $(docker exec "${DAEMON_CT}" date '+%Y-%m-%d %H:%M:%S %Z %z' 2>/dev/null || echo unknown)"
  echo "NOTE           : the capture window above is UTC; daemon logs may be in the daemon's local zone."
  echo
  echo "--- log slice offsets (bytes at capture start) ---"
  printf '%s' "${LOG_OFFSETS:-（none）}"
  echo
  echo "--- containers ---"
  docker ps --filter "name=taranac-" --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
} > "${WORK}/environment.txt"

# ── Step 6: report ──────────────────────────────────────────────────────────
# (PKT_COUNT and CAPTURE_TRUNCATED were computed in step 5, before the decode.)

# How much did Taranac itself record during the window? Used for the correlation
# below; counted here so summary.txt and the console agree.
DB_ROWS=0
if [ -f "${WORK}/db-logs.json" ]; then
  DB_ROWS="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    print(0); raise SystemExit
print(sum(s.get("count", 0) for s in d.get("sections", {}).values()))
' "${WORK}/db-logs.json" 2>/dev/null || echo 0)"
fi
# -maxdepth 1 on purpose: logs/context/ holds tails from OTHER services, which
# are always non-empty. Counting them would make "traffic arrived but Taranac
# recorded nothing" impossible to reach — the one finding that matters most.
LOG_BYTES="$(find "${WORK}/logs" -maxdepth 1 -type f -exec cat {} + 2>/dev/null | wc -c | tr -d '[:space:]')"

SUMMARY="${WORK}/summary.txt"
{
  echo "Taranac diagnostic bundle"
  echo "========================="
  echo
  echo "protocol : ${PROTOCOL}"
  echo "device   : ${DEVICE_IP}"
  echo "window   : ${STARTED_AT} .. ${ENDED_AT}"
  echo "packets  : ${PKT_COUNT}"
  echo
  echo "How this address is configured"
  echo "------------------------------"
  if [ -n "${PREFLIGHT_JSON}" ]; then
    python3 "${RENDER_PY}" "${PREFLIGHT_FILE}" --matches 2>/dev/null || echo "  (unavailable)"
  else
    echo "  (preflight did not run — the api container was not reachable)"
  fi
  echo
  echo "Findings"
  echo "--------"
  if [ -n "${PREFLIGHT_JSON}" ]; then
    python3 "${RENDER_PY}" "${PREFLIGHT_FILE}" --findings-only 2>/dev/null || true
  fi
  if [ "${PKT_COUNT}" -eq 0 ]; then
    echo "  [EMPTY]   NOT WORTH SENDING — no traffic from ${DEVICE_IP} was captured at all."
    echo
    echo "            This bundle cannot show what went wrong, because nothing arrived"
    echo "            on ports ${PORT_LIST} during the window. Sending it to support only"
    echo "            costs a round-trip: the answer will be 'please collect it again'."
    echo
    echo "            Before re-running, check that:"
    echo "              - the problem was actually reproduced while the collector was running"
    echo "              - ${DEVICE_IP} is the address the device sends FROM (its source IP,"
    echo "                which is often a loopback or management interface, not the one you"
    echo "                log in to)"
    echo "              - the device points at THIS server, on the port(s) above"
    echo "              - nothing between them drops it — a firewall or an ACL on the path"
  else
    echo "  [traffic] ${PKT_COUNT} packets captured."
  fi
  # The one correlation worth making automatically: traffic arrived, but did
  # Taranac react to it? Packets with no record anywhere means the request was
  # dropped before processing — an unknown client, the wrong shared secret or
  # the wrong protocol on that port. That is a different problem from "policy
  # said no", and the two look identical to whoever reports "it doesn't work".
  DAEMON_ANSWERED=""
  if [ -f "${WORK}/decoded.txt" ] && grep -qE "(REPLY|RESPONSE)" "${WORK}/decoded.txt"; then
    DAEMON_ANSWERED=1
  fi
  if [ "${PKT_COUNT}" -gt 0 ] && [ "${DB_ROWS}" = "0" ] && [ "${LOG_BYTES}" = "0" ] && [ -n "${DAEMON_ANSWERED}" ]; then
    # The daemon clearly processed the request — the decode contains its
    # replies. So "dropped before processing" would be wrong; what is missing
    # is an OUTCOME, which is what an exchange that never finished looks like.
    echo "  [!]       ${PKT_COUNT} packets arrived and the daemon DID answer (see decoded.txt),"
    echo "            but nothing was recorded: no log line and no database row. The exchange"
    echo "            started and never completed — the device stopped mid-conversation, or"
    echo "            gave up before sending credentials."
  elif [ "${PKT_COUNT}" -gt 0 ] && [ "${DB_ROWS}" = "0" ] && [ "${LOG_BYTES}" = "0" ]; then
    echo "  [!]       ${PKT_COUNT} packets arrived from ${DEVICE_IP}, but Taranac recorded"
    echo "            NOTHING — no daemon log output, no database rows, and no reply sent."
    echo "            The requests are being discarded before any policy runs. Usual causes:"
    echo "            the device is not a configured client, the shared secret does not match,"
    echo "            or it is sending a different protocol to this port."
  elif [ "${PKT_COUNT}" -gt 0 ]; then
    echo "  [ok]      Taranac reacted: ${DB_ROWS} database record(s), ${LOG_BYTES} bytes of daemon log."
  fi
  # A key mismatch is invisible from the outside: the daemon simply stops
  # answering. The decode is the only place it can be stated outright.
  if [ -f "${WORK}/decoded.txt" ] && grep -q "disagree about the shared secret" "${WORK}/decoded.txt"; then
    echo "  [KEY]     The captured bodies do NOT decode with the key Taranac holds for"
    echo "            ${DEVICE_IP}. The device is configured with a different shared secret."
    echo "            Re-enter the key on both sides — see decoded.txt."
  elif [ -f "${WORK}/decoded.txt" ]; then
    echo "  [decode]  Traffic decoded into readable text — see decoded.txt."
  fi
  if [ -n "${ROTATED_NOTE}" ]; then
    echo "  [logs]    The daemon rotated or trimmed a log mid-capture (${ROTATED_NOTE%% })."
    echo "            The window boundary was lost there, so the bundle carries a bounded"
    echo "            tail of that file instead of an exact slice."
  fi
  if [ -n "${CAPTURE_TRUNCATED}" ]; then
    echo "  [traffic] The capture hit the ${MAX_FILE_MB}MB cap and wrapped — the EARLIEST"
    echo "            packets were overwritten. Re-run with a shorter window or a"
    echo "            larger --max-size if the start of the exchange matters."
  fi
  echo
  echo "Contents"
  echo "--------"
  # Listed from what is actually on disk. A fixed list would promise a daemon
  # log that is not there and send the reader looking for a file that was never
  # written — the bundle has to describe itself honestly.
  ( cd "${WORK}" && find . -type f ! -name summary.txt | sed 's|^\./||' | sort ) | while read -r item; do
    case "${item}" in
      capture.pcap)  echo "  ${item}  — raw traffic (${PKT_COUNT} packets; open in Wireshark)" ;;
      preflight.json) echo "  ${item}  — how the device is configured in Taranac" ;;
      db-logs.json)  echo "  ${item}  — what Taranac recorded during the window (${DB_ROWS} rows)" ;;
      decoded.txt)   echo "  ${item}  — the exchange decoded into readable text (no secret included)" ;;
      logs/context/*) echo "  ${item}  — recent tail from a neighbouring service (context, not the window)" ;;
      logs/*)        echo "  ${item}  — daemon log output during the window" ;;
      config/*)      echo "  ${item}  — generated daemon config, secrets masked" ;;
      environment.txt) echo "  ${item}  — versions, containers, capture settings" ;;
      tcpdump.stderr) echo "  ${item}  — capture tool output (empty unless something went wrong)" ;;
      *)             echo "  ${item}" ;;
    esac
  done
  if [ "${LOG_BYTES}" = "0" ]; then
    echo "  (no daemon log output at all during the window — see the finding above)"
  fi
  echo
  echo "Note on secrets: no shared secret is included. Secrets appear only as a"
  echo "12-hex fingerprint. To decode TACACS+ payloads in Wireshark yourself, enter"
  echo "the device's key locally — it is not, and must not be, in this archive."
} > "${SUMMARY}"

ARCHIVE="${OUT_DIR}/${BUNDLE}.tar.gz"
tar -czf "${ARCHIVE}" -C "${OUT_DIR}" "${BUNDLE}"

echo
cat "${SUMMARY}"
rm -rf "${WORK}"
echo
echo "Archive: ${ARCHIVE}  ($(du -h "${ARCHIVE}" | cut -f1))"
if [ "${PKT_COUNT}" -eq 0 ]; then
  # Do not end an empty collection with "send this to support" — that is how a
  # useless archive gets mailed and a day gets lost waiting for the reply.
  echo
  echo "⚠  DO NOT SEND THIS ONE — it captured no traffic (see the finding above)."
  echo "   Reproduce the problem while the collector is running, then collect again."
else
  echo "Send this file to support."
fi
