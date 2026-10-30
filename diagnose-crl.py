#!/usr/bin/env python3
"""The EAP-TLS revocation half of ``diagnose --protocol nac``: is a CRL applied, and why not.

``diagnose.sh`` hands this script four things it collected on THIS node and gets
back a plain-words report (stdout) and the findings for the bundle summary:

  --inventory  what ``crl-inventory.sh`` saw in the CRL directory INSIDE the nac
               container: every file, CRL, certificate and hash link
  --facts      ``python -m app.scripts.diag crl-facts`` from the api container:
               what the DATABASE says every CRL source holds
  --eap        the rendered ``mods-enabled/eap`` (secrets masked)
  --logs       the window's logs: radiusd's stdout (why a TLS handshake failed)
               and the nac handler's log (which certificate serial got in)

Why both disk and database: a revocation that "silently did not apply" sits in
one of the gaps between them — the DB has a newer CRL than this node's disk; the
disk has it but radiusd has not rebuilt its store yet; the file is there but no
hash link leads to it; checking is off; or the CRL expired and now everything of
that CA is refused. Each of those is named here in words, with the numbers.

Per-CA CRL policy: the daemon checks a chain against a CRL only when some CA of
it, up to the root, is named by a ``ca_policy`` line of ``eap`` (its key's
SHA-256). The facts carry the policy the database implies and, for every CA
certificate, the chain the daemon walks from it; this script holds that against
the rendered lines (a node running an older config), names the CAs whose
clients will miss a CRL because the CRL configured is of the level above, and
groups the window's refusals and "CRL not checked" warnings by issuer.

Per-CA OCSP: a ``ca_policy`` line with ``ocsp`` (and maybe ``ocsp_url=``) makes the
daemon ask an OCSP responder about every client of that CA, and refuse the client
when it gets no usable answer. The facts carry the OCSP lines the database
implies, URL conflicts between sources, what blocks the deploy, the open
``nac_ocsp:*`` alerts, the last day's ``tls_ocsp_*`` rejects by class, and a live
probe of each responder a CA names (sent from the api container). This script
holds the lines against the rendered ones and puts each in words.

Standard library only: it runs on the host, where nothing else is installed.
"""

from __future__ import annotations

import argparse
import calendar
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Any

# FreeRADIUS rebuilds its X509 store (ca_file + ca_path) on the first new TLS
# session after this many seconds; 300 is also the minimum it accepts.
RELOAD_FLOOR_S = 300

KIND_LABEL = {"internal_ca": "Internal CA", "trusted_ca": "Trusted CA", "ldap": "LDAP EAP-TLS CA"}


# ── inventory ────────────────────────────────────────────────────────────────


@dataclass
class DirFile:
    name: str
    size: int = 0
    mtime: int = 0
    sha256: str = ""
    crl: dict[str, Any] | None = None
    cert: dict[str, Any] | None = None
    revoked: set[str] = field(default_factory=set)


@dataclass
class Inventory:
    now: int = 0
    directory: str = ""
    present: bool = False
    radiusd_pid: str = ""
    radiusd_age: int | None = None
    files: dict[str, DirFile] = field(default_factory=dict)
    links: dict[str, tuple[str, bool]] = field(default_factory=dict)  # name -> (target, ok)
    skipped: dict[str, str] = field(default_factory=dict)
    serials_listed: bool = False


def openssl_time(value: str) -> int | None:
    """``Oct 15 13:35:30 2026 GMT`` → epoch seconds (UTC)."""
    value = " ".join(value.split())
    if not value:
        return None
    try:
        return calendar.timegm(time.strptime(value, "%b %d %H:%M:%S %Y %Z"))
    except ValueError:
        return None


def iso_time(value: str | None) -> int | None:
    if not value:
        return None
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", value)
    if not m:
        return None
    year, month, day, hour, minute, second = (int(x) for x in m.groups())
    return calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))


def stamp(epoch: int | None) -> str:
    if epoch is None:
        return "?"
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(epoch))


def parse_inventory(text: str) -> Inventory:
    inv = Inventory()
    for line in text.splitlines():
        parts = line.split("\t")
        kind, rest = parts[0], parts[1:]
        try:
            if kind == "NOW":
                inv.now = int(rest[0])
            elif kind == "DIR":
                inv.directory, inv.present = rest[0], rest[1] == "present"
            elif kind == "RADIUSD":
                inv.radiusd_pid, inv.radiusd_age = rest[0], int(rest[1])
            elif kind == "LINK":
                inv.links[rest[0]] = (rest[1], rest[2] == "ok")
            elif kind == "FILE":
                inv.files[rest[0]] = DirFile(rest[0], int(rest[1]), int(rest[2]), rest[3])
            elif kind == "CRL":
                name, issuer, hsh, last, nxt, number, revoked, der, verify = rest[:9]
                inv.files.setdefault(name, DirFile(name)).crl = {
                    "issuer": issuer,
                    "hash": hsh,
                    "this_update": openssl_time(last),
                    "next_update": openssl_time(nxt),
                    "crl_number": None if number in ("", "<NONE>") else number.upper().replace("0X", "0x"),
                    "revoked": int(revoked or 0),
                    "sha256_der": der,
                    "verify": verify,
                }
            elif kind == "CERT":
                name, subject, issuer, hsh, not_after = rest[:5]
                inv.files.setdefault(name, DirFile(name)).cert = {
                    "subject": subject,
                    "issuer": issuer,
                    "hash": hsh,
                    "not_after": openssl_time(not_after),
                }
            elif kind == "SERIALS":
                inv.serials_listed = True
            elif kind == "REVOKED":
                inv.serials_listed = True
                inv.files.setdefault(rest[0], DirFile(rest[0])).revoked.add(norm_serial(rest[1]))
            elif kind == "SKIP":
                inv.skipped[rest[0]] = rest[1]
        except (IndexError, ValueError):
            continue  # one malformed line must not cost the rest of the report
    if not inv.now:
        inv.now = int(time.time())
    return inv


def norm_serial(serial: str) -> str:
    return serial.strip().lower().replace(":", "").lstrip("0") or "0"


def dn_key(dn: str) -> tuple[tuple[str, str], ...]:
    """A DN as a sorted set of (ATTR, value) — ``/DC=pro/CN=x`` and ``CN=x,DC=pro`` compare equal."""
    dn = dn.strip()
    if dn.startswith("/"):
        parts = [p for p in dn.split("/") if p]
    else:
        parts = [p.strip() for p in re.split(r"(?<!\\),", dn) if p.strip()]
    out = []
    for p in parts:
        if "=" in p:
            k, v = p.split("=", 1)
            out.append((k.strip().upper(), v.strip().replace("\\,", ",").lower()))
    return tuple(sorted(out))


# ── rendered eap module ──────────────────────────────────────────────────────


def parse_eap(text: str) -> dict[str, Any]:
    """The few directives that decide whether a CRL is consulted and when it is re-read."""

    def directive(name: str) -> str | None:
        m = re.search(rf"^\s*{name}\s*=\s*(\S+)", text, re.MULTILINE)
        return m.group(1).strip('"') if m else None

    cache = None
    m = re.search(r"^\s*cache\s*\{(.*?)\}", text, re.MULTILINE | re.DOTALL)
    if m:
        e = re.search(r"^\s*enable\s*=\s*(\S+)", m.group(1), re.MULTILINE)
        cache = e.group(1) if e else None
    interval = directive("ca_path_reload_interval")
    lines = [
        (m.group(1).lower(), m.group(2).split())
        for m in re.finditer(r'^\s*ca_policy\s*=\s*"([0-9A-Fa-f]{64})\s+([^"]*)"', text, re.MULTILINE)
    ]
    policy = [key for key, tokens in lines if "crl" in tokens]
    # key -> its ocsp_url ("" when the line asks the AIA of each client certificate)
    ocsp = {
        key: next((t.partition("=")[2] for t in tokens if t.startswith("ocsp_url=")), "")
        for key, tokens in lines
        if "ocsp" in tokens
    }
    return {
        "ca_policy": policy,
        "ca_policy_ocsp": ocsp,
        "check_crl": (directive("check_crl") or "no").lower() in ("yes", "true", "1"),
        "check_crl_raw": directive("check_crl"),
        "ca_path_reload_interval": int(interval) if interval and interval.isdigit() else None,
        "ca_path": directive("ca_path"),
        "ca_file": directive("ca_file"),
        "cache_enable": cache,
    }


# ── window logs ──────────────────────────────────────────────────────────────

_REQ_RE = re.compile(r"\((\d+)\)\s+eap_tls:.*?OpenSSL says error (\d+)\s*:\s*(.+?)\s*$")
_TLS_ERR_RE = re.compile(r"\((\d+)\)\s+eap_tls:.*\(TLS\)\s*(.+?)\s*$")
_REJECT_RE = re.compile(r"post_auth REJECT: user=(\S*) mac=(\S*) method=(\S*)")
_ACCEPT_TLS_RE = re.compile(r"post_auth EAP-TLS: cn=(.*?) upn=.*? serial=([0-9A-Fa-f:]+) issuer=(.+?)\s*$")
# The nac handler's own log: the reject line carries the message, which for a
# refused client certificate ends with "; issuer: <DN>" (TLS-Client-Cert-Issuer).
_REJECT_MSG_RE = re.compile(r"post_auth REJECT: user=(\S*) mac=\S* method=\S* reason=(\S+) .*?msg=(.*?)\s*$")
_OPENSSL_CODE_RE = re.compile(r"OpenSSL error (\d+)")
_ISSUER_SUFFIX_RE = re.compile(r"; issuer: (.+)$")
# The handler's message for a per-CA OCSP refusal (tls_ocsp_revoked / _unknown / _failed).
_OCSP_MSG_RE = re.compile(
    r"^OCSP check failed: (?:\[(?P<klass>[a-z]+)\] )?(?P<detail>.*?)"
    r"(?:; responder (?P<responder>\S+))?(?:; issuer: (?P<issuer>.*))?$"
)
# Our FreeRADIUS fork, once per issuer key per store generation, when the policy
# lifted a CRL error because no CA of the chain is configured.
_UNCHECKED_RE = re.compile(r"CRL not checked for '(.*)': no CA in its chain has a CRL configured(?: \((.*)\))?\s*$")
_UNCHECKED_ISSUER_RE = re.compile(r"issuer '(.*)', issuer key sha256:([0-9a-fA-F]{64})")
_UNCHECKED_DIRECT_RE = re.compile(r"certificate trusted directly, its own key sha256:([0-9a-fA-F]{64})")
OPENSSL_CRL_CODES = {3: "unable to get certificate CRL", 12: "CRL has expired"}

REASONS = (
    ("certificate revoked", "certificate revoked"),
    ("CRL has expired", "CRL has expired"),
    ("unable to get certificate CRL", "unable to get certificate CRL"),
)


def classify(text: str) -> str:
    low = text.lower()
    for needle, label in REASONS:
        if needle.lower() in low:
            return label
    return "other TLS"


@dataclass
class Window:
    rejects: dict[str, list[str]] = field(default_factory=dict)  # reason -> users ("" when unknown)
    accepted: dict[str, tuple[str, str, int]] = field(default_factory=dict)  # serial -> (cn, issuer, count)
    files_read: list[str] = field(default_factory=list)
    # (OpenSSL error, issuer DN) -> users, from the handler's reject messages
    by_issuer: dict[tuple[int, str], list[str]] = field(default_factory=dict)
    # issuer key (or "" when the daemon could not hash it) -> (issuer DN, subjects)
    unchecked: dict[str, tuple[str, list[str]]] = field(default_factory=dict)
    # (token, class, responder, issuer) -> users, from the handler's OCSP reject messages
    ocsp: dict[tuple[str, str, str, str], list[str]] = field(default_factory=dict)


def scan_logs(root: str) -> Window:
    win = Window()
    if not root or not os.path.isdir(root):
        return win
    paths: list[str] = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d != "context"]  # neighbours' tails are not the window
        paths.extend(os.path.join(base, n) for n in sorted(names))
    for path in sorted(paths):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        win.files_read.append(os.path.relpath(path, root))
        req_reason: dict[str, str] = {}
        pending: list[str] = []  # reasons in order, waiting for their post_auth REJECT line
        for line in lines:
            m = _REQ_RE.search(line)
            if m:
                req, _code, text = m.groups()
                if req not in req_reason:
                    req_reason[req] = classify(text)
                    pending.append(req_reason[req])
                continue
            m = _TLS_ERR_RE.search(line)
            if m and m.group(1) not in req_reason and "Error in error" not in line:
                req, text = m.groups()
                if "alert" in text.lower() and "fatal" in text.lower():
                    req_reason[req] = classify(text)
                    pending.append(req_reason[req])
                continue
            m = _REJECT_RE.search(line)
            if m and m.group(3) == "eap_tls" and pending:
                win.rejects.setdefault(pending.pop(0), []).append(m.group(1))
                continue
            m = _REJECT_MSG_RE.search(line)
            if m:
                user, reason, msg = m.groups()
                om = _OCSP_MSG_RE.match(msg) if reason.startswith("tls_ocsp_") else None
                if om:
                    key = (reason, om.group("klass") or "-", om.group("responder") or "none", om.group("issuer") or "")
                    win.ocsp.setdefault(key, []).append(user)
                    continue
                code = _OPENSSL_CODE_RE.search(msg)
                issuer_m = _ISSUER_SUFFIX_RE.search(msg)
                if code and issuer_m:
                    win.by_issuer.setdefault((int(code.group(1)), issuer_m.group(1)), []).append(user)
                continue
            m = _UNCHECKED_RE.search(line)
            if m:
                subject, detail = m.group(1), m.group(2) or ""
                im = _UNCHECKED_ISSUER_RE.search(detail)
                dm = _UNCHECKED_DIRECT_RE.search(detail)
                if im:
                    issuer, key = im.group(1), im.group(2).lower()
                elif dm:
                    issuer, key = subject, dm.group(1).lower()
                else:
                    issuer, key = "", ""
                _dn, subjects = win.unchecked.get(key, (issuer, []))
                if subject not in subjects:
                    subjects.append(subject)
                win.unchecked[key] = (issuer or _dn, subjects)
                continue
            m = _ACCEPT_TLS_RE.search(line)
            if m:
                cn, serial, issuer = m.groups()
                key = norm_serial(serial)
                _cn, _iss, count = win.accepted.get(key, (cn, issuer, 0))
                win.accepted[key] = (cn, issuer, count + 1)
        for reason in pending:  # a TLS failure whose post_auth line was not in this file
            win.rejects.setdefault(reason, []).append("")
    return win


# ── analysis ─────────────────────────────────────────────────────────────────


class Report:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.findings: list[str] = []

    def out(self, text: str = "") -> None:
        self.lines.append(text)

    def find(self, text: str, tag: str = "[CRL]") -> None:
        first, *rest = text.split("\n")
        block = [f"  {tag:<9} {first}"] + [f"            {r}" for r in rest]
        self.findings.append("\n".join(block))


def crl_label(crl: dict[str, Any]) -> str:
    number = crl.get("crl_number")
    return f"#{number}" if number else f"(no CRL Number, thisUpdate {stamp(crl.get('this_update'))})"


def _hash_link_for(inv: Inventory, name: str, marker: str) -> bool:
    return any(
        t == name and ok and re.fullmatch(rf"[0-9a-f]{{8}}\.{marker}\d+", ln) for ln, (t, ok) in inv.links.items()
    )


def _linked_twin(inv: Inventory, name: str) -> str | None:
    """A linked CRL file with the same DER as ``name`` — the link manager links one of identical files only."""
    der = (inv.files[name].crl or {}).get("sha256_der")
    for other, f in sorted(inv.files.items()):
        if other != name and f.crl and f.crl.get("sha256_der") == der and _hash_link_for(inv, other, "r"):
            return other
    return None


# ── per-CA CRL policy ────────────────────────────────────────────────────────


CONFIGURED_BY = {
    "internal": "Internal CA — Taranac signs its CRL",
    "crl": "its stored CRL",
    "crl_signer_unknown": "a stored CRL no certificate of it verifies (or that does not decrypt) — every certificate",
    "url_pending": "a CRL URL with no CRL downloaded yet — every certificate",
    "none": "neither a CRL URL nor a CRL — not configured",
}


@dataclass
class Policy:
    """The facts' ``policy``, indexed for the analysis."""

    known: bool = False
    master_on: bool = False
    keys: set[str] = field(default_factory=set)
    sources_of: dict[str, list[str]] = field(default_factory=dict)  # key -> source ids
    labels: dict[str, str] = field(default_factory=dict)  # source id -> label
    subjects: dict[str, str] = field(default_factory=dict)  # key -> subject
    certs_by_dn: dict[tuple[tuple[str, str], ...], list[dict[str, Any]]] = field(default_factory=dict)
    predicted: dict[str, dict[str, Any]] = field(default_factory=dict)  # key -> predicted_crl_missing entry
    raw: dict[str, Any] = field(default_factory=dict)


def index_policy(facts: dict[str, Any] | None) -> Policy:
    pol = Policy()
    raw = (facts or {}).get("policy")
    if not isinstance(raw, dict) or "error" in raw:
        return pol
    pol.known, pol.raw = True, raw
    pol.master_on = bool(raw.get("master_on"))
    for entry in raw.get("entries", []):
        pol.keys.add(entry["spki_sha256"])
        pol.sources_of[entry["spki_sha256"]] = list(entry.get("sources", []))
    for src in raw.get("sources", []):
        pol.labels[src["source"]] = src.get("label") or src["source"]
        for cert in src.get("certs", []):
            pol.subjects.setdefault(cert["spki_sha256"], cert["subject"])
            pol.certs_by_dn.setdefault(dn_key(cert["subject"]), []).append(cert)
    for entry in raw.get("predicted_crl_missing", []):
        pol.predicted[entry["spki_sha256"]] = entry
    return pol


def short(key: str) -> str:
    return f"sha256:{key[:16]}…"


def named(pol: Policy, key: str) -> str:
    subject = pol.subjects.get(key)
    return f"{subject} ({short(key)})" if subject else short(key)


def chain_needs_crl(cert: dict[str, Any]) -> bool:
    """The daemon keeps a CRL error for this CA's clients: it, or a CA above it, is configured."""
    return bool(cert.get("configured") or cert.get("configured_above"))


def analyse_policy(
    rep: Report, facts: dict[str, Any] | None, eap: dict[str, Any] | None, pol: Policy, check_on: bool
) -> None:
    rep.out("")
    rep.out("Per-CA CRL policy")
    rep.out("-----------------")
    raw_policy = (facts or {}).get("policy")
    if not pol.known:
        why = raw_policy.get("error") if isinstance(raw_policy, dict) else "not in the database facts"
        rep.out(f"  policy from the database: unknown ({why})")
    rendered = list(eap["ca_policy"]) if eap else None
    if pol.known:
        rep.out(
            f"  database: {len(pol.keys)} CA key(s) need a CRL{'' if pol.master_on else ' (CRL checking is off: none)'}"
        )
    rep.out(f"  rendered eap: {'not collected' if rendered is None else f'{len(rendered)} ca_policy line(s)'}")

    # 1. The node's eap against the database.
    if pol.known and rendered is not None and set(rendered) != pol.keys:
        missing = sorted(pol.keys - set(rendered))
        extra = sorted(set(rendered) - pol.keys)
        lines = ["The ca_policy lines FreeRADIUS runs with differ from what the database implies:"]
        lines += [f"  not in eap : {named(pol, k)}" for k in missing]
        lines += [f"  only in eap: {named(pol, k)}" for k in extra]
        lines.append("This node runs a config older than the database: the deploy was deferred (readiness)")
        lines.append("or its validation failed — see the nac_config alerts and the NAC config page.")
        if pol.raw.get("deployable") is False:
            lines.append(
                "The trust cannot be deployed now (a CA certificate does not decrypt or parse, or an OCSP URL\n"
                "cannot be used: "
                + ", ".join(
                    pol.raw.get("unreadable", []) + pol.raw.get("unparsed", []) + pol.raw.get("invalid_ocsp_url", [])
                )
                + "), so the bundle and eap on disk are kept on purpose."
            )
        rep.find("\n".join(lines), tag="[policy]")

    # 2. An image that ignores ca_policy (no marker at -XC).
    unsupported = (facts or {}).get("ca_policy_unsupported") or []
    for alert in unsupported:
        where = "this node" if alert.get("this_node") else f"node {alert.get('node') or '?'}"
        rep.out(f"  open alert: ca_policy not understood on {where} (since {alert.get('first_seen') or '?'})")
    mine = [a for a in unsupported if a.get("this_node")]
    if mine and rendered:
        version = mine[0].get("api_version") or "the api's version"
        rep.find(
            "The nac image on this node does not understand ca_policy (no 'tls: ca_policy: N entries' marker\n"
            "at config validation): FreeRADIUS here requires a valid CRL from EVERY trusted CA, so clients of\n"
            f"a CA without a CRL are rejected ('unable to get certificate CRL'). Update this node's images to\n"
            f"Taranac {version} or later.",
            tag="[policy]",
        )

    if not pol.known:
        return
    for label in pol.raw.get("unreadable", []):
        rep.find(f"{label}: its CA certificate does not decrypt — the deploy keeps the previous bundle and eap.")
    for label in pol.raw.get("unparsed", []):
        rep.find(f"{label}: its CA certificate cannot be parsed — the deploy keeps the previous bundle and eap.")
    for label in pol.raw.get("invalid_ocsp_url", []):
        rep.find(
            f"{label}: OCSP is on and its stored OCSP responder URL cannot be used (http:// only, a host, no user\n"
            "info, printable ASCII without spaces, quotes, backslashes or '$') — the deploy keeps the previous\n"
            "bundle and eap. Correct or clear the URL, or turn OCSP off."
        )

    # 2-3. Each record: its chain, whose CRL it holds, whether that CA issues the leaves.
    for src in pol.raw.get("sources", []):
        label = src.get("label") or src["source"]
        rep.out(f"  {label}  [{src['source']}]")
        if not src.get("parsed"):
            rep.out("      certificate not parsed — not in the policy")
            continue
        by = src.get("configured_by", "none")
        rep.out(f"      configured by: {CONFIGURED_BY.get(by, by)}")
        signer = src.get("crl_signer_spki")
        for cert in src.get("certs", []):
            key = cert["spki_sha256"]
            state = "configured" if cert.get("configured") else "not configured"
            rep.out(f"      {cert['subject']}  key {short(key)}  {state}")
            above = [entry["subject"] for level in cert.get("chain", [])[1:] for entry in level]
            if above:
                rep.out(f"          chain up: {' ← '.join(above)}")
            if cert.get("configured_above"):
                rep.out(
                    "          a CA above is configured ("
                    + ", ".join(e["subject"] for e in cert["configured_above"])
                    + "): its clients' CRL errors stand"
                )
            if key == signer and cert.get("signs"):
                issued = ", ".join(pol.subjects.get(k, short(k)) for k in cert["signs"])
                rep.out(
                    f"          holds the CRL, but signs CA certificate(s) {issued}: probably not the issuing CA —"
                    " their clients need THEIR CRL"
                )
        if by == "url_pending" and check_on:
            rep.find(
                f"{label} has a CRL URL but no CRL downloaded: every certificate of it is configured, so its\n"
                "clients are rejected ('unable to get certificate CRL') until a download succeeds — see the\n"
                "download error and the CRL alerts."
            )
        elif by == "crl_signer_unknown" and check_on:
            rep.find(
                f"{label}: its stored CRL is not verified by any of its certificates (or does not decrypt): every\n"
                "certificate of it is configured, and its clients get 'unable to get certificate CRL' or\n"
                "'CRL signature failure'. Load the CRL of the CA that issues the client certificates."
            )

    # 3. The resulting policy.
    if pol.master_on:
        rep.out("  CA keys whose chains need a CRL:")
        for key in sorted(pol.keys):
            owners = ", ".join(pol.labels.get(s, s) for s in pol.sources_of.get(key, []))
            rep.out(f"      {named(pol, key)}  — {owners}")
        if not pol.keys:
            rep.out("      (none — no CA has a CRL configured; nothing is checked)")

    # The CRL "of the wrong level": a CA above is configured, this one has no CRL.
    if pol.master_on:
        for entry in sorted(pol.predicted.values(), key=lambda e: e["subject"]):
            above = ", ".join(e["subject"] for e in entry.get("configured_above", []))
            where = ", ".join(pol.labels.get(s, s) for s in entry.get("sources", []))
            note = (
                "\nIt signs CA certificates itself; if it issues no client certificates, nothing breaks."
                if entry.get("signs")
                else ""
            )
            rep.find(
                f"Clients of {entry['subject']} ({where}) will be rejected with 'unable to get certificate CRL'\n"
                f"(error 3): {above} above it has a CRL configured, so its chains are checked, but\n"
                f"{entry['subject']} has no CRL of its own. A CA's CRL covers only the certificates that CA\n"
                f"issued itself — give {entry['subject']} its CRL (URL or upload on its record).{note}",
                tag="[policy]",
            )


OCSP_CLASS_WORDS = {
    "transport": "no usable answer in time (name, connection, timeout, HTTP status, not an OCSP response)",
    "busy": "this node's OCSP slots were all taken — says nothing about the responder",
    "response": "the responder answered with an error status (tryLater, unauthorized, ...)",
    "verify": "the answer did not hold (signature or signer, no status for the certificate, times)",
    "config": "the check could not be made here (no responder URL, no issuer)",
}


def analyse_ocsp(rep: Report, facts: dict[str, Any] | None, eap: dict[str, Any] | None, pol: Policy) -> None:
    rep.out("")
    rep.out("Per-CA OCSP")
    rep.out("-----------")
    raw = (facts or {}).get("ocsp")
    rendered: dict[str, str] | None = eap.get("ca_policy_ocsp") if eap else None
    if not isinstance(raw, dict) or "error" in raw:
        why = raw.get("error") if isinstance(raw, dict) else "not in the database facts"
        rep.out(f"  OCSP facts from the database: unknown ({why})")
        if rendered:
            rep.out(f"  rendered eap: {len(rendered)} ca_policy line(s) with ocsp")
        return

    entries = {e["spki_sha256"]: (e.get("ocsp_url") or "") for e in raw.get("entries", [])}
    # A key whose source holds a stored URL the daemon cannot take has no URL in
    # the line — and the trust is not deployable: it is not "the AIA".
    invalid_sources = {s.get("source") for s in raw.get("sources", []) if s.get("responder") == "invalid"}
    invalid_keys = {
        e["spki_sha256"]
        for e in raw.get("entries", [])
        if not e.get("ocsp_url") and invalid_sources & set(e.get("sources") or [])
    }
    rep.out(f"  database: {len(entries)} CA key(s) checked with OCSP")
    for key, url in sorted(entries.items()):
        if key in invalid_keys:
            where = "a stored URL that cannot be used (the deploy is held back)"
        else:
            where = url or "the AIA of each client certificate"
        rep.out(f"    {named(pol, key)}: {where}")
    shown = "not collected" if rendered is None else f"{len(rendered)} ca_policy line(s) with ocsp"
    rep.out(f"  rendered eap: {shown}")
    if rendered is not None and rendered != entries:
        lines = ["The OCSP lines FreeRADIUS runs with differ from what the database implies:"]
        for key in sorted(set(entries) - set(rendered)):
            lines.append(f"  not in eap : {named(pol, key)}")
        for key in sorted(set(rendered) - set(entries)):
            lines.append(f"  only in eap: {named(pol, key)}")
        for key in sorted(k for k in set(entries) & set(rendered) if entries[k] != rendered[k]):
            lines.append(
                f"  responder  : {named(pol, key)} — eap {rendered[key] or 'AIA'}, database {entries[key] or 'AIA'}"
            )
        lines.append("This node runs a config older than the database: the deploy was deferred (readiness), its")
        lines.append("validation failed (an image without per-CA OCSP refuses or ignores the lines), or the trust")
        lines.append("is not deployable — see the nac_config alerts and the lines below.")
        rep.find("\n".join(lines), tag="[ocsp]")
    if entries and eap and (eap.get("cache_enable") or "").lower() in ("yes", "true", "1"):
        rep.find(
            "OCSP is checked but the TLS session cache is enabled: a resumed session skips the OCSP\n"
            "check, so a revoked certificate keeps getting in for the cache lifetime.",
            tag="[ocsp]",
        )

    for key in raw.get("url_conflicts", []):
        rep.find(
            f"Sources that check {named(pol, key)} with OCSP disagree on the responder URL (one may\n"
            f"be empty, i.e. the AIA). The first non-empty one in bundle order is used: {entries.get(key) or 'AIA'}.",
            tag="[ocsp]",
        )
    for label in raw.get("unreadable_ocsp", []):
        rep.find(
            f"{label}: OCSP is on and its CA certificate does not decrypt — the deploy keeps the previous eap.",
            tag="[ocsp]",
        )
    for label in raw.get("unparsed_ocsp", []):
        rep.find(
            f"{label}: OCSP is on and its CA certificate cannot be parsed — the deploy keeps the previous eap.",
            tag="[ocsp]",
        )
    for src in raw.get("sources", []):
        if src.get("responder") == "aia":
            rep.out(f"  {src.get('label')}: OCSP on, no URL — each client certificate's AIA names the responder")
        elif src.get("responder") == "invalid":
            rep.out(
                f"  {src.get('label')}: OCSP on, stored URL {src.get('ocsp_url')} cannot be used "
                f"({src.get('url_problem')})"
            )

    for alert in raw.get("alerts", []):
        subject = alert.get("url") or f"issuer {alert.get('issuer') or '?'}"
        node = f" on node {alert['node']}" if alert.get("node") else ""
        rep.out(
            f"  open alert{node}: {alert.get('fingerprint')} ({alert.get('failure_class') or '?'}) since "
            f"{alert.get('first_seen') or '?'}, last {alert.get('last_seen') or '?'}, ×{alert.get('occurrences')}"
        )
        rep.find(f"Open OCSP alert{node} for {subject}: {alert.get('message') or alert.get('title')}", tag="[ocsp]")

    rejects = raw.get("rejects") or {}
    groups = rejects.get("groups") or []
    if groups:
        capped = "at least " if rejects.get("capped") else ""
        rep.out(
            f"  OCSP rejects in the last {rejects.get('hours', '?')} h (database, {capped}{rejects.get('rows', '?')}"
            " rows), newest first:"
        )
        for g in groups:
            klass = g.get("class") or "-"
            node = f" node {g['node']}" if g.get("node") else ""
            rep.out(
                f"    {g.get('reason')} [{klass}] ×{g.get('count')} responder {g.get('responder')} "
                f"issuer {g.get('issuer') or '?'}{node} — last {g.get('last') or '?'}: {g.get('detail') or ''}"
            )
        # A revoked certificate refused is OCSP doing its job: shown, not a finding.
        by_class: dict[str, int] = {}
        for g in groups:
            if g.get("reason") == "tls_ocsp_revoked":
                continue
            node = f" on node {g['node']}" if g.get("node") else ""
            label_class = f"{g.get('reason')} [{g.get('class') or '-'}]{node}"
            by_class[label_class] = by_class.get(label_class, 0) + int(g.get("count") or 0)
        if by_class:
            rep.find(
                f"{capped}{sum(by_class.values())} OCSP check(s) failed or unknown in the last "
                f"{rejects.get('hours', '?')} h: "
                + ", ".join(f"{k} ×{v}" for k, v in sorted(by_class.items()))
                + "."
                + "".join(
                    f"\n  {klass}: {words}"
                    for klass, words in OCSP_CLASS_WORDS.items()
                    if any(f"[{klass}]" in k for k in by_class)
                ),
                tag="[ocsp]",
            )
    else:
        rep.out(f"  OCSP rejects in the last {rejects.get('hours', '?')} h (database): none")

    probe = raw.get("probe") or {}
    if probe.get("error"):
        rep.out(f"  live probe: {probe['error']}")
    records = probe.get("records") or []
    if records:
        rep.out(f"  live probe from {probe.get('from', 'the api container')} (budget {probe.get('budget_s', '?')} s):")
    for record in records:
        label, url = record.get("label"), record.get("url")
        if record.get("skipped"):
            rep.out(f"    {label} {url}: not probed — {record['skipped']}")
            continue
        for result in record.get("results") or []:
            issuer = result.get("issuer") or "?"
            if result.get("ok"):
                rep.out(
                    f"    {label} {url} for {issuer}: answers in {result.get('elapsed_ms')} ms "
                    f"(HTTP {result.get('http_status')}, {result.get('response_status')}, test serial "
                    f"{result.get('cert_status') or '?'}, nextUpdate {result.get('next_update') or 'none'})"
                )
            else:
                rep.out(
                    f"    {label} {url} for {issuer}: FAILED [{result.get('failure')}] after "
                    f"{result.get('elapsed_ms')} ms — {result.get('reason')}"
                )
                rep.find(
                    f"The OCSP responder {url} of {label} did not answer as the daemon needs for {issuer}\n"
                    f"[{result.get('failure')}]: {result.get('reason')}. Clients of this CA are refused while this\n"
                    "lasts. (Probed from the api container; the daemon asks from the nac container.)",
                    tag="[ocsp]",
                )


def analyse_ocsp_window(rep: Report, win: Window) -> None:
    if not win.ocsp:
        return
    rep.out("  OCSP refusals by class (nac handler):")
    for (reason, klass, responder, issuer), users in sorted(win.ocsp.items()):
        names = sorted({u for u in users if u})
        rep.out(
            f"    {reason} [{klass}] responder {responder} issuer {issuer or '?'} ×{len(users)}"
            f"{': ' + ', '.join(names) if names else ''}"
        )


def analyse_policy_window(rep: Report, win: Window, pol: Policy) -> None:
    if win.by_issuer:
        rep.out("  refused client certificates by issuer (nac handler):")
        for (code, issuer), users in sorted(win.by_issuer.items()):
            names = sorted({u for u in users if u})
            rep.out(
                f"    OpenSSL error {code} ({OPENSSL_CRL_CODES.get(code, 'see the code')}) issuer {issuer}"
                f" ×{len(users)}{': ' + ', '.join(names) if names else ''}"
            )
    for (code, issuer), users in sorted(win.by_issuer.items()):
        if code not in OPENSSL_CRL_CODES:
            continue
        certs = pol.certs_by_dn.get(dn_key(issuer), [])
        predicted = [c for c in certs if c["spki_sha256"] in pol.predicted]
        if code == 3 and predicted:
            why = "as predicted above: a CA above it has a CRL configured and it has none of its own."
        elif code == 3:
            why = "no CRL of this issuer reached radiusd — check the CRL directory and downloads above."
        else:
            why = "its CRL has expired — load a current one."
        rep.find(
            f"{len(users)} client certificate(s) of {issuer} refused with OpenSSL error {code}\n"
            f"({OPENSSL_CRL_CODES[code]}): {why}",
            tag="[window]",
        )
    if win.unchecked:
        rep.out("  CRL not checked (no CA in the chain has a CRL configured), by issuer:")
        for key, (issuer, subjects) in sorted(win.unchecked.items()):
            rep.out(
                f"    issuer {issuer or '?'} key {short(key) if key else '?'}: "
                + ", ".join(subjects[:5])
                + (f" and {len(subjects) - 5} more" if len(subjects) > 5 else "")
            )
            if key and key in pol.keys:
                rep.find(
                    f"radiusd lifted the CRL check for issuer {issuer} (key {short(key)}), but the database\n"
                    "configures that key: this node runs an older eap, or the daemon and Taranac disagree on\n"
                    "the key's fingerprint. See the ca_policy comparison above.",
                    tag="[window]",
                )


def analyse(inv: Inventory, facts: dict[str, Any] | None, eap: dict[str, Any] | None, win: Window) -> Report:
    rep = Report()
    now = inv.now
    check_db = facts.get("crl_check_enable") if facts else None
    check_rendered = eap["check_crl"] if eap else None

    # ── configuration ────────────────────────────────────────────────────────
    rep.out("CRL checking")
    rep.out("------------")
    rep.out(f"  nac.crl_check_enable (DB) : {'unknown' if check_db is None else ('on' if check_db else 'off')}")
    if eap:
        rep.out(f"  rendered check_crl        : {eap['check_crl_raw'] or '(absent = no)'}")
        interval = eap["ca_path_reload_interval"]
        rep.out(f"  ca_path_reload_interval   : {interval if interval is not None else '(absent)'}")
        rep.out(f"  ca_path / ca_file         : {eap['ca_path']} / {eap['ca_file']}")
        rep.out(f"  TLS session cache enable  : {eap['cache_enable']}")
    else:
        rep.out("  rendered eap module       : not collected")
    check_on = bool(check_rendered if check_rendered is not None else check_db)
    pol = index_policy(facts)
    # With the toggle on but no CA configured there is nothing to check, and the
    # deploy renders no check_crl on purpose (an Infra CA makes that rare).
    nothing_configured = bool(check_db) and pol.known and not pol.keys
    expected_rendered = check_db if not nothing_configured else False

    if check_db is not None and check_rendered is not None and expected_rendered != check_rendered:
        rep.find(
            f"The setting says CRL checking is {'ON' if check_db else 'OFF'}, but the eap module FreeRADIUS\n"
            f"runs was rendered with it {'ON' if check_rendered else 'OFF'}. The NAC config on this node has\n"
            "not been regenerated or reloaded since the toggle changed."
        )
    if nothing_configured and check_rendered is False:
        rep.out("  no CA has a CRL configured: check_crl is not rendered — nothing is checked")
    elif check_rendered is False or (check_rendered is None and check_db is False):
        rep.find(
            "CRL checking is OFF: FreeRADIUS consults no CRL at all, so a revoked client\n"
            "certificate is accepted. Turn on 'Check CRL' in NAC settings to enforce revocation."
        )
    if eap and check_rendered:
        if eap["ca_path_reload_interval"] is None:
            rep.find(
                "CRL checking is on but ca_path_reload_interval is missing: FreeRADIUS never\n"
                "re-reads the CRL directory (a HUP does not either), so a new CRL applies only\n"
                "after a full restart of the nac container."
            )
        if (eap["cache_enable"] or "").lower() in ("yes", "true", "1"):
            rep.find(
                "CRL checking is on but the TLS session cache is enabled: a resumed session skips\n"
                "the revocation check, so a revoked certificate keeps getting in for the cache lifetime."
            )

    # ── radiusd ──────────────────────────────────────────────────────────────
    rep.out("")
    rep.out("radiusd")
    rep.out("-------")
    started = now - inv.radiusd_age if inv.radiusd_age is not None else None
    if started is not None:
        rep.out(f"  pid {inv.radiusd_pid}, running {inv.radiusd_age} s — started {stamp(started)}")
    else:
        rep.out("  process age unknown (radiusd not found, or /proc unreadable)")

    # ── directory ────────────────────────────────────────────────────────────
    rep.out("")
    rep.out(f"CRL directory on this node: {inv.directory or '?'}")
    rep.out("-" * 40)
    if not inv.present:
        rep.out("  (missing)")
        if check_on:
            rep.find(
                f"CRL checking is on but the CRL directory {inv.directory} does not exist on this node:\n"
                "every client certificate is rejected ('unable to get certificate CRL')."
            )
    crls = {n: f for n, f in inv.files.items() if f.crl}
    for name in sorted(inv.files):
        f = inv.files[name]
        rep.out(f"  {name}  ({f.size} B, written {stamp(f.mtime)}, sha256 {f.sha256[:16]}…)")
        if f.crl:
            c = f.crl
            expired = c["next_update"] is not None and c["next_update"] <= now
            rep.out(f"      CRL  issuer {c['issuer']}  {crl_label(c)}")
            rep.out(
                f"           thisUpdate {stamp(c['this_update'])}  nextUpdate {stamp(c['next_update'])}"
                f"{'  EXPIRED' if expired else ''}"
            )
            rep.out(f"           revoked {c['revoked']}  DER sha256 {c['sha256_der'][:16]}…  signature {c['verify']}")
            if not _hash_link_for(inv, name, "r"):
                twin = _linked_twin(inv, name)
                rep.out(
                    f"           identical to {twin}, which is linked — loaded once through it"
                    if twin
                    else "           ! no <hash>.rN link leads here — OpenSSL's by_dir never loads it"
                )
        if f.cert:
            rep.out(
                f"      CERT subject {f.cert['subject']}"
                f"  (hash {f.cert['hash']}, notAfter {stamp(f.cert['not_after'])})"
            )
    for name, reason in sorted(inv.skipped.items()):
        rep.out(f"  {name}  — skipped: {reason}")
    for name, (target, ok) in sorted(inv.links.items()):
        rep.out(f"  {name} -> {target}{'' if ok else '   BROKEN'}")

    for name, (target, ok) in sorted(inv.links.items()):
        if not ok:
            rep.find(
                f"Hash link {name} points at {target}, which does not exist. OpenSSL's by_dir\n"
                "follows these links to find CRLs and CA certificates; a dangling one hides what\n"
                "it should point to."
            )
    for name, f in sorted(crls.items()):
        c = f.crl or {}
        if c["next_update"] is not None and c["next_update"] <= now:
            rep.find(
                f"{name}: the CRL of {c['issuer']} {crl_label(c)} EXPIRED at {stamp(c['next_update'])}.\n"
                + (
                    "CRL checking is on, so EVERY client certificate of that CA is rejected now\n"
                    "('CRL has expired') until a current CRL is loaded."
                    if check_on
                    else "Checking is off, so nothing breaks yet; turning it on would reject every client of that CA."
                )
            )
        if c["verify"] == "fail":
            rep.find(
                f"{name}: the CRL's signature does NOT verify against the CA certificate of its issuer\n"
                "in this directory. OpenSSL rejects it ('CRL signature failure'), so with checking on\n"
                "every client of that CA is refused."
            )
        elif c["verify"] == "no-ca":
            rep.find(
                f"{name}: no CA certificate in this directory has the subject of the CRL's issuer\n"
                f"({c['issuer']}); the CRL cannot be verified here."
            )
        if not _hash_link_for(inv, name, "r") and not _linked_twin(inv, name):
            rep.find(
                f"{name}: no <hash>.rN link points at this CRL, so radiusd never loads it —\n"
                "revocations in it do not apply. The next CRL deploy rebuilds the links."
            )

    # ── database vs disk ─────────────────────────────────────────────────────
    rep.out("")
    rep.out("Database (crl-facts) vs this node's disk")
    rep.out("----------------------------------------")
    if not facts:
        rep.out("  (no database facts — the api container was not reachable)")
    else:
        fetch = facts.get("crl_fetch") or {}
        rep.out(
            f"  crl_fetch every {fetch.get('interval_minutes')} min; next run ≈ {fetch.get('next_run_estimate') or '?'}"
            " (estimate)"
        )
        expected_files = set()
        for src in facts.get("sources", []):
            label = f"{KIND_LABEL.get(src['kind'], src['kind'])} '{src['name']}'"
            db = src.get("crl")
            disk = inv.files.get(src["disk_file"])
            rep.out(f"  {label}  [{src['kind']}:{src['id']}]")
            rep.out(
                f"      enabled={src['enabled']}  url={src.get('crl_url') or '-'}  "
                f"last download={src.get('last_fetched_at') or '-'}"
            )
            if src.get("fetch_error"):
                rep.out(f"      download error: {src['fetch_error']}")
            if db and "error" in db:
                rep.out(f"      DB : {db['error']}")
            elif db:
                rep.out(
                    f"      DB : {'#' + db['crl_number'] if db['crl_number'] else 'no CRL Number'}"
                    f"  thisUpdate {db['this_update']}  nextUpdate {db['next_update']}  revoked {db['revoked_count']}"
                    f"  DER sha256 {db['sha256_der'][:16]}…"
                )
            else:
                rep.out("      DB : no CRL stored")
            if disk and disk.crl:
                number = disk.crl["crl_number"]
                rep.out(
                    f"      disk: {src['disk_file']} {'#' + number if number else 'no CRL Number'}"
                    f"  DER sha256 {disk.crl['sha256_der'][:16]}…"
                )
            else:
                rep.out(f"      disk: {src['disk_file']} {'absent' if not disk else 'present but not a readable CRL'}")

            if src.get("fetch_error") and src["enabled"]:
                rep.find(f"{label}: the last CRL download failed: {src['fetch_error']}")
            if not src.get("deployed"):
                if disk and disk.crl:
                    rep.find(
                        f"{label} is {'disabled' if not src['enabled'] else 'without a stored CRL'}, yet\n"
                        f"{src['disk_file']} is still on this node's disk — the deploy should have removed it."
                    )
                continue
            expected_files.add(src["disk_file"])
            if not db or "error" in db:
                continue
            if not disk or not disk.crl:
                rep.find(
                    f"{label}: the database holds CRL {crl_label_db(db)}, but this node's disk has no\n"
                    f"{src['disk_file']} — this node has not deployed it, so FreeRADIUS here does not see it."
                )
                continue
            if disk.crl["sha256_der"] == db["sha256_der"]:
                continue
            order = compare_crls(disk.crl, db)
            if order < 0:
                rep.find(
                    f"{label}: node disk has CRL {crl_label(disk.crl)}, DB has {crl_label_db(db)} — this node\n"
                    "has not deployed the newer CRL. Revocations added since are NOT enforced here."
                )
            elif order > 0:
                rep.find(
                    f"{label}: node disk has CRL {crl_label(disk.crl)}, which is LATER than the DB's\n"
                    f"{crl_label_db(db)}. The disk is kept (an older CRL never replaces a newer one); the\n"
                    "DB will catch up at the next download."
                )
            else:
                rep.find(
                    f"{label}: node disk and DB hold different CRLs ({crl_label(disk.crl)} vs {crl_label_db(db)})\n"
                    "that cannot be ordered — different issuer key or no CRL Number."
                )
        for alert in facts.get("alerts", []):
            rep.find(f"open alert: {alert.get('title')} ({alert.get('severity')})")

        # The external issuing chain of a CA signed outside Taranac. FreeRADIUS
        # never gets these CRLs (EAP-TLS trusts the issuing CA alone), so there
        # is no disk side to compare — only what was downloaded.
        upper = facts.get("upper_chain") or []
        if upper:
            rep.out("")
            rep.out("Upper-chain CRLs (external issuing chains; not given to FreeRADIUS)")
            rep.out("------------------------------------------------------------------")
            for row in upper:
                label = f"'{row['ca_name']}' chain #{row['position']} {row['subject']}"
                db = row.get("crl")
                rep.out(f"  {label}")
                rep.out(
                    f"      expires {row.get('not_after')}  url={row.get('crl_url') or '-'}  "
                    f"last download={row.get('last_fetched_at') or '-'}"
                )
                if db and "error" in db:
                    rep.out(f"      DB : {db['error']}")
                elif db:
                    rep.out(
                        f"      DB : {'#' + db['crl_number'] if db['crl_number'] else 'no CRL Number'}"
                        f"  thisUpdate {db['this_update']}  nextUpdate {db['next_update']}"
                        f"  revoked {db['revoked_count']}"
                    )
                else:
                    rep.out("      DB : no CRL stored")
                if row.get("expired"):
                    rep.find(f"{label}: this certificate has expired — every chain through it fails.")
                if row.get("fetch_error") and row.get("ca_enabled"):
                    rep.find(f"{label}: the last CRL download failed: {row['fetch_error']}")

    analyse_policy(rep, facts, eap, pol, check_on)
    analyse_ocsp(rep, facts, eap, pol)

    # ── when does radiusd pick it up ─────────────────────────────────────────
    if crls and check_on:
        newest = max(crls.values(), key=lambda f: f.mtime)
        rep.out("")
        rep.out(f"  newest CRL file: {newest.name}, written {stamp(newest.mtime)}")
        if started is not None and started < newest.mtime and (inv.radiusd_age or 0) < RELOAD_FLOOR_S:
            rep.find(
                f"radiusd started at {stamp(started)}, before the newest CRL ({newest.name},\n"
                f"written {stamp(newest.mtime)}), and has run only {inv.radiusd_age} s. Its CA store is\n"
                f"rebuilt on the first new TLS session after {stamp(started + RELOAD_FLOOR_S)}: the new CRL\n"
                "applies at the next TLS session after that time — not before."
            )
        elif started is not None and started >= newest.mtime:
            rep.out("  radiusd started after the newest CRL file was written — it has loaded it.")
        elif now - newest.mtime < RELOAD_FLOOR_S:
            rep.find(
                f"The newest CRL ({newest.name}) was written only {now - newest.mtime} s ago. radiusd\n"
                f"re-reads the directory at most every {RELOAD_FLOOR_S} s, on a new TLS session: it applies no later\n"
                f"than the first TLS session after {stamp(newest.mtime + RELOAD_FLOOR_S)}.",
                tag="[note]",
            )

    # ── the window ───────────────────────────────────────────────────────────
    rep.out("")
    rep.out("EAP-TLS in the window")
    rep.out("---------------------")
    rep.out(f"  logs read: {', '.join(win.files_read) or '(none)'}")
    total = sum(len(v) for v in win.rejects.values())
    if total:
        parts = [f"{reason} ×{len(users)}" for reason, users in sorted(win.rejects.items())]
        rep.out(f"  TLS rejects: {total} — " + ", ".join(parts))
        for reason, users in sorted(win.rejects.items()):
            named = sorted({u for u in users if u})
            if named:
                rep.out(f"    {reason}: {', '.join(named)}")
        rep.find(
            f"{total} EAP-TLS reject(s) in the window: " + ", ".join(parts) + ".\n"
            "radiusd does not log the client certificate's serial when the handshake fails,\n"
            "so the serials checked below are from ACCEPTED sessions only.",
            tag="[window]",
        )
    else:
        rep.out("  TLS rejects: none")
    analyse_policy_window(rep, win, pol)
    analyse_ocsp_window(rep, win)
    by_issuer = index_crls_by_issuer(crls)
    for serial, (cn, issuer, count) in sorted(win.accepted.items()):
        listed = by_issuer.get(dn_key(issuer), [])
        line = f"  accepted serial {serial} (CN {cn}, issuer {issuer}) ×{count}: "
        if not listed:
            issuer_certs = pol.certs_by_dn.get(dn_key(issuer), [])
            if pol.known and issuer_certs and not any(chain_needs_crl(c) for c in issuer_certs):
                rep.out(line + "no CRL of this issuer on disk — not configured, not checked by policy")
                continue
            rep.out(line + "no CRL of this issuer on disk")
            if check_on:
                rep.find(
                    f"Certificate serial {serial} (CN {cn}) was accepted, but no CRL of its issuer\n"
                    f"{issuer} is on this node's disk — its revocation status was not checked.",
                    tag="[window]",
                )
            continue
        hit = [f for f in listed if serial in f.revoked]
        if hit:
            f = hit[0]
            rep.out(line + f"REVOKED in {f.name} {crl_label(f.crl or {})}")
            rep.find(
                f"Certificate serial {serial} (CN {cn}) was ACCEPTED in the window, but it is revoked\n"
                f"in the CRL of {issuer} {crl_label(f.crl or {})} on this node's disk ({f.name}).\n"
                + (
                    "radiusd has not loaded that CRL yet — see the reload timing above."
                    if check_on
                    else "CRL checking is off, so the revocation is not enforced."
                ),
                tag="[window]",
            )
        elif inv.serials_listed:
            labels = ", ".join(f"{f.name} {crl_label(f.crl or {})}" for f in listed)
            rep.out(line + f"not listed in {labels}")
        else:
            rep.out(line + "(revoked serials were not collected)")
    if not total and not win.accepted and not win.by_issuer and not win.unchecked and not win.ocsp:
        rep.out("  no EAP-TLS authentication was logged in the window")
    return rep


def crl_label_db(db: dict[str, Any]) -> str:
    return crl_label({"crl_number": db.get("crl_number"), "this_update": iso_time(db.get("this_update"))})


def compare_crls(disk: dict[str, Any], db: dict[str, Any]) -> int:
    """>0 when the disk CRL is later, <0 when earlier, 0 when they cannot be ordered."""
    dn, bn = disk.get("crl_number"), db.get("crl_number")
    if dn and bn:
        try:
            a, b = int(dn, 16), int(bn, 16)
            return int(a > b) - int(a < b)
        except ValueError:
            pass
    ta, tb = disk.get("this_update"), iso_time(db.get("this_update"))
    if ta is None or tb is None:
        return 0
    return int(ta > tb) - int(ta < tb)


def index_crls_by_issuer(crls: dict[str, DirFile]) -> dict[tuple[tuple[str, str], ...], list[DirFile]]:
    out: dict[tuple[tuple[str, str], ...], list[DirFile]] = {}
    for f in crls.values():
        out.setdefault(dn_key((f.crl or {}).get("issuer", "")), []).append(f)
    return out


def _read(path: str | None) -> str | None:
    if not path:
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--facts")
    ap.add_argument("--eap")
    ap.add_argument("--logs")
    ap.add_argument("--findings-out", help="write the summary findings here")
    args = ap.parse_args(argv)

    inv = parse_inventory(_read(args.inventory) or "")
    facts = None
    raw = _read(args.facts)
    if raw:
        try:
            facts = json.loads(raw)
        except json.JSONDecodeError:
            facts = None
        if isinstance(facts, dict) and "error" in facts and "sources" not in facts:
            facts = None
    eap_text = _read(args.eap)
    eap = parse_eap(eap_text) if eap_text else None
    rep = analyse(inv, facts, eap, scan_logs(args.logs or ""))

    print("EAP-TLS revocation (CRL and OCSP) — this node")
    print("=============================================")
    print(f"collected: {stamp(inv.now)}")
    print()
    print("\n".join(rep.lines))
    print()
    print("Findings")
    print("--------")
    print("\n".join(rep.findings) if rep.findings else "  (nothing noticed)")
    if args.findings_out:
        with open(args.findings_out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rep.findings) + ("\n" if rep.findings else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
