#!/usr/bin/env bash
# =============================================================================
# taranac-restore.sh — guided disaster recovery from a Taranac backup archive.
#
# Normally invoked as:  ./taranac restore <archive.tar>
#
# WHAT RECOVERY IS
#   Deploy the same version fresh, overlay the handful of secrets that must
#   survive the rebuild, load the dump from a one-off container, THEN recreate the
#   stack. In that order — the api refuses to boot on a database whose key canary
#   is another key's, so the dump must be in before it runs on the restored key.
#
# WHY THE .env IS NOT COPIED BACK
#   The archive carries the old host's .env whole (it is the record of how that
#   install was configured, and the only place MASTER_KEY ever existed). But
#   restoring it wholesale would carry the OLD host onto the NEW one: the image
#   tag (TARANAC_VERSION — a silent rollback), the HA topology (NODE_ADDRESS,
#   DB_HOSTS, ETCD_INITIAL_CLUSTER, TARANAC_NODE_NAME, PG_ALLOW_CIDR), the
#   domains, ports, TLS paths and all three database connection settings. And an
#   archive cut by an older release simply has no line for a key added since —
#   restoring a 1.1.2 archive over 1.2.1 would drop REPORTS_RENDERER_API_KEY and
#   break the report renderer. The list of things to EXCLUDE would grow with every
#   release; the list of things that must SURVIVE is short and stable, so that is
#   the list we keep. Same shape as MANAGED_SECRETS in env-secrets.sh.
#
# WHERE THE ARCHIVE AND ITS CONTENTS LIVE
#   `backups` is a NAMED volume mounted at /app/backups in the api container — not
#   a bind of ./backups. The host cannot see into it, so everything here crosses
#   that boundary explicitly: an archive given as a host path is streamed IN, and
#   what phase 1 extracts (the env snapshot, host_config/) is read back OUT through
#   the container. Through 1.3.1 this script looked for them under ./backups/restore,
#   where they never were — so the recovery keys were never overlaid, host_config
#   was never restored, and a --master-key restore onto a fresh install failed
#   phase 2 after it had already recreated the stack with the wrong key.
#
# COMPATIBLE BACK TO 1.2.2 — ON PURPOSE
#   Phase 2 refuses an archive of another version, so restoring a 1.3.1-or-older
#   archive means deploying THAT version — whose bundle ships the broken script
#   described above. The way out is to drop THIS script into that old bundle and
#   run it. So it must work against api images and bundles from 1.2.2 on: it
#   feature-detects the image's restore CLI and falls back where it is older, and
#   it depends on nothing in env-secrets.sh that those bundles lack.
#
# Prerequisites:
#   * A freshly deployed, HEALTHY Taranac of the archive's version (log in as the
#     default admin once — that separates "the deploy failed" from "recovery
#     failed").
#   * The archive: either a file on this host (any path — it is copied into the
#     backups volume), or the bare name of an archive already in that volume (one
#     this install wrote, listed in System → Backup).
#   * The ORIGINAL master key. If the fresh install does not already run with it,
#     pass it: --master-key <key>, or TARANAC_MASTER_KEY=<key> in the environment
#     (keeps it out of the shell history; the flag wins if both are given). Without
#     it the archive cannot be opened at all. It is written into the env-file,
#     because every container that reads the key is recreated from that file, and
#     it reaches the api container on stdin only — never on a command line, where
#     every user of the host could read it in `ps`.
#
# Usage:
#   ./taranac restore /path/to/taranac-backup-YYYYMMDDTHHMMSSZ.tar [--master-key KEY] [--yes]
#   ./taranac restore taranac-backup-YYYYMMDDTHHMMSSZ.tar      # already in the volume
#   ./taranac restore [options] -- -odd-name.tar             # a name starting with '-'
#
# In the source repo (dev/prod layouts) point it at the right pair explicitly:
#   TARANAC_ENV_FILE=.env.dev TARANAC_COMPOSE_FILE=docker-compose.dev.yml \
#     deploy/dist/taranac-restore.sh <archive.tar>
# =============================================================================
# The `sh -c '… "$1"' sh <path>` calls into the api container quote on purpose: the
# path is expanded by the container's shell from its argument, never spliced into
# the script text.
# shellcheck disable=SC2016
set -euo pipefail
# Temp files here hold secrets (.env copies). Owner-only by default; the two things
# that must stay readable by the api's uid 999 keep their mode anyway — .env is
# rewritten through its own inode, and ./config is copied under an explicit umask
# and then re-secured.
umask 077

# A relative archive path means relative to where the operator stood, not to the
# bundle. The `taranac` wrapper has already cd'd into the bundle by the time it
# execs this script, so it exports where it was called from; run directly, $PWD
# (captured before the cd below) is that place.
CALLER_PWD="${TARANAC_CALLER_PWD:-${PWD}}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${HERE}"

ENV_FILE="${TARANAC_ENV_FILE:-.env}"
COMPOSE_FILE="${TARANAC_COMPOSE_FILE:-docker-compose.yml}"

ARCHIVE_ARG=""
MASTER_KEY_ARG=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --master-key) [ $# -ge 2 ] || { echo "✗ --master-key needs a value" >&2; exit 1; }
                  MASTER_KEY_ARG="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,67p' "$0"; exit 0 ;;
    --)           shift; [ $# -gt 0 ] && ARCHIVE_ARG="$1"; break ;;
    -*)           echo "✗ unknown option: $1" >&2; exit 1 ;;
    *)            ARCHIVE_ARG="$1"; shift ;;
  esac
done
[ -n "${MASTER_KEY_ARG}" ] || MASTER_KEY_ARG="${TARANAC_MASTER_KEY:-}"

[ -n "${ARCHIVE_ARG}" ] || { echo "Usage: ./taranac restore <archive.tar> [--master-key KEY] [--yes]" >&2; exit 1; }
[ -f "${ENV_FILE}" ] || { echo "✗ ${ENV_FILE} not found — deploy a fresh install first (./install.sh)." >&2; exit 1; }

# ── Where the archive is ────────────────────────────────────────────────────
# A file on this host wins: that is what an operator holds after a rebuild. The
# legacy ./backups/ is tried too, because the documents used to tell people to put
# the archive there (it never reached the volume from there either). Otherwise it
# must already be in the volume — checked before phase 1, below.
ARCHIVE_HOST=""
case "${ARCHIVE_ARG}" in
  /*) HOST_CANDIDATES=("${ARCHIVE_ARG}") ;;
  *)  HOST_CANDIDATES=("${CALLER_PWD}/${ARCHIVE_ARG}" "${HERE}/backups/${ARCHIVE_ARG}") ;;
esac
for candidate in "${HOST_CANDIDATES[@]}"; do
  [ -f "${candidate}" ] && { ARCHIVE_HOST="${candidate}"; break; }
done
ARCHIVE_NAME="${ARCHIVE_ARG##*/}"   # not basename: a name may start with '-'
# These names are this script's own work paths in the volume (the extraction, the
# old-image key check, a copy in flight). An archive called that would be deleted
# or extracted over by the restore itself.
case "${ARCHIVE_NAME}" in
  ""|restore|.*|*.part)
    echo "✗ '${ARCHIVE_NAME}' cannot be restored under that name — it collides with the restore's" >&2
    echo "  own work files in the backups volume. Rename the archive (e.g. taranac-backup-<UTC>.tar)." >&2
    exit 1 ;;
esac

# ── HA awareness ────────────────────────────────────────────────────────────
# Under HA the database is Patroni-managed via the overlay. Acting on the base
# compose alone would start a SECOND writable Postgres on the Patroni data
# directory — split-brain, on a host we are in the middle of recovering. Same
# detection as the `taranac` wrapper (docs/ops/ha.md): fail toward the
# overlay, never silently base-only.
COMPOSE_FILES=(-f "${COMPOSE_FILE}")
RESTORE_HA=0
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?TARANAC_HA[[:space:]]*=[[:space:]]*"?1"?[[:space:]]*$' "${ENV_FILE}" \
   || grep -Eiq '^[[:space:]]*(export[[:space:]]+)?DB_HOSTS[[:space:]]*=[[:space:]]*"?[^"[:space:]#]' "${ENV_FILE}"; then
  [ -f docker-compose.ha.yml ] || {
    echo "✗ HA is configured but docker-compose.ha.yml is missing. Refusing to act on the" >&2
    echo "  base compose alone — that would start a second writable Postgres on the" >&2
    echo "  Patroni-managed data directory. Restore the overlay ('./taranac update') first." >&2
    exit 1
  }
  COMPOSE_FILES=(-f "${COMPOSE_FILE}" -f docker-compose.ha.yml)
  echo "! HA detected — using the Patroni overlay."
  RESTORE_HA=1
  # 🔑 On the LEADER only, and checked, not printed. The dump is loaded into the one
  # writable database of the cluster and reaches the replicas by replication; on a
  # replica the load cannot run at all, and the recovery keys it writes into THIS
  # node's .env would leave it unable to read the database the cluster really has.
  if ! docker exec taranac-db psql -U taranac -d taranac -tAc 'select not pg_is_in_recovery()' 2>/dev/null </dev/null | grep -qi '^t'; then
    echo "✗ This node is not the cluster's leader (its database is a replica, or does not answer)." >&2
    echo "  A restore loads the dump into the cluster's ONE writable database — the leader's —" >&2
    echo "  and every replica takes it from there by replication. Nothing has been changed." >&2
    echo "  Find the leader and run the same command there:" >&2
    echo "      ./taranac cluster status" >&2
    exit 1
  fi
  echo "  This node is the leader: the restore runs here and reaches the replicas by replication."
fi
COMPOSE=(docker compose --env-file "${ENV_FILE}" "${COMPOSE_FILES[@]}")

ARCHIVE_IN_CONTAINER="/app/backups/${ARCHIVE_NAME}"
RESTORE_OUT_CONTAINER="/app/backups/restore"

# env_last_value <key> < env-text — one key's value, read the way compose,
# env-secrets.sh (_env_secret_value) and rotate-key.sh read it: the LAST assignment
# wins, an `export` prefix is allowed, no interpolation, quotes and CR dropped.
# Inlined rather than sourced: the 1.2.2/1.2.3 bundles this script must also run in
# ship an env-secrets.sh without _env_secret_value.
env_last_value() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" \
    | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"'\r' || true
}

# ── Only an env-sourced key can be restored this way ────────────────────────
# Everything below puts the key into the env-file, because that is where the
# recreated containers take it from. Under MASTER_KEY_SOURCE=file or =prompt the
# api ignores MASTER_KEY in the env-file entirely: the overlay would succeed, the
# gate would pass on a key nothing uses, and phase 2 would fail after the stack had
# been recreated. Refused here, before anything is touched.
KEY_SOURCE="$(env_last_value MASTER_KEY_SOURCE < "${ENV_FILE}")"
if [ -n "${KEY_SOURCE}" ] && [ "${KEY_SOURCE}" != "env" ]; then
  echo "✗ ${ENV_FILE} sets MASTER_KEY_SOURCE=${KEY_SOURCE}: the api does not take its key from" >&2
  echo "  MASTER_KEY in ${ENV_FILE}, so this script cannot put the archive's key in place." >&2
  echo "  Switch to MASTER_KEY_SOURCE=env for the recovery (the original key as MASTER_KEY)," >&2
  echo "  or install the original key where your key source reads it, then retry." >&2
  echo "  Nothing has been changed." >&2
  exit 1
fi

# The values that must survive the rebuild. Everything else in a .env describes
# the host, and a rebuilt host has its own. Mirrored by RECOVERY_KEYS in
# backend/app/scripts/restore.py (a unit test asserts the two stay identical).
MANAGED_RECOVERY_KEYS=(
    MASTER_KEY                 # decrypts every secret in the database dump
    SECRET_KEY                 # signs sessions
    TARANAC_MFA_API_KEY        # paired — the other half is a row in the restored DB
    INTERNAL_API_KEY           # paired — daemons ↔ api
    REPORTS_RENDERER_API_KEY   # paired — api ↔ taranac-renderer
)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
# After phase 1 the backups volume holds DECRYPTED secrets. A failure from then on
# leaves them there (the re-run needs nothing from them, but the operator may want
# to look), and says how to remove them rather than leaving that to be discovered.
EXTRACTED=0
fail() {
  echo "✗ $1" >&2
  if [ "${EXTRACTED}" -eq 1 ]; then
    echo "  The extracted archive (decrypted secrets) is still in the backups volume at" >&2
    echo "  ${RESTORE_OUT_CONTAINER}. Remove it once you no longer need it:" >&2
    echo "    ./taranac exec -T api rm -rf ${RESTORE_OUT_CONTAINER}" >&2
  fi
  exit 1
}

# ── The one writer for the env-file ─────────────────────────────────────────
# set_env_value <key> <value> — every .env write in this script goes through here,
# because each of these properties has bitten a recovery once already:
#   * a BARE `KEY=value` line — no quotes, no `export`: rotate-key.sh reads the key
#     with `^KEY=`, and a quoted value would carry its quotes into a Fernet key;
#   * EVERY matching line replaced, not the first: compose, env-secrets.sh and
#     rotate-key.sh take the LAST assignment, older code here took the FIRST — with
#     duplicates left in place the two halves of the system would disagree about
#     which key is live;
#   * the value through ENVIRON, never `awk -v` (which expands backslash escapes)
#     and never sed (a '/' or '&' in base64url is a sed metacharacter) — a mangled
#     MASTER_KEY is unrecoverable;
#   * written back IN PLACE (`cat > file`, not mv): secure_env_file gave the file
#     group 999 and mode 640 so the api can read it into the next backup, and a
#     replaced inode loses both — silently, since that backup then just lacks .env;
#   * EVERY step checked, explicitly. Callers run it in `if`/`||`, where `set -e` is
#     off for the whole function body: an unwritable directory once made the awk
#     fail, the empty temp file was copied over .env, and the script went on to
#     report "restored". The file is overwritten only from a temp file that exists,
#     is non-empty and carries the new line.
# Returns 0 written, 1 already exactly in place (not rewritten), 2 failed.
ENV_CHANGED=0
ENV_TMP="${ENV_FILE}.restore-tmp"
set_env_value() {
  local key="$1" value="$2" state
  state="$(TARANAC_RESTORE_KEY="${key}" TARANAC_RESTORE_VALUE="${value}" awk '
    BEGIN { k = ENVIRON["TARANAC_RESTORE_KEY"]; want = k "=" ENVIRON["TARANAC_RESTORE_VALUE"]
            re = "^[[:space:]]*(export[[:space:]]+)?" k "=" }
    $0 ~ re { n++; if ($0 != want) d++ }
    END { print ((n > 0 && d == 0) ? "same" : "differs") }
  ' "${ENV_FILE}")" || return 2
  case "${state}" in
    same)    return 1 ;;
    differs) ;;
    *)       return 2 ;;
  esac
  TARANAC_RESTORE_KEY="${key}" TARANAC_RESTORE_VALUE="${value}" awk '
    BEGIN { k = ENVIRON["TARANAC_RESTORE_KEY"]; want = k "=" ENVIRON["TARANAC_RESTORE_VALUE"]
            re = "^[[:space:]]*(export[[:space:]]+)?" k "=" }
    $0 ~ re { print want; done = 1; next }
    { print }
    END { if (!done) print want }
  ' "${ENV_FILE}" > "${ENV_TMP}" || { rm -f "${ENV_TMP}"; return 2; }
  if ! { [ -s "${ENV_TMP}" ] && grep -qxF -- "${key}=${value}" "${ENV_TMP}"; }; then
    rm -f "${ENV_TMP}"; return 2
  fi
  cat "${ENV_TMP}" > "${ENV_FILE}" || { rm -f "${ENV_TMP}"; return 2; }
  rm -f "${ENV_TMP}"
  ENV_CHANGED=1
  return 0
}

# Put .env back from the copy this run made. Used when a write fails and when the
# key gate refuses; the copy is removed only once its content is back in place.
PRE_RESTORE=""
put_env_back() {
  [ -n "${PRE_RESTORE}" ] && [ -s "${PRE_RESTORE}" ] || return 1
  cat "${PRE_RESTORE}" > "${ENV_FILE}" || return 1
  rm -f "${PRE_RESTORE}"
  PRE_RESTORE=""
}

# apply_env_value <key> <value> <what-it-is> — set_env_value, reported; a failed
# write ends the restore here, before anything irreversible, with .env put back.
apply_env_value() {
  local rc=0
  set_env_value "$1" "$2" || rc=$?
  case "${rc}" in
    0) echo "  - $1: $3" ;;
    1) echo "  - $1: already that value" ;;
    *) local kept="${PRE_RESTORE}"
       if put_env_back; then
         fail "could not write $1 into ${ENV_FILE} — ${ENV_FILE} put back from ${kept}, nothing else changed. Is ${HERE} writable?"
       fi
       fail "could not write $1 into ${ENV_FILE}, nor put it back: ${ENV_FILE} may be damaged; the original is ${kept}. Copy it back before anything else." ;;
  esac
}

# ── Phase 1: verify the key, extract the host material ──────────────────────
if [ -n "${ARCHIVE_HOST}" ]; then
  say "Copying ${ARCHIVE_HOST} into the backups volume"
  # Streamed through the api process rather than `docker compose cp`: cp lands the
  # file owned by root with the host file's mode, and an archive kept 0600 on the
  # host (as it should be) would then be unreadable to the api's uid 999. Written by
  # the api itself, it is the api's own file. Into a .part first and renamed only
  # when complete: an interrupted copy must never sit in the volume under the name
  # of a real archive.
  "${COMPOSE[@]}" exec -T api sh -c 'cat > "$1.part" && mv "$1.part" "$1" || { rm -f "$1.part"; exit 1; }' \
      sh "${ARCHIVE_IN_CONTAINER}" < "${ARCHIVE_HOST}" \
    || fail "could not copy the archive into the api container's ${ARCHIVE_IN_CONTAINER} — nothing has been changed."
  echo "  now at ${ARCHIVE_IN_CONTAINER}"
elif ! "${COMPOSE[@]}" exec -T api sh -c 'test -f "$1"' sh "${ARCHIVE_IN_CONTAINER}" >/dev/null 2>&1; then
  {
    echo "✗ archive not found. Looked on this host at:"
    printf '    %s\n' "${HOST_CANDIDATES[@]}"
    echo "  and in the backups volume at ${ARCHIVE_IN_CONTAINER}."
    echo "  Give the archive's ABSOLUTE path on this host (a wrapper older than this script"
    echo "  takes a relative one relative to ${HERE}). Nothing has been changed."
  } >&2
  exit 1
fi

# ── Which restore CLI does this api image have? ─────────────────────────────
# `check-key` and `--master-key -` (stdin) arrived together, in the release that
# fixed this script. An image from 1.2.2–1.3.1 has neither, and gets the fallbacks
# below. Asked once, by asking for the subcommand's help.
NEW_CLI=0
if "${COMPOSE[@]}" exec -T api python -m app.scripts.restore check-key --help >/dev/null 2>&1; then
  NEW_CLI=1
else
  echo "! This api image predates the restore key check (1.3.1 or older) — using its older CLI."
fi
KEYCHECK_OUT="/app/backups/.restore-keycheck"

say "Phase 1: verify master key + extract host files, certificates"
# A previous, interrupted run may have left an extraction behind, and extracting
# over it would let a stale env/env from ANOTHER archive survive into the overlay.
"${COMPOSE[@]}" exec -T api sh -c 'rm -rf "$1"' sh "${RESTORE_OUT_CONTAINER}" \
  || fail "could not clear ${RESTORE_OUT_CONTAINER} in the api container — nothing has been changed."
EXTRACTED=1
if [ -n "${MASTER_KEY_ARG}" ] && [ "${NEW_CLI}" -eq 0 ]; then
  # Old images only: their CLI reads the key from argv and nowhere else, so for the
  # few seconds of phase 1 it is visible in the host's `ps`. The price of restoring
  # onto 1.3.1 or older at all; a current image never takes this branch.
  "${COMPOSE[@]}" exec -T api python -m app.scripts.restore host \
      "${ARCHIVE_IN_CONTAINER}" --out "${RESTORE_OUT_CONTAINER}" --master-key "${MASTER_KEY_ARG}" \
    || fail "phase 1 failed — nothing has been changed."
elif [ -n "${MASTER_KEY_ARG}" ]; then
  # `--master-key -`: the key on stdin, so it never appears in the host's `ps`.
  printf '%s\n' "${MASTER_KEY_ARG}" \
    | "${COMPOSE[@]}" exec -T api python -m app.scripts.restore host \
        "${ARCHIVE_IN_CONTAINER}" --out "${RESTORE_OUT_CONTAINER}" --master-key - \
    || fail "phase 1 failed — nothing has been changed."
else
  "${COMPOSE[@]}" exec -T api python -m app.scripts.restore host \
      "${ARCHIVE_IN_CONTAINER}" --out "${RESTORE_OUT_CONTAINER}" \
    || fail "phase 1 failed — nothing has been changed."
fi

# The env snapshot is read OUT of the container into memory — it holds the old
# host's secrets, and a copy on the host's disk is one more thing to forget to
# delete. Whether it exists is asked first, so a failed READ of one that does is
# an error, not the "this archive has no snapshot" explanation — that would leave
# the keys as deployed while saying the archive never had them.
ENV_SNAPSHOT=""
HAVE_SNAPSHOT=0
SNAPSHOT_IN_CONTAINER="${RESTORE_OUT_CONTAINER}/env/env"
if "${COMPOSE[@]}" exec -T api sh -c 'test -f "$1"' sh "${SNAPSHOT_IN_CONTAINER}" >/dev/null 2>&1; then
  ENV_SNAPSHOT="$("${COMPOSE[@]}" exec -T api sh -c 'cat "$1"' sh "${SNAPSHOT_IN_CONTAINER}")" \
    || fail "the archive's env snapshot is at ${SNAPSHOT_IN_CONTAINER} in the api container but could not be read — nothing has been changed."
  HAVE_SNAPSHOT=1
fi
# The archived value of one key — same reader as for .env.
snapshot_value() { printf '%s\n' "${ENV_SNAPSHOT}" | env_last_value "$1"; }

# ── Under HA the keys are the CLUSTER's, not this node's ────────────────────
# Every node carries the same MASTER_KEY, SECRET_KEY and paired API keys in its own
# .env. An archive cut before they were changed (rotate-key) would put the OLD ones
# into this node's .env only: the leader then runs on keys no other node holds, and
# the other nodes can neither read the restored secrets nor talk to it. Refused here,
# before .env is touched.
if [ "${RESTORE_HA}" -eq 1 ]; then
  differ=""
  for key in "${MANAGED_RECOVERY_KEYS[@]}"; do
    have="$(env_last_value "${key}" < "${ENV_FILE}")"
    want=""
    [ "${HAVE_SNAPSHOT}" -eq 1 ] && want="$(snapshot_value "${key}")"
    [ "${key}" = MASTER_KEY ] && [ -n "${MASTER_KEY_ARG}" ] && want="${MASTER_KEY_ARG}"
    if [ -n "${want}" ] && [ -n "${have}" ] && [ "${want}" != "${have}" ]; then
      differ="${differ:+${differ}, }${key}"
    fi
  done
  if [ -n "${differ}" ]; then
    fail "this archive was cut with other keys than this cluster runs now: ${differ}
  (the keys were changed after it — rotate-key, most likely). Under HA these keys are
  in every node's .env; restoring would change them on this node only, and the other
  nodes could no longer read the restored data or talk to this one. Nothing has been
  changed in ${ENV_FILE} or the database.
  · Restore an archive taken after the last key change, or
  · if this older archive is the one you need: bring the cluster down to this node
    first (./taranac cluster remove-node --node <each other node>, then ./ha-deconvert.sh),
    restore here, and build the cluster again from it (HA.md §3)."
  fi
fi

# ── Overlay the recovery keys onto THIS install's .env ──────────────────────
say "Overlaying the recovery keys onto ${ENV_FILE}"
# The copy is made BEFORE the first write, and its failure stops the restore:
# without it neither a failed write nor the key gate below could put .env back.
# Timestamped, so a second run never overwrites the first run's original.
PRE_RESTORE="${ENV_FILE}.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "${PRE_RESTORE}" ] || PRE_RESTORE="${PRE_RESTORE}.$$"   # a re-run within the same second
if ! cp -a "${ENV_FILE}" "${PRE_RESTORE}" || ! cmp -s "${ENV_FILE}" "${PRE_RESTORE}"; then
  rm -f "${PRE_RESTORE}" 2>/dev/null || true
  fail "could not keep a copy of ${ENV_FILE} as ${PRE_RESTORE} — nothing in ${ENV_FILE} has been changed. Is ${HERE} writable?"
fi
if [ "${HAVE_SNAPSHOT}" -eq 1 ]; then
  for key in "${MANAGED_RECOVERY_KEYS[@]}"; do
    if [ "${key}" = "MASTER_KEY" ] && [ -n "${MASTER_KEY_ARG}" ]; then
      continue   # --master-key was verified by phase 1; it is written below and wins
    fi
    value="$(snapshot_value "${key}")"
    if [ -z "${value}" ]; then
      echo "  - ${key}: absent from the archived env-file — left as deployed"
    else
      apply_env_value "${key}" "${value}" "restored from the archive"
    fi
  done
else
  echo "! This archive carries no env-file snapshot (taken before the host-files mount"
  echo "  was fixed, or with 'include host files' switched off), so SECRET_KEY and the"
  echo "  paired API keys stay as this install generated them:"
  echo "  * sessions signed before the disaster are simply invalid — users log in again;"
  echo "  * the report renderer needs nothing: the api and the renderer both read"
  echo "    REPORTS_RENDERER_API_KEY from ${ENV_FILE}, so they still agree;"
  echo "  * Push MFA may stop answering: the api's half of that pair is restored with the"
  echo "    database. If it does, set the MFA API key in the MFA provider settings in the"
  echo "    UI to TARANAC_MFA_API_KEY from ${ENV_FILE}."
fi
if [ -n "${MASTER_KEY_ARG}" ]; then
  apply_env_value MASTER_KEY "${MASTER_KEY_ARG}" "set from --master-key"
elif [ "${HAVE_SNAPSHOT}" -eq 0 ]; then
  echo "  - MASTER_KEY: kept as deployed (no --master-key given) — checked against the archive next"
fi
if [ "${ENV_CHANGED}" -eq 1 ]; then
  echo "  (previous file kept as ${PRE_RESTORE})"
else
  echo "  (nothing changed in ${ENV_FILE})"
  rm -f "${PRE_RESTORE}"; PRE_RESTORE=""
fi

# ── Gate: the key in .env must open this archive ────────────────────────────
# Everything after this point is irreversible: the certificates are overwritten,
# the dump is loaded with the key in the env-file, the daemons' key volume is
# cleared and the containers are recreated from that file. With the wrong key there
# phase 2 refuses, or worse loads data nothing can decrypt — on a stack this script
# has started to change. So the key phase 2 and the recreated containers WILL read
# is checked against the archive's canary NOW, on every path. It travels on stdin: an exec
# argument is visible to every user of the host in `ps`.
say "Checking that the master key in ${ENV_FILE} opens this archive"
ENV_KEY="$(env_last_value MASTER_KEY < "${ENV_FILE}")"
NOT_A_KEY="MASTER_KEY in ${ENV_FILE} is not a valid Fernet key (an inline comment? stray quotes?)"
MISMATCH="the master key in ${ENV_FILE} does not open this archive"
why=""
if [ -z "${ENV_KEY}" ]; then
  # Never handed on empty: an old image's `host --master-key ""` would fall back to
  # the key the api RUNS, and pass the gate on a key nothing will use after the
  # recreate.
  why="${NOT_A_KEY}"
elif [ "${NEW_CLI}" -eq 1 ]; then
  GATE_RC=0
  printf '%s\n' "${ENV_KEY}" \
    | "${COMPOSE[@]}" exec -T api python -m app.scripts.restore check-key "${ARCHIVE_IN_CONTAINER}" \
    || GATE_RC=$?
  # check-key's own codes, chosen so nothing else produces them: only those two
  # blame the key. Anything else is the check failing, not the key.
  case "${GATE_RC}" in
    0)  ;;
    10) why="${NOT_A_KEY}" ;;
    11) why="${MISMATCH}" ;;
    *)  why="could not check the master key against the archive (exit ${GATE_RC})" ;;
  esac
else
  # Old image: no check-key, so a full phase-1 extraction into a scratch directory
  # is the only way to ask. It decrypts the whole payload, so the removal runs in
  # the SAME container shell, on success and failure alike — nothing the host does
  # or fails to do afterwards can leave it behind. Key on argv: see phase 1.
  GATE_RC=0
  "${COMPOSE[@]}" exec -T api sh -c \
    'rm -rf "$2"; python -m app.scripts.restore host "$1" --out "$2" --master-key "$3" >/dev/null; rc=$?; rm -rf "$2"; exit $rc' \
    sh "${ARCHIVE_IN_CONTAINER}" "${KEYCHECK_OUT}" "${ENV_KEY}" \
    || GATE_RC=$?
  # The old CLI's codes: 2 the canary refused the key, 1 not a key (the archive
  # was found above). Anything else is the check failing.
  case "${GATE_RC}" in
    0) ;;
    1) why="${NOT_A_KEY}" ;;
    2) why="${MISMATCH}" ;;
    *) why="could not check the master key against the archive (exit ${GATE_RC})" ;;
  esac
fi
if [ -n "${why}" ]; then
  # The remedy is offered only when the KEY is what failed.
  remedy=" Pass the original key with --master-key."
  case "${why}" in could*) remedy=" Fix the cause above, then re-run." ;; esac
  if [ -n "${PRE_RESTORE}" ]; then
    kept="${PRE_RESTORE}"
    put_env_back \
      || fail "${why}; and ${ENV_FILE} could not be put back — the original is ${kept}. Copy it back before anything else."
    fail "${why} — ${ENV_FILE} put back, nothing else changed.${remedy}"
  fi
  fail "${why} — nothing has been changed.${remedy}"
fi

# ── Certificates + operator files ───────────────────────────────────────────
say "Restoring certificates into the taranac_certs volume"
"${COMPOSE[@]}" exec -T api sh -c \
  "cp -a ${RESTORE_OUT_CONTAINER}/certs/. /opt/taranac/certs/ 2>/dev/null || true"

HOST_CONFIG_IN_CONTAINER="${RESTORE_OUT_CONTAINER}/host_config"
if "${COMPOSE[@]}" exec -T api sh -c 'test -d "$1"' sh "${HOST_CONFIG_IN_CONTAINER}" >/dev/null 2>&1; then
  if [ -d ./config ]; then
    say "Restoring the operator's TLS certificate, Firebase key and etcd CA into ./config"
    # `SRC/.` copies the directory's CONTENTS into ./config, merging with what the
    # fresh install already has there.
    # Under the ordinary umask, not this script's 077: these files are read by the
    # api, and a bundle older than secure_host_config has nothing to repair them.
    ( umask 022; "${COMPOSE[@]}" cp "api:${HOST_CONFIG_IN_CONTAINER}/." ./config/ ) \
      || fail "could not copy host_config out of the api container into ./config."
    echo "  restored into ./config"
    # Re-apply the group the api needs, so THIS node's next backup carries them too.
    # The copy lands owned by whoever ran this script, which the api (uid 999) cannot
    # necessarily read. Getting this wrong is silent: the node comes up fine and its
    # archives quietly stop carrying the cluster CA. Optional: the env-secrets.sh of
    # a 1.2.2–1.2.7 bundle has no secure_host_config.
    if [ -f "${HERE}/env-secrets.sh" ]; then
      # shellcheck source=/dev/null
      . "${HERE}/env-secrets.sh" 2>/dev/null || true
    fi
    if type secure_host_config >/dev/null 2>&1; then secure_host_config "./config" || true; fi
  else
    echo
    echo "! The archive carries host_config/ (TLS cert / Firebase key) but this layout has"
    echo "  no ./config directory. It is in the api container at ${HOST_CONFIG_IN_CONTAINER};"
    echo "  fetch it with:"
    echo "    docker compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} cp api:${HOST_CONFIG_IN_CONTAINER}/. <destination>/"
    echo "  before this script finishes — it removes the extraction on success."
  fi
fi

# ── Phase 2: the database — BEFORE the api runs on the restored key ──────────
# The api's lifespan has a KEK gate (since 1.2.2): it decrypts the canary stored
# in the database with the key it was started with, and refuses to boot when that
# fails. Until the dump is loaded, the database holds the FRESH install's canary —
# so an api recreated with the restored key exits, the daemons that depend on it
# never start, and phase 2 run through `exec api` waits on a container that will
# never be there. The field shape exactly: "taranac-api is unhealthy … the stack
# did not come back up". So the dump goes in first, from a one-off container: the
# image's entrypoint (certs, chown, migrations) and then the restore CLI — never
# the app, so no gate. It reads .env as it is NOW (the restored key), and mounts
# the same volumes as the api (the archive, the daemon config volumes the
# regeneration writes into).
say "Phase 2: load the configuration dump (DESTRUCTIVE — replaces current config)"

# health_of <service> → healthy | unhealthy | starting | none | absent
health_of() {
  local id
  id="$("${COMPOSE[@]}" ps -q "$1" 2>/dev/null || true)"
  [ -n "${id}" ] || { echo absent; return 0; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${id}" 2>/dev/null || echo absent
}
# wait_healthy <service> — up to ~3 minutes. A service with no healthcheck counts
# as up once it runs.
wait_healthy() {
  local h
  for _ in $(seq 1 90); do
    h="$(health_of "$1")"
    case "${h}" in healthy|none) return 0 ;; esac
    sleep 2
  done
  return 1
}

# Only the database has to be up. --no-recreate: start it if it is stopped, never
# rebuild it — its data is what is being restored into, and under HA it is the
# Patroni-managed primary (same service name in the overlay).
"${COMPOSE[@]}" up -d --no-recreate postgres \
  || fail "could not start the database service — nothing has been loaded and the running stack is untouched. ${ENV_FILE} already holds the restored keys; re-run once the database is up."
wait_healthy postgres \
  || fail "the database did not become healthy — nothing has been loaded and the running stack is untouched. Look at: ./taranac logs postgres --tail 50, then re-run."

# The old api is STOPPED for the load, not left running beside it. It runs on the
# fresh key, and anything that reaches it once the dump is in — a collector pushing
# a snapshot with a token that is valid again, an EST enrollment, an admin saving a
# secret — would write ciphertext under that key into the restored database:
# undecryptable after the recreate, and silently so. Stopping it also frees its
# address on the project network for the one-off container.
PROJECT="$("${COMPOSE[@]}" config 2>/dev/null | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d "\"'")"
PROJECT="${PROJECT:-${COMPOSE_PROJECT_NAME:-$(basename "${HERE}")}}"
# One-off api containers an interrupted attempt left behind hold an address too.
STALE_RUNS="$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}" \
               --filter "label=com.docker.compose.service=api" \
               --filter "label=com.docker.compose.oneoff=True" 2>/dev/null || true)"
if [ -n "${STALE_RUNS}" ]; then
  # shellcheck disable=SC2086  # one id per word, on purpose
  docker rm -f ${STALE_RUNS} >/dev/null 2>&1 || true
fi
# The key the api RUNS on — the one the database's canary belongs to until the dump
# is in. Read from the container, not from a file: on a re-run .env already holds
# the restored key while the old container still runs the fresh one.
API_ID="$("${COMPOSE[@]}" ps -q api 2>/dev/null || true)"
OLD_KEY=""
[ -z "${API_ID}" ] || OLD_KEY="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${API_ID}" 2>/dev/null \
                                 | env_last_value MASTER_KEY)"
[ -n "${OLD_KEY}" ] || OLD_KEY="$(env_last_value MASTER_KEY < "${PRE_RESTORE:-${ENV_FILE}}")"
"${COMPOSE[@]}" stop api \
  || fail "could not stop the api for the load — nothing has been loaded. Re-run once './taranac stop api' works."
DB_ARGS=()
[ "${ASSUME_YES}" -eq 1 ] && DB_ARGS=(--yes)
P2_RC=0
"${COMPOSE[@]}" run --rm --no-deps -T api python -m app.scripts.restore db "${ARCHIVE_IN_CONTAINER}" "${DB_ARGS[@]}" \
  || P2_RC=$?

if [ "${P2_RC}" -ne 0 ]; then
  # Did the dump get in? The exit code alone cannot say: an image older than this
  # release exits non-zero when its audit record fails AFTER the load committed.
  # The database can: its canary is the archive's (decrypts with the restored key)
  # once the load committed, and still the fresh install's if it rolled back.
  RERUN_NOTE="${ENV_FILE} already holds the restored keys; re-run this restore once the cause is fixed — the load truncates and reloads, so running it again is safe."
  if [ "${OLD_KEY}" = "${ENV_KEY}" ]; then
    # Same key before and after: the canary cannot tell the two apart. Either way
    # the old api boots on this database, so it is brought back.
    "${COMPOSE[@]}" start api >/dev/null 2>&1 || true
    fail "phase 2 failed (exit ${P2_RC}). This install already ran on the archive's key, so whether the data was loaded cannot be told from it; the api has been started again. ${RERUN_NOTE}"
  fi
  PROBE_RC=0
  "${COMPOSE[@]}" run --rm --no-deps -T api python -c '
import asyncio, sys
from sqlalchemy import text
from app.config import settings
from app.core.crypto import KEK_CANARY_KEY, KEK_CANARY_PLAINTEXT, fernet_decrypt, get_master_key, load_master_key
from app.database import async_session_factory

async def main() -> int:
    load_master_key(settings)
    async with async_session_factory() as session:
        row = (await session.execute(text("SELECT value FROM system_settings WHERE key = :k"), {"k": KEK_CANARY_KEY})).scalar_one_or_none()
    if not row:
        return 3
    try:
        return 0 if fernet_decrypt(row.encode(), get_master_key()) == KEK_CANARY_PLAINTEXT else 4
    except Exception:
        return 4

sys.exit(asyncio.run(main()))
' >/dev/null 2>&1 || PROBE_RC=$?
  case "${PROBE_RC}" in
    0)
      echo "! phase 2 reported an error after loading the data (exit ${P2_RC}) — the database carries"
      echo "  the archive's key canary, so the load committed. Continuing; check the output above"
      echo "  (an older image fails like this when only its audit record could not be written)." ;;
    4)
      "${COMPOSE[@]}" start api >/dev/null 2>&1 \
        || fail "phase 2 failed (exit ${P2_RC}) and nothing was loaded, but the api could not be started again: ./taranac start api. ${RERUN_NOTE}"
      # 4 is restore.py's EXIT_ABORTED — a "no" at the confirmation prompt. Trusted
      # only here, after the probe proved nothing was loaded: older images can exit 4
      # for other reasons too.
      [ "${P2_RC}" -eq 4 ] \
        && fail "phase 2 aborted at the confirmation prompt — nothing was loaded and the api has been started again. ${RERUN_NOTE}"
      fail "phase 2 failed (exit ${P2_RC}) — nothing was loaded (the database still carries the previous key's canary) and the api has been started again. ${RERUN_NOTE}" ;;
    *)
      fail "phase 2 failed (exit ${P2_RC}), and checking whether it loaded the data failed too (exit ${PROBE_RC}). The api is stopped. Do not guess:
    * if the data WAS loaded, the api only starts on the restored key — finish with: ./taranac up -d --force-recreate
    * if it was NOT, the api starts as it was — ./taranac start api — then re-run this restore.
  Which one: ./taranac logs postgres --tail 50, and the phase 2 output above." ;;
  esac
fi

# The database is restored from here on: putting the previous .env back would now
# be WRONG (its key no longer opens the data), so every failure below says so.
NOT_BACK="The database is already restored, so do NOT put the previous env-file back — it holds the fresh install's key, which no longer opens the data."

# ── Reconcile the daemons' master_key volume ────────────────────────────────
# tacacs/radius/nac read the KEK from a FILE in the shared master_key volume, and
# their entrypoint provisions it ABSENT-ONLY — an existing file is never updated.
# A fresh install has already pinned its OWN generated key there, so without this
# the daemons would decrypt device secrets with the wrong key while the api is
# fine: enable-password and shared-secret reads fail on a system that otherwise
# looks healthy. Same reconciliation ha-join.sh does when a node joins a cluster.
say "Reconciling the daemons' master_key volume"
# Resolved from compose's own labels, not from a running daemon: a daemon stuck
# behind an unhealthy api (an earlier attempt) is exactly when the stale key is
# there, and "no tacacs container" used to read as "nothing to reconcile".
MK_VOL="$(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" \
            --filter "label=com.docker.compose.volume=master_key" 2>/dev/null | head -1 || true)"
if [ -z "${MK_VOL}" ] && docker volume inspect "${PROJECT}_master_key" >/dev/null 2>&1; then
  MK_VOL="${PROJECT}_master_key"
fi
if [ -n "${MK_VOL}" ]; then
  docker run --rm -v "${MK_VOL}:/d" busybox rm -f /d/master_key \
    || fail "could not clear the stale master key from ${MK_VOL}. The database is restored but the stack is not recreated yet. Finish by hand:
    docker run --rm -v ${MK_VOL}:/d busybox rm -f /d/master_key
    ./taranac up -d --force-recreate
  ${NOT_BACK}"
  echo "  cleared ${MK_VOL} — the daemon entrypoints will adopt the restored MASTER_KEY on the next start."
else
  echo "  this node has no master_key volume (no daemons deployed) — nothing to reconcile."
  echo "  If they are added later, clear their master_key volume once so the entrypoint"
  echo "  adopts the restored MASTER_KEY (it provisions absent-only and never updates)."
fi

# ── Recreate the stack with the restored secrets ────────────────────────────
say "Recreating the services that read the restored secrets"
# Only the containers whose environment or key volume changed. Postgres (and etcd
# under HA) are deliberately left alone: their data has just been restored, and
# force-recreating a Patroni-managed primary mid-recovery would invite a leader
# election at the worst possible moment. Intersected with the compose file's own
# service list so a layout without, say, the renderer does not error out.
SERVICES="$("${COMPOSE[@]}" config --services)"
TARGETS=()
for svc in api tacacs radius nac taranac-mfa taranac-renderer; do
  printf '%s\n' "${SERVICES}" | grep -qx "${svc}" && TARGETS+=("${svc}")
done
LOOK="Look at: ./taranac logs api --tail 50"
"${COMPOSE[@]}" up -d --force-recreate "${TARGETS[@]}" \
  || fail "the stack did not come back up with the restored key. ${NOT_BACK} ${LOOK}"
# By the container's HEALTH, not by an import: the KEK gate runs in the app's
# lifespan, so an api in a crash loop imports fine and is still down.
echo "  waiting for the api to become healthy…"
wait_healthy api \
  || fail "the api did not become healthy with the restored key (it is $(health_of api)). ${NOT_BACK} ${LOOK}"

say "Restarting every service so it re-reads the restored configuration"
"${COMPOSE[@]}" restart

# The extraction holds the old host's secrets in clear. Nothing needs it any more.
if "${COMPOSE[@]}" exec -T api sh -c 'rm -rf "$1"' sh "${RESTORE_OUT_CONTAINER}"; then
  EXTRACTED=0
  CLEANUP_NOTE="The extracted archive (decrypted secrets) has been removed from the backups volume."
else
  CLEANUP_NOTE="Could not remove ${RESTORE_OUT_CONTAINER} (decrypted secrets) from the backups volume — do it by hand:
    ./taranac exec -T api rm -rf ${RESTORE_OUT_CONTAINER}"
fi
PRE_RESTORE_NOTE=""
[ -z "${PRE_RESTORE}" ] || PRE_RESTORE_NOTE="
The previous env-file is kept at ${PRE_RESTORE}."

cat <<EOF

✓ Recovery complete.

Verify by VERDICT, not by the absence of errors in a log:
  * log in to the UI with a pre-disaster account;
  * authenticate a real device over TACACS+ (proves the device shared secret
    survived — it is Fernet ciphertext in the dump, decrypted with the key you
    just restored);
  * authenticate a real endpoint over 802.1X (proves the PKI survived).

Two things this archive deliberately does not carry:
  * MFA enrollments — taranac-mfa has its own database and its own crypto.
    Users with Push/TOTP re-enroll unless you protected that side separately.
  * The Active Directory machine account — Samba rotates its password weekly, so a
    restored one would be a broken trust. Re-join the domain from
    System → Authentication if MS-CHAPv2 is used.

${CLEANUP_NOTE}${PRE_RESTORE_NOTE}
EOF
