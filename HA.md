# High Availability (Pro)

This is the operator runbook for running Taranac as a **High Availability cluster**.
It is self-contained — you should not need to read anything else to deploy or
operate HA. The design rationale behind these decisions, and the options that were
rejected, are kept in Taranac's internal documentation; that is not part of this
bundle — ask TaranacLabs if you need it.

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
3. **All nodes on the SAME version.** Check with `./taranac version` on each
   host; they must match before you build the cluster. A joining node whose
   bundle is on another version is refused before anything changes (item 6).
4. **Know the addresses** — every node's routable address *and* a **witness host**
   (see below). You answer them **once, on node-1**; nothing is copied into any
   other node's `.env` by hand.
5. **A private network between the nodes.** Replication, etcd and Patroni traffic
   must travel a trusted interconnect, not the public internet (see
   [§7 Security](#7-security--you-must-do-this)). **And each database node's own
   Docker network (its address pool `10.255.255.240/28`) must reach that node's own address on `2379`
   and `8008`**: Patroni and the api dial every etcd member — their own node's
   included — from the Docker network, and Patroni asks its own REST API at the
   node's address whenever a switchover names that node. A host firewall that admits
   only the LAN cuts a node off from its own etcd, and makes it refuse itself as a
   switchover candidate. One rule covers both ([§7](#7-security--you-must-do-this));
   the tooling tests both ports before it changes anything and prints that rule.
6. **The other machines already have the bundle unpacked** — a joining DB node
   needs an ordinary `./install.sh`ed node **of the cluster's version** (a node on
   another version is refused before anything changes, and told to run
   `./taranac update --version <cluster version>` first, then the same join command
   again — the primary keeps waiting); a witness host needs only the unpacked
   bundle (`docker-compose.witness.yml`, `witness-join.sh`, `ha-etcd-ca.sh`, and
   `ha-probe.sh`, which reads the witness etcd's log for the cause of a failure) plus
   docker, curl, openssl and python3 — **on the cluster's version too**. A witness on
   another version is refused the same way and told to run
   `./taranac update --version <cluster version> --no-restart` (a witness runs no
   Taranac services, so only its files are refreshed), then the same command again.
7. **TACACS+, RADIUS and NAC ports are set per node.** `TACACS_PORT`,
   `TACACS_TLS_PORT`, `RADIUS_AUTH_PORT`, `RADIUS_ACCT_PORT`, `NAC_AUTH_PORT` and
   `NAC_ACCT_PORT` in each node's own `.env` are the ports that node publishes, its
   daemons listen on and its settings pages show; the shared database does not carry them. Keep them the
   same on every node unless you mean otherwise — a device configured for one
   node's port fails over to a node that listens on another.
8. **The TACACS+ over TLS and EST gateway certificates are per node.** Each node
   generates its own stubs and signs them with **its own** Infrastructure CA (from
   its own `taranac_certs`; joining does not copy it). A device that fails over
   between nodes must trust every node's CA — or put a certificate of your own, from
   a CA your devices already trust, on every node (TACACS+: Deploy on the TACACS+
   settings page; EST gateway: `server.crt`/`server.key` in the node's
   `taranac_certs` volume under `est-gateway/`).

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

- The witness runs **only** `docker-compose.witness.yml` — etcd and the small
  `etcd-agent` that renews its certificate (§4.2), **no Postgres, no Taranac
  stack**. It is tiny (a management VM is fine) and stores kilobytes. It pulls the
  agent image from `ghcr.io/taranaclabs/taranac` — or, air-gapped, from the mirror
  named by `ETCD_AGENT_IMAGE_PREFIX` in its `.env`.
- It **MUST be a separate host.** Co-locating the witness with a DB node is
  useless: losing that host loses a DB node *and* the tiebreaker at the same time.
  `witness-join.sh` refuses to run on a machine that has a `taranac-db` or
  `taranac-api` container, for exactly that reason.
- The tooling **refuses** a cluster that does not declare at least **3 etcd
  voting members**. This is not optional.
- A witness holds **no database, no `MASTER_KEY` and no application credential**.
  Of the cluster's secret set it holds one thing since 1.3.3: the **etcd CA key**,
  which it needs to renew its own etcd certificate (§4.2). Losing the machine costs
  nothing; someone else holding its disk holds that key — protect it accordingly
  ([Replacing the etcd CA](#replacing-the-etcd-ca) is the answer to a lost one).

> **With 3 or 4 DB nodes you still declare one, and the build is still the same
> three commands.** Quorum-wise you would not need it — three database nodes are
> already a majority of themselves — but `cluster init` asks for a witness address
> and **refuses without one**, whatever the node count, and `add-witness` is the
> command that performs the conversion. So plan for the extra host either way: it
> needs docker and about 200 MB, and nothing else.
>
> Be clear about what it does and does not buy you there. Three DB nodes plus a
> witness is a **4-member ring**, so a majority is 3 and you survive losing **one**
> member — the same as three DB nodes alone. The witness does not raise fault
> tolerance at that size; it is the tiebreaker that makes a **2-node** cluster
> safe, and above that it is what the build sequence is made of.

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
| `--witness ADDR[=NAME]` | the 3rd etcd arbiter, on a separate host |
| `--node ADDR[=NAME]` | another Taranac node — repeatable |
| `--pg-allow-cidr LIST` | the `pg_hba` scope (default: the /24 of each declared address) |
| `--force` | recreate `config/cluster.yml` — **discards your `skip:` entries** |
| `--yes` / `-y` | non-interactive; every value must be given on the command line |

**Naming the nodes.** Omit `=NAME` and each node is called `<cluster>-node-N`.
Give it and the node is called what you call it, everywhere the name appears —
`ETCD_NAME`, the etcd ring, the certificate, the roster row, Patroni and every
diagnostic bundle:

```bash
./taranac cluster init --cluster PlasmaNetworks \
    --address 192.168.8.58 --name acs-lom-01 \
    --witness 172.16.0.59=acsw-kan-01 \
    --node    192.168.16.58=acs-nek-01 --yes
```

The name and its address travel as ONE argument on purpose: with a separate
`--node-name` the pairing would be positional, and one omitted name would shift
every later name quietly onto the next machine.

⚠️ **This is the only moment a name is chosen.** There is no rename: the name is
written into the etcd ring, the certificates and every node's `.env`, and
changing it afterwards means rebuilding that machine. `init` says so before it
writes anything, for any name it had to derive.

**Why you declare the whole topology now.** The etcd ring must be declared
*complete* before the conversion: `--prepare` issues one certificate per member of
the declared ring, so a member that is missing from it gets no certificate and can
never join. Declaring it all up front also means every node carries the same node
list from day one, so nothing has to be rewritten later on a live member.

**Before it writes anything, `init` logs in to this node's database as `replicator`
with `POSTGRES_REPLICATION_PASSWORD`**, the way every replica will — from the Docker
network the database is on. That role was created once, when this node's database was
initialised, and nothing has kept it in step with `.env` since; a mismatch used to
surface only on a joining node, after its database had been discarded
([§7a](#7a-durable-gotchas--the-ones-that-bite-silently) item 5). This node's stack
must be running for the check (`./taranac up -d`).

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

The token is hex and printed as two words, `--token <secret>`, because that is the only
form the join scripts of 1.3.2 and older parse — and a machine still on an older bundle
must reach the broker's version check, which tells it the one `./taranac update` to run,
rather than stop at its own argument parser. Hex never begins with `-`, so no token can
be read as an option.

Run that on the witness host, in the unpacked bundle directory. `witness-join.sh`
pins the fingerprint **before it says anything**, takes the cluster's etcd topology
from the channel, generates its **own** private key and sends only a certificate
request, writes a complete `.env` for `docker-compose.witness.yml`, starts etcd,
and then **proves** the result — it does not announce it.

Before it opens that channel, `add-witness` repeats `init`'s `replicator` login on
this node (it may be days later).

Back on node-1 the command then runs `ha-convert.sh --continue` (the real
conversion: Patroni adopts your existing data directory in place, forms quorum
with the witness, and promotes this node). **Everything that can refuse runs while
the standalone stack is still serving:** etcd is started beside it, quorum with the
witness is awaited, and every live etcd member — this node's own address included —
is called from the Docker network, as Patroni will call it, and so is this node's own
address on `8008` (through a stand-in listener: Patroni does not run yet). Only when all of that
passes is the standalone stopped and the node brought up on the HA overlay; a refusal
leaves it running and says so. It then verifies two things before it
reports success: this node's Postgres reports `not pg_is_in_recovery()`, and the
witness is a **voting** member of the ring with a live client URL.

> If node-1 is **already** an HA node, `add-witness` skips the conversion and just
> adds (or replaces) the witness in the running ring. Run again after an interruption,
> with the witness already voting, it adds nothing: it verifies the leader and the ring
> and says so ("Nothing was added").

`TARANAC_HA=1` is written the moment Patroni is handed the data, before the overlay
starts. From then on the data is Patroni's, whatever happens next — so a conversion that
fails after that point says which of two states it left (the database is primary and
some services are unhealthy; or it never became primary) and prints both ways out:
`./taranac up -d` and the same `add-witness` again, or `./ha-deconvert.sh` back to
standalone ([§8](#8-troubleshooting)). Before the conversion, `config/cluster.yml` on
node-1 is the cluster's only copy: `add-witness` works from it without asking the api,
and publishes it once the converted node's api is up.

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
   with `./taranac restore ./pre-join-backup/<that file>` — the path on this host is
   enough; the restore copies it into the backups volume itself. Note what it is: a **configuration**
   backup — devices, users and settings come back from it; **log records do not**.
   Export anything you need from Reports before confirming. (`--no-backup` skips
   this, for when you took one another way.)
7. **Make, from this node's Docker network, every connection the cluster will
   need — before a single cluster value is written here.** It asks Patroni on the
   first declared node that answers (`GET :8008/cluster`) who the members are and
   which one leads, then: logs in to the **leader** as `replicator` on `5432` and
   reaches its Patroni on `8008`; reaches `2379` and `2380` on every other etcd
   member (the witness included); and reaches **its own** address on `2379` and `8008`
   through stand-in listeners, because its own etcd and Patroni do not exist yet. Any of those failing
   stops the join with one cure per finding — nothing on this host has changed; fix
   it and run `add-node` on the primary again for a fresh command. The same checks
   against a member that is **not** the leader only warn (the clone reads from the
   leader; after a failover to that member this node could not follow it). A node
   declared in `DB_HOSTS` that Patroni does not list yet is said and not probed.

   **These checks are OUTBOUND only** — from the new node to the others. Nothing can
   test, from the new node, what the others will send **to it**, and that must be
   open too before you run the join: from every other member (the witness included)
   to the new node's **`2380`** (etcd peer traffic, from the moment it joins the
   ring) and **`2379`**, and from every other DB node to its **`5432`** and **`8008`**
   (once it is a replica, a failover can make it the leader the others clone from
   and Patroni calls). The same firewall rule you wrote for the existing members,
   extended to the new address, is what it takes.
8. Receive the cluster's wrapped key material — the master key, the shared MFA key
   and **the cluster's etcd CA**, so that no single machine's loss can leave the
   cluster unable to grow ([§4.2](#42-certificates-a-request-not-a-copy)).
9. Discard the local database, join the etcd ring, and bring the stack up under
   the HA overlay so Patroni clones this node from the primary.
10. Wait until the local Postgres is really a streaming replica, then until this
   node's own api has **registered** it — an active roster row and the join token
   consumed; the api does both when it starts — and report the outcome back to
   node-1's console.

**If a join stops after the clone.** A join killed there (an ssh session that dropped)
leaves a node that streams and that the roster cannot name. Every command that meets it
— `ha-join.sh` itself, `add-node`, `remove-node`, `diagnose --ha` — prints the same
finish, with the time the token expires:

```bash
./taranac up -d                    # on that node: its api starts and registers it
./taranac update --version <v>     # on that node: writes its version record, restarts nothing
```

Registration is done by the node's api, not by the script, because the api is the one
thing that runs whenever the node runs: a join killed after the api started is
registered all the same, and one killed before it is finished by starting the api — no
token to copy, nothing to revoke. (`ha-join.sh` starts what a failed `up -d` left down
itself once the node streams, before it waits.) The api uses a token only while it is
pending. After it expires, a **new token for the same name and address** is the way —
not a re-clone: `./taranac cluster join-token --name <n> --address <a>` on the primary,
then on the node `./taranac up -d` (or `./taranac restart api` when its api already runs
and made its row without a token) and `update --version <v>`. The cluster lets an expired,
unconsumed join be invited again under its own name and address, because that row is the
node being finished, not a name already taken or one more node. `add-node --reinstall` is
the last resort the finish names after that.

Back on node-1, `add-node` then confirms — by asking **Patroni**, which answers the
same from any node — that the new member is a replica in a running state. A node in
the ring that is not replicating cannot take over, and that is not a success.

Repeat once per node, up to your license's `max_nodes`.

> **That is the whole build.** If those three commands succeeded, go straight to
> [§3.6 Verify](#36-verify) and confirm it — that is the step that finishes the job.
> [§3.4](#34-the-manifest--configclusteryml) and
> [§3.5](#35-the-preflight--every-member-is-consulted) in between describe the file
> the wizard keeps and the checks it runs before it grows the cluster; you need them
> when a command **stops**, not to build.

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
about the quorum checks is bypassed by taking this route. **Before** it evicts
anything, a reinstall checks the license (`./taranac cluster license-check` — exit 0
when a join token can be issued) and runs the preflight: the re-add needs a token,
and a node evicted on a cluster that then cannot issue one would stay out.

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
  option to copy along with the printed command. Once accepted, the join records
  `ADDRESS_NOT_LOCAL_OK=1` in this node's `.env`, so `./taranac up` keeps starting a
  node that does not hold its own address ([§5](#5-operating-the-cluster)).

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

**Every node takes the cluster's copy, whole.** The file is published into the
replicated database, and every command that changes the topology (`init`,
`add-witness`, `add-node`, `remove-node`, `remove-witness`) publishes its change
**before** it makes it — and stops, with nothing changed, if it cannot. So the
published copy is always the newest. A node whose own file differs, or that has
none (one that joined later), takes the cluster's copy and keeps its own beside it
as `config/cluster.yml.<time>.bak`; the command says so and carries on. Nothing is
merged: an entry you wrote only into one node's file is not part of the cluster's
copy until you publish it:

```bash
./taranac cluster manifest-publish < config/cluster.yml
```

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
   — and except for the three keys below, each of which is judged on its own terms
   rather than by byte equality.
3. **The new node's address falls inside every member's `PG_ALLOW_CIDR`.** This
   one matters more than it looks: outside that range the new node's replication
   login is refused *after* the TCP handshake, so the port answers and nothing
   looks broken until the failover that needs it. It is a comparison of addresses —
   no packet leaves the primary. Whether the new node can actually **reach** every
   member is tested by the new node itself (step 7 of [§3.3](#33-add-each-remaining-node--on-node-1)),
   by doing it, before anything there changes.
4. **etcd has quorum**, and the ring will still hold **≥ 3 voting members**.

**Bootstrap values that are out of date on a peer are reported but do NOT stop the
add.** `ETCD_HOSTS` and a **peer's** `ETCD_INITIAL_CLUSTER` are what that member's
containers were started with. A running etcd takes its ring from Raft and write
routing follows the replicated roster, so nothing reads them until that member
restarts — and its next `./taranac update` rewrites them from the roster and the live
ring right before it restarts anything. Nothing to do by hand: restarting a member
for them would restart Patroni, which on the leader is a failover.

**This node's own `ETCD_INITIAL_CLUSTER` does stop the add** when it does not name
every live member — `add-node` hands **this** node's list to the machine being
joined, and etcd refuses a short one (*"member count is unequal"*). `add-node` first
brings this node's own `.env` up to what the roster and the live ring report, without
recreating anything, so this stops an add only when the ring cannot be read.

**A member that does not route writes to every node stops the add.** What a member
routes to is published in its heartbeat as `EFFECTIVE_DB_HOSTS`, derived by its api
from the replicated roster — a node that completed its join is in every member's list
within seconds, with nothing restarted. A member that still misses one has a roster
copy that is behind (its replication is broken), or runs an older version that routes
by its `DB_HOSTS` (update it). Extra entries are fine.

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

`status` should show every machine, with exactly one leader and the rest streaming.
The witness is a row of the same table — role `witness`, its etcd state and the
version its own updater recorded; its database columns read `—` because it has no
database. The first line is the verdict, about **machines**, witness included:

```
Healthy — any one machine (taranac-node-1, taranac-node-2, stand-witness) can be lost and writes continue.

You are on: taranac-node-1 (leader). Leader: taranac-node-1.
```

When the witness (or any member) does not answer, the verdict says so and what one
more loss would cost — `Degraded — stand-witness is down. One more loss stops
writes.` — and a line under the table names the reason and the command for that
machine. Three database nodes and no witness (after `remove-witness`) is a normal,
healthy cluster: no witness row and no warning. A roster row that neither Patroni
nor etcd knows and that never was a machine is shown under the table as a *stale
roster row*, with its `decommission` command — never as a database node that is
"behind". If the api cannot read the etcd ring, the verdict stays with "any one
database node" and says why.

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

#### The rehearsal — the step that finishes the job

Everything above describes how the cluster is **built**. `connectivity` says so in
as many words: it proves "the legs that will matter *after* a failover". Nobody
had ever made one happen. This is the door being opened:

```bash
./taranac cluster verify            # inspection only — never disruptive
./taranac cluster verify --rehearse # …and actually hand leadership over, and back
```

Without `--rehearse` it is a read: the survivability verdict, the roles, the lag,
the connectivity matrix and the **`max_connections` each node is actually running
with**, with a non-zero exit if anything is not ready. That last one is asked of
every node rather than read from any configuration, and it is the one result that
can make `verify` exit non-zero on a cluster that is otherwise healthy and passed
its rehearsal — an old connection ceiling is a change nobody has applied yet, not
an inability to lose a node. When it reports one, it prints the procedure that
raises it, in the order it has to be done: **replicas first, the leader last.** The
same procedure, with what it costs and why, is
[§5 Raise the connection ceiling](#raise-the-connection-ceiling).

**The survivability verdict is decided in bytes of WAL, not seconds.** "Can this
replica take over?" is Patroni's decision and Patroni makes it by comparing WAL
positions against `maximum_lag_on_failover`, so `status` reads that threshold from
Patroni and prints it (`Promotion bar: 1.0 MB of WAL`). The `LAG` column still shows
seconds because that is what a person reads, but nothing is concluded from it: under
real write load a replica can be a fraction of a second behind and tens of megabytes
behind at the same moment, and only the second of those decides whether you keep
writing. If Patroni's threshold cannot be read, the verdict says so rather than
guessing — a survivability line computed against an assumed number looks exactly
like a real one.

Neither command will ever answer with a Python traceback. A refusal is a sentence, a
non-zero exit and, where one exists, the command that fixes it — and because the
rehearsal moves leadership, an interruption — or a hand-back Patroni refuses — also
says which machine it left leading and the command that puts it back, and where to
run it: on the node that leads now.

With `--rehearse` it hands leadership to a healthy replica — the one whose turn was
longest ago, so repeated runs prove every replica in turn; `--to NAME` picks one —
**writes a real row on the new leader** and times how long that took, waits for the old leader to come
back as a streaming replica, and hands leadership back. Then it says, in words:

```
The cluster survived losing its leader.
  Writes resumed 6.9s after the handover began.
  taranac-node-1 left, came back, and took the lead again.
  You can lose any one machine and keep working.
```

The last line is read from the ring after the handovers: it says "any one machine"
only when the etcd ring keeps a majority without any one of its members. Otherwise
it stays with "any one DATABASE node" and quotes the verdict that holds it back.

It is a **planned handover**, not a kill: Patroni waits for the target to catch up,
so nothing is lost. A kill proves less and costs more.

⚠️ **Run it once, here, before the cluster carries traffic.** Two leader changes
mean a few seconds without writes each. The command refuses to rehearse on a
**ring formed** more than a day ago — age is a proxy for "someone is depending on
this", not a traffic measurement — and `--even-if-serving` gets past that when you
know better. The ring's formation is stamped into `.env` by `cluster init` and
adopted by every node that joins, so a cluster rebuilt on an existing database is
dated from the rebuild rather than from the data. A cluster built before that stamp
existed has none, and the refusal then says plainly that what it measured was the
oldest **roster** row instead. It also refuses outright on a cluster that is not already healthy: there
is nothing to learn from removing the leader of a cluster with nothing to take
over, and no flag makes a missing replica promotable.

This is the only check that walks the whole promise. A cluster whose leader demotes
itself every few minutes cannot complete it cleanly — which is exactly the shape
that is otherwise found weeks later, in production.

**The database is one half.** `verify` sees roster nodes; the etcd ring, witness
included, is not a roster row. `./taranac diagnose --ha` is the other half, and
§13 says what it looks at.

### 3.7 Which command runs on which machine

There are four kinds of machine in a cluster, and the `cluster` commands are not
interchangeable between them. Every refusal below is a real guard in the tooling.

| Command | Runs on | Everywhere else |
|---|---|---|
| `cluster init` | the **future seed** — installed, populated, still standalone | On an already-converted node: *"this node is already an HA node (`TARANAC_HA=1`)"*. On a host with no `taranac_pg_data` volume: *"init converts an installed, populated node"*. |
| `cluster add-witness` | a **DB node that holds the etcd CA** — the seed, or any node that joined since the CA has been handed out at join. A node without its own `config/cluster.yml` takes the cluster's published copy and says so. | Without the etcd CA: *"this node holds no etcd CA … run this on a node that HAS it"*. With no manifest here **and** none published by the cluster: it stops, because there is no source of truth to restore from. |
| `cluster add-node` | the same: any DB node with the etcd CA | Not converted at all: it prints the three-command order instead. Otherwise the same two refusals. |
| `cluster sync` | **the node that is behind** — never the seed on the seed's behalf | On a node that is not converted: *"this node is not converted to HA yet"*. It changes **only the machine it is run on** and says so before asking. |
| `cluster remove-node` | a **surviving DB node** (conventionally the primary) — it must reach the local Patroni and another member's etcd | Refuses if it cannot read the current leader from Patroni, rather than guessing. Refuses to evict the **current leader**. Only *this* machine's `.env` and manifest are pruned — the other survivors need nothing. |
| `cluster detach` | **the machine being detached** | Refuses while that machine is still a cluster member — run `remove-node` on a survivor first. When no other member answers, membership cannot be checked, so it also needs `--confirm NOT-A-MEMBER` (next to `--confirm FORK-MY-DATA`). |
| `cluster status` · `connectivity` · `switchover` · `join-token` · `register` · `revoke` | **any DB node** (they run inside that node's `api` container) | — |
| `cluster decommission` (and **Decommission** in the UI) | **any DB node** — for a roster row that is a *name*, not a machine | Refuses the current **leader**, any **etcd ring member** and any running **Patroni member**, naming `./taranac cluster remove-node --node <name>`. The UI disables the button for those rows and says why. |
| `./ha-join.sh --broker …` | **the machine being added**, using the command node-1 printed | Refuses on a machine whose identity disagrees with the token ([§3.3.1](#331-the-wrong-terminal-guard)). |
| `./witness-join.sh --broker …` | **the witness host** | Refuses on any host that has a `taranac-db` or `taranac-api` container, a product `.env` or a `taranac_pg_data` volume (a database node whose stack is only stopped) — an arbiter co-located with a node it arbitrates is not a smaller deployment, it is a broken one. Refuses on a host that does not hold the address the primary named (`ADDRESS_NOT_LOCAL_OK=1` for NAT), and on the **live witness of another cluster** (run `remove-witness` there and `--leave` here first). Re-run after an interruption, it keeps the etcd state of a member the ring already counts. |
| `cluster renew-cert` · `rotate-ca` | **any member, the witness included** (they run in that host's `etcd-agent` container); for `rotate-ca` a DB node is the better choice | Without a running `etcd-agent` on the host: *"The etcd agent (taranac-etcd-agent) is not running on this host"*, with how to start or update it. |
| any other `cluster` subcommand | — | **On the witness: all of them are refused**, with the reason (a witness has no database and no API — that is the design, not a missing piece) and a list of what you *can* run there. |

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

`add-witness` / `add-node` start **`cluster-broker.py`**, a one-shot process on the
*host* you run them on (node-1 during the build) — not in the `api` container, and
not a daemon. It lives only for
the duration of one join and exits when that join finishes or times out.

It has to be a host process, for three reasons that are not preferences: the
values it serves live in the host's `.env`, which no container owns; the etcd CA
**private key** lives in `config/etcd-ca/` **on the host** (since 1.3.3 the `etcd-agent`
container uses it to renew this member's certificate and to take part in a CA
replacement, §4.2, but nothing that joins a node can count on a container being there);
and the api container has no Docker socket, so it could not
recreate the stack afterwards anyway. (The one container that is given the socket is
the update finisher, [§6](#6-upgrades-under-ha) — it has no network at all.)

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
> it: back the archive up, and keep the nodes as trusted as you keep node-1. A machine
> that leaves the cluster without being wiped takes its copy along;
> [replacing the CA](#replacing-the-etcd-ca) is what makes that copy worthless.

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

#### Renewal — every member renews its own

A member's certificate is valid for 825 days. Since **1.3.3** you do not renew it by
hand: every member — each database node **and the witness** — runs a small
`etcd-agent` container that renews **its own** certificate **45 days** before it ends,
using the cluster CA key on that machine's own disk. The renewed certificate keeps the
member's key and exactly the addresses the old one named (they are copied, never
added to), and it replaces `config/etcd-tls/etcd-server.crt` in one atomic step. etcd
starts presenting it on the next connection; **nothing is restarted** — not etcd, not
Postgres, not Patroni (the agent has no access to Docker at all). A certificate that
has already expired — a machine that was off for months — is renewed the same way.

To renew now rather than wait:

```bash
./taranac cluster renew-cert          # this member, now (works on the witness too)
./taranac cluster renew-cert --all    # every member renews its own; run it on any member
```

`--all` shows one line per member of the ring — the old and the new end date — until
every member has answered or two minutes have passed, then asks each member which
certificate it actually serves. A member that cannot take part is named, not waited
for: one on a release older than 1.3.3 ("needs update to 1.3.3 or newer"), one whose
agent does not answer ("is its agent running?"). It exits non-zero unless every member
renewed; fix what the table says on those hosts, then run it again. `--timeout <s>`
waits longer.

What the agent did is in its log: `./taranac logs etcd-agent` on that host.

> **The CA key is now on the witness too.** Renewing locally needs it, so after the
> update to 1.3.3 the witness asks for it and a database node's agent sends it —
> **encrypted to the witness's own certificate**, and accepted only if it belongs to
> the CA the witness already trusts. A witness joined from 1.3.3 on receives it during
> `witness-join.sh`, wrapped like every other join secret. It is stored 0600 under the
> owner of `config/` and deleted by `./witness-join.sh --leave`. Protect the witness
> as you protect a database node.

The **cluster CA** itself (10 years) is not renewed by this — a member's certificate can
never outlive it. It is **replaced**, with the cluster running, by
`./taranac cluster rotate-ca`: [§5 Replacing the etcd CA](#replacing-the-etcd-ca).
`cluster:etcd_ca_expiring` warns six months ahead.

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

**What the wrapper refuses, and why.** Each of these used to need a repair by hand:

- `./taranac down -v` on a cluster node or the witness — `-v` deletes the database,
  the etcd state, the backups and the master key. Stop with `./taranac down`; take a
  node out with `remove-node`. (On a standalone install it needs
  `--confirm=DELETE-ALL-DATA`.)
- `up`/`restart` on a node that never finished becoming a member: on the seed between
  `cluster init` and `add-witness` (next: `./taranac cluster add-witness --address
  <witness>`), or after an interrupted `ha-join.sh` (next: on the primary
  `./taranac cluster add-node --address <this node>`). To give up instead and run the
  node standalone again: `./ha-deconvert.sh --abandon` — it removes this node's etcd
  container and volume (a conversion starts etcd beside the standalone, long before it
  stops anything), takes the cluster lines out of `.env` (keeping a `.env.bak-<time>`),
  sets the manifest aside, and tells you to `./taranac up -d`. It refuses on a member
  (`TARANAC_HA=1`) and when **Patroni has already run on this data** — a conversion by an
  earlier version that failed after the adoption; the refusal prints the way forward and
  the way back ([§8](#8-troubleshooting)). `add-witness` itself starts this node's
  standalone stack, as it was, when a stopped conversion left it down.
- `up`/`restart` when `NODE_ADDRESS` in `.env` is not an address of this host (a copied
  `.env`, a cloned VM, a changed IP), or when another machine already runs in the
  cluster under this node's name. If the host's address changed, give it its old one
  back. To really move a member, take it out and add it again
  (`./taranac cluster remove-node --node <name>`, then `./taranac cluster add-node
  --address <new address>`; switch the leader over first). A node reached through NAT
  carries `ADDRESS_NOT_LOCAL_OK=1` in its `.env`: `cluster init`, `ha-join.sh` and
  `witness-join.sh` write it when they accept such an address, and `./taranac update`
  writes it for a node that already runs that way. A hostname that resolves only to
  loopback (`127.0.1.1` in `/etc/hosts`) is not taken for a mismatch.
- `up`/`restart` when `TARANAC_VERSION` in `.env` was edited by hand to another
  version than the bundle's — use `./taranac update --version <version>`.
- `up`/`restart` on a replica waiting for the leader's schema — its finisher starts the
  rest by itself; update the leader next. (Naming `postgres` or `etcd`, and anything on
  the leader, is never refused.)
- `up`/`restart` on a `.env` with the HA lines removed while the host still holds the
  member's etcd state — put the lines back, or take the node out properly.

`./taranac down` on the leader goes ahead, and says first that it is the leader and
that `./taranac cluster switchover` hands leadership over without a failover.

**One topology change at a time.** `add-node`, `add-witness`, `remove-node`,
`remove-witness` and `ha-deconvert.sh` take the same cluster-wide lock in etcd as
`./taranac update` — and so does `cluster rotate-ca` while it runs. A second one — on
any node, or during a node's update — is refused with the name of the node and the
command that holds it.

### Check status

```bash
./taranac cluster status     # nodes, roles, replication lag + WAL bytes behind, etcd certificate dates
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
on the seed — or any DB node that holds the etcd CA, if the seed is gone
([§3.7](#37-which-command-runs-on-which-machine)) — within your license's
`max_nodes`. The preflight consults every existing member first, so a node is never
added to a cluster that has quietly drifted.

To rebuild a machine that is **already** a member — it died, it was replaced, a join
never finished — the same command with `--reinstall` evicts it and adds it again from
scratch. It is refused for the current leader, and requires the flag while the node
is still streaming. See
[Re-adding a node that is already a member](#re-adding-a-node-that-is-already-a-member).

### Bring a node back up to date

Since write routing follows the replicated roster, a node does not need this after a
join: every member picks a new node up by itself, and each node's `./taranac update`
rewrites its bootstrap lists (`DB_HOSTS`, `ETCD_HOSTS`, `ETCD_INITIAL_CLUSTER`) from
the roster and the live ring right before its planned restart. `cluster sync` remains
the explicit "do it now" for one node:

```bash
./taranac cluster sync
```

It works out what the cluster actually looks like — the node list from the
**replicated roster**, the etcd endpoints **and the declared ring** from the **live
ring** — shows you each value it would change, asks once, and writes **only this
machine's** `.env` (and takes the cluster's `config/cluster.yml`, keeping this
machine's as a `.bak` if it differed). It recreates **no** container: these values are read at
the next start, and recreating `postgres` on the leader is a failover.

> **Why it does not simply copy the primary's values.** Leadership moves. A node that
> joined early, never learned about a member added later, and then won a failover
> would become "the primary" — and copying *its* shorter list onto everyone else would
> erase a node that really exists. That is not hypothetical: it is why the command
> derives the answer from the roster and the ring, which are the same on every node,
> instead of trusting whichever machine happens to lead right now.

### Raise the connection ceiling

`./taranac cluster verify` ([§3.6](#36-verify)) tells you whether this applies to
you. If it does not, skip this — a cluster built on a recent version already has
what it needs.

**Why it is not simply raised for you.** Under HA every node's **writes** route to
the one primary, so the primary carries the write side of the whole cluster on top
of its own local reads. That needs `max_connections = 300`. New clusters get it
from the bundled Patroni configuration — but that configuration is *bootstrap*
config, which Patroni applies **only when a cluster is first built**, and
`max_connections` is one of the parameters Patroni accepts **only** from the DCS,
so a local override is ignored. An existing cluster therefore keeps Postgres' own
default of 100 until somebody raises it deliberately, and upgrading does not do it.

On 100 the ceiling is reached by three nodes' api pools alone. What that looks like
when it happens: the daemons answer authentications with an error, a plain local
`psql` is refused with `FATAL: sorry, too many clients already` — and
`cluster status` goes on printing *Healthy* throughout, because nothing about
replication is wrong.

> ⚠️ `superuser_reserved_connections` does **not** protect you here. In the shipped
> product the application role *is* the Postgres superuser, so when the application
> exhausts the ceiling you cannot get a `psql` in either.

**The procedure. Replicas first, the leader last** — a standby whose
`max_connections` is below the primary's cannot start hot standby and **stops
replaying**, so raising the leader first breaks replication until you catch up.

```bash
# 1 — raise it once, cluster-wide. On ANY DB node:
docker exec taranac-db patronictl -c /tmp/patroni.yml edit-config --force -p max_connections=300

# 2 — see who is now waiting for a restart: the members that need one are marked
#     "Pending restart". Patroni flags the REPLICAS and leaves the leader unflagged
#     until they are done, so this tells you the order too:
docker exec taranac-db patronictl -c /tmp/patroni.yml list

# 3 — restart every REPLICA, one at a time:
docker exec taranac-db patronictl -c /tmp/patroni.yml restart <cluster> <replica> --force

# 4 — and only then the leader:
docker exec taranac-db patronictl -c /tmp/patroni.yml restart <cluster> <leader> --force
```

Each restart is a few seconds of that node's Postgres; **authentication keeps
serving throughout** from the daemons' caches.

Re-run `./taranac cluster verify` when you are done. It asks each node what it is
**running** with — not what the configuration says, which already reads 300 the
moment step 1 finishes — so it is useful *during* the procedure as well as before
it: it names the nodes still to go and repeats the order.

> ⚠️ If `verify` ever reports a **replica running below the primary**, restart that
> replica now. That is not a half-finished upgrade — that standby has stopped
> replaying.

### Keep etcd's store from growing without bound

etcd keeps **every revision it has ever written** unless it is told not to, and
nothing tells it by default. Patroni writes to etcd constantly, so on a default
configuration the store grows forever — about 13 MB a day at the write rate we
measure. That is not a scaling problem that arrives politely: one customer's ring
reached **127 MB**, at which point `fsync` had become slow enough to lose
elections, and their leader was demoting itself and re-promoting every few minutes.

**New clusters need nothing here.** Both compose files that start an etcd —
`docker-compose.ha.yml` on a DB node and `docker-compose.witness.yml` on the
witness — ask it to compact (`ETCD_AUTO_COMPACTION_MODE=revision`,
`ETCD_AUTO_COMPACTION_RETENTION=1000`, roughly half an hour of history). Under a
genuinely busy cluster that holds the store around **half a megabyte**.

This section is for three other cases: a cluster **older than that setting**, a
cluster whose **leader keeps flapping**, and a store that has **already grown** and
whose disk you want back.

**Check what each member is actually carrying.** Ask every machine separately:

```bash
docker exec taranac-etcd         etcdctl endpoint status -w table   # on each DB node
docker exec taranac-witness-etcd etcdctl endpoint status -w table   # on the witness
```

> 🔑 **Ask each machine for its own size — not the ring.** For `endpoint status`
> and `defrag`, the `--cluster` form answers for members it has not really
> measured, so a ring where one machine is still carrying the whole history looks
> uniform. (`endpoint health --cluster` is a different question and is fine — that
> is the quorum check used everywhere else in this runbook.)

**Step 1 — make sure the setting is present.** `./taranac update` refreshes the
compose files (it replaces every bundle file that is not `.env` or `config/`), so
the setting arrives with any update. It only takes effect when that member's etcd
is **recreated**, which the update does not do on its own:

```bash
./taranac up -d --force-recreate --no-deps etcd
```

Recreating an etcd member is a **quorum event**. Do it **one machine at a time**,
waiting for the ring to be healthy again in between
(`docker exec taranac-etcd etcdctl endpoint health --cluster`), and never at the
same time as anything else that removes a vote.

**Step 2 — throw the old history away.** Compaction only bounds *new* growth; the
history already written is still there. Discard it **once, from any one member** —
it is a cluster-wide operation:

```bash
# read the current revision — the `fields` form is the one that prints it
docker exec taranac-etcd etcdctl endpoint status --write-out=fields | grep Revision

# then discard everything older
docker exec taranac-etcd etcdctl compact <that revision>
```

**Step 3 — give the disk back, on every machine separately.** Compaction frees
space *inside* etcd's file; it does not shrink the file. Defragmentation does, and
it must be run **locally on each machine, including the witness**:

```bash
docker exec taranac-etcd         etcdctl defrag    # on EVERY DB node, one at a time
docker exec taranac-witness-etcd etcdctl defrag    # and on the witness
```

> ⚠️ **Do not use `etcdctl defrag --cluster`.** It reports success for members that
> did not shrink at all — you get a clean-looking result and a ring where some
> machines are still carrying the whole history. This was found on our own stand,
> and it is why every command above is addressed at one container on one machine.
> Defragmentation briefly blocks that member, so keep to one machine at a time here
> as well.

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

Then it removes the node from the cluster manifest and **publishes it first** — if
that cannot be done, it stops with nothing changed — and only then removes the etcd
member, decommissions the roster row and prunes the node from this node's `.env`
topology. Given the **witness's** name or address, it hands over to
`remove-witness` (below): which machine that is, is asked of the live etcd ring.
Without a terminal it needs `--yes`.

> Both safety questions are answered from the **running** cluster — the live etcd
> member list and Patroni's own view of who leads — never from this node's `.env`,
> which is exactly the thing that can be out of date.

> **You do NOT repeat this on the other nodes.** Membership is in etcd, write
> routing follows the replicated roster and the manifest was published — each
> changed once, cluster-wide. (This is the one thing the
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

> 🔑 **Either way, the machine still holds the cluster's etcd CA key** (`config/etcd-ca/ca.key`),
> and so do its backups. `remove-node` and `detach` both end by saying so. Unless the
> machine and its backups are wiped, replace the CA afterwards — on a database node of the
> cluster: `./taranac cluster rotate-ca` ([Replacing the etcd CA](#replacing-the-etcd-ca)).

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

### Remove the witness

A cluster of **three or more database nodes** does not need its witness: three
database voters keep a majority through any single loss on their own. On **any
database node**:

```bash
./taranac cluster remove-witness          # add --yes when there is no terminal
```

It reads the **live etcd ring** to find the witness — the member with no row in the
node roster — and refuses while the cluster still needs it:

- **two database nodes** — `a 2-node cluster needs its witness: add a third database
  node first (./taranac cluster add-node --address …)`;
- **one database node** — the witness is half its quorum; to go back to a single
  server, use `./ha-deconvert.sh` instead (next section);
- **a member is down** — the voters left must still hold a majority, or the ring
  could not elect a leader.

Then it removes the witness from `config/cluster.yml` and **publishes it first**,
removes the witness from the ring, records the departure for the leader, and drops
the witness from this node's `ETCD_HOSTS` / `ETCD_INITIAL_CLUSTER`. **No container
is restarted.** Running it again is safe: it finds the witness gone and only cleans
a manifest entry if one was left.

**On the witness host** — the one command the run ends with:

```bash
./witness-join.sh --leave
```

It asks a database node's etcd whether this host is still in the ring and refuses
if it is. Otherwise it takes the witness etcd down **with its state**
(`docker compose down -v`), deletes this host's etcd certificate and key, and keeps
`.env` as `.env.left-<time>`. It also deletes the one cluster secret a witness holds,
the etcd CA key (`config/etcd-ca/`), so nothing else is left on it; `./taranac update`
there then says the host has left. `remove-witness` ends by saying that: if `--leave`
cannot run there, or the machine may have been copied, [replace the CA](#replacing-the-etcd-ca).
If no database node answers from that host (the cluster is gone, or unreachable for
good), it refuses unless you confirm it:
`./witness-join.sh --leave --confirm NOT-A-MEMBER`.

If the witness was **already down** when it was removed, the run says there is
nothing to do on that host. If it was running, its etcd keeps restarting and being
turned away until `--leave` runs there: no vote, no risk to the cluster, but the
leader reports it — the `cluster:departed_witness_running` alert and a line in
`cluster status` — until `--leave` runs. If that machine is gone for good and will
never run it, let it go from any database node:

```bash
./taranac cluster remove-witness --forget <address>
```

> Removing the witness by hand with `etcdctl member remove` leaves the manifest and
> every node's bootstrap lists naming it. Run `remove-witness` afterwards anyway: it
> cleans what is left.

### Replacing the etcd CA

```bash
./taranac cluster rotate-ca          # asks once, [y/N]
./taranac cluster rotate-ca --yes    # the same, without the question (needed without a terminal)
```

Every member trusts one CA (`config/etcd-tls/ca.crt`) and holds its key
(`config/etcd-ca/ca.key`). This command makes a new CA and moves every member onto it —
the database nodes and the witness — re-issuing each member's certificate on the key it
already has. **Nothing is restarted**: etcd, Patroni and the api take the new files on
their next connection, and the cluster serves throughout.

**When to run it:**

- after `remove-node`, `remove-witness` or `detach` of a machine that was **not wiped** —
  it took a copy of the CA key along, and so did its backups (each of those commands ends
  by saying so);
- when the key may have leaked — a lost disk, a backup archive in the wrong hands (read
  *what it protects against* below first);
- before the CA ends. It lives ten years; `cluster:etcd_ca_expiring` opens **180 days**
  ahead ([§14](#14-alert-reference)). Once it has expired this command can no longer help —
  see [expired etcd CA](#expired-etcd-ca).

**Where:** on any member. A database node is the better choice — that is where
`./taranac cluster status` shows the result — but it runs in the host's `etcd-agent`
container, so it works on the witness too.

**Before you start:** every member must be up and answering, and every member must run
**1.3.3 or newer — the same release** (finish a rolling update first). The command asks
every member's agent before it changes anything; a member that does not answer, or
runs another release, is named with what to do there, and nothing is changed. A member
that is gone for good is taken out first (`./taranac cluster remove-node --node <name>`,
or `./taranac cluster remove-witness`): a rotation never skips a member.

**What you see.** The plan — the current CA, the members, the steps — and one question.
Then a table (MEMBER / KIND / STEP / STATUS) through four steps, one member at a time,
**the witness first**:

1. **trust** — the member receives the new CA, its key encrypted to that member's own
   certificate, and trusts both CAs;
2. **serve** — the member's certificate is re-issued from the new CA, and the command
   checks with a TLS handshake that the member really serves it;
3. **settle** — the new CA becomes the member's only one; the old CA and its key are
   deleted from it. The first settle is the **point of no return**: before it every member
   still trusts the old CA, after it the only way is forward. Every member is checked once
   more right before it;
4. **verify** — every member's files, and what each one serves.

It ends with `✓ etcd CA rotated: <old> → <new> (until …)` and `Nothing was restarted.`
Backups taken from then on carry the new CA. Exit code 0: done; 1: refused, nothing
changed; 3: stopped part way. `--timeout <seconds>` waits longer for each member's answer
at each step (default 90) — for a witness behind a slow link.

**If it stops part way**, it says what stopped it, where that leaves the cluster, and what
to do. The cluster works in every state a rotation passes through: before the point of no
return every member trusts both CAs, after it every member already serves a certificate
from the new one. Fix what it names — usually a member to bring back (on that host
`./taranac up -d --no-deps etcd-agent`; `./taranac logs etcd-agent` says why it stopped) or
to take out of the cluster — then run **the same command again**. A re-run first puts every
member back on one CA, and reads the direction from the members' own files, never from a
guess:

- stopped **before** the point of no return → the attempt is **undone**: every member is
  back on the old CA, the new CA and its key are deleted everywhere, and a fresh rotation
  follows in the same run;
- stopped **after** it → the attempt is **finished**: `The rotation is complete.` No second
  rotation follows.

There is no "resume", "abort" or "skip a member" — running it again is all three.

**What else waits for it.**

- While it runs it holds the cluster lock: `./taranac update`, `add-node`, `add-witness`,
  `remove-node`, `remove-witness` and `renew-cert --all` refuse with `its 'rotate-ca'
  started at …`. A run that died frees the lock within two minutes.
- After a run that stopped, until a re-run completes it: `add-node` and `add-witness`
  refuse — a node joined then would be handed one of the two CAs and could not verify the
  members on the other. `remove-node` and `remove-witness` are allowed (a dead member must
  be removable, or the rotation could never finish), and `./taranac update` only warns: it
  changes no CA file, and an update is how a fixed etcd agent would arrive.
- `./taranac cluster status` lists each CA as `in use` or `not in use`, and an unfinished
  rotation as `⚠  etcd CA rotation unfinished (started by … at …)` (`… in progress` while
  one runs). `./taranac diagnose --ha` reports it as `[CA ROTATION]`.

**What it protects against — and what it does not.** A rotation makes the old key
worthless to whoever holds it **offline**: a removed machine that was not wiped, a stolen
disk, an old backup archive. That holder is no member, receives nothing, and once the
rotation completes the key it holds signs certificates no member trusts. It does **not**
protect against someone who holds the old key **and reaches the cluster's etcd (2379)
while the rotation runs**: with that key they can pass for a member and be handed the new
one. If a machine you no longer control may still be on the interconnect, take it out
(`remove-node` / `remove-witness`), shut it out at the firewall ([§7](#7-security--you-must-do-this)),
and only then rotate. And the CA key protects etcd alone: a database node also held
`MASTER_KEY`, the database passwords and a full copy of the data, and replacing the CA
changes none of those.

**Restoring an archive taken before a rotation.** It carries the old CA. A restore
does not put it back over the one the cluster runs on: it keeps `config/etcd-ca`
as it is, sets the archive's copy aside in `config/etcd-ca.restored-<time>`, and says so.
That directory holds a CA private key — once you are sure the restore went to the right
cluster, delete it (`rm -rf config/etcd-ca.restored-<time>`).

### Shrink back to a single node (remove HA)

To go all the way back to a plain standalone install — on the **surviving primary,
after** the other nodes are removed and torn down:

```bash
./ha-deconvert.sh          # back up first; add --yes to skip the prompt
```

It stops the HA overlay, strips the HA markers from `.env`, brings the stack up on
the base compose so the standalone Postgres image **adopts the data dir in place**
(the reverse of the convert), drops the orphan replication slots, and removes the
orphan etcd volume. It **refuses** to run on a replica, and while the **live etcd
ring or the node roster** still has another database node — a stopped replica too:
when it came back it found the witness, held two votes of three and promoted itself
next to this node (split-brain). The refusal lists each such node with its
`./taranac cluster remove-node --node <name>`. The witness may stay. If the ring or
the roster cannot be read at all, it refuses unless you state that every other
machine is gone: `./ha-deconvert.sh --confirm NO-OTHER-NODES`.

**The last survivor of a cluster whose other machines are gone for good** is a special
case: with no quorum left Patroni has demoted it, so it does not look like the primary
and the shrink refuses that too. On that machine the whole command is:

```bash
./ha-deconvert.sh --force --confirm NO-OTHER-NODES
```

`--force` only gets past "not the primary"; it never skips the check for other
database nodes — only `--confirm NO-OTHER-NODES` stands in for that, and only when
the ring or the roster cannot be read.

Afterwards the witness host is no longer needed; the ring it belonged to is gone, so
on that host confirm it explicitly: `./witness-join.sh --leave --confirm NOT-A-MEMBER`.

---

## 6. Upgrades under HA

**Docker Engine 28.0 or newer on every database node before you update the first one**
(the witness runs no stack network, so its Docker is not checked). Check each with `docker version --format '{{.Server.Version}}'`. The update
checks it on each database node and refuses there with nothing changed, but by then the
members updated before it run the new release, and the rollout stops half-way until that
node's Docker is updated.

Keep **every node on the same image version**. Take a backup from the in-app Backup &
Recovery tools first, then run `./taranac update` on one machine at a time, in this
order: **every replica, then the leader, then the witness.** Schema migrations run once,
on the leader, automatically.

You do not have to work the order out yourself. Run `./taranac update` on any member:

- **If it is the right machine,** it updates it.
- **If it is not,** it refuses **before it writes anything** — no backup, no file swap,
  no version pin, no download — and tells you where to go:
  `This is a cluster … Start here: node-2 (10.0.0.2) → ./taranac update --version 1.3.2`.

Every command it prints for the next machine names the version this rollout is going
to. Copy it as printed: a bare `./taranac update` means "the latest stable release",
which is not the same thing when you are installing a release candidate or a pinned
version.

Every run — an update, a refusal, or "already on this version" — ends with the same
table of the whole cluster: each member's role, the version it recorded, its state, and
which one is next.

```
Next: update the leader now: node-1 (10.0.0.1) → ./taranac update --version 1.3.2

  NODE      ROLE            VERSION   STATE            NEXT
  node-1    leader          1.3.1*    reported         ← update now
  node-2    replica (this)  1.3.2     awaiting-schema  finishes by itself once its api is healthy
  witness   witness         ?         no record        waits
```

**Where the answer comes from.** Each node's updater records the version it reached in
etcd, under `/taranac/update/members/<etcd member name>`, at the end of its own run. The
order is recomputed on every run from those records, the etcd member list, the cluster
manifest (`config/cluster.yml`, which says which member is the witness) and Patroni's
current leader — so a failover in the middle of an upgrade simply changes which node is
"next". A node that has not been updated since 1.3.x has no record yet; for it, the
version its api last reported is used if that report is fresh, and the table marks it
with `*`.

**What you see on a replica (and on the leader).** The node recreates every container on
the new images, starts the api and the database first, and waits up to two minutes for
the api:

- If the api is healthy in that time (a release without a schema change, or the leader,
  which migrates it), the rest of the stack starts and the node is **updated**.
- Otherwise the node is **awaiting-schema**: its api waits for the leader to migrate the
  schema. The update still finishes in a couple of minutes, and says plainly what that
  means: **AAA (tacacs/radius/nac) and the UI on this node are down until the leader is
  updated** — so update the leader next, right away. A small helper container,
  `taranac-update-finisher`, stays behind: as soon as the api is healthy it starts the
  services that are not running yet, records **updated** and removes itself. It never
  restarts or recreates a running container, and never starts, restarts or recreates the
  etcd, database or api containers (those are the updater's and their restart policy's) —
  so finishers on several replicas can never take etcd voters down together. You do not
  run anything a second time. It survives your logout and, with its `unless-stopped`
  restart policy, a reboot of the host; if it cannot finish within 24 hours (counted
  from its first start, not reset by a reboot) it records **failed** with the reason,
  which every member's table then shows. Its trail is `.taranac-update.log` in the
  bundle directory.

The finisher holds the Docker socket (the same access the updater itself has) and the
bundle directory, has no network, and nothing else. Its image travels with the release and is verified
against `IMAGES.lock` with the rest.

The finisher never overrides you. Before each step it re-reads the bundle's `VERSION`
and `.env`; if you rolled the node back (the previous bundle files from
`.taranac-backup-*`, the previous `TARANAC_VERSION`, `./taranac up -d`), or the node is no
longer configured for HA, it stops without starting anything and without writing to
etcd, and says why in `.taranac-update.log`. `./taranac down`, `./taranac cluster detach`
and `ha-deconvert.sh` remove a pending finisher first and say so.

**One update at a time, cluster-wide.** Before it changes anything, a run takes the
cluster's single update slot in etcd, in one atomic step — two members started in the
same second cannot both get it. A run on any other member is refused with nothing
changed, names the node being updated, and prints the command to run once that run has
ended; `--allow-out-of-order` does not skip this. The slot is freed when the run ends,
however it ends, and a run that died (a reboot, `kill -9`) frees it by itself within two
minutes.

**Running it again is safe.** On a node already on the version, `./taranac update
--version <it>` (or `--from` the same bundle) makes no backup, swaps no files and
prints `Already on <version> — nothing to do` with the table — unless a container
there is stopped or only Created: then it starts exactly those (under the same
cluster slot), recreates nothing, and shows the table. On a node still awaiting its
schema it makes sure the finisher is running (and starts it again if the host was
rebooted before its restart policy brought it back) instead of starting anything
itself. A witness whose record already says it is on the version is a no-op too.

**Downgrades.** `./taranac update --version <older>` on a cluster member asks you to type
`DOWNGRADE`. If the newer release migrated the schema, the older api cannot start on it
and waits (the finisher gives up after 24 hours) with AAA and the UI down on that node;
the schema is never migrated backwards. Downgrade only to a release with the same
schema; otherwise restore the backup taken before the update.

**The leader** is accepted as soon as every replica is on the new version, including
replicas that are still awaiting their schema — that is the normal state at that point.
Recreating the leader's database container triggers a failover, which is why it goes
after the replicas.

**The witness** goes last, see below. It waits for the database nodes' finishers (with
progress, up to 15 minutes) and refuses, naming the node and the reason, if one of them
failed or its finisher stopped reporting.

**When etcd cannot answer** — no quorum, or Patroni in the middle of a leader election
for longer than half a minute — the update refuses with that reason and changes nothing;
`./taranac diagnose` shows what is wrong with the ring.

**`--allow-out-of-order`** is for repairs only, never for a normal upgrade. It asks you
to type `OUT-OF-ORDER` (without a terminal: add `--confirm OUT-OF-ORDER`), then turns an
order refusal into one warning line, writes `override=1` into this node's record (shown
as `!` in the table) and appends a line to `.taranac-update.log` in the bundle
directory.

**A plain `./taranac update` in the middle of a rollout** to a release candidate (or to
any version newer than the latest stable release) is refused: it would aim this node at
the older stable release. The refusal names the rollout's version and the command that
continues it, `./taranac update --version <that version>`.

**`-y` only answers the prompt.** On a node already on the target the update does
nothing; to re-apply the current version anyway (a new backup, the files swapped, the
stack recreated) use `./taranac update --version <current> --repair`.

**Offline: `--from` takes the version from the bundle.** `./taranac update --from
<file>` installs whatever the bundle's own `VERSION` file says, whatever the file is
called — a renamed copy (`/tmp/fix.tar.gz`) never makes it look for a tag named after
the file. A `--version` that disagrees with the bundle is ignored with a warning. The
cluster order and the slot apply exactly as online.

Each node pulls and verifies its images before it writes anything, so a node whose pull
fails stays entirely on the old version and simply re-runs `./taranac update`. An update
that changes the etcd image also recreates that node's etcd member briefly — harmless one
node at a time, which is one more reason the order is enforced.

### Upgrading the WITNESS

Run `./taranac update` on the witness **last**, after every database node. It knows the
host is an arbiter: it refreshes the witness's own tooling (`witness-join.sh`, the witness
compose file, `diagnose.sh`, this runbook) and starts no Taranac container.

Before it changes anything it checks that every database node finished its update
(waiting, with progress, for a finisher that is still working). It refuses — with
nothing changed — while a database node is not on the new version, has failed, or has
a finisher that stopped reporting; the message names the node and what to do there.

Of the witness `.env` it writes **exactly one line**, `TARANAC_VERSION=<version>`, in
place (same file, same owner and mode); nothing else in that file is read or changed.
That line is what makes a second run a no-op and lets the cluster table show the
witness's version. New witnesses get it from `witness-join.sh` when they join.

Since 1.3.3 the witness also runs the `etcd-agent` (it renews the witness's etcd
certificate, §4.2) — the one Taranac image a witness runs. The update pulls it at the
new version, checks it against the release's `IMAGES.lock` like a database node's
images, and recreates **only that container** (`--no-deps`); etcd is recreated only when
the release changes etcd's own definition (its compose config hash), and then only on a
healthy ring. It comes
from `ghcr.io/taranaclabs/taranac/etcd-agent:<version>`. An **air-gapped** witness
names its mirror in `.env` — one more line, `ETCD_AGENT_IMAGE_PREFIX=<registry>/<path>`, the
same kind of value as a database node's `IMAGE_PREFIX`; the tag follows the version by itself,
so later updates need no edit — copied there with a digest-preserving tool (`docker buildx imagetools create`, `skopeo copy
--all`, `crane copy`), or the check refuses it.

If a release changes `docker-compose.witness.yml`, the update **applies it itself** —
only after `etcdctl endpoint health --cluster` shows the ring healthy (otherwise it
refuses before writing anything), and only on the witness, which by then is the one
member left to update, so the arbiter's vote is never lost together with a database node.
It then waits for the witness etcd to be healthy again.

The wrapper is witness-aware everywhere else too: `./taranac ps` and `./taranac logs
-f etcd` drive the **witness** stack, and any command that needs the database or the
API (`cluster …`, `unlock`, `reset-password`, …) says it belongs on a DB node instead
of failing with a wall of "variable is not set". The two exceptions run in the
witness's own `etcd-agent`: `cluster renew-cert` and `cluster rotate-ca`.

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
- **Let each database node's own Docker network reach that node's own address on
  `2379` and `8008`.** Two things on a node dial its own LAN address from inside a
  container: the api and Patroni reach etcd through `ETCD_HOSTS`, this node's
  `2379` included; and Patroni asks its **own** REST API at its `api_url`
  (`<this node>:8008`) whenever a switchover names this node as the candidate —
  `api_url` is the address the other nodes use, so it cannot be pointed anywhere
  else. That traffic comes from the node's Docker network, `taranac_default`, whose
  containers `docker-compose.yml` addresses from **`10.255.255.240/28`** — not from the LAN. A host
  firewall that admits only the LAN cuts the node off from its own etcd on `2379`;
  on `8008` it makes Patroni refuse the node as a candidate (`no good candidates
  have been found`), so leadership can be handed away from it but never back.
  One rule per database node covers both — with ufw:

  ```bash
  sudo ufw allow proto tcp from 10.255.255.240/28 to <this node's address> port 2379,8008
  ```

  Its own database is reached over the container network and needs no such rule.
  `cluster init` / `add-witness`, `ha-join.sh` and `./taranac diagnose --ha` test
  both ports from the Docker network and print this rule, with the address filled in.
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
- **IPv6 does not change these rules.** The cluster ports (`5432`, `8008`, `2379`) belong
  to containers kept off IPv6, so IPv6 to them still passes the host's INPUT chain and
  ufw. Only the user- and device-facing ports are forwarded into their containers for
  IPv6 and bypass INPUT — filter those in `DOCKER-USER` ([INSTALL.md
  §1](INSTALL.md#ipv6-on-the-host)).

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
private key (`config/etcd-ca/ca.key`) is **held by every member, the witness
included**: the join delivers it wrapped, and it is included in the backup archive of
every database node, so losing one machine can never leave you unable to add or
replace a node ([§4.2](#42-certificates-a-request-not-a-copy)). It reaches **no etcd,
Patroni or daemon container**; two read it — the backup (the api sees `./config`
read-only for exactly that purpose) and, since 1.3.3, the member's own `etcd-agent`,
which renews that member's certificate with it. The agent opens no port, has no
Docker socket and gets none of `.env` but this member's etcd name, client scheme and
version. Protect every node **and the witness** accordingly, and keep your backups as
safe as you keep `MASTER_KEY`. Whoever holds the CA key can mint a certificate the
cluster's clients trust — and anyone who can reach 2379 can already write to etcd,
which is why the firewall above is not optional. When a copy of the key leaves with a
machine, or the CA nears its end, replace it:
[Replacing the etcd CA](#replacing-the-etcd-ca).

> 🔑 **The archive can only carry what the api can read.** `ca.key` is created 0600
> under the installing operator's account, and the api runs as uid/gid 999 — so the
> tooling grants group 999 read on `config/tls`, `config/firebase` and
> `config/etcd-ca` at the moment it writes them (`env-secrets.sh::secure_host_dir`,
> called by `install.sh`, `taranac-update.sh`, `ha-etcd-ca.sh` and `ha-join.sh`).
> Before 1.2.8 nothing did, and `config/etcd-ca` reached no archive on any install
> — reported by a customer, and the reason the backup now names every file it could
> not read instead of skipping it quietly. If you ever restore these files by hand,
> or copy them between machines with `sudo`, run `./install.sh --no-start` (it re-applies
> the permissions, starts nothing and changes nothing else) or run
> `sudo chgrp -R 999 config/etcd-ca && sudo chmod -R g+rX config/etcd-ca`.

Each member's own certificate is obtained by the request-and-sign flow in
[§4.2](#42-certificates-a-request-not-a-copy) — nothing is copied between machines.

Flipping the etcd scheme on a **running** cluster breaks the ring; that is a
planned maintenance-window migration, never a blind edit and `up -d`. The two
procedures are below.

#### Changing the etcd TLS scheme on a LIVE cluster

Only in a maintenance window. Throughout either procedure the **data plane keeps
serving auth**; what pauses is the control plane — config writes, daemon config
reloads and automatic failover.

**The peer channel (`2380`) — `http` ⇄ `https`.** The peer transport **cannot be
mixed**, so this is not a rolling change. Two ways:

*Option A — coordinated restart.* Preserves the DCS state and PGDATA; recommended
when you want the cluster's history kept.

1. Announce the window. Confirm `2379`/`2380` are firewalled to the private
   interconnect.
2. On **every DB node and the witness**, edit `.env`: `ETCD_PEER_SCHEME=https`,
   `ETCD_PEER_AUTO_TLS=true`, and rewrite **every** peer URL in
   `ETCD_INITIAL_CLUSTER` to `https://`.
3. Persist the new peer URLs into the DCS so restarted members advertise `https`.
   On any node, once per member (`etcdctl member list` gives the IDs):
   ```bash
   docker exec taranac-etcd etcdctl member update <memberID> \
       --peer-urls=https://<that member's address>:2380
   ```
4. Restart etcd on **all** members within the same brief window — the ring only
   re-forms once every member is `https`. On each DB node
   `./taranac up -d --force-recreate --no-deps etcd`; on the witness the same
   through `docker-compose.witness.yml`.
5. Verify: `docker exec taranac-etcd etcdctl endpoint health --cluster`, then
   `./taranac cluster status` shows one primary and healthy replicas.

Reverse the same steps with `http` / `false` to roll back.

*Option B — fresh DCS bootstrap.* Simplest, and **your Postgres data is untouched**:
etcd holds only ephemeral coordination state — the database lives in the `pg_data`
volume, never in etcd — and Patroni re-creates its DCS keys on start. Window and
firewall check as above; set the same knobs plus `ETCD_INITIAL_CLUSTER_STATE=new`
everywhere; `./taranac down` and remove **only the etcd volume** (never `pg_data`);
then bring the cluster back up in bootstrap order — **witness first, then node-1,
then the rest**. Each Postgres adopts its existing data directory in place.

**The client channel (`2379`) — `http` ⇄ `https`.** Gentler: etcd can listen on
both at once, so a real one-node-at-a-time cutover exists.

1. Window and firewall check. Provision `config/etcd-tls/` (the CA plus a per-node
   leaf) on **every** node and the witness first — it is inert until referenced.
2. Add an `https` client listener **alongside** `http` on every etcd member.
3. One node at a time, flip that node's **clients** to `https`: set
   `ETCD_CLIENT_SCHEME=https` and the certificate-path knobs in its `.env`, then
   recreate `etcd` and `postgres` on that node. Patroni reconnects over `https`;
   that node's control plane blips only briefly.
4. Once every client is `https`, drop the `http` listener and verify
   `endpoint health` over `https` on every endpoint.

> If you are at all unsure, **Option B is the one to take**. It is the least
> error-prone path, and the data plane is untouched either way.

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
   **never as a replicated DB row**. Seven values are cluster-wide; a wrong or missing one is silent
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

5. **`POSTGRES_REPLICATION_PASSWORD` in `.env` is not what the `replicator` role was
   created with — and nothing keeps them in step.** The role is created once, when the
   node's database is first initialised, with the value `.env` held then. Patroni adopts
   that data directory as it is; restoring an older `.env`, or editing the value, changes
   only the file. Every replica clones with the `.env` value, so a mismatch shows up as a
   clone looping on `password authentication failed for user "replicator"`. `cluster
   init` and `add-witness` now log in with it before anything changes, and `ha-join.sh`
   does the same against the leader before it touches its own node. To bring the role in
   line with `.env` (it prompts; the password goes on no command line), on the node that
   holds the database — the leader, once converted:

   ```bash
   docker exec -it taranac-db psql -U taranac -c '\password replicator'
   ```

   and enter the value of `POSTGRES_REPLICATION_PASSWORD` from `.env`. If the role does not
   exist at all, create it first:
   `docker exec -it taranac-db psql -U taranac -c 'CREATE ROLE replicator REPLICATION LOGIN'`.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **`cluster init` refuses: "already an HA node"** | `TARANAC_HA=1` is set — this node is already converted. Grow the cluster with `add-node`, or inspect it with `cluster status`. |
| **`cluster init` refuses: no `taranac_pg_data`** | The wizard converts an installed, populated node. Install and start this node first (`./install.sh`), then re-run. |
| **`cluster init` refuses: `POSTGRES_REPLICATION_PASSWORD` not set** | That value was baked into the `replicator` role when this node's database was initialised. The wizard will not mint a new one (the role's password would not change with it, and every join would then fail authentication silently). Restore it into `.env` — or choose a new value, put it in `.env`, and give the role the same one: `docker exec -it taranac-db psql -U taranac -c '\password replicator'` (it prompts; [§7a](#7a-durable-gotchas--the-ones-that-bite-silently) item 5). |
| **`cluster init` / `add-witness` refuses: "replicator could not log in to this node's database (auth)"** | The `replicator` role's password is not `POSTGRES_REPLICATION_PASSWORD` from `.env` (or the role is missing). Nothing was converted. Set it as printed — `docker exec -it taranac-db psql -U taranac -c '\password replicator'` and enter the `.env` value ([§7a](#7a-durable-gotchas--the-ones-that-bite-silently) item 5) — then re-run. |
| **… refuses with "(nologin)"** | The role exists but cannot replicate or log in. `docker exec -it taranac-db psql -U taranac -c 'ALTER ROLE replicator REPLICATION LOGIN'`, then re-run. |
| **… refuses: "this node's database (taranac-db) is not running"** | The login check runs from the Docker network the database is on. Start the node — `./taranac up -d` — and re-run. |
| **`add-witness` (`ha-convert.sh --continue`) refuses: "the Docker network cannot reach every etcd member"** | Each finding names the member, the class (`refused`, `timeout`, `filtered`, …) and the cure. When it is **this node's own address** — its etcd on `2379`, or its Patroni on `8008` (`<this node>:8008`, tested through a stand-in listener) — the host firewall drops the Docker network's traffic to it: add the one rule the refusal prints ([§7](#7-security--you-must-do-this): `10.255.255.240/28` to `<this node>` on tcp `2379,8008`). **The standalone stack is still running** — nothing was converted; re-run `./taranac cluster add-witness --address <witness>`. |
| **`ha-join.sh` stops: "this node cannot make every connection the cluster needs"** | Each finding names the connection (the leader's `replicator` login on 5432 or its Patroni on 8008, a ring member's 2379/2380, or this node's own 2379 or 8008 from its Docker network — for those the cure is the one rule of [§7](#7-security--you-must-do-this)), what failed, and the cure: `auth` → set the role's password on the leader as in [§7a](#7a-durable-gotchas--the-ones-that-bite-silently) item 5; `hba` → widen that node's `PG_ALLOW_CIDR`; `refused` / `timeout` / `filtered` → a firewall or route between the two. Nothing on the joining host changed. Fix it, then run `./taranac cluster add-node --address <addr>` on the primary again and use the fresh command. |
| **`cluster switchover --to <node>` (or the rehearsal's hand-back) refused: "switchover is not possible: no good candidates have been found"**, while `<node>` is healthy and streaming | The Patroni the command reached — the one on the node you ran it on — could not ask the candidate for its state at `<node>:8008`. Run on the candidate itself, that is the host firewall dropping its Docker network's traffic to its own address (`docker logs taranac-db` there shows `Request failed to <node>: GET http://<its address>:8008/patroni … connect timeout`). `./taranac diagnose --ha` on that node names it and prints the one rule of [§7](#7-security--you-must-do-this): `sudo ufw allow proto tcp from 10.255.255.240/28 to <its address> port 2379,8008`. Until it is in, the same command run **on the node that leads now** works — that Patroni reaches the candidate over the LAN. |
| **`ha-join.sh` stops: "no declared database node's Patroni answered on 8008"** | The joining node could not learn the members or the leader. Admit it to `8008` on the DB nodes (the finding names each one tried), then re-run `add-node` on the primary. |
| **`ha-join.sh` prints a WARNING for a member that is not the leader** | The join goes ahead (the clone reads from the leader only), but if that member ever becomes leader this node cannot follow it. Fix the connection the warning names before you rely on a failover. |
| **node-1 never becomes primary during `add-witness`** ("this node's database is Patroni's now") | etcd has no quorum. Confirm the witness is up and reachable: `docker exec taranac-etcd etcdctl endpoint health --cluster`, then `./taranac logs --tail 80 postgres`. `TARANAC_HA=1` is already set — the data is Patroni's. Forward: fix the cause, `./taranac up -d`, then `./taranac cluster add-witness --address <witness>` again. Back: `./ha-deconvert.sh --force --confirm NO-OTHER-NODES`, then on the witness `./witness-join.sh --leave --confirm NOT-A-MEMBER`. |
| **`add-witness` stops: "the database is converted and this node is the primary, but services did not become healthy"** | Patroni holds the data and node-1 is the primary; a service (usually one waiting on the api's health) did not start. `./taranac logs --tail 80 api` says why. Forward: fix it, `./taranac up -d`, then `./taranac cluster add-witness --address <witness>` again — with the witness already voting it only verifies and records. Back: `./ha-deconvert.sh`, then on the witness `./witness-join.sh --leave --confirm NOT-A-MEMBER`. |
| **`add-witness` or `--abandon` refuses: "Patroni has already run on this node's data, but TARANAC_HA=1 is missing"** | A conversion by an earlier version failed after Patroni adopted the data (it writes `patroni.dynamic.json` there). Forward: `printf '\nTARANAC_HA=1\n' >> .env`, `./taranac up -d`, then `add-witness` again. Back: the same marker line, `./ha-deconvert.sh --force --confirm NO-OTHER-NODES`, then `--leave` on the witness. The file is dated against `TARANAC_CLUSTER_FORMED_AT`: older is a leftover and is not refused. With no usable `FORMED_AT` the refusal first prints the one command that removes a file you know to be a leftover (`docker run --rm -v taranac_pg_data:/d postgres:16-alpine rm -f /d/patroni.dynamic.json`). |
| **`remove-node` on a database node that did not finish joining** | It is in the etcd ring with no active roster row — to the ring it looks like the witness (a row `add-node --reinstall` decommissioned does not count). `config/cluster.yml` says what it is: declared a database node, it is evicted as one (never handed to `remove-witness`), unless Patroni runs on it. Streaming: finish its join — on it `./taranac up -d`, then `./taranac update --version <v>`, before its token expires (the refusal prints when; after that, `./taranac cluster add-node --address <a> --reinstall` here) — or `./taranac down` on it first. Still cloning: wait for it to stream and run remove-node again, or `./taranac down` on it first. Back on that machine: `./taranac cluster detach --confirm FORK-MY-DATA` before any `./taranac restore`. Declared nowhere, it is refused with the two `./cluster-manifest.py add-witness` / `add-node` lines to declare it. `remove-witness` refuses it the same way. |
| **`ha-join.sh` stops: "the node streams, but its api did not register it"** | The node is a replica the roster cannot name — its api did not start (or not within 90 s). On the node, before the token expires (the message says when): `./taranac up -d`, then `./taranac update --version <v>`. After it has expired: `./taranac cluster join-token --name <n> --address <a>` on the primary, then the same two lines on the node. `add-node` and `diagnose --ha` on the primary print the same finish for such a node. |
| **`ha-join.sh` stops: "its api made its roster row, but consumed no join token of this run"** | The token expired (or was revoked) before the api took it. A new token for the same name and address on the primary (`./taranac cluster join-token --name <n> --address <a>`), then on the node `./taranac restart api` and `./taranac update --version <v>`. |
| **The joining machine cannot read a certificate from the broker** | The broker is **one-shot** and exits when it times out. Re-run `./taranac cluster add-node` / `add-witness` on the primary and use the freshly printed command — and check the joining machine can reach the primary on `9443` (firewall). |
| **`--pin` does not match the presented certificate** | Either the address is not the machine you think it is (check `--broker`, including the port), or something is terminating TLS in between (proxy, load balancer, inspecting firewall) and re-signing. **Neither is safe to click through** — this channel carries the master key. Note also that a *second* `add-node` mints a **fresh** certificate, so an old `--pin` will legitimately fail; use the command that is on the console now. |
| **The broker rejects the credentials (401)** | The token on the joining machine is not the one the broker was started with — it is long and easy to truncate. Compare without guessing: `./ha-join.sh --token <secret> --print-auth` on the joining machine against the broker's expectation. |
| **"the wrapped secret did not decrypt"** | Same cause: the token does not match. The wrap is authenticated, so this is never file corruption — copy the whole printed command again. |
| **`add-node` stops in preflight** | The cluster does not agree with itself. Each finding names the node, the value and the cure — fix it **on the node it names** (the wizard deliberately never rewrites a live member's config mid-join), then re-run. |
| **`add-node` stops: "the manifest has drifted"** | A member exists that `config/cluster.yml` does not name (a hand-rolled join, or an edited file). Either adopt it — `./cluster-manifest.py add-node --address <addr>` — or take it out — `./taranac cluster remove-node --address <addr>` — then re-run. |
| **`add-node` refuses: "is this cluster's WITNESS, not a database node"** | The address is the witness's. Check the address you meant; a broken witness is rebuilt with `add-witness --address <addr> --reinstall`. |
| **`add-node --reinstall` refuses: "no valid HA license — nothing was evicted"** | A reinstall evicts the node and then needs a join token, which only an HA license issues. The license and the preflight are now checked **before** the eviction; upload the license, then retry. |
| **`cluster decommission` (or the UI button) refuses: "still a member of the cluster"** | The row is a live machine — the leader, an etcd member or a running Patroni member. Dropping only its roster row took it out of every node's write routing. Use `./taranac cluster remove-node --node <name>` (switch the leader over first). |
| **`add-node` stops: no cluster manifest here and none published** | A node without `config/cluster.yml` normally takes the cluster's published copy by itself. This stop means the cluster has none either (it was built before the manifest was published, or its only copy was lost). On the node that still holds a good `config/cluster.yml`: `./taranac cluster manifest-publish < config/cluster.yml`, then re-run. Otherwise the next `./taranac update` on any DB node rebuilds it from the roster and the live ring and publishes it. |
| **`add-node` stops: "this node holds no etcd CA"** | This machine cannot sign a joining node's certificate. Nodes that joined *before* the CA was handed out at join never received one; run the command on a node that has `config/etcd-ca/ca.key` (the seed always does). |
| **A container is listed as `<12 hex>_taranac-db` (or another `<12 hex>_taranac-…` name)** | `docker compose` was interrupted while recreating it, and the new container is still running under its temporary name. Any `./taranac` command renames it back without restarting it. If the message says the real name is still held by the container being replaced, the leftover never ran: remove it as printed (`docker rm <leftover>`) and never `start` it. `./taranac diagnose --ha` reports this as `[RENAMED]` and changes nothing. |
| **`add-node --reinstall --name <new>` is refused** | A reinstall keeps the member's name. To bring the machine back under a new name, remove it, then add it as new: `./taranac cluster remove-node --node <old name>`, then `./taranac cluster add-node --address <addr> --name <new>`. |
| **`add-node` refuses: "already a member AND is streaming right now"** | That is a healthy replica — there is nothing to add. If you really are rebuilding it, `--reinstall` (see [§3.3](#re-adding-a-node-that-is-already-a-member)); the cluster runs one replica short until the re-clone finishes. |
| **`ha-join.sh` stops: "this command was issued for a DIFFERENT machine"** | You are in the wrong terminal — the guard that exists because doing this on a healthy member destroys its database. Run it on the machine the token names, or issue a token for **this** host with `add-node` on the seed. If this host really is reached at that address through NAT, re-run with `ADDRESS_NOT_LOCAL_OK=1` ([§3.3.1](#331-the-wrong-terminal-guard)). |
| **Every `cluster` command on the witness says "this host is the cluster's WITNESS"** | Correct, and by design: a witness runs etcd only — no database, no API — so none of those commands has anything to read or drive. Run them on a DB node; the message lists what you *can* run there. |
| **`cluster status` shows fewer pending tokens than you issued** | Expired tokens are not listed, because "outstanding" means *redeemable*. Expiry is applied when the list is read, so a token past its lifetime simply disappears from it; a completed join also revokes any other pending token for that same address. |
| **"already at its licensed node limit" while `cluster status` shows a free slot** | An earlier interrupted add left an unredeemed join token holding that slot. `add-node` now clears the leftovers for the same address before issuing a new token, so re-running it is the fix; `./taranac cluster revoke --id <id>` is the manual route. |
| **The node joined the ring but is not streaming** | Usually a `PG_ALLOW_CIDR` that does not reach it — `pg_hba` refuses the `replicator` login *after* the handshake, so nothing looks broken. Check from both ends: `pg_stat_replication` on the primary, and `./taranac logs --tail 80 postgres` on the new node. |
| **A node's Postgres refuses to start: "PATRONI_REST_PASSWORD is not set"** | Correct behaviour, not a bug ([§7](#7-security--you-must-do-this)). Since 1.2.7 `./taranac update` provisions this key on an already-converted cluster, identically on every node, so an upgrade no longer lands here. If you do meet it: copy the value from a node that already has one — it must be **identical** everywhere — or, if no node has one, run `./taranac update` on each node. |
| **`taranac-db` restarts in a loop saying "REFUSING to start — this node is part of an HA cluster"** | The base compose file was used on an HA node, without the Patroni overlay. Starting there would put a second **writable** Postgres on Patroni's data directory. Bring it up through the wrapper, which merges the overlay itself: `./taranac up -d`. If the node is genuinely no longer in a cluster, shrink it first with `./ha-deconvert.sh`. |
| **A join fails on the new machine with `member count is unequal`** | The node you ran `add-node` from has a declared etcd member list that no longer matches the live ring, and that list is what the joining node is given. Run `./taranac cluster sync` on that node and repeat the add. The preflight stops this before a token is issued since 1.2.7. |
| **`ha-convert` / the join fails writing certs — "cannot write to config/etcd-tls"** | Docker created that directory **root-owned** on an earlier start. `sudo chown -R "$(id -u):$(id -g)" config/etcd-tls config/etcd-ca config/cluster-secrets`, then retry. |
| **A re-join won't form quorum / etcd "cluster ID mismatch"** | A stale `taranac_etcd_data` volume from a previous cluster. The join clears it automatically — let the script run rather than pre-clearing volumes by hand. During `add-witness`, both rings are new: the refusal prints the two clears (this node and the witness) and the re-run. Elsewhere, `./taranac diagnose --ha` prints the recipe per member ([below](#what-taranac-diagnose---ha-reads-in-the-logs)). |
| **The tooling refuses with "< 3 etcd members"** | The declared ring is too small. A 2-node cluster needs a witness: `./taranac cluster add-witness --address <a third host>`. |
| **A `cluster:readiness` / `cluster:readiness_blind` or grant alert** | Only relevant if you run a hardened, non-superuser database. The app role is missing a stats grant — the alert reference in [§14](#14-alert-reference) names the grant each one needs. The default Taranac DB image is unaffected. |
| **Worried about split-brain** | With a witness there is none: a partitioned old primary self-demotes to read-only on its own (it cannot reach quorum), so two writers never exist. Just keep the witness in a separate failure domain. |
| **The leader demotes itself and re-promotes every few minutes, with nothing else wrong** | Suspect etcd's store first: past roughly a hundred megabytes `fsync` gets slow enough to lose elections. Ask each machine locally — `docker exec taranac-etcd etcdctl endpoint status -w table` — and if the store is large, follow [§5 Keep etcd's store from growing without bound](#keep-etcds-store-from-growing-without-bound). A cluster older than that setting never got it. |
| **A node shows as a "phantom streamer"** | A removed node is still physically running — finish Step 2 of [§5 Remove a node](#remove-a-node): wipe it or detach it. |
| **`./taranac restore` refuses on a cluster node** | A restore runs on the **leader** only (the replicas take the data by replication), and only with an archive cut under the keys the cluster runs now — an archive from before a `rotate-key` would change them on one node. It never restores the cluster's published topology (`cluster.manifest`): the live one is kept. |
| **`install.sh` refuses** | On a cluster node: use `./taranac update` (it keeps the order and the lock). On the witness: `./taranac update`. With no `.env` but an existing `taranac_pg_data`/`taranac_etcd_data`: a fresh install would make a new master key that cannot read that database — put the old `.env` back. |
| **`cluster rotate-ca` stopped, or refuses** | It says why and what to do; the cure for a stop is always the same command again. See [Replacing the etcd CA](#replacing-the-etcd-ca). |

### What `./taranac diagnose --ha` reads in the logs

The collector matches the etcd, database and api container logs against a fixed list of
lines that name a cause (`signatures.txt` in the archive). A finding names the line, how
often and when it was written, and its cure. It reads each log only **up to the moment it
starts**: the logins and connections it makes itself can never come back as a finding.
A match is **live** when the line is at most five minutes old, or the container has
stopped and the line is from its last run. Only a live one decides the `Next:` line; an
older one is still shown.

**Current evidence beats a line's age.** Where the fault a line names can be asked now, it
is asked — after that moment, so the question never comes back as a line — and a fault
that is gone makes its line *past*, with the reason beside it: `[NO-ROLE]`, `[NOLOGIN]` and
`[NO-REPLICATION]` once `replicator` logs in to this node's database with `.env`'s password
(those are properties of the role; `[REPL-PASSWORD]` is not superseded so — the server writes
it for whichever client connected, usually a peer whose `.env` differs, and this node's own
login says nothing about that peer), `[CLONE-AUTH]` once
this node's WAL receiver streams, `[API-DB-TIMEOUT]` once the api is healthy since a
start after the line. A clock alone sent operators to recreate a role their previous
cure had already recreated, while the real fault sat in the reachability table.

| Finding | What the log line means | Cure |
|---|---|---|
| `[ETCD-ID]` on a database node | This etcd and a peer belong to **different rings** — one side kept an etcd volume from an earlier attempt. The finding prints both cluster ids. | For each member that answers on 2380: the **witness** — on it `docker rm -f taranac-witness-etcd && docker volume rm taranac-witness_etcd_data`, then on the leader `./taranac cluster add-witness --address <witness>` and run the command it prints there; a **database node** — on the leader `./taranac cluster add-node --address <addr> --reinstall` (the join clears its etcd volume). Then `./taranac diagnose --ha` on that member. |
| `[ETCD-ID]` on the witness | (a) its `.env` has no `TARANAC_CLUSTER_ID`: its etcd formed a ring of its own; (b) otherwise its etcd volume is from an earlier ring. | (a) on the leader `./taranac cluster add-witness --address <witness>`, and run what it prints on the witness; (b) the witness wipe above, then the same. |
| `[ETCD-COUNT]` | The member was given a ring list that is not the live one. | `./taranac cluster sync` on the node the add ran from, then repeat the add. |
| `[ETCD-PEERURL]` | The member's peer URL is not the one the ring holds for its name. | Remove it (`remove-node` / `remove-witness`) and add it again. |
| `[ETCD-PEM]` / `[ETCD-TLS]` | A certificate or key is not PEM / a TLS handshake failed (an untrusted certificate, or http against https). | `./taranac cluster renew-cert` on that member; compare `certs.txt` and the schemes across members. |
| `[ETCD-INVALID]` | etcd refused a value of its configuration — the line names it. | Correct that key in `.env`, then `./taranac up -d`. |
| `[NO-ROLE]` | A node asked this database for the `replicator` role, and it does not exist here. | On the leader: `docker exec -it taranac-db psql -U taranac -c 'CREATE ROLE replicator REPLICATION LOGIN'`, then `\password replicator` with the `.env` value ([§7a](#7a-durable-gotchas--the-ones-that-bite-silently) item 5). |
| `[REPL-PASSWORD]` | A node logged in as `replicator` with another password (PostgreSQL 16's `FATAL:  password authentication failed for user "replicator"`). The line does not say which node. | Compare `POSTGRES_REPLICATION_PASSWORD` in each database node's `config.txt`, then set the role's password as above. |
| `[NOLOGIN]` / `[NO-REPLICATION]` | The role exists but may not log in, or has no `REPLICATION` (PostgreSQL: "permission denied to start WAL sender"). | On the leader: `docker exec -it taranac-db psql -U taranac -c 'ALTER ROLE replicator REPLICATION LOGIN'`. |
| `[CLONE-AUTH]` | This replica's clone was refused by the leader: the leader's `replicator` password is not `.env`'s. | On the **leader Patroni names** (never an address taken from the log): `CREATE ROLE` if missing, then `\password replicator`. |
| `[API-DB-TIMEOUT]` | The api wrote `startup: no database connection (…)`: its start-up could not open a database connection (timed out, refused, or the database was still starting) and it exited. | Once a database in `DB_HOSTS` answers (the database findings say why it does not): `./taranac up -d`. |
| `[BIND]` | Not a log line: Docker could not start a container of this node's stack (any of them — `taranac-edge` on 443 as much as etcd) because a port it publishes is taken. | Find the holder (`sudo ss -ltnp 'sport = :<port>'`), stop it, `./taranac up -d`. |

**There is no `pg_hba` row.** Patroni, taking over a data directory, writes `no pg_hba.conf
entry for replication connection from host "127.0.0.1"` a few times before it has
rendered its own `pg_hba.conf` — so the line is noise exactly while a node is converted,
and it once outranked a taken port, a wrong password and a healthy verdict. Whether
`PG_ALLOW_CIDR` covers a peer is asked by doing it: the `replicator` login the
reachability step makes, whose `hba` answer prints the widened value with the real
address.

**The order of `Next:`.** The first that applies: a standalone host — nothing; a port taken
or a live etcd line — its cure; the ring without a majority — the first member down; **this
node's own `:2379` or `:8008` dropped from its Docker network while the host reaches it** — the
firewall cure, one rule for both ports (the hairpin; the database and api lines that follow from it rank below); a
live database or api line — its cure; the ring unreadable — another member; **a member
Patroni reports streaming that the roster has no active row for** — on it `./taranac up -d`
and `./taranac update --version <v>`, as in [If a join stops after the clone](#33-add-each-remaining-node--on-node-1);
then the member the verdict names.

**Why `Next:` never says `./taranac up -d` to a member Patroni lists.** Patroni listing a
node means its stack runs: it is cloning, starting or stopped by Patroni itself.
Restarting it changes nothing and hides the cause, which is in that node's own logs — so
the step is `./taranac diagnose --ha` **on that node**, and its signatures. `up -d` is
said only for a member Patroni does not list and whose ports **refuse** — and for a member
Patroni reports **streaming** that the roster does not know: its stack is the overlay's
database alone, and starting the rest is what registers it.

**Refused, dropped, silent.** The reachability table has two columns — from the host, and
from the Docker network Patroni and the api dial from (this node's own address included:
the hairpin, asked on 2379 and, on a database node, 8008 — the ports a container here
reaches through the LAN address). `refused` means the host answered and nothing listens there (or a firewall
REJECTs): start it. `timeout` means nothing came back — a firewall DROPs the traffic, and
the cure names the source to admit (for this node's own address, the Docker subnet on
both ports, as the one ufw rule of [§7](#7-security--you-must-do-this)). No
port and no ping at all: the machine is down or unreachable — check it is powered on.

### etcd CA out of sync

Each member signs with the CA in its `config/etcd-ca/ca.crt`, and that CA must be among
the ones its `config/etcd-tls/ca.crt` trusts — the same CA on every member. You are sent
here by `rotate-ca` ("members disagree about the CA", "older than the cluster", "holds no
key for it"), by the etcd agent's log ("not among the CAs this node trusts"), or by
`./taranac diagnose --ha` (`[CA]`). An interrupted rotation never leaves this state —
`rotate-ca` sorts those out by itself. What does is a `config/etcd-ca` copied back from an
archive older than a rotation, or from another cluster, or edited by hand. On the member
it names:

- **Its `config/etcd-ca` is older than the cluster**: delete `config/etcd-ca/ca.key` and
  `config/etcd-ca/ca.crt` there (and `next.crt` / `next.key` if present). Its etcd agent
  asks the ring for the current CA, and another member sends it within five minutes —
  `./taranac logs etcd-agent` there shows it arrive. Then run `rotate-ca` again, if that is
  what sent you here.
- **It holds only an old CA while the cluster has moved to a new one**, or that does not
  help: re-join it — on a database node `./taranac cluster remove-node --node <name>`
  (`./taranac cluster remove-witness` for the witness), then add it again:
  `./taranac cluster add-node --address <addr>` ([Add a node later](#add-a-node-later)),
  or, for the witness, `./witness-join.sh --leave` on it (as `remove-witness` says) and
  then `./taranac cluster add-witness --address <addr>`.
- **`rotate-ca` says the member it runs on holds no key for the cluster's CA**: run it on
  another member, then put this one right as above.

Members that disagree with no rotation behind it: collect `./taranac diagnose --ha` on
**every** member (each archive's `certs.txt` lists the SHA-256 of every CA that member
holds and trusts) and send them all.

### expired etcd CA

The cluster CA has ended. Every member's certificate is signed by it, so nothing that
talks to etcd on 2379 — Patroni, the api, the etcd agents, `etcdctl` — can verify any
member. `rotate-ca` cannot replace it: it needs members that still verify each other.
The new CA is put in place by hand, on every member, with `ha-etcd-ca.sh` from the
bundle. Make it on one database node — node-1 below.

1. **On every member** (each database node and the witness), in the bundle directory:
   a certificate request on the key the member already has, and the addresses its
   current certificate names.
   ```bash
   ./ha-etcd-ca.sh make-csr config/etcd-tls <member name>
   openssl x509 -in config/etcd-tls/etcd-server.crt -noout -ext subjectAltName
   ```
   Copy `config/etcd-tls/etcd-server.csr` to node-1 as `<member name>.csr` (a request is
   not a secret) and note the addresses.
2. **On node-1**, set the expired CA aside and make a new one:
   ```bash
   mv config/etcd-ca config/etcd-ca.expired
   ./ha-etcd-ca.sh init-ca config/etcd-ca
   ```
3. **On node-1**, sign each request with exactly the addresses that member's certificate
   named, comma-separated (`127.0.0.1` and `localhost` among them):
   ```bash
   ./ha-etcd-ca.sh sign-csr config/etcd-ca <member name>.csr <member name>.crt <addresses>
   ```
4. **On every member**, node-1 included: copy `<member name>.crt` over
   `config/etcd-tls/etcd-server.crt`, and node-1's new `config/etcd-ca/ca.crt` over
   `config/etcd-tls/ca.crt`. On every member but node-1, also put node-1's
   `config/etcd-ca/ca.crt` and `ca.key` into `config/etcd-ca/` — the key is the cluster's
   most sensitive file: copy it over SSH and delete every copy made on the way. Then, on a
   database node, `sudo chgrp -R 999 config/etcd-ca && sudo chmod -R g+rX config/etcd-ca`
   (so the backup can read it, [§7](#7-security--you-must-do-this)); on the witness,
   `chmod 600 config/etcd-ca/ca.key`. Delete `config/etcd-tls/etcd-server.csr`.
5. **Check.** Nothing needs a restart: etcd reads its certificate on every connection, and
   its clients read `config/etcd-tls/ca.crt` on every new one. On a database node
   `./taranac cluster status` lists one etcd CA, `in use`, and a leader; if no leader
   shows within a few minutes, `./taranac logs --tail 80 postgres` on a node says why.
   `./taranac diagnose --ha` on every member reports no `[CA]` finding. Then delete
   `config/etcd-ca.expired` on node-1.

---

## 9. A note on the database image

Taranac's standalone and HA Postgres images are **both Alpine/musl** on purpose,
and the HA conversion **adopts your existing data dir in place**. Do not
substitute a custom or third-party Postgres image: adopting a data directory
across a different C library (e.g. a Debian/glibc image) would order text indexes
by glibc collation while the data sits in musl order — silent index corruption,
with no version-mismatch warning, because musl reports no collation version. This
is handled for you by the bundled images — there is nothing to configure.

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

**Where reads and writes go.** **Writes** go to a list of every node's Postgres with
`target_session_attrs=read-write`, so they always land on whichever node is currently
primary. That list is the cluster's **node roster** — the replicated list of nodes
that completed a join — which every node holds a copy of: the api re-reads it every
few seconds and hands it to the daemons and `taranac-mfa` on this node as
`write_hosts.conf`. So a node you add is written to by every member within seconds,
with nothing restarted, and a switchover to it just works. `DB_HOSTS` in `.env` is
only the starting list a process uses until it has read the roster (and `./taranac
update` refreshes it before each restart). **Daemon reads stay node-local** — each
daemon reads its own node's replica and serves AAA from that plus in-memory caches.
That is why **authentication never depends on the primary being up**: a replica node
keeps answering TACACS/RADIUS/NAC from local data even mid-failover. Only *writes* (UI
config edits, accounting rows) briefly pause.

**Failover.** When the primary stops renewing its etcd lease (the DCS TTL, **~30 s**),
Patroni promotes the most up-to-date replica, the other replicas re-point to it, and
every node's writes reconnect to the new primary through that list. **Leader-only work
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
`ETCD_INITIAL_CLUSTER`, `PG_ALLOW_CIDR`, etcd client scheme, version and HA marker,
plus `EFFECTIVE_DB_HOSTS` — the write list it actually uses)
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
agrees, and if it differs the per-key block names the value that drifted. A database
node also prints a `crl-fingerprint` line over the EAP-TLS CRLs in its NAC container
(`crl.txt` lists each file with its CRL Number): different on two nodes means they
enforce different CRLs, so a revoked certificate may be refused by one and accepted by
the other. Within one CRL download interval of a new CRL that can be a deploy still in
progress — collect again before concluding.

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
| A join failed and you want to retry | a failed join can leave the node in the ring — the failure message says so and prints the finish/evict commands; `add-node --reinstall` or `remove-node --address` take it from there. Otherwise re-run the `add-node` / `add-witness` command on the primary — a fresh token and a fresh certificate are issued each time |
| A `cluster` command refuses on the machine you are on | you are probably in the wrong terminal — [§3.7](#37-which-command-runs-on-which-machine) lists what runs where and what each refusal looks like |
| A node's `.env` is out of date after a join | nothing to do: its next `./taranac update` rewrites it before restarting; `./taranac cluster sync` on that node does it now, without restarting ([§5](#bring-a-node-back-up-to-date)) |

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
| `cluster:etcd_member_down` | warning / **error** / **critical** | A member of the etcd ring has not answered **two checks in a row** (about one to two minutes) — a database node, the **witness**, a node removed from the roster but still a voting member, or a member left by an interrupted add. A single missed check (an etcd election, a quick restart) is never reported. **Warning**: the ring still tolerates another loss. **Error**: exactly a majority answers, so the **next loss stops writes** cluster-wide. On a 2-node cluster with a witness, and on 3 database nodes, **any one machine down is an error** — a dead database node shows up as this error *and* a `cluster:node_down` warning; a reboot longer than one to two minutes raises it too. **Critical**: below a majority. | Bring the member back — the alert clears on the first check it answers. If it is gone for good, remove it (§5) — a voting member never leaves on its own and keeps counting against quorum. Only on a ring with a member to spare (five members) is a dead database node left to `cluster:node_down` alone. |
| `cluster:departed_witness_running` | warning | A witness was taken out of the ring with `remove-witness` while its etcd was running, and that host has not run `./witness-join.sh --leave` yet. It has no vote and no data, so the cluster is not at risk, but that host is still set up as a witness and keeps restarting its etcd. Raised about a minute after the removal and held until the host leaves. Also shown in `cluster status`. | On that host: `./witness-join.sh --leave` — it clears within a minute. If the machine is gone for good: `./taranac cluster remove-witness --forget <address>` on any database node. |
| `cluster:etcd_unreachable` | warning | For two checks in a row the leader could not read the etcd ring from any endpoint, could not load the etcd CA (`config/etcd-tls/ca.crt`, or `config/etcd-ca/ca.crt` as a fallback), or this node has no `ETCD_HOSTS`. Until it clears, no etcd alert is cleared. | Check this node's etcd (`./taranac diagnose --ha`) and that 2379 is reachable; the alert names the cause. `./taranac-update.sh` makes a `config/etcd-tls` directory left unreadable by a strict umask readable again. |
| `cluster:etcd_cert_expiring:<member>` | warning / **error** | The client-TLS certificate (`etcd-server.crt`) that etcd member — a database node or the witness — serves on 2379 ends within 30 days; **error** once it has expired, when clients refuse that member. Every member renews its own 45 days ahead (§4.2), so this alert means **the automatic renewal did not happen** on that member. One alert per member; checked every minute against what the member actually serves. | On that host: `./taranac cluster renew-cert` (or `./taranac cluster renew-cert --all` on any member). If it does not renew, `./taranac logs etcd-agent` there says why. etcd picks the new certificate up without a restart; the alert clears within a minute. |
| `cluster:etcd_agent_outdated:<member>` | warning | That etcd member — usually the witness, which is updated last — runs a release older than 1.3.3, so it has no `etcd-agent` and nothing will renew its certificate. Read from the member's own update record, and raised only once no member's update record has moved for an hour — during a rolling update a member behind the others is the plan. | Update it: `./taranac update` on that host (the witness last). The alert clears within a minute of its record showing 1.3.3 or newer. |
| `cluster:etcd_ca_expiring` | warning / **error** | The cluster's etcd CA (`ca.crt`) that signs the members' certificates ends within **180 days**; once it has expired, no member certificate verifies. A second CA that `ca.crt` only carries, and that signs nothing the members serve, does not raise it. `./taranac cluster status` lists each CA as `in use` or `not in use`. | Replace it — on a database node: `./taranac cluster rotate-ca` ([Replacing the etcd CA](#replacing-the-etcd-ca)); nothing restarts. It needs every member, the witness included, on 1.3.3 or newer and answering — which is why the alert opens six months ahead. Once the CA has expired that command can no longer replace it: [expired etcd CA](#expired-etcd-ca). Renewing members' certificates does not help — they cannot outlive the CA. |
| `cluster:max_nodes` | **error** | Active nodes exceed the license `max_nodes`, or you are multi-node without an HA license. | Remove a node, or upload a license granting `ha` / a higher `max_nodes`. |
| `cluster:orphan_slots` | warning | Replication slot(s) match no active node and were **not** auto-dropped (ambiguous / still streaming). | Confirm the node is truly gone, then it will be reaped; never drop slots by hand. |
| `service:{tacacs,radius,nac}_backend` | **critical** (per node) | That daemon is **up but not authenticating** — running, its port accepting, and refusing every request because it has no database connection. The ordinary `service:*` check cannot see this: it is a TCP connect, and it stays green throughout. | Get that node's database back. It resolves on its own when the daemon recovers, and the requests refused during the window are replayed into the AAA log as failures (`reject_reason = backend_unavailable`) rather than leaving a gap. A stall shorter than 30 s never raises it — that is an ordinary restart loading its caches. |
| `license:validation` | **error** | The stored Pro license cannot be honoured (bad signature / wrong installation / expired). Surfaces only — disables nothing. | Upload a valid license at Settings → System → Licensing. |

The hourly leader-only reconcile re-checks the grant / over-cap / phantom alerts;
the slot reaper runs every 10 min. So a transient condition clears on its own within
those windows once you have fixed the root cause.

---

The architecture, failover internals, quorum reasoning and slot lifecycle are
summarised in [§10](#10-how-it-works-under-the-hood). The full design record —
including the options that were rejected and why — is internal to TaranacLabs and
is not shipped with this bundle; ask if you need it.
