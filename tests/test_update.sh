#!/usr/bin/env bash
# =============================================================================
# Real end-to-end test for the bundle self-updater (taranac-update.sh).
#
# This is deliberately NOT mocked: it builds a real bundle tarball, serves a
# real GitHub-Releases-shaped layout over a real local HTTP server, and runs the
# real updater against a real "installed" bundle directory. The ONLY part not
# exercised is the final `docker compose pull/up` (gated behind --no-restart),
# because that needs the registry + Docker daemon; everything else — version
# discovery, download, checksum verification, file swap, .env preservation,
# backup, version bump, new-key diff — runs for real and is asserted.
#
# Run:  bash deploy/dist/tests/test_update.sh
# =============================================================================
set -euo pipefail

DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 — [$2]"; fi; }

NEW_VER="1.0.0-rc2"
OLD_VER="1.0.0-rc1"

FRAMEWORK=(taranac taranac-update.sh docker-compose.yml install.sh bootstrap.sh INSTALL.md README.md .env.example VERSION postgres-initdb docker-compose.ha.yml docker-compose.witness.yml ha-convert.sh ha-join.sh HA.md)

# ── 1. Build a realistic "new" bundle tarball from the real dist files ───────
echo "==> Building bundle tarball (mirrors what release.yml ships)"
# Stage into a versioned top-level dir, exactly like build-bundle.sh / release.yml
# ship it, so this run also exercises the updater's top-level-dir normalisation
# (taranac-update.sh strips the single wrapping folder on extract).
PREFIX="taranac-${NEW_VER}"
BUNDLE_SRC="${WORK}/bundle-src/${PREFIX}"
mkdir -p "${BUNDLE_SRC}"
for f in "${FRAMEWORK[@]}"; do cp -a "${DIST_DIR}/${f}" "${BUNDLE_SRC}/"; done
printf '%s\n' "${NEW_VER}" > "${BUNDLE_SRC}/VERSION"
TARBALL="taranac-bundle-${NEW_VER}.tar.gz"
( cd "${WORK}/bundle-src" && tar -czf "${WORK}/${TARBALL}" "${PREFIX}" )
( cd "${WORK}" && sha256sum "${TARBALL}" > SHA256SUMS )

# ── 2. Serve a GitHub-Releases-shaped layout over real HTTP ──────────────────
echo "==> Starting local release server"
SRV_ROOT="${WORK}/srv"
mkdir -p "${SRV_ROOT}/v${NEW_VER}"
printf '{"tag_name": "v%s", "name": "release"}\n' "${NEW_VER}" > "${SRV_ROOT}/latest.json"
cp "${WORK}/${TARBALL}" "${SRV_ROOT}/v${NEW_VER}/"
cp "${WORK}/SHA256SUMS" "${SRV_ROOT}/v${NEW_VER}/"
# Bind an ephemeral port, print it, then serve — captured below.
exec 3< <(cd "${SRV_ROOT}" && python3 -c '
import http.server, socketserver, sys
h = http.server.SimpleHTTPRequestHandler
class Q(socketserver.TCPServer):
    allow_reuse_address = True
with Q(("127.0.0.1", 0), h) as s:
    print(s.server_address[1], flush=True)
    s.serve_forever()
' 2>/dev/null)
SERVER_PID=$!
read -r PORT <&3
[ -n "${PORT}" ] || { echo "server failed to start"; exit 1; }
BASE="http://127.0.0.1:${PORT}"
echo "    serving on ${BASE} (pid ${SERVER_PID})"

# ── 3. Lay down a realistic "installed" (old) bundle ─────────────────────────
echo "==> Creating an installed bundle at old version ${OLD_VER}"
INST="${WORK}/installed"
mkdir -p "${INST}/config/tls" "${INST}/postgres-initdb"
# Old framework files: use a deliberately OLD wrapper + OLD .env.example to prove
# they get replaced. Real taranac-update.sh is copied so the updater can run.
cp -a "${DIST_DIR}/taranac-update.sh" "${INST}/"
cp -a "${DIST_DIR}/docker-compose.yml" "${INST}/"
cp -a "${DIST_DIR}/install.sh" "${INST}/"
cp -a "${DIST_DIR}/bootstrap.sh" "${INST}/"
cp -a "${DIST_DIR}/INSTALL.md" "${INST}/README.md"   # placeholder old content
cp -a "${DIST_DIR}/INSTALL.md" "${INST}/"
cp -a "${DIST_DIR}/postgres-initdb/." "${INST}/postgres-initdb/"
printf '#!/usr/bin/env bash\n# OLD wrapper without unlock/update\nexec docker compose "$@"\n' > "${INST}/taranac"
printf 'IMAGE_PREFIX=ghcr.io/x/taranac\nTARANAC_VERSION=%s\nMAX_LOGIN_ATTEMPTS=5\n' "${OLD_VER}" > "${INST}/.env.example"
printf '%s\n' "${OLD_VER}" > "${INST}/VERSION"
# Operator state that MUST be preserved untouched:
SECRET_MASTER="MASTER_KEY=super-secret-do-not-touch-$(date +%s 2>/dev/null || echo x)"
cat > "${INST}/.env" <<EOF
IMAGE_PREFIX=ghcr.io/taranaclabs/taranac
TARANAC_VERSION=${OLD_VER}
APP_VERSION=${OLD_VER}
POSTGRES_PASSWORD=operator-db-password
${SECRET_MASTER}
TRUSTED_PROXY_HOPS=2
EOF
echo "OPERATOR-CERT-CONTENT" > "${INST}/config/tls/tls.crt"
ENV_BEFORE="$(cat "${INST}/.env")"

# ── 4. Run the REAL updater over the online path (only restart stubbed) ──────
echo "==> Running: taranac-update.sh update (online path, --no-restart)"
UPDATE_OUT="${WORK}/update.out"
TARANAC_RELEASE_API="${BASE}/latest.json" \
TARANAC_RELEASE_DL_BASE="${BASE}" \
  bash "${INST}/taranac-update.sh" update --yes --no-restart > "${UPDATE_OUT}" 2>&1 \
  || { echo "updater exited non-zero:"; cat "${UPDATE_OUT}"; exit 1; }
sed 's/^/    /' "${UPDATE_OUT}"

echo "==> Assertions"
check "wrapper replaced with new one (has 'unlock')"        "grep -q 'unlock' '${INST}/taranac'"
check "wrapper has new 'update' subcommand"                  "grep -q 'taranac-update.sh' '${INST}/taranac'"
check ".env.example replaced (has TRUSTED_PROXY_HOPS)"       "grep -q 'TRUSTED_PROXY_HOPS' '${INST}/.env.example'"
check "VERSION bumped to ${NEW_VER}"                         "[ \"\$(cat '${INST}/VERSION')\" = '${NEW_VER}' ]"
check ".env TARANAC_VERSION bumped"                          "grep -q '^TARANAC_VERSION=${NEW_VER}\$' '${INST}/.env'"
check ".env APP_VERSION bumped"                              "grep -q '^APP_VERSION=${NEW_VER}\$' '${INST}/.env'"
check ".env MASTER_KEY preserved"                            "grep -qF '${SECRET_MASTER}' '${INST}/.env'"
check ".env POSTGRES_PASSWORD preserved"                     "grep -q '^POSTGRES_PASSWORD=operator-db-password\$' '${INST}/.env'"
check ".env TRUSTED_PROXY_HOPS (operator value) preserved"   "grep -q '^TRUSTED_PROXY_HOPS=2\$' '${INST}/.env'"
check "operator TLS cert untouched"                          "[ \"\$(cat '${INST}/config/tls/tls.crt')\" = 'OPERATOR-CERT-CONTENT' ]"
check "HA overlay refreshed into the bundle (framework file)"     "[ -f '${INST}/docker-compose.ha.yml' ]"
check "HA runbook refreshed into the bundle (framework file)"     "[ -f '${INST}/HA.md' ]"
check "ha-convert.sh refreshed + executable"                      "[ -x '${INST}/ha-convert.sh' ]"
check "backup directory created"                             "ls -d '${INST}'/.taranac-backup-* >/dev/null 2>&1"
check "backup holds the OLD wrapper"                         "grep -rq 'OLD wrapper' '${INST}'/.taranac-backup-*/taranac"
# The new-key diff lists keys the operator LACKS; keys they already have must be
# excluded. The bare key is printed indented (^ +KEY$); the explanatory notice
# uses 'TRUSTED_PROXY_HOPS=2' so it won't match the anchored bare form.
check "present key TRUSTED_PROXY_HOPS excluded from new-key diff"  "! grep -qE '^ +TRUSTED_PROXY_HOPS\$' '${UPDATE_OUT}'"
check "present key POSTGRES_PASSWORD excluded from new-key diff"   "! grep -qE '^ +POSTGRES_PASSWORD\$' '${UPDATE_OUT}'"

# ── 5. New-key diff DOES fire when operator .env lacks a new setting ──────────
echo "==> Sub-case: operator .env missing a new setting -> diff warns"
# Remove TRUSTED_PROXY_HOPS from .env, re-run apply only (idempotent re-run).
grep -v '^TRUSTED_PROXY_HOPS=' "${INST}/.env" > "${INST}/.env.tmp" && mv "${INST}/.env.tmp" "${INST}/.env"
DIFF_OUT="${WORK}/diff.out"
TARANAC_RELEASE_API="${BASE}/latest.json" TARANAC_RELEASE_DL_BASE="${BASE}" \
  bash "${INST}/taranac-update.sh" update --version "${NEW_VER}" --yes --no-restart > "${DIFF_OUT}" 2>&1 || true
check "diff warns about missing TRUSTED_PROXY_HOPS"          "grep -q 'TRUSTED_PROXY_HOPS' '${DIFF_OUT}' && grep -q 'New settings exist' '${DIFF_OUT}'"

# ── 6. Offline version check is a NOTICE, not an error ───────────────────────
echo "==> Sub-case: offline 'version' check exits 0 with a notice"
OFFLINE_OUT="${WORK}/offline.out"
set +e
TARANAC_RELEASE_API="http://127.0.0.1:1/nope" TARANAC_CURL_TIMEOUT=2 \
  bash "${INST}/taranac-update.sh" version > "${OFFLINE_OUT}" 2>&1
rc=$?
set -e
sed 's/^/    /' "${OFFLINE_OUT}"
check "offline check exit code is 0"                         "[ ${rc} -eq 0 ]"
check "offline check prints a non-error notice"             "grep -qi 'Could not check for updates' '${OFFLINE_OUT}'"

# ── 6b. The wrapper routes `version` to the updater (real wiring) ─────────────
echo "==> Sub-case: ./taranac version routes through the wrapper"
WRAP_OUT="${WORK}/wrap.out"
set +e
TARANAC_RELEASE_API="http://127.0.0.1:1/nope" TARANAC_CURL_TIMEOUT=2 \
  bash "${INST}/taranac" version > "${WRAP_OUT}" 2>&1
wrc=$?
set -e
check "wrapper 'version' exits 0 offline"                    "[ ${wrc} -eq 0 ]"
check "wrapper 'version' reports installed version"          "grep -qi 'Installed version' '${WRAP_OUT}'"

# ── 6c. Wrapper compose passthrough + unlock routing (stub docker on PATH) ───
# Guards the "exec cannot run a shell function" regression: the wrapper must
# `exec docker compose …` (a real binary), not `exec compose …` (a function).
echo "==> Sub-case: ./taranac forwards to 'docker compose' (no exec-function bug)"
BIN="${WORK}/bin"; mkdir -p "${BIN}"
DOCKER_LOG="${WORK}/docker.log"; : > "${DOCKER_LOG}"
cat > "${BIN}/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${DOCKER_LOG}"
EOF
chmod +x "${BIN}/docker"
ROUTE_OUT="${WORK}/route.out"
PATH="${BIN}:${PATH}" bash "${INST}/taranac" ps                    > "${ROUTE_OUT}" 2>&1 || true
PATH="${BIN}:${PATH}" bash "${INST}/taranac" unlock admin         >> "${ROUTE_OUT}" 2>&1 || true
PATH="${BIN}:${PATH}" bash "${INST}/taranac" reset-password admin >> "${ROUTE_OUT}" 2>&1 || true
PATH="${BIN}:${PATH}" bash "${INST}/taranac" create-admin ops      >> "${ROUTE_OUT}" 2>&1 || true
check "no 'compose: not found' regression"                  "! grep -qi 'compose: not found' '${ROUTE_OUT}'"
check "passthrough forwards 'ps' to docker compose"         "grep -q 'compose --env-file .env -f docker-compose.yml ps' '${DOCKER_LOG}'"
check "unlock routes to the api unlock script"              "grep -q 'exec -T api python -m app.scripts.unlock_user admin' '${DOCKER_LOG}'"
check "reset-password routes to the api reset script"       "grep -q 'exec -T api python -m app.scripts.reset_password admin' '${DOCKER_LOG}'"
check "create-admin routes to the api create-admin script"  "grep -q 'exec -T api python -m app.scripts.create_admin ops' '${DOCKER_LOG}'"

# ── 7. Checksum mismatch aborts WITHOUT mutating the bundle ──────────────────
echo "==> Sub-case: corrupted bundle fails checksum and changes nothing"
BADROOT="${WORK}/badsrv"; mkdir -p "${BADROOT}/v${NEW_VER}"
printf '{"tag_name": "v%s"}\n' "${NEW_VER}" > "${BADROOT}/latest.json"
cp "${WORK}/SHA256SUMS" "${BADROOT}/v${NEW_VER}/"          # correct sums...
printf 'CORRUPTED' > "${BADROOT}/v${NEW_VER}/${TARBALL}"   # ...but wrong tarball
exec 4< <(cd "${BADROOT}" && python3 -c '
import http.server, socketserver
class Q(socketserver.TCPServer):
    allow_reuse_address = True
with Q(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler) as s:
    print(s.server_address[1], flush=True); s.serve_forever()
' 2>/dev/null)
BADPID=$!; read -r BADPORT <&4
WRAPPER_BEFORE="$(cat "${INST}/taranac")"
set +e
TARANAC_RELEASE_API="http://127.0.0.1:${BADPORT}/latest.json" TARANAC_RELEASE_DL_BASE="http://127.0.0.1:${BADPORT}" \
  bash "${INST}/taranac-update.sh" update --version "${NEW_VER}" --yes --no-restart > "${WORK}/bad.out" 2>&1
badrc=$?
set -e
kill "${BADPID}" 2>/dev/null || true
check "corrupted update exits non-zero"                     "[ ${badrc} -ne 0 ]"
check "checksum failure reported"                           "grep -qi 'Checksum verification FAILED' '${WORK}/bad.out'"
check "bundle wrapper unchanged after failed update"        "[ \"\$(cat '${INST}/taranac')\" = \"\${WRAPPER_BEFORE}\" ]"

# ── 8. Unreachable bundle -> graceful IMAGES-ONLY fallback (not a hard fail) ──
# The images live on a separate (public) channel from the bundle; a 404 on the
# bundle must NOT block the image update. Request a version the server has no
# bundle for -> download returns "unreachable" -> updater bumps the pinned
# version and would pull, instead of dying.
echo "==> Sub-case: unreachable bundle falls back to images-only (version still bumps)"
IO_OUT="${WORK}/imagesonly.out"
MASTER_BEFORE="$(grep '^MASTER_KEY=' "${INST}/.env")"
WRAP_IO_BEFORE="$(cat "${INST}/taranac")"
set +e
TARANAC_RELEASE_API="${BASE}/latest.json" TARANAC_RELEASE_DL_BASE="${BASE}" \
  bash "${INST}/taranac-update.sh" update --version 9.9.9-missing --yes --no-restart > "${IO_OUT}" 2>&1
iorc=$?
set -e
sed 's/^/    /' "${IO_OUT}"
check "images-only fallback exits 0 (no hard fail)"          "[ ${iorc} -eq 0 ]"
check "output warns it is an IMAGES-ONLY update"             "grep -qi 'IMAGES-ONLY' '${IO_OUT}'"
check ".env TARANAC_VERSION bumped despite missing bundle"   "grep -q '^TARANAC_VERSION=9.9.9-missing\$' '${INST}/.env'"
check "operator MASTER_KEY still preserved"                  "grep -qF \"\${MASTER_BEFORE}\" '${INST}/.env'"
check "framework wrapper NOT refreshed in images-only mode"  "[ \"\$(cat '${INST}/taranac')\" = \"\${WRAP_IO_BEFORE}\" ]"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "============================================="
printf 'RESULT: %d passed, %d failed\n' "${pass}" "${fail}"
echo "============================================="
[ "${fail}" -eq 0 ]
