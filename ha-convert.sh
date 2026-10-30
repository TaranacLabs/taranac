#!/usr/bin/env bash
# ha-convert.sh — convert THIS existing single node into the SEED (node-1) of an HA
# cluster (docs/ops/ha.md). Run it on your current standalone install AFTER
# you have uploaded the HA license. It swaps the DB to the Patroni image, which
# ADOPTS the existing PGDATA in place (no re-init — the §6.7 baseline is already
# right), and brings node-1 up as the primary that initialises the DCS.
#
# This MUST run (and node-1 must become primary) BEFORE any other node runs
# ha-join.sh — otherwise an empty joining node could win the bootstrap race and
# clone over node-1's real data. Convert is SEQUENTIAL: node-1 first.
#
# Prerequisite: copy the cluster-wide HA settings into this .env first (the SAME on
# every node — see the .env HA block / ha-join.sh header): TARANAC_CLUSTER_NAME,
# DB_HOSTS, ETCD_HOSTS, ETCD_INITIAL_CLUSTER, POSTGRES_REPLICATION_PASSWORD,
# PG_ALLOW_CIDR. Bring the witness etcd up (a SEPARATE host) BEFORE converting — node-1
# needs etcd quorum (>= 2 of 3 members) to initialise the cluster, and convert PRUNES
# any not-yet-started member, so a witness that is still down would be pruned and
# node-1 would strand as a 1-member cluster the witness can never join.
#
# ── DEFAULT = secure etcd (peer auto-TLS + one-way client TLS), a TWO-PHASE convert (#30, ha.md §7.3) ──
# Securing etcd is a chicken-and-egg: the witness must be up BEFORE convert (or it gets
# pruned), but the witness needs a server leaf signed by a CA that only exists once THIS
# seed generates it. So the DEFAULT convert is split into two phases:
#
#   Phase 1  ./ha-convert.sh --prepare --node-name node-1 --node-address 10.0.0.1
#            → generates the etcd CA + node-1's leaf + a leaf for EVERY other member
#              (the witness + the future DB nodes) into config/cluster-secrets/, enables
#              peer auto-TLS + rewrites the member URLs to https://, writes the client-TLS
#              knobs, and STOPS. The stack is left running as-is (standalone).
#   ── then carry the witness its leaf and bring it up (OOB, on the witness host) ──
#   Phase 2  ./ha-convert.sh --continue
#            → now that the witness is a live etcd member, does the real convert
#              (adopt PGDATA, form quorum, prune the not-yet-started DB nodes, promote).
# (--client-tls is accepted as a no-op alias — TLS is already the default.)
#
# ── Opt DOWN to plaintext etcd (--plaintext): single-shot, witness already up ──
#   ./ha-convert.sh --plaintext --node-name node-1 --node-address 10.0.0.1
#   (plaintext http on 2379/2380 — MUST be firewalled to the private interconnect.)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
# A death under `set -e` prints where it happened, and a container compose left
# under a temporary name is renamed back before anything addresses it by name.
# Guarded: a bundle caught half-updated must still run (container-names.sh).
if [ -f "$HERE/container-names.sh" ]; then
  . "$HERE/container-names.sh"
  loud_death "ha-convert.sh"
  heal_container_names
fi
ENV_FILE=.env
COMPOSE="docker compose --env-file ${ENV_FILE} -f docker-compose.yml -f docker-compose.ha.yml"

NODE_NAME=""; NODE_ADDRESS=""; ETCD_NAME=""; FORCE=""; PLAINTEXT=""; PHASE=""; CLIENT_TLS_ALIAS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node-name)    NODE_NAME="$2"; shift 2 ;;
    --node-address) NODE_ADDRESS="$2"; shift 2 ;;
    --etcd-name)    ETCD_NAME="$2"; shift 2 ;;
    --client-tls)   CLIENT_TLS_ALIAS=1; shift ;;  # accepted no-op alias: secure etcd (peer+client TLS) is the DEFAULT now (#30)
    --plaintext)    PLAINTEXT=1; shift ;;         # opt DOWN to the legacy plaintext-http single-shot convert
    --prepare)      PHASE="prepare"; shift ;;
    --continue)     PHASE="continue"; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"

fail() { echo "ha-convert: $*" >&2; exit 1; }

# ── Epilogue suppression when the wizard is driving ──────────────────────────
# These scripts print "what to do next" blocks written for the MANUAL runbook. When
# `./taranac cluster …` drives them, those blocks are actively WRONG: they tell the
# operator to run a convert the wizard just ran, to SCP TLS material that now travels
# as a CSR, and to carry MASTER_KEY by hand when it rides the broker channel. An
# operator who follows them either repeats work or is sent looking for files that no
# longer exist. Printed commands mean "there is something for you to do" — so when
# there is nothing, print nothing. The wizard owns the narration in that case.
wizard_driving() { [ "${TARANAC_WIZARD:-}" = "1" ]; }


# Pre-check that a config dir the seed must WRITE into is actually writable by this
# operator (#31). Docker auto-creates a bind-mount source as ROOT the first time the
# stack comes up on the overlay; if config/etcd-tls got root-created that way, the
# non-root operator running convert can no longer drop this node's etcd leaf into it,
# and openssl fails with a cryptic EACCES. Catch it early with the exact fix.
require_writable_dir() {  # <dir>
  local d="$1"
  mkdir -p "$d" 2>/dev/null || true
  [ -w "$d" ] || fail "cannot write to '${d}' — it is not writable by $(id -un) (uid $(id -u)). Docker most likely created it as root on an earlier stack start. Fix ownership and retry:
    sudo chown -R \"\$(id -u):\$(id -g)\" '${d}'"
}

# ── Mode resolution (ha.md §7.3) ──────────────────────────────────────────────
# Secure etcd (peer auto-TLS + one-way client TLS) is the DEFAULT now (#30). Because
# client TLS is a chicken-and-egg — the witness must be a live etcd member BEFORE the
# convert, but its leaf is signed by the CA only THIS convert generates (#28) — the
# DEFAULT convert is TWO-PHASE (--prepare then --continue). --plaintext opts DOWN to the
# legacy single-shot plaintext-http path.
TLS=1; [ -n "$PLAINTEXT" ] && TLS=""
if [ -n "$CLIENT_TLS_ALIAS" ] && [ -n "$PLAINTEXT" ]; then
  fail "--client-tls (secure etcd — already the default) and --plaintext (the plaintext opt-out) are contradictory. Pass ONE: omit both (or --client-tls) for the secure default, or --plaintext to opt down."
fi
if [ -n "$PLAINTEXT" ] && [ -n "$PHASE" ]; then
  fail "--${PHASE} is the SECURE (TLS) two-phase convert; a --plaintext convert is single-shot and takes no --prepare/--continue. Bring the witness up first, then run:
    ./ha-convert.sh --plaintext --node-name <name> --node-address <addr>"
fi
if [ -n "$TLS" ] && [ -z "$PHASE" ]; then
  fail "the DEFAULT convert now secures etcd (peer + client TLS) — this is a TWO-PHASE operation, because the witness needs a leaf from the CA this seed generates (so it can't be up before convert, and a single shot would prune it — #28). Run it as:
    1) ./ha-convert.sh --prepare --node-name <name> --node-address <addr>   # generate the CA + every leaf, then STOP
    2) carry the witness its leaf (config/cluster-secrets/etcd/<witness>/) and bring the witness up
    3) ./ha-convert.sh --continue                                           # do the real convert
  (See ha.md §7.3.)  For the legacy plaintext-http single-shot, pass --plaintext instead."
fi
# An ABSENT key is an empty value, not an error. Without `|| true` this pipeline exits 1
# when grep matches nothing, and under `set -euo pipefail` a bare assignment —
# VAR="$(getenv MISSING)" — then kills the script SILENTLY, before it prints anything.
# rotate-key.sh:157 already works around this per-call; fixed here at the source.
getenv() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true ; }
setenv() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENV_FILE"; then
    local esc; esc=$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ── Unified "cluster secret set" (ha.md §12) ──────────────────────────────────
# The seed assembles the OOB secret set every join node needs — provisioned by hand
# out-of-band exactly like MASTER_KEY (never via the DB or the join-config API). This
# unifies the CHANNEL, not the runtimes: each service still reads its own *_FILE/env,
# nothing learns about "the bundle".
#   master.key    — a copy of this cluster's MASTER_KEY (Fernet KEK)          [always]
#   mfa.enckey    — the seed's taranac-mfa AES key, shared so Push tokens                [always,
#                   enrolled on ANY node decrypt on EVERY node (#13, D4-safe)    if mfa present]
#   etcd/…        — the etcd client-TLS CA + per-member server leaves          [secure default]
SECRETS_DIR="$HERE/config/cluster-secrets"
CA_DIR="$HERE/config/etcd-ca"          # the cluster CA (ca.key: into the etcd-agent container only)
TLS_DIR="$HERE/config/etcd-tls"        # this node's DEPLOYED leaf (RO-mounted into etcd+postgres)

# Extract the seed's existing mfa enckey (base64) so joining nodes reuse it. Reads the
# live container if up, else the volume — returns "" if mfa was never deployed.
mfa_enckey_b64() {
  local out
  out="$(docker exec taranac-mfa base64 -w0 /opt/taranac/data/enckey 2>/dev/null || true)"
  [ -n "$out" ] || out="$(docker run --rm -v taranac_mfa_data:/d busybox base64 /d/enckey 2>/dev/null | tr -d '\n' || true)"
  printf '%s' "$out"
}

# Parse "name=scheme://addr:2380,name2=…" → emit "name<TAB>addr" per member.
# The trailing \n keeps `read` from dropping the last (newline-less) member.
etcd_members() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r m; do
    [ -n "$m" ] || continue
    local name url addr
    name="${m%%=*}"; url="${m#*=}"
    addr="${url#*://}"; addr="${addr%%:*}"
    [ -n "$name" ] && [ -n "$addr" ] && printf '%s\t%s\n' "$name" "$addr"
  done
}

assemble_secret_set() {
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  # master.key (OOB copy for join nodes — they still pass it via env to ha-join)
  local mk; mk="$(getenv MASTER_KEY)"
  if [ -n "$mk" ] && [ "$mk" != "__GENERATE__" ]; then
    printf '%s\n' "$mk" > "$SECRETS_DIR/master.key"; chmod 600 "$SECRETS_DIR/master.key"
  fi
  # mfa.enckey — share the seed's key so Push works on every node.
  local mfa; mfa="$(mfa_enckey_b64)"
  if [ -n "$mfa" ]; then
    printf '%s' "$mfa" | base64 -d > "$SECRETS_DIR/mfa.enckey" 2>/dev/null && chmod 600 "$SECRETS_DIR/mfa.enckey"
    setenv TARANAC_MFA_ENCKEY "$mfa"
    echo "ha-convert:   shared the seed's mfa enckey (Push tokens will decrypt on every node)."
  else
    echo "ha-convert:   no taranac-mfa enckey found (mfa not deployed?) — skipping the shared-Push key."
  fi
}

provision_client_tls() {
  command -v openssl >/dev/null 2>&1 || fail "securing etcd needs openssl on this host to generate the etcd CA. (To skip TLS entirely, re-run with --plaintext.)"
  # The seed WRITES the CA, this node's leaf, and the carried secret set into these dirs —
  # verify they are writable BEFORE openssl runs so a root-created config/etcd-tls fails
  # loud with a chown hint, not a cryptic openssl permission error (#31).
  require_writable_dir "$CA_DIR"
  require_writable_dir "$TLS_DIR"
  require_writable_dir "$SECRETS_DIR"
  echo "ha-convert: securing etcd — generating the shared client-TLS CA + this node's leaf (peer channel = auto-TLS)…"
  "$HERE/ha-etcd-ca.sh" init-ca "$CA_DIR"
  "$HERE/ha-etcd-ca.sh" issue "$CA_DIR" "$TLS_DIR" "taranac-etcd-${NODE_NAME}" "${NODE_ADDRESS},127.0.0.1,localhost"
  # Persist the client-TLS knobs so THIS node's overlay comes up https (paths point
  # into the RO ./config/etcd-tls mount inside the etcd + postgres containers).
  setenv ETCD_CLIENT_SCHEME https
  setenv ETCD_SERVER_CERT_FILE /etc/etcd/tls/etcd-server.crt
  setenv ETCD_SERVER_KEY_FILE  /etc/etcd/tls/etcd-server.key
  setenv ETCD_CLIENT_CACERT    /etc/etcd/tls/ca.crt
  # Peer channel (2380, cross-host Raft) — encrypt it too, via etcd auto-TLS (zero cert
  # mgmt; each member self-signs a peer cert at boot). "Full etcd HTTPS" = client + peer.
  # etcd requires the peer transport CONSISTENT across the whole ring, so we also rewrite
  # EVERY member URL in ETCD_INITIAL_CLUSTER http://→https:// (idempotent — a no-op if the
  # operator already shipped https). ha-join derives a joining node's peer scheme from the
  # https:// in this list (preserved), so the ring forms https end-to-end from bootstrap.
  setenv ETCD_PEER_SCHEME https
  setenv ETCD_PEER_AUTO_TLS true
  local ic; ic="$(getenv ETCD_INITIAL_CLUSTER | sed 's|http://|https://|g')"
  setenv ETCD_INITIAL_CLUSTER "$ic"
  # Pre-issue a leaf for every OTHER declared member (the other DB node(s) + the
  # witness) into the secret set, so the operator carries each node its ready leaf.
  # ONLY the public ca.crt goes here — the CA PRIVATE key stays in config/etcd-ca/ on
  # the seed and is NEVER placed in the hand-carried set (invariant: it must not reach a
  # data node). Future leaves are issued from config/etcd-ca/ via ha-etcd-ca.sh.
  mkdir -p "$SECRETS_DIR/etcd"; cp -f "$CA_DIR/ca.crt" "$SECRETS_DIR/etcd/ca.crt"
  local name addr
  while IFS="$(printf '\t')" read -r name addr; do
    [ -n "$name" ] || continue
    [ "$addr" = "$NODE_ADDRESS" ] && continue   # skip the seed's own leaf (already in etcd-tls)
    echo "ha-convert:   issuing an etcd leaf for member '${name}' (${addr})…"
    "$HERE/ha-etcd-ca.sh" issue "$CA_DIR" "$SECRETS_DIR/etcd/${name}" "taranac-etcd-${name}" "${addr},127.0.0.1,localhost"
  done <<EOF
$(etcd_members "$(getenv ETCD_INITIAL_CLUSTER)")
EOF
  cat > "$SECRETS_DIR/README.txt" <<'RDME'
Taranac HA cluster secret set (out-of-band) — see HA.md in this bundle
Carry these to each node OVER A SECURE CHANNEL (like MASTER_KEY); never commit them.

  master.key            The cluster MASTER_KEY (KEK). Pass to ha-join via env:
                          MASTER_KEY="$(cat master.key)" ./ha-join.sh …
  mfa.enckey            The shared taranac-mfa encryption key (raw). ha-join lays it
                        down so Push tokens decrypt on every node. (Auto-provisioned
                        via TARANAC_MFA_ENCKEY when ha-join fetches the config.)
  etcd/ca.crt          The etcd client-TLS CA cert (public — safe to distribute).
  etcd/<node>/         That node's etcd server leaf (ca.crt + etcd-server.crt/.key).
                        Copy the WHOLE dir into that node's bundle as config/etcd-tls/
                        BEFORE ha-join. ha-join --primary follows the cluster's scheme
                        automatically (secure etcd is the default); for a MANUAL join
                        with no --primary, pass --client-tls.

The etcd CA PRIVATE key is deliberately NOT in this set — it stays in config/etcd-ca/
on the seed for now; each joining node receives a copy over the broker channel, so no
single machine's loss can leave the cluster unable to admit nodes. To add a node LATER,
issue its leaf on the
seed:  ./ha-etcd-ca.sh issue config/etcd-ca <out-dir> taranac-etcd-<name> <addr>,127.0.0.1,localhost
RDME
  echo "ha-convert: etcd secured (client TLS + peer auto-TLS). The cluster secret set is in: ${SECRETS_DIR}"
}

# ── The convert core (shared by the plaintext single-shot and client-TLS --continue) ──
# 🔑 ORDER IS LOAD-BEARING. Everything that can refuse runs while the STANDALONE stack
# is still serving: etcd is brought up BESIDE it (it needs nothing the standalone holds),
# quorum is awaited, the witness is confirmed, and the Docker network's path to every
# member's etcd — this node's own address included — is tried. Only when all of that has
# passed is the standalone taken down and node-1 started on the overlay. The previous
# order took the stack down FIRST, so a witness that was not up, or a host firewall that
# dropped the Docker network's traffic to this host's own address, left the node DOWN
# with the cause printed underneath. Seen in the field (1.3.2).
do_convert() {
  echo "ha-convert: converting '${NODE_NAME}' (${NODE_ADDRESS}) into the HA seed of cluster '$(getenv TARANAC_CLUSTER_NAME)'…"
  echo "ha-convert: ⚠️  Patroni will ADOPT the existing data dir in place (no re-init). Take a backup first if you have not."

  # The reachability checks below are actions (ha-probe.sh); without it they cannot be
  # made, and converting unchecked is how a node ended up down.
  [ -f "$HERE/ha-probe.sh" ] || fail "ha-probe.sh is missing from this bundle — it makes the checks that run before the standalone stack is stopped. Nothing was changed. Refresh the bundle and retry:
    ./taranac update"
  # shellcheck source=ha-probe.sh
  . "$HERE/ha-probe.sh"

  # What a refusal from here until the stack is stopped must say — and what to re-run.
  # Said from what Docker reports at that moment, not assumed: a standalone api that
  # had already stopped is not "still running", and saying so sends the operator to
  # look for a problem in the wrong place.
  still_says() {
    if [ "$(docker inspect -f '{{.State.Running}}' taranac-api 2>/dev/null)" = true ]; then
      echo "The standalone stack is still running and nothing was converted."
    else
      echo "Nothing was converted. The standalone api (taranac-api) is NOT running — this command did not stop it; start it again with ./taranac up -d."
    fi
  }
  local still; still="$(still_says)"
  local rerun="./ha-convert.sh --continue"
  [ -n "$PLAINTEXT" ] && rerun="./ha-convert.sh --plaintext --node-name ${NODE_NAME} --node-address ${NODE_ADDRESS}"

  # ── etcd first: form the initial quorum, then PRUNE not-yet-started members ────
  # ETCD_INITIAL_CLUSTER declares every future member (both DB nodes + the witness),
  # but at convert time only this seed + the witness are up. etcd will NOT promote its
  # cluster version until EVERY declared member has reported its version — so a member
  # that has not started yet (node-2, which runs ha-join later) pins the cluster
  # version at the 3.0.0 default. Patroni then refuses the DCS as "too old" ("Detected
  # Etcd version 3.0.0 ... watches are not supported" → it probes the dead /v3alpha
  # path and loops forever), so node-1 never becomes primary. The fix is to GROW the
  # cluster instead of declaring it whole: bring etcd up, drop the not-yet-started
  # members now, and let ha-join re-add each one (etcdctl member add) when it comes up.
  # (If every etcd is already up — e.g. you started node-2's etcd early — this is a
  # no-op, because every member then advertises a client URL.)
  # etcd belongs to the same compose project (`taranac`) as the running standalone and
  # joins its network; starting it touches no standalone container.
  echo "ha-convert: forming the initial etcd quorum (this seed + the witness), beside the running standalone stack…"
  ${COMPOSE} pull >/dev/null 2>&1 || true
  local etcd_up_at; etcd_up_at="$(date -u +%s)"
  ${COMPOSE} up -d etcd
  local etcd_ok=""
  for _ in $(seq 1 30); do
    docker exec taranac-etcd etcdctl endpoint health >/dev/null 2>&1 && { etcd_ok=1; break; }
    sleep 2
  done
  # The seed's etcd reaches "healthy" only after it forms quorum — and with 3 declared
  # members and only the seed up, that is impossible. So a failure here means the
  # witness (>= 2 of 3) is not reachable. Fail LOUD rather than let the DB wedge later.
  if [ -z "$etcd_ok" ]; then
    still="$(still_says)"
    # What this etcd has said since it was started, against ha-probe.sh's signature
    # table — a line etcd wrote is the cause, stated, and outranks any inference below.
    local saidf said="" sid scnt _f _l ssample
    saidf="$(mktemp)"
    docker logs --timestamps --since "$etcd_up_at" taranac-etcd > "$saidf" 2>&1 || true
    while IFS=$'\t' read -r sid scnt _f _l ssample; do
      [ -n "$sid" ] || continue
      said+=$'\n'"  taranac-etcd's log: [${sid}] ${scnt}× — $(printf '%s' "$ssample" | cut -c1-200)"
      if [ "$sid" = ETCD-ID ]; then
        # During a convert both rings are new: this seed's and the witness's. Neither
        # holds anything worth keeping, so both are cleared and the convert re-run.
        said+=$'\n'"    this seed's etcd and the witness's belong to different rings — one kept an etcd volume"
        said+=$'\n'"    from an earlier attempt. Both are new; clear both:"
        said+=$'\n'"      docker rm -f taranac-etcd && docker volume rm taranac_etcd_data                    # on this node"
        said+=$'\n'"      docker rm -f taranac-witness-etcd && docker volume rm taranac-witness_etcd_data    # on the witness"
        if wizard_driving; then
          local _w _wa=""
          for _w in $(getenv ETCD_INITIAL_CLUSTER | tr ',' ' '); do
            _w="${_w#*://}"; _w="${_w%%:*}"
            [ "$_w" = "$NODE_ADDRESS" ] && continue
            case ",$(getenv DB_HOSTS)," in *",${_w}:"*) continue ;; esac
            _wa="$_w"; break
          done
          said+=$'\n'"    then re-run (it joins the witness again):  ./taranac cluster add-witness --address ${_wa:-<witness>}"
        else
          said+=$'\n'"    then on the witness:  ./taranac up -d     and here:  ${rerun}"
        fi
      else
        while IFS= read -r _l; do said+=$'\n'"    ${_l}"; done < <(ha_sig_cure "$sid")
      fi
    done < <(ha_sig_scan "$saidf" etcd)
    rm -f "$saidf"
    [ -z "$said" ] || fail "the seed's etcd did not become healthy, and its own log says why:${said}
    ${still}"
    # Two different causes land here, and naming only one sends the operator to check
    # a machine that is fine. etcd elects a leader by MAJORITY OF THE DECLARED members,
    # so the arithmetic matters as much as reachability — with four declared and two up,
    # 2 of 4 is not a majority and the ring waits forever with nothing wrong anywhere.
    _declared="$(getenv ETCD_INITIAL_CLUSTER | tr ',' '\n' | grep -c '=' || true)"
    if [ "${_declared:-0}" -gt 3 ]; then
      fail "the seed's etcd did not form a quorum, and the reason is arithmetic, not reachability.
    ${still}
    ETCD_INITIAL_CLUSTER declares ${_declared} members, but at convert time only TWO exist —
    this seed and the witness. etcd elects a leader by a MAJORITY of the DECLARED
    members, and 2 of ${_declared} is not one, so the ring waits forever even though both
    machines are healthy.
    Bootstrap with just these two and let the others join later — each re-adds itself
    to the live ring when it is added:
      ETCD_INITIAL_CLUSTER=<seed>=https://<seed-addr>:2380,<witness>=https://<witness-addr>:2380
    then clear the half-formed state and retry:
      docker rm -f taranac-etcd && docker volume rm taranac_etcd_data   # on this node
      docker volume rm taranac-witness_etcd_data                        # on the witness
    ('./taranac cluster add-witness' does this trimming for you.)"
    fi
    fail "the seed's etcd did not become healthy — it needs quorum (>= 2 of 3 members) to form, so the WITNESS etcd must be up FIRST (a SEPARATE host, docker-compose.witness.yml). ${still} Bring the witness up, then retry:
    ${rerun}
  Check: docker logs taranac-etcd"
  fi

  # Witness-presence guard (#28): count started members OTHER than this seed (a non-empty
  # client-URL column, $5). At convert time exactly the witness should be up besides the
  # seed; the DB nodes join later. If NONE has reported in, the witness is not a live
  # member — pruning now would strand node-1 as a 1-member cluster the witness (which
  # bootstraps with ETCD_INITIAL_CLUSTER_STATE=new) can never join → deadlock.
  local members started_others
  members="$(docker exec taranac-etcd etcdctl member list 2>/dev/null || true)"
  started_others="$(printf '%s\n' "$members" \
    | awk -F',' -v me="$ETCD_NAME" '{u=$5;gsub(/ /,"",u); n=$3;gsub(/^[ \t]+|[ \t]+$/,"",n); if(u!="" && n!=me) c++} END{print c+0}')"
  [ "${started_others:-0}" -ge 1 ] || fail "quorum has not formed with the WITNESS yet (no other etcd member has advertised a client URL). Refusing to prune — that would leave node-1 a 1-member cluster the witness can never join (ha.md §7.3/§10.1). ${still} Bring the witness up (its leaf under config/etcd-tls + docker-compose.witness.yml up -d) and retry:
    ${rerun}"

  # ── The Docker network's path to every started member's etcd ─────────────────
  # The api and Patroni dial ETCD_HOSTS from the Docker network — THIS node's own
  # NODE_ADDRESS:2379 among them. A host firewall that admits the LAN and nothing else
  # drops that traffic to this host's own address (the "hairpin") while every check
  # made from the host passes. So each started member's client URL is called from
  # taranac_default, as Patroni will call it; a failure is named by a TCP probe.
  local ca="" url host port src subnet witness_addr="" findings="" line
  if [ "$(getenv ETCD_CLIENT_SCHEME)" = https ]; then
    ca="$TLS_DIR/ca.crt"; [ -s "$ca" ] || ca="$CA_DIR/ca.crt"
  fi
  ha_probe_network
  subnet="$(ha_probe_docker_subnet)"
  echo "ha-convert: checking every started etcd member is reachable from the Docker network (${HA_PROBE_NET}${subnet:+, ${subnet}})…"
  for url in $(printf '%s\n' "$members" | awk -F',' '{u=$5; gsub(/ /,"",u); if (u!="") print u}' | tr ',' '\n' | sort -u); do
    host="${url#*://}"; host="${host%%/*}"; port="${host##*:}"; host="${host%:*}"
    [ "$host" = "$NODE_ADDRESS" ] && src="the Docker network ${subnet:-taranac_default}" || { src="$NODE_ADDRESS"; witness_addr="${witness_addr:-$host}"; }
    if ha_probe_etcd "$url" "$ca"; then
      echo "ha-convert:   ✓ ${url}"
      continue
    fi
    local etcd_said="$PROBE_DETAIL" line
    ha_probe_tcp "$host" "$port" || true
    [ "$PROBE_CLASS" = ok ] && PROBE_CLASS=other   # the port answers; etcd's own words say why
    findings+=$'\n'"  ✗ ${url} — ${PROBE_CLASS}"
    while IFS= read -r line; do findings+=$'\n'"      | ${line}"; done < <(printf '%s\n' "$etcd_said" | tail -2)
    while IFS= read -r line; do findings+=$'\n'"      ${line}"; done < <(ha_probe_cure "$host" "$port" "$src")
  done

  # ── This node's own Patroni, by its LAN address, from the Docker network ─────
  # Patroni calls its OWN api_url (NODE_ADDRESS:8008) whenever a switchover names
  # this node as the candidate — so a firewall that drops the Docker network's
  # traffic to this host's own address leaves a cluster that cannot hand leadership
  # BACK to node-1 (1.3.3-rc3, live). Patroni does not exist yet, so a stand-in
  # listener publishes 8008 the way the overlay will, on the probe's network
  # (ha-probe.sh says why that matters). Removed again whatever happens: a listener
  # left on 8008 is a Patroni that cannot start.
  local lrc=0
  trap 'ha_probe_listen_stop' EXIT
  ha_probe_listen_start 8008 || lrc=$?
  if [ "$lrc" = 0 ] || [ "$lrc" = 2 ]; then
    [ "$lrc" = 2 ] && echo "ha-convert:   port 8008 is already in use on this host — probing what listens there"
    if ha_probe_tcp "$NODE_ADDRESS" 8008; then
      echo "ha-convert:   ✓ ${NODE_ADDRESS}:8008 (this node's Patroni, as Patroni itself will call it)"
    else
      findings+=$'\n'"  ✗ ${NODE_ADDRESS}:8008 (this node's Patroni, which it calls by this address) — ${PROBE_CLASS}"
      while IFS= read -r line; do findings+=$'\n'"      | ${line}"; done < <(printf '%s\n' "$PROBE_DETAIL" | tail -2)
    fi
  else
    findings+=$'\n'"  ✗ a stand-in listener on this host's port 8008 could not be started — this node's own 8008 could not be checked"
    while IFS= read -r line; do findings+=$'\n'"      | ${line}"; done < <(printf '%s\n' "$PROBE_DETAIL" | tail -2)
  fi
  [ "$lrc" = 0 ] && ha_probe_listen_stop
  trap - EXIT

  if [ -n "$findings" ]; then
    local again="$rerun"
    if wizard_driving; then again="./taranac cluster add-witness --address ${witness_addr:-<witness>}"; fi
    fail "the Docker network cannot reach every etcd member and this node's own Patroni — Patroni and the api would dial them from there.${findings}
  ${still}
  When the unreachable address is this node's own (${NODE_ADDRESS}), $(ha_probe_self_cure "$NODE_ADDRESS" "$subnet")
  Then re-run:
    ${again}"
  fi

  # ── Every check passed: only now is anything of the standalone touched ──────
  # The ring is read again, not reused: the probes above took seconds, and a member
  # that started meanwhile must not be pruned on a stale answer.
  local prune mid
  members="$(docker exec taranac-etcd etcdctl member list 2>/dev/null || true)"
  prune="$(printf '%s\n' "$members" | awk -F',' '{c=$5; gsub(/ /,"",c); if(c==""){id=$1; gsub(/ /,"",id); print id}}')"
  for mid in $prune; do
    echo "ha-convert:   dropping not-yet-started etcd member ${mid} (ha-join re-adds it later)…"
    docker exec taranac-etcd etcdctl member remove "$mid" >/dev/null 2>&1 || true
  done

  # Stop the standalone stack so nothing holds the data volume. The base file alone
  # leaves taranac-etcd running (it is not one of that file's services) and the
  # network it is attached to in place — compose reports "Resource is still in use"
  # for the network and carries on; the overlay below reuses both.
  echo "ha-convert: stopping the standalone stack (etcd keeps running)…"
  docker compose --env-file "$ENV_FILE" -f docker-compose.yml down >/dev/null 2>&1 || true

  # 🔑 The marker goes in NOW, before the overlay starts — TARANAC_HA=1 means "Patroni
  # owns this data", and from the next line on it does. It used to be written only after
  # node-1 had been seen primary, so an overlay `up` that failed after Patroni had
  # adopted the data (an api that never turned healthy) died under `set -e` with the
  # marker absent: the wrapper then refused `up` as "half-way", --abandon refused on the
  # etcd volume, and the shrink refused a node "not marked HA" — no way forward or back
  # (1.3.2, in the field). With the marker set first, every container also starts with
  # it in its environment, so nothing has to be recreated afterwards for the api to
  # report it.
  setenv TARANAC_HA 1   # ha.md §13 A — bundle tooling merges the overlay from here on.

  echo "ha-convert: starting node-1 on the HA overlay (Patroni adopts the data + initialises the cluster)…"
  local up_rc=0
  ${COMPOSE} up -d || up_rc=$?

  # Whether `up` succeeded or not, the database is the verdict: Patroni may hold the
  # data and be primary while a service that waits on the api's health did not start.
  echo "ha-convert: waiting for node-1 to come up as the PRIMARY (needs etcd quorum — is the witness up?)…"
  local primary=""
  for _ in $(seq 1 60); do
    if docker exec taranac-db psql -U taranac -d taranac -tAc "select not pg_is_in_recovery()" 2>/dev/null | grep -qi t; then
      primary=1; break
    fi
    sleep 5
  done
  local again="./taranac cluster status"
  if wizard_driving; then again="./taranac cluster add-witness --address ${witness_addr:-<the witness>}"; fi
  if [ -z "$primary" ]; then
    fail "this node's database belongs to Patroni now (TARANAC_HA=1 is set), and it did not become
  the primary within the timeout. The usual cause is etcd without quorum. Check both:
      docker exec taranac-etcd etcdctl endpoint health --cluster
      ./taranac logs --tail 80 postgres
  Forward — once the cause is fixed, start it again (the overlay is merged from now on):
      ./taranac up -d
      ${again}
  Back — to a standalone server (this node keeps its data):
      ./ha-deconvert.sh --force --confirm NO-OTHER-NODES
    then on the witness host:   ./witness-join.sh --leave --confirm NOT-A-MEMBER"
  fi
  if [ "$up_rc" -ne 0 ]; then
    echo "ha-convert: the database is converted and node-1 is the primary, but the overlay's 'up -d'
  failed — the services compose names above did not become healthy. Find out why:
      ./taranac logs --tail 80 api
  Forward — once the cause is fixed:
      ./taranac up -d
      ${again}
  Back — to a standalone server (this node keeps its data):
      ./ha-deconvert.sh
    then on the witness host:   ./witness-join.sh --leave --confirm NOT-A-MEMBER" >&2
    exit 3
  fi
}

print_join_steps() {
  echo "    ./taranac cluster join-token --name node-2 --address <addr>"
  echo "    # OOB (carry like MASTER_KEY): copy the seed's  config/cluster-secrets/mfa.enckey  →"
  echo "    #   node-2's  config/cluster-secrets/mfa.enckey  so Push MFA tokens decrypt cluster-wide."
  echo "    #   ha-join AUTO-DETECTS that file (or pass TARANAC_MFA_ENCKEY); skipping it = node-local Push key."
  echo "    # then on node-2:  MASTER_KEY=<key> ./ha-join.sh --node-name node-2 --node-address <addr> --join-token <secret>"
}

# ── Guards (shared by every mode) ─────────────────────────────────────────────
[ -f "$ENV_FILE" ] || fail "no .env in $(pwd) — this is meant to run on a configured standalone install."

# Idempotency guard — convert is a ONE-TIME standalone→HA operation. Re-running it on
# an already-converted node needlessly tears the whole stack down and back up (downtime)
# and, on a multi-node cluster, forces a failover to another node and then TIMES OUT
# waiting for THIS node to be primary (it comes back as a replica). Refuse by default.
# (--prepare does NOT set TARANAC_HA=1 — the node stays standalone until --continue —
# so this correctly does not fire between the two phases.)
if [ "$(getenv TARANAC_HA)" = "1" ] && [ -z "$FORCE" ]; then
  fail "this node is ALREADY an HA node (TARANAC_HA=1 in .env). ha-convert is a one-time standalone→HA conversion — re-running it just restarts the stack (and can trigger a failover on a multi-node cluster). Use './taranac up -d' to (re)start it, or './taranac cluster status' to inspect it. Pass --force only if you truly mean to re-run the conversion."
fi

# --continue is a fresh invocation after an out-of-band pause; default this node's
# identity from what --prepare persisted so the operator need not re-type it, and verify
# --prepare actually ran (before the docker-dependent guards, so a missing prepare fails
# fast and unambiguously rather than tripping the data-volume guard first).
if [ "$PHASE" = continue ]; then
  [ -n "$NODE_NAME" ]    || NODE_NAME="$(getenv TARANAC_NODE_NAME)"
  [ -n "$NODE_ADDRESS" ] || NODE_ADDRESS="$(getenv NODE_ADDRESS)"
  [ -n "$ETCD_NAME" ] || ETCD_NAME="$(getenv ETCD_NAME)"
  ETCD_NAME="${ETCD_NAME:-$NODE_NAME}"
  [ "$(getenv ETCD_CLIENT_SCHEME)" = https ] && [ -s "$CA_DIR/ca.crt" ] && [ -s "$TLS_DIR/etcd-server.crt" ] \
    || fail "no completed --prepare found (missing etcd CA at $CA_DIR/ca.crt, this node's leaf at $TLS_DIR/etcd-server.crt, or ETCD_CLIENT_SCHEME=https in .env). Run './ha-convert.sh --prepare …' FIRST, bring the witness up, then re-run --continue."
fi

[ -n "$NODE_NAME" ]    || fail "missing --node-name (this seed node's unique cluster name)"
[ -n "$NODE_ADDRESS" ] || fail "missing --node-address (this node's routable host/IP)"
for k in TARANAC_CLUSTER_NAME DB_HOSTS ETCD_HOSTS ETCD_INITIAL_CLUSTER POSTGRES_REPLICATION_PASSWORD; do
  [ -n "$(getenv "$k")" ] || fail "$k is not set in .env — add the cluster-wide HA block first (see the .env HA section)."
done

# Witness guard (ha.md §8) — a 2-node cluster needs a 3rd etcd arbiter.
MEMBERS=$(getenv ETCD_INITIAL_CLUSTER); MCOUNT=$(printf '%s' "$MEMBERS" | tr ',' '\n' | grep -c '=')
[ "$MCOUNT" -ge 3 ] || fail "ETCD_INITIAL_CLUSTER lists $MCOUNT etcd member(s); HA REQUIRES >= 3 (the DB nodes + a witness arbiter in a SEPARATE failure domain) or a partition cannot reach quorum → split-brain (ha.md §8)."

# Directionality: the SEED must have EXISTING data (the opposite of a joining node).
VOL="taranac_pg_data"
docker volume inspect "$VOL" >/dev/null 2>&1 || fail "Postgres volume '${VOL}' not found — convert runs on a POPULATED standalone node. (A fresh node should be a join, not a convert.)"
[ -n "$(docker run --rm -v "${VOL}:/d" postgres:16-alpine sh -c 'ls -A /d 2>/dev/null')" ] || fail "Postgres volume '${VOL}' is EMPTY — nothing to adopt. Convert runs on your existing standalone data."

# Persist this node's identity (used by provision_client_tls SANs + read back by --continue).
setenv TARANAC_NODE_NAME "$NODE_NAME"
setenv NODE_ADDRESS "$NODE_ADDRESS"
setenv ETCD_NAME "$ETCD_NAME"

# Patroni REST password. Authentication on port 8008 is unconditional — the postgres-ha
# entrypoint refuses to start without it — but a node installed by an OLDER install.sh has
# no such key in .env, so the convert would bring up a Patroni that immediately refuses.
# Mint one here if it is absent (this node is the seed; joining nodes adopt it over the
# token-authenticated join-config). Never overwrite an existing value: on --continue this
# runs a second time, and a fresh password would lock out the members already holding it.
[ -n "$(getenv PATRONI_REST_PASSWORD)" ] || setenv PATRONI_REST_PASSWORD "$(openssl rand -hex 24)"

# The ring's IDENTITY, drawn once per incarnation of the cluster and independent of
# its NAME. etcd derives the ClusterID from this token plus the initial member set:
# with the name in that role, a cluster rebuilt under the same name came back with
# the same ClusterID, and a machine left over from the cluster it replaced rejoined
# it silently. Same rule as the password above — minted only when absent, never
# overwritten, because --continue runs this a second time and every member of the
# ring has to agree on it. Joining nodes and the witness adopt it over the
# token-authenticated join-config.
[ -n "$(getenv TARANAC_CLUSTER_ID)" ] || setenv TARANAC_CLUSTER_ID "$(openssl rand -hex 16)"

# When this ring was FORMED — the companion fact to the id above, and drawn at the
# same moment for the same reason. The failover rehearsal refuses on a cluster that
# looks like it is in service, and the only age it could measure before this was the
# oldest ROSTER row: a surviving node keeps that row across a deconvert-and-rebuild,
# so a stand rebuilt in the morning reported 12.9 days and refused its own rehearsal.
# Minted only when absent (--continue / a re-run of init must not restamp a ring that
# already exists), cleared by ha-deconvert, and adopted verbatim by joining nodes.
[ -n "$(getenv TARANAC_CLUSTER_FORMED_AT)" ] || setenv TARANAC_CLUSTER_FORMED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Mode dispatch ─────────────────────────────────────────────────────────────
if [ "$PHASE" = prepare ]; then
  # Phase 1: generate the CA + every member's leaf + the https knobs, then STOP. Do NOT
  # set TARANAC_HA=1 and do NOT touch the stack — the node stays standalone until
  # --continue. The mfa enckey is read from the still-running standalone mfa container.
  echo "ha-convert: PREPARE phase (secure etcd, the default) — generating the client-TLS CA + every member's leaf + enabling peer auto-TLS. The stack is left running as-is (still standalone)."
  assemble_secret_set
  provision_client_tls
  echo
  if wizard_driving; then
    echo "ha-convert: prepare complete (CA + a leaf for every declared member)."
    exit 0
  fi
  echo "ha-convert: ✅ prepare complete. Next, BEFORE the convert:"
  echo "  1) Bring up the WITNESS on its separate host (it is SECURE BY DEFAULT — client + peer TLS):"
  echo "       • on the witness:  cp .env.witness.example .env  (secure by default), then set NODE_ADDRESS,"
  echo "         ETCD_NAME, TARANAC_CLUSTER_NAME + the https:// ETCD_INITIAL_CLUSTER member list to match this cluster"
  echo "       • copy  config/cluster-secrets/etcd/<witness-name>/  →  the witness bundle's  config/etcd-tls/  (OOB)"
  echo "         (its client-TLS leaf — the .env.witness.example TLS knobs already point at it; no hand-editing)"
  echo "       • on the witness:  docker compose --env-file .env -f docker-compose.witness.yml up -d"
  echo "     (Per-member leaves generated now — the witness is one of these; the DB nodes join later via ha-join:)"
  for _leaf in "$SECRETS_DIR"/etcd/*/; do
    [ -d "$_leaf" ] || continue   # dirs only → the ca.crt file is skipped
    echo "       - config/cluster-secrets/etcd/$(basename "$_leaf")/"
  done
  echo "  2) Then, back HERE on node-1, run the real convert:"
  echo "       ./ha-convert.sh --continue"
  echo
  echo "ha-convert: (do NOT run './taranac up -d' during the pause — the node is not converted yet.)"
  exit 0
fi

if [ "$PHASE" = continue ]; then
  # Phase 2: --prepare completion was already verified in the early continue guard above.
  # do_convert writes TARANAC_HA=1 itself, just before the overlay starts: a refusal
  # before that point leaves the node standalone and the convert retryable.
  do_convert
  if wizard_driving; then
    echo "ha-convert: done — node-1 is the primary (etcd secured: client TLS + peer auto-TLS)."
    exit 0
  fi
  echo "ha-convert: done — node-1 is the primary (etcd secured: client TLS + peer auto-TLS). NOW issue a join token and run ha-join.sh on each other node:"
  print_join_steps
  echo "ha-convert: etcd TLS is ON — for each joining node, ALSO:"
  echo "    1) copy config/cluster-secrets/etcd/<that-node>/  →  its bundle's config/etcd-tls/  (OOB)"
  echo "    2) run ha-join.sh with --primary <this node> (it auto-follows the https scheme); or, for a manual join with no --primary, pass --client-tls"
  echo "    (the etcd CA private key is in config/etcd-ca/; the wizard's join hands every node a wrapped copy.)"
  exit 0
fi

# ── Plaintext single-shot (--plaintext opt-out) ───────────────────────────────
# Reached only with --plaintext and no phase (the mode-resolution guards above enforce
# it). Secure etcd is the DEFAULT (#30); this is the explicit opt-DOWN to plaintext http.
# Assemble the unified secret set BEFORE the standalone stack is torn down (the mfa
# enckey is read from the still-running mfa container).
[ -n "$PLAINTEXT" ] || fail "internal: reached the plaintext path without --plaintext (this should be unreachable — please report)."
assemble_secret_set
mkdir -p "$TLS_DIR"   # keep the RO bind-mount source present (inert) for the http path
# --plaintext is fully plaintext etcd: force http on BOTH channels regardless of what the
# copied .env HA block carried (the .env.example ships the secure https:// default), so the
# result is deterministic — never a half-https ring from a stale member URL.
setenv ETCD_CLIENT_SCHEME http
setenv ETCD_PEER_SCHEME http
setenv ETCD_PEER_AUTO_TLS false
PLAINTEXT_IC="$(getenv ETCD_INITIAL_CLUSTER | sed 's|https://|http://|g')"
setenv ETCD_INITIAL_CLUSTER "$PLAINTEXT_IC"
echo "ha-convert: --plaintext — etcd channel = plaintext http (NOT encrypted; firewall 2379/2380 to the private interconnect). The DEFAULT is secure etcd (peer + client TLS) via the two-phase '--prepare' / '--continue' (ha.md §7.3)."
# The authoritative HA marker (ha.md §13 A) is written inside do_convert, at the moment
# Patroni is handed the data — see there.
do_convert
if wizard_driving; then
  echo "ha-convert: done — node-1 is the primary."
  exit 0
fi
echo "ha-convert: done — node-1 is the primary. NOW issue a join token and run ha-join.sh on each other node:"
print_join_steps
