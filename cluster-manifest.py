#!/usr/bin/env python3
# =============================================================================
# cluster-manifest.py — read and write config/cluster.yml, the HA cluster
# manifest (docs/spec/backend/infra/cluster.md, "The manifest").
#
# WHY THIS EXISTS AT ALL
# ----------------------
# The wizard commands (`./taranac cluster init | add-node | add-witness |
# remove-node`) are bash, and bash cannot safely edit YAML. It also must not
# LEARN to: the manifest is the primary's declared source of truth for the whole
# cluster, and a sed-edited source of truth is a source of drift. So the bash
# side shells out to this helper — exactly the way ha-join.sh:92 already shells
# out to python3 to read the join-config JSON — and never touches the file
# itself.
#
# WHY A SURGICAL TEXT SPLICE, NOT yaml.dump()
# -------------------------------------------
# Ownership is SPLIT INSIDE THE FILE. `nodes:` is machine-written; `skip:` is the
# one section an operator edits by hand, with reasons they wrote for their future
# self. PyYAML has no concept of a comment: load+dump would silently return the
# file with every comment gone and every key reordered — i.e. it would eat the
# operator's work as a side effect of adding a node. That is precisely the drift
# this file was split out of .env to remove.
#
# So writes NEVER re-serialise the document. They locate the top-level `nodes:`
# block in the raw text, replace exactly those lines, and leave every other byte
# untouched. PyYAML is used for READING and VALIDATION only, where it is exactly
# the right tool. Consequences, stated plainly:
#   * survives: `skip:` and its entries, their order, all comments outside the
#     nodes block, key order, blank lines, indentation style, trailing newline.
#   * does NOT survive: comments written INSIDE the `nodes:` block. That block is
#     machine-owned and is rewritten wholesale; a comment there has no stable
#     anchor to be reattached to. Put notes above `nodes:` or in `skip:`.
#
# CONTRACT WITH THE CALLER (bash)
# -------------------------------
# * stdout is MACHINE output only — either `eval`-able `CM_KEY='value'` lines
#   (shell-quoted, prefixed CM_ so nothing collides with the .env names these
#   scripts already carry, e.g. NODE_ADDRESS) or TAB-separated records for
#   `while read`. jq is NOT installed on the appliance and is never required.
# * stderr is for humans: progress and errors.
# * EVERY error names its own remedy. Hard house rule — an operator must never
#   have to guess the next command, and must never see a traceback.
#
# Exit codes (a caller can branch on these):
#    0  success
#    1  error — bad manifest, bad argument value, unwritable file (see stderr)
#    2  usage error (unknown subcommand / unknown option)
#    3  add-node: the node is in the manifest AND in the cluster → already added
#    4  add-node: the node is in the cluster but NOT in the manifest → the source
#       of truth has drifted; the caller must stop and offer adopt/decommission
#    5  lookup miss — no such node / the value is not set
#    6  PyYAML is missing (see the install line printed on stderr)
#
# Usage:  ./cluster-manifest.py <command> [options]     ( --help for the list )
# =============================================================================
import os
import re
import shlex
import sys
import ipaddress

PROG = "cluster-manifest"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_ALREADY_ADDED = 3
EXIT_DRIFT = 4
EXIT_NOT_FOUND = 5
EXIT_NO_PYYAML = 6

# ── Dependency guard ─────────────────────────────────────────────────────────
# PyYAML ships in the appliance image (python3-yaml, 6.0.1) and in every distro
# we support, so this is a "someone built a minimal box" path, not a normal one.
# Same shape as install.sh:48-49 — name the missing thing AND the command that
# installs it. An ImportError traceback at an operator is a defect.
try:
    import yaml
except ImportError:  # pragma: no cover - exercised by the test's stub-import run
    sys.stderr.write(
        f"{PROG}: PyYAML is not installed, and the cluster manifest cannot be read without it.\n"
        "   Install it, then re-run:\n"
        "     sudo apt install -y python3-yaml      # Debian / Ubuntu\n"
        "     sudo dnf install -y python3-pyyaml    # RHEL / Fedora / Rocky\n"
    )
    sys.exit(EXIT_NO_PYYAML)


HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FILE = os.path.join(HERE, "config", "cluster.yml")

ROLES = ("primary", "witness", "replica")
DEFAULT_ROLE = "replica"
DEFAULT_CLUSTER = "taranac"

# Names go into ETCD_NAME / TARANAC_NODE_NAME / the Patroni member name, so keep
# them to what all three accept without quoting.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
HOSTNAME_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
                         r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$")


class ManifestError(Exception):
    """An operator-facing failure. `remedy` is mandatory — see the house rule."""

    def __init__(self, message, remedy, path=None, line=None, code=EXIT_ERROR):
        super().__init__(message)
        self.message = message
        self.remedy = remedy
        self.path = path
        self.line = line
        self.code = code

    def render(self):
        where = ""
        if self.path:
            where = f" {os.path.basename(self.path)}"
            if self.line:
                where += f" line {self.line}"
            where += ":"
        return f"{PROG}:{where} {self.message}\n   Remedy: {self.remedy}"


def fail(message, remedy, path=None, line=None, code=EXIT_ERROR):
    raise ManifestError(message, remedy, path=path, line=line, code=code)


# ── Line-aware YAML loading ──────────────────────────────────────────────────
# "A malformed manifest must fail with the offending entry named" — which means
# every validation error needs a line number. PyYAML throws the marks away once
# it has constructed plain dicts/lists, so construct dict/list SUBCLASSES that
# remember where they came from. They behave as dict/list everywhere else.
class LineDict(dict):
    line = 0


class LineList(list):
    line = 0


class _LineLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    result = LineDict()
    result.line = node.start_mark.line + 1
    seen = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        # PyYAML's default is last-wins on a duplicate key — a silent half-load,
        # which is the one thing this file must never do.
        if key in seen:
            fail(
                f"the key '{key}' is defined twice (first on line {seen[key]})",
                f"delete one of the two '{key}:' lines — YAML keeps only the last "
                "one, so the other is silently ignored.",
                line=key_node.start_mark.line + 1,
            )
        seen[key] = key_node.start_mark.line + 1
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


def _construct_sequence(loader, node, deep=False):
    result = LineList(loader.construct_object(child, deep=deep) for child in node.value)
    result.line = node.start_mark.line + 1
    return result


_LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)
_LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_SEQUENCE_TAG, _construct_sequence)


def line_of(obj, default=0):
    return getattr(obj, "line", default)


# ── Validation helpers ───────────────────────────────────────────────────────
def check_address(value, path=None, line=None, what="address"):
    """An address is a host the OTHER nodes route to — an IP literal or a DNS
    name. NOT a URL and NOT host:port: it is rendered straight into NODE_ADDRESS,
    DB_HOSTS entries and etcd member URLs, each of which appends its own port."""
    if not isinstance(value, str) or not value.strip():
        fail(f"{what} is empty",
             "give the node's routable host or IP, e.g. --address 10.0.0.2",
             path=path, line=line)
    value = value.strip()
    if "://" in value or "/" in value:
        fail(f"{what} '{value}' looks like a URL",
             "use a bare host or IP — no scheme and no path, e.g. 10.0.0.2",
             path=path, line=line)
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        pass
    # 🔑 Digits and dots ONLY means an IP was intended — so a failed parse is a TYPO,
    # not a hostname. Without this, `10.1.1.1000` (octet > 255) falls through to the
    # hostname branch, which legitimately allows digits, and a malformed address is
    # accepted, written into the manifest, into DB_HOSTS and into an etcd member URL.
    # It then fails much later, somewhere that does not mention the address at all.
    # RFC 1123 makes this safe to assert: a hostname's top-level label may not be
    # all-numeric, exactly so that names cannot be confused with addresses.
    if re.fullmatch(r"[0-9.]+", value):
        fail(f"{what} '{value}' is not a valid IP address",
             "it contains only digits and dots, so it was meant to be one — check for a "
             "typo (each part must be 0-255, e.g. 10.0.0.2). A hostname must contain "
             "at least one non-digit label.",
             path=path, line=line)
    if ":" in value:
        fail(f"{what} '{value}' contains a colon",
             "use a bare host or IP without a port — the ports are added by the "
             "tooling (5432 for Postgres, 2379/2380 for etcd)",
             path=path, line=line)
    if not HOSTNAME_RE.match(value):
        fail(f"{what} '{value}' is not a valid IP address or DNS name",
             "use an IPv4/IPv6 literal (10.0.0.2) or a resolvable hostname "
             "(node-2.example.com)",
             path=path, line=line)
    return value


def check_name(value, path=None, line=None):
    if not isinstance(value, str) or not value.strip():
        fail("a node has an empty name",
             "give it a name, or let the wizard derive one by omitting --name",
             path=path, line=line)
    value = value.strip()
    if not NAME_RE.match(value):
        fail(f"node name '{value}' is not usable",
             "use letters, digits, dot, dash or underscore (max 63 chars, starting "
             "with a letter or digit) — the name becomes ETCD_NAME and the Patroni "
             "member name, which do not accept anything else",
             path=path, line=line)
    return value


def check_role(value, path=None, line=None):
    if value is None:
        return DEFAULT_ROLE
    if not isinstance(value, str) or value.strip().lower() not in ROLES:
        fail(f"role '{value}' is not one of {', '.join(ROLES)}",
             f"set role: to one of {', '.join(ROLES)} (omit it for the default "
             f"'{DEFAULT_ROLE}')",
             path=path, line=line)
    return value.strip().lower()


def check_cidr_list(value, path=None, line=None):
    """PG_ALLOW_CIDR is a COMMA-SEPARATED list — postgres-ha/entrypoint.sh:64
    splits on commas because cluster nodes may live in different subnets."""
    if not isinstance(value, str) or not value.strip():
        fail("pg_allow_cidr is empty",
             "either remove the pg_allow_cidr: line entirely (the cluster then "
             "keeps the .env value) or set it, e.g. pg_allow_cidr: 10.0.0.0/24",
             path=path, line=line)
    parts = [p.strip() for p in value.split(",") if p.strip()]
    for part in parts:
        try:
            ipaddress.ip_network(part, strict=False)
        except ValueError:
            fail(f"pg_allow_cidr entry '{part}' is not a valid CIDR range",
                 "use network/prefix notation, comma-separated for several "
                 "subnets, e.g. 10.0.0.0/24,10.1.0.0/24",
                 path=path, line=line)
    return ",".join(parts)


# ── The manifest ─────────────────────────────────────────────────────────────
class Node:
    #: ``pending`` marks an add that was STARTED and has not been confirmed finished.
    #: It is the only thing that distinguishes "a previous add died halfway" from "the
    #: operator declared this node at init and has not got to it yet" — the two look
    #: IDENTICAL by state (in the manifest, in .env, absent from the ring and the
    #: roster), so cleaning up by state alone would silently delete the declarations
    #: that `init --node ...` exists to make. Set when add-node begins, cleared when
    #: the join is verified; a leftover therefore means exactly "was never finished".
    def __init__(self, name, address, role=DEFAULT_ROLE, line=0, pending=False):
        self.name = name
        self.address = address
        self.role = role
        self.pending = pending
        self.line = line


class Manifest:
    def __init__(self, path, text, cluster, nodes, pg_allow_cidr, skips):
        self.path = path
        self.text = text                  # the raw file, kept for the splice
        self.cluster = cluster
        self.nodes = nodes
        self.pg_allow_cidr = pg_allow_cidr
        self.skips = skips

    # -- lookups ------------------------------------------------------------
    def by_address(self, address):
        for node in self.nodes:
            if node.address == address:
                return node
        return None

    def by_name(self, name):
        for node in self.nodes:
            if node.name == name:
                return node
        return None

    def by_role(self, role):
        return [n for n in self.nodes if n.role == role]

    def next_derived_name(self, role):
        """`<cluster>-node-N` by POSITION, per the spec. N counts the non-witness
        nodes, so the witness sitting at position 2 does not consume 'node-2' —
        which is exactly the numbering in the spec's example file. A witness
        defaults to the bare name 'witness' (likewise from the example).
        Collisions bump the suffix rather than failing: a derived name must never
        be the thing that stops a join."""
        if role == "witness":
            candidate = "witness"
            counter = 1
            while self.by_name(candidate):
                counter += 1
                candidate = f"witness-{counter}"
            return candidate
        index = len([n for n in self.nodes if n.role != "witness"]) + 1
        candidate = f"{self.cluster}-node-{index}"
        while self.by_name(candidate):
            index += 1
            candidate = f"{self.cluster}-node-{index}"
        return candidate


def load(path, required=True):
    if not os.path.exists(path):
        if not required:
            return None
        fail(f"no cluster manifest at {path}",
             "create it on the future primary with:  ./taranac cluster init",
             code=EXIT_NOT_FOUND)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        fail(f"cannot read {path} ({exc.strerror})",
             f"check the file's permissions:  ls -l {path}")

    try:
        data = yaml.load(text, Loader=_LineLoader)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        line = mark.line + 1 if mark else None
        problem = getattr(exc, "problem", None) or str(exc).splitlines()[0]
        fail(f"the file is not valid YAML — {problem}",
             "YAML is indentation-sensitive: use spaces (never tabs), and keep "
             "every key of a list entry at the same indent. Fix that line and "
             f"re-check with:  ./cluster-manifest.py validate --file {path}",
             path=path, line=line)

    if data is None:
        fail("the file is empty",
             "recreate it with:  ./taranac cluster init  (or restore your copy)",
             path=path, line=1)
    if not isinstance(data, dict):
        fail("the top level of the file is not a mapping of keys",
             "the file must start with 'cluster:' and 'nodes:' at column 0 — see "
             "the example in HA.md",
             path=path, line=1)

    cluster = data.get("cluster", DEFAULT_CLUSTER)
    if not isinstance(cluster, str) or not NAME_RE.match(cluster.strip()):
        fail(f"cluster name '{cluster}' is not usable",
             "use letters, digits, dot, dash or underscore — it must match "
             "TARANAC_CLUSTER_NAME in .env",
             path=path, line=line_of(data, 1))
    cluster = cluster.strip()

    raw_nodes = data.get("nodes")
    if raw_nodes is None:
        raw_nodes = LineList()
    if not isinstance(raw_nodes, list):
        fail("'nodes:' is not a list",
             "each node is a list entry, e.g.\n"
             "     nodes:\n"
             "       - name: taranac-node-1\n"
             "         address: 10.0.0.1\n"
             "         role: primary",
             path=path, line=line_of(raw_nodes, 1))

    nodes = []
    for position, entry in enumerate(raw_nodes, start=1):
        line = line_of(entry, line_of(raw_nodes, 1))
        if not isinstance(entry, dict):
            fail(f"node entry #{position} is not a mapping (got {entry!r})",
                 "each entry needs 'name:' and 'address:' keys, indented under a "
                 "leading '- '",
                 path=path, line=line)
        unknown = sorted(set(entry) - {"name", "address", "role", "pending"})
        if unknown:
            fail(f"node entry #{position} has unknown key(s): {', '.join(unknown)}",
                 "a node entry accepts only name, address, role and pending — remove the "
                 "rest (operator notes belong in the 'skip:' section)",
                 path=path, line=line)
        if "address" not in entry:
            fail(f"node entry #{position} has no 'address:'",
                 "add the node's routable host or IP, e.g. address: 10.0.0.2",
                 path=path, line=line)
        if "name" not in entry:
            fail(f"node entry #{position} has no 'name:'",
                 "add a name, e.g. name: " + f"{cluster}-node-{position}" +
                 " — it becomes ETCD_NAME and the Patroni member name, so it "
                 "cannot be derived after the fact",
                 path=path, line=line)
        node = Node(
            name=check_name(entry["name"], path=path, line=line),
            address=check_address(entry["address"], path=path, line=line),
            role=check_role(entry.get("role"), path=path, line=line),
            pending=entry.get("pending") is True,
            line=line,
        )
        for existing in nodes:
            if existing.address == node.address:
                fail(f"two nodes share the address {node.address} "
                     f"('{existing.name}' on line {existing.line} and '{node.name}')",
                     "delete one of the two entries — an address identifies a node, "
                     "and duplicates would make the cluster's DB_HOSTS list a node "
                     "twice",
                     path=path, line=line)
            if existing.name == node.name:
                fail(f"two nodes share the name '{node.name}' "
                     f"(line {existing.line} and here)",
                     "rename one of them — the name is the etcd member name and "
                     "Patroni refuses a duplicate",
                     path=path, line=line)
        nodes.append(node)

    for role, article in (("primary", "one primary"), ("witness", "one witness")):
        found = [n for n in nodes if n.role == role]
        if len(found) > 1:
            names = ", ".join(f"'{n.name}' (line {n.line})" for n in found)
            fail(f"the manifest declares {len(found)} nodes with role '{role}': {names}",
                 f"a cluster has exactly {article}. Leave the real one as "
                 f"role: {role} and set the other(s) to role: replica",
                 path=path, line=found[1].line)

    pg_allow_cidr = data.get("pg_allow_cidr")
    if pg_allow_cidr is not None:
        pg_allow_cidr = check_cidr_list(pg_allow_cidr, path=path, line=line_of(data, 1))

    raw_skips = data.get("skip") or []
    if not isinstance(raw_skips, list):
        fail("'skip:' is not a list",
             "each skip is a list entry with node/key/reason, e.g.\n"
             "     skip:\n"
             "       - node: taranac-node-3\n"
             "         key: PG_ALLOW_CIDR\n"
             '         reason: "site behind NAT"',
             path=path, line=line_of(raw_skips, 1))
    skips = []
    for position, entry in enumerate(raw_skips, start=1):
        line = line_of(entry, line_of(raw_skips, 1))
        if not isinstance(entry, dict):
            fail(f"skip entry #{position} is not a mapping (got {entry!r})",
                 "each entry needs node:, key: and reason:, indented under a "
                 "leading '- '",
                 path=path, line=line)
        for field in ("node", "key"):
            if not entry.get(field):
                fail(f"skip entry #{position} has no '{field}:'",
                     "a skip must say which node and which setting it excuses — "
                     "preflight prints it with the reason, so an unnamed skip "
                     "would hide a real divergence",
                     path=path, line=line)
        skips.append({
            "node": str(entry["node"]),
            "key": str(entry["key"]),
            "reason": str(entry.get("reason") or "").replace("\n", " ").strip(),
            "line": line,
        })

    return Manifest(path, text, cluster, nodes, pg_allow_cidr, skips)


# ── Writing: splice the `nodes:` block, leave every other byte alone ─────────
_TOP_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:")


def _is_block_continuation(line):
    """True while the line still belongs to the block of the preceding top-level
    key. A YAML sequence under a key may be indented OR sit at column 0 with a
    leading '- ', so both count; blank and comment lines never terminate a block
    on their own (they are trimmed back afterwards)."""
    if not line.strip():
        return True
    if line.lstrip().startswith("#"):
        return True
    if line[0] in " \t":
        return True
    if line.startswith("- ") or line.rstrip() == "-":
        return True
    return False


def _find_nodes_block(lines):
    """Return (start, end) of the top-level `nodes:` block, or None. `end` is
    exclusive and is pulled back over trailing blank/comment lines so that a
    comment the operator wrote as a header for the NEXT section stays with that
    section instead of being swallowed and rewritten away."""
    start = None
    for index, line in enumerate(lines):
        if line.startswith("---") or line.startswith("..."):
            continue
        match = _TOP_KEY_RE.match(line)
        if match and match.group(1) == "nodes":
            start = index
            break
    if start is None:
        return None

    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.startswith("---") or line.startswith("..."):
            break
        if not _is_block_continuation(line):
            break
        end += 1

    while end - 1 > start and not lines[end - 1].strip():
        end -= 1
    trimmed = end
    while trimmed - 1 > start and (not lines[trimmed - 1].strip()
                                   or lines[trimmed - 1].lstrip().startswith("#")):
        trimmed -= 1
    return start, trimmed


def _scalar(value):
    """Emit a plain scalar when it is unambiguous, else double-quote it. Names,
    addresses and cluster names are validated to a safe charset, so this is
    belt-and-braces — but a value that YAML would re-read as a bool/number/null
    must be quoted or the file would not round-trip."""
    text = str(value)
    if text and re.match(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$", text) and \
            text.lower() not in ("y", "n", "yes", "no", "true", "false", "on", "off", "null", "~"):
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_nodes_block(nodes):
    if not nodes:
        # An explicit empty list, never a bare `nodes:` — a bare key reads back
        # as null and every consumer would have to special-case it.
        return "nodes: []\n"
    out = ["nodes:\n"]
    for node in nodes:
        out.append(f"  - name: {_scalar(node.name)}\n")
        out.append(f"    address: {_scalar(node.address)}\n")
        out.append(f"    role: {_scalar(node.role)}\n")
        # Written only while true, so a settled manifest carries no noise.
        if getattr(node, "pending", False):
            out.append("    pending: true\n")
    return "".join(out)


def write_nodes(manifest, nodes):
    """Replace ONLY the nodes block in the raw text, then prove the result still
    parses before it replaces the real file. Atomic (tmp + rename) so an
    interrupted wizard can never leave a half-written source of truth."""
    lines = manifest.text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    block = render_nodes_block(nodes)

    span = _find_nodes_block(lines)
    if span:
        start, end = span
        new_lines = lines[:start] + [block] + lines[end:]
    else:
        # No nodes: key yet — put it directly after `cluster:` so the file keeps
        # the documented order, else at the end of the leading comment header.
        insert_at = 0
        for index, line in enumerate(lines):
            match = _TOP_KEY_RE.match(line)
            if match and match.group(1) == "cluster":
                insert_at = index + 1
                break
            if match:
                insert_at = index
                break
            insert_at = index + 1
        new_lines = lines[:insert_at] + [block] + lines[insert_at:]

    new_text = "".join(new_lines)
    try:
        yaml.safe_load(new_text)
    except yaml.YAMLError as exc:  # pragma: no cover - a bug in the splice, not operator input
        fail(f"refusing to write — the updated manifest would not parse ({exc})",
             f"nothing was changed. Report this with a copy of {manifest.path}")
    _atomic_write(manifest.path, new_text)
    manifest.text = new_text
    manifest.nodes = nodes


def _atomic_write(path, text):
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as exc:
        fail(f"cannot create {directory} ({exc.strerror})",
             f"create it yourself and retry:  mkdir -p {directory}")
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail(f"cannot write {path} ({exc.strerror})",
             "the bundle directory must be writable by the operator running the "
             f"wizard. Fix ownership and retry:  sudo chown $(id -u):$(id -g) {directory}")


# ── Output helpers — stdout is machine-readable, stderr is for humans ────────
def emit(**pairs):
    for key, value in pairs.items():
        sys.stdout.write(f"CM_{key}={shlex.quote(str(value))}\n")


def note(message):
    sys.stderr.write(f"{PROG}: {message}\n")


# ── Argument parsing ─────────────────────────────────────────────────────────
# Hand-rolled rather than argparse, for one reason: argparse's error text has no
# room for a remedy, and "every error carries its own cure" is a house rule that
# outranks saving thirty lines here.
VALUE_OPTS = {"--file", "--cluster", "--address", "--name", "--role", "--pg-allow-cidr",
              "--other"}
FLAG_OPTS = {"--in-cluster", "--force", "--debug", "--pending"}


def parse_args(argv):
    opts = {"file": None, "cluster": None, "address": None, "name": None,
            "role": None, "pg_allow_cidr": None, "in_cluster": False,
            "force": False, "debug": False, "pending": False, "other": None}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in VALUE_OPTS:
            if index + 1 >= len(argv):
                fail(f"{arg} needs a value",
                     f"pass one, e.g. {arg} <value> — see --help",
                     code=EXIT_USAGE)
            opts[arg[2:].replace("-", "_")] = argv[index + 1]
            index += 2
            continue
        if arg in FLAG_OPTS:
            opts[arg[2:].replace("-", "_")] = True
            index += 1
            continue
        fail(f"unknown option '{arg}'",
             "run  ./cluster-manifest.py --help  for the supported options",
             code=EXIT_USAGE)
    return opts


USAGE = """\
cluster-manifest.py — read/write the HA cluster manifest (config/cluster.yml).

Commands
  init          [--cluster N] [--address A] [--name N] [--pg-allow-cidr C] [--force]
                Create the manifest. With --address, records that node as the primary.
  add-node      --address A [--name N] [--role primary|witness|replica] [--in-cluster]
                [--pending]  mark it as an add IN FLIGHT (cleared by mark-joined)
  mark-joined   (--address A | --name N)   the add finished — clear the mark
  pending                                  list adds that were started, never finished
                Record a node. Prints CM_CASE = RECORDED | RESUME | ALREADY_ADDED | DRIFT
                (exit 0 / 0 / 3 / 4). --in-cluster tells the helper that the cluster
                itself already lists this node — only the caller can know that.
  add-witness   --address A [--name N] [--in-cluster]     (= add-node --role witness)
  remove-node   (--address A | --name N)
  list          [--role R]        TAB-separated:  name <TAB> address <TAB> role
  get           (--address A | --name N)                  eval-able CM_* lines
  show                            eval-able cluster-level CM_* lines
  pg-allow-cidr                   the raw value on stdout (exit 5 if not set)
  skips                           TAB-separated:  node <TAB> key <TAB> reason
  validate                        parse + check, and say so
  compare       --other PATH      how this manifest differs from another copy.
                TAB-separated:  kind <TAB> a ready-to-print phrase, plus CM_* lines
                (CM_IDENTICAL, CM_SAME_TOPOLOGY, CM_SKIPS_ONLY_HERE/THERE,
                CM_DIFF_COUNT). Exit 0 even when they differ — differing is an
                answer, not an error; branch on CM_SAME_TOPOLOGY.

Common options
  --file PATH   the manifest (default: <bundle>/config/cluster.yml)
  --debug       print a traceback on an unexpected internal error

stdout is machine output (eval-able CM_* or TAB records); stderr is for humans.
Exit: 0 ok · 1 error · 2 usage · 3 already added · 4 manifest drift · 5 not found
      · 6 PyYAML missing
"""


# ── Commands ─────────────────────────────────────────────────────────────────
def cmd_init(opts):
    path = opts["file"] or DEFAULT_FILE
    if os.path.exists(path) and not opts["force"]:
        fail(f"{path} already exists",
             "the manifest is the cluster's source of truth and is not recreated "
             "by accident. Add nodes with  ./taranac cluster add-node, or pass "
             "--force to overwrite it (this DISCARDS any 'skip:' entries you "
             "wrote by hand)")

    cluster = opts["cluster"] or DEFAULT_CLUSTER
    if not NAME_RE.match(cluster):
        fail(f"cluster name '{cluster}' is not usable",
             "use letters, digits, dot, dash or underscore — it must match "
             "TARANAC_CLUSTER_NAME in .env")
    pg_allow_cidr = opts["pg_allow_cidr"]
    if pg_allow_cidr:
        pg_allow_cidr = check_cidr_list(pg_allow_cidr)

    nodes = []
    if opts["address"]:
        address = check_address(opts["address"])
        name = check_name(opts["name"]) if opts["name"] else f"{cluster}-node-1"
        nodes.append(Node(name=name, address=address, role="primary"))
    elif opts["name"]:
        fail("--name was given without --address",
             "a node needs an address the other nodes route to: "
             "--address <this host's IP> --name " + opts["name"])

    header = (
        "# Taranac HA cluster manifest — the primary's declared intent.\n"
        "#\n"
        "# 'nodes:' is written by the wizard (./taranac cluster add-node /\n"
        "# add-witness / remove-node). Comments inside that block are NOT kept.\n"
        "#\n"
        "# 'skip:' is yours. It marks a preflight divergence you have decided is\n"
        "# expected: preflight still PRINTS the line, with your reason beside it —\n"
        "# a silent skip is an invisible landmine. Nothing here rewrites it.\n"
        f"cluster: {_scalar(cluster)}\n"
    )
    body = render_nodes_block(nodes)
    tail = ""
    if pg_allow_cidr:
        tail += f"pg_allow_cidr: {_scalar(pg_allow_cidr)}\n"
    tail += (
        "# skip:\n"
        "#   - node: taranac-node-3\n"
        "#     key: PG_ALLOW_CIDR\n"
        '#     reason: "site behind NAT, address set by hand"\n'
    )
    text = header + body + tail
    try:
        yaml.safe_load(text)
    except yaml.YAMLError as exc:  # pragma: no cover - would be a bug in the renderer
        fail(f"refusing to write — the manifest we generated does not parse ({exc})",
             "nothing was written. Re-run with --debug and report it")
    _atomic_write(path, text)

    note(f"created {path} for cluster '{cluster}'"
         + (f" with primary {nodes[0].name} ({nodes[0].address})" if nodes else ""))
    emit(FILE=path, CLUSTER=cluster, NODE_COUNT=len(nodes),
         PRIMARY_NAME=nodes[0].name if nodes else "",
         PRIMARY_ADDRESS=nodes[0].address if nodes else "")
    return EXIT_OK


def cmd_add_node(opts, forced_role=None):
    path = opts["file"] or DEFAULT_FILE
    if not opts["address"]:
        fail("missing --address",
             "give the address the OTHER nodes route to, e.g. "
             "--address 10.0.0.2 (it is also what goes into DB_HOSTS)",
             code=EXIT_USAGE)
    manifest = load(path)
    address = check_address(opts["address"])

    # `add-witness` is `add-node --role witness` with the role nailed down; an
    # explicit --role that disagrees is a typo worth stopping for, not something
    # to silently override.
    role_given = forced_role or opts["role"]
    if forced_role and opts["role"] and check_role(opts["role"]) != forced_role:
        fail(f"add-witness cannot record role '{opts['role']}'",
             f"drop --role (add-witness always records role: {forced_role}), or use "
             f"./taranac cluster add-node --role {opts['role']} instead",
             code=EXIT_USAGE)
    role = forced_role or (check_role(opts["role"]) if opts["role"] else DEFAULT_ROLE)

    existing = manifest.by_address(address)
    in_cluster = opts["in_cluster"]

    # The four cases of the spec, in the order of its table. Only the caller can
    # know the "in cluster" half — it comes from etcd / the roster — so it is an
    # input here, and this helper owns the manifest half plus the verdict.
    if existing and in_cluster:
        note(f"'{existing.name}' ({address}) is already a member of this cluster — nothing to do.")
        emit(CASE="ALREADY_ADDED", NAME=existing.name, ADDRESS=existing.address,
             ROLE=existing.role, CHANGED=0,
             MESSAGE=f"node '{existing.name}' ({address}) is already added")
        return EXIT_ALREADY_ADDED

    if not existing and in_cluster:
        note(f"{address} is a member of the cluster but is NOT in {path} — "
             "the source of truth has drifted.")
        emit(CASE="DRIFT", NAME="", ADDRESS=address, ROLE=role, CHANGED=0,
             MESSAGE=(f"{address} is in the cluster but not in the manifest; adopt it "
                      f"into {os.path.basename(path)} or decommission the node"))
        return EXIT_DRIFT

    if existing:
        # In the manifest, not in the cluster: the normal retry after an
        # interrupted add — and the idempotency guarantee. No second entry.
        if opts["name"] and opts["name"] != existing.name:
            fail(f"{address} is already recorded as '{existing.name}', not "
                 f"'{opts['name']}'",
                 f"drop --name to keep '{existing.name}', or remove the stale entry "
                 f"first:  ./taranac cluster remove-node --address {address}")
        if role_given and role != existing.role:
            fail(f"{address} is already recorded with role '{existing.role}', "
                 f"not '{role}'",
                 f"drop the role argument to keep '{existing.role}', or remove the "
                 f"entry first:  ./taranac cluster remove-node --address {address}")
        note(f"'{existing.name}' ({address}) is already in {os.path.basename(path)} "
             "and not yet in the cluster — continuing the add.")
        # A retry is still an attempt in flight: (re)mark it, so an interruption here
        # is as recognisable as one on the first try.
        if opts.get("pending") and not existing.pending:
            existing.pending = True
            write_nodes(manifest, manifest.nodes)
        emit(CASE="RESUME", NAME=existing.name, ADDRESS=existing.address,
             ROLE=existing.role, CHANGED=0,
             MESSAGE=f"resuming the add of '{existing.name}' ({address})")
        return EXIT_OK

    name = check_name(opts["name"]) if opts["name"] else manifest.next_derived_name(role)
    if manifest.by_name(name):
        fail(f"the name '{name}' is already used by the node at "
             f"{manifest.by_name(name).address}",
             "choose another --name, or drop --name and let the wizard derive one")
    if role in ("primary", "witness") and manifest.by_role(role):
        held = manifest.by_role(role)[0]
        as_replica = ("./taranac cluster add-node --address " + address
                      if forced_role else "the same command without --role")
        fail(f"this cluster already has a {role}: '{held.name}' ({held.address})",
             f"a cluster has exactly one {role}. Add this node as a replica with "
             f"{as_replica}, or remove the current {role} first:  "
             f"./taranac cluster remove-node --address {held.address}")

    node = Node(name=name, address=address, role=role, pending=bool(opts.get("pending")))
    write_nodes(manifest, manifest.nodes + [node])
    note(f"recorded '{name}' ({address}) as {role} in {path}")
    emit(CASE="RECORDED", NAME=name, ADDRESS=address, ROLE=role, CHANGED=1,
         MESSAGE=f"recorded '{name}' ({address}) as {role}")
    return EXIT_OK


def cmd_mark_joined(opts):
    """Clear the ``pending`` mark — the add for this node is confirmed finished."""
    manifest = load(opts["file"])
    address = check_address(opts["address"]) if opts.get("address") else None
    target = manifest.by_address(address) if address else manifest.by_name(opts["name"])
    if target is None:
        fail(f"{address or opts['name']} is not in {opts['file']}",
             "nothing to mark; add it first with add-node")
    if target.pending:
        target.pending = False
        write_nodes(manifest, manifest.nodes)
    emit(NAME=target.name, ADDRESS=target.address, ROLE=target.role)
    note(f"'{target.name}' ({target.address}) is confirmed joined")
    return 0


def cmd_pending(opts):
    """List the entries whose add was started and never confirmed finished.

    TAB-separated `name<TAB>address<TAB>role`, so a shell caller can read it with
    `while IFS=$'\t' read`. Empty output (exit 0) means nothing was left half-done.
    """
    manifest = load(opts["file"])
    for node in manifest.nodes:
        if node.pending:
            sys.stdout.write(f"{node.name}\t{node.address}\t{node.role}\n")
    return 0


def cmd_remove_node(opts):
    path = opts["file"] or DEFAULT_FILE
    manifest = load(path)
    if opts["address"]:
        target = manifest.by_address(check_address(opts["address"]))
        needle = opts["address"]
    elif opts["name"]:
        target = manifest.by_name(opts["name"])
        needle = opts["name"]
    else:
        fail("missing --address or --name",
             "say which node to remove, e.g. --address 10.0.0.2 "
             "(./cluster-manifest.py list shows both)",
             code=EXIT_USAGE)
    if target is None:
        fail(f"no node '{needle}' in {os.path.basename(path)}",
             "list what is actually recorded with:  ./cluster-manifest.py list",
             path=path, code=EXIT_NOT_FOUND)
    write_nodes(manifest, [n for n in manifest.nodes if n is not target])
    note(f"removed '{target.name}' ({target.address}) from {path}")
    emit(NAME=target.name, ADDRESS=target.address, ROLE=target.role, CHANGED=1,
         MESSAGE=f"removed '{target.name}' ({target.address})")
    return EXIT_OK


def cmd_list(opts):
    manifest = load(opts["file"] or DEFAULT_FILE)
    role = opts["role"]
    if role:
        role = check_role(role)
    for node in manifest.nodes:
        if role and node.role != role:
            continue
        sys.stdout.write(f"{node.name}\t{node.address}\t{node.role}\n")
    return EXIT_OK


def cmd_get(opts):
    path = opts["file"] or DEFAULT_FILE
    manifest = load(path)
    if opts["address"]:
        target = manifest.by_address(check_address(opts["address"]))
        needle = opts["address"]
    elif opts["name"]:
        target = manifest.by_name(opts["name"])
        needle = opts["name"]
    else:
        fail("missing --address or --name",
             "say which node to look up, e.g. --address 10.0.0.2",
             code=EXIT_USAGE)
    if target is None:
        note(f"no node '{needle}' in {os.path.basename(path)} — "
             "see  ./cluster-manifest.py list")
        return EXIT_NOT_FOUND
    emit(NAME=target.name, ADDRESS=target.address, ROLE=target.role,
         INDEX=manifest.nodes.index(target) + 1)
    return EXIT_OK


def cmd_show(opts):
    manifest = load(opts["file"] or DEFAULT_FILE)
    primary = (manifest.by_role("primary") or [None])[0]
    witness = (manifest.by_role("witness") or [None])[0]
    emit(FILE=manifest.path,
         CLUSTER=manifest.cluster,
         NODE_COUNT=len(manifest.nodes),
         PG_ALLOW_CIDR=manifest.pg_allow_cidr or "",
         PRIMARY_NAME=primary.name if primary else "",
         PRIMARY_ADDRESS=primary.address if primary else "",
         WITNESS_NAME=witness.name if witness else "",
         WITNESS_ADDRESS=witness.address if witness else "",
         SKIP_COUNT=len(manifest.skips))
    return EXIT_OK


def cmd_pg_allow_cidr(opts):
    manifest = load(opts["file"] or DEFAULT_FILE)
    if not manifest.pg_allow_cidr:
        note("pg_allow_cidr is not set in the manifest — the cluster keeps "
             "whatever PG_ALLOW_CIDR is in .env (default 0.0.0.0/0).")
        return EXIT_NOT_FOUND
    sys.stdout.write(manifest.pg_allow_cidr + "\n")
    return EXIT_OK


def cmd_skips(opts):
    manifest = load(opts["file"] or DEFAULT_FILE)
    for skip in manifest.skips:
        sys.stdout.write(f"{skip['node']}\t{skip['key']}\t{skip['reason']}\n")
    return EXIT_OK


def cmd_validate(opts):
    path = opts["file"] or DEFAULT_FILE
    manifest = load(path)
    roles = ", ".join(f"{n.name}={n.role}" for n in manifest.nodes) or "no nodes yet"
    sys.stdout.write(
        f"{PROG}: {path} is valid — cluster '{manifest.cluster}', "
        f"{len(manifest.nodes)} node(s) [{roles}], "
        f"{len(manifest.skips)} skip entr{'y' if len(manifest.skips) == 1 else 'ies'}.\n")
    return EXIT_OK


# ── compare: how two copies of the manifest differ ───────────────────────────
# The manifest is no longer a file that lives in one place: it is published into
# the cluster's replicated settings so that ANY node can take the primary role
# (see cluster-wizard.sh, "The manifest's cluster-wide copy"). That makes
# "these two copies are not the same" a real, routine question — and it is a
# question bash must not answer, for the same reason bash must not WRITE this
# file: the answer depends on parsing YAML, and a grep-based comparison would
# call two identical documents different because one has a comment.
#
# Two verdicts, deliberately separate, because they carry different weight:
#   * IDENTICAL   — byte-for-byte. The only verdict that means "nothing to do".
#   * SAME_TOPOLOGY — the machine-owned half (cluster name, the node set, their
#     names/roles, pg_allow_cidr) agrees. The rest — comments and the operator's
#     `skip:` section — may still differ, and that difference is not a
#     disagreement about what the cluster IS. A caller can reconcile it; it must
#     never reconcile a topology difference on its own, because one of the two
#     copies then describes a cluster that does not exist.
#
# `pending` is excluded from the topology on purpose: it marks an add IN FLIGHT
# on the node doing the adding, not a property of the cluster.
_TOPOLOGY_KINDS = ("cluster", "only-here", "only-there", "name", "role", "pg-allow-cidr")


def _node_phrase(node):
    return f"'{node.name}' ({node.address}) as {node.role}"


def _skip_phrase(skip):
    reason = skip.get("reason") or ""
    return f"{skip['key']} on {skip['node']}" + (f' — "{reason}"' if reason else "")


def cmd_compare(opts):
    """Compare --file (here) against --other (there). Never writes anything."""
    path = opts["file"]
    other = opts["other"]
    if not other:
        fail("missing --other",
             "give the second copy to compare against, e.g. "
             "--other /tmp/published-cluster.yml",
             code=EXIT_USAGE)
    here = load(path)
    there = load(other)

    records = []
    if here.cluster != there.cluster:
        records.append(("cluster", f"named '{here.cluster}' here and '{there.cluster}' there"))

    # Keyed by ADDRESS, because that is what identifies a node everywhere else in
    # this file (DB_HOSTS entries, etcd member URLs, the roster). A renamed node is
    # then reported as a rename rather than as one node vanishing and another
    # appearing, which is what a name-keyed comparison would claim.
    here_by_address = {n.address: n for n in here.nodes}
    there_by_address = {n.address: n for n in there.nodes}
    for address, node in here_by_address.items():
        if address not in there_by_address:
            records.append(("only-here", _node_phrase(node)))
    for address, node in there_by_address.items():
        if address not in here_by_address:
            records.append(("only-there", _node_phrase(node)))
    for address, node in here_by_address.items():
        peer = there_by_address.get(address)
        if peer is None:
            continue
        if peer.name != node.name:
            records.append(("name", f"{address} is '{node.name}' here and '{peer.name}' there"))
        if peer.role != node.role:
            records.append(("role", f"'{node.name}' ({address}) is {node.role} here "
                                    f"and {peer.role} there"))

    if (here.pg_allow_cidr or "") != (there.pg_allow_cidr or ""):
        records.append(("pg-allow-cidr",
                        f"'{here.pg_allow_cidr or '(unset)'}' here, "
                        f"'{there.pg_allow_cidr or '(unset)'}' there"))

    here_skips = {(s["node"], s["key"]): s for s in here.skips}
    there_skips = {(s["node"], s["key"]): s for s in there.skips}
    for key, skip in here_skips.items():
        if key not in there_skips:
            records.append(("skip-only-here", _skip_phrase(skip)))
    for key, skip in there_skips.items():
        if key not in here_skips:
            records.append(("skip-only-there", _skip_phrase(skip)))

    for kind, text in records:
        sys.stdout.write(f"{kind}\t{text}\n")

    same_topology = not any(kind in _TOPOLOGY_KINDS for kind, _ in records)
    emit(IDENTICAL=1 if here.text == there.text else 0,
         SAME_TOPOLOGY=1 if same_topology else 0,
         SKIPS_ONLY_HERE=sum(1 for kind, _ in records if kind == "skip-only-here"),
         SKIPS_ONLY_THERE=sum(1 for kind, _ in records if kind == "skip-only-there"),
         DIFF_COUNT=len(records),
         HERE_NODES=len(here.nodes),
         THERE_NODES=len(there.nodes))
    return EXIT_OK


COMMANDS = {
    "init": cmd_init,
    "add-node": cmd_add_node,
    "add-witness": lambda opts: cmd_add_node(opts, forced_role="witness"),
    "remove-node": cmd_remove_node,
    "list": cmd_list,
    "get": cmd_get,
    "show": cmd_show,
    "pg-allow-cidr": cmd_pg_allow_cidr,
    "skips": cmd_skips,
    "validate": cmd_validate,
    "compare": cmd_compare,
    "mark-joined": cmd_mark_joined,
    "pending": cmd_pending,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(USAGE)
        return EXIT_OK
    command = argv[0]
    if command not in COMMANDS:
        sys.stderr.write(
            f"{PROG}: unknown command '{command}'\n"
            f"   Remedy: use one of: {', '.join(sorted(COMMANDS))} — "
            "run  ./cluster-manifest.py --help  for the full list\n")
        return EXIT_USAGE
    opts = parse_args(argv[1:])
    # Resolve the default ONCE, here. Every command used to do `opts["file"] or
    # DEFAULT_FILE` for itself, which works until someone adds a command and forgets —
    # then it fails with `stat: path should be string … not NoneType`, an error that
    # says nothing about manifests. Doing it at the single entry point makes forgetting
    # impossible; the per-command `or DEFAULT_FILE` are now redundant but harmless.
    opts["file"] = opts["file"] or DEFAULT_FILE
    return COMMANDS[command](opts)


if __name__ == "__main__":
    debug = "--debug" in sys.argv
    try:
        sys.exit(main(sys.argv[1:]))
    except ManifestError as error:
        sys.stderr.write(error.render() + "\n")
        sys.exit(error.code)
    except KeyboardInterrupt:
        sys.stderr.write(f"\n{PROG}: interrupted — nothing was written.\n")
        sys.exit(EXIT_ERROR)
    except Exception as error:  # never show an operator a traceback
        if debug:
            raise
        sys.stderr.write(
            f"{PROG}: unexpected internal error: {error.__class__.__name__}: {error}\n"
            "   Remedy: the manifest was NOT modified. Re-run the same command with "
            "--debug to get the full detail, and report it with a copy of "
            "config/cluster.yml.\n")
        sys.exit(EXIT_ERROR)
