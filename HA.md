# High Availability (Pro)

This is the operator runbook for running Taranac as a **High Availability cluster**.
It is self-contained — you should not need to read anything else to deploy or
operate HA. For the design rationale behind every decision here, see the design
spec `docs/guide/ha.md` (in the project repository).

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
these directly — the bundled `ha-convert.sh` / `ha-join.sh` scripts and the
`./taranac cluster` commands are the whole interface.

---

## 2. Before you start (prerequisites)

1. **A running single node**, installed normally (see [INSTALL.md](INSTALL.md)),
   that already holds your data. This becomes **node-1**, the seed/primary.
2. **The HA license uploaded on node-1 while it is still single-node**
   (Settings → System → Licensing). New nodes inherit the license automatically
   when they join — you never upload it per node.
3. **All nodes on the SAME image version.** Check with `./taranac version` on
   each host; they must match before you convert/join.
4. **Decide the full topology up front** — every node's name and address, *and*
   a **witness host** (see below). You will write the same cluster-wide block
   into every node's `.env`, so plan it once.
5. **A private network between the nodes.** Replication, etcd and Patroni traffic
   must travel a trusted interconnect, not the public internet (see
   [§7 Security](#7-security--you-must-do-this)).

### The witness — MANDATORY for a 2-node cluster

A 2-node cluster **cannot safely fail over on its own**. If the network splits the
two nodes, neither can tell whether the other is dead or just unreachable, so
neither may safely become primary (this is "split-brain"). The tiebreaker is a
**third etcd voting member — a witness** — running on a **separate failure
domain**: a 3rd host or VM, ideally a different rack/site.

- The witness runs **only** `docker-compose.witness.yml` — etcd only, **no
  Postgres, no Taranac stack**. It is tiny (a management VM is fine).
- It **MUST be a separate host.** Co-locating the witness with a DB node is
  useless: losing that host loses a DB node *and* the tiebreaker at the same time.
- The tooling **refuses** a 2-node deploy that does not list at least **3 etcd
  members** in `ETCD_INITIAL_CLUSTER`. This is not optional.
- For **3 or 4 DB nodes** you already have a natural majority, so a dedicated
  witness is not required — but you still list every node's etcd member.

---

## 3. Configure the cluster `.env` (every node + the witness)

Put the **same cluster-wide HA block** in `.env` on **every DB node and the
witness**. These names come straight from `.env.example` (the "HA / clustering"
section). Set the shared values identically everywhere:

```ini
# Identical on every node + the witness
TARANAC_CLUSTER_NAME=taranac
DB_HOSTS=10.0.0.1:5432,10.0.0.2:5432
PG_ALLOW_CIDR=10.0.0.0/24
ETCD_INITIAL_CLUSTER=taranac-node-1=http://10.0.0.1:2380,taranac-node-2=http://10.0.0.2:2380,witness=http://10.0.0.3:2380
ETCD_HOSTS=10.0.0.1:2379,10.0.0.2:2379,10.0.0.3:2379
ETCD_INITIAL_CLUSTER_STATE=new
POSTGRES_REPLICATION_PASSWORD=<the same value node-1 already generated>
POSTGRES_PASSWORD=<the same value node-1 already has>
```

> `POSTGRES_PASSWORD` and `POSTGRES_REPLICATION_PASSWORD` on a joining node **must
> match node-1's** — they are the cluster's shared app + replication credentials.
> Node-1 already generated both at install time; copy them onto the other nodes.

Then set the **per-node** values (different on each host):

```ini
# Unique per node
TARANAC_NODE_NAME=taranac-node-1     # this node's unique cluster name
NODE_ADDRESS=10.0.0.1                # this node's address the others route to
ETCD_NAME=taranac-node-1            # this node's etcd member name (= its key in ETCD_INITIAL_CLUSTER)
```

The witness `.env` needs only the etcd block: `TARANAC_CLUSTER_NAME`, the same
`ETCD_INITIAL_CLUSTER`, `ETCD_INITIAL_CLUSTER_STATE=new`, `ETCD_NAME=witness`,
and `NODE_ADDRESS=<the witness host's address>`.

> `DB_HOSTS` lists **every DB node's** Postgres endpoint. It is one cluster-wide
> knob the API and all three daemons read so that writes always reach whichever
> node is currently primary. Do **not** list the witness in `DB_HOSTS` (it runs
> no Postgres).

---

## 4. Convert to HA (do these steps IN ORDER)

The order is **sequential and matters** — node-1 must be the live primary before
anything joins, or an empty joining node could win the bootstrap race and clone
over your real data. (The tooling guards against this, but follow the order
anyway.)

### Step 1 — Bring up the witness etcd (on the witness host)

```bash
docker compose --env-file .env -f docker-compose.witness.yml up -d
```

### Step 2 — Convert node-1 (on your existing single node)

`ha-convert.sh` swaps node-1's database to the Patroni image, which **adopts your
existing data in place** (no re-initialisation, no data loss) and brings node-1
up as the primary that initialises the cluster.

```bash
# Take a backup first (in-app Backup & Recovery) — adoption is in-place.
./ha-convert.sh --node-name taranac-node-1 --node-address 10.0.0.1
```

The script waits until node-1 reports itself as primary, then prints the next
commands. **This must finish before you join any node.** If it times out, etcd
most likely has no quorum — confirm the witness from Step 1 is up and reachable.

### Step 3 — Join each additional node

For **each** new node, do two things:

**On node-1**, issue a join token:

```bash
./taranac cluster join-token --name taranac-node-2 --address 10.0.0.2
```

**On the new node**, first write its `.env` *without* starting a standalone stack
(a started standalone would initialise the data volume and block the clone):

```bash
./install.sh --no-start
```

Then fill its `.env` per [§3](#3-configure-the-cluster-env-every-node--the-witness),
supply `MASTER_KEY` out-of-band and run the join:

```bash
MASTER_KEY=<the cluster master key> \
  ./ha-join.sh --node-name taranac-node-2 --node-address 10.0.0.2 --join-token <secret>
```

Patroni clones the new node from the primary (its own basebackup + streaming —
there is no manual `pg_basebackup`), the node comes up as a read-only replica,
and the script redeems the token so the node registers in the roster. Repeat for
any further nodes, up to your license's `max_nodes`.

### Step 4 — Verify

```bash
./taranac cluster status     # lists nodes + replication health
```

Every node should appear, with exactly one primary and the rest streaming.

> **MASTER_KEY is delivered out-of-band — never through the database.** It must be
> **identical on every node**. Stored secrets are replicated as ciphertext; a
> wrong or missing `MASTER_KEY` makes every secret on that node undecryptable.
> It is the same `MASTER_KEY` from node-1's `.env` — back it up and guard it.

---

## 5. Operating the cluster

> **The tooling is HA-aware — you do not pass compose files by hand.** Once a node is
> converted (its `.env` has `DB_HOSTS` set), `./taranac` and `./taranac update`
> **auto-detect HA and merge `docker-compose.ha.yml` for you**, so `ps`, `logs`,
> `restart`, `down`, `up` and `update` all act on the Patroni-managed database
> correctly. You no longer need the long `-f docker-compose.yml -f docker-compose.ha.yml`
> form. (If the overlay file is ever missing on an HA node, a container-starting
> command **refuses loudly** rather than silently start a second writable Postgres —
> restore it with `./taranac update`.) `ha-convert.sh` / `ha-join.sh` set this up
> during conversion.

### Check status

```bash
./taranac cluster status     # nodes, roles, replication lag/health
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

### Add a node later

Same as a join ([§4 Step 3](#step-3--join-each-additional-node)), within your
license's `max_nodes`. Fill the new node's `.env`, issue a token on the current
primary, run `ha-join.sh` on the new node.

### Decommission a node — TWO steps

Removing a node is a **logical** removal followed by a **physical** teardown.
Both steps are required.

**Step 1 — soft-delete it from the roster** (run from any node):

```bash
./taranac cluster decommission --id <node-id>     # node-id from `./taranac cluster status`
```

This marks the node `decommissioned` in the roster (its id is retained forever so
old records still resolve). It does **not** stop the node — that replica is still
streaming and still holds a full copy of the database **and** `MASTER_KEY`.

**Step 2 — on that node, physically tear it down** (use BOTH compose files so etcd
stops too, and `-v` to remove its volumes):

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.ha.yml down -v
# then securely WIPE anything left of its Postgres data + its MASTER_KEY (.env)
```

Until Step 2 completes, the still-streaming node shows up as a **"phantom
streamer"** alert in cluster status — that alert is your cue that physical
teardown is still pending. Once the node's stack is stopped, Patroni expires its
membership and the leader auto-drops its replication slot on its own; **never
drop a replication slot by hand.**

> ⚠️ **Decommissioning down to 2 nodes brings the witness requirement back.**
> If removing a node would leave you with two DB nodes, you must keep (or add) a
> witness or you lose safe automatic failover.

---

## 6. Upgrades under HA

Keep **every node on the same image version**. Upgrade the cluster one node at a
time (see [README.md](README.md#upgrade-to-a-new-version)): update the **replicas
first, the primary last**. Schema migrations run only once, on the primary,
automatically. Take a backup from the in-app Backup & Recovery tools before
upgrading.

> `./taranac update` is HA-aware: on a converted node it brings the **database** back
> up under the Patroni overlay automatically (no manual `-f … -f` form needed) and
> reminds you of the one-node-at-a-time order. Recreating a node's container restarts
> its Postgres — on the **primary** that triggers a failover, which is exactly why you
> do the primary **last**. It also refreshes the HA overlay/tooling/runbook files
> themselves so they stay in step with the new images. (An update that changes the etcd
> image will also recreate this node's etcd member briefly — harmless one node at a
> time, but another reason not to update two nodes at once.)

---

## 7. Security — you MUST do this

The HA control-plane traffic is **not encrypted or authenticated** by default
(etcd speaks plaintext HTTP). It carries the cluster's control state and database,
so you must keep it on a private, firewalled interconnect:

- **Firewall the cluster ports to the private interconnect only — never expose
  them publicly:**
  - **etcd `2379` / `2380`** (client + peer) — holds the cluster control state.
  - **Postgres `5432`** — the database itself.
  - **Patroni REST `8008`** — cluster control.
- **Narrow `PG_ALLOW_CIDR`** from any wide default to the cluster's **private
  subnet** (e.g. `10.0.0.0/24`). Do not leave it open.
- The only ports that should face users/devices are the same as a single-node
  install: **443** (UI) and the AAA/NAC service ports you use.

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **node-1 never becomes primary** during `ha-convert.sh` | etcd has no quorum. Confirm the **witness** is up (`docker-compose.witness.yml`) and reachable, then check `docker logs taranac-db`. |
| **A node won't join / `ha-join.sh` times out** | Check that `MASTER_KEY` matches the rest of the cluster, that `POSTGRES_REPLICATION_PASSWORD` (and `POSTGRES_PASSWORD`) match the primary, and that the primary is reachable on the address in `DB_HOSTS`. |
| **`ha-convert.sh` / `ha-join.sh` refuses with "< 3 etcd members"** | Your `ETCD_INITIAL_CLUSTER` lists fewer than 3 members. A 2-node cluster needs a witness — add the 3rd etcd member and bring up the witness host. |
| **A `cluster:readiness` / `cluster:readiness_blind` or grant alert** | Only relevant if you run a hardened, non-superuser database. The app role is missing a stats grant — see the design spec `docs/guide/ha.md` §5. The default Taranac DB image is unaffected. |
| **Worried about split-brain** | With a witness there is none: a partitioned old primary self-demotes to read-only on its own (it cannot reach quorum), so two writers never exist. Just keep the witness in a separate failure domain. |
| **A node shows as a "phantom streamer"** | A decommissioned node is still physically running — finish Step 2 (stop its stack + wipe its data volume + `MASTER_KEY`). See [§5 Decommission](#decommission-a-node--two-steps). |

---

## 9. A note on the database image

Taranac's standalone and HA Postgres images are **both Alpine/musl** on purpose,
and the HA conversion **adopts your existing data dir in place**. Do not
substitute a custom or third-party Postgres image: adopting a data directory
across a different C library (e.g. a Debian/glibc image) silently corrupts text
indexes with no warning. This is handled for you by the bundled images — there is
nothing to configure. The reasoning is in the design spec `docs/guide/ha.md` §6.7.

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

Run these from any node. Start at the top; most issues are visible in the first two.

**1. Cluster status (the first thing to run):**

```bash
./taranac cluster status
```

Shows edition (`Pro (HA)` vs `Community`), node count / `max_nodes`, the **leader**,
a per-node table — **NAME / ROLE / SYNC / LAG / ADDRESS** — and warnings for
over-cap or phantom streamers. Read the **SYNC** column:

- **`in_sync`** — streaming, lag < 10 s. Healthy.
- **`behind`** — streaming but lag ≥ 10 s. Watch it; a node that stays behind > 45 s
  trips the readiness gate (its daemon-config reloads freeze) and raises a
  `cluster:readiness` alert.
- **`unreachable`** — a roster node that is **not** streaming at all. Broken
  replication or a down node.

**2. Local container health on this node:**

```bash
./taranac ps
```

**3. Patroni's own view (authoritative; use when status looks wrong):**

```bash
docker exec taranac-db patronictl -c /tmp/patroni.yml list
# role (Leader/Replica), state (running/streaming), lag per member
docker exec -it taranac-db patronictl -c /tmp/patroni.yml switchover   # planned, controlled handover
```

Patroni REST (same data, scriptable): `curl -s http://<node>:8008/cluster | jq` ·
`curl -s http://<node>:8008/` (this node's role/health).

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
docker exec taranac-etcd etcdctl endpoint health
docker exec taranac-etcd etcdctl member list
```

**Quick map — symptom → where to look:**

| Symptom | Look at |
|---|---|
| A node is `unreachable` / missing | its `taranac-db` log (`docker logs`), then §13.5 on the primary, then etcd health |
| Lag growing on one node | that node's disk/IO and `taranac-db` log; check it is not also tripping `cluster:readiness` |
| "Config won't apply on a node" | api log → grep `Readiness gate BLOCKED`; that node is out of sync (§14 `cluster:readiness`) |
| No automatic failover happened | etcd quorum / the **witness** — a 2-node cluster without a witness will not auto-fail-over (§2) |
| `./taranac` refuses an `up`/`restart` on an HA node | the `docker-compose.ha.yml` overlay is missing — restore it with `./taranac update` (the refusal is the split-brain guard, §5) |

---

## 14. Alert reference

Taranac raises these in the **UI** (and via syslog) — you do not poll. They are
stateful and **auto-resolve** when the condition clears. The relevant ones for HA:

| Alert (fingerprint) | Severity | What it means | What to do |
|---|---|---|---|
| `cluster:readiness` | warning | A replica node is too far behind (broken/stalled streaming, lag past 45 s); its **daemon-config reloads are frozen on the last-good version**. Auth still serves from caches. | Find why it stopped streaming (§13.5/§13.6); it auto-clears on catch-up. Brief config staleness on that node only. |
| `cluster:readiness_blind` | **error** | The database role can see `pg_stat_replication` rows but the columns read NULL → it lacks **`pg_read_all_stats`**, so the readiness gate / status run blind. | Only on a hardened, non-superuser DB. `GRANT pg_read_all_stats` to the app role. The bundled image is unaffected. |
| `cluster:replication_grant` | **error** | Under HA the app role lacks the **`REPLICATION`** attribute, so the orphan-slot reaper cannot drop slots. | `ALTER ROLE <app role> REPLICATION`. Bundled image unaffected. |
| `cluster:phantom_node` | warning | A node is **streaming under a name that matches no active roster entry** — either a node-name mismatch, or a **decommissioned node still physically running**. | Fix the name mismatch, or finish the physical teardown of the decommissioned node (§5). |
| `cluster:max_nodes` | **error** | Active nodes exceed the license `max_nodes`, or you are multi-node without an HA license. | Remove a node, or upload a license granting `ha` / a higher `max_nodes`. |
| `cluster:orphan_slots` | warning | Replication slot(s) match no active node and were **not** auto-dropped (ambiguous / still streaming). | Confirm the node is truly gone, then it will be reaped; never drop slots by hand. |
| `license:validation` | **error** | The stored Pro license cannot be honoured (bad signature / wrong installation / expired). Surfaces only — disables nothing. | Upload a valid license at Settings → System → Licensing. |

The hourly leader-only reconcile re-checks the grant / over-cap / phantom alerts;
the slot reaper runs every 10 min. So a transient condition clears on its own within
those windows once you have fixed the root cause.

---

For the full architecture, failover internals, quorum proofs and slot lifecycle,
see the design spec `docs/guide/ha.md`.
