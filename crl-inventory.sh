#!/bin/sh
# =============================================================================
# crl-inventory.sh — what is in an EAP-TLS CRL directory, one fact per line.
#
#   docker exec -i taranac-nac sh -s -- /etc/raddb/certs/crl --serials --radiusd < crl-inventory.sh
#
# Run INSIDE the nac container by diagnose.sh (and by diagnose-ha.sh, for the
# per-node fingerprints), fed on stdin, so the bundle never has to put a script
# into a container. It reads the directory FreeRADIUS actually loads — not the
# api's view of the same volume — because a revocation that "is in the database
# but did not apply" lives exactly in the gap between those two.
#
# POSIX sh + openssl + sha256sum + stat + readlink only: the nac image is Alpine
# with busybox, no GNU options. The same script runs on a host against a fixture
# directory in deploy/dist/tests/test_diagnose.sh.
#
# Output: tab-separated records, the first field names the record —
#   NOW      <epoch>
#   DIR      <path> <present|missing>
#   RADIUSD  <pid> <seconds since start>                  (--radiusd, when running)
#   LINK     <name> <target> <ok|broken>
#   FILE     <name> <size> <mtime epoch> <sha256 of the file>
#   CERT     <name> <subject> <issuer> <subject hash> <notAfter>
#   CRL      <name> <issuer> <issuer hash> <lastUpdate> <nextUpdate> <crlNumber> <revoked> <sha256 of DER> <verify>
#            verify: ok:<cert file> | fail | no-ca (no cert file of that subject hash)
#   SERIALS  listed                                       (--serials: REVOKED lines are complete)
#   REVOKED  <name> <serial, lowercase hex, no leading 0> (--serials)
#   SKIP     <name> <reason>
#
# NOTHING SECRET IS READ OUT. Only certificates and CRLs are described; a file
# carrying a private key is reported by name as SKIP and never opened past that
# check. Server keys do not live here (certs/nac/), but the check does not rely
# on that.
# =============================================================================
DIR="${1:-/etc/raddb/certs/crl}"
shift 2>/dev/null || true
SERIALS=""
RADIUSD=""
for a in "$@"; do
  case "${a}" in
    --serials) SERIALS=1 ;;
    --radiusd) RADIUSD=1 ;;
  esac
done

rec() {  # fields… → one tab-separated line
  _first=1
  for _f in "$@"; do
    if [ -n "${_first}" ]; then printf '%s' "${_f}"; _first=""; else printf '\t%s' "${_f}"; fi
  done
  printf '\n'
}

rec NOW "$(date +%s)"
[ -n "${SERIALS}" ] && rec SERIALS listed

# radiusd's age: /proc/<pid>/stat field 22 (starttime, clock ticks since boot)
# against /proc/uptime. The comm field "(radiusd)" has no space, so the fields
# split cleanly. No `ps -o etimes`: busybox has no such column.
if [ -n "${RADIUSD}" ]; then
  pid="$(pidof radiusd 2>/dev/null | awk '{print $NF}')"
  if [ -n "${pid}" ] && [ -r "/proc/${pid}/stat" ] && [ -r /proc/uptime ]; then
    tck="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    case "${tck}" in ''|*[!0-9]*) tck=100 ;; esac
    age="$(awk -v t="${tck}" 'NR==FNR { up = $1; next } { printf "%d", up - $22 / t }' /proc/uptime "/proc/${pid}/stat")"
    rec RADIUSD "${pid}" "${age}"
  fi
fi

if [ ! -d "${DIR}" ]; then
  rec DIR "${DIR}" missing
  exit 0
fi
rec DIR "${DIR}" present

field() {  # <openssl output> <prefix> → value after the first '='
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# Sorted, dotfiles excluded (the api's temp files start with '.').
ls -1 "${DIR}" 2>/dev/null | LC_ALL=C sort | while IFS= read -r name; do
  [ -n "${name}" ] || continue
  path="${DIR}/${name}"
  if [ -L "${path}" ]; then
    target="$(readlink "${path}" 2>/dev/null)"
    if [ -f "${path}" ]; then state=ok; else state=broken; fi
    rec LINK "${name}" "${target}" "${state}"
    continue
  fi
  [ -f "${path}" ] || continue
  if grep -q "PRIVATE KEY" "${path}" 2>/dev/null; then
    rec SKIP "${name}" "carries a private key — not described, not copied"
    continue
  fi
  size="$(stat -c %s "${path}" 2>/dev/null || echo 0)"
  mtime="$(stat -c %Y "${path}" 2>/dev/null || echo 0)"
  sum="$(sha256sum "${path}" 2>/dev/null | cut -d' ' -f1)"
  rec FILE "${name}" "${size}" "${mtime}" "${sum}"

  inform=PEM
  grep -q -- "-----BEGIN" "${path}" 2>/dev/null || inform=DER
  described=""

  if [ "${inform}" = DER ] || grep -q -- "-----BEGIN X509 CRL-----" "${path}" 2>/dev/null; then
    out="$(openssl crl -inform "${inform}" -in "${path}" -noout -nameopt RFC2253 \
             -issuer -lastupdate -nextupdate -crlnumber -hash 2>/dev/null)"
    if [ -n "${out}" ]; then
      described=1
      issuer="$(field "${out}" issuer)"
      last="$(field "${out}" lastUpdate)"
      next="$(field "${out}" nextUpdate)"
      number="$(field "${out}" crlNumber)"
      hash="$(field "${out}" 'issuer name hash')"
      text="$(openssl crl -inform "${inform}" -in "${path}" -noout -text 2>/dev/null)"
      revoked="$(printf '%s\n' "${text}" | grep -c 'Serial Number:')"
      der="$(openssl crl -inform "${inform}" -in "${path}" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
      # Which CA certificate in this directory verifies the signature — the one
      # FreeRADIUS would use. Candidates: certificate files of the same subject
      # hash as the CRL's issuer hash.
      verify=no-ca
      for cand in $(ls -1 "${DIR}" | LC_ALL=C sort); do
        cpath="${DIR}/${cand}"
        [ -f "${cpath}" ] && [ ! -L "${cpath}" ] || continue
        grep -q -- "-----BEGIN CERTIFICATE-----" "${cpath}" 2>/dev/null || continue
        grep -q "PRIVATE KEY" "${cpath}" 2>/dev/null && continue
        chash="$(openssl x509 -in "${cpath}" -noout -subject_hash 2>/dev/null)"
        [ "${chash}" = "${hash}" ] || continue
        # The exit status says nothing: `openssl crl -CAfile` prints "verify failure"
        # and still exits 0 (3.0 and 3.3 alike). Only the words are the answer.
        if openssl crl -inform "${inform}" -in "${path}" -CAfile "${cpath}" -noout 2>&1 | grep -q "verify OK"; then
          verify="ok:${cand}"
          break
        fi
        verify=fail
      done
      rec CRL "${name}" "${issuer}" "${hash}" "${last}" "${next}" "${number:-<NONE>}" "${revoked}" "${der}" "${verify}"
      if [ -n "${SERIALS}" ]; then
        printf '%s\n' "${text}" | sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' \
          | tr 'A-F' 'a-f' | sed 's/^0*//' | while IFS= read -r serial; do
            rec REVOKED "${name}" "${serial}"
          done
      fi
    fi
  fi

  if grep -q -- "-----BEGIN CERTIFICATE-----" "${path}" 2>/dev/null; then
    out="$(openssl x509 -in "${path}" -noout -nameopt RFC2253 -subject -issuer -enddate 2>/dev/null)"
    if [ -n "${out}" ]; then
      described=1
      shash="$(openssl x509 -in "${path}" -noout -subject_hash 2>/dev/null)"
      rec CERT "${name}" "$(field "${out}" subject)" "$(field "${out}" issuer)" "${shash}" "$(field "${out}" notAfter)"
    fi
  fi

  [ -n "${described}" ] || rec SKIP "${name}" "neither a certificate nor a CRL openssl can read"
done
