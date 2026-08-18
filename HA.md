# High Availability (Pro)

This is the operator runbook for running Taranac as a **High Availability cluster**.
It is self-contained — you should not need to read anything else to deploy or
operate HA. For the design rationale behind every decision here, see the design
spec `docs/ops/ha.md` (in the project repository).

HA is a **Pro** feature. It is unlocked by an HA license file (see
[README.md → Activating a Pro license](README.md#activating-a-pro-license)); the
license must allow `ha` and set how many nodes you may run (`max_nodes`).

---

## 1. What HA gives you

- **2–4 nodes**, each running the **full Taranac stack** (UI, API, daemons, DB).
- One node is the **primary** (read-write); the others are **read-only replicas**
  that continuously stream the primary's data.
- **Authentication keeps serving on every node — including during a failover.**
  The TACACS/RADIUS/NAC daemons answer from their own node-local data and cache,
  so the AAA/NAC data plane never depends on the primary being up. Point your
  network devices at *every* node as AAA servers and they ride out a failover.
- **Automatic failover**: if the primary dies, a replica is promoted and the
  cluster keeps running. Configuration writes (UI edits, new accounting rows)
  pause for a few seconds during promotion, then resume on the new primary.

The cluster is managed by **Patroni** (supervises Postgres on each node) and
**etcd** (the agreement layer that decides who is primary). You do not operate
these directly — you build the cluster with **three `./taranac cluster` commands**
([§3](#3-build-the-cluster--three-commands)) and operate it with the rest of that
family. The `ha-*.sh` scripts in this bundle are the mechanism underneath
([§4](#4-what-the-three-commands-do-underneath)); an operator normally never runs
them by hand.

---

## 2. Before you start (prerequisites)

1. **A running single node**, installed normally (see [INSTALL.md](INSTALL.md)),
   that already holds your data. This becomes **node-1**, the seed/primary.
   The wizard converts an *installed and populated* node — it refuses a host with
   no Postgres data volume, because a cluster has to be seeded from something.
2. **The HA license uploaded on node-1 while it is still single-node**
   (Settings → System → Licensing). New nodes inherit the license automatically
   when they join — you never upload it per node.
3. **All nodes on the SAME image version.** Check with `./taranac version` on
   each host; they must match before you build the cluster. (A joining node
   adopts the cluster's `TARANAC_VERSION` and says so if it differed.)
4. **Know the addresses** — every node's routable address *and* a **witness host**
   (see below). You answer them **once, on node-1**; nothing is copied into any
   other node's `.env` by hand.
5. **A private network between the nodes.** Replication, etcd and Patroni traffic
   must travel a trusted interconnect, not the public internet (see
   [§7 Security](#7-security--you-must-do-this)).
6. **The other machines already have the bundle unpacked** — a joining DB node
   needs an ordinary `./install.sh`ed node; a witness host needs only the unpacked
   bundle (`docker-compose.witness.yml`, `witness-join.sh`, `ha-etcd-ca.sh`) plus
   docker, curl, openssl and python3.

### A node that is already running and configured is the NORMAL case

You installed Taranac the ordinary way on the second machine, used it, and now
want replication. That is expected and supported. **A joining replica's local
database cannot be preserved** — Patroni clones the replica from the primary, and
two independently seeded Postgres instances cannot be merged. So the join
**inspects** what that node holds (devices, extra administrators, log volume),
**states it**, takes a **backup**, and asks you to confirm before discarding it.
You never type a `docker volume` command. See
[§3.3](#33-add-each-remaining-node--on-node-1).

### The witness — MANDATORY for a 2-node cluster

A 2-node cluster **cannot safely fail over on its own**. If the network splits the
two nodes, neither can tell whether the other is dead or just unreachable, so
neither may safely become primary (this is "split-brain"). The tiebreaker is a
**third etcd voting member — a witness** — running on a **separate failure
domain**: a 3rd host or VM, ideally a different rack/site.

- The witness runs **only** `docker-compose.witness.yml` — etcd only, **no
  Postgres, no Taranac stack**. It is tiny (a management VM is fine) and stores
  kilobytes.
- It **MUST be a separate host.** Co-locating the witness with a DB node is
  useless: losing that host loses a DB node *and* the tiebreaker at the same time.
  `witness-join.sh` refuses to run on a machine that has a `taranac-db` or
  `taranac-api` container, for exactly that reason.
- The tooling **refuses** a cluster that does not declare at least **3 etcd
  voting members**. This is not optional.
- A witness holds **no database, no `MASTER_KEY` and no application credential**.
  Nothing of the cluster's secret set is written to it — it is a machine that is
  cheap to lose.
- For **3 or 4 DB nodes** you already have a natural majority, so a dedicated
  witness is not required — but you still declare every node's etcd member.

---

## 3. Build the cluster — three commands

```bash
# on the future primary (node-1)
./taranac cluster init
./taranac cluster add-witness --address 10.0.0.3
./taranac cluster add-node    --address 10.0.0.2      # once per additional node
```

**The order is mandatory** and it is not our preference — it falls out of the
mechanism. `ha-convert.sh --continue` refuses to prune the etcd ring unless the
witness is already a live member (otherwise node-1 would strand as a one-member
cluster the witness could never join), and a join refuses a ring that declares
fewer than three etcd members. The wizard turns those two refusals into a guided
sequence; it never routes around them.

**All three of these run on node-1.** Two of them print a single, ready-to-paste
command for the machine being added — a **plain command with a visible address**,
never an opaque blob. The address is the one thing you may need to edit (NAT, a
different FQDN, another port), so it is never hidden.

> **Not every `cluster` command runs on node-1**, and with several nodes it is easy
> to be in the wrong terminal. [§3.7](#37-which-command-runs-on-which-machine) is the
> table: what runs where, and exactly how each command refuses when it is run
> somewhere else.

**Every step announces itself before it runs and asserts an observable outcome.**
A join is not "the container started"; it is *real streaming replication*. If a
step cannot observe its outcome it stops, names the step, and carries its own cure.

### 3.1 `init` — declare the cluster (on node-1)

```bash
./taranac cluster init
```

It asks for the cluster name, this node's address, the witness address and any
further node addresses, then shows the plan and waits for your confirmation
before writing anything. All of them can be given up front:

```bash
./taranac cluster init --cluster taranac --address 10.0.0.1 \
    --witness 10.0.0.3 --node 10.0.0.2 --yes
```

| Option | Meaning |
|---|---|
| `--cluster NAME` | cluster name, identical on every node (default `taranac`) |
| `--address ADDR` | **this** node's routable address, as the others reach it |
| `--name NAME` | this node's cluster name (default `<cluster>-node-1`) |
| `--witness ADDR` | the 3rd etcd arbiter, on a separate host |
| `--node ADDR` | another Taranac node — repeatable |
| `--pg-allow-cidr LIST` | the `pg_hba` scope (default: the /24 of each declared address) |
| `--force` | recreate `config/cluster.yml` — **discards your `skip:` entries** |
| `--yes` / `-y` | non-interactive; every value must be given on the command line |

**Why you declare the whole topology now.** The etcd ring must be declared
*complete* before the conversion: `--prepare` issues one certificate per member of
the declared ring, so a member that is missing from it gets no certificate and can
never join. Declaring it all up front also means every node carries the same node
list from day one, so nothing has to be rewritten later on a live member.

`init` writes `config/cluster.yml` (the manifest, [§3.4](#34-the-manifest--configclusteryml)),
writes the cluster block into this node's `.env`, and runs `ha-convert.sh --prepare`
— which generates the etcd CA and a certificate for every declared member.

**It deliberately does NOT convert the database.** Nothing failed: securing etcd is
a chicken-and-egg (the witness must be live before the convert, but its certificate
can only be signed by the CA the convert just created). The stack keeps running
standalone until the next command.

> ⚠️ **Between `init` and `add-witness`, do not run `./taranac up -d` on node-1.**
> `.env` now declares the cluster, so the tooling would start the HA overlay on a
> node that has not been converted yet.

`init` is retryable: re-running it reads the existing manifest instead of asking
again, so an interrupted run is simply repeated.

### 3.2 `add-witness` — bring the arbiter up and convert node-1

```bash
./taranac cluster add-witness --address 10.0.0.3
```

| Option | Meaning |
|---|---|
| `--address ADDR` | the witness host (**required**) |
| `--name NAME` | its etcd member name (default from the manifest) |
| `--port N` | the join broker's port (default `9443`) |
| `--timeout N` | seconds to wait for the witness to connect (default `1800`) |
| `--wait-seconds N` | budget for each post-join check (default `120`) |

It opens a **one-shot join channel** on this host and prints the command to run on
the witness, with the channel's own certificate fingerprint:

```
    ./witness-join.sh \
        --broker 10.0.0.1:9443 \
        --token <secret> \
        --pin sha256:<fingerprint>
```

Run that on the witness host, in the unpacked bundle directory. `witness-join.sh`
pins the fingerprint **before it says anything**, takes the cluster's etcd topology
from the channel, generates its **own** private key and sends only a certificate
request, writes a complete `.env` for `docker-compose.witness.yml`, starts etcd,
and then **proves** the result — it does not announce it.

Back on node-1 the command then runs `ha-convert.sh --continue` (the real
conversion: Patroni adopts your existing data directory in place, forms quorum
with the witness, and promotes this node), and verifies two things before it
reports success: this node's Postgres reports `not pg_is_in_recovery()`, and the
witness is a **voting** member of the ring with a live client URL.

> If node-1 is **already** an HA node, `add-witness` skips the conversion and just
> adds (or replaces) the witness in the running ring.

### 3.3 Add each remaining node — on node-1

```bash
./taranac cluster add-node --address 10.0.0.2
```

| Option | Meaning |
|---|---|
| `--address ADDR` | the joining node (**required**) |
| `--name NAME` | its cluster name (default derived by position) |
| `--port N` | the join broker's port (default `9443`) |
| `--timeout N` | seconds to wait for the node to connect (default `1800`) |
| `--ttl-minutes N` | join-token lifetime (default `60`) |
| `--wait-seconds N` | budget for each post-join check (default `120`) |
| `--reinstall` | the address is **already a member**: evict it and add it again from scratch (see below) |
| `--yes` / `-y` | do not ask the questions this command would otherwise ask |

Before anything grows, `add-node` **clears leftovers from an earlier interrupted
add** (a manifest entry marked as an add-in-flight, an address left in this node's
`.env` that is in neither the manifest nor the etcd ring, and any unredeemed join
token for this same address — that token holds one of your licensed node slots
until it expires). Then it runs a **preflight against every existing member**
([§3.5](#35-the-preflight--every-member-is-consulted)) and **stops** if the cluster
does not already agree with itself. Then it issues a license-gated join token and
prints the command for the new machine:

```
    ./ha-join.sh \
        --broker 10.0.0.1:9443 \
        --token <secret> \
        --pin sha256:<fingerprint>
```

Run it **on the joining node**, in its bundle directory. It will:

1. Check this host has what the join needs (docker, curl with `--pinnedpubkey`,
   openssl, `python3-cryptography`) **before** contacting anything or touching
   this node — discovering a missing package after the database has been discarded
   would be the worst possible moment for it.
2. Pin the broker's certificate against `--pin`. **Nothing derived from the token
   is transmitted until this passes**, and a mismatch is never something to click
   through: this channel carries the cluster's master key.
3. **Check that this is the machine the token was issued for**, and stop if it is
   not — see [§3.3.1](#331-the-wrong-terminal-guard).
4. **Inventory what this node holds** and print it — devices, administrators
   beyond the default, AAA/NAC log records.
5. If the node holds real content, **stop** and ask you to re-run the same command
   with the confirmation appended (it prints the exact command back to you):

   ```bash
   ./ha-join.sh --broker 10.0.0.1:9443 --token <secret> --pin sha256:<fp> \
       --confirm DISCARD-LOCAL-DATA
   ```

   A node that was installed but never configured proceeds with a printed notice
   and no confirmation.
6. **Take a backup first**, using the product's own Backup & Recovery machinery,
   and leave the archive on this node in `./pre-join-backup/`. Restore it later
   with `./taranac restore <that file>`. Note what it is: a **configuration**
   backup — devices, users and settings come back from it; **log records do not**.
   Export anything you need from Reports before confirming. (`--no-backup` skips
   this, for when you took one another way.)
7. Receive the cluster's wrapped key material — the master key, the shared MFA key
   and **the cluster's etcd CA**, so that no single machine's loss can leave the
   cluster unable to grow ([§4.2](#42-certificates-a-request-not-a-copy)).
8. Discard the local database, join the etcd ring, and bring the stack up under
   the HA overlay so Patroni clones this node from the primary.
9. Wait until the local Postgres is really a streaming replica, redeem the join
   token so the node appears in the roster, and report the outcome back to node-1's
   console.

Back on node-1, `add-node` then confirms — by asking **Patroni**, which answers the
same from any node — that the new member is a replica in a running state. A node in
the ring that is not replicating cannot take over, and that is not a success.

Repeat once per node, up to your license's `max_nodes`.

#### Re-adding a node that is already a member

Re-adding a machine that is already in the cluster is a real need (it died, it was
rebuilt, it half-joined and never finished), and it is also an easy way to destroy a
healthy node by accident. So the decision is made from **what that node is doing
right now**, asked of Patroni — not from what the roster says:

| The node is… | What happens |
|---|---|
| the **current leader** | **Refused**, always. Reinstalling it takes the cluster's write path away mid-flight, and the database it would be re-cloned from is the one it is serving. Hand leadership over first: `./taranac cluster switchover --to <another node>`. |
| a healthy **streaming** replica | Refused **unless** you pass `--reinstall` (accepted by `add-node` and by `add-witness`), and the refusal prints that exact command. It is destructive on that node: it is evicted, its database is discarded, and Patroni clones it again — **the cluster runs one replica short until that finishes**. |
| a member that is **not streaming** | You are **asked** to confirm (this is the case `--reinstall` exists for). `--reinstall` skips the question. |

The eviction is the same `remove-node` machinery, with the same guards, so nothing
about the quorum checks is bypassed by taking this route.

#### 3.3.1 The wrong-terminal guard

A join token is a **bearer** credential — whoever presents it, the channel serves.
With several terminals open it is easy to paste the command meant for one node into
another, and that is not a harmless error: it happened on our own stand, and the
machine it was pasted on was a **healthy member** that accepted an identity which was
not its own and discarded its database before anything stopped it.

The joining machine is the only party that knows where it is standing, so the check
lives there. `ha-join.sh` stops, before touching anything, when:

- **this host already carries a cluster identity that disagrees with the token's** —
  a **hard** stop, not overridable. It prints both, and the command to issue a token
  for *this* host instead.
- **the token's address is on none of this host's interfaces** — a stop you may
  override, because a node behind NAT is genuinely reached at an address it does not
  hold itself:

  ```bash
  ADDRESS_NOT_LOCAL_OK=1 ./ha-join.sh --broker … --token … --pin …
  ```

  Set it only when you know that is the situation. It is an environment variable and
  not a flag on purpose: it is a statement about **this host's** network, not one more
  option to copy along with the printed command.

### 3.4 The manifest — `config/cluster.yml`

`init` writes the primary's declared source of truth beside `.env`:

```yaml
cluster: taranac
nodes:
  - name: taranac-node-1
    address: 10.0.0.1
    role: primary
  - name: witness
    address: 10.0.0.3
    role: witness
  - name: taranac-node-2
    address: 10.0.0.2
    role: replica
pg_allow_cidr: 10.0.0.0/24
```

**Ownership is split inside the file.** The `nodes:` block is machine-written —
`add-node` / `add-witness` record what you passed as `--address`. The **`skip:`**
section below is the only part you edit by hand, and the tooling preserves it (and
every comment outside `nodes:`) byte for byte:

```yaml
skip:
  - node: taranac-node-3
    key: PG_ALLOW_CIDR
    reason: "site behind NAT, address set by hand"
```

A `skip:` entry marks a divergence as **expected**. It does **not** silence it —
the preflight still prints the line, with your recorded reason, because a silent
skip becomes an invisible landmine.

If a machine turns up in the cluster that the manifest does not name, `add-node`
**stops**: the source of truth itself has drifted, and growing the cluster on a
description that no longer matches reality is how the two quietly diverge forever.
It tells you how to adopt the node into the manifest or decommission it.

Check the file at any time with `./cluster-manifest.py validate`.

### 3.5 The preflight — every member is consulted

`add-node` refuses to grow a cluster that does not already agree with itself. Its
inputs come from the **replicated database**, not from peer requests: every node
publishes its own topology into the cluster heartbeat every 30 s, and that write
routes to the primary and replicates. (Deliberately so — a peer request is exactly
what hangs when a node is in trouble, which is the moment a preflight has to
produce an answer.)

It asserts:

1. **Every member has reported recently.** A **silent** member stops the add — it
   is never assumed healthy, because its configuration is unknown.
2. **Every member's topology matches this node's**, except where `skip:` covers it
   — with the two exceptions below.
3. **The new node's address falls inside every member's `PG_ALLOW_CIDR`.** This
   one matters more than it looks: outside that range the new node's replication
   login is refused *after* the TCP handshake, so the port answers and nothing
   looks broken until the failover that needs it.
4. **etcd has quorum**, and the ring will still hold **≥ 3 voting members**.

**Two things are reported but do NOT stop the add**, because being out of date is
normal in a growing cluster and blocking on it would mean hand-editing every peer
before you may add a node:

- **`ETCD_INITIAL_CLUSTER`** is read only when a member's etcd *bootstraps*. A
  running member takes the ring from etcd itself, so a stale value here changes
  nothing until that member is ever recreated from scratch.
- **`ETCD_HOSTS`** is a list of endpoints that member's Patroni may try. One missing
  entry means one fewer to try — degraded, not broken.

Bring those up to date when convenient, on each node that was named:
`./taranac cluster sync` ([§5 Bring a node up to date](#bring-a-node-back-up-to-date)).

**`DB_HOSTS` does stop the add** — it is how a member finds the node to send
**writes** to, so a member that does not list a node cannot follow it when it becomes
the leader, and the cluster looks healthy until that failover. It is checked for
**coverage**: every member must list every node that has actually joined. Extra
entries are fine. (It is deliberately *not* compared byte-for-byte with node-1's own
file — node-1 legitimately lists the node you are adding before anyone else does.)

On divergence it **stops and shows** — it never fixes anything for you. Rewriting a
live member's configuration at the moment of a join is a surprise write at the
worst possible time. Each finding names the node, the value, the difference and the
command that cures it; fix it **on the node it names**, then re-run.

The witness publishes nothing here (it runs etcd only, with no Taranac node); it is
checked against the etcd ring instead.

### 3.6 Verify

```bash
./taranac cluster status         # roles, sync state, lag
./taranac cluster connectivity   # every node's PROVEN login to every other node
```

`status` should show every node, with exactly one leader and the rest streaming.

`connectivity` is the stronger check and the one worth running after every join.
Each node continuously attempts a **real `replicator` login** to every other node
and publishes the verdict, so this is a matrix of proofs, not of pings — and it
answers the question no configuration can: whether each peer's `pg_hba` will
actually admit each other node **when a failover needs it**. A TCP connect to 5432
proves nothing here, because the port accepts first and refuses only after the
handshake.

It **exits non-zero unless every ordered pair is proven by a fresh login** — `stale`
and `unknown` count as not proven, deliberately. Run it, and read the exit code:

```bash
./taranac cluster connectivity || echo "NOT fully verified — read the matrix above"
```

> The join itself does **not** wait on this matrix — it proves the new node is
> replicating from the current primary, which is the leg that must work today. The
> matrix is what proves the legs that will matter **after** a failover, so running it
> yourself is a real step, not a formality.

### 3.7 Which command runs on which machine

There are four kinds of machine in a cluster, and the `cluster` commands are not
interchangeable between them. Every refusal below is a real guard in the tooling.

| Command | Runs on | Everywhere else |
|---|---|---|
| `cluster init` | the **future seed** — installed, populated, still standalone | On an already-converted node: *"this node is already an HA node (`TARANAC_HA=1`)"*. On a host with no `taranac_pg_data` volume: *"init converts an installed, populated node"*. |
| `cluster add-witness` | the **seed** (it needs `config/cluster.yml` and the etcd CA) | Without the etcd CA: *"this node holds no etcd CA … run this command on the SEED"*. With the CA but no manifest (any node that joined later): it stops one step further on, at *"no cluster manifest at config/cluster.yml"*. |
| `cluster add-node` | the **seed**, same reason | Not converted at all: it prints the three-command order instead. Converted but no CA: the CA refusal. CA but no manifest: the manifest refusal. |
| `cluster sync` | **the node that is behind** — never the seed on the seed's behalf | On a node that is not converted: *"this node is not converted to HA yet"*. It changes **only the machine it is run on** and says so before asking. |
| `cluster remove-node` | a **surviving DB node** (conventionally the primary) — it must reach the local Patroni and another member's etcd | Refuses if it cannot read the current leader from Patroni, rather than guessing. Refuses to evict the **current leader**. Only *this* machine's `.env` and manifest are pruned — the other survivors need nothing. |
| `cluster detach` | **the machine being detached** | Refuses while that machine is still a cluster member — run `remove-node` on a survivor first. |
| `cluster status` · `connectivity` · `switchover` · `join-token` · `register` · `revoke` · `decommission` | **any DB node** (they run inside that node's `api` container) | — |
| `./ha-join.sh --broker …` | **the machine being added**, using the command node-1 printed | Refuses on a machine whose identity disagrees with the token ([§3.3.1](#331-the-wrong-terminal-guard)). |
| `./witness-join.sh --broker …` | **the witness host** | Refuses on any host that has a `taranac-db` or `taranac-api` container — an arbiter co-located with a node it arbitrates is not a smaller deployment, it is a broken one. |
| any `cluster` subcommand | — | **On the witness: all of them are refused**, with the reason (a witness has no database and no API — that is the design, not a missing piece) and a list of what you *can* run there. |

Two practical consequences worth stating plainly:

- **Growing the cluster is no longer tied to one machine.** Every node receives the
  etcd CA when it joins, and the manifest is published into the cluster on every
  wizard write — a node that has no `config/cluster.yml` restores it from there and
  carries on. Both halves of "any node can admit the next one" now hold, so losing
  the machine you happened to run `init` on costs you that machine and nothing else.
- **`sync` is the one command that is meant to be run somewhere else.** When a
  preflight names a node as out of date, the cure runs **on that node**. The wizard
  never rewrites a live member's configuration from node-1 — a surprise write during
  someone else's join is the worst possible moment for it.

---

## 4. What the three commands do underneath

**This section is the mechanism, not the instructions.** You do not need it to
deploy — [§3](#3-build-the-cluster--three-commands) is the whole procedure. Read
this when a step fails and you need to know what it was in the middle of, or when
you are debugging a cluster somebody else built.

### 4.1 The join channel

`add-witness` / `add-node` start **`cluster-broker.py`**, a one-shot process on
node-1's *host* — not in the `api` container, and not a daemon. It lives only for
the duration of one join and exits when that join finishes or times out.

It has to be a host process, for three reasons that are not preferences: the
values it serves live in the host's `.env`, which no container owns; the etcd CA
**private key** lives in `config/etcd-ca/` **on the host** and must never enter a
network-facing container; and no compose file in this product mounts the docker
socket, so a container could not recreate the stack afterwards anyway.

**Trust is explicit pinning, not trust-on-first-use.** The broker mints a
throwaway certificate for this one join and prints its fingerprint on node-1's
console; you type it on the other machine. That is affordable here — and stronger
than TOFU — precisely because one operator is standing at both consoles within the
same minute.

**The token does double duty, with domain separation.** You carry exactly one
secret. From it both ends derive two independent keys:

| Derivation | Used for |
|---|---|
| `HKDF(token, "taranac-ha-join-auth-v1")` | what the joining machine presents as its credential |
| `HKDF(token, "taranac-ha-join-wrap-v1")` | what encrypts the key material in transit |

**The raw token is never transmitted.** Without that split, the value presented as
a bearer credential *is* the decryption key — one proxy log or traffic capture and
the cluster's KEK is readable by whoever holds the transcript.

The channel serves: the cluster-wide `.env` values (the same set the API's
join-config endpoint serves — no wider), a **signed etcd certificate in exchange for
a certificate request**, and `MASTER_KEY`, the shared `mfa.enckey` and **the
cluster's etcd CA**, all AES-256-GCM **wrapped** under the wrap key — under the TLS,
not instead of it.

**`MASTER_KEY` no longer travels by hand, and the invariant it protects is
unchanged.** The reason the API cannot serve the master key is *"a stolen database
or backup cannot be decrypted"* — and this channel does not weaken that: **the key
still never lands in the database, in replicated data, or in a backup archive.**
Meanwhile the same token already unlocks the database credentials and grants a full
clone of the database, so the master key is not a new trust class here; it is
brought into line with what the token already opens. The channel is ephemeral,
single-token, fingerprint-pinned, and driven by an operator at both ends.

**Diagnostic.** If a machine is told its credentials are invalid, compare without
guessing — on either machine:

```bash
./ha-join.sh --token <secret> --print-auth        # or ./witness-join.sh --token … --print-auth
```

### 4.2 Certificates: a request, not a copy

Every etcd member needs a server certificate signed by the cluster's shared etcd
CA. The joining machine generates its **own** private key locally and sends only a
**certificate signing request**; the seed signs it and returns the leaf plus the
public `ca.crt`. **That** private key never travels, and a signed certificate is not
a secret at all. This is what removes the "copy three TLS files to every node and to
the witness by hand" step entirely.

> **The CA itself is now copied to every node, on purpose.** It used to live on the
> seed alone and was in no backup — which meant that losing that one disk left a
> cluster that could never add or replace a node again, and could not even replace the
> seed, because a replacement needs a signed certificate and nothing was left to sign
> it with. A single point of failure inside the feature whose whole purpose is
> surviving one is not acceptable, and what the rule bought was small: a node already
> holds the master key, the database password and a full copy of the data, so whoever
> owns that machine owns the cluster's secrets anyway.
>
> So the join hands each node the CA (wrapped, like the master key), and
> `config/etcd-ca` is included in the **backup archive**. Treat every node as holding
> it: back the archive up, and keep the nodes as trusted as you keep node-1.

> 🔑 **The SANs come from the signer, never from the request.** A certificate
> request is authored by the party being authenticated, so honouring its
> `subjectAltName` would let a joining machine mint itself a certificate for *any*
> address it names — including an existing member's — and then impersonate that
> member to every Patroni and `etcdctl` client in the cluster, which verifies only
> "signed by our CA, and the address matches". `ha-etcd-ca.sh sign-csr` takes the
> addresses as its own argument and ignores whatever the request embeds. The seed
> already knows the right address: it is the one you named when you issued the
> token.

The joining machine then verifies what it got before using it: that the leaf
chains to the returned CA, and that it matches the private key that never left.
Two files on disk prove nothing — a truncated response also produces two files, and
an etcd that fails its TLS handshake hours later is a miserable way to find out.

`ha-etcd-ca.sh` keeps its original `issue` command (the seed makes both halves and
you carry them) — that is what `ha-convert.sh --prepare` uses to pre-issue each
declared member's leaf, and it stays available for a hand-driven repair.

### 4.3 The steps `init` / `add-witness` wrap

`init` = manifest + the cluster block in `.env` + `ha-convert.sh --prepare`
(generate the etcd CA, this node's leaf, and one leaf per declared member; enable
peer auto-TLS; rewrite the member URLs to `https://`) — then **stop**.

`add-witness` = the join channel for the witness + `ha-convert.sh --continue` (the
real convert: adopt the existing data directory in place, form quorum with the
now-live witness, prune members that have not started, promote this node).

`add-node` = preflight + a license-gated join token + the join channel; the
joining machine runs `ha-join.sh --broker …`, and Patroni does the clone.

Both `ha-convert.sh` phases and `ha-join.sh` remain usable directly. `ha-join.sh`
also still supports the older hand-driven route (`--primary <address>
--join-token <secret>` with `MASTER_KEY` supplied out-of-band in the environment,
and the node's TLS leaf carried by hand) — it is unchanged and still supported, but
it is the expert path, not the instructions.

> **Plaintext opt-out.** If your interconnect is already isolated and you do not
> want etcd TLS at all, the legacy single-shot convert is
> `./ha-convert.sh --plaintext --node-name … --node-address …` (witness up first).
> It forces both etcd channels to http and needs no certificates. This is a
> deliberate operator choice, not a legacy path — see [§7](#7-security--you-must-do-this).

---

## 5. Operating the cluster

> **The tooling is HA-aware — you do not pass compose files by hand.** Once a node is
> converted (`TARANAC_HA=1` in its `.env`), `./taranac` and `./taranac update`
> **auto-detect HA and merge `docker-compose.ha.yml` for you**, so `ps`, `logs`,
> `restart`, `down`, `up` and `update` all act on the Patroni-managed database
> correctly. You no longer need the long `-f docker-compose.yml -f docker-compose.ha.yml`
> form. (If the overlay file is ever missing on an HA node, a container-starting
> command **refuses loudly** rather than silently start a second writable Postgres —
> restore it with `./taranac update`.)

### Check status

```bash
./taranac cluster status     # nodes, roles, replication lag + WAL bytes behind
./taranac ps                 # local container health on this node
```

The cluster also raises **alerts** in the UI (and via syslog) when a role changes
or a node falls out of sync — you do not have to poll.

### Failover (loss of the primary)

- **With a witness (or 3+ nodes): automatic.** When the primary stops renewing
  its lease (≈ the DCS TTL, ~30 s), the most up-to-date replica is promoted, the
  other replicas re-point to it, and the API reconnects to the new primary.
- **Throughout the window, authentication keeps serving** on every node. Only
  **writes pause briefly** (config edits, accounting) and then resume on the new
  primary — at Taranac's volume that is a handful of buffered records, retried
  automatically, not lost.
- **The old node rejoins automatically** as a replica when it comes back (Patroni
  uses `pg_rewind` — fast). You do nothing.
- A **2-node cluster WITHOUT a witness has no automatic failover** — promotion is
  manual. This is exactly why the witness is mandatory; deploy one.
- You see the role change in `./taranac cluster status` and a cluster-status
  alert in the UI.

### Move the leader on purpose

```bash
./taranac cluster switchover                       # Patroni picks the best follower
./taranac cluster switchover --to taranac-node-2   # to a specific node
```

A **switchover** is a planned handover with **no data loss** — the target has to be
caught up. Use it before maintenance on the primary, and before evicting the
primary from the cluster.

When the leader is gone or the target is behind, a switchover is not possible and
you are asking for a **forced promotion** (a failover), which **discards whatever
the promoted node has not replayed**. That is a typed decision:

```bash
./taranac cluster switchover --to taranac-node-2 --force --confirm FAILOVER
```

It states the cost in bytes of unreplayed WAL before it acts. The command then
waits for a writable primary to come back and reports **who actually leads** — read
back from Patroni, not assumed from what was requested. If the outcome could not be
observed it exits non-zero and tells you to run `cluster status` rather than
requesting a second handover.

### Add a node later

Exactly the same as the initial build: `./taranac cluster add-node --address <addr>`
on the seed ([§3.3](#33-add-each-remaining-node--on-node-1)), within your license's
`max_nodes`. The preflight consults every existing member first, so a node is never
added to a cluster that has quietly drifted.

To rebuild a machine that is **already** a member — it died, it was replaced, a join
never finished — the same command with `--reinstall` evicts it and adds it again from
scratch. It is refused for the current leader, and requires the flag while the node
is still streaming. See
[Re-adding a node that is already a member](#re-adding-a-node-that-is-already-a-member).

### Bring a node back up to date

When the preflight (or your own reading of `cluster status`) says a node's topology
is out of date, the cure runs **on that node**:

```bash
./taranac cluster sync
```

It works out what the cluster actually looks like — the node list from the
**replicated roster**, the etcd endpoints from the **live ring** — shows you each
value it would change, asks once, writes **only this machine's `.env`**, and
recreates this machine's containers so they read it. No other node is touched.

> **Why it does not simply copy the primary's values.** Leadership moves. A node that
> joined early, never learned about a member added later, and then won a failover
> would become "the primary" — and copying *its* shorter list onto everyone else would
> erase a node that really exists. That is not hypothetical: it is why the command
> derives the answer from the roster and the ring, which are the same on every node,
> instead of trusting whichever machine happens to lead right now.

Run it on each node the preflight named, then re-run the command that stopped.

### Remove a node

Removal is **two decisions**, and they are separate commands on separate machines.

**Step 1 — evict it from the cluster.** On the **primary**:

```bash
./taranac cluster remove-node --node taranac-node-2      # by name, or by address
```

It refuses if the target is the **current leader** (hand leadership over first with
`switchover` — evicting the leader is an outage you did not ask for). If the
surviving etcd ring would drop below **3 voting members** it does not refuse: it
**tells you which hazard that actually is and asks**. The two are different, and one
sentence would describe the wrong one half the time:

- **one DB node left, plus the witness** — not split-brain (there is nothing to
  split). It is a 2-member ring that needs **both** members for quorum, so if the
  witness then goes down, the surviving database node is demoted to **read-only** —
  worse than not running HA at all. If the goal is a single server, finish the job
  afterwards with `./ha-deconvert.sh`.
- **two DB nodes left with no arbiter** — the classic split-brain shape: on a
  partition neither side holds a majority, so neither may promote, and failover stops
  working.

Then it removes the etcd member, decommissions the roster row, prunes the node from
this node's `.env` topology, and updates the manifest.

> Both safety questions are answered from the **running** cluster — the live etcd
> member list and Patroni's own view of who leads — never from this node's `.env`,
> which is exactly the thing that can be out of date.

> **You do NOT repeat this on the other nodes.** They read cluster membership from
> etcd, which this command changed once, cluster-wide. (This is the one thing the
> older `ha-deconvert.sh --decommission-dead` path could not do for you, and why it
> asked you to re-run it on every survivor.)

**Step 2 — decide what that machine becomes.** It is still running, and it still
holds a full copy of everything. Two honest options:

- **Wipe it.** It is finished with; nothing further to do on the cluster side.
- **Keep it as an independent install.** On **that** machine:

  ```bash
  ./taranac cluster detach --confirm FORK-MY-DATA
  ```

  > 🔑 **A detached node keeps a COMPLETE COPY of the cluster's database** — every
  > device shared secret, every enable password, every credential, every log — and
  > with the same `MASTER_KEY` it is a second, fully working Taranac carrying all
  > of it. **That is a fork of your data, not a decommission.** It is legitimate
  > (salvaging data after losing the primary, splitting a lab) but it is not what
  > "remove a node" sounds like, which is why the confirmation is typed.

  `detach` refuses if the node is **still** a cluster member — Step 1 has to happen
  first, or the detached node's etcd keeps trying to rejoin the ring and its
  Postgres stays a follower of a primary that still counts on it. It takes a backup,
  stops the HA stack, clears the HA markers from `.env`, brings the node up on the
  base compose so the standalone Postgres adopts the data directory in place, and
  waits until the database actually **accepts writes** before reporting success.

> ⚠️ **Removing down to 2 DB nodes brings the witness requirement back.** If you
> keep two DB nodes, you must keep (or add) a witness or you lose safe automatic
> failover.

Until a removed node is wiped or detached it may still show as a **"phantom
streamer"** in cluster status — that alert is the cue that the physical half is
still pending.

### Removing a node that is DEAD (won't come back)

If the machine is permanently gone you cannot run Step 2 on it, but its **etcd
voting membership** must still be removed or it drags quorum math down forever.
Run Step 1 on a survivor (`./taranac cluster remove-node --node <name>`); it does
the etcd removal and the roster soft-delete. If that dead node ever returns, wipe
its `pg_data` **and** `etcd_data` volumes before joining it again — or simply
re-run `./taranac cluster add-node` against it, which handles both.

### Shrink back to a single node (remove HA)

To go all the way back to a plain standalone install — on the **surviving primary,
after** the other nodes are removed and torn down:

```bash
./ha-deconvert.sh          # back up first; add --yes to skip the prompt
```

It stops the HA overlay, strips the HA markers from `.env`, brings the stack up on
the base compose so the standalone Postgres image **adopts the data dir in place**
(the reverse of the convert), drops the orphan replication slots, and removes the
orphan etcd volume. It **refuses** to run on a replica or while replicas are still
streaming (that would strand them). Afterwards the witness host is no longer needed
(`docker compose --env-file .env -f docker-compose.witness.yml down -v`).

---

## 6. Upgrades under HA

Keep **every node on the same image version**. Upgrade the cluster one node at a
time (see [README.md](README.md#upgrade-to-a-new-version)): update the **replicas
first, the primary last**. Schema migrations run only once, on the primary,
automatically. Take a backup from the in-app Backup & Recovery tools before
upgrading.

> `./taranac update` is HA-aware: on a converted node it brings the **database** back
> up under the Patroni overlay automatically (no manual `-f … -f` form needed) and
> reminds you of the one-node-at-a-time order. It also **detects whether this node is the
> primary** and, if so, warns you to update the replicas first and this node last (Ctrl-C
> if you started on the primary by mistake). Recreating a node's container restarts
> its Postgres — on the **primary** that triggers a failover, which is exactly why you
> do the primary **last**. It also refreshes the HA overlay/tooling/runbook files
> themselves so they stay in step with the new images. (An update that changes the etcd
> image will also recreate this node's etcd member briefly — harmless one node at a
> time, but another reason not to update two nodes at once.)

### Upgrading the WITNESS

Run `./taranac update` on the witness too — it is safe, and it is how the witness's
own tooling (`witness-join.sh`, the witness compose file, `diagnose.sh`, this
runbook) stays in step with the cluster. It knows the host is an arbiter and
**refreshes those files only**: it does not read or edit the witness `.env`, and it
starts no Taranac container there. The witness runs one **pinned upstream etcd
image**, so a Taranac release brings it nothing to pull — there is normally nothing
to restart, and the update deliberately does not restart etcd on its own.

If a release does change `docker-compose.witness.yml`, the update says so and prints
the one command that applies it:

```bash
docker compose --env-file .env -f docker-compose.witness.yml up -d
```

Apply it **deliberately**: it recreates the arbiter's etcd, which is a quorum event.
Do it only while the cluster is healthy (`./taranac cluster status` on a DB node),
and never at the same time as a DB node — the witness is a vote, and a 2-node cluster
that loses its vote and a node together loses quorum.

The wrapper is witness-aware everywhere else too: `./taranac ps` and `./taranac logs
-f etcd` drive the **witness** stack, and any command that needs the database or the
API (`cluster …`, `unlock`, `reset-password`, …) says it belongs on a DB node instead
of failing with a wall of "variable is not set".

> Witnesses joined **before 1.2.7** are recognised from the `.env` that
> `witness-join.sh` writes, so they need no change. New ones also carry an explicit
> `TARANAC_ROLE=witness` line — keep it if you ever hand-edit that file.

---

## 7. Security — you MUST do this

The HA control plane carries the cluster's control state and database. It is
**encrypted and authenticated by default** — the wizard secures etcd (peer auto-TLS
+ one-way client TLS) and Patroni's control API on every cluster it builds. The
**firewall is still the always-on baseline** (TLS is not a substitute), so you must
keep the cluster on a private, firewalled interconnect:

- **Firewall the cluster ports to the private interconnect only — never expose
  them publicly:**
  - **etcd `2379` / `2380`** (client + peer) — holds the cluster control state.
  - **Postgres `5432`** — the database itself.
  - **Patroni REST `8008`** — cluster control (leadership, restart, reload).
- **`9443` — the join channel**, only while a join is running. It is opened on the
  primary by `add-node` / `add-witness`, must be reachable **from the machine being
  added**, and closes when that join finishes or times out. Nothing listens on it
  between joins.
- **Narrow `PG_ALLOW_CIDR`** from any wide default to the cluster's **private
  subnet** (e.g. `10.0.0.0/24`). The wizard derives it from the addresses you
  declare; check it and tighten it if your addresses are spread wider than you want
  `pg_hba` to reach.
- The only ports that should face users/devices are the same as a single-node
  install: **443** (UI) and the AAA/NAC service ports you use.

### Patroni's control API is authenticated — unconditionally

Patroni's REST listener on **`8008`** accepts `POST /switchover`, `/failover`,
`/restart` and `/reload` — i.e. full control of the cluster's leadership. It is
published to the host, so a node that came up without a credential would hand that
control to anyone who can reach the port, with only the firewall in front of it.

**So every node refuses to start without one.** There is no flag and no fallback:
the `postgres` container fails fast if `PATRONI_REST_PASSWORD` is unset, and says
so. The value is **cluster-wide**, like `POSTGRES_PASSWORD` — `install.sh`
generates one per node, and a joining node **adopts the cluster's** over its own
(a per-node value would make this node's Patroni reject every control call the rest
of the cluster makes to it). `PATRONI_REST_USERNAME` defaults to `patroni`.

**Reads stay open on purpose.** `GET /cluster`, `/patroni` and `/health` carry no
credential requirement in Patroni, which is what keeps the backend's topology
polling, the slot reaper and the container healthcheck working. Only the unsafe
methods are gated.

### etcd TLS

Both etcd channels are encrypted by default: the **peer** channel (`2380`,
cross-host Raft) via auto-TLS, and the **client** channel (`2379`, Patroni ↔ etcd)
via the cluster's shared CA — one-way, meaning etcd presents a CA-signed
certificate and clients verify it without presenting one of their own. The CA
private key (`config/etcd-ca/ca.key`) is **never mounted into any container**, and it
is **held by every node**: the join delivers it wrapped, and it is included in the
backup archive, so losing one machine can never leave you unable to add or replace a
node ([§4.2](#42-certificates-a-request-not-a-copy)). Protect every node accordingly,
and keep your backups as safe as you keep `MASTER_KEY`.

Each member's own certificate is obtained by the request-and-sign flow in
[§4.2](#42-certificates-a-request-not-a-copy) — nothing is copied between machines.

Flipping the etcd scheme on a **running** cluster breaks the ring; that is a
planned maintenance-window migration (`docs/ops/ha.md`), never a
blind edit and `up -d`.

---

## 7a. Durable gotchas — the ones that bite silently

1. **The HA config dirs MUST be operator-writable — Docker will root-create them otherwise.**
   `config/etcd-tls`, `config/etcd-ca` and `config/cluster-secrets` are bind-mounted. If a container
   starts before they exist, Docker creates the path **owned by root**, and this node can then no
   longer write its own etcd key or certificate into it. Fresh bundles ship these dirs pre-created and
   **user-owned** (each carries a `.gitkeep`), and the tooling prechecks writability and fails loudly
   up front. Only older installs are exposed; fix with
   `sudo chown -R "$(id -u):$(id -g)" config/etcd-tls config/etcd-ca config/cluster-secrets`.

2. **A joining node's stale volumes are reconciled for you — let the join do it.**
   Three data volumes carry per-cluster identity, and each fails silently if it is stale: a leftover
   `taranac_etcd_data` from a previous cluster → etcd **"cluster ID mismatch"** and no quorum; a
   `taranac_mfa_data` `enckey` this node self-generated → Push tokens minted on another node **fail to
   decrypt here** (surfacing as *"Invalid setup link"*); and a node-local `master_key` in the daemon
   volume → the TACACS/RADIUS/NAC daemons decrypt device secrets with the **wrong key** while the API
   looks fine. `ha-join.sh` clears or reconciles all three, and handles `pg_data` through the
   inventory-and-confirm flow in [§3.3](#33-add-each-remaining-node--on-node-1). Do not pre-empt it by
   hand.

3. **The cluster-shared secret set must be identical on every node** — and it is delivered by the join,
   **never as a replicated DB row**. Six values are cluster-wide; a wrong or missing one is silent
   (undecryptable stored secrets, mfa 401s, invalid login sessions on that node, or a Patroni that
   rejects control calls):

   | Secret | What it protects | How it reaches a joining node |
   |---|---|---|
   | `MASTER_KEY` | the KEK for every stored secret **and the daemons' KEK** (they read it from the `master_key` volume, not env) | **wrapped** over the join channel, under `HKDF(token,"…wrap-v1")` — never in the DB, never in a backup, never served by the API |
   | `mfa.enckey` | `taranac-mfa`'s Push/TOTP token crypto | wrapped over the same channel; reconciled into the mfa volume by the join |
   | `SECRET_KEY` | signs the app's JWTs (login, MFA-setup links, invites) | served over the join channel (and by the join-config API) |
   | `TARANAC_MFA_API_KEY` | backend ↔ `taranac-mfa` auth | same |
   | `POSTGRES_PASSWORD` / `POSTGRES_REPLICATION_PASSWORD` | app + streaming-replication credentials | same |
   | `PATRONI_REST_PASSWORD` | Patroni's control API on 8008 | same |

   The etcd **CA** travels a different way again: a member's own certificate is obtained by request
   and signature ([§4.2](#42-certificates-a-request-not-a-copy)), and the CA itself is delivered
   wrapped over the same channel so that **no single machine's loss can leave the cluster unable to
   grow**. A **witness** receives none of the credentials in that table — it needs none of them.

   Alongside them travels one value that is **not** a secret and is just as load-bearing:
   `TARANAC_CLUSTER_ID`, the cluster's identity. `cluster init` draws it, the join channel
   carries it to every node **and to the witness**, and `ha-deconvert` clears it. Never copy
   it between clusters and never edit it by hand: a member holding a different value forms a
   ring of its own instead of joining yours.

4. **Wipe every machine that was ever pointed at this cluster — not only the replicas.**
   When you dismantle a cluster, the machine most often left standing is the one whose join
   **failed**: it never became a replica, so advice about "former replica nodes" does not
   reach it, and it already holds the cluster's master key and an etcd data volume. On each
   such host:

   ```bash
   ./taranac down
   docker volume rm taranac_pg_data taranac_etcd_data taranac_master_key
   ```

   A cluster built after 1.2.7 draws its own `TARANAC_CLUSTER_ID`, so an unwiped machine can
   no longer rejoin a rebuilt cluster of the same name — but it still holds that cluster's
   data and key material, which is reason enough.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **`cluster init` refuses: "already an HA node"** | `TARANAC_HA=1` is set — this node is already converted. Grow the cluster with `add-node`, or inspect it with `cluster status`. |
| **`cluster init` refuses: no `taranac_pg_data`** | The wizard converts an installed, populated node. Install and start this node first (`./install.sh`), then re-run. |
| **`cluster init` refuses: `POSTGRES_REPLICATION_PASSWORD` not set** | That value was baked into the `replicator` role when this node's database was initialised. The wizard will not mint a new one (the role's password would not change with it, and every join would then fail authentication silently). Restore it into `.env`, or `ALTER ROLE replicator PASSWORD '<new>'` and put the same value in `.env`. |
| **node-1 never becomes primary during `add-witness`** | etcd has no quorum. Confirm the witness is up and reachable: `docker exec taranac-etcd etcdctl endpoint health --cluster`, then `./taranac logs --tail 80 postgres`. |
| **The joining machine cannot read a certificate from the broker** | The broker is **one-shot** and exits when it times out. Re-run `./taranac cluster add-node` / `add-witness` on the primary and use the freshly printed command — and check the joining machine can reach the primary on `9443` (firewall). |
| **`--pin` does not match the presented certificate** | Either the address is not the machine you think it is (check `--broker`, including the port), or something is terminating TLS in between (proxy, load balancer, inspecting firewall) and re-signing. **Neither is safe to click through** — this channel carries the master key. Note also that a *second* `add-node` mints a **fresh** certificate, so an old `--pin` will legitimately fail; use the command that is on the console now. |
| **The broker rejects the credentials (401)** | The token on the joining machine is not the one the broker was started with — it is long and easy to truncate. Compare without guessing: `./ha-join.sh --token <secret> --print-auth` on the joining machine against the broker's expectation. |
| **"the wrapped secret did not decrypt"** | Same cause: the token does not match. The wrap is authenticated, so this is never file corruption — copy the whole printed command again. |
| **`add-node` stops in preflight** | The cluster does not agree with itself. Each finding names the node, the value and the cure — fix it **on the node it names** (the wizard deliberately never rewrites a live member's config mid-join), then re-run. |
| **`add-node` stops: "the manifest has drifted"** | A member exists that `config/cluster.yml` does not name (a hand-rolled join, or an edited file). Either adopt it — `./cluster-manifest.py add-node --address <addr>` — or decommission it — `./taranac cluster decommission --name <its name>` — then re-run. |
| **`add-node` stops: "no cluster manifest at config/cluster.yml"** | You are on the wrong machine. The manifest exists only on the **seed** — the node you ran `cluster init` on. See [§3.7](#37-which-command-runs-on-which-machine). |
| **`add-node` stops: "this node holds no etcd CA"** | Same class: this machine cannot sign a joining node's certificate. Nodes that joined *before* the CA was distributed never received one; run the command on the seed. |
| **`add-node` refuses: "already a member AND is streaming right now"** | That is a healthy replica — there is nothing to add. If you really are rebuilding it, `--reinstall` (see [§3.3](#re-adding-a-node-that-is-already-a-member)); the cluster runs one replica short until the re-clone finishes. |
| **`ha-join.sh` stops: "this command was issued for a DIFFERENT machine"** | You are in the wrong terminal — the guard that exists because doing this on a healthy member destroys its database. Run it on the machine the token names, or issue a token for **this** host on the seed. If this host really is reached at that address through NAT, re-run with `ADDRESS_NOT_LOCAL_OK=1` ([§3.3.1](#331-the-wrong-terminal-guard)). |
| **Every `cluster` command on the witness says "this host is the cluster's WITNESS"** | Correct, and by design: a witness runs etcd only — no database, no API — so none of those commands has anything to read or drive. Run them on a DB node; the message lists what you *can* run there. |
| **`cluster status` shows fewer pending tokens than you issued** | Expired tokens are not listed, because "outstanding" means *redeemable*. Expiry is applied when the list is read, so a token past its lifetime simply disappears from it; a completed join also revokes any other pending token for that same address. |
| **"already at its licensed node limit" while `cluster status` shows a free slot** | An earlier interrupted add left an unredeemed join token holding that slot. `add-node` now clears the leftovers for the same address before issuing a new token, so re-running it is the fix; `./taranac cluster revoke --id <id>` is the manual route. |
| **The node joined the ring but is not streaming** | Usually a `PG_ALLOW_CIDR` that does not reach it — `pg_hba` refuses the `replicator` login *after* the handshake, so nothing looks broken. Check from both ends: `pg_stat_replication` on the primary, and `./taranac logs --tail 80 postgres` on the new node. |
| **A node's Postgres refuses to start: "PATRONI_REST_PASSWORD is not set"** | Correct behaviour, not a bug ([§7](#7-security--you-must-do-this)). Since 1.2.7 `./taranac update` provisions this key on an already-converted cluster, identically on every node, so an upgrade no longer lands here. If you do meet it: copy the value from a node that already has one — it must be **identical** everywhere — or, if no node has one, run `./taranac update` on each node. |
| **`taranac-db` restarts in a loop saying "REFUSING to start — this node is part of an HA cluster"** | The base compose file was used on an HA node, without the Patroni overlay. Starting there would put a second **writable** Postgres on Patroni's data directory. Bring it up through the wrapper, which merges the overlay itself: `./taranac up -d`. If the node is genuinely no longer in a cluster, shrink it first with `./ha-deconvert.sh`. |
| **A join fails on the new machine with `member count is unequal`** | The node you ran `add-node` from has a declared etcd member list that no longer matches the live ring, and that list is what the joining node is given. Run `./taranac cluster sync` on that node and repeat the add. The preflight stops this before a token is issued since 1.2.7. |
| **`ha-convert` / the join fails writing certs — "cannot write to config/etcd-tls"** | Docker created that directory **root-owned** on an earlier start. `sudo chown -R "$(id -u):$(id -g)" config/etcd-tls config/etcd-ca config/cluster-secrets`, then retry. |
| **A re-join won't form quorum / etcd "cluster ID mismatch"** | A stale `taranac_etcd_data` volume from a previous cluster. The join clears it automatically — let the script run rather than pre-clearing volumes by hand. |
| **The tooling refuses with "< 3 etcd members"** | The declared ring is too small. A 2-node cluster needs a witness: `./taranac cluster add-witness --address <a third host>`. |
| **A `cluster:readiness` / `cluster:readiness_blind` or grant alert** | Only relevant if you run a hardened, non-superuser database. The app role is missing a stats grant — see the design spec `docs/ops/ha.md` The default Taranac DB image is unaffected. |
| **Worried about split-brain** | With a witness there is none: a partitioned old primary self-demotes to read-only on its own (it cannot reach quorum), so two writers never exist. Just keep the witness in a separate failure domain. |
| **A node shows as a "phantom streamer"** | A removed node is still physically running — finish Step 2 of [§5 Remove a node](#remove-a-node): wipe it or detach it. |

---

## 9. A note on the database image

Taranac's standalone and HA Postgres images are **both Alpine/musl** on purpose,
and the HA conversion **adopts your existing data dir in place**. Do not
substitute a custom or third-party Postgres image: adopting a data directory
across a different C library (e.g. a Debian/glibc image) silently corrupts text
indexes with no warning. This is handled for you by the bundled images — there is
nothing to configure. The reasoning is in the design spec `docs/ops/ha.md`

---

## 10. How it works (under the hood)

You do not operate Patroni/etcd directly, but knowing the moving parts makes
diagnostics obvious.

**What runs where**

- **Each DB node** runs the full stack: the Taranac **api**, the three **daemons**
  (radius / tacacs / nac), one **etcd** voting member (`taranac-etcd`), and the
  **database** container `taranac-db` — which is the `taranac-postgres-ha` image:
  **Patroni** supervising **PostgreSQL 16** (Alpine/musl). Patroni renders Postgres'
  config and decides, with etcd, who is primary.
- **The witness host** runs **only** an etcd member (`taranac-witness-etcd`) — no
  Postgres, no Taranac.

**Roles.** Exactly one node is the **primary** (read-write); the rest are
**read-only replicas** streaming the primary's WAL. The agreement on "who is
primary" lives in **etcd** (the DCS); Patroni reads it to elect and to fail over.
In Taranac the rule is simply **leader == Postgres primary**.

**Where reads and writes go.** The api and all three daemons read `DB_HOSTS` (every
node's Postgres endpoint). **Writes** carry `target_session_attrs=read-write`, so
they always land on whichever node is currently primary. **Daemon reads stay
node-local** — each daemon reads its own node's replica and serves AAA from that
plus in-memory caches. That is why **authentication never depends on the primary
being up**: a replica node keeps answering TACACS/RADIUS/NAC from local data even
mid-failover. Only *writes* (UI config edits, accounting rows) briefly pause.

**Failover.** When the primary stops renewing its etcd lease (the DCS TTL, **~30 s**),
Patroni promotes the most up-to-date replica, the other replicas re-point to it, and
the api reconnects through the multi-host `DB_HOSTS` string. **Leader-only work
migrates automatically** to the new primary (it is gated on
`NOT pg_is_in_recovery()`). The old node, when it returns, rejoins as a replica via
**`pg_rewind`** (fast — no full re-clone). You do nothing.

**Quorum & split-brain.** etcd needs a **majority** of members to act. Two DB nodes
are an even split, so a network partition would deadlock — that is what the
**witness** (a 3rd voting member) is for. A partitioned old-primary that can no
longer reach a majority **self-demotes to read-only on its own**, so two writers can
never coexist. Three or four DB nodes have a natural majority.

**How each node knows what the others are configured with.** Every node publishes a
small, **non-secret** topology map (its `DB_HOSTS`, `ETCD_HOSTS`,
`ETCD_INITIAL_CLUSTER`, `PG_ALLOW_CIDR`, etcd client scheme, version and HA marker)
plus a fingerprint of it into the cluster heartbeat every 30 s. The write routes to
the primary and replicates, so any node can read what every other node *actually
holds* without asking it — which is what makes the preflight
([§3.5](#35-the-preflight--every-member-is-consulted)) able to answer even when a
member is in trouble. Credentials are deliberately **not** in that map: it lands in
a replicated table that ends up in every backup.

On the same beat each node also attempts a real `replicator` login to every other
node and publishes that verdict — the matrix `./taranac cluster connectivity` prints
([§3.6](#36-verify)). Configuration agreeing is not the same as replication being
*possible*, and that difference only shows up at the failover that needs it.

**Readiness gate (config safety).** Before a node reloads daemon config it checks
its own replication lag. Normal small lag is fine (the gate is a no-op). But a node
whose streaming is **broken or badly behind** (lag past the cutoff, default 45 s)
will **not** reload daemon config from stale data — it **freezes config on the
last-good version** and raises an alert. It is a tail-safety for broken replication,
not a freshness knob; auth keeps serving throughout. (Inert on a single node.)

**Replication slots.** Patroni keeps a slot per replica so the primary retains the
WAL each replica still needs. A removed node's slot is auto-dropped by Patroni about
**30 min** after its membership expires; a conservative backstop reaper (every
10 min) cleans only genuine orphans. Disk is protected regardless by
`max_slot_wal_keep_size=2GB`. **Never drop a slot by hand** — Patroni would recreate
it.

---

## 11. Logs — what each component writes, and where

Everything is a container; the table is where each one sends its log. Prefer
`./taranac logs <service>` (it merges the HA overlay for you); `docker logs` /
`docker exec` are shown for the cases that need a specific container.

| Component | Where it logs | How to view |
|---|---|---|
| **Backend api** | stdout (**node-tagged JSON**, one object per line) | `./taranac logs api` |
| **Database** (Patroni + Postgres) | stdout of `taranac-db` | `docker logs taranac-db` (Patroni logs promotions/failover here) |
| **etcd** | stdout of `taranac-etcd` (witness: `taranac-witness-etcd`) | `docker logs taranac-etcd` |
| **RADIUS daemon** | stdout (radiusd + Python handler) | `./taranac logs radius` |
| **NAC daemon** | stdout | `./taranac logs nac` |
| **TACACS daemon** | **a file inside the container** — `/var/log/taranac/syslog.log` (tac_plus-ng → syslogd, **not** docker logs) | `docker exec <tacacs> tail -f /var/log/taranac/syslog.log` |
| **Parsed AAA records** (all 3) | dated files `/var/log/taranac/aaa/<proto>/<type>/YYYYMM/YYYY-MM-DD.log` | view in the **UI → Logs** / DB instead — the files are an export tier, not the place to read AAA history |

**The join commands log to your console, and nowhere else.** `cluster-broker.py`,
`ha-join.sh` and `witness-join.sh` narrate their steps as they run; there is no
join log file to find afterwards. If you want a transcript, capture it (`| tee`) —
the output is line-flushed so a pipe shows it live.

**HA-relevant lines to grep:**

- A **readiness-gate block** is logged in the **api** as a WARNING:
  `Readiness gate BLOCKED <daemon> reload on node <name> (reason=…, lag=…s)`. If
  daemon config "won't apply" on a node, grep the api log for `Readiness gate
  BLOCKED`.
- **Failover / promotion** is logged by Patroni in **`taranac-db`** (and surfaced as
  a cluster-status alert + in `./taranac cluster status`).
- Every backend log line is a JSON object carrying a **`node`** field (this node's
  name) — so a merged multi-node log stream stays attributable. See §12.

---

## 12. Log levels & raising verbosity

Verbosity is controlled **per component** — there is no single cluster-wide log
level.

**TACACS — runtime, no restart (the easy one).** Toggle the setting
**`tacacs.debug_enabled`** in **Settings → System** (or via the API). Turning it on
makes the backend re-render the tac_plus-ng config with `debug = PACKET AUTHEN
AUTHOR` and reload the daemon — debug then appears in
`/var/log/taranac/syslog.log` inside the tacacs container. No file editing, no
restart. Turn it back off when done.

**RADIUS / NAC Python handlers — env, needs a daemon restart.** Each handler honours
a **`LOG_LEVEL`** env var (`DEBUG | INFO | WARNING | ERROR`, default already
`DEBUG`). Set it in that daemon's environment (`.env` / compose) and restart the
daemon container.

**RADIUS / NAC FreeRADIUS engine itself — no setting.** For deep FreeRADIUS
protocol debug, run it in the foreground manually inside the container
(`radiusd -X`); this is an advanced, temporary step.

**Backend api — env, needs a container restart.** The api honours a **`LOG_LEVEL`**
env var (`DEBUG | INFO | WARNING | ERROR`, default `INFO`). Set it in the api's
environment (`.env` / compose) and restart the api container — it is the **single
verbosity knob** for the backend (it drives the app, uvicorn access *and* uvicorn
error logs alike; you do **not** pass uvicorn `--log-level`). `LOG_LEVEL=DEBUG`
turns on the chatter; `LOG_LEVEL=WARNING` quiets it down — note that `WARNING` also
silences the per-request access lines.

Backend logs are emitted as **structured JSON, one object per line**, and every
line carries a **`node`** field (this node's name — from `TARANAC_NODE_NAME`, the
Patroni member name under HA, falling back to the container hostname). That is what
makes a merged multi-node stream readable: filter or group by `node` to see one
node at a time. To pretty-print or filter, pipe through `jq`, e.g.
`./taranac logs api | jq -c 'select(.node=="node-2" and .level=="ERROR")'`.
File output + rotation are also available (`LOG_OUTPUT=file|both`,
`LOG_FILE_PATH`, `LOG_FILE_MAX_SIZE_MB`, `LOG_FILE_BACKUP_COUNT`); the default
`LOG_OUTPUT=stdout` is what `docker logs` / `./taranac logs api` read.

**Patroni / etcd / Postgres.** These run at their managed defaults. For Postgres
verbosity, change parameters through Patroni (`patronictl … edit-config`, §13) — do
not hand-edit `postgresql.conf`, Patroni owns it.

---

## 13. Diagnostics — a health-check playbook

**Collect everything below in one command — on every node:**

```bash
./taranac diagnose --ha
```

It writes one archive per node holding this node's view of the cluster: its role and
timeline, the etcd ring, Patroni's view, replication and slots, reachability to every
declared member on every port, certificates, clocks and logs — plus a **Findings**
section that names what it noticed in plain words. It reads state and changes nothing.

**Run it on EVERY machine, the witness included, and send all the archives.** That is
not politeness — almost every HA fault is a *disagreement* between hosts (a timeline
that forked, a secret that differs, a ring one node knows and another does not), and a
disagreement cannot be seen from one side of it. Each bundle prints one
`cluster-fingerprint` line: identical on every node means every cluster-wide secret
agrees, and if it differs the per-key block names the value that drifted.

It is deliberately safe in the states you actually need it in — a node whose database
will not start, a node that was never converted, and the witness. It reads `.env` from
the host, reads the timeline straight off the data volume when the container is dead,
and asks a *peer's* Patroni when the local one is gone. No password, key or token ever
reaches the archive: cluster-wide values appear only as 12-hex fingerprints.

The rest of this section is what the collector automates — run it by hand when you
want to watch something change, rather than capture it once.

Run these from any node. Start at the top; most issues are visible in the first two.

**1. Cluster status (the first thing to run):**

```bash
./taranac cluster status
```

Shows edition (`Pro (HA)` vs `Community`), node count / `max_nodes`, the **leader**,
a per-node table — **NAME / ROLE / SYNC / LAG / BEHIND / ADDRESS** — and warnings for
over-cap or phantom streamers. Read the **SYNC** column:

- **`in_sync`** — streaming, lag < 10 s. Healthy.
- **`behind`** — streaming but lag ≥ 10 s. Watch it; a node that stays behind > 45 s
  trips the readiness gate (its daemon-config reloads freeze) and raises a
  `cluster:readiness` alert.
- **`unreachable`** — a roster node that is **not** streaming at all. Broken
  replication or a down node.

**LAG and BEHIND answer different questions.** LAG is time; BEHIND is the volume of
WAL that node has not replayed. A replica that has stopped replaying entirely can
report a small, static seconds-lag while its byte figure grows — and the byte figure
is the one that says what a **forced promotion would throw away**.

**1b. Can every node actually log in to every other node?**

```bash
./taranac cluster connectivity            # grid; exit 0 only if every pair is proven
./taranac cluster connectivity --format tsv   # one line per ordered pair, for scripts
```

Each node continuously attempts a real `replicator` login to every other node and
publishes the verdict, so this answers the question `status` cannot: whether each
peer's `pg_hba` will admit each other node **when a failover needs it**. `stale` and
`unknown` are **not** successes — the exit code treats them as failures, and so
should you. The usual cause of a red cell is a `PG_ALLOW_CIDR` on that source node
that does not cover the target.

**2. Local container health on this node:**

```bash
./taranac ps
```

**3. Patroni's own view (authoritative; use when status looks wrong):**

```bash
docker exec taranac-db patronictl -c /tmp/patroni.yml list
# role (Leader/Replica), state (running/streaming), lag per member
```

Patroni REST (same data, scriptable) — **reads need no credential**:

```bash
curl -s http://<node>:8008/cluster | jq      # the whole ring
curl -s http://<node>:8008/                  # this node's role/health
```

Anything that **changes** the cluster (`POST /switchover`, `/failover`, `/restart`,
`/reload`) requires HTTP Basic auth with `PATRONI_REST_USERNAME` /
`PATRONI_REST_PASSWORD` from `.env` ([§7](#7-security--you-must-do-this)). Prefer
`./taranac cluster switchover`, which is RBAC-gated, audited, and reports the
observed outcome rather than the accepted request.

**4. Which node am I / who is primary:**

```bash
docker exec taranac-db psql -U taranac -d taranac -tAc "select not pg_is_in_recovery()"
# t = this node is the primary,  f = replica
```

**5. Replication health (run on the primary — a replica returns nothing):**

```bash
docker exec taranac-db psql -U taranac -d taranac \
  -c "select application_name, state, sync_state, replay_lag from pg_stat_replication;"
```

One row per streaming replica. `application_name` is the node's `TARANAC_NODE_NAME`.
If the rows appear but `state/replay_lag` read **NULL**, the database role lacks
`pg_read_all_stats` — see the `cluster:readiness_blind` alert in §14.

**6. etcd / quorum:**

```bash
docker exec taranac-etcd etcdctl endpoint health --cluster
docker exec taranac-etcd etcdctl member list -w table
```

A member with **no client URL** is *declared but not running* — etcd calls it
"unstarted". A member marked as a **learner** is present but does **not vote**, so
it does not count toward quorum.

**7. The declared cluster vs the real one:**

```bash
./cluster-manifest.py validate       # is config/cluster.yml well-formed?
./cluster-manifest.py list           # what this node declares: name, address, role
```

**Quick map — symptom → where to look:**

| Symptom | Look at |
|---|---|
| Anything at all, and you want one answer rather than seven commands | `./taranac diagnose --ha` **on every node** — its Findings section states what it noticed, and the bundles compare against each other |
| A node is `unreachable` / missing | its `taranac-db` log (`docker logs`), then §13.5 on the primary, then etcd health |
| Lag growing on one node | that node's disk/IO and `taranac-db` log; check it is not also tripping `cluster:readiness` |
| "Config won't apply on a node" | api log → grep `Readiness gate BLOCKED`; that node is out of sync (§14 `cluster:readiness`) |
| No automatic failover happened | etcd quorum / the **witness** — a 2-node cluster without a witness will not auto-fail-over (§2) |
| `./taranac` refuses an `up`/`restart` on an HA node | the `docker-compose.ha.yml` overlay is missing — restore it with `./taranac update` (the refusal is the split-brain guard, §5) |
| A join failed and you want to retry | just re-run the `add-node` / `add-witness` command on the primary — a fresh token and a fresh certificate are issued each time, and nothing on the cluster was changed by the failure |
| A `cluster` command refuses on the machine you are on | you are probably in the wrong terminal — [§3.7](#37-which-command-runs-on-which-machine) lists what runs where and what each refusal looks like |
| A node's `.env` is out of date after a join | run `./taranac cluster sync` **on that node** ([§5](#bring-a-node-back-up-to-date)) |

---

## 14. Alert reference

Taranac raises these in the **UI** (and via syslog) — you do not poll. They are
stateful and **auto-resolve** when the condition clears. The relevant ones for HA:

| Alert (fingerprint) | Severity | What it means | What to do |
|---|---|---|---|
| `cluster:readiness` | warning | A replica node is too far behind (broken/stalled streaming, lag past 45 s); its **daemon-config reloads are frozen on the last-good version**. Auth still serves from caches. | Find why it stopped streaming (§13.5/§13.6); it auto-clears on catch-up. Brief config staleness on that node only. |
| `cluster:readiness_blind` | **error** | The database role can see `pg_stat_replication` rows but the columns read NULL → it lacks **`pg_read_all_stats`**, so the readiness gate / status run blind. | Only on a hardened, non-superuser DB. `GRANT pg_read_all_stats` to the app role. The bundled image is unaffected. |
| `cluster:replication_grant` | **error** | Under HA the app role lacks the **`REPLICATION`** attribute, so the orphan-slot reaper cannot drop slots. | `ALTER ROLE <app role> REPLICATION`. Bundled image unaffected. |
| `cluster:phantom_node` | warning | A node is **streaming under a name that matches no active roster entry** — either a node-name mismatch, or a **removed node still physically running**. | Fix the name mismatch, or finish the physical half of the removal (§5). |
| `cluster:max_nodes` | **error** | Active nodes exceed the license `max_nodes`, or you are multi-node without an HA license. | Remove a node, or upload a license granting `ha` / a higher `max_nodes`. |
| `cluster:orphan_slots` | warning | Replication slot(s) match no active node and were **not** auto-dropped (ambiguous / still streaming). | Confirm the node is truly gone, then it will be reaped; never drop slots by hand. |
| `license:validation` | **error** | The stored Pro license cannot be honoured (bad signature / wrong installation / expired). Surfaces only — disables nothing. | Upload a valid license at Settings → System → Licensing. |

The hourly leader-only reconcile re-checks the grant / over-cap / phantom alerts;
the slot reaper runs every 10 min. So a transient condition clears on its own within
those windows once you have fixed the root cause.

---

For the full architecture, failover internals, quorum proofs and slot lifecycle,
see the design spec `docs/ops/ha.md`.
