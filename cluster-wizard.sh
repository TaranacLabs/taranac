#!/usr/bin/env bash
# =============================================================================
# cluster-wizard.sh — the PRIMARY-side commands of the HA setup wizard.
#   ./taranac cluster init
#   ./taranac cluster add-witness --address 10.0.0.3
#   ./taranac cluster add-node    --address 10.0.0.2
#
# Design: docs/spec/backend/infra/cluster.md. This file is orchestration only —
# every mechanism it drives already exists and is owned elsewhere:
#   cluster-manifest.py   the manifest (config/cluster.yml) — read/write
#   ha-convert.sh         standalone → seed conversion (TWO-PHASE by default)
#   cluster-broker.py     the one-shot host-side join channel
#   ./taranac cluster …   join tokens + status, inside the api container
#
# WHY THE ORDER OF THE THREE COMMANDS IS FIXED
# --------------------------------------------
# It is physics, not preference, and it comes from two refusals that already
# exist in the shipped HA feature:
#   * `ha-convert.sh --continue` refuses to prune the etcd ring unless the
#     WITNESS is already a live member (ha-convert.sh, the "witness-presence
#     guard") — pruning without it strands the seed as a 1-member cluster the
#     witness could never join;
#   * `ha-join.sh` refuses a cluster whose ETCD_INITIAL_CLUSTER lists fewer than
#     three etcd members — a 2-node ring has no quorum on a partition.
# So: init prepares, add-witness completes the conversion, add-node grows it.
# The wizard turns those refusals into a guided sequence; it does not route
# around them, and it never invents a third way to do the same thing.
#
# WHY `init` CANNOT FINISH THE CONVERSION BY ITSELF
# -------------------------------------------------
# Securing etcd is a chicken-and-egg: the witness must be up BEFORE the convert
# (or the convert prunes it), but the witness needs a server leaf signed by a CA
# that only the convert's PREPARE phase generates. Hence `--prepare` … witness …
# `--continue`. `init` therefore runs --prepare and STOPS, and says plainly what
# comes next and why. There is no flag here that fuses the two phases, because
# there is no way to fuse them that is not a lie about what was observed.
#
# THE STEP CONTRACT (the house rule this file exists to honour)
# ------------------------------------------------------------
# Every step announces itself BEFORE it runs, asserts an OBSERVABLE outcome, and
# on failure names the step and carries its own cure:
#     step 4/9: node-2 did not publish its config fingerprint within 30s
# "the command returned 0" is never an outcome. An installer may not report a
# success it has not observed — under HA the difference is invisible until the
# failover that needs it.
# =============================================================================
set -uo pipefail   # NOT -e: every failure here is reported by a named step, and
                   # a bare `set -e` abort would print nothing an operator can act on.

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${HERE}"

ENV_FILE="${HERE}/.env"
MANIFEST="${HERE}/config/cluster.yml"
CM="${HERE}/cluster-manifest.py"
BROKER="${HERE}/cluster-broker.py"
CONVERT="${HERE}/ha-convert.sh"
WRAPPER="${HERE}/taranac"
CA_DIR="${HERE}/config/etcd-ca"
TLS_DIR="${HERE}/config/etcd-tls"
SECRETS_DIR="${HERE}/config/cluster-secrets"

# The freshness window for a member's heartbeat. There must be exactly ONE notion
# of "recent" in the product, and it lives in the backend
# (service_health.STALE_AFTER_SECONDS = 3 missed 30s beats). We READ it from the
# running api rather than restate it; this literal is only the fallback for when
# the api cannot be reached, and it is deliberately the same number so the
# fallback can never silently widen the window.
STALE_AFTER_SECONDS=90

# ── Output: the step contract ────────────────────────────────────────────────
STEP_NO=0; STEP_TOTAL=0; STEP_NAME=""

steps()  { STEP_TOTAL="$1"; STEP_NO=0; }
step()   { STEP_NO=$((STEP_NO + 1)); STEP_NAME="$1"
           printf '\n\033[1mstep %d/%d:\033[0m %s\n' "${STEP_NO}" "${STEP_TOTAL}" "$1"; }
ok()     { printf '   \033[32m✓\033[0m %s\n' "$1"; }
info()   { printf '     %s\n' "$1"; }
warn()   { printf '   \033[33m!\033[0m %s\n' "$1"; }
hdr()    { printf '\n\033[1m%s\033[0m\n' "$1"; }

# A plain failure (argument validation, a guard outside any step). The first line
# is what went wrong; every following line is the cure. A message with no cure is
# a defect — an operator must never have to guess the next command.
fail() {
  printf '\n\033[31m✗ cluster-wizard: %s\033[0m\n' "$1" >&2
  shift
  local line; for line in "$@"; do printf '  %s\n' "${line}" >&2; done
  exit 1
}

# A failure INSIDE a step: names the step, so the operator knows exactly which
# observable outcome did not happen — not that "it failed".
step_fail() {
  printf '\n\033[31m✗ step %d/%d: %s — %s\033[0m\n' \
    "${STEP_NO}" "${STEP_TOTAL}" "${STEP_NAME}" "$1" >&2
  shift
  local line; for line in "$@"; do printf '  %s\n' "${line}" >&2; done
  exit 1
}

# ── .env access — the same idiom as ha-convert.sh/ha-join.sh, deliberately ────
# One parser for the host's .env across the bundle. `getenv` takes the LAST
# assignment (install.sh ships the HA keys commented out, so the wizard's own
# appended line is the live one).
# An ABSENT key is an empty value, not an error. Without `|| true` this pipeline exits 1
# when grep matches nothing, and under `set -euo pipefail` a bare assignment —
# VAR="$(getenv MISSING)" — kills the script SILENTLY, mid-step, with no message at
# all. Fixed in the sibling scripts after it cost an afternoon; missed here until the
# wrong-terminal guard read a key a fresh node does not have and the join just died.
getenv() { grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true ; }
setenv() {
  local k="$1" v="$2" esc
  if grep -qE "^${k}=" "${ENV_FILE}"; then
    esc=$(printf '%s' "${v}" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${k}" "${v}" >> "${ENV_FILE}"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail \
    "$1 is not installed on this host, and the wizard needs it." \
    "Install it and re-run:  sudo bash bootstrap.sh"
}

# How long the post-join verification steps wait for their observable outcome.
# A knob rather than a constant because the honest answer depends on the cluster:
# Patroni has finished cloning by the time the broker returns, but promotion and
# the first streaming report still take a moment, and a very large database on a
# slow link stretches that. Overridable with --wait-seconds; never silently
# widened, because a longer wait must be the operator's decision, not ours.
WAIT_SECONDS=120

# Poll <command…> until it succeeds or the budget runs out. Returns the
# command's verdict — never "we waited, so assume it worked".
wait_until() {  # <seconds> <command...>
  local budget="$1"; shift
  local deadline=$((SECONDS + budget))
  while :; do
    "$@" && return 0
    [ "${SECONDS}" -lt "${deadline}" ] || return 1
    sleep 1
  done
}

# This node's Postgres says it is the primary. `not pg_is_in_recovery()` is the
# only answer that proves it — a running container proves nothing.
is_local_primary() {
  docker exec taranac-db psql -U taranac -d taranac -tAc "select not pg_is_in_recovery()" 2>/dev/null \
    | grep -qi '^t'
}

# <address> is an etcd member that VOTES. A learner is present and does not count
# toward quorum, so it must never satisfy this.
is_voting_member() {
  etcd_members | grep -F -- "//$1:2380" | grep -qv "$(printf '\ttrue')$"
}

# What THIS primary sees on the wire for a replica. Not "is the container up" and
# not "is there a roster row": a cluster that looks healthy while one node cannot
# follow a failover is worse than one that failed loudly, because nobody finds out
# until the failover.
replication_state() {  # <address> <node-name>
  psql_q "SELECT state FROM pg_stat_replication
          WHERE client_addr = '$1'::inet OR application_name = '$2'"
}
is_streaming() { case "$(replication_state "$1" "$2")" in *streaming*) return 0 ;; *) return 1 ;; esac; }

# ── The manifest helper ──────────────────────────────────────────────────────
# bash never edits config/cluster.yml itself: the operator's hand-written `skip:`
# section lives in that file, and a sed-edited source of truth is a source of
# drift. Everything goes through cluster-manifest.py, whose exit codes we branch on.
cm() { python3 "${CM}" "$@" --file "${MANIFEST}"; }

# ── The manifest's cluster-wide copy ─────────────────────────────────────────
# WHY THIS EXISTS
# ---------------
# config/cluster.yml used to live ONLY on the machine that ran `init`. Lose that
# machine and the cluster could never be grown or repaired again: every command
# that touches the topology dies at "no cluster manifest at config/cluster.yml",
# and the remedy that message prints — `cluster init` — is the one command that
# must NEVER be run against a live cluster. The etcd CA was distributed to every
# node for exactly this reason; the manifest is the other half of the same fix.
# The rule it serves is the owner's: anything the original primary can do must
# work on any node that takes the primary role.
#
# HOW
# ---
# The manifest TEXT is published into the replicated settings store, so it
# travels the way every other cluster-wide fact already does. bash never touches
# the database — it goes through the api container, exactly like the
# `cluster join-token` call in add-node:
#     ./taranac cluster manifest-publish  < config/cluster.yml
#     ./taranac cluster manifest-fetch    > <a temp file>
#     ./taranac cluster manifest-info     -> eval-able MP_* metadata
#
# `manifest-fetch` exits 5 when nothing has ever been published — a code no other
# failure uses. That distinction is load-bearing: "the cluster holds no copy"
# means publish ours, "the cluster could not be asked" means stop and say so, and
# collapsing the two would let a node overwrite a manifest it never managed to read.
MANIFEST_ABSENT_RC=5

# Indent a captured block under the step contract's output, so a multi-line
# message from the api does not land at column 0 in the middle of a step.
indent_block() { printf '%s\n' "$1" | sed 's/^/     /'; }

# Publish the LOCAL manifest to the cluster. Never fatal, and deliberately so: the
# file has already been written, and refusing to continue because the copy could
# not be replicated would turn a degraded outcome into a failed one. It is loud
# instead — silence here would rebuild exactly the seed-only manifest this whole
# mechanism exists to remove.
publish_manifest() {
  [ -f "${MANIFEST}" ] || return 0
  local out rc
  if [ ! -x "${WRAPPER}" ]; then
    warn "./taranac is missing from the bundle, so config/cluster.yml was NOT published"
    info "Cure: refresh the bundle once, then publish by hand:  ./taranac update"
    return 1
  fi
  out="$("${WRAPPER}" cluster manifest-publish < "${MANIFEST}" 2>&1)"; rc=$?
  if [ ${rc} -ne 0 ]; then
    warn "the cluster's copy of config/cluster.yml was NOT updated"
    indent_block "${out}"
    info "Every other node therefore still sees the previous node list, and none of them"
    info "could grow the cluster if this one were lost."
    info "Cure — once the api answers again (./taranac ps), publish it by hand:"
    info "  ./taranac cluster manifest-publish < config/cluster.yml"
    return 1
  fi
  ok "config/cluster.yml published to the cluster — every node can read it"
  return 0
}

# Fetch the published manifest into <destination>.
#   0  fetched                    · the file is written and non-empty
#   5  nothing has been published · MANIFEST_ABSENT_RC, an ANSWER, not a failure
#   1  the cluster could not be asked (api down, no wrapper, empty reply)
# The reason for a 1 is left in <destination>.err for the caller to print.
fetch_published_manifest() {  # <destination file>
  local dest="$1" rc
  [ -x "${WRAPPER}" ] || { printf './taranac is missing from the bundle\n' > "${dest}.err"; return 1; }
  "${WRAPPER}" cluster manifest-fetch > "${dest}" 2> "${dest}.err"; rc=$?
  [ ${rc} -eq 0 ] || return ${rc}
  # A zero exit with no bytes would be a contract violation upstream; treat it as
  # "could not be asked" rather than as an empty manifest, which would then be
  # written over a perfectly good local file.
  [ -s "${dest}" ] || { printf 'the api returned an empty manifest\n' > "${dest}.err"; return 1; }
  return 0
}

# When the published copy was last written, in epoch seconds (empty if unknown).
manifest_published_epoch() {
  local meta
  meta="$("${WRAPPER}" cluster manifest-info 2>/dev/null | grep '^MP_' || true)"
  [ -n "${meta}" ] || return 1
  MP_PUBLISHED_AT_EPOCH=""
  # shellcheck disable=SC1090
  eval "${meta}"
  [ -n "${MP_PUBLISHED_AT_EPOCH:-}" ] || return 1
  printf '%s\n' "${MP_PUBLISHED_AT_EPOCH}"
}

# Print HOW the two copies differ, and set CM_SAME_TOPOLOGY / CM_SKIPS_ONLY_THERE
# for the caller's decision. Comparing YAML is cluster-manifest.py's job — a
# grep-based diff would call two identical documents different over a comment.
# Returns non-zero only if the comparison itself could not be made.
describe_manifest_difference() {  # <the published copy>
  local published="$1" out rc kind text
  CM_IDENTICAL=""; CM_SAME_TOPOLOGY=""; CM_SKIPS_ONLY_HERE=""; CM_SKIPS_ONLY_THERE=""
  out="$(cm compare --other "${published}" 2>&1)"; rc=$?
  local machine; machine="$(printf '%s\n' "${out}" | grep '^CM_' || true)"
  # shellcheck disable=SC1090
  [ -n "${machine}" ] && eval "${machine}"
  if [ ${rc} -ne 0 ] || [ -z "${CM_SAME_TOPOLOGY}" ]; then
    warn "the two copies of the manifest could not be compared"
    indent_block "$(printf '%s\n' "${out}" | grep -v '^CM_')"
    return 1
  fi

  # Only printf inside the loop — nothing here reads stdin, so nothing can eat the
  # heredoc that feeds `read` (the trap that once silently truncated a sweep to its
  # first entry).
  while IFS="$(printf '\t')" read -r kind text; do
    [ -n "${kind}" ] || continue
    case "${kind}" in
      only-here)       printf "     · only in THIS node's file:    %s\n" "${text}" ;;
      only-there)      printf "     · only in the cluster's copy:  %s\n" "${text}" ;;
      skip-only-here)  printf "     · skip: entry only here:       %s\n" "${text}" ;;
      skip-only-there) printf "     · skip: entry only in the cluster's copy: %s\n" "${text}" ;;
      *)               printf '     · %s: %s\n' "${kind}" "${text}" ;;
    esac
  done <<EOF
$(printf '%s\n' "${out}" | grep -v '^CM_')
EOF

  # Which is newer — a HINT, said as one. The two timestamps come off two
  # different clocks (this host's filesystem and the primary's database), so it
  # orders them; it does not prove anything.
  local pub_epoch local_epoch
  pub_epoch="$(manifest_published_epoch 2>/dev/null || true)"
  local_epoch="$(stat -c %Y "${MANIFEST}" 2>/dev/null || true)"
  if [ -n "${pub_epoch}" ] && [ -n "${local_epoch}" ]; then
    local newer_here="" newer_there="" verdict="(two different clocks — treat 'newer' as a hint, not as proof)"
    if [ "${pub_epoch}" -gt "${local_epoch}" ] 2>/dev/null; then
      newer_there="  <- newer"
    elif [ "${local_epoch}" -gt "${pub_epoch}" ] 2>/dev/null; then
      newer_here="  <- newer"
    else
      # Same second on two different clocks proves nothing at all — claiming one
      # is newer here would be inventing an ordering out of rounding.
      verdict="(the same second on two different clocks — which is newer cannot be told)"
    fi
    info ""
    info "this node's file:     $(date -d "@${local_epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "${local_epoch}")${newer_here}"
    info "the cluster's copy:   $(date -d "@${pub_epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "${pub_epoch}")${newer_there}"
    info "${verdict}"
  fi
  return 0
}

# Make sure THIS node has a usable config/cluster.yml before anything is recorded
# in it, and that it does not silently disagree with the cluster's copy.
#
# The grading below is the whole design, and it is not symmetric on purpose:
#
#   no local file, a published copy      -> restore it, and say so out loud. This
#                                           is the case the mechanism exists for.
#   no local file, nothing published     -> stop: there is no source of truth.
#   a local file, nothing published      -> publish ours (first run after an
#                                           upgrade; nothing can be lost).
#   identical                            -> nothing to do.
#   the DECLARED NODES differ            -> STOP. One of the two copies describes
#                                           a cluster that does not exist, and
#                                           picking one for the operator could
#                                           delete a node from the cluster's own
#                                           description of itself.
#   nodes agree, the cluster's copy has  -> STOP. Publishing ours would drop an
#   a skip: entry we do not have            operator's hand-written entry, with
#                                           its reason, from the cluster's copy.
#   nodes agree, and every skip: entry   -> proceed, and publish ours, so the
#   we hold is a superset                   entries the operator wrote HERE reach
#                                           the cluster's copy too. Nothing is
#                                           lost in either direction, and it is
#                                           stated rather than done quietly.
#
# Never writes over the LOCAL file. That file is where hand-written `skip:`
# entries live; the published copy is a copy, and a copy is what gets replaced.
#
# Idempotent within one run: a command may need the manifest in place EARLIER than
# the step that records into it (add-node sweeps leftovers first, and a sweep that
# reads an absent manifest sees "nothing is declared" and would strip every
# declaration out of .env). Ensuring twice would ask the api twice and print the
# same two lines twice, so the first call wins and the second is a no-op.
MANIFEST_ENSURED=""

ensure_manifest() {
  [ -z "${MANIFEST_ENSURED}" ] || return 0
  MANIFEST_ENSURED=1
  local work published rc
  work="$(mktemp -d)"; published="${work}/published.yml"
  fetch_published_manifest "${published}"; rc=$?

  if [ ! -f "${MANIFEST}" ]; then
    case ${rc} in
      0)
        local vout
        vout="$(python3 "${CM}" validate --file "${published}" 2>&1)" || step_fail \
          "the manifest published by this cluster does not parse" \
          "$(indent_block "${vout}")" \
          "Nothing was written here. The cluster's copy is what every node would restore" \
          "from, so it is not installed unread." \
          "Cure: fix it on the node that holds a good config/cluster.yml and re-publish:" \
          "  ./taranac cluster manifest-publish < config/cluster.yml"
        mkdir -p "${HERE}/config"
        mv -f "${published}" "${MANIFEST}" || step_fail \
          "the cluster's manifest could not be written to ${MANIFEST}" \
          "Cure: the bundle directory must be writable by you:" \
          "  sudo chown -R \$(id -u):\$(id -g) ${HERE}/config"
        ok "config/cluster.yml was missing here — restored it from the cluster's published copy"
        # Say WHAT was restored, not where the temp copy sat: the validator names
        # the cluster and every node, which is exactly the confirmation an operator
        # needs before this node starts recording into it.
        info "it declares $(printf '%s' "${vout}" | sed 's/^.*is valid — //')"
        ;;
      "${MANIFEST_ABSENT_RC}")
        rm -rf "${work}"
        step_fail "there is no config/cluster.yml on this node, and no node has published one" \
          "The manifest is the cluster's declared source of truth — which nodes exist, and" \
          "which divergences the operator has already accepted. Without it this command has" \
          "nothing to record into and nothing to check against." \
          "Cure — on the node that DOES hold config/cluster.yml (the one you ran init on)," \
          "publish it once; every node then has it, including this one:" \
          "  ./taranac cluster manifest-publish < config/cluster.yml" \
          "If no node holds one at all, this cluster predates the manifest — recreate it" \
          "there to match the cluster you actually have, then publish it."
        ;;
      *)
        local why; why="$(cat "${published}.err" 2>/dev/null)"
        rm -rf "${work}"
        step_fail "this node has no config/cluster.yml, and the cluster could not be asked for its copy" \
          "$(indent_block "${why:-the api container did not answer}")" \
          "Guessing is not an option here: an empty manifest would look exactly like a" \
          "cluster with no nodes, and the next command would build on it." \
          "Cure: bring the api back on this node and retry, or run this command on a node" \
          "that already holds the file:" \
          "  ./taranac ps" \
          "  ./taranac logs --tail 50 api"
        ;;
    esac
    rm -rf "${work}"
    return 0
  fi

  case ${rc} in
    "${MANIFEST_ABSENT_RC}")
      info "this cluster has never published its manifest — publishing this node's copy"
      publish_manifest
      ;;
    0)
      if cmp -s "${MANIFEST}" "${published}"; then
        ok "config/cluster.yml matches the copy published by the cluster"
      else
        printf '\n'
        warn "this node's config/cluster.yml and the copy published by the cluster differ:"
        describe_manifest_difference "${published}" || true
        printf '\n'
        if [ "${CM_SAME_TOPOLOGY:-0}" = "1" ] && [ "${CM_SKIPS_ONLY_THERE:-0}" = "0" ]; then
          info "The declared nodes agree — the difference is in comments or in skip: entries"
          info "that only THIS node's file carries, so nothing of the cluster's is lost."
          info "Publishing this node's file, so those entries reach every node too."
          publish_manifest
        else
          rm -rf "${work}"
          step_fail "config/cluster.yml here and the copy published by the cluster do not agree" \
            "Nothing was changed — not this file, not the cluster's copy. This file is where" \
            "your hand-written skip: section lives, so neither copy is picked for you." \
            "Cure — decide which one describes the cluster you actually have, then re-run:" \
            "  · this node's file is right — publish it to every node:" \
            "      ./taranac cluster manifest-publish < config/cluster.yml" \
            "  · the cluster's copy is right — take it (this file is backed up first):" \
            "      ./taranac cluster sync"
        fi
      fi
      ;;
    *)
      local why; why="$(cat "${published}.err" 2>/dev/null)"
      warn "the cluster's published manifest could not be read — using this node's file as it is"
      indent_block "${why:-the api container did not answer}"
      info "This node can still be worked on; what cannot be checked is whether another node"
      info "holds a different copy. Cure:  ./taranac ps"
      ;;
  esac
  rm -rf "${work}"
  return 0
}

# ── Cluster observation (docker) ─────────────────────────────────────────────
# Read-only probes. Each one is a single, canonical docker invocation so the
# failure mode is greppable and the test harness can stub it on PATH.

etcd_running() { docker inspect -f '{{.State.Running}}' taranac-etcd 2>/dev/null | grep -qi true; }

# name<TAB>peerURLs<TAB>clientURLs<TAB>isLearner, one row per etcd member.
# Parsed from `-w json`, NOT the simple table: a member may carry several peer
# URLs, and in the table those extra commas shift every following column — a bug
# that would silently mis-read the ring exactly when it matters.
etcd_members() {
  docker exec taranac-etcd etcdctl member list -w json 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for m in doc.get("members", []):
    print("\t".join([
        m.get("name", ""),
        ",".join(m.get("peerURLs", []) or []),
        ",".join(m.get("clientURLs", []) or []),
        "true" if m.get("isLearner") else "false",
    ]))
'
}

# endpoint<TAB>healthy(true|false) for every member of the ring.
etcd_health() {
  docker exec taranac-etcd etcdctl endpoint health --cluster -w json 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for e in doc if isinstance(doc, list) else []:
    print("%s\t%s" % (e.get("endpoint", ""), "true" if e.get("health") else "false"))
'
}

# A read against the cluster database. Under HA `taranac-db` is the Patroni
# container; the wizard runs on the primary, so this is the leader's own copy.
psql_q() {
  docker exec -i taranac-db psql -U taranac -d taranac -tAqX -F"$(printf '\t')" -c "$1" 2>/dev/null
}

# Is this address a member of the ACTUAL cluster? Two independent sources, because
# they answer for different kinds of member: etcd knows the witness (which has no
# Taranac roster row at all), the roster knows a Taranac node whose etcd entry an
# operator may have removed by hand. Either is enough to say "yes".
#
# Prints yes | no | unknown. **`unknown` is not `no`.** If the cluster exists but
# cannot be interrogated, guessing "no" would let add-node record a duplicate or
# miss a drift — so the caller stops instead.
address_in_cluster() {
  local address="$1"
  # TARANAC_HA is the ONLY discriminator here, and DB_HOSTS deliberately is not:
  # init writes the whole declared node list into .env before the conversion, so
  # between init and add-witness a non-empty DB_HOSTS means "declared", not
  # "exists". Reading declared intent as an existing cluster would make the
  # normal two-phase pause look like an uninterrogable cluster and stop the very
  # command that is supposed to end it. ha-convert sets TARANAC_HA=1 only after a
  # conversion actually succeeded.
  if [ "$(getenv TARANAC_HA)" != "1" ]; then
    printf 'no\n'; return 0
  fi
  if ! etcd_running; then
    printf 'unknown\n'; return 0
  fi
  local members; members="$(etcd_members)"
  if [ -z "${members}" ]; then
    printf 'unknown\n'; return 0
  fi
  if printf '%s\n' "${members}" | grep -qF -- "//${address}:"; then
    printf 'yes\n'; return 0
  fi
  local roster
  roster="$(psql_q "SELECT address FROM cluster_nodes WHERE status = 'active' AND address IS NOT NULL")"
  if printf '%s\n' "${roster}" | grep -qxF -- "${address}"; then
    printf 'yes\n'; return 0
  fi
  printf 'no\n'
}

# ── Address / CIDR arithmetic ────────────────────────────────────────────────
# In python because bash cannot do it correctly, and correctness here decides
# whether a joining node's replication connection is accepted by pg_hba.

# True when <address> falls inside <cidr-list>. An EMPTY list means the key is
# unset on that node, and postgres-ha/entrypoint.sh then defaults PG_ALLOW_CIDR to
# 0.0.0.0/0 — so "unset" covers everything, and reporting it as "not covered"
# would be a false alarm.
cidr_covers() {
  local address="$1" cidrs="$2"
  [ -n "${cidrs}" ] || return 0
  python3 - "${address}" "${cidrs}" <<'PY'
import ipaddress, sys
addr_s, cidrs = sys.argv[1], sys.argv[2]
try:
    addr = ipaddress.ip_address(addr_s)
except ValueError:
    # A DNS name — we cannot decide containment without resolving, and resolving
    # HERE would answer for THIS host's resolver, not the member's. Treat as
    # "cannot disprove" and let the report say so.
    sys.exit(0)
for part in (p.strip() for p in cidrs.split(",")):
    if not part:
        continue
    try:
        if addr in ipaddress.ip_network(part, strict=False):
            sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PY
}

# The narrowest sensible PG_ALLOW_CIDR default covering every declared address:
# the /24 of each (deduplicated). Only a DEFAULT — the operator overrides it with
# --pg-allow-cidr, and a name-based address contributes nothing.
derive_pg_allow_cidr() {
  python3 - "$@" <<'PY'
import ipaddress, sys
nets = []
for value in sys.argv[1:]:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        continue
    net = ipaddress.ip_network(f"{value}/{24 if addr.version == 4 else 64}", strict=False)
    if net not in nets:
        nets.append(net)
print(",".join(str(n) for n in nets))
PY
}

valid_address() {
  # Reuses the manifest helper's own validator by asking it to validate a throwaway
  # file, so there is exactly one definition of "a usable address" in the bundle.
  local tmp; tmp="$(mktemp -d)"
  python3 "${CM}" init --file "${tmp}/probe.yml" --address "$1" >/dev/null 2>&1
  local rc=$?
  rm -rf "${tmp}"
  return ${rc}
}

valid_node_name() {
  # Same trick as valid_address, and for the same reason: the rule for a usable
  # node name lives in cluster-manifest.py (it becomes ETCD_NAME and the Patroni
  # member name, which accept a narrow character set), so it is ASKED rather than
  # restated here.
  local tmp; tmp="$(mktemp -d)"
  python3 "${CM}" init --file "${tmp}/probe.yml" --address 10.0.0.1 --name "$1" >/dev/null 2>&1
  local rc=$?
  rm -rf "${tmp}"
  return ${rc}
}

# ── `<address>=<name>` — one argument, because two would drift ───────────────
# A node's name is chosen at `init` and never again: renaming is deliberately not
# built (the name lives in the manifest, .env, ETCD_NAME, the etcd ring, the
# certificate SANs, the roster row, Patroni, the daemons' markers and every
# diagnostic), so a wrong one costs a rebuild of that machine.
#
# The name is therefore glued to its address in a SINGLE argument. A separate
# `--node-name` would make the association positional, and one omitted name would
# shift every later name silently onto the next machine — a fresh way to
# desynchronise, invented in the middle of curing one. `=` occurs in no IPv4
# address, no hostname and no `host:port`, so the split is never ambiguous;
# anything malformed is refused rather than guessed at.
SPEC_ADDR=""; SPEC_NAME=""
split_addr_name() {  # <spec> <option, for the message>
  local spec="$1" opt="$2"
  SPEC_ADDR="${spec}"; SPEC_NAME=""
  case "${spec}" in
    *=*=*)
      fail "'${spec}' has more than one '=' after ${opt}." \
        "The form is  ${opt} <address>=<name>  — one address, one name." ;;
    *=*)
      SPEC_ADDR="${spec%%=*}"; SPEC_NAME="${spec#*=}"
      [ -n "${SPEC_ADDR}" ] || fail "'${spec}' gives a name but no address after ${opt}." \
        "The form is  ${opt} <address>=<name>  — the address comes first."
      [ -n "${SPEC_NAME}" ] || fail "'${spec}' ends at '=' with no name after ${opt}." \
        "The form is  ${opt} <address>=<name>  — or drop the '=' to have one derived." ;;
    "")
      fail "${opt} was given no value." "The form is  ${opt} <address>[=<name>]." ;;
  esac
}

# ── Prompting ────────────────────────────────────────────────────────────────
ASSUME_YES=""

ask() {  # <varname> <prompt> <default>
  local __var="$1" prompt="$2" default="$3" reply=""
  if [ -n "${ASSUME_YES}" ] || [ ! -t 0 ]; then
    # Non-interactive: take the default, or leave the value EMPTY. It is not this
    # helper's place to refuse — every caller already validates its own value and
    # can say what that particular value is for, which a generic "you did not
    # answer a prompt" never could.
    [ -z "${default}" ] || printf '%s [%s]\n' "${prompt}" "${default}"
    printf -v "${__var}" '%s' "${default}"
    return 0
  fi
  if [ -n "${default}" ]; then
    read -r -p "${prompt} [${default}]: " reply
  else
    read -r -p "${prompt}: " reply
  fi
  printf -v "${__var}" '%s' "${reply:-${default}}"
}

confirm() {  # <question>
  [ -z "${ASSUME_YES}" ] || return 0
  [ -t 0 ] || fail \
    "refusing to proceed without confirmation on a non-interactive terminal." \
    "Re-run with --yes once you have read the plan above."
  local reply=""
  read -r -p "$1 [y/N]: " reply
  case "${reply}" in [yY]|[yY][eE][sS]) return 0 ;; *) fail "aborted — nothing was changed." ;; esac
}

# ── Shared guards ────────────────────────────────────────────────────────────
require_bundle() {
  [ -f "${ENV_FILE}" ] || fail \
    "no .env in ${HERE} — the wizard runs from the bundle directory of an installed node." \
    "cd into it (usually /opt/taranac) and re-run, or install first:  ./install.sh"
  [ -f "${CM}" ] || fail \
    "cluster-manifest.py is missing from the bundle." \
    "Refresh the bundle once and retry:  ./taranac update"
  need_cmd python3
  need_cmd docker
}

require_seed() {
  # The broker signs a joining node's CSR with the cluster's etcd CA, so a node
  # without it cannot admit anyone. Every node RECEIVES the CA when it joins, so
  # this normally passes anywhere — it fails on the two cases that matter: a node
  # that joined before the CA was distributed, and a seed where init never finished.
  [ -s "${CA_DIR}/ca.key" ] || fail \
    "this node holds no etcd CA (${CA_DIR}/ca.key is missing), so it cannot sign a joining node's certificate." \
    "Every node receives the CA when it joins, so one without it either joined before" \
    "that was the case, or is a seed where init did not finish." \
    "Cure — run this on a node that HAS it (check with: ls config/etcd-ca/ca.key), or" \
    "if this IS the seed and init never completed:" \
    "  ./taranac cluster init"
}


# Who leads RIGHT NOW, from Patroni — the authority. Not the roster (that records
# what we intend) and not the printed status table (that is written for a person and
# may be re-worded, which would silently disable any guard that greps it). GET
# /cluster is JSON and, by Patroni's own design, needs no credentials — only its
# unsafe methods do. One definition, used by every caller here.
patroni_leader_name() {
  curl -fsS --max-time 10 http://127.0.0.1:8008/cluster 2>/dev/null \
    | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
for m in d.get("members", []):
    if m.get("role") in ("leader","standby_leader"):
        print(m.get("name","")); break' 2>/dev/null || true
}

# What the CLUSTER says a member is doing, from Patroni. `pg_stat_replication` is
# the PRIMARY's view of its own wire and is EMPTY on every replica — so reading it
# locally only answers when the command happens to run on the leader. Leadership
# moves (a failover is the feature), and after one it made a successful join report
# "not streaming from this primary" while the node was demonstrably streaming.
# Patroni's /cluster is DCS-derived and answers the same from any member.
patroni_member_state() {  # <member-name> -> running|streaming|creating replica|…|""
  curl -fsS --max-time 10 http://127.0.0.1:8008/cluster 2>/dev/null \
    | MEMBER="$1" python3 -c 'import json,os,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(0)
want = os.environ["MEMBER"]
for m in d.get("members", []):
    if m.get("name") == want:
        print(m.get("state","")); break' 2>/dev/null || true
}

# A member counts as replicating when Patroni reports it running as a replica and
# it is not still cloning. Patroni normalises "streaming" into state=running +
# role=replica, so both are read.
patroni_member_replicating() {  # <member-name>
  local view
  view="$(curl -fsS --max-time 10 http://127.0.0.1:8008/cluster 2>/dev/null \
    | MEMBER="$1" python3 -c 'import json,os,sys
try: d = json.load(sys.stdin)
except Exception: raise SystemExit(1)
want = os.environ["MEMBER"]
for m in d.get("members", []):
    if m.get("name") == want:
        role, state = m.get("role",""), m.get("state","")
        ok = role in ("replica","sync_standby") and state in ("running","streaming")
        print("yes" if ok else "no")
        raise SystemExit(0)
raise SystemExit(1)' 2>/dev/null)" || return 1
  [ "$view" = yes ]
}

require_converted() {
  [ "$(getenv TARANAC_HA)" = "1" ] || fail \
    "this node is not converted to HA yet, so there is no cluster to add to." \
    "Run the wizard in order — the order is enforced by the mechanism, not by us:" \
    "  1) ./taranac cluster init" \
    "  2) ./taranac cluster add-witness --address <witness>" \
    "  3) ./taranac cluster add-node    --address <node>"
}

# Read the backend's own freshness constant so this script cannot drift into a
# second definition of "recent". Falls back to the literal above, and says so.
load_stale_window() {
  local value
  value="$(docker compose --env-file "${ENV_FILE}" -f docker-compose.yml exec -T api \
      python -c 'from app.modules.infra.cluster.service_health import STALE_AFTER_SECONDS; print(STALE_AFTER_SECONDS)' \
      2>/dev/null | tr -dc '0-9')"
  if [ -n "${value}" ] && [ "${value}" -gt 0 ] 2>/dev/null; then
    STALE_AFTER_SECONDS="${value}"
    return 0
  fi
  return 1
}


# ── Already a member: reinstall, refuse, or stop ─────────────────────────────
# Called only when the manifest AND the cluster both already know this address.
# Returns 0 to continue the add (after evicting), non-zero never — it either
# continues or ends the command through step_fail.
handle_already_member() {  # <address> <node-name> [role]
  local address="$1" node_name="$2" want_role="${3:-replica}" leader state

  # 🔑 A WITNESS is not a database node and never appears in Patroni at all. Asking
  # "is it replicating?" about one always answers no, so the reinstall path used to
  # declare a perfectly healthy arbiter dead and offer to evict it — and the eviction
  # then re-recorded it as a REPLICA, because the re-add did not carry its role. Seen
  # on the stand: one keystroke turned the cluster's witness into a phantom replica
  # and left the ring with a single voter. For a witness the only meaningful question
  # is the one the ring can answer.
  if [ "${want_role}" = witness ]; then
    if etcd_running && etcd_members | grep -qF -- "//${address}:2380"; then
      note "${node_name} (${address}) is already a member of the etcd ring"
      if [ "${REINSTALL:-0}" -ne 1 ]; then
        step_fail "${node_name} (${address}) is already this cluster's witness" \
          "It is in the ring; there is nothing to add." \
          "Cure — if it is broken and you want it rebuilt from scratch:" \
          "  ./taranac cluster add-witness --address ${address} --reinstall" \
          "Otherwise nothing needs doing:" \
          "  ./taranac cluster status"
      fi
    else
      note "${node_name} (${address}) is declared but is NOT in the etcd ring — re-adding it"
    fi
    step "evicting ${node_name} so it can be added again"
    [ -x "${HERE}/cluster-remove.sh" ] || step_fail "cluster-remove.sh is missing from the bundle" \
      "Cure: refresh the bundle once, then retry:  ./taranac update"
    bash "${HERE}/cluster-remove.sh" --node "${node_name}" --yes >/dev/null 2>&1 || true
    ok "${node_name} evicted — continuing as a fresh add"
    # 🔑 Re-record with the ROLE it had. Without --role this lands as a replica and
    # the cluster silently loses its arbiter.
    cm add-witness --address "${address}" --name "${node_name}" >/dev/null 2>&1 || true
    NODE_NAME="${node_name}"; NODE_ROLE="witness"
    return 0
  fi
  node_name="${node_name:-$(psql_q "SELECT name FROM cluster_nodes WHERE address = '${address}' AND status='active'" | head -1)}"
  [ -n "${node_name}" ] || node_name="that node"

  # The leader is read from Patroni, the authority on who leads — not from a roster
  # row, which is what we INTEND rather than what is true right now.
  leader="$(patroni_leader_name)"

  if [ -n "${leader}" ] && [ "${leader}" = "${node_name}" ]; then
    step_fail "${node_name} (${address}) is the cluster's CURRENT LEADER" \
      "Reinstalling it would take the cluster's write path away mid-flight, and the" \
      "database it would be re-cloned from is the one it is currently serving." \
      "Cure: hand leadership to another node first, then reinstall this one:" \
      "  ./taranac cluster switchover --to <another node>" \
      "  ./taranac cluster add-node --address ${address} --reinstall"
  fi

  # 🔑 Asked of PATRONI, not of the local pg_stat_replication — and here the stakes
  # are higher than a wrong message. That table is empty on every replica, so after a
  # failover this command, run on a node that is no longer the leader, would find
  # EVERY healthy peer "not streaming" and offer to evict it. An operator trusting the
  # question would tear down a working node. Patroni answers the same from any member.
  state="$(patroni_member_state "${node_name}")"
  if patroni_member_replicating "${node_name}"; then
    # A healthy replica. Re-adding is almost never what was meant, so it is refused
    # by DEFAULT — but it is a legitimate thing to want (a node being rebuilt on new
    # hardware while it still runs), so the exact command is printed rather than the
    # operator being told to go away.
    if [ "${REINSTALL:-0}" -ne 1 ]; then
      step_fail "${node_name} (${address}) is already a member AND is streaming right now" \
        "It is a healthy replica of this cluster — there is nothing to add." \
        "" \
        "Reinstalling it is possible but destructive on that node: it is evicted from" \
        "the cluster, its local database is discarded, and Patroni clones it again from" \
        "the primary. The cluster runs with one less replica until it finishes." \
        "Cure — if that is genuinely what you want:" \
        "  ./taranac cluster add-node --address ${address} --reinstall" \
        "Otherwise nothing needs doing:" \
        "  ./taranac cluster status"
    fi
    info "${node_name} is streaming, and --reinstall was given — evicting it first"
  else
    # Not streaming: dead, rebuilt, or half-joined. THIS is the reinstall case the
    # command exists for, so ask rather than refuse.
    info "${node_name} (${address}) is already a member but is NOT streaming${state:+ (state: ${state})}"
    info "that is what a node looks like after it died, was rebuilt, or half-joined"
    if [ "${REINSTALL:-0}" -ne 1 ]; then
      confirm "Remove ${node_name} from the cluster and add it again from scratch?" || step_fail \
        "left the cluster as it is" \
        "Nothing was changed." \
        "Cure: inspect it before deciding, then re-run with --reinstall to skip this question:" \
        "  ./taranac cluster status" \
        "  ./taranac cluster connectivity"
    fi
  fi

  # The eviction itself is cluster-remove's job — one implementation, one set of
  # guards (quorum, leadership), used by both commands.
  step "evicting ${node_name} so it can be added again"
  [ -x "${HERE}/cluster-remove.sh" ] || step_fail "cluster-remove.sh is missing from the bundle" \
    "Cure: refresh the bundle once, then retry:  ./taranac update"
  bash "${HERE}/cluster-remove.sh" --node "${node_name}" --yes >/dev/null 2>&1 || step_fail \
    "could not evict ${node_name}" \
    "The cluster was left as it was; nothing has been added." \
    "Cure: run the eviction on its own to see why, then retry the add:" \
    "  ./taranac cluster remove-node --node ${node_name}"
  ok "${node_name} evicted — continuing as a fresh add"

  # Re-record it: the eviction removed it from the manifest too.
  # Re-record with the role it had, never the default — see the witness branch above
  # for what losing it costs.
  cm add-node --address "${address}" --name "${node_name}" --role "${want_role}" >/dev/null 2>&1 || true
  NODE_NAME="${node_name}"; NODE_ROLE="${want_role}"
  return 0
}


# ── Clear out adds that were started and never finished ──────────────────────
# A manifest entry marked `pending` is an add that began and was never confirmed:
# the operator hit Ctrl-C, the joining machine failed, the network dropped. Its
# address is ALSO in this node's ETCD_INITIAL_CLUSTER / ETCD_HOSTS / DB_HOSTS,
# because step 5 declares it there so the broker can serve the joiner a list that
# includes itself. Left behind, that entry is handed to the NEXT joining node as a
# real member: its etcd tries to form a ring with a machine that does not exist and
# never becomes healthy — the join then fails with `container taranac-etcd is
# unhealthy`, which names nothing that would lead anyone here. Observed exactly so.
#
# 🔑 The `pending` mark is what makes this safe. By state alone, a half-finished add
# is INDISTINGUISHABLE from a node the operator declared at init and has not added
# yet: both are in the manifest, both are in .env, neither is in the ring or the
# roster. Cleaning by state would silently delete the declarations that
# `init --node ...` exists to make. Only an entry whose add was actually STARTED is
# touched here.
prune_unfinished_adds() {  # <address-being-added-now>
  local keep="$1" line name addr pruned=0
  local list; list="$(cm pending 2>/dev/null || true)"
  [ -n "${list}" ] || return 0
  while IFS="$(printf '\t')" read -r name addr _role; do
    [ -n "${addr}" ] || continue
    [ "${addr}" = "${keep}" ] && continue          # the one we are adding right now
    # Never touch something that actually made it: a live ring member or a roster row
    # means the add DID finish and the mark is merely stale — clear the mark, keep it.
    # </dev/null on every command in this loop: without it they inherit the loop's
    # stdin and consume the heredoc feeding `read`, so the second iteration sees EOF
    # and only the FIRST entry is ever cleaned. Observed exactly that way — one of
    # three leftovers removed, silently.
    if [ "$(address_in_cluster "${addr}" </dev/null)" = yes ]; then
      cm mark-joined --address "${addr}" >/dev/null 2>&1 </dev/null || true
      continue
    fi
    warn "removing '${name}' (${addr}) — an earlier add was started and never finished"
    cm remove-node --address "${addr}" >/dev/null 2>&1 </dev/null || true
    setenv ETCD_INITIAL_CLUSTER "$(csv_drop "$(getenv ETCD_INITIAL_CLUSTER)" "=https://${addr}:2380")"
    setenv ETCD_HOSTS           "$(csv_drop "$(getenv ETCD_HOSTS)"           "^${addr}:2379$")"
    setenv DB_HOSTS             "$(csv_drop "$(getenv DB_HOSTS)"             "^${addr}:5432$")"
    pruned=$((pruned + 1))
  done <<EOF
${list}
EOF
  [ "${pruned}" -gt 0 ] && info "removed ${pruned} unfinished entr$([ "${pruned}" -eq 1 ] && echo y || echo ies) from the manifest and this node's .env"
  return 0
}

# ── …and entries that are in .env but in NOTHING else ────────────────────────
# The sweep above works from the manifest's `pending` marks, so it cannot see an
# address that is in this node's topology lists and in NO manifest entry at all —
# left by a manifest-only removal, or by someone editing .env. Such an address is
# still served to the next joining node as a member of the ring, with the same
# result: its etcd waits for a machine that does not exist.
#
# The manifest is the declared source of truth and the live ring is the realised
# one, so an address in neither is a leftover by definition. An address in the ring
# but NOT in the manifest is a different thing entirely — real drift — and is left
# alone here; record_in_manifest stops on it (case DRIFT) with a proper explanation.
prune_orphan_declarations() {  # <address-being-added-now>
  local keep="$1" addr dropped=0 declared
  declared="$(cm list 2>/dev/null | cut -f2 || true)"
  for addr in $(getenv ETCD_INITIAL_CLUSTER | tr ',' '\n' | sed -n 's|.*=https\?://\([^:]*\):2380.*|\1|p'); do
    [ -n "${addr}" ] || continue
    [ "${addr}" = "${keep}" ] && continue
    printf '%s\n' "${declared}" | grep -qxF "${addr}" && continue
    [ "$(address_in_cluster "${addr}" </dev/null)" = yes ] && continue
    warn "removing ${addr} from this node's .env — it is in neither the manifest nor the ring"
    setenv ETCD_INITIAL_CLUSTER "$(csv_drop "$(getenv ETCD_INITIAL_CLUSTER)" "=https?://${addr}:2380$")"
    setenv ETCD_HOSTS           "$(csv_drop "$(getenv ETCD_HOSTS)"           "^${addr}:2379$")"
    setenv DB_HOSTS             "$(csv_drop "$(getenv DB_HOSTS)"             "^${addr}:5432$")"
    dropped=$((dropped + 1))
  done
  [ "${dropped}" -gt 0 ] && info "removed ${dropped} orphaned declaration(s)"
  return 0
}

# Drop every comma-separated element matching a regex. Rebuilding the list this way
# (rather than sed-ing the whole string) cannot corrupt a neighbouring entry whose
# text happens to contain the one being removed.
csv_drop() {  # <csv> <regex>
  printf '%s' "$1" | tr ',' '\n' | grep -vE "$2" | paste -sd, - || true
}

# ── The manifest's four cases ────────────────────────────────────────────────
# The caller owns the "is it in the cluster?" half (only it can look at etcd and
# the roster); cluster-manifest.py owns the manifest half and returns the verdict.
# Exit 0 + RECORDED/RESUME → proceed · 3 ALREADY_ADDED → error · 4 DRIFT → stop.
record_in_manifest() {  # <add-node|add-witness> <address> [--name X] ; sets NODE_NAME/NODE_ROLE
  local verb="$1" address="$2"; shift 2
  local in_cluster flag="" out rc

  # FIRST: make sure there is a manifest here at all, and that it is not a
  # different document from the one the rest of the cluster holds. Recording into
  # a file that only this node has — or that disagrees with everyone else's — is
  # how the source of truth stopped describing reality in the first place.
  ensure_manifest

  in_cluster="$(address_in_cluster "${address}")"
  case "${in_cluster}" in
    yes) flag="--in-cluster" ;;
    no)  flag="" ;;
    unknown)
      step_fail "cannot tell whether ${address} is already a member of this cluster" \
        "etcd is unreachable on this node, so the wizard cannot answer the one question" \
        "the manifest needs — and guessing would either record a duplicate node or hide a" \
        "drifted manifest." \
        "Cure: bring the local etcd back, confirm the ring, then retry:" \
        "  ./taranac up -d etcd" \
        "  ./taranac cluster status"
      ;;
  esac

  out="$(cm "${verb}" --address "${address}" ${flag} "$@" 2>&1)"; rc=$?
  # stdout carries eval-able CM_* lines; stderr carries the human sentence. We
  # printed them together, so pick the machine lines back out before eval.
  local machine; machine="$(printf '%s\n' "${out}" | grep '^CM_')"
  # shellcheck disable=SC1090
  [ -n "${machine}" ] && eval "${machine}"

  case ${rc} in
    0)
      NODE_NAME="${CM_NAME:-}"; NODE_ROLE="${CM_ROLE:-}"
      case "${CM_CASE:-}" in
        RECORDED) ok "recorded '${NODE_NAME}' (${address}) as ${NODE_ROLE} in config/cluster.yml" ;;
        RESUME)   ok "'${NODE_NAME}' (${address}) was already declared and is not in the cluster — continuing the add" ;;
        *)        ok "manifest updated for ${address}" ;;
      esac
      ;;
    3)
      # ── Already a member: REINSTALL, refuse, or stop — decided by what the node
      #    is actually DOING, never by the roster row alone.
      #
      # "Already in the cluster" covers two situations that must not share an answer:
      # a healthy replica that is streaming right now, and a member that is dead,
      # rebuilt or being reinstalled. Offering a blanket "remove and re-add?" would
      # invite an operator to evict a working node — the cluster loses its redundancy
      # and re-clones a database for no reason. So the wizard looks first.
      handle_already_member "${address}" "${CM_NAME:-}" "$([ "${verb}" = add-witness ] && echo witness || echo replica)" || return 1
      ;;
    4)
      step_fail "the manifest has drifted — ${address} is in the cluster but not in config/cluster.yml" \
        "config/cluster.yml is the primary's declared source of truth. A member it does not" \
        "name is a hand-rolled join or an edited file, and growing the cluster now would" \
        "build on a description that has already stopped matching reality." \
        "Cure — pick one, then re-run this command:" \
        "  · adopt it into the manifest (if the node is legitimate):" \
        "      ./cluster-manifest.py add-node --address ${address}" \
        "  · or decommission it (if it is not):" \
        "      ./taranac cluster decommission --name <its name>" \
        "" \
        "$(printf '%s\n' "${out}" | grep -v '^CM_')"
      ;;
    *)
      step_fail "the manifest refused the entry for ${address}" \
        "$(printf '%s\n' "${out}" | grep -v '^CM_')"
      ;;
  esac

  # Reaching here means the manifest was accepted (cases 4 and * both exit), so
  # this node's file has just become the newest description of the cluster —
  # push it to every node. Cases 0 and 3 both land here: 3 goes through
  # handle_already_member, which evicts and RE-RECORDS, so its write needs
  # publishing just as much as a plain add does.
  publish_manifest
}

# =============================================================================
# PREFLIGHT — consult EVERY existing member before the cluster grows
# =============================================================================
# Its inputs come from the REPLICATED DATABASE, never from peer requests. Every
# node already publishes its own topology into the heartbeat
# (service_health.py::_record_config_report → node_config_reports), the write
# routes to the primary and replicates. The mechanism's own docstring gives the
# reason and it is the whole point: "no peer request that could hang exactly when
# a node is in trouble" — which is precisely the moment a preflight must produce
# an answer.
#
# It asserts:
#   1. every member has reported within the freshness window — a SILENT member
#      STOPS the add; it is never assumed healthy;
#   2. every member's topology matches this node's, except where `skip:` covers it;
#   3. the new node's address falls inside every member's PG_ALLOW_CIDR;
#   4. etcd has quorum and the ring stays at >= 3 voting members.
#
# On divergence it STOPS AND SHOWS — it never fixes anything. Rewriting a live
# member's configuration at the moment of a join is a surprise write at the worst
# possible time. A `skip:` entry marks a divergence *expected*: the line is still
# printed, with the recorded reason, because a silent skip is an invisible landmine.
preflight() {  # <new-address>
  local new_address="$1"
  local reference; reference="$(getenv TARANAC_NODE_NAME)"
  local work; work="$(mktemp -d)"

  if load_stale_window; then
    info "freshness window: ${STALE_AFTER_SECONDS}s (read from the api — the backend's own STALE_AFTER_SECONDS)"
  else
    info "freshness window: ${STALE_AFTER_SECONDS}s (the api could not be asked; using the same built-in value)"
  fi

  # Every active node's last published topology, with its age computed IN SQL
  # against the same session's now() — the primary's clock on both sides, so the
  # age is immune to cross-node skew. Exactly the comparison
  # ServiceHealthService.list_cluster_topology makes.
  psql_q "SELECT n.name,
                 coalesce(round(extract(epoch from now() - r.updated_at))::text, ''),
                 coalesce(r.fingerprint, ''),
                 coalesce(r.config_values::text, '')
          FROM cluster_nodes n
          LEFT JOIN node_config_reports r ON r.node_id = n.id
          WHERE n.status = 'active'
          ORDER BY n.name" > "${work}/reports.tsv"

  if [ ! -s "${work}/reports.tsv" ]; then
    rm -rf "${work}"
    step_fail "no member published a topology report — the preflight has nothing to consult" \
      "Either this node's database is unreachable, or no node has completed a heartbeat yet" \
      "(each node publishes one every 30s)." \
      "Cure: confirm the cluster answers, wait one heartbeat, and retry:" \
      "  ./taranac cluster status" \
      "  ./taranac logs --tail 50 api"
  fi

  # The roster: who has ACTUALLY completed a join. This, not any node's .env, is
  # what every member's DB_HOSTS has to cover — see the check that uses it.
  psql_q "SELECT address FROM cluster_nodes
           WHERE status = 'active' AND address IS NOT NULL
           ORDER BY address" > "${work}/roster.tsv"

  cm skips > "${work}/skips.tsv" 2>/dev/null || : > "${work}/skips.tsv"
  etcd_members > "${work}/members.tsv" 2>/dev/null || : > "${work}/members.tsv"
  etcd_health  > "${work}/health.tsv"  2>/dev/null || : > "${work}/health.tsv"

  python3 - "${new_address}" "${reference}" "${STALE_AFTER_SECONDS}" "${work}" "$(getenv ETCD_INITIAL_CLUSTER)" <<'PY'
"""Render the preflight report and decide whether the cluster may grow.

Formatting and the verdict live here rather than in bash because the report has
to NAME things — the node, the key, both values and the cure — and bash cannot
diff two JSON maps without inventing a parser.

Exit 0 = every assertion held (skip-covered divergences still printed).
Exit 1 = at least one assertion failed; the caller stops.
"""
import ipaddress
import json
import os
import sys

new_address, reference, stale_after, work = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
# THIS node's declared ring, read from the .env FILE rather than from its own
# heartbeat. The two can differ, and when they do it is the file that matters:
# the heartbeat is what the api published when it last started, while the file is
# what cluster-broker.py serves to the joining node minutes from now. A check
# against the heartbeat alone passes on a node whose .env was edited since — and
# then hands the joiner the edited value.
local_declared_ring = sys.argv[5] if len(sys.argv) > 5 else ""

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def read_tsv(name):
    path = os.path.join(work, name)
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if line.strip():
                rows.append(line.split("\t"))
    return rows


def covered(address, cidrs):
    """(verdict, explanation). An UNSET PG_ALLOW_CIDR is 0.0.0.0/0 by the
    postgres-ha entrypoint's own default, so it covers everything — reporting it
    as "not covered" would be a false alarm that stops a legitimate add."""
    if not cidrs.strip():
        return True, "unset -> 0.0.0.0/0 (the postgres-ha default)"
    try:
        addr = ipaddress.ip_address(address)
    except ValueError:
        return True, "not checked: %s is a name, and resolving it here would answer for THIS host" % address
    for part in (p.strip() for p in cidrs.split(",")):
        if not part:
            continue
        try:
            if addr in ipaddress.ip_network(part, strict=False):
                return True, part
        except ValueError:
            continue
    return False, cidrs


reports = []
for row in read_tsv("reports.tsv"):
    row = (row + ["", "", "", ""])[:4]
    name, age_s, fingerprint, values_json = row
    try:
        values = json.loads(values_json) if values_json else {}
    except ValueError:
        values = {}
    age = int(age_s) if age_s.strip().lstrip("-").isdigit() else None
    reports.append({
        "name": name,
        "age": age,
        "fingerprint": fingerprint,
        "values": values,
        "silent": age is None or age > stale_after,
    })

skips = {}
for row in read_tsv("skips.tsv"):
    row = (row + ["", "", ""])[:3]
    skips[(row[0], row[1])] = row[2]

members = [dict(zip(("name", "peer", "client", "learner"), (r + ["", "", "", ""])[:4]))
           for r in read_tsv("members.tsv")]
health = [dict(zip(("endpoint", "healthy"), (r + ["", ""])[:2])) for r in read_tsv("health.tsv")]

problems = []   # each entry: (headline, [cure lines...])  — these STOP the add
expected = []   # skip-covered divergences: printed, never a stop
stale    = []   # real drift that breaks nothing right now: printed, never a stop

# ── Which drift actually stops a join, and which is only worth knowing ────────
# Drift between members is INEVITABLE: the moment this node declares a new member,
# every node that joined earlier is out of date. Treating all of it as blocking
# would refuse every add after the first until the operator hand-edited each peer —
# exactly the toil this wizard exists to remove. So classify by consequence:
#
#   ETCD_HOSTS            one fewer DCS endpoint for that member's Patroni to try.
#                         It has the others; degraded, not broken.
#   DB_HOSTS              the write-routing list. If the node being added ever
#                         becomes the leader, a peer that does not list it cannot
#                         route writes to it — the cluster looks healthy and fails
#                         at the next failover. Blocking.
#   everything else       schemes, versions and the HA marker must match or the
#                         member is misconfigured now, not later. Blocking.
#
# ETCD_INITIAL_CLUSTER used to be in this set, described as "bootstrap-only: a
# RUNNING etcd takes the ring from Raft, so a stale value changes nothing until
# that member is recreated from scratch". Every clause of that is true, and the
# conclusion drawn from it was wrong twice over:
#
#   · "until that member is recreated from scratch" is not a distant hypothetical.
#     It is a rebuilt disk, a `--reinstall`, a wiped volume — the ordinary repair
#     operations. A member whose list is stale does not come back from any of
#     them: its etcd compares the list with the live ring and exits with
#     "member count is unequal".
#   · and the value is read at ONE more moment nobody had counted: `ha-join.sh`
#     hands the JOINING node this node's list (ha-join.sh:703). So the list on
#     whichever node someone runs `add-node` from is load-bearing at exactly the
#     moment this preflight is running, and this is the only place that holds
#     both it and the live ring.
#
# cluster-remove.sh:165 says outright that this preflight is what catches this
# key drifting. It now does. Section 2c below compares it against the ring.
NON_BLOCKING_KEYS = {"ETCD_HOSTS"}

# ── 1. Freshness ──────────────────────────────────────────────────────────────
print()
print("  Every member of this cluster, as IT reported itself (replicated heartbeat):")
print()
print("    %-24s %-12s %-11s %s" % ("NODE", "REPORTED", "TOPOLOGY", "PG_ALLOW_CIDR covers " + new_address))

ref = next((r for r in reports if r["name"] == reference and not r["silent"]), None)

for report in reports:
    age = "never" if report["age"] is None else "%ds ago" % report["age"]
    if report["silent"]:
        verdict, colour = "SILENT", RED
        coverage = "-"
    elif ref is not None and report["name"] == ref["name"]:
        verdict, colour = "reference", DIM
        yes, why = covered(new_address, report["values"].get("PG_ALLOW_CIDR", ""))
        coverage = ("yes (%s)" % why) if yes else ("NO (%s)" % why)
    else:
        same = ref is not None and report["fingerprint"] == ref["fingerprint"]
        verdict, colour = ("matches", GREEN) if same else ("DIFFERS", RED)
        yes, why = covered(new_address, report["values"].get("PG_ALLOW_CIDR", ""))
        coverage = ("yes (%s)" % why) if yes else ("NO (%s)" % why)
    print("    %-24s %-12s %s%-11s%s %s" % (report["name"], age, colour, verdict, RESET, coverage))

print()
print("    (the witness publishes nothing here — it runs etcd only, no Taranac node;")
print("     it is checked against the etcd ring below.)")

for report in reports:
    if not report["silent"]:
        continue
    seen = "has never reported" if report["age"] is None else "has not reported for %ds" % report["age"]
    problems.append((
        "%s %s (the freshness window is %ds)" % (report["name"], seen, stale_after),
        ["A silent member is NOT assumed healthy — it stops the add: its configuration is",
         "unknown, so 'every member agrees' cannot be observed.",
         "Cure: bring it back, or take it out of the cluster:",
         "  ./taranac cluster status",
         "  ./taranac cluster decommission --name %s" % report["name"]],
    ))

# ── 2. Topology agreement ─────────────────────────────────────────────────────
if ref is None:
    problems.append((
        "this node ('%s') has published no fresh topology of its own" % reference,
        ["The preflight diffs every member against THIS node, and there is nothing",
         "authoritative to diff against. Inventing a reference would report an agreement",
         "that was never observed.",
         "Cure: make sure the local api is up and has completed a heartbeat, then retry:",
         "  ./taranac ps api",
         "  ./taranac logs --tail 50 api"],
    ))
else:
    for report in reports:
        if report["silent"] or report["name"] == ref["name"]:
            continue
        for key in sorted(set(ref["values"]) | set(report["values"])):
            mine, theirs = ref["values"].get(key), report["values"].get(key)
            if mine == theirs:
                continue
            # 🔑 DB_HOSTS is checked for COVERAGE, not for equality — handled below.
            if key == "DB_HOSTS":
                continue
            headline = "%s disagrees with %s on %s" % (report["name"], ref["name"], key)
            detail = [
                "  %-28s %s" % (ref["name"] + " (reference):", mine if mine is not None else "(key absent)"),
                "  %-28s %s" % (report["name"] + ":", theirs if theirs is not None else "(key absent)"),
                "Cure: ON THAT NODE, pull the primary's values and apply them (the wizard",
                "      never rewrites a live member's config from here — a surprise write at",
                "      the moment of a join is the worst possible time):",
                "  ./taranac cluster sync",
            ]
            reason = skips.get((report["name"], key))
            if reason is not None:
                expected.append((headline, detail, reason))
            elif key in NON_BLOCKING_KEYS:
                stale.append((headline, detail))
            else:
                problems.append((headline, detail))

# ── 2b. DB_HOSTS covers every node that actually exists ──────────────────────
# 🔑 Compared against the ROSTER, never against this node's .env. Byte-equality with
# the local file is the wrong test twice over:
#   · this node legitimately lists the node being added, and no peer does yet — an
#     add would always "find" that as drift and refuse itself;
#   · this node's own file can be the WRONG one. A previous half-finished add leaves
#     an address in it that never became a member, and comparing peers against that
#     tells a correctly-configured peer to change. Seen exactly so: `cluster sync` on
#     the peer reported "already matches what the cluster reports" while the preflight
#     insisted it disagreed — because they were measuring against different things,
#     and the peer was right.
# What actually matters is narrower and checkable: every member must know every node
# that HAS joined, or it cannot route writes there when that node leads. Extra
# entries cost a connection attempt on failover, nothing more, so they do not block.
roster = [r[0].strip() for r in read_tsv("roster.tsv") if r and r[0].strip()]
for report in reports:
    if report["silent"]:
        continue
    listed = {h.strip() for h in (report["values"].get("DB_HOSTS") or "").split(",") if h.strip()}
    missing = [a for a in roster if "%s:5432" % a not in listed]
    if not missing:
        continue
    headline = "%s's DB_HOSTS does not list %s" % (report["name"], ", ".join(missing))
    detail = [
        "  the cluster's roster:  %s" % ", ".join(roster),
        "  %-22s %s" % (report["name"] + " lists:", ", ".join(sorted(listed)) or "(nothing)"),
        "DB_HOSTS is how that member finds the node to send WRITES to. A node it does",
        "not list cannot be followed when it becomes the leader — the cluster looks",
        "healthy until the failover that needs it.",
        "Cure: ON THAT NODE, pull what the cluster reports about itself:",
        "  ./taranac cluster sync",
    ]
    reason = skips.get((report["name"], "DB_HOSTS"))
    if reason is not None:
        expected.append((headline, detail, reason))
    else:
        problems.append((headline, detail))

# ── 2c. The declared etcd ring against the LIVE one ──────────────────────────
# The check the section above explains. A member's ETCD_INITIAL_CLUSTER must name
# exactly the live ring — no more, no fewer — because that is the comparison etcd
# itself makes, byte for byte, the next time that member's etcd starts on an empty
# data directory, and because `add-node` serves this list to the node it is
# adding. The node being added is excluded from both sides: it is legitimately
# already declared here and legitimately not yet a member.
def peers(value):
    """`n1=https://host:2380,n2=…` → {"host:2380", …}. Scheme-insensitive: the
    scheme is checked as its own key (ETCD_CLIENT_SCHEME) and mixing it in here
    would report one fault twice."""
    out = set()
    for part in (value or "").split(","):
        part = part.strip()
        if "=" not in part:
            continue
        url = part.split("=", 1)[1].strip()
        if "//" in url:
            url = url.split("//", 1)[1]
        if url:
            out.add(url)
    return out


live_ring = set()
for member in members:
    for url in (member.get("peer") or "").split(","):
        url = url.strip()
        if "//" in url:
            url = url.split("//", 1)[1]
        if url:
            live_ring.add(url)

new_peer = "%s:2380" % new_address

# Who is checked, and with which copy of the value:
#   · THIS node, from its .env file — the copy that is about to be SERVED to the
#     joining node. This is the one that decides whether the join can work at all.
#   · every other member, from its heartbeat — the only copy of theirs this node
#     can see without asking them, which is deliberate (the preflight never makes
#     a peer request that could hang exactly when a node is in trouble).
checked = []
if local_declared_ring:
    checked.append((reference + " (this node, from .env)", peers(local_declared_ring)))
for report in reports:
    if report["silent"] or report["name"] == reference:
        continue
    declared = peers(report["values"].get("ETCD_INITIAL_CLUSTER", ""))
    if declared:
        checked.append((report["name"], declared))

if live_ring:
    for member_name, declared in checked:
        node_name = member_name.split(" (")[0]
        # Two shapes, and only one of them is a fault.
        #
        #   MISSING — the declaration does not name a member that IS in the ring.
        #     Unambiguous, silent, and exactly what `add-node` leaves behind on
        #     every peer by design. That member cannot come back from an empty
        #     data directory, and if the next `add-node` is run FROM it the node
        #     it adds receives the short list and dies with "member count is
        #     unequal". Blocking.
        #
        #   EXTRA — the declaration names a member that is not in the ring yet.
        #     That is the ORDINARY state of a topology declared up front and built
        #     one node at a time: `init` declares every node, `add-witness` trims
        #     the ring to three, and each remaining node is still declared while
        #     it waits its turn. Reported, never blocking — refusing it would
        #     refuse the documented flow.
        extra = sorted(declared - live_ring - {new_peer})
        missing = sorted(live_ring - declared - {new_peer})
        if not missing:
            if extra:
                stale.append((
                    "%s declares %s, which the ring does not hold yet"
                    % (member_name, ", ".join(extra)),
                    ["  the live ring:   %s" % ", ".join(sorted(live_ring)),
                     "  a node declared at init is listed until it joins — expected while the"],
                ))
            continue
        headline = "%s's declared etcd ring is not the ring that is running" % member_name
        detail = [
            "  the live ring:   %s" % ", ".join(sorted(live_ring)),
            "  %-16s %s" % (node_name + " declares:", ", ".join(sorted(declared)) or "(nothing)"),
        ]
        detail.append("  does not name a member that IS in the ring:  %s" % ", ".join(missing))
        if extra:
            detail.append("  (it also names %s, not in the ring yet — that part is expected)"
                          % ", ".join(extra))
        detail += [
            "ETCD_INITIAL_CLUSTER is not advisory. etcd compares it with the live ring the",
            "next time that member starts on an empty data directory — a rebuilt disk, a",
            "--reinstall, a restored node — and refuses to start on any difference",
            "(\"member count is unequal\"). And 'cluster add-node' hands THIS list to the",
            "node it is adding, so a short list here is a join that cannot succeed.",
            "Cure: ON THAT NODE, pull what the live ring reports:",
            "  ./taranac cluster sync",
        ]
        reason = skips.get((node_name, "ETCD_INITIAL_CLUSTER"))
        if reason is not None:
            expected.append((headline, detail, reason))
        else:
            problems.append((headline, detail))

# ── 3. PG_ALLOW_CIDR reaches the new node ─────────────────────────────────────
for report in reports:
    if report["silent"]:
        continue
    yes, why = covered(new_address, report["values"].get("PG_ALLOW_CIDR", ""))
    if yes:
        continue
    headline = "%s would refuse %s: its PG_ALLOW_CIDR does not cover that address" % (report["name"], new_address)
    detail = [
        "  %s's PG_ALLOW_CIDR: %s" % (report["name"], why),
        "PG_ALLOW_CIDR is rendered into that node's pg_hba at container start. Outside it,",
        "the new node's replication login is refused AFTER the TCP handshake — the port",
        "answers, so nothing looks broken until the failover that needs it.",
        "Cure: widen it on that node and apply it there:",
        "  PG_ALLOW_CIDR=%s,<the new node's subnet>   in its .env" % why,
        "  ./taranac up -d",
    ]
    reason = skips.get((report["name"], "PG_ALLOW_CIDR"))
    if reason is not None:
        expected.append((headline, detail, reason))
    else:
        problems.append((headline, detail))

# ── 4. etcd quorum and the size of the ring ───────────────────────────────────
voting = [m for m in members if m.get("learner") != "true"]
healthy = [h for h in health if h.get("healthy") == "true"]

print()
if not members:
    problems.append((
        "the etcd ring could not be read on this node",
        ["Without it, neither quorum nor the voting count can be observed, and both decide",
         "whether the cluster survives losing a node.",
         "Cure: check the local etcd, then retry:",
         "  ./taranac ps etcd",
         "  ./taranac logs --tail 50 etcd"],
    ))
else:
    already = any(("//%s:" % new_address) in m.get("peer", "") + "," + m.get("client", "") for m in members)
    after = len(voting) + (0 if already else 1)
    print("  etcd: %d voting member(s) now, %d after this add; %d of %d endpoint(s) healthy." %
          (len(voting), after, len(healthy), len(health)))
    if health and len(healthy) * 2 <= len(health):
        problems.append((
            "etcd has no quorum: only %d of %d endpoints are healthy" % (len(healthy), len(health)),
            ["A ring without quorum cannot elect a leader, so the node you are about to add",
             "could not be admitted to the DCS anyway.",
             "Cure: restore the unhealthy member(s) first:",
             "  docker exec taranac-etcd etcdctl endpoint health --cluster"],
        ))
    if after < 3:
        problems.append((
            "the ring would hold %d voting etcd member(s) after this add; HA requires at least 3" % after,
            ["With fewer than three voters a partition has no majority and failover is unsafe.",
             "Cure: add the witness arbiter first — on a SEPARATE failure domain:",
             "  ./taranac cluster add-witness --address <witness address>"],
        ))

# ── The report ────────────────────────────────────────────────────────────────
for headline, detail, reason in expected:
    print()
    print("  %s! %s%s" % (YELLOW, headline, RESET))
    for line in detail:
        print("    %s" % line)
    print("    %sexpected: skip: in config/cluster.yml — \"%s\"%s" % (DIM, reason, RESET))
    print("    (printed anyway: a silent skip is an invisible landmine.)")

# Drift that breaks nothing today is still worth SAYING — silence would let a
# cluster drift indefinitely with nobody ever told. It just does not stop the add.
if stale:
    print()
    print("  %s! %d value(s) are out of date on a peer, which breaks nothing right now:%s" % (YELLOW, len(stale), RESET))
    for headline, detail in stale:
        print()
        print("   · %s" % headline)
        for line in detail[:2]:
            print("     %s" % line)
    print()
    print("     ETCD_HOSTS is a list of DCS endpoints for that member's Patroni to try, and")
    print("     it has the others — one stale entry is degraded, not broken.")
    print("     Bring those nodes up to date when convenient, ON EACH of them:")
    print("       ./taranac cluster sync")

if problems:
    print()
    print("  %s✗ preflight refuses to grow the cluster — %d finding(s):%s" % (RED, len(problems), RESET))
    for headline, detail in problems:
        print()
        print("   · %s" % headline)
        for line in detail:
            print("     %s" % line)
    print()
    print("  Nothing was changed. Nothing is fixed for you on purpose: rewriting a live")
    print("  member's configuration during a join is a surprise write at the worst")
    print("  possible time. Cure each finding above on the node it names, then retry.")
    sys.exit(1)

print()
print("  %s✓ every member agrees, is fresh, and can reach %s.%s" % (GREEN, new_address, RESET))
if expected:
    print("    (%d expected divergence(s) above are covered by skip: entries.)" % len(expected))
sys.exit(0)
PY
  local rc=$?
  rm -rf "${work}"
  return ${rc}
}

# =============================================================================
# The declared topology → this node's .env
# =============================================================================
# ha-convert.sh REQUIRES the cluster-wide block to already be in .env (it checks
# TARANAC_CLUSTER_NAME, DB_HOSTS, ETCD_HOSTS, ETCD_INITIAL_CLUSTER and
# POSTGRES_REPLICATION_PASSWORD and refuses without them), and its PREPARE phase
# issues an etcd leaf for every member named in ETCD_INITIAL_CLUSTER. That is the
# concrete reason the operator declares ALL the nodes up front: the witness only
# gets a pre-issued leaf if it is in that list when --prepare runs.
#
# Declaring the whole ring now also means every node's DB_HOSTS is the same from
# the first day. The alternative — growing DB_HOSTS as nodes arrive — would mean
# rewriting every existing member's .env at join time, which is exactly the
# surprise write the preflight refuses to do.
write_env_topology() {  # <cluster> <primary-name> <primary-addr> <cidr> <etcd_initial> <etcd_hosts> <db_hosts>
  local cluster="$1" pname="$2" paddr="$3" cidr="$4" initial="$5" ehosts="$6" dhosts="$7"
  setenv TARANAC_CLUSTER_NAME       "${cluster}"
  # This INCARNATION of the cluster, as distinct from its name. etcd derives the
  # ring's ClusterID from it, so two clusters that share a name are still two
  # clusters and a leftover member of the old one cannot rejoin the new. Drawn
  # only when absent, so re-running init on a half-built cluster keeps the ring
  # it already declared; ha-deconvert clears it, which is what makes a genuine
  # rebuild a genuinely new cluster.
  [ -n "$(getenv TARANAC_CLUSTER_ID)" ] || setenv TARANAC_CLUSTER_ID "$(openssl rand -hex 16)"
  # When this ring was FORMED — the companion fact to the id above, and drawn at the
  # same moment for the same reason. The failover rehearsal refuses on a cluster that
  # looks like it is in service, and the only age it could measure before this was the
  # oldest ROSTER row: a surviving node keeps that row across a deconvert-and-rebuild,
  # so a stand rebuilt in the morning reported 12.9 days and refused its own rehearsal.
  # Minted only when absent (--continue / a re-run of init must not restamp a ring that
  # already exists), cleared by ha-deconvert, and adopted verbatim by joining nodes.
  [ -n "$(getenv TARANAC_CLUSTER_FORMED_AT)" ] || setenv TARANAC_CLUSTER_FORMED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  setenv TARANAC_NODE_NAME          "${pname}"
  setenv NODE_ADDRESS               "${paddr}"
  setenv ETCD_NAME                  "${pname}"
  setenv ETCD_INITIAL_CLUSTER       "${initial}"
  setenv ETCD_INITIAL_CLUSTER_STATE new
  setenv ETCD_HOSTS                 "${ehosts}"
  setenv DB_HOSTS                   "${dhosts}"
  [ -n "${cidr}" ] && setenv PG_ALLOW_CIDR "${cidr}"
  [ -n "$(getenv DB_CONNECT_TIMEOUT)" ] || setenv DB_CONNECT_TIMEOUT 3
}

# =============================================================================
# init
# =============================================================================
cmd_init() {
  local cluster="" address="" name="" witness="" witness_name="" cidr="" force="" derived_any=""
  local -a extra_nodes=() extra_names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --cluster)        cluster="${2:-}"; shift 2 ;;
      --address)        address="${2:-}"; shift 2 ;;
      # --name is, and stays, the name of THIS node — wherever it appears on the
      # line. That is exactly why a per-node name is not spelled --name: a command
      # written today has to mean tomorrow what it means today.
      --name)           name="${2:-}"; shift 2 ;;
      --witness)        split_addr_name "${2:-}" --witness
                        witness="${SPEC_ADDR}"; witness_name="${SPEC_NAME}"; shift 2 ;;
      --node)           split_addr_name "${2:-}" --node
                        extra_nodes+=("${SPEC_ADDR}"); extra_names+=("${SPEC_NAME}"); shift 2 ;;
      --pg-allow-cidr)  cidr="${2:-}"; shift 2 ;;
      --force)          force=1; shift ;;
      --yes|-y)         ASSUME_YES=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) fail "unknown option '$1' for 'cluster init'." "Run  ./taranac cluster init --help  for the supported options." ;;
    esac
  done

  require_bundle
  steps 8

  # ── 1 ──────────────────────────────────────────────────────────────────────
  step "checking that this node can still become the seed of a new cluster"
  if [ "$(getenv TARANAC_HA)" = "1" ]; then
    step_fail "this node is already an HA node (TARANAC_HA=1 in .env)" \
      "init converts a STANDALONE node into the seed; it is a one-time operation, and" \
      "re-running it on a live cluster would restart the stack and can force a failover." \
      "Cure: inspect what you have, and grow it with the other two commands:" \
      "  ./taranac cluster status" \
      "  ./taranac cluster add-node --address <addr>"
  fi
  if ! docker volume inspect taranac_pg_data >/dev/null 2>&1; then
    step_fail "the Postgres volume 'taranac_pg_data' does not exist on this host" \
      "init converts an INSTALLED, populated standalone node into the seed — Patroni adopts" \
      "its data directory in place. A host with no data has nothing to seed from." \
      "Cure: install and start this node first, then re-run init:" \
      "  ./install.sh"
  fi
  local replpw; replpw="$(getenv POSTGRES_REPLICATION_PASSWORD)"
  if [ -z "${replpw}" ] || [ "${replpw}" = "__GENERATE__" ]; then
    step_fail "POSTGRES_REPLICATION_PASSWORD is not set in .env" \
      "The 'replicator' role was created with this value when this node's database was" \
      "initialised, and it is the credential every replica logs in with." \
      "The wizard will not mint a new one: the role's password in the database would not" \
      "change with it, and every join would then fail authentication for a reason that" \
      "nothing reports." \
      "Cure: restore the value from your install record into .env, or ALTER the role to a" \
      "new one and put the same value in .env:" \
      "  docker exec -it taranac-db psql -U taranac -c \"ALTER ROLE replicator PASSWORD '<new>'\""
  fi
  # 🔑 A leftover etcd volume is a ring this node used to belong to. Starting a NEW
  # cluster on top of it produces one that comes up already believing in members that
  # do not exist — 1 live of 2 declared is not a majority, so the ring never becomes
  # usable and the failure surfaces much later, when a witness is refused with
  # "unhealthy cluster" and the blame lands on the machine being added. `detach` now
  # clears this, but init cannot assume every predecessor was a clean detach: a node
  # may have been half-torn-down, restored from a backup, or converted before this
  # version existed.
  if docker volume inspect taranac_etcd_data >/dev/null 2>&1; then
    warn "this node still holds etcd state from a previous cluster"
    info "a new ring built on it would inherit that cluster's members and never reach"
    info "quorum. etcd here stores only Raft membership — no application data."
    confirm "Remove the previous etcd state and start a clean ring?" || step_fail \
      "left the previous etcd state in place" \
      "init cannot build a healthy ring on top of it. Remove it yourself and re-run:" \
      "  docker rm -f taranac-etcd && docker volume rm taranac_etcd_data"
    docker rm -f taranac-etcd >/dev/null 2>&1 || true
    docker volume rm taranac_etcd_data >/dev/null 2>&1 || step_fail \
      "could not remove taranac_etcd_data" \
      "Something still uses it. Find it, stop it, and re-run:" \
      "  docker ps -a --filter volume=taranac_etcd_data"
    ok "previous etcd state removed"
  fi
  ok "standalone, populated, and carrying a replication credential — this node can seed a cluster"

  # ── 2 ──────────────────────────────────────────────────────────────────────
  step "collecting the cluster's declared topology"

  # Names are checked HERE, before either branch, because both of them write:
  # the merge path records into an existing manifest and the declaration path
  # builds a new one. Checked against cluster-manifest.py's own rule, so there is
  # one definition of a usable name in the bundle.
  local _n
  if [ -n "${witness_name}" ] && ! valid_node_name "${witness_name}"; then
    step_fail "'${witness_name}' is not a usable node name" \
      "It becomes ETCD_NAME and the Patroni member name: letters, digits, dot, dash" \
      "or underscore, starting with a letter or digit, at most 63 characters." \
      "The form is  --witness <address>=<name>."
  fi
  for _n in ${extra_names[@]+"${extra_names[@]}"}; do
    [ -n "${_n}" ] || continue
    valid_node_name "${_n}" || step_fail "'${_n}' is not a usable node name" \
      "It becomes ETCD_NAME and the Patroni member name: letters, digits, dot, dash" \
      "or underscore, starting with a letter or digit, at most 63 characters." \
      "The form is  --node <address>=<name>."
  done

  local manifest_exists=""
  if [ -f "${MANIFEST}" ] && [ -z "${force}" ]; then
    manifest_exists=1
    info "config/cluster.yml already exists — reading the topology from it instead of asking again"
    info "(this is what makes init retryable after an interrupted run; --force starts over)"
    # 🔑 …but a value the operator TYPED beats a file they did not. Reusing the manifest
    # is what makes an interrupted init retryable; silently discarding the arguments of
    # THIS invocation is a different thing entirely. It produced a run that accepted
    # `--witness X --node Y`, declared a one-member ring from a stale file, and then
    # refused itself for having too few members — while both addresses sat unused in
    # the command line above. Seen on the stand after a detach left a one-node manifest.
    # So: merge them in. Addresses already declared are a no-op; new ones are recorded.
    if [ -n "${witness}" ] || [ ${#extra_nodes[@]} -gt 0 ]; then
      local _added=0 _i
      if [ -n "${witness}" ] && ! cm get --address "${witness}" >/dev/null 2>&1; then
        cm add-witness --address "${witness}" ${witness_name:+--name "${witness_name}"} \
          >/dev/null 2>&1 && _added=$((_added + 1))
      fi
      # An index loop, not a value loop: the name given for an address travels
      # with it, and only the index ties the two arrays together.
      for (( _i = 0; _i < ${#extra_nodes[@]}; _i++ )); do
        [ -n "${extra_nodes[$_i]}" ] || continue
        cm get --address "${extra_nodes[$_i]}" >/dev/null 2>&1 && continue
        cm add-node --address "${extra_nodes[$_i]}" ${extra_names[$_i]:+--name "${extra_names[$_i]}"} \
          >/dev/null 2>&1 && _added=$((_added + 1))
      done
      if [ "${_added}" -gt 0 ]; then
        info "…and merging the ${_added} address(es) you gave on THIS command line into it"
      fi
    fi
  elif [ -f "${MANIFEST}" ]; then
    warn "--force: config/cluster.yml will be recreated, DISCARDING any 'skip:' entries you wrote"
  fi

  local -a node_names=() node_addrs=() node_roles=()
  if [ -n "${manifest_exists}" ]; then
    local mout; mout="$(cm show 2>/dev/null)" || step_fail \
      "config/cluster.yml exists but could not be read" \
      "$(cm validate 2>&1)"
    # shellcheck disable=SC1090
    eval "${mout}"
    cluster="${CM_CLUSTER}"; cidr="${CM_PG_ALLOW_CIDR}"
    local n a r
    while IFS=$'\t' read -r n a r; do
      [ -n "${n}" ] || continue
      node_names+=("${n}"); node_addrs+=("${a}"); node_roles+=("${r}")
      [ "${r}" = "primary" ] && { name="${n}"; address="${a}"; }
      [ "${r}" = "witness" ] && witness="${a}"
    done < <(cm list)
    [ -n "${address}" ] || step_fail \
      "config/cluster.yml declares no node with role 'primary'" \
      "The seed must be named in the manifest before it can be converted." \
      "Cure: record this node, then re-run init:" \
      "  ./cluster-manifest.py add-node --address <this host's IP> --role primary"
  else
    hdr "Declaring the cluster"
    printf '%s\n' \
      "  Answer for the WHOLE cluster now, not just this node. Two things depend on it:" \
      "  the etcd ring must be declared complete before the conversion (a member missing" \
      "  from it gets no certificate and can never join), and every node then carries the" \
      "  same node list from day one — nothing has to be rewritten later on a live member." \
      ""
    [ -n "${cluster}" ] || ask cluster "Cluster name (identical on every node)" "$(getenv TARANAC_CLUSTER_NAME || true)"
    cluster="${cluster:-taranac}"
    [ -n "${address}" ] || ask address "This node's address, as the OTHER nodes route to it" "$(getenv NODE_ADDRESS || true)"
    [ -n "${address}" ] || step_fail "no address was given for this node" \
      "Every other node and the witness reach this one by it, and it goes into DB_HOSTS," \
      "the etcd member URL and this node's TLS certificate." \
      "Cure:  ./taranac cluster init --address <this host's IP>"
    valid_address "${address}" || step_fail "'${address}' is not a usable node address" \
      "Give a bare IP or DNS name — no scheme, no port, no path (the tooling appends 5432," \
      "2379 and 2380 itself).  e.g. --address 10.0.0.1"
    [ -n "${witness}" ] || ask witness "Witness address (the 3rd etcd arbiter, a SEPARATE host)" ""
    [ -n "${witness}" ] || step_fail "no witness address was given" \
      "HA needs three etcd voters: both DB nodes plus an arbiter in a separate failure" \
      "domain. With two, a partition has no majority and failover is unsafe — which is why" \
      "ha-join.sh refuses a ring smaller than three." \
      "Cure: pick a third host (it needs ~100MB and docker, nothing else) and re-run:" \
      "  ./taranac cluster init --witness <its address>"
    valid_address "${witness}" || step_fail "'${witness}' is not a usable witness address" \
      "Give a bare IP or DNS name — no scheme and no port."
    if [ ${#extra_nodes[@]} -eq 0 ] && [ -z "${ASSUME_YES}" ] && [ -t 0 ]; then
      local more=""
      while :; do
        ask more "Another node — <address>, or <address>=<name> to choose its name (blank when done)" ""
        [ -n "${more}" ] || break
        split_addr_name "${more}" --node
        [ -z "${SPEC_NAME}" ] || valid_node_name "${SPEC_NAME}" || step_fail \
          "'${SPEC_NAME}' is not a usable node name" \
          "Letters, digits, dot, dash or underscore, starting with a letter or digit."
        extra_nodes+=("${SPEC_ADDR}"); extra_names+=("${SPEC_NAME}")
        more=""
      done
    fi

    name="${name:-${cluster}-node-1}"
    node_names+=("${name}");    node_addrs+=("${address}"); node_roles+=("primary")
    node_names+=("${witness_name:-witness}"); node_addrs+=("${witness}"); node_roles+=("witness")

    # Derived names are handed out from the first FREE {cluster}-node-N, not from
    # the position in the argument list. Positional numbering would hand a name
    # to an unnamed node that an explicit `--node X=taranac-node-2` had already
    # taken — two members answering to one name, which is a ring that cannot
    # form. HAL_DERIVED_ANY records whether we invented any name at all, because
    # an operator who did not choose one is entitled to know that the choice is
    # effectively permanent.
    local extra _i _cand _taken _x
    for (( _i = 0; _i < ${#extra_nodes[@]}; _i++ )); do
      extra="${extra_nodes[$_i]}"
      valid_address "${extra}" || step_fail "'${extra}' is not a usable node address" \
        "Give a bare IP or DNS name — no scheme and no port; add =<name> to choose its name."
      if [ -n "${extra_names[$_i]}" ]; then
        node_names+=("${extra_names[$_i]}")
      else
        local _n=2
        while :; do
          _cand="${cluster}-node-${_n}"; _taken=""
          for _x in ${node_names[@]+"${node_names[@]}"} ${extra_names[@]+"${extra_names[@]}"}; do
            [ "${_x}" = "${_cand}" ] && { _taken=1; break; }
          done
          [ -z "${_taken}" ] && break
          _n=$((_n + 1))
        done
        node_names+=("${_cand}"); derived_any=1
      fi
      node_addrs+=("${extra}"); node_roles+=("replica")
    done

    # Two members answering to one name is not a naming problem, it is a cluster
    # that never forms — etcd rejects the duplicate and Patroni cannot tell the
    # two apart. Caught here, while it is still one edit to the command line.
    local _a _b
    for _a in "${!node_names[@]}"; do
      for _b in "${!node_names[@]}"; do
        [ "${_a}" -lt "${_b}" ] || continue
        [ "${node_names[$_a]}" = "${node_names[$_b]}" ] && step_fail \
          "two nodes are given the same name '${node_names[$_a]}'" \
          "${node_addrs[$_a]} and ${node_addrs[$_b]} would both answer to it. A node's name" \
          "becomes its ETCD_NAME and its Patroni member name, and both must be unique in the" \
          "ring — a duplicate is refused by etcd and the cluster never forms." \
          "Cure: give each machine its own name:" \
          "  --node ${node_addrs[$_b]}=<name>"
      done
    done

    if [ -z "${cidr}" ]; then
      cidr="$(derive_pg_allow_cidr ${node_addrs[@]+"${node_addrs[@]}"})"
      [ -z "${cidr}" ] || info "PG_ALLOW_CIDR derived from the declared addresses: ${cidr}"
    fi
  fi
  ok "${#node_names[@]} node(s) declared for cluster '${cluster}'"

  # Every declared address must be inside PG_ALLOW_CIDR, or that node's
  # replication login is refused by pg_hba after the TCP handshake — i.e. it looks
  # fine until the failover that needs it. Catch it here, while it is one edit.
  local i
  for i in "${!node_addrs[@]}"; do
    [ "${node_roles[$i]}" = "witness" ] && continue   # the witness runs no Postgres
    cidr_covers "${node_addrs[$i]}" "${cidr}" || step_fail \
      "PG_ALLOW_CIDR (${cidr}) does not cover ${node_names[$i]} (${node_addrs[$i]})" \
      "PG_ALLOW_CIDR becomes this cluster's pg_hba scope. A node outside it can open a TCP" \
      "connection to 5432 and still be refused at authentication — nothing looks broken" \
      "until replication is needed." \
      "Cure: widen it to cover every declared node, e.g." \
      "  ./taranac cluster init --pg-allow-cidr ${cidr},$(derive_pg_allow_cidr "${node_addrs[$i]}")"
  done

  # ── 3 ──────────────────────────────────────────────────────────────────────
  step "showing the plan before anything is written"
  local etcd_initial="" etcd_hosts="" db_hosts=""
  for i in "${!node_names[@]}"; do
    etcd_initial="${etcd_initial:+${etcd_initial},}${node_names[$i]}=https://${node_addrs[$i]}:2380"
    etcd_hosts="${etcd_hosts:+${etcd_hosts},}${node_addrs[$i]}:2379"
    [ "${node_roles[$i]}" = "witness" ] || db_hosts="${db_hosts:+${db_hosts},}${node_addrs[$i]}:5432"
  done
  printf '\n'
  printf '  cluster:         %s\n' "${cluster}"
  printf '  this node:       %s (%s) — becomes the primary\n' "${name}" "${address}"
  for i in "${!node_names[@]}"; do
    [ "${node_roles[$i]}" = "primary" ] && continue
    printf '  declared:        %s (%s) — %s\n' "${node_names[$i]}" "${node_addrs[$i]}" "${node_roles[$i]}"
  done
  printf '  pg_allow_cidr:   %s\n' "${cidr:-(unset -> 0.0.0.0/0, the postgres-ha default)}"
  printf '  etcd ring:       %s\n' "${etcd_initial}"
  printf '\n'
  printf '  This will: write config/cluster.yml, write the cluster block into .env, and run\n'
  printf '  ha-convert.sh --prepare (which generates the etcd CA and every member'\''s leaf).\n'
  printf '  It does NOT convert the database — that happens in add-witness, once the witness\n'
  printf '  is a live etcd member. The stack keeps running standalone until then.\n\n'
  # Said only when we invented a name, and said plainly: there is no rename. The
  # name reaches the manifest, .env, ETCD_NAME, the ring, the certificate SANs,
  # the roster row, Patroni and every diagnostic, and the supported way to change
  # it is to rebuild that machine. An operator who is about to accept a name they
  # did not choose should know that now, not the first time a bundle calls their
  # host something they do not recognise.
  if [ -n "${derived_any}" ]; then
    printf '  A node cannot be renamed afterwards — the name is written into the etcd ring, the\n'
    printf '  certificates and every node'"'"'s .env, so changing it means rebuilding that machine.\n'
    printf '  The names above that you did not choose were derived. To choose them instead, re-run\n'
    printf '  with  --node <address>=<name>  (and  --witness <address>=<name>).\n\n'
  fi
  confirm "Proceed?"
  ok "confirmed"

  # ── 4 ──────────────────────────────────────────────────────────────────────
  step "writing the manifest config/cluster.yml"
  if [ -n "${manifest_exists}" ]; then
    ok "already written by an earlier run — left exactly as it is (including your skip: entries)"
  else
    # Built in a temp file and moved into place only once every entry validated:
    # a half-written source of truth is worse than none, and cluster-manifest.py's
    # own validators are the single definition of a usable name/address.
    local tmp; tmp="$(mktemp -d)"
    local out rc
    # An ARRAY, not ${cidr:+--pg-allow-cidr "$cidr"}: quotes produced by a
    # parameter expansion are not removed afterwards, so that idiom would hand
    # the helper a value with literal double quotes around it.
    local -a cidr_opt=(); [ -n "${cidr}" ] && cidr_opt=(--pg-allow-cidr "${cidr}")
    out="$(python3 "${CM}" init --file "${tmp}/cluster.yml" --cluster "${cluster}" \
            --address "${address}" --name "${name}" ${cidr_opt[@]+"${cidr_opt[@]}"} 2>&1)"; rc=$?
    [ ${rc} -eq 0 ] || { rm -rf "${tmp}"; step_fail "the manifest could not be created" "${out}"; }
    for i in "${!node_names[@]}"; do
      [ "${node_roles[$i]}" = "primary" ] && continue
      local verb="add-node"; [ "${node_roles[$i]}" = "witness" ] && verb="add-witness"
      out="$(python3 "${CM}" "${verb}" --file "${tmp}/cluster.yml" \
              --address "${node_addrs[$i]}" --name "${node_names[$i]}" 2>&1)"; rc=$?
      [ ${rc} -eq 0 ] || { rm -rf "${tmp}"; step_fail \
        "the manifest refused ${node_names[$i]} (${node_addrs[$i]})" "${out}"; }
    done
    out="$(python3 "${CM}" validate --file "${tmp}/cluster.yml" 2>&1)"; rc=$?
    [ ${rc} -eq 0 ] || { rm -rf "${tmp}"; step_fail "the manifest we generated does not validate" "${out}"; }
    mkdir -p "${HERE}/config"
    mv -f "${tmp}/cluster.yml" "${MANIFEST}" || { rm -rf "${tmp}"; step_fail \
      "config/cluster.yml could not be written" \
      "Cure: the bundle directory must be writable by you:" \
      "  sudo chown -R \$(id -u):\$(id -g) ${HERE}/config"; }
    rm -rf "${tmp}"
    ok "$(cm validate 2>&1)"
  fi
  # Both branches publish, including the "already written" one: a previous run may
  # have created the file and failed to publish it (the api was down, the operator
  # hit Ctrl-C), and init is the retryable command. Publishing is idempotent — the
  # api answers "already matches" and writes nothing.
  publish_manifest

  # ── 5 ──────────────────────────────────────────────────────────────────────
  step "writing the cluster-wide block into .env"
  write_env_topology "${cluster}" "${name}" "${address}" "${cidr}" "${etcd_initial}" "${etcd_hosts}" "${db_hosts}"
  ok "DB_HOSTS, ETCD_HOSTS, ETCD_INITIAL_CLUSTER, TARANAC_CLUSTER_NAME and this node's identity are set"

  # ── 6 ──────────────────────────────────────────────────────────────────────
  step "reading the .env block back and checking it is what the convert requires"
  local k
  for k in TARANAC_CLUSTER_NAME DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER POSTGRES_REPLICATION_PASSWORD; do
    [ -n "$(getenv "${k}")" ] || step_fail "${k} did not survive the write to .env" \
      "ha-convert refuses without it, so the next step would stop anyway." \
      "Cure: check the file for a stray duplicate of that key:" \
      "  grep -n '^${k}=' .env"
  done
  local mcount; mcount="$(getenv ETCD_INITIAL_CLUSTER | tr ',' '\n' | grep -c '=')"
  [ "${mcount}" -ge 3 ] || step_fail "the declared etcd ring has ${mcount} member(s); HA requires at least 3" \
    "A cluster needs its database nodes plus an arbiter in a separate failure domain —" \
    "with fewer, a partition has no majority and failover is unsafe." \
    "Cure: name the missing members. They are MERGED into the existing manifest, so your" \
    "'skip:' entries survive and --force is not needed:" \
    "  ./taranac cluster init --witness <addr> --node <addr>" \
    "(--force starts the declaration over and DISCARDS the skip: section — only for that.)"
  ok "the ring declares ${mcount} etcd members; every value the convert reads is present"

  # ── 7 ──────────────────────────────────────────────────────────────────────
  step "running ha-convert.sh --prepare (etcd CA + a leaf for every member)"
  [ -x "${CONVERT}" ] || step_fail "ha-convert.sh is missing from the bundle" \
    "Cure: refresh the bundle once and retry:  ./taranac update"
  TARANAC_WIZARD=1 bash "${CONVERT}" --prepare --node-name "${name}" --node-address "${address}" || step_fail \
    "ha-convert.sh --prepare did not complete" \
    "Nothing was converted — the stack is still standalone and this is retryable." \
    "Read the message above, fix the cause, then run the same command again:" \
    "  ./taranac cluster init"

  # ── 8 ──────────────────────────────────────────────────────────────────────
  step "verifying what --prepare was supposed to produce"
  [ -s "${CA_DIR}/ca.crt" ] || step_fail "no etcd CA at config/etcd-ca/ca.crt" \
    "Cure: re-run  ./taranac cluster init  and read ha-convert's output."
  [ -s "${TLS_DIR}/etcd-server.crt" ] || step_fail "this node got no etcd leaf (config/etcd-tls/etcd-server.crt)" \
    "Cure: re-run  ./taranac cluster init  and read ha-convert's output."
  [ "$(getenv ETCD_CLIENT_SCHEME)" = "https" ] || step_fail "ETCD_CLIENT_SCHEME is not https in .env" \
    "--prepare sets it; without it the ring would form plaintext and no member would match." \
    "Cure: re-run  ./taranac cluster init."
  local witness_name="" leaf=""
  for i in "${!node_roles[@]}"; do
    [ "${node_roles[$i]}" = "witness" ] && witness_name="${node_names[$i]}"
  done
  leaf="${SECRETS_DIR}/etcd/${witness_name}"
  [ -s "${leaf}/etcd-server.crt" ] || step_fail \
    "no pre-issued etcd leaf for the witness '${witness_name}' (${leaf}/etcd-server.crt)" \
    "--prepare issues one leaf per member of ETCD_INITIAL_CLUSTER. A witness with no leaf" \
    "cannot join an https ring, and the convert would then have nothing to reach quorum with." \
    "Cure: confirm the witness is named in the ring, then re-run init:" \
    "  grep '^ETCD_INITIAL_CLUSTER=' .env"
  ok "CA, this node's leaf, and a leaf for every declared member are in place"

  hdr "init is complete — and the conversion is deliberately NOT."
  printf '%s\n' \
    "" \
    "  The database is still standalone and still serving. Nothing failed: securing etcd" \
    "  is a chicken-and-egg, and this is the half that can be done alone." \
    "" \
    "  The witness must be a LIVE etcd member before the conversion can prune the ring —" \
    "  otherwise this node would strand as a 1-member cluster the witness could never" \
    "  join. But the witness needs a certificate signed by the CA that was created only" \
    "  a moment ago. So the next command carries the witness its identity, brings it up," \
    "  and only then converts this node:" \
    "" \
    "      ./taranac cluster add-witness --address ${witness:-<witness address>}" \
    "" \
    "  Until then, do NOT run './taranac up -d' on this node: .env now declares the" \
    "  cluster, so the tooling would start the HA overlay on a node that has not been" \
    "  converted yet." \
    ""
}

# =============================================================================
# add-witness
# =============================================================================
cmd_add_witness() {
  local address="" name="" port=9443 timeout=1800
  REINSTALL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --address)  address="${2:-}"; shift 2 ;;
      --name)     name="${2:-}"; shift 2 ;;
      --port)     port="${2:-}"; shift 2 ;;
      --timeout)  timeout="${2:-}"; shift 2 ;;
      --reinstall) REINSTALL=1; shift ;;
      --wait-seconds) WAIT_SECONDS="${2:-}"; shift 2 ;;
      --yes|-y)   ASSUME_YES=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) fail "unknown option '$1' for 'cluster add-witness'." "Run  ./taranac cluster add-witness --help." ;;
    esac
  done
  [ -n "${address}" ] || fail \
    "missing --address for 'cluster add-witness'." \
    "Give the witness host's routable address — a SEPARATE failure domain from the DB nodes:" \
    "  ./taranac cluster add-witness --address 10.0.0.3"

  require_bundle
  require_seed
  steps 7

  local converted=""; [ "$(getenv TARANAC_HA)" = "1" ] && converted=1

  # ── 1 ──────────────────────────────────────────────────────────────────────
  step "recording the witness in config/cluster.yml"
  NODE_NAME=""; NODE_ROLE=""
  local -a name_opt=(); [ -n "${name}" ] && name_opt=(--name "${name}")
  record_in_manifest add-witness "${address}" ${name_opt[@]+"${name_opt[@]}"}
  local witness_name="${NODE_NAME}"

  # ── 2 ──────────────────────────────────────────────────────────────────────
  step "checking that init has produced everything the witness needs"
  [ -s "${CA_DIR}/ca.crt" ] || step_fail "no etcd CA at config/etcd-ca/ca.crt" \
    "The witness's certificate is signed by it, so there is nothing to join with." \
    "Cure:  ./taranac cluster init"
  case ",$(getenv ETCD_INITIAL_CLUSTER)," in
    *"=https://${address}:2380,"*) ok "the witness is named in the declared etcd ring" ;;
    *)
      # 🔑 The manifest is the declaration; ETCD_INITIAL_CLUSTER is this node's copy of
      # it. When the manifest DOES name this address and the .env does not, the two have
      # simply drifted — an eviction pruned the .env, or an earlier attempt left it half
      # written — and the fix is to restore the line, not to re-declare the cluster.
      #
      # Sending an operator to `init --force` here was actively dangerous: init is the
      # standalone-to-seed conversion, refuses on a node already marked TARANAC_HA=1, and
      # recreates the manifest, DISCARDING the operator's skip: entries. It answered a
      # bookkeeping mismatch with "start the cluster over". Seen on the stand.
      if cm get --address "${address}" >/dev/null 2>&1; then
        local declared_name; declared_name="$(cm get --address "${address}" 2>/dev/null | sed -n "s/^CM_NAME=//p" | tr -d "'")"
        info "the manifest declares ${address} but this node's .env does not — restoring it"
        local ring; ring="$(getenv ETCD_INITIAL_CLUSTER)"
        setenv ETCD_INITIAL_CLUSTER "${ring:+${ring},}${declared_name:-witness}=https://${address}:2380"
        local ehosts; ehosts="$(getenv ETCD_HOSTS)"
        case ",${ehosts}," in
          *",${address}:2379,"*) : ;;
          *) setenv ETCD_HOSTS "${ehosts:+${ehosts},}${address}:2379" ;;
        esac
        ok "the witness is named in the declared etcd ring"
      else
        step_fail "${address} is in neither the declared etcd ring nor config/cluster.yml" \
          "Nothing on this node knows about that address, so there is nothing to add it as." \
          "Cure — declare it first, then run this command again:" \
          "  ./cluster-manifest.py add-witness --address ${address}"
      fi
      ;;
  esac

  # ── 3 ──────────────────────────────────────────────────────────────────────
  step "checking whether ${witness_name} is already a live etcd member"
  local already=""
  if etcd_running && etcd_members | grep -qF -- "//${address}:2380"; then
    already=1
    ok "${witness_name} is already a member of the ring — the broker will re-issue only what it asks for"
  else
    ok "not a member yet (expected: on a first run this node's etcd is not even running)"
  fi

  # ── Bootstrap the ring at THREE declared members ─────────────────────────
  # 🔑 Three, not "all" and not "the two that are up" — both extremes fail, in
  # opposite ways, and this is the only size that works:
  #
  #   all declared (4+)  etcd elects a leader by a MAJORITY OF THE DECLARED members.
  #                      At convert time exactly two machines exist — this seed and
  #                      the witness — and 2 of 4 is not a majority, so both sit
  #                      exchanging pre-votes forever and the convert hangs with
  #                      nothing wrong on either box.
  #   only the two up    ha-convert refuses a declared ring under three: a two-member
  #                      ring cannot survive losing either member, so a cluster that
  #                      ended up that way would have no failover at all.
  #   THREE              2 of 3 IS a majority → the ring forms with seed + witness,
  #                      and ha-convert then prunes the third (not-yet-started) member
  #                      itself. Each remaining node re-adds itself to the LIVE ring
  #                      when it joins. This is the shape the convert was built for.
  #
  # Nothing is lost by trimming: `--prepare` has already issued a certificate to every
  # declared member, and the manifest keeps the operator's full declaration.
  local full_ring seed_addr keep_two rest trimmed
  full_ring="$(getenv ETCD_INITIAL_CLUSTER)"
  seed_addr="$(getenv NODE_ADDRESS)"
  keep_two="$(printf '%s' "${full_ring}" | tr ',' '\n' \
               | grep -E "=https?://(${seed_addr}|${address}):2380$" | paste -sd, -)"
  rest="$(printf '%s' "${full_ring}" | tr ',' '\n' \
           | grep -vE "=https?://(${seed_addr}|${address}):2380$" | head -1)"
  trimmed="${keep_two}${rest:+,${rest}}"
  if [ -n "${keep_two}" ] && [ -n "${rest}" ] && [ "${trimmed}" != "${full_ring}" ]; then
    setenv ETCD_INITIAL_CLUSTER "${trimmed}"
    info "bootstrapping the ring at three declared members (this node, the witness and"
    info "one more) — etcd needs a MAJORITY of the DECLARED members to elect a leader,"
    info "and only two machines exist yet. The rest join the live ring as they are added."
  fi

  # ── 4 ──────────────────────────────────────────────────────────────────────
  step "opening the one-shot join channel for ${witness_name} (${address})"
  [ -f "${BROKER}" ] || step_fail "cluster-broker.py is missing from the bundle" \
    "Cure: refresh the bundle once and retry:  ./taranac update"
  # A LOCAL one-shot secret, deliberately NOT './taranac cluster join-token'. A join
  # token is a roster-and-licence artifact for a Taranac NODE: outstanding tokens
  # count against max_nodes, and the token is only cleared when the joining node
  # calls `cluster register`. A witness runs etcd alone — no api, no roster row,
  # nothing to redeem with — so a join token issued here would sit pending forever
  # and permanently consume one licensed node slot.
  need_cmd openssl
  local token; token="$(openssl rand -hex 24)"
  [ -n "${token}" ] || step_fail "could not generate the channel secret" \
    "Cure: check that openssl works on this host:  openssl rand -hex 24"
  info "the broker prints the exact command to run on the witness host, with its own"
  info "certificate fingerprint — compare it there before pasting."
  python3 "${BROKER}" --token "${token}" --node-name "${witness_name}" \
      --node-address "${address}" --role witness --port "${port}" --timeout "${timeout}" \
      --env-file "${ENV_FILE}" --wizard || step_fail \
    "${witness_name} did not complete its side of the join" \
    "Nothing was changed on this node, and the channel is closed. A fresh secret is" \
    "issued every time, so simply run the command again once the cause is fixed:" \
    "  ./taranac cluster add-witness --address ${address}"
  ok "${witness_name} reported a completed join"

  # ── 5 ──────────────────────────────────────────────────────────────────────
  if [ -n "${converted}" ]; then
    step "skipping the conversion — this node is already an HA node"
    ok "TARANAC_HA=1: the cluster exists, so the witness joins the running ring instead"
  else
    step "converting this node into the cluster's primary (ha-convert.sh --continue)"
    info "this is the half that could not run before: the witness is up, so the ring can"
    info "form quorum, drop the members that have not started yet, and promote this node."
    TARANAC_WIZARD=1 bash "${CONVERT}" --continue || step_fail \
      "ha-convert.sh --continue did not complete" \
      "This node is NOT marked converted, so the operation stays retryable — read the" \
      "message above, fix the cause, and run the same command again:" \
      "  ./taranac cluster add-witness --address ${address}"
    ok "ha-convert reported a completed conversion"
  fi

  # ── 6 ──────────────────────────────────────────────────────────────────────
  step "verifying that this node is the cluster's primary"
  wait_until "${WAIT_SECONDS}" is_local_primary || step_fail \
    "this node did not report itself as the primary within ${WAIT_SECONDS}s" \
    "'not pg_is_in_recovery()' is the only answer that proves it — a running container is not." \
    "Cure: the usual cause is that etcd has no quorum. Check both:" \
    "  docker exec taranac-etcd etcdctl endpoint health --cluster" \
    "  ./taranac logs --tail 80 postgres"
  ok "the local Postgres reports it is the primary (not in recovery)"

  # ── 7 ──────────────────────────────────────────────────────────────────────
  step "verifying that ${witness_name} is a VOTING member of the etcd ring"
  wait_until "${WAIT_SECONDS}" is_voting_member "${address}" || step_fail \
    "${witness_name} (${address}) is not a voting member of the ring after ${WAIT_SECONDS}s" \
    "A member that is present but not voting (a learner) or absent altogether does not count" \
    "toward quorum, so the cluster would still be one failure away from being unable to" \
    "elect a leader — which is the entire reason the witness exists." \
    "Cure: inspect the ring and the witness's own etcd:" \
    "  docker exec taranac-etcd etcdctl member list -w table" \
    "  on the witness:  docker compose -f docker-compose.witness.yml logs --tail 80"
  local members voting client_url
  members="$(etcd_members)"
  voting="$(printf '%s\n' "${members}" | grep -cv "$(printf '\ttrue')$")"
  client_url="$(printf '%s\n' "${members}" | grep -F -- "//${address}:2380" | cut -f3)"
  [ -n "${client_url}" ] || step_fail \
    "${witness_name} is in the ring but has never advertised a client URL" \
    "etcd shows that as an 'unstarted' member: it is declared, not running. A convert that" \
    "pruned around it would leave this node a 1-member cluster the witness could never join." \
    "Cure: start the witness and re-run:" \
    "  on the witness:  docker compose --env-file .env -f docker-compose.witness.yml up -d"
  ok "${witness_name} is a live voting member (client URL ${client_url}); the ring has ${voting} voter(s)"

  hdr "The cluster is up: one primary and a witness arbiter."
  printf '%s\n' \
    "" \
    "  Add each remaining Taranac node — one command per node, from HERE:" \
    "" \
    "      ./taranac cluster add-node --address <that node's address>" \
    "" \
    "  Each one runs a preflight against every existing member first, so a node is never" \
    "  added to a cluster that does not already agree with itself." \
    ""
}

# =============================================================================
# add-node
# =============================================================================
cmd_add_node() {
  local address="" name="" port=9443 timeout=1800 ttl=60
  REINSTALL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --address)      address="${2:-}"; shift 2 ;;
      --name)         name="${2:-}"; shift 2 ;;
      --port)         port="${2:-}"; shift 2 ;;
      --timeout)      timeout="${2:-}"; shift 2 ;;
      --ttl-minutes)  ttl="${2:-}"; shift 2 ;;
      --reinstall)    REINSTALL=1; shift ;;
      --wait-seconds) WAIT_SECONDS="${2:-}"; shift 2 ;;
      --yes|-y)       ASSUME_YES=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) fail "unknown option '$1' for 'cluster add-node'." "Run  ./taranac cluster add-node --help." ;;
    esac
  done
  [ -n "${address}" ] || fail \
    "missing --address for 'cluster add-node'." \
    "Give the address the OTHER nodes route to — it becomes this node's DB_HOSTS entry," \
    "its etcd member URL and the SAN of its certificate:" \
    "  ./taranac cluster add-node --address 10.0.0.2"

  require_bundle
  # Converted BEFORE seed, deliberately: on a node that never ran init both are
  # true, and "there is no cluster yet, here is the order" is the answer that
  # actually helps. "This node holds no CA" is the right answer only for someone
  # who does have a cluster and is standing on the wrong node.
  require_converted
  require_seed
  steps 9

  # ── 1 ──────────────────────────────────────────────────────────────────────
  step "validating the address and this node's ability to grow the cluster"
  valid_address "${address}" || step_fail "'${address}' is not a usable node address" \
    "Give a bare IP or DNS name — no scheme, no port, no path (the tooling appends 5432," \
    "2379 and 2380 itself).  e.g. --address 10.0.0.2"
  etcd_running || step_fail "the local etcd container is not running" \
    "Growing the cluster means admitting a new member to the ring, and the ring cannot be" \
    "read — let alone changed — from here without it." \
    "Cure:  ./taranac up -d etcd  then  ./taranac cluster status"
  # BEFORE the sweeps, not with the recording step — both sweeps read the manifest
  # to decide what is a leftover, and on a node that has none they would see "nothing
  # is declared" and strip every declaration out of this node's .env. Restoring the
  # cluster's copy first is what makes those sweeps answer the question they mean.
  ensure_manifest
  # Both sweeps, called from HERE rather than one from inside the other: the first
  # returns early when there is nothing marked pending, which silently skipped the
  # second. Two independent leftovers, two independent sweeps.
  prune_unfinished_adds "${address}"
  prune_orphan_declarations "${address}"
  ok "address accepted; the local etcd answers"

  # ── 2 ──────────────────────────────────────────────────────────────────────
  step "asking the cluster whether ${address} is already a member"
  local membership; membership="$(address_in_cluster "${address}")"
  case "${membership}" in
    yes) ok "it IS a member (the manifest step will tell you what that means)" ;;
    no)  ok "it is not a member of the etcd ring nor of the node roster" ;;
    unknown) : ;;   # record_in_manifest turns this into a named stop
  esac

  # ── 3 ──────────────────────────────────────────────────────────────────────
  step "recording ${address} in config/cluster.yml"
  NODE_NAME=""; NODE_ROLE=""
  local -a name_opt=(); [ -n "${name}" ] && name_opt=(--name "${name}")
  record_in_manifest add-node "${address}" --pending ${name_opt[@]+"${name_opt[@]}"}
  local node_name="${NODE_NAME}"

  # ── 4 ──────────────────────────────────────────────────────────────────────
  step "preflight — consulting every existing member before the cluster grows"
  preflight "${address}" || step_fail \
    "the cluster does not agree with itself, so it is not grown" \
    "Every finding above names the node, the value and the command that cures it. Fix them" \
    "on the nodes they name, then run the same command again:" \
    "  ./taranac cluster add-node --address ${address}"
  ok "preflight passed"

  # ── 5 ──────────────────────────────────────────────────────────────────────
  step "making sure this node's declared topology names ${node_name}"
  # The broker serves the joining machine the values out of THIS node's .env. If
  # the ring/host lists here do not name the new node, it would be handed a
  # cluster description that does not include itself. We only ever write OUR OWN
  # .env — a live member's configuration is never touched (that is the preflight's
  # whole discipline) — and we say out loud that the running containers still hold
  # the previous value until they are recreated.
  local changed=""
  local ic; ic="$(getenv ETCD_INITIAL_CLUSTER)"
  case ",${ic}," in
    *"=https://${address}:2380,"*) : ;;
    *) setenv ETCD_INITIAL_CLUSTER "${ic:+${ic},}${node_name}=https://${address}:2380"; changed=1 ;;
  esac
  local eh; eh="$(getenv ETCD_HOSTS)"
  case ",${eh}," in
    *",${address}:2379,"*) : ;;
    *) setenv ETCD_HOSTS "${eh:+${eh},}${address}:2379"; changed=1 ;;
  esac
  local dh; dh="$(getenv DB_HOSTS)"
  case ",${dh}," in
    *",${address}:5432,"*) : ;;
    *) setenv DB_HOSTS "${dh:+${dh},}${address}:5432"; changed=1 ;;
  esac
  if [ -n "${changed}" ]; then
    warn "this node was not declared at init, so .env has been extended to name it"
    info "the joining node reads these values from the broker, so it now gets a correct list."
    info "THIS node's containers still carry the previous value until they are recreated —"
    info "preflight will report that difference until you run, at your convenience:"
    info "  ./taranac up -d"
  else
    ok "already declared in ETCD_INITIAL_CLUSTER, ETCD_HOSTS and DB_HOSTS — nothing to change"
  fi

  # ── 6 ──────────────────────────────────────────────────────────────────────
  step "issuing a join token for ${node_name}"
  # A real, license-gated token this time: a Taranac node DOES register a roster
  # row, and the token is the product's only hard enforcement point for growth.
  #
  # 🔑 First clear THIS address's own leftovers. An outstanding pending token
  # reserves a licensed slot (membership.py counts active nodes PLUS pending tokens
  # against max_nodes, so N tokens cannot over-subscribe one free slot). An add that
  # was interrupted after the token was issued therefore leaves a slot consumed by a
  # token nobody will ever redeem, and the retry is refused with "already at its
  # licensed node limit (2)" while `cluster status` cheerfully reports "1 node / max
  # 2". Both are true and the operator cannot reconcile them, because what consumes
  # the second slot is invisible. Found exactly that way on the stand.
  #
  # Only tokens for the SAME address are dropped: another node's pending token is
  # someone else's join in flight, and stealing its slot would break that one to fix
  # this one. Retry-after-interruption is safe by construction, the same property the
  # manifest's RESUME case gives, applied to the token.
  local stale_ids
  stale_ids="$(psql_q "select id from cluster_join_tokens
                            where node_address = '${address}'
                              and status = 'pending'
                              and expires_at > now();" 2>/dev/null || true)"
  if [ -n "${stale_ids}" ]; then
    local sid
    while IFS= read -r sid; do
      [ -n "${sid}" ] || continue
      if "${WRAPPER}" cluster revoke --id "${sid}" >/dev/null 2>&1; then
        info "revoked a leftover pending token for ${address} (an earlier add did not finish)"
      else
        info "could not revoke a leftover pending token ${sid} — it holds a licensed slot until it expires"
      fi
    done <<EOF
${stale_ids}
EOF
  fi
  local tok_out rc
  tok_out="$("${WRAPPER}" cluster join-token --name "${node_name}" --address "${address}" \
              --ttl-minutes "${ttl}" 2>&1)"; rc=$?
  [ ${rc} -eq 0 ] || step_fail "the cluster refused to issue a join token" \
    "${tok_out}" \
    "Cure: growth is license-gated. Check the edition and the node cap:" \
    "  ./taranac cluster status"
  local token; token="$(printf '%s\n' "${tok_out}" | awk '/^[[:space:]]*token:[[:space:]]/ {print $2; exit}')"
  [ -n "${token}" ] || step_fail "a join token was issued but could not be read from the output" \
    "${tok_out}" \
    "Cure: issue one by hand and pass it to the joining node yourself:" \
    "  ./taranac cluster join-token --name ${node_name} --address ${address}"
  ok "a single-use join token was issued (it is shown once, inside the command below)"

  # ── 7 ──────────────────────────────────────────────────────────────────────
  step "opening the one-shot join channel for ${node_name} (${address})"
  [ -f "${BROKER}" ] || step_fail "cluster-broker.py is missing from the bundle" \
    "Cure: refresh the bundle once and retry:  ./taranac update"
  info "the broker prints the exact command to run on ${address}, with its own certificate"
  info "fingerprint — compare it there before pasting; it is not trust-on-first-use."
  python3 "${BROKER}" --token "${token}" --node-name "${node_name}" \
      --node-address "${address}" --role replica --port "${port}" --timeout "${timeout}" \
      --env-file "${ENV_FILE}" --wizard || step_fail \
    "${node_name} did not complete its side of the join" \
    "Nothing was changed on this cluster and the channel is closed. Revoke the unused token" \
    "if you are not retrying immediately, then run the command again — a fresh token is" \
    "issued every time:" \
    "  ./taranac cluster add-node --address ${address}"
  ok "${node_name} reported a completed join"

  # ── 8 ──────────────────────────────────────────────────────────────────────
  step "verifying that ${node_name} became a voting etcd member"
  wait_until "${WAIT_SECONDS}" is_voting_member "${address}" || step_fail \
    "${node_name} (${address}) is not a voting member of the etcd ring after ${WAIT_SECONDS}s" \
    "Cure: inspect the ring here and etcd on the joining node:" \
    "  docker exec taranac-etcd etcdctl member list -w table" \
    "  on ${address}:  ./taranac logs --tail 80 etcd"
  ok "${node_name} is in the ring and votes"

  # ── 9 ──────────────────────────────────────────────────────────────────────
  step "verifying that ${node_name} is really streaming from this primary"
  # The observable proof of a joined node is REPLICATION, not a running container
  # and not a roster row: a cluster that looks healthy while one node cannot follow
  # a failover is worse than one that failed loudly, because nobody finds out until
  # the failover.
  local streaming="" roster=""
  # Asked of PATRONI, not of the local pg_stat_replication: this command may well be
  # running on a replica (leadership moves, and after a failover it usually has), and
  # a replica's pg_stat_replication is empty by definition — which reads exactly like
  # "the new node is not replicating". Seen on the stand: a join that had demonstrably
  # started streaming was reported as failed because the wizard asked the wrong node.
  wait_until "${WAIT_SECONDS}" patroni_member_replicating "${node_name}"
  streaming="$(patroni_member_state "${node_name}")"
  if patroni_member_replicating "${node_name}"; then
    ok "Patroni reports ${node_name} as a replica in state '${streaming}'"
  else
    step_fail "${node_name} is not replicating after ${WAIT_SECONDS}s (Patroni state: '${streaming:-unknown}')" \
        "The node joined the ring but is not replicating, so it could not take over. The usual" \
        "causes are a PG_ALLOW_CIDR that does not reach it (pg_hba refuses the replicator" \
        "login AFTER the handshake, so nothing looks broken) or a still-running clone." \
        "Cure: watch it from both ends:" \
        "  docker exec taranac-db psql -U taranac -d taranac -c 'select * from pg_stat_replication'" \
        "  on ${address}:  ./taranac logs --tail 80 postgres"
  fi
  roster="$(psql_q "SELECT name FROM cluster_nodes WHERE status = 'active' AND address = '${address}'")"
  if [ -n "${roster}" ]; then
    ok "the node registered its roster row as '${roster}'"
    # The add is confirmed finished, so the entry is no longer an attempt in flight —
    # clear the mark, or the NEXT add would treat this healthy node as a leftover.
    # That clears a line from the file, so the cluster's copy has to learn about it
    # too — otherwise the node that materialises the published copy inherits a
    # `pending` mark for an add that finished long ago, and sweeps it as a leftover.
    cm mark-joined --address "${address}" >/dev/null 2>&1 || true
    publish_manifest || true
  else
    warn "no active roster row for ${address} yet — the node redeems its token a moment after the clone"
    info "check it with:  ./taranac cluster status"
  fi

  hdr "${node_name} (${address}) is part of the cluster."
  printf '%s\n' \
    "" \
    "  Confirm the whole picture, including replication lag:" \
    "      ./taranac cluster status" \
    ""
}

# =============================================================================
usage() {
  cat <<'USAGE'
cluster-wizard.sh — the primary-side commands of the Taranac HA setup wizard.
Reached through the bundle wrapper:  ./taranac cluster <command>

  init          Declare the cluster on this node and prepare the conversion.
                --cluster NAME        cluster name (identical on every node)
                --address ADDR        THIS node's routable address
                --name NAME           this node's cluster name (default <cluster>-node-1)
                --witness ADDR[=NAME] the 3rd etcd arbiter, on a separate host
                --node ADDR[=NAME]    another Taranac node (repeatable)
                --pg-allow-cidr LIST  pg_hba scope (default: the /24 of each address)
                --force               recreate config/cluster.yml (DISCARDS skip:)
                --yes                 non-interactive; every value must be given

                A name is chosen HERE or not at all: there is no rename, because the
                name is written into the etcd ring, the certificates and every node's
                .env — changing it later means rebuilding that machine. Omit =NAME and
                one is derived (<cluster>-node-N).

                Every command this tooling PRINTS is run through its own parser by
                tests/test_cures_are_executable.sh, so the example is one line:

                  ./taranac cluster init --witness 10.0.0.3=acsw-kan-01 --node 10.0.0.2=acs-nek-01

  add-witness   Bring the witness up and complete the conversion.
                --address ADDR        the witness host (required)
                --name NAME           its etcd member name (default from the manifest)
                --port N              broker port (default 9443)
                --timeout N           seconds to wait for the join (default 1800)
                --wait-seconds N      budget for each post-join check (default 120)

  add-node      Grow the cluster by one Taranac node.
                --address ADDR        the joining node (required)
                --name NAME           its cluster name (default derived by position)
                --port N              broker port (default 9443)
                --timeout N           seconds to wait for the join (default 1800)
                --ttl-minutes N       join-token lifetime (default 60)
                --wait-seconds N      budget for each post-join check (default 120)
                --reinstall           the node is ALREADY a member: evict it and add
                                      it again from scratch. Use after a node was
                                      rebuilt, replaced or died. Refused for the
                                      current leader (switch over first); on a node
                                      that is still streaming it must be explicit,
                                      because the cluster loses a replica until the
                                      re-clone finishes.

  sync          Bring THIS node up to date with the cluster (run it on a node the
                preflight reported stale). Reconciles config/cluster.yml with the
                copy the cluster publishes — offering to take the cluster's copy,
                after backing yours up — and then DB_HOSTS / ETCD_HOSTS in .env.
                --yes                 non-interactive; answers yes to both

The cluster manifest travels with the cluster, not with one machine: every write
to config/cluster.yml is published into the replicated settings store, and a node
that has no copy restores it from there. So add-node / add-witness work on any
node that holds the primary role, not only on the one that ran init. When the two
copies disagree the wizard STOPS and names both — it never picks one for you,
because that file carries your hand-written skip: section.
  ./taranac cluster manifest-publish < config/cluster.yml   # this node's is right
  ./taranac cluster sync                                    # the cluster's is right

The order is mandatory and enforced by the mechanism, not by this script:
  ./taranac cluster init
  ./taranac cluster add-witness --address <witness>
  ./taranac cluster add-node    --address <node>          (once per node)

The operator runbook is HA.md, in this bundle.
USAGE
}


# =============================================================================
# sync — bring THIS node's topology up to date with the primary's
# =============================================================================
# Adding a node makes every node that joined earlier out of date, by construction.
# The wizard deliberately never writes a live member's .env from the primary — a
# surprise write during someone else's join is the worst possible moment — so the
# update has to be an action taken ON the node, by the operator, when they choose.
# That is this command.
#
# 🔑 The reference is read from the REPLICATED heartbeat, not fetched over a new
# channel: every node already publishes its own topology into node_config_reports
# (service_health.py), the write routes to the primary and replicates back here. So
# this node can read what the primary says about itself out of its OWN database —
# no port, no token, no second protocol, and it works from any member.
# The manifest half of sync, and the only place in the wizard that may REPLACE
# this node's config/cluster.yml. `sync` is the command whose whole meaning is
# "pull the cluster's truth onto THIS node", so it is the one gesture where taking
# the cluster's copy is what the operator asked for — which is why every other
# path prints `./taranac cluster sync` as its cure instead of doing it.
#
# It still never destroys anything: the file is copied aside first, and the
# operator is asked, because `skip:` entries are hand-written and their reasons
# were written for a future self. A refusal is not a failure — the topology sync
# below is the command's main job and continues regardless.
sync_manifest() {
  local work published rc backup reply=""
  work="$(mktemp -d)"; published="${work}/published.yml"
  fetch_published_manifest "${published}"; rc=$?

  if [ ${rc} -ne 0 ] && [ ${rc} -ne "${MANIFEST_ABSENT_RC}" ]; then
    warn "the cluster's published manifest could not be read — leaving config/cluster.yml alone"
    indent_block "$(cat "${published}.err" 2>/dev/null || echo 'the api container did not answer')"
    info "Cure:  ./taranac ps"
    rm -rf "${work}"; return 0
  fi

  if [ ! -f "${MANIFEST}" ]; then
    if [ ${rc} -eq "${MANIFEST_ABSENT_RC}" ]; then
      warn "this node has no config/cluster.yml and the cluster has never published one"
      info "Nothing can be restored. On the node that holds the file, publish it once:"
      info "  ./taranac cluster manifest-publish < config/cluster.yml"
      rm -rf "${work}"; return 0
    fi
    local vout
    if ! vout="$(python3 "${CM}" validate --file "${published}" 2>&1)"; then
      warn "the manifest published by this cluster does not parse — not installing it"
      indent_block "${vout}"
      rm -rf "${work}"; return 0
    fi
    mkdir -p "${HERE}/config"
    mv -f "${published}" "${MANIFEST}" || { warn "could not write ${MANIFEST}"; rm -rf "${work}"; return 0; }
    ok "config/cluster.yml was missing here — restored from the cluster's published copy"
    rm -rf "${work}"; return 0
  fi

  if [ ${rc} -eq "${MANIFEST_ABSENT_RC}" ]; then
    info "this cluster has never published its manifest — publishing this node's copy"
    publish_manifest
    rm -rf "${work}"; return 0
  fi

  if cmp -s "${MANIFEST}" "${published}"; then
    ok "config/cluster.yml already matches the copy published by the cluster"
    rm -rf "${work}"; return 0
  fi

  printf '\n'
  warn "this node's config/cluster.yml differs from the copy published by the cluster:"
  describe_manifest_difference "${published}" || { rm -rf "${work}"; return 0; }
  printf '\n'

  if [ -n "${ASSUME_YES}" ]; then
    reply=y
  elif [ ! -t 0 ]; then
    reply=n
  else
    read -r -p "   Replace this node's config/cluster.yml with the cluster's copy? [y/N]: " reply
  fi
  case "${reply}" in
    [yY]|[yY][eE][sS])
      backup="${MANIFEST}.$(date +%Y%m%d-%H%M%S).bak"
      cp -p "${MANIFEST}" "${backup}" || { warn "could not back up ${MANIFEST} — nothing replaced"; rm -rf "${work}"; return 0; }
      mv -f "${published}" "${MANIFEST}" || { warn "could not write ${MANIFEST} — the backup is at ${backup}"; rm -rf "${work}"; return 0; }
      ok "config/cluster.yml replaced with the cluster's copy"
      info "your previous file is kept at $(basename "${backup}") — nothing was deleted"
      ;;
    *)
      warn "left config/cluster.yml as it is"
      info "If THIS node's file is the right one, publish it so every node agrees:"
      info "  ./taranac cluster manifest-publish < config/cluster.yml"
      ;;
  esac
  rm -rf "${work}"
  return 0
}

cmd_sync() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)  ASSUME_YES=1; shift ;;   # the GLOBAL confirm() reads, not a local
      -h|--help) usage; exit 0 ;;
      *) fail "unknown option '$1' for 'cluster sync'." "It takes only --yes." ;;
    esac
  done
  require_converted
  STEP_TOTAL=5; STEP_NO=0

  step "reconciling config/cluster.yml with the copy the cluster publishes"
  sync_manifest

  # 🔑 The reference is DERIVED, never copied from a peer's .env.
  #
  # "Take the values from the primary" is wrong, and wrong in a way that destroys
  # information: leadership moves. A node that joined early, never learned about a
  # later member, and then won a failover would become the reference and propagate
  # its SHORTER list — every peer would forget a node that really exists. Seen
  # exactly that way on the stand: the ex-primary knew about node-6, the new primary
  # did not, and syncing "from the primary" would have deleted it.
  #
  # So build the truth from sources that are authoritative by construction and the
  # same on every node:
  #   DB_HOSTS    ← cluster_nodes, the replicated roster of nodes that actually
  #                 completed a join. Every member reads the identical table.
  #   ETCD_HOSTS  ← the LIVE etcd ring. It is the ring itself talking, it includes
  #                 the witness (which has no roster row), and Raft keeps it current.
  # Neither can be stale on one node and fresh on another, so there is no reference
  # to choose and no direction to get backwards.

  step "reading the cluster's own record of who is in it"
  local roster; roster="$(psql_q "SELECT address FROM cluster_nodes
                                   WHERE status = 'active' AND address IS NOT NULL
                                   ORDER BY address")"
  [ -n "${roster}" ] || step_fail "the node roster came back empty" \
    "This node's database did not answer, so there is nothing authoritative to build from." \
    "Cure: check it is up, then retry:" \
    "  ./taranac ps" \
    "  ./taranac cluster status"
  local want_db; want_db="$(printf '%s\n' "${roster}" | sed 's/$/:5432/' | paste -sd, -)"
  ok "$(printf '%s\n' "${roster}" | grep -c .) node(s) in the roster"

  step "reading the live etcd ring (it knows the witness too)"
  # Field 3 is clientURLs (name<TAB>peerURLs<TAB>clientURLs<TAB>isLearner), and a
  # member can advertise several — take them all, strip the scheme, keep host:port.
  local ring; ring="$(etcd_members 2>/dev/null | cut -f3 | tr ',' '\n' \
                       | sed -e 's|.*//||' -e 's/[[:space:]]//g' | grep -E '^[^:]+:[0-9]+$' | sort -u || true)"
  local want_etcd=""
  [ -n "${ring}" ] && want_etcd="$(printf '%s\n' "${ring}" | paste -sd, -)"
  if [ -n "${want_etcd}" ]; then
    ok "$(printf '%s\n' "${ring}" | grep -c .) etcd member(s) answering"
  else
    warn "the ring did not answer — ETCD_HOSTS will be left as it is"
  fi

  # ── The DECLARED ring, rebuilt from the live one ─────────────────────────────
  # ETCD_INITIAL_CLUSTER used to be left out of this command, and this command is
  # what the preflight prints as the cure for that key drifting. So an operator
  # was told to run a fix that reported "already matches what the cluster
  # reports" while the value it was prescribed for sat untouched — the failure
  # mode the TARANAC_HA note above was written about, one key further along.
  #
  # It is not cosmetic drift. A member's etcd reads this list when it starts on
  # an EMPTY data directory, and `add-node` hands it to the JOINING node as-is.
  # etcd then compares it with the live ring and refuses on any difference
  # ("member count is unequal"), so a node whose list is stale cannot add a node
  # and a node that is rebuilt cannot come back.
  #
  # Built from name + peerURL (fields 1 and 2), which is exactly the form etcd
  # validates, and only when the ring answered in full — a partial ring would
  # write a SHORTER list than the truth, which is the very fault being repaired.
  local want_ring="" ring_rows
  ring_rows="$(etcd_members 2>/dev/null || true)"
  if [ -n "${ring_rows}" ] && ! printf '%s\n' "${ring_rows}" | awk -F'\t' '{ if ($1 == "" || $2 == "") exit 0 } END { exit 1 }'; then
    want_ring="$(printf '%s\n' "${ring_rows}" | awk -F'\t' '{split($2, u, ","); print $1 "=" u[1]}' | paste -sd, -)"
  elif [ -n "${ring_rows}" ]; then
    warn "a ring member has no name or peer URL yet — ETCD_INITIAL_CLUSTER will be left as it is"
  fi

  step "comparing with this node's .env"
  # TARANAC_HA is included because the preflight can flag it and this command is the
  # cure it prints — a cure that does not cover what it is prescribed for is worse
  # than none, because the operator runs it, is told "nothing to do", and is left
  # exactly where they started. On a node that is in the cluster the value is not a
  # matter of opinion: it is 1.
  local changes="" key want have
  for key in DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER TARANAC_HA; do
    case "${key}" in
      DB_HOSTS)             want="${want_db}" ;;
      ETCD_HOSTS)           want="${want_etcd}" ;;
      ETCD_INITIAL_CLUSTER) want="${want_ring}" ;;
      TARANAC_HA)           want="1" ;;
    esac
    [ -n "${want}" ] || continue
    have="$(getenv "${key}")"
    [ "${want}" = "${have}" ] && continue
    printf '\n   · %s\n       now:  %s\n       new:  %s\n' "${key}" "${have:-(unset)}" "${want}"
    changes="${changes}${key}=${want}"$'\n'
  done
  if [ -z "${changes}" ]; then
    ok "this node already matches what the cluster reports — nothing to do"
    return 0
  fi

  echo
  info "Only THIS node's .env is written; no other member is touched."
  confirm "Apply these to this node?" || fail "nothing was changed."
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    setenv "${line%%=*}" "${line#*=}"
  done <<EOF
${changes}
EOF
  ok ".env updated"

  step "recreating this node's containers so they read the new values"
  # Through the wrapper, never a bare compose call: it merges docker-compose.ha.yml
  # from the TARANAC_HA marker. A base-only start here would put a plain postgres on
  # the Patroni data directory — precisely the split-brain that guard exists for.
  "${WRAPPER}" up -d >/dev/null 2>&1 || step_fail "the stack did not come back up" \
    "The .env is updated but the containers are not. Look at what happened:" \
    "  ./taranac ps" \
    "  ./taranac logs --tail 50 api"
  ok "this node now matches the cluster"
  echo
}

case "${1:-}" in
  init)         shift; cmd_init "$@" ;;
  add-witness)  shift; cmd_add_witness "$@" ;;
  add-node)     shift; cmd_add_node "$@" ;;
  sync)         shift; cmd_sync "$@" ;;
  -h|--help|"") usage ;;
  *)
    fail "unknown command 'cluster $1'." \
      "This wizard handles: init, add-witness, add-node, sync." \
      "Everything else under 'cluster' (status, join-token, register, revoke," \
      "decommission) is handled by the api container — run  ./taranac cluster --help."
    ;;
esac
