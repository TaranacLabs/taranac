#!/usr/bin/env bash
# =============================================================================
# cluster-versions.sh — which member of an HA cluster runs which version, and
# which one `./taranac update` must touch next. Sourced by taranac-update.sh,
# never executed.
#
# WHY THIS EXISTS
#   Upgrading a cluster has one safe order — every replica, then the leader, then
#   the witness — and the updater used to learn where it stood from the heartbeat
#   table (node_config_reports). That source is written by each node's api, and
#   the api of a freshly upgraded replica is exactly what is DOWN while it waits
#   for the leader to migrate the schema. So the one window in which the question
#   mattered was the one window in which it had no answer: the replica sat for half
#   an hour, the leader then refused because the replica "never reported", and the
#   only way through was --allow-out-of-order. A guard that needs its own override
#   on the documented sequence does not work.
#
#   So the updater now writes the answer itself, into etcd, at the end of its own
#   run on each node: /taranac/update/members/<ETCD_NAME>. etcd is the one store
#   every member — the witness included — can read while any api is down, and it
#   is already the cluster's arbiter. Patroni writes only under /service/<scope>/,
#   so the /taranac/ root cannot collide with it.
#
# WHO SAYS WHAT
#   member list   etcdctl member list — the cluster, witness included.
#   kind          db | witness. From the member's own record (it said so itself),
#                 else from config/cluster.yml (the declared topology), else for
#                 THIS host from its own .env. On a witness the others are DB nodes,
#                 because a manifest admits exactly one witness. Never from the
#                 absence of a Patroni key: a DB node whose Patroni is down for a
#                 moment would turn into a witness and be updated last.
#   leader        /service/<scope>/leader — the ONLY thing read from Patroni.
#   version       the member's own record. For a member without one (a node still
#                 on 1.3.x), the heartbeat table is read as a secondary source —
#                 never written into etcd on that member's behalf: a record is a
#                 first-person statement, or it is not trustworthy.
#
# THE RECORD — a flat `key=value;…` string, because the updater has no JSON parser
# (jq is not on the appliance, python3 is not promised on a witness):
#   version=1.3.2;state=updated;role=db;node=node-1;address=10.0.0.1;at=…;hb=…;override=0
# state ∈ updating | updated | awaiting-schema | failed (then reason=…).
# update-finisher.sh writes the same shape; the two must agree. `updating` is the
# claim a run takes before it changes anything (cv_claim): no other member starts
# while it is fresh, and it is put back as it was when the run ends without a
# record of its own (a refusal, a failure, --no-restart).
# =============================================================================

# The colours, info/ok/warn/notice and env_value come from taranac-update.sh, which
# sources this file; the CV_*/M_* results are read there. A topology script that
# sources it only for the lock (cv_topology_lock) has neither, and gets these two.
type env_value >/dev/null 2>&1 || env_value() {  # $1 = env file, $2 = key
    sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null \
        | tail -1 | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
type notice >/dev/null 2>&1 || notice() { printf '%s\n' "· $*"; }
# shellcheck disable=SC2034,SC2154
CV_PREFIX="/taranac/update/members/"
# How a member's finisher proves it is alive: it rewrites hb= every minute, so three
# missed rewrites mean the process is gone (a host reboot, most likely).
CV_HB_STALE_S="${TARANAC_UPDATE_HB_STALE_S:-180}"
# The product's own notion of a recent heartbeat (service_health.STALE_AFTER_SECONDS).
CV_REPORT_STALE_S=90
CV_RETRY_SLEEP="${TARANAC_UPDATE_RETRY_SLEEP:-5}"
CV_ELECTION_WAIT_S="${TARANAC_UPDATE_ELECTION_WAIT_S:-30}"
CV_WITNESS_WAIT_S="${TARANAC_UPDATE_WITNESS_WAIT_S:-900}"
CV_POLL_S="${TARANAC_UPDATE_POLL_S:-10}"
# A run's claim (state=updating) is refreshed at every phase of the run; one older
# than this is a run that died without releasing it (a reboot, a kill -9), and no
# longer holds the others back. Generous: a pull over a slow link is one phase.
CV_UPDATING_STALE_S="${TARANAC_UPDATE_UPDATING_STALE_S:-1800}"

_cv_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now; }
_cv_epoch() { date -u +%s 2>/dev/null || echo 0; }
_cv_iso_epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

# ── What this host is ─────────────────────────────────────────────────────────
cv_init() {  # <bundle dir> <env file> <kind: db|witness>
    CV_DIR="$1"; CV_ENV="$2"; CV_SELF_KIND="$3"
    CV_SELF_NAME="$(env_value "${CV_ENV}" ETCD_NAME)"
    CV_SELF_NODE="$(env_value "${CV_ENV}" TARANAC_NODE_NAME)"
    [ -n "${CV_SELF_NODE}" ] || CV_SELF_NODE="${CV_SELF_NAME}"
    # A DB node's ETCD_NAME defaults to its node name (ha-join.sh, the wizard) and
    # an older .env may not spell it out.
    [ -n "${CV_SELF_NAME}" ] || CV_SELF_NAME="${CV_SELF_NODE}"
    CV_SELF_ADDR="$(env_value "${CV_ENV}" NODE_ADDRESS)"
    CV_SCOPE="$(env_value "${CV_ENV}" TARANAC_CLUSTER_NAME)"
    CV_OVERRIDE=0
    CV_ETCD_ERR=""
}

# ── etcdctl, from wherever it can run ────────────────────────────────────────
# The local member's container first: it already carries ETCDCTL_ENDPOINTS and the
# CA, so client TLS costs nothing. If that container is down (the node being
# repaired, a member that crashed) a one-shot container of the same image reaches
# the other members with this node's CA — the same fallback diagnose-ha.sh uses.
_cv_local_etcd() {
    local c
    for c in taranac-etcd taranac-witness-etcd; do
        if [ "$(docker inspect --format '{{.State.Running}}' "${c}" 2>/dev/null)" = "true" ]; then
            printf '%s' "${c}"; return 0
        fi
    done
    return 1
}

_cv_etcd_image() {
    local f img
    for f in "${CV_DIR}/docker-compose.ha.yml" "${CV_DIR}/docker-compose.witness.yml"; do
        [ -f "${f}" ] || continue
        img="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(quay\.io\/coreos\/etcd[^[:space:]]*\).*/\1/p' "${f}" | head -1)"
        [ -n "${img}" ] && { printf '%s' "${img}"; return 0; }
    done
    printf 'quay.io/coreos/etcd:v3.5.17'
}

_cv_etcdctl_once() {
    # stdin only for `txn` (CV_STDIN_FILE): etcdctl reads its request there. Every
    # other call gets /dev/null, so no docker exec ever attaches the operator's terminal.
    local c in="${CV_STDIN_FILE:-/dev/null}"
    local -a si=(); [ -n "${CV_STDIN_FILE:-}" ] && si=(-i)
    if c="$(_cv_local_etcd)"; then
        docker exec ${si[@]+"${si[@]}"} "${c}" etcdctl --command-timeout=5s "$@" < "${in}"
        return $?   # explicit: a bare return in a trap handler reports the status from BEFORE the trap
    fi
    local scheme hosts eps="" h cacert
    scheme="$(env_value "${CV_ENV}" ETCD_CLIENT_SCHEME)"; scheme="${scheme:-http}"
    hosts="$(env_value "${CV_ENV}" ETCD_HOSTS)"
    for h in ${hosts//,/ }; do eps="${eps:+${eps},}${scheme}://${h}"; done
    [ -n "${eps}" ] || { echo "no local etcd container, and ETCD_HOSTS is empty in .env" >&2; return 1; }
    cacert="$(env_value "${CV_ENV}" ETCD_CLIENT_CACERT)"
    local -a tls=()
    [ "${scheme}" = "https" ] && [ -n "${cacert}" ] && tls=(--cacert="${cacert}")
    docker run --rm ${si[@]+"${si[@]}"} --network host -v "${CV_DIR}/config/etcd-tls:/etc/etcd/tls:ro" \
        "$(_cv_etcd_image)" etcdctl --endpoints="${eps}" ${tls[@]+"${tls[@]}"} --command-timeout=5s "$@" < "${in}"
}

# Three tries, five seconds apart: a leader election in etcd itself, or a member
# restarting next door, is a few seconds of "context deadline exceeded" that must
# not become a refusal. Whatever still fails after that is the ring, not a blip.
#
# The answer comes back in CV_OUT (stdout) and CV_ERR (stderr), never on stdout:
# the callers branch on the outcome AND need the error text for the refusal, and a
# `$(…)` would run this in a subshell where both are lost.
cv_etcdctl() {
    local i err
    CV_OUT=""; CV_ERR=""; CV_ETCD_ERR=""
    err="$(mktemp)"
    for i in 1 2 3; do
        if CV_OUT="$(_cv_etcdctl_once "$@" 2>"${err}")"; then
            CV_ERR="$(cat "${err}")"; rm -f "${err}"
            return 0
        fi
        [ "${i}" -lt 3 ] && sleep "${CV_RETRY_SLEEP}"
    done
    CV_ERR="$(cat "${err}")"
    # etcdctl prints a JSON log line per retry and then one plain "Error: …" — the
    # plain one is the sentence worth showing.
    CV_ETCD_ERR="$(grep -v '^{' "${err}" | tail -1 || true)"
    [ -n "${CV_ETCD_ERR}" ] || CV_ETCD_ERR="$(tail -1 "${err}" || true)"
    rm -f "${err}"
    return 1
}

# ── The declared topology (config/cluster.yml) ───────────────────────────────
# "name<TAB>address<TAB>role". Parsed with awk rather than cluster-manifest.py:
# the nodes block is machine-written in one fixed shape (render_nodes_block), and
# PyYAML is not promised on every host this runs on. If this node holds no copy,
# the copy the cluster published is read straight from the local database — a
# replica's read-only Postgres answers that as well as the primary's.
_cv_manifest_awk() {
    awk '
        function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); gsub(/^"|"$/, "", s); return s }
        /^nodes:/ { inn = 1; next }
        /^[^[:space:]#-]/ { inn = 0 }
        inn && /^  - name:/ { if (n != "") print n "\t" a "\t" r; n = val($0); a = ""; r = "replica"; next }
        inn && /^    address:/ { a = val($0); next }
        inn && /^    role:/ { r = val($0); next }
        END { if (n != "") print n "\t" a "\t" r }
    '
}

CV_MANIFEST_FILE=""   # a manifest rebuilt by the updater but not published yet (ha_rebuild_manifest)
cv_manifest_rows() {
    if [ -n "${CV_MANIFEST_FILE}" ] && [ -f "${CV_MANIFEST_FILE}" ]; then
        _cv_manifest_awk < "${CV_MANIFEST_FILE}"
        return 0
    fi
    if [ -f "${CV_DIR}/config/cluster.yml" ]; then
        _cv_manifest_awk < "${CV_DIR}/config/cluster.yml"
        return 0
    fi
    [ "${CV_SELF_KIND}" = "db" ] || return 0
    docker exec taranac-db psql -U taranac -d taranac -tA -c \
        "SELECT value FROM system_settings WHERE key = 'cluster.manifest' AND entity_type IS NULL AND entity_id IS NULL AND NOT is_encrypted" \
        2>/dev/null | _cv_manifest_awk || true
}

# The heartbeat table, as "name|address|version|age_seconds" — psql's default `|`
# separator (a `-F'\t'` argument reaches psql as two characters, not a tab; that
# cost a release once). Only DB nodes have a database to ask.
cv_heartbeat_rows() {
    [ "${CV_SELF_KIND}" = "db" ] || return 0
    docker exec taranac-db psql -U taranac -d taranac -tA -c "
        SELECT n.name, COALESCE(n.address, ''),
               COALESCE(r.config_values->>'TARANAC_VERSION', ''),
               COALESCE(EXTRACT(EPOCH FROM (now() - r.updated_at))::int, -1)
          FROM cluster_nodes n
          LEFT JOIN node_config_reports r ON r.node_id = n.id
         WHERE n.status = 'active'
         ORDER BY n.name" 2>/dev/null || true
}

cv_field() {  # <record> <field>
    printf '%s' ";$1;" | sed -n "s/.*;$2=\([^;]*\);.*/\1/p"
}

# ── The plan: who is what, on which version, and who goes next ───────────────
# Fills M_* (one index per etcd member), CV_LEADER, CV_NEXT (indices) and
# CV_REFUSAL (empty, or why no plan could be made). Returns 1 on a refusal.
cv_plan() {  # <target version>
    local target="$1"
    M_NAME=(); M_ADDR=(); M_KIND=(); M_VER=(); M_STATE=(); M_SRC=(); M_HB=(); M_REASON=(); M_DONE=(); M_OVR=(); M_NODE=(); M_RAW=()
    CV_LEADER=""; CV_LEADER_IDX=""; CV_NEXT=(); CV_REFUSAL=""; CV_SELF_IDX=""

    local members
    if cv_etcdctl member list; then members="${CV_OUT}"; else
        CV_REFUSAL="quorum|the etcd ring did not answer from this node (${CV_ETCD_ERR:-no answer}) — without a quorum the update cannot be coordinated"
        return 1
    fi
    local name peers addr line i=0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        # `member list` (simple): "id, status, name, peerURLs, clientURLs, isLearner".
        IFS='|' read -r _ _ name peers _ <<<"${line//, /|}"
        addr="${peers%%,*}"; addr="${addr#*://}"; addr="${addr%:*}"; addr="${addr#[}"; addr="${addr%]}"
        [ -n "${name}" ] || name="(unstarted ${addr})"
        M_NAME[i]="${name}"; M_ADDR[i]="${addr}"; M_KIND[i]=""; M_VER[i]=""; M_STATE[i]=""
        M_SRC[i]=""; M_HB[i]=""; M_REASON[i]=""; M_DONE[i]=0; M_OVR[i]=0; M_NODE[i]="${name}"; M_RAW[i]=""
        [ "${name}" = "${CV_SELF_NAME}" ] && CV_SELF_IDX="${i}"
        i=$((i + 1))
    done <<<"${members}"
    if [ "${i}" -eq 0 ]; then
        CV_REFUSAL="quorum|the etcd ring returned no members"
        return 1
    fi

    local recs key val
    if cv_etcdctl get --prefix "${CV_PREFIX}"; then recs="${CV_OUT}"; else
        CV_REFUSAL="quorum|the etcd ring did not answer a read from this node (${CV_ETCD_ERR:-no answer}) — without a quorum the update cannot be coordinated"
        return 1
    fi
    local -A rec=()
    while IFS= read -r key && IFS= read -r val; do
        case "${key}" in "${CV_PREFIX}"*) rec["${key#"${CV_PREFIX}"}"]="${val}" ;; esac
    done <<<"${recs}"

    local manifest hb mname maddr mrole n
    manifest="$(cv_manifest_rows)"
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        val="${rec[${M_NAME[n]}]:-}"
        M_RAW[n]="${val}"
        if [ -n "${val}" ]; then
            M_VER[n]="$(cv_field "${val}" version)"; M_STATE[n]="$(cv_field "${val}" state)"
            M_KIND[n]="$(cv_field "${val}" role)"; M_HB[n]="$(cv_field "${val}" hb)"
            M_REASON[n]="$(cv_field "${val}" reason)"; M_OVR[n]="$(cv_field "${val}" override)"
            M_SRC[n]="etcd"
            local rnode; rnode="$(cv_field "${val}" node)"
            [ -n "${rnode}" ] && M_NODE[n]="${rnode}"
        fi
        if [ -z "${M_KIND[n]}" ]; then
            while IFS=$'\t' read -r mname maddr mrole; do
                [ -n "${mname}" ] || continue
                if [ "${maddr}" = "${M_ADDR[n]}" ] || [ "${mname}" = "${M_NAME[n]}" ]; then
                    case "${mrole}" in witness) M_KIND[n]=witness ;; *) M_KIND[n]=db ;; esac
                    break
                fi
            done <<<"${manifest}"
        fi
        if [ -z "${M_KIND[n]}" ] && [ "${n}" = "${CV_SELF_IDX}" ]; then M_KIND[n]="${CV_SELF_KIND}"; fi
        # A manifest admits exactly one witness; on the witness, that is this host.
        if [ -z "${M_KIND[n]}" ] && [ "${CV_SELF_KIND}" = "witness" ]; then M_KIND[n]=db; fi
    done

    # The heartbeat, for DB members that have written no record yet (1.3.x).
    hb="$(cv_heartbeat_rows)"
    local hname haddr hver hage
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        [ -z "${M_SRC[n]}" ] || continue
        while IFS='|' read -r hname haddr hver hage; do
            [ -n "${hname}" ] || continue
            if [ "${hname}" = "${M_NAME[n]}" ] || { [ -n "${haddr}" ] && [ "${haddr}" = "${M_ADDR[n]}" ]; }; then
                # Being in the cluster's node table is positive evidence of a DB node.
                [ -n "${M_KIND[n]}" ] || M_KIND[n]=db
                if [ -n "${hver}" ] && [ "${hage}" -ge 0 ] 2>/dev/null && [ "${hage}" -le "${CV_REPORT_STALE_S}" ]; then
                    M_VER[n]="${hver}"; M_STATE[n]="reported"; M_SRC[n]="heartbeat"
                fi
                break
            fi
        done <<<"${hb}"
    done

    local unknown=""
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        [ -n "${M_KIND[n]}" ] || unknown="${unknown:+${unknown}, }${M_NAME[n]} (${M_ADDR[n]})"
        # A claim (state=updating) names the version being installed, not one that
        # runs: that member is not done until its run writes its own record.
        [ "${M_VER[n]}" = "${target}" ] && [ "${M_STATE[n]}" != updating ] && M_DONE[n]=1
    done
    if [ -n "${unknown}" ]; then
        CV_REFUSAL="unknown|cannot tell whether ${unknown} is a DB node or the witness: it has written no update record, and this node holds no config/cluster.yml naming it. Cure: on a DB node run  ./taranac cluster sync  (fetches the cluster's manifest), or publish it from the node that holds it:  ./taranac cluster manifest-publish < config/cluster.yml"
        return 1
    fi

    # The leader — the only fact taken from Patroni. Absent means an election is
    # under way, which is seconds; it is waited for, briefly and visibly.
    local waited=0 said=0
    while :; do
        if cv_etcdctl get "/service/${CV_SCOPE}/leader" --print-value-only; then CV_LEADER="${CV_OUT}"; else
            CV_REFUSAL="quorum|the etcd ring did not answer a read from this node (${CV_ETCD_ERR:-no answer})"
            return 1
        fi
        CV_LEADER="$(printf '%s' "${CV_LEADER}" | head -1 | tr -d '[:space:]')"
        [ -z "${CV_LEADER}" ] || break
        if [ "${waited}" -ge "${CV_ELECTION_WAIT_S}" ]; then
            CV_REFUSAL="election|leader election in progress — Patroni has no leader in cluster '${CV_SCOPE}' after ${waited}s. Check:  ./taranac cluster status  on a DB node, or  ./taranac diagnose"
            return 1
        fi
        [ "${said}" = 1 ] || { notice "No Patroni leader right now (an election is under way) — waiting up to ${CV_ELECTION_WAIT_S}s ..." >&2; said=1; }
        sleep "${CV_POLL_S}"; waited=$((waited + CV_POLL_S))
        notice "  still no leader after ${waited}s" >&2
    done
    # Patroni's member name is the node name; ETCD_NAME defaults to it but may be
    # overridden, so the record's node= and the manifest's name are tried too.
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        if [ "${M_NAME[n]}" = "${CV_LEADER}" ] || [ "${M_NODE[n]:-}" = "${CV_LEADER}" ]; then CV_LEADER_IDX="${n}"; break; fi
    done
    if [ -z "${CV_LEADER_IDX}" ]; then
        while IFS=$'\t' read -r mname maddr mrole; do
            [ "${mname}" = "${CV_LEADER}" ] || continue
            for ((n = 0; n < ${#M_NAME[@]}; n++)); do [ "${M_ADDR[n]}" = "${maddr}" ] && CV_LEADER_IDX="${n}"; done
        done <<<"${manifest}"
    fi

    # The order: every replica, then the leader, then the witness.
    local -a reps=() wit=()
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        [ "${M_DONE[n]}" = 1 ] && continue
        if [ "${M_KIND[n]}" = "witness" ]; then wit+=("${n}")
        elif [ "${n}" != "${CV_LEADER_IDX}" ]; then reps+=("${n}"); fi
    done
    if [ ${#reps[@]} -gt 0 ]; then CV_NEXT=("${reps[@]}")
    elif [ -n "${CV_LEADER_IDX}" ] && [ "${M_DONE[CV_LEADER_IDX]}" != 1 ]; then CV_NEXT=("${CV_LEADER_IDX}")
    elif [ ${#wit[@]} -gt 0 ]; then CV_NEXT=("${wit[@]}")
    fi
    return 0
}

cv_role_of() {  # <index> → leader | replica | witness
    if [ "${M_KIND[$1]}" = "witness" ]; then echo witness
    elif [ "$1" = "${CV_LEADER_IDX}" ]; then echo leader
    else echo replica; fi
}

cv_is_next() {  # <index>
    local n
    for n in ${CV_NEXT[@]+"${CV_NEXT[@]}"}; do [ "${n}" = "$1" ] && return 0; done
    return 1
}

# ── One run at a time, cluster-wide ──────────────────────────────────────────
# CV_NEXT holds EVERY replica not yet done, so without this two operators (or one,
# in two terminals) could recreate two replicas at once — on 3 DB nodes + witness,
# two of three database nodes down together. Another member's fresh claim refuses.
cv_age_of() {  # <iso time> → seconds ago (huge when unparseable)
    local e; e="$(_cv_iso_epoch "$1")"
    [ "${e}" -gt 0 ] 2>/dev/null || { echo 999999999; return; }
    echo $(( $(_cv_epoch) - e ))
}

CV_BUSY=""
cv_other_running() {  # → 0 and CV_BUSY="<who, since when>" when another member's run is under way
    local n age
    CV_BUSY=""
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        [ "${n}" != "${CV_SELF_IDX}" ] && [ "${M_STATE[n]}" = updating ] || continue
        age="$(cv_age_of "${M_HB[n]}")"
        [ "${age}" -le "${CV_UPDATING_STALE_S}" ] || continue
        CV_BUSY="${M_NAME[n]} (${M_ADDR[n]}) — its update to ${M_VER[n]:-?} started there; last sign of life ${age}s ago"
        return 0
    done
    return 1
}

CV_CLAIMED=0; CV_CLAIM_PREV=""; CV_CLAIM_TARGET=""
# ── The cluster's ONE update slot: an etcd lock, taken atomically ─────────────
# The `updating` record above is what the table shows; it cannot be what decides,
# because reading it and then writing it are two steps: two replicas started in the
# same second both read "nobody", both wrote "me", and both restarted together
# (seen live on 1.3.2-rc1 — AAA down on two of three DB nodes, two etcds recreated at
# once on a four-voter ring). So the decision is one etcd transaction: the lock key
# is created only if it does not exist (create_revision = 0), and only the run whose
# transaction succeeded goes on. The key lives on a LEASE: kept alive every
# CV_LOCK_TTL_S/4 by this run, revoked when it ends (any exit), and gone by itself
# CV_LOCK_TTL_S after a run that died without ending (a reboot, kill -9) — nobody
# is ever stuck behind a dead run for longer than that.
CV_LOCK_KEY="/taranac/update/lock"
CV_LOCK_TTL_S="${TARANAC_UPDATE_LOCK_TTL_S:-120}"
CV_LOCK_LEASE=""; CV_LOCK_KEEPER=""; CV_LOCK_HOLDER=""; CV_LOCK_VALUE=""; CV_LOCK_WHY=""
# What the last cv_lock_peek saw: held (by another member) | free | unknown (etcd did
# not answer). "free" is a FACT read from etcd, and it is what makes a leftover
# `updating` record harmless: the run that wrote it holds no lock, so it is dead.
CV_LOCK_STATE=unknown
# Who holds it (its member name), when CV_LOCK_STATE=held; and whether for an update
# (empty) or a topology command (its op). The table's NEXT column reads these, so
# it can never contradict the refusal printed above it.
CV_LOCK_HOLDER_NAME=""; CV_LOCK_HOLDER_OP=""
_cv_lock_saw() {  # <lock value held by another member>
    CV_LOCK_STATE=held
    CV_LOCK_HOLDER_NAME="$(_cv_lock_field "$1" name)"; CV_LOCK_HOLDER_OP="$(_cv_lock_field "$1" op)"
    CV_LOCK_HOLDER="$(cv_lock_describe "$1")"
}
_cv_lock_field() { printf '%s' ";$1;" | sed -n "s/.*;$2=\([^;]*\);.*/\1/p"; }
cv_lock_describe() {  # <lock value> → "name (address) — updating to X since T"
    local v="$1" op
    op="$(_cv_lock_field "${v}" op)"
    if [ -n "${op}" ]; then
        # A topology command (cv_topology_lock) holds it, not an update.
        printf "%s (%s) — its '%s' started at %s" "$(_cv_lock_field "${v}" name)" \
            "$(_cv_lock_field "${v}" address)" "${op}" "$(_cv_lock_field "${v}" at)"
        return 0
    fi
    printf '%s (%s) — its update to %s started at %s' "$(_cv_lock_field "${v}" name)" \
        "$(_cv_lock_field "${v}" address)" "$(_cv_lock_field "${v}" version)" "$(_cv_lock_field "${v}" at)"
}
cv_lock_peek() {  # → 0 another member holds it (CV_LOCK_HOLDER); 1 free (or this member's own); 2 etcd did not answer
    CV_LOCK_HOLDER=""; CV_LOCK_STATE=unknown; CV_LOCK_HOLDER_NAME=""; CV_LOCK_HOLDER_OP=""
    cv_etcdctl get "${CV_LOCK_KEY}" --print-value-only || return 2
    if [ -z "${CV_OUT}" ] || [ "$(_cv_lock_field "${CV_OUT}" name)" = "${CV_SELF_NAME}" ]; then
        CV_LOCK_STATE=free; return 1
    fi
    _cv_lock_saw "${CV_OUT}"
    return 0
}
cv_lock_held() {  # → 0 when this run still holds the lock it took; 1 (CV_LOCK_WHY) when not
    CV_LOCK_WHY=""
    [ -n "${CV_LOCK_VALUE}" ] || { CV_LOCK_WHY="this run never took it"; return 1; }
    if ! cv_etcdctl get "${CV_LOCK_KEY}" --print-value-only; then
        CV_LOCK_WHY="etcd did not answer (${CV_ETCD_ERR:-no answer})"; return 1
    fi
    [ "${CV_OUT}" = "${CV_LOCK_VALUE}" ] && return 0
    if [ -z "${CV_OUT}" ]; then
        CV_LOCK_WHY="its lease expired — etcd lost its quorum for longer than ${CV_LOCK_TTL_S}s while this run waited"
    else
        CV_LOCK_WHY="it now belongs to $(cv_lock_describe "${CV_OUT}")"
    fi
    return 1
}
cv_lock_acquire() {  # <target> [op] → 0 = this run holds it; 1 = another member does (CV_LOCK_HOLDER); 2 = etcd did not answer
    local value lease req held op="${2:-}"
    CV_LOCK_HOLDER=""
    value="name=${CV_SELF_NAME};node=${CV_SELF_NODE};address=${CV_SELF_ADDR};version=$1;at=$(_cv_now)${op:+;op=${op}}"
    cv_etcdctl lease grant "${CV_LOCK_TTL_S}" || return 2
    lease="$(printf '%s\n' "${CV_OUT}" | awk '$1 == "lease" && $3 == "granted" { print $2; exit }')"
    [ -n "${lease}" ] || return 2
    req="$(mktemp)"
    # The trailing blank line closes the failure block; without it etcdctl 3.5 answers
    # "Error: EOF" and the lock can never be taken (seen on every real cluster in rc2).
    printf 'create("%s") = "0"\n\nput --lease=%s %s "%s"\n\nget %s\n\n' \
        "${CV_LOCK_KEY}" "${lease}" "${CV_LOCK_KEY}" "${value}" "${CV_LOCK_KEY}" > "${req}"
    if ! CV_STDIN_FILE="${req}" cv_etcdctl txn; then
        rm -f "${req}"; cv_etcdctl lease revoke "${lease}" >/dev/null || true
        return 2
    fi
    rm -f "${req}"
    if [ "$(printf '%s\n' "${CV_OUT}" | head -1)" != SUCCESS ]; then
        # The value is the line after the key in the failure branch's `get`.
        held="$(printf '%s\n' "${CV_OUT}" | awk -v k="${CV_LOCK_KEY}" 'f { print; exit } $0 == k { f = 1 }')"
        # Taken over only as an UPDATE from an update: this host's update runs are
        # serialised by flock, so its own lock can only be a dead run's. A topology
        # command has no such flock (two terminals on one host), and an update must
        # never take the lock out from under one — so either side holding it with
        # op= is a refusal, freed when that command ends or its lease expires.
        if [ -n "${held}" ] && [ "$(_cv_lock_field "${held}" name)" = "${CV_SELF_NAME}" ] \
           && [ -z "${op}" ] && [ -z "$(_cv_lock_field "${held}" op)" ]; then
            # This member's own earlier run, which died with its lease still alive.
            # It cannot be running: this host's runs are serialised by flock. Taken
            # over — atomically too: only if the key still holds exactly that value
            # (its lease may expire this very moment and another member take it).
            req="$(mktemp)"
            printf 'value("%s") = "%s"\n\nput --lease=%s %s "%s"\n\nget %s\n\n' \
                "${CV_LOCK_KEY}" "${held}" "${lease}" "${CV_LOCK_KEY}" "${value}" "${CV_LOCK_KEY}" > "${req}"
            if ! CV_STDIN_FILE="${req}" cv_etcdctl txn; then
                rm -f "${req}"; cv_etcdctl lease revoke "${lease}" >/dev/null || true
                return 2
            fi
            rm -f "${req}"
            if [ "$(printf '%s\n' "${CV_OUT}" | head -1)" != SUCCESS ]; then
                held="$(printf '%s\n' "${CV_OUT}" | awk -v k="${CV_LOCK_KEY}" 'f { print; exit } $0 == k { f = 1 }')"
                cv_etcdctl lease revoke "${lease}" >/dev/null || true
                [ -n "${held}" ] || return 2
                _cv_lock_saw "${held}"
                return 1
            fi
        else
            cv_etcdctl lease revoke "${lease}" >/dev/null || true
            # What a peek before this said ("free") is stale now: the lock is the fact.
            _cv_lock_saw "${held}"
            return 1
        fi
    fi
    CV_LOCK_LEASE="${lease}"; CV_LOCK_VALUE="${value}"
    CV_LOCK_STATE=free; CV_LOCK_HOLDER_NAME=""; CV_LOCK_HOLDER_OP=""
    # Kept alive while THIS process lives — the loop checks for it, so a run killed
    # outright stops renewing and the lease expires on its own.
    local me=$$ every=$(( CV_LOCK_TTL_S / 4 )); [ "${every}" -ge 1 ] || every=1
    # It closes the updater's descriptors first: fd 9 is the per-host flock on the
    # bundle directory, and a keeper (or its sleep) holding it refused the NEXT run here.
    ( exec 9>&- 8>&-
      while sleep "${every}"; do
        kill -0 "${me}" 2>/dev/null || exit 0
        _cv_etcdctl_once lease keep-alive --once "${lease}" >/dev/null 2>&1 || true
      done ) >/dev/null 2>&1 &
    CV_LOCK_KEEPER=$!
    return 0
}
cv_lock_release() {  # every exit of a run that holds it
    [ -n "${CV_LOCK_KEEPER}" ] && kill "${CV_LOCK_KEEPER}" 2>/dev/null
    CV_LOCK_KEEPER=""
    [ -n "${CV_LOCK_LEASE}" ] || return 0
    # Revoking the lease deletes the key with it.
    cv_etcdctl lease revoke "${CV_LOCK_LEASE}" >/dev/null || true
    CV_LOCK_LEASE=""; CV_LOCK_VALUE=""
}

cv_claim() {  # <target> — take the claim before anything is written; never fatal
    [ -n "${CV_SELF_NAME:-}" ] && [ -n "${CV_SELF_IDX:-}" ] || return 0
    CV_CLAIM_PREV="${M_RAW[CV_SELF_IDX]:-}"; CV_CLAIM_TARGET="$1"
    # A claim left by this node's own earlier run that died is not worth restoring.
    case ";${CV_CLAIM_PREV};" in *";state=updating;"*) CV_CLAIM_PREV="" ;; esac
    if cv_etcdctl put "${CV_PREFIX}${CV_SELF_NAME}" "$(cv_record_value updating "$1")" >/dev/null; then
        CV_CLAIMED=1
    else
        notice "Could not mark this node as updating in etcd (${CV_ETCD_ERR:-no answer}) — another node's run cannot see this one."
    fi
}
cv_beat() {  # refresh the claim's hb= between the phases of a long run
    [ "${CV_CLAIMED}" = 1 ] || return 0
    cv_etcdctl put "${CV_PREFIX}${CV_SELF_NAME}" "$(cv_record_value updating "${CV_CLAIM_TARGET}")" >/dev/null || true
}
cv_release() {  # put the record back as it was, if this run wrote none of its own; free the lock
    cv_lock_release
    [ "${CV_CLAIMED}" = 1 ] || return 0
    CV_CLAIMED=0
    if [ -n "${CV_CLAIM_PREV}" ]; then
        cv_etcdctl put "${CV_PREFIX}${CV_SELF_NAME}" "${CV_CLAIM_PREV}" >/dev/null || true
    else
        cv_etcdctl del "${CV_PREFIX}${CV_SELF_NAME}" >/dev/null || true
    fi
}

# ── What the operator reads at the end of EVERY run ──────────────────────────
# Every command this navigator hands the operator for ANOTHER run names the version.
# A bare `./taranac update` means "the latest stable", and that is not the cluster's
# target whenever this run had an explicit --version (a release candidate, a pinned
# older release) — on 1.3.2-rc1 the printed "Start here … ./taranac update" took the
# next node to 1.3.1, a no-op, and the rollout stalled without a word. And even when
# the target IS the latest, a release published halfway through a rollout would take
# the remaining nodes to a different version than the first ones. So: always.
cv_update_cmd() {  # <target> → the one command that continues THIS rollout
    printf './taranac update --version %s' "$1"
}

# "Next:" first — it is the one line that matters — then the whole cluster.
cv_next_line() {
    if [ ${#CV_NEXT[@]} -eq 0 ]; then
        local n waiting=""
        for ((n = 0; n < ${#M_NAME[@]}; n++)); do
            [ "${M_STATE[n]}" = updated ] || waiting="${waiting:+${waiting}, }${M_NAME[n]} (${M_STATE[n]:-no record})"
        done
        if [ -z "${waiting}" ]; then
            printf '%s\n' "${c_bold}Next:${c_reset} nothing — every member is on ${1}."
        else
            printf '%s\n' "${c_bold}Next:${c_reset} nothing to run — every member is on ${1}; still finishing: ${waiting}."
        fi
        return 0
    fi
    local n="${CV_NEXT[0]}" more=""
    [ ${#CV_NEXT[@]} -gt 1 ] && more=" (then the other $(( ${#CV_NEXT[@]} - 1 )) marked below, one at a time)"
    printf '%s\n' "${c_bold}Next:${c_reset} ${M_NAME[n]} (${M_ADDR[n]}) → $(cv_update_cmd "$1")${more}"
}

CV_SHOWN=0
cv_table() {  # <target>
    local target="$1" n role ver state next
    CV_SHOWN=1
    printf '\n  %-22s %-15s %-12s %-16s %s\n' NODE ROLE VERSION STATE NEXT
    for ((n = 0; n < ${#M_NAME[@]}; n++)); do
        role="$(cv_role_of "${n}")"
        ver="${M_VER[n]:-?}"; [ "${M_SRC[n]}" = "heartbeat" ] && ver="${ver}*"
        state="${M_STATE[n]:-no record}"
        [ "${M_OVR[n]}" = 1 ] && state="${state}!"
        # The lock first: it is what the refusal above the table was decided by, and a
        # member holding it for an update IS being updated, whatever its record says.
        if [ "${CV_LOCK_STATE}" = held ] && [ -z "${CV_LOCK_HOLDER_OP}" ] \
           && [ "${n}" != "${CV_SELF_IDX}" ] && [ "${M_NAME[n]}" = "${CV_LOCK_HOLDER_NAME}" ]; then
            next="being updated right now"
        elif [ "${M_DONE[n]}" = 1 ]; then
            case "${M_STATE[n]}" in
                awaiting-schema) next="finishes by itself once its api is healthy" ;;
                failed) next="FAILED: ${M_REASON[n]:-see .taranac-update.log}" ;;
                *) next="✓" ;;
            esac
        elif [ "${M_STATE[n]}" = updating ] && [ "${n}" != "${CV_SELF_IDX}" ] && [ "${CV_LOCK_STATE}" = free ]; then
            next="its last run ended without a result (holds nothing back)"
        elif [ "${M_STATE[n]}" = updating ] && [ "$(cv_age_of "${M_HB[n]}")" -le "${CV_UPDATING_STALE_S}" ]; then
            next="being updated right now"
        elif cv_is_next "${n}"; then next="← update now"
        else next="waits"; fi
        [ "${n}" = "${CV_SELF_IDX}" ] && role="${role} (this)"
        printf '  %-22s %-15s %-12s %-16s %s\n' "${M_NAME[n]}" "${role}" "${ver}" "${state}" "${next}"
    done
    printf '%s\n' "  ${c_dim}target ${target}; * = from the heartbeat (no record yet); ! = written with --allow-out-of-order${c_reset}"
}

cv_summary() {  # <target> — Next, then the table. Never fails.
    cv_next_line "$1" || true
    cv_table "$1" || true
}

# ── The refusal: before ANYTHING is written ──────────────────────────────────
# Returns 0 = this node may go ahead, 1 = refuse. The message names where to start.
cv_refuse_wrong_node() {  # <target>
    local n="${CV_NEXT[0]}"
    echo >&2
    printf '%s\n' "${c_red}✗ NOT updating: this is a cluster, and ${M_NAME[CV_SELF_IDX]} is not the next member to update.${c_reset}" >&2
    printf '%s\n' "  The order is every replica, then the leader, then the witness — so that no node" >&2
    printf '%s\n' "  ever runs code older than the schema, and the arbiter's vote is never lost together" >&2
    printf '%s\n' "  with a database node. Nothing was changed here." >&2
    printf '%s\n' "  Start here: ${M_NAME[n]} (${M_ADDR[n]}) → $(cv_update_cmd "$1")" >&2
}

# ── Writing THIS member's record (and only this member's) ────────────────────
cv_record_value() {  # <state> <version> [reason]
    local reason="${3:-}"
    reason="${reason//;/,}"
    printf 'version=%s;state=%s;role=%s;node=%s;address=%s;at=%s;hb=%s;override=%s%s' \
        "$2" "$1" "${CV_SELF_KIND}" "${CV_SELF_NODE}" "${CV_SELF_ADDR}" "$(_cv_now)" "$(_cv_now)" \
        "${CV_OVERRIDE}" "${reason:+;reason=${reason}}"
}

cv_record_put() {  # <state> <version> [reason] — bounded; a failure is said, never fatal (CV_RECORD_OK=0)
    CV_RECORD_OK=0
    [ -n "${CV_SELF_NAME:-}" ] || return 0
    if cv_etcdctl put "${CV_PREFIX}${CV_SELF_NAME}" "$(cv_record_value "$@")" >/dev/null; then
        CV_CLAIMED=0        # the run's own record replaces its claim
        CV_RECORD_OK=1
        return 0
    fi
    warn "Could not record this node's version in etcd (${CV_ETCD_ERR:-no answer})."
    # The next member reads THIS record to know where the cluster stands — a witness
    # sees nothing else — so the cure is to write it, from here, once etcd answers.
    if [ "${CV_SELF_KIND}" = witness ]; then
        notice "The update itself is done. Once etcd answers, write the record on this host:  $(cv_update_cmd "$2")"
    else
        notice "The update itself is done. Once etcd answers, write the record on this node:  $(cv_update_cmd "$2")"
        notice "(on a node already on ${2} that only records the version — nothing is restarted)."
    fi
    return 0
}

# ── The witness's gate: every DB node finished, not merely started ───────────
# A DB node that is on the target but still awaiting its schema has a finisher
# that will complete it — waited for, with progress and a ceiling. A finisher that
# stopped beating, or a node that failed, is a refusal naming that node and why.
cv_witness_gate() {  # <target> → 0 = go
    local target="$1" waited=0 n pending stuck said=0
    # 🔑 A finisher is alive when its hb= CHANGES, not when its time stamp looks recent
    # by THIS host's clock: with the two clocks more than CV_HB_STALE_S apart, a live
    # finisher read as dead and the cure printed ("run update there") changed nothing.
    # A stamp that looks recent is taken as alive at once (the common case); one that
    # looks old is watched, by elapsed time on this host only, until it either changes
    # (alive — the clocks disagree) or stays the same for CV_HB_STALE_S (dead).
    local -A hb_seen=() hb_since=()
    while :; do
        pending=""; stuck=""
        for ((n = 0; n < ${#M_NAME[@]}; n++)); do
            [ "${M_KIND[n]}" = "db" ] || continue
            case "${M_STATE[n]}" in
                updated) ;;
                failed) stuck="${stuck}${M_NAME[n]} (${M_ADDR[n]}): ${M_REASON[n]:-its update failed — see .taranac-update.log there}"$'\n' ;;
                awaiting-schema)
                    local now age key="${M_NAME[n]}"
                    now="$(_cv_epoch)"
                    age=$(( now - $(_cv_iso_epoch "${M_HB[n]}") ))
                    if [ "${hb_seen[${key}]+set}" != set ] || [ "${hb_seen[${key}]}" != "${M_HB[n]}" ]; then
                        hb_seen[${key}]="${M_HB[n]}"; hb_since[${key}]="${now}"
                    fi
                    local unchanged=$(( now - ${hb_since[${key}]} ))
                    if [ "${age}" -gt "${CV_HB_STALE_S}" ] && [ "${unchanged}" -ge "${CV_HB_STALE_S}" ]; then
                        stuck="${stuck}${M_NAME[n]} (${M_ADDR[n]}): awaiting its schema, but its finisher has not reported for ${unchanged}s — its record did not change once while this host watched (host restarted?). On ${M_NAME[n]} run  $(cv_update_cmd "${target}")  (it restarts the finisher)"$'\n'
                    else
                        pending="${pending}${M_NAME[n]} "
                    fi ;;
                *) stuck="${stuck}${M_NAME[n]} (${M_ADDR[n]}): ${M_STATE[n]:-no record} on ${M_VER[n]:-?}"$'\n' ;;
            esac
        done
        if [ -n "${stuck}" ]; then
            echo >&2
            printf '%s\n' "${c_red}✗ NOT updating the witness: a database node has not finished its update.${c_reset}" >&2
            printf '%s' "${stuck}" | sed 's/^/      /' >&2
            printf '%s\n' "  Nothing was changed here." >&2
            return 1
        fi
        [ -n "${pending}" ] || return 0
        if [ "${waited}" -ge "${CV_WITNESS_WAIT_S}" ]; then
            echo >&2
            printf '%s\n' "${c_red}✗ NOT updating the witness: ${pending% } still awaiting the schema after ${waited}s.${c_reset}" >&2
            printf '%s\n' "  Their finishers are alive but the api there is not healthy. On that node:" >&2
            printf '%s\n' "      ./taranac logs --tail 50 api" "      ./taranac cluster status" >&2
            printf '%s\n' "  Nothing was changed here." >&2
            return 1
        fi
        [ "${said}" = 1 ] || { info "Waiting for ${pending% } to finish (up to $(( CV_WITNESS_WAIT_S / 60 )) min) — their finishers start the rest of the stack once the api is healthy ..."; said=1; }
        sleep "${CV_POLL_S}"; waited=$((waited + CV_POLL_S))
        notice "  ${waited}s: still waiting for ${pending% }"
        cv_plan "${target}" >/dev/null 2>&1 || true
    done
}

# ── The finisher: the part of a DB node's update that must outlive this shell ─
# On a DB node the dependants of the api (frontend, AAA daemons, …) are created but
# left in Created until the api is healthy — `depends_on: service_healthy` is kept
# on purpose, so new daemons never run against an old schema. A replica's api is
# healthy only after the LEADER migrates, which is the operator's next step on
# another machine, so the last `up -d` cannot run in this shell. It runs in a
# one-shot container that holds the Docker socket and this bundle directory
# (docker-compose.update-finisher.yml): it survives logout and, through its restart
# policy, a reboot — a host process would survive neither.
CV_FINISHER=taranac-update-finisher

cv_finisher_running() {
    [ "$(docker inspect --format '{{.State.Running}}' "${CV_FINISHER}" 2>/dev/null)" = "true" ]
}

cv_start_finisher() {  # <dest> <version>
    local dest="$1" ver="$2" etcd_c started=""
    etcd_c="$(_cv_local_etcd || echo taranac-etcd)"
    # The 24 h ceiling counts from the FIRST start for this version, so a restart
    # (or a reboot) of the finisher never resets it.
    if [ -f "${dest}/.taranac-update-finisher.started" ]; then
        started="$(awk -v v="${ver}" '$2 == v { print $1 }' "${dest}/.taranac-update-finisher.started" 2>/dev/null || true)"
    fi
    [ -n "${started}" ] || printf '%s %s\n' "$(_cv_epoch)" "${ver}" > "${dest}/.taranac-update-finisher.started"
    # The finisher runs as root and appends to this log; created here first, it stays
    # the operator's file, so the updater's own lines (an override's trail) still land.
    touch "${dest}/.taranac-update.log" 2>/dev/null || true
    # Compose, not `docker run`: same name + same settings → the running finisher is
    # kept; anything different (a newer version) → it is replaced. One per host,
    # by container_name.
    FINISHER_DIR="${dest}" FINISHER_VERSION="${ver}" FINISHER_ETCD="${etcd_c}" \
    FINISHER_KEY="${CV_PREFIX}${CV_SELF_NAME}" \
    FINISHER_RECORD="version=${ver};role=${CV_SELF_KIND};node=${CV_SELF_NODE};address=${CV_SELF_ADDR};override=${CV_OVERRIDE}" \
        docker compose -p "${CV_FINISHER}" --project-directory "${dest}" \
            -f "${dest}/docker-compose.update-finisher.yml" up -d >/dev/null 2>&1
}

# Append one line to the bundle's update log — the trail an override leaves.
cv_log() {  # <dest> <message>
    printf '%s %s\n' "$(_cv_now)" "$2" >> "$1/.taranac-update.log" 2>/dev/null || true
}

# ── Is an address this host's own? (one definition for the bundle) ───────────
# 0 = an address of this host; 1 = not; 2 = cannot tell. "Cannot tell" is never a
# refusal: no `ip`, a name that does not resolve, or a name that resolves only to
# loopback — Ubuntu and cloud-init write `127.0.1.1 <fqdn>` into /etc/hosts, so the
# host's own FQDN answers loopback from `files` while every peer reaches it by its
# real address.
cv_address_is_local() {  # <address or name>
    local a="$1" ips r x seen=0
    command -v ip >/dev/null 2>&1 || return 2
    ips="$(ip -o addr show 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1)"
    [ -n "${ips}" ] || return 2
    a="${a#[}"; a="${a%]}"
    if [[ "${a}" =~ ^[0-9.]+$ ]] || [[ "${a}" == *:* ]]; then
        r="${a}"
    else
        r="$(getent ahosts "${a}" 2>/dev/null | awk '{ print $1 }' | sort -u)"
    fi
    [ -n "${r}" ] || return 2
    for x in ${r}; do
        case "${x}" in 127.*|::1) continue ;; esac
        seen=1
        printf '%s\n' "${ips}" | grep -qxF -- "${x}" && return 0
    done
    [ "${seen}" = 1 ] || return 2
    return 1
}

# ── The same lock, for a change of the cluster's TOPOLOGY ────────────────────
# add-node, add-witness, remove-node, remove-witness and ha-deconvert each rewrite
# the ring and publish the manifest. Two of them at once — or one in the middle of a
# rolling update — published the manifest "last writer wins" and changed the ring
# under the other's arithmetic. One lock for all of it: the update's. Sourced by the
# topology scripts through cv_topology_lock_standalone (they carry no env_value).
cv_topology_lock() {  # <op> → 0 held (or no etcd to ask: CV_TOPOLOGY_NOTE says so); 1 refused (CV_LOCK_HOLDER)
    local rc=0
    CV_TOPOLOGY_NOTE=""
    cv_lock_acquire "-" "$1" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        1) return 1 ;;
        *) CV_TOPOLOGY_NOTE="etcd did not answer (${CV_ETCD_ERR:-no answer}), so no other command could be ruled out; going on — this command checks the ring itself"
           return 0 ;;
    esac
}
