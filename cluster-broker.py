#!/usr/bin/env python3
"""cluster-broker.py — the one-shot join broker that runs on the PRIMARY's host.

Started by `./taranac cluster add-node` / `add-witness`, it listens for exactly one
joining machine, hands it everything that machine needs, and exits. It is not a
daemon: nothing of it survives the join.

WHY THIS RUNS ON THE HOST AND NOT IN THE `api` CONTAINER
--------------------------------------------------------
The joining node needs three things the API physically cannot provide:

  1. Values out of the host's `.env`, which the container does not own.
  2. A signed etcd leaf — and the etcd CA *private key* lives in `config/etcd-ca/`
     on the seed host. `ha-convert.sh` treats "the CA key never reaches a
     network-facing container" as an invariant, and this respects it: the key is
     read by a short-lived host process, never mounted anywhere.
  3. MASTER_KEY, which is deliberately absent from the container's join-config
     response (`membership.py::_JOIN_CONFIG_KEYS`) precisely so the API can never
     serve it.

No compose file in this product mounts the docker socket, and `install.sh` creates
no systemd unit, so a container also could not restart the stack afterwards. The
broker is therefore a host-side process by necessity, not by preference.

THE TOKEN DOES DOUBLE DUTY, WITH DOMAIN SEPARATION
--------------------------------------------------
The operator carries ONE secret to the joining machine: the join token, printed on
this console inside a ready-to-paste command. From it both sides derive two
independent keys via HKDF:

    HKDF(token, info="taranac-ha-join-auth-v1")   -> what the client presents
    HKDF(token, info="taranac-ha-join-wrap-v1")   -> what wraps MASTER_KEY

The split is load-bearing. Without it the value presented as a bearer credential
IS the decryption key: one proxy log, one traffic capture, one shell history and
the KEK is readable by whoever holds the transcript. With it, the raw token never
travels at all — it exists only on the two consoles and in the operator's
clipboard — and the auth material is useless for decryption.

The AES-GCM wrap sits UNDER TLS, not instead of it. TLS protects the channel; the
wrap means the KEK is never plaintext at any layer that might be logged, buffered
or terminated by something in between.

WHY THE KEK MAY TRAVEL HERE AT ALL
----------------------------------
The invariant that keeps MASTER_KEY out of the API is "a stolen database or backup
cannot be decrypted". This broker does not weaken it: the key still never lands in
the database, in replicated data, or in a backup archive. Meanwhile the same join
token already unlocks POSTGRES_PASSWORD and SECRET_KEY through the API's
join-config, and it grants a full clone of the database — so the KEK is not a new
trust class here, it is being brought into line with what the token already opens.
The channel is ephemeral, single-token, explicitly fingerprint-pinned, and driven
by an operator standing at both ends within the same minute.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent

# HKDF info labels. Versioned so a future scheme change derives distinct keys and an
# old client fails closed rather than silently interoperating with new semantics.
INFO_AUTH = b"taranac-ha-join-auth-v1"
INFO_WRAP = b"taranac-ha-join-wrap-v1"

# The cluster-wide .env keys a joining node adopts. Deliberately the SAME set the
# API serves (membership.py::_JOIN_CONFIG_KEYS) plus nothing: the broker is a second
# delivery route for the same data, not a wider one. MASTER_KEY is NOT here — it
# travels wrapped, through its own endpoint, so it can never be served by accident.
CONFIG_KEYS = (
    "TARANAC_CLUSTER_NAME",
    # The ring's identity (etcd's cluster token). Non-secret, and MANDATORY for a
    # joining member: etcd derives its ClusterID from this, so a node that does not
    # receive it bootstraps a ring of its own and never joins ours.
    "TARANAC_CLUSTER_ID",
    # When the ring was formed — non-secret, and the companion of the id above: the
    # rehearsal gate dates the cluster from it, and a node that minted its own would
    # make every grown cluster read as young.
    "TARANAC_CLUSTER_FORMED_AT",
    "DB_HOSTS",
    "ETCD_HOSTS",
    "ETCD_INITIAL_CLUSTER",
    "ETCD_CLIENT_SCHEME",
    "PG_ALLOW_CIDR",
    "DB_CONNECT_TIMEOUT",
    "TARANAC_VERSION",
    "POSTGRES_PASSWORD",
    "POSTGRES_REPLICATION_PASSWORD",
    "SECRET_KEY",
    "TARANAC_MFA_API_KEY",
    "PATRONI_REST_PASSWORD",
)


def fail(msg: str) -> None:
    """Abort with a message that carries its own remedy. Never a traceback."""
    print(f"cluster-broker: {msg}", file=sys.stderr)
    raise SystemExit(1)


def step(n: int, total: int, msg: str) -> None:
    """One line per step, printed BEFORE the work — the operator watches progress."""
    print(f"  [{n}/{total}] {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"        ✓ {msg}", flush=True)


try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover - environment guard
    fail(
        "python3-cryptography is not installed, and the join channel cannot wrap the\n"
        "  master key without it. Install it, then re-run:\n"
        "    sudo apt install -y python3-cryptography     # Debian / Ubuntu\n"
        "    sudo dnf install -y python3-cryptography     # RHEL / Fedora / Rocky"
    )


# ── Key derivation ────────────────────────────────────────────────────────────


def hkdf(token: str, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 HKDF-SHA256, no salt.

    Implemented on hmac/hashlib rather than pulled from `cryptography` so the two
    ends of this protocol can be re-implemented anywhere (the client half runs in
    bash + python on a machine we do not control the packages of). Extract-then-
    expand with a fixed empty salt is the standard construction for a
    high-entropy input like a 32-byte urlsafe token.
    """
    prk = hmac.new(b"\x00" * hashlib.sha256().digest_size, token.encode(), hashlib.sha256).digest()
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def wrap_secret(token: str, plaintext: bytes) -> str:
    """AES-256-GCM under the wrap key. Returns base64(nonce || ciphertext || tag)."""
    key = hkdf(token, INFO_WRAP)
    nonce = secrets.token_bytes(12)
    blob = nonce + AESGCM(key).encrypt(nonce, plaintext, None)
    return base64.b64encode(blob).decode()


# ── The host's .env ───────────────────────────────────────────────────────────


def read_env(env_file: Path) -> dict[str, str]:
    """Parse the bundle's .env into a dict.

    Deliberately NOT `os.environ`: the broker must serve what this node's .env
    actually says, which is the same thing its containers were started from and
    the thing an operator would read. Mirrors `getenv()` in the bundle's shell
    scripts — last assignment wins, `export ` tolerated, quotes stripped.
    """
    if not env_file.is_file():
        fail(
            f"no .env at {env_file} — the broker must run from the bundle directory of an\n"
            "  installed node. cd into it (usually /opt/taranac) and re-run."
        )
    values: dict[str, str] = {}
    for raw in env_file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"^export\s+", "", line)
        key, sep, val = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        values[key] = val
    return values


# ── The broker's own TLS identity ─────────────────────────────────────────────


def make_tls_identity(workdir: Path, address: str) -> tuple[Path, str]:
    """Mint a throwaway self-signed cert for this one join, return (pem, fingerprint).

    Deliberately NOT reusing the node's real TLS material: this listener exists for
    minutes and its trust is established out-of-band by the operator reading the
    fingerprint off THIS console and typing it on the other machine. That is
    stronger than the collector's trust-on-first-use, and it is affordable here
    precisely because a human is standing at both ends at the same time.
    """
    pem = workdir / "broker.pem"
    subj = "/CN=taranac-join-broker"
    san = f"IP:{address},IP:127.0.0.1,DNS:localhost" if _is_ipv4(address) else f"DNS:{address},IP:127.0.0.1"
    proc = subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(pem), "-out", str(pem), "-days", "1",
            "-subj", subj, "-addext", f"subjectAltName={san}",
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        fail(f"could not generate the broker's TLS certificate:\n  {proc.stderr.strip()}")
    pem.chmod(0o600)
    der = subprocess.run(
        ["openssl", "x509", "-in", str(pem), "-outform", "DER"], capture_output=True
    ).stdout
    return pem, hashlib.sha256(der).hexdigest()


def _is_ipv4(value: str) -> bool:
    return bool(re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", value))


def _version_key(version: str) -> tuple[tuple[int, ...], int, tuple[tuple[int, int | str], ...]]:
    """Order 1.3.1 < 1.3.2-rc1 < 1.3.2-rc2 < 1.3.2 (a final release after its pre-releases)."""
    base, _, pre = version.lstrip("v").partition("-")
    nums = tuple(int(p) if p.isdigit() else 0 for p in base.split("."))
    parts = tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.]|(?<=\D)(?=\d)", pre) if p)
    return nums, 0 if pre else 1, parts


def version_newer(a: str, b: str) -> bool:
    """True when release ``a`` is newer than ``b``."""
    return _version_key(a) > _version_key(b)


# ── The request handler ───────────────────────────────────────────────────────


class BrokerState:
    """What the broker serves, and what it has observed. One join, one instance."""

    def __init__(
        self,
        token: str,
        env: dict[str, str],
        node_name: str,
        node_address: str,
        role: str,
        wizard: bool = False,
    ) -> None:
        self.token = token
        self.env = env
        self.node_name = node_name
        self.node_address = node_address
        self.role = role
        self.wizard = wizard
        self.expected_auth = base64.b64encode(hkdf(token, INFO_AUTH)).decode()
        self.served: set[str] = set()
        self.done = threading.Event()
        self.failure: str | None = None
        #: The joiner's own bundle version, as it reported it on completion — what the
        #: wizard records for a witness whose ring could not take a write yet.
        self.joiner_version = ""
        #: The last /join/config was refused for the joiner's bundle version and
        #: nothing has been served since: the failure report that follows it is the
        #: joiner's exit, not the end of this join (see _route_complete).
        self.version_refused = False


class Handler(BaseHTTPRequestHandler):
    state: BrokerState

    # ── plumbing ──────────────────────────────────────────────────────────
    def log_message(self, fmt: str, *args: object) -> None:  # noqa: A002
        """Silence the stdlib's per-request stderr spam; we narrate our own steps."""

    def _send(self, code: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        """Constant-time check of the presented auth material.

        `hmac.compare_digest` rather than `==`: a timing side channel on a bearer
        credential is cheap to avoid and expensive to discover later.
        """
        presented = self.headers.get("X-Taranac-Join-Auth", "")
        if not presented or not hmac.compare_digest(presented, self.state.expected_auth):
            self._send(401, {"error": "join authentication failed"})
            print(
                "        ! a caller presented invalid join credentials — ignoring it "
                "(is the token on the other machine the one printed above?)",
                flush=True,
            )
            return False
        return True

    def _body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 1_000_000:
            return {}
        try:
            parsed = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            return {}
        return parsed if isinstance(parsed, dict) else {}

    # ── routes ────────────────────────────────────────────────────────────
    def do_POST(self) -> None:  # noqa: N802  (stdlib naming)
        routes = {
            "/join/config": self._route_config,
            "/join/sign-csr": self._route_sign_csr,
            "/join/secrets": self._route_secrets,
            "/join/complete": self._route_complete,
        }
        handler = routes.get(self.path)
        if handler is None:
            self._send(404, {"error": "no such endpoint"})
            return
        if not self._authed():
            return
        handler()

    def _route_config(self) -> None:
        """The cluster-wide .env values, plus who this node is meant to be."""
        if self._refuse_other_bundle():
            return
        cfg = {key: self.state.env.get(key, "") for key in CONFIG_KEYS}
        cfg["NODE_NAME"] = self.state.node_name
        cfg["NODE_ADDRESS"] = self.state.node_address
        cfg["NODE_ROLE"] = self.state.role
        # The joining machine suppresses its own "what to do next" epilogue when the
        # wizard is driving: those blocks describe the MANUAL runbook and would tell an
        # operator to run a convert the wizard already ran, or to SCP files that now
        # travel as a CSR. Printed commands mean "you have something to do".
        cfg["WIZARD_DRIVEN"] = "1" if self.state.wizard else ""
        self.state.served.add("config")
        ok(f"served the cluster configuration to {self.client_address[0]}")
        self._send(200, {"config": cfg})

    def _refuse_other_bundle(self) -> bool:
        """A database node joins on the cluster's version — bundle AND images.

        The join hands the node the cluster's TARANAC_VERSION (its images); its
        bundle files (the taranac wrapper, the updater, the wizard, the join scripts)
        are whatever it was installed from. A host installed from the public 1.3.1
        bundle and joined to a 1.3.2-rc1 cluster ran rc1 images under 1.3.1 scripts
        (`./taranac cluster remove-witness` → "invalid choice"). So the joiner says
        which bundle it runs, and anything but the cluster's version is refused here,
        before a single value is served. A joiner that says NOTHING is an ha-join
        older than this check — exactly the case in the field — and is refused too:
        this side is the only one that can stop it, and its console prints our error.

        The refusal does not end the join: the broker keeps waiting, so the operator
        brings that host's bundle up with the one command named and runs the SAME
        join command again. A witness carries no bundle-driven commands of its own
        and is not checked here.
        """
        if self.state.role != "replica":
            return False
        want = self.state.env.get("TARANAC_VERSION", "")
        have = str(self._body().get("bundle_version") or "")
        if not want or have == want:
            self.state.version_refused = False
            return False
        said = have or "older than 1.3.2 (its ha-join.sh does not say which)"
        self.state.version_refused = True
        if have and version_newer(have, want):
            # A fresh machine from a newer bundle, an older cluster: taking that machine
            # back is a dead end (its database is already on the newer schema).
            print(
                f"        ! {self.client_address[0]} runs Taranac bundle {have}, NEWER than this cluster's {want}.\n"
                f"          Still waiting — update the cluster to {have} first, or install that machine from the {want} bundle.",
                flush=True,
            )
            self._send(
                409,
                {
                    "error": (
                        f"this host's Taranac bundle is {have}, NEWER than the cluster's {want}. A node joins on "
                        "the cluster's own version. Nothing on this host has been changed. Either update the "
                        f"cluster to {have} first (on its nodes, replicas first, as the updater directs: "
                        f"./taranac update --version {have}) and then run the add command on the primary again, "
                        f"or install this machine from the cluster's own bundle (taranac-bundle-{want}.tar.gz) "
                        "and run this same ha-join command again."
                    )
                },
            )
            return True
        print(
            f"        ! {self.client_address[0]} runs Taranac bundle {said}; the cluster runs {want}.\n"
            f"          Still waiting — on that machine:  ./taranac update --version {want}\n"
            "          then the same ha-join command again.",
            flush=True,
        )
        self._send(
            409,
            {
                "error": (
                    f"this host's Taranac bundle is {said}, but the cluster runs {want}. A node joins "
                    "on the cluster's own version — its scripts and its images together. Nothing on "
                    "this host has been changed, and the primary keeps waiting for it. On this host run:\n"
                    f"    ./taranac update --version {want}\n"
                    "  then run this same ha-join command again."
                )
            },
        )
        return True

    def _route_sign_csr(self) -> None:
        """Sign the joining machine's CSR with the cluster's etcd CA.

        🔑 The SANs are OURS, never the requester's. `ha-etcd-ca.sh sign-csr` takes
        them as an argument and ignores whatever the CSR embeds — a CSR is authored
        by the party being authenticated, so honouring its subjectAltName would let
        a joining node mint itself a certificate for the primary's address. We pass
        the address the operator named when issuing this token.
        """
        csr_pem = str(self._body().get("csr") or "")
        if "BEGIN CERTIFICATE REQUEST" not in csr_pem:
            self._send(400, {"error": "no PEM certificate request in the body"})
            return
        ca_dir = HERE / "config" / "etcd-ca"
        if not (ca_dir / "ca.key").is_file():
            self._send(
                503,
                {
                    "error": (
                        f"this node holds no etcd CA at {ca_dir}. Signing runs on the SEED "
                        "(the node converted with ha-convert). Run the wizard there."
                    )
                },
            )
            return
        with tempfile.TemporaryDirectory() as tmp:
            csr_file = Path(tmp) / "node.csr"
            crt_file = Path(tmp) / "node.crt"
            csr_file.write_text(csr_pem)
            sans = f"{self.state.node_address},127.0.0.1,localhost"
            proc = subprocess.run(
                [
                    str(HERE / "ha-etcd-ca.sh"), "sign-csr",
                    str(ca_dir), str(csr_file), str(crt_file), sans,
                ],
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0 or not crt_file.is_file():
                detail = (proc.stderr or proc.stdout).strip().splitlines()
                self._send(400, {"error": detail[-1] if detail else "the CSR was refused"})
                print(f"        ! refused a CSR: {detail[-1] if detail else 'unknown reason'}", flush=True)
                return
            self.state.served.add("csr")
            ok(f"signed the etcd certificate for {self.state.node_name} (SAN {sans})")
            self._send(200, {"certificate": crt_file.read_text(), "ca": (ca_dir / "ca.crt").read_text()})

    def _route_secrets(self) -> None:
        """MASTER_KEY and the shared mfa key, wrapped under HKDF(token, "wrap")."""
        master_key = self.state.env.get("MASTER_KEY", "")
        if not master_key or master_key == "__GENERATE__":
            self._send(503, {"error": "this node's .env carries no usable MASTER_KEY"})
            return
        payload: dict[str, object] = {"master_key": wrap_secret(self.state.token, master_key.encode())}
        mfa = HERE / "config" / "cluster-secrets" / "mfa.enckey"
        if mfa.is_file():
            payload["mfa_enckey"] = wrap_secret(self.state.token, mfa.read_bytes())

        # ── The etcd CA travels too ───────────────────────────────────────────
        # This deliberately REVERSES the earlier invariant that the CA private key
        # never leaves the seed. That rule made the cluster unable to heal: the key
        # existed on exactly one disk and was not even in the product's backup, so
        # losing that machine meant no node could ever be added again — and the seed
        # itself could not be replaced, because a replacement needs a signed
        # certificate. An HA product whose recovery depends on one surviving disk is
        # not one.
        #
        # What the rule actually bought is small. A node already holds MASTER_KEY,
        # the database password, SECRET_KEY and a full copy of the data; whoever owns
        # it owns the cluster's secrets and is already inside the interconnect. Adding
        # "can mint an etcd server certificate" to that changes little. Being unable
        # to replace a lost node changes everything.
        ca_key = HERE / "config" / "etcd-ca" / "ca.key"
        ca_crt = HERE / "config" / "etcd-ca" / "ca.crt"
        if ca_key.is_file() and ca_crt.is_file():
            payload["etcd_ca_key"] = wrap_secret(self.state.token, ca_key.read_bytes())
            payload["etcd_ca_crt"] = wrap_secret(self.state.token, ca_crt.read_bytes())
        self.state.served.add("secrets")
        ok("served the wrapped cluster secrets (master key + etcd CA, never in plaintext)")
        self._send(200, payload)

    def _route_complete(self) -> None:
        """The joining machine reports the outcome. This is what ends the broker.

        It reports, it does not merely stop: a broker that exited 0 because its
        timer ran out would be an installer claiming a success it never observed.
        """
        body = self._body()
        succeeded = bool(body.get("ok"))
        detail = str(body.get("detail") or "")
        self._send(200, {"acknowledged": True})
        if not succeeded and self.state.version_refused and not self.state.served:
            # The joiner's exit after OUR version refusal (an older ha-join reports
            # every exit as a failure). Nothing was served, nothing changed on either
            # side: keep waiting for it to come back on the cluster's version.
            return
        self.state.failure = None if succeeded else (detail or "the joining node reported a failure")
        self.state.joiner_version = str(body.get("version") or "").strip()[:64]
        self.state.done.set()


# ── Entry point ───────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="cluster-broker.py",
        description="One-shot join broker for the Taranac HA wizard (runs on the primary's host).",
    )
    ap.add_argument("--token", required=True, help="the join token this session accepts (exactly one)")
    ap.add_argument("--node-name", required=True, help="the joining node's cluster name")
    ap.add_argument("--node-address", required=True, help="the joining node's routable address")
    ap.add_argument("--role", default="replica", choices=("replica", "witness"))
    ap.add_argument("--listen", default="0.0.0.0", help="bind address (default: all interfaces)")
    ap.add_argument("--port", type=int, default=9443)
    ap.add_argument("--advertise", default="", help="address to print in the operator's command")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds to wait for the join (default 1800)")
    ap.add_argument("--env-file", default=str(HERE / ".env"))
    ap.add_argument("--print-only", action="store_true", help="print the command and exit (no listener)")
    ap.add_argument(
        "--wizard",
        action="store_true",
        help="the wizard is driving: joining machines suppress their own next-step epilogues",
    )
    ap.add_argument(
        "--report-file",
        default="",
        help="on success, write 'version=<the joiner's bundle version>' here (empty when it did not say)",
    )
    args = ap.parse_args()

    env = read_env(Path(args.env_file))
    advertise = args.advertise or env.get("NODE_ADDRESS") or args.listen

    with tempfile.TemporaryDirectory(prefix="taranac-broker-") as tmp:
        workdir = Path(tmp)
        pem, fingerprint = make_tls_identity(workdir, advertise)

        state = BrokerState(args.token, env, args.node_name, args.node_address, args.role, args.wizard)
        Handler.state = state

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(pem))
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2

        httpd = ThreadingHTTPServer((args.listen, args.port), Handler)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

        script = "ha-join.sh" if args.role == "replica" else "witness-join.sh"
        # flush=True is load-bearing, not cosmetic: this block is what the operator has
        # to READ WHILE THE BROKER WAITS. Python line-buffers stdout only when it is a
        # tty, so piped into a log, a wrapper, or `tee` the whole invitation would sit
        # in the buffer until exit — i.e. appear only once it is useless.
        print(
            "\n"
            "  Run this on the machine you are adding — the address is visible and editable,\n"
            "  so correct it if that machine reaches this one by a different name or port:\n"
            "\n"
            f"      ./{script} \\\n"
            f"          --broker {advertise}:{args.port} \\\n"
            f"          --token {args.token} \\\n"
            f"          --pin sha256:{fingerprint}\n"
            "\n"
            f"  Waiting for {args.node_name} ({args.node_address}) to connect… Ctrl-C aborts.\n",
            flush=True,
        )

        if args.print_only:
            httpd.server_close()
            return 0

        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        deadline = time.monotonic() + args.timeout
        try:
            while not state.done.is_set():
                if time.monotonic() > deadline:
                    httpd.shutdown()
                    fail(
                        f"no machine completed the join within {args.timeout}s.\n"
                        f"  The broker served: {', '.join(sorted(state.served)) or 'nothing'}.\n"
                        "  Nothing was changed on this node. Check that the joining machine can\n"
                        f"  reach {advertise}:{args.port} (firewall?), then run the add command again."
                    )
                time.sleep(0.5)
        except KeyboardInterrupt:
            httpd.shutdown()
            fail("aborted by the operator. Nothing was changed on this node.")
        httpd.shutdown()

        if state.failure:
            fail(
                f"the joining machine reported a failure: {state.failure}\n"
                "  Nothing was changed on this node. Fix the cause on that machine and run\n"
                "  the add command again — a fresh token is issued each time."
            )
        stamp = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        print(f"  {state.node_name} ({state.node_address}) completed its join at {stamp}.")
        if args.report_file:
            Path(args.report_file).write_text(f"version={state.joiner_version}\n", encoding="utf-8")
        return 0


if __name__ == "__main__":
    if shutil.which("openssl") is None:
        fail("openssl is not installed on this host, and the join channel needs it. Run: sudo bash bootstrap.sh")
    sys.exit(main())
