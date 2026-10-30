# Installing Taranac

This is the full, step-by-step install runbook. For a one-page overview see
[README.md](README.md). Every step below was verified on a clean Ubuntu 24.04 host,
and re-verified end to end on a clean Ubuntu 26.04 LTS host.

---

## 1. Prepare a host

| Requirement | Minimum |
|-------------|---------|
| OS          | Ubuntu 22.04 / 24.04 / 26.04 LTS (any modern Linux with systemd works) |
| CPU         | 4 cores |
| RAM         | 6 GB |
| Disk        | 20 GB free |
| Access      | a non-root user with `sudo` |
| Docker      | Docker Engine **28.0 or newer**, with its ip6tables on (the default). Podman answering the `docker` command (`podman-docker`) is not supported |
| Kernel      | IPv6 support on (not booted with `ipv6.disable=1`). The host itself needs no IPv6 address |
| Network     | inbound **443** (UI), plus the AAA/NAC ports you use — TACACS `49`, RADIUS `1812/1813`, NAC `1814/1815`, and EST `8445` if devices enroll certificates over EST (renewal over mutual TLS goes only there); outbound HTTPS to pull images, and UDP to the switches' CoA port (`3799` or the vendor's) for CoA/Disconnect. IPv4 and IPv6 alike: an IPv6 device reaches the same ports and is seen with its own address |

`install.sh` and `./taranac update` check Docker and the kernel before they change anything,
and refuse with what to do; `bootstrap.sh` checks the same. Docker 27 is refused because a container kept off
IPv6 still gets an IPv6 address there, and connections inside the stack would stall on it.

### IPv6 on the host

The stack's Docker network carries IPv6 for the services devices and browsers dial, so an IPv6
client reaches them with its own address. Two things change on the host because of it:

- **Router advertisements.** Docker's first IPv6 network turns on IPv6 forwarding, and the kernel
  then ignores router advertisements on interfaces with `accept_ra=1`. A host that takes its IPv6
  address or its default route from them would lose that route when the current one expires —
  hours later, with nothing pointing at the cause. So `install.sh` and `./taranac update` set
  `accept_ra=2` on exactly those interfaces, keep it in
  `/etc/sysctl.d/99-taranac-accept-ra.conf`, and say so. This needs root: they run as root, use
  `sudo` without a password, or — at a terminal — let `sudo` ask for yours. Run without any of
  these (a non-root user from a script, say), they stop with nothing changed and print the
  commands; run those once, then the same command again.
- **The firewall.** IPv6 to the client-facing ports (80/443, MFA, TACACS+, RADIUS, NAC, EST/SCEP,
  the captive portal) is forwarded by Docker into the container, as IPv4 always was: ufw rules
  in INPUT do not see it. Filter it in the `DOCKER-USER` chain instead (Docker's guide: *Packet
  filtering and firewalls*), for example:

  ```bash
  sudo ip6tables -I DOCKER-USER -p udp -m conntrack --ctorigdstport 1812 ! -s 2001:db8:10::/48 -j DROP
  ```

  Rules added this way are not kept across a reboot unless your host saves ip6tables rules. The
  HA ports (5432, 8008, 2379) are not affected: IPv6 to them still passes INPUT.

When the host passes, `install.sh` and `./taranac update` say it in one line — the update also
in `.taranac-update.log` — for example
`Host: Docker 29.1.2 ✓, kernel IPv6 ✓, dual-stack network test ✓, accept_ra: nothing changed`.

Pick the hostname or IP that clients will use to reach Taranac — you'll enter it
during install and it should match your TLS certificate later. (Examples below
use `taranac.example.com`.)

---

## 2. Get the bundle

Pick either way and enter the bundle directory.

**Option A — release tarball** (pinned to a specific version; works offline once
downloaded). Grab `taranac-bundle-<ver>.tar.gz` from the
[Releases page](https://github.com/TaranacLabs/taranac/releases/latest), then:

```bash
tar xf taranac-bundle-<ver>.tar.gz   # unpacks into its own folder ./taranac/ (version-neutral)
cd taranac
```

**Option B — git clone** (always the latest bundle scripts):

```bash
git clone https://github.com/TaranacLabs/taranac.git
cd taranac
```

**Option C — ready-to-run virtual appliance** (no host to prepare, no internet
needed). Taranac also ships as a VMware **OVA** and, for QEMU/KVM, Proxmox and
libvirt, a **qcow2** of the same image, with the container images already baked
in. The appliance images are far larger than a GitHub release asset may be, so
they are not attached to the Releases page — ask TaranacLabs for a download link.

Import the image, give it the CPU/RAM/disk from step 1, and power it on. On the
console a setup wizard walks through:

1. **Hostname**
2. **Network** — DHCP or a static address (address / prefix / gateway / DNS)
3. **Timezone**
4. **A new password for the `taranac` login user** — set one, it is the SSH login
5. **Install Taranac** (or *Manual installation*, which just drops you into a
   shell in `/opt/taranac`)

Choosing *Install Taranac* asks for the admin UI address (defaults to this
appliance's IP), the admin username and email, and then installs the whole stack
**offline from the images already in the appliance** — no registry access. When it
finishes, the screen shows the admin URL, username and generated password: **copy
the password now.**

Everything from step 5 onward applies unchanged — the appliance simply carries
this same bundle in `/opt/taranac`, so `./taranac …`, TLS certificates and
`./taranac update` work exactly as documented below. Steps 3 and 4 are already
done for you.

Useful on the appliance:

```bash
sudo taranac-setup          # re-run the setup wizard at any time
cd /opt/taranac && ./taranac ps
cd /opt/taranac && ./taranac reset-password admin
```

The bundle contains only configuration — no product source. The application
ships as Docker images that the steps below pull automatically; their version is
read from the bundle's `VERSION` file, so `install.sh` never asks for a tag.

---

## 3. Install prerequisites (Docker)

If the host already has Docker Engine + the compose plugin, skip this. Otherwise:

```bash
sudo bash bootstrap.sh
```

This installs Docker, the compose plugin, and adds your user to the `docker`
group. A Docker that is already on the host is kept — unless it is older than 28.0 or is
Podman: then it stops and prints the command that updates or replaces it on this host.
**Log out and back in** (or run `newgrp docker`) so the group takes
effect, then verify:

```bash
docker ps        # should run without sudo and without error
```

---

## 4. Install Taranac

```bash
./install.sh
```

The installer will:

1. Ask a few questions (press Enter for the default):
   - **Primary domain** — the hostname/IP for the admin UI (e.g. `taranac.example.com`)
   - **Admin username / email** — defaults `admin` / `admin@<domain>`

   Other addresses, the MFA push domain, the registry and the version are not
   asked: the first is set once the stack is up (the note below), the rest are
   properties of the bundle.
2. **Generate every secret** (database password, JWT key, encryption master key,
   internal API keys, and the admin password).
3. Pull the images and start the whole stack.

> **The primary domain is not always the only address — and the installer does not
> ask.** Staff open a DNS name while a remote collector or a DMZ captive portal
> dials this node's IP. Nothing about that has to be decided before the product
> runs: the certificate the installer generates is self-signed, so a browser warns
> whatever addresses it covers, and the two things that verify it — a standalone
> collector and a DMZ portal — pin the certificate they are shown rather than
> matching a name against a list.
>
> To widen it once you are up: set `TARANAC_EXTRA_ADDRESSES` in `.env` (names and
> IPs, comma-separated) and run `./taranac restart edge`. It widens both the
> self-signed certificate's SAN and nginx's `server_name`; the primary stays the
> one used for links and the printed URL. An IP is written as an `IP:` SAN, never
> `DNS:` — browsers merely warn at that distinction while a strict client refuses
> the connection outright, a failure that shows up at the remote site with nothing
> pointing back here. Dropping a real certificate into `config/tls/` is the other
> way, and the better one for anything permanent.

When it finishes it prints the **admin login** (URL, username, generated
password). Copy that password now.

> **Store a copy of `MASTER_KEY` off this host.** It holds `MASTER_KEY`; if you lose
> it, every stored secret becomes permanently undecryptable — **including the backup
> archives, which are encrypted with it**. A copy that lives only on the machine you
> are protecting is not a copy. Never edit `MASTER_KEY` after first start.
> Re-running `./install.sh` later is the **upgrade** command — it pulls new
> images and restarts without touching your secrets.

---

## 5. First login

Open `https://<your-domain>/` and sign in with the printed admin credentials.

Until you install a trusted certificate (next step) the site uses a temporary
self-signed certificate, so your browser shows a security warning — that's
expected. Change the admin password right after logging in.

---

## 6. Install your trusted TLS certificate

Taranac does **not** automate Let's Encrypt — bring your own certificate (a
commercial CA, your organization's internal CA, or a manually-issued one).

Put two files in `config/tls/` (exact names):

| File      | Contents                                                  |
|-----------|-----------------------------------------------------------|
| `tls.crt` | Full chain: your server cert followed by any intermediates |
| `tls.key` | The matching private key (unencrypted PEM)                |

The certificate's SAN must cover `TARANAC_DOMAIN`, every address in
`TARANAC_EXTRA_ADDRESSES`, and `TARANAC_MFA_DOMAIN` if you set one — with any IP
address present as an `IP:` SAN rather than `DNS:` (most public CAs will not
issue for an IP at all, which is what an internal CA is for). The edge proxy
logs a warning at startup naming every address your certificate does not cover;
`config/tls/README.md` has the detail. Then apply it:

```bash
./taranac restart edge
```

Reload the page — the warning is gone.

---

## 7. (Optional) Enable MFA push

Out of the box, MFA works in **free poll-only mode** (the app checks for pending
approvals periodically). To enable instant push, drop your Firebase
service-account JSON at `config/firebase/firebase-credentials.json`, then:

```bash
./taranac up -d taranac-mfa
```

---

## 8. Day-to-day operations

Use the `taranac` wrapper from the bundle directory:

```bash
./taranac ps                # service status
./taranac logs -f api       # follow logs for a service
./taranac restart edge      # restart one service
./taranac down              # stop everything (data is preserved in volumes)
./taranac up -d             # start again
./taranac unlock            # list locked admin accounts (see below)
```

**Locked out of the admin UI.** After `MAX_LOGIN_ATTEMPTS` failed logins (5 by
default) an account is locked — common on a public server once someone starts
guessing passwords. The lock never auto-expires, so a locked-out admin cannot
use the web UI to recover. Unlock from the server console instead:

```bash
./taranac unlock            # list locked accounts
./taranac unlock admin      # unlock one account
./taranac unlock --all      # unlock every locked account
./taranac reset-password admin   # reset a forgotten admin password (prints a new one)
```

**Upgrade** to a new version — one command refreshes both images and bundle files:

```bash
./taranac version           # installed version + check for a newer one
./taranac update            # update to the latest stable release (no version to type)
```

**Factory reset** (demo stands only) — wipe all data and restore the fresh-install
state: every table is truncated (schema stays at the migration head), the default
seeds are re-applied (settings, RBAC roles, AAA templates + profiles, default
policy), the daemon configs are regenerated, and the admin is recreated from the
`INITIAL_ADMIN_*` values in `.env`. Disabled on production: set `APP_ENV=demo` in
`.env`, then `./taranac up -d` to recreate the api container, before resetting.

```bash
./taranac reset                  # dry run — print the plan, change nothing
./taranac reset --confirm RESET  # perform the factory reset (demo/development only)
```

Options:

| Flag | Effect |
|---|---|
| `--confirm RESET` | Required to actually wipe. Without it, `reset` only prints the plan. |
| `--no-backup` | Skip the automatic pre-reset backup. |
| `--force-prod` | Override the environment guard so reset runs outside `demo`/`development` (e.g. on `production`). Use with extreme care. |

By default a configuration backup is taken **before** the wipe, and the reset is
**aborted** if that backup fails — so you are never left without a safety net.
`--no-backup` removes both the backup and that abort-on-failure guard:

```bash
./taranac reset --confirm RESET --no-backup   # wipe without taking a backup first
```

After a reset, log in as the `INITIAL_ADMIN_USERNAME` from `.env` (you will be asked
to change the password on first login). If `INITIAL_ADMIN_PASSWORD` is unset, a
random password is printed in the api logs (`./taranac logs api`).

`update` works in this order, and the order is what makes a failure safe to re-run:

1. records which image every running container uses (with its digest) into the
   backup directory `.taranac-backup-<time>/images-before.txt`;
2. checks there is room on the disk for the images that are not on the host yet;
3. pulls the new version's images — **without touching `.env`**: the new tag is
   handed to `docker compose` for that one command, and your stack keeps running;
4. compares every pulled image with the list of digests the release ships
   (`IMAGES.lock`, inside the checksum-verified bundle) and stops on any mismatch;
5. only then backs up and swaps the bundle files, leaves your `.env` and `config/`
   untouched (only listing any new settings worth adding) and pins
   `TARANAC_VERSION` in `.env`;
6. restarts the stack (DB migrations run automatically) and reports the update
   complete only when every container runs the new images.

On an HA cluster member the same steps run inside the cluster's order and its
one-member-at-a-time lock, and step 6 is different — see [HA.md §6](HA.md#6-upgrades-under-ha).

If a step fails, the message says what did and did not change. A failure in 1–4
changes nothing but downloaded image layers. Either way, `./taranac update` again
finishes the job: it answers "Already on <version> — nothing to do" only when the
bundle, the pin **and the running containers** all agree, and then it makes no
backup and swaps no files (a container that is stopped is started, nothing is
recreated). Specific version: `./taranac update --version 1.1.0`. Re-apply the
version you already run (new backup, files swapped, stack recreated):
`./taranac update --version <current> --repair`. `-y` (`--yes`) only answers the
"Proceed?" prompt — it never re-applies anything.

TACACS+ accepts only devices in the inventory; a device without an entry of its own is
refused whatever key it uses (the global key is a fallback for inventoried devices). Before
"Proceed?" (right after it, when the updater already installed is older) the updater (and `./install.sh` run as an upgrade) lists the addresses that logged
in to TACACS+ in the last 30 days without an inventory entry — on an update from a release
that still let them in, these are the devices it locks out: add them to the inventory. It is
a warning, not a stop; the updater also keeps the list in `.taranac-update.log`.

**The first update to a release whose stack network carries IPv6** (from any earlier release)
does three things more, each before anything else is changed. From this release on the updater
asks them before its "Proceed?" question; on this first update the updater already installed
asks "Proceed?" first — answer it, a refusal after it still changes nothing. A command the
update prints for running it again has the form you ran it in: `--from <the same file>` for an
update from a bundle.

- It checks the host (Docker 28 or newer, IPv6 in the kernel, Docker able to create a network
  with IPv6) and sets `accept_ra=2` where needed — [§1](#ipv6-on-the-host).
- **It looks for inventory entries IPv6 devices match only through the Docker gateway.** Until
  now every IPv6 device reached Taranac from the gateway's address (`10.255.255.225`), so an
  entry covering it — the Docker subnet, a `/8`, `0.0.0.0/0` — matched every IPv6 device, with
  its key. After the update each device arrives with its own address, matches none of those,
  and is refused as unknown. If such entries exist **and the inventory has no IPv6 entry at all**
  (no IPv6 address, prefix or range with TACACS+, RADIUS or NAC on), the update names them and
  stops. Add next to each an IPv6 entry with the same key — the devices' IPv6 addresses or
  prefix, or `::/0` for all of them — and run the update again: with an IPv6 entry in the
  inventory it names those entries once more and goes on. To go on now and add them afterwards
  (IPv6 devices are refused until then): type `CONTINUE` at the prompt, or, without a terminal, run
  `TARANAC_IPV6_OWN_ADDRESS_OK=1 ./taranac update` — on this first update the updater already
  installed runs the command and does not know the `--ipv6-own-address-ok` flag yet.
  `./install.sh --ipv6-own-address-ok` is the same for the upgrade through `install.sh`.
  `./taranac diagnose` names such entries too: as a finding while IPv6 devices still arrive from
  the gateway (before the update, or with Docker's ip6tables off), afterwards only in `ipv6.txt`.
- **It recreates the stack's Docker network**, which gains its IPv6 subnet: the stack goes down
  and comes up once. Re-running `./install.sh` as the upgrade does the same.

**Release candidates** are published as GitHub pre-releases. A plain `./taranac
update` never picks one — it means "the latest stable release". To test a candidate,
name it: `./taranac update --version X.Y.Z-rcN`. A node already on a candidate is
told it is ahead of the latest stable release, not offered a downgrade. A candidate
is for a test installation: it does not update to the final release — install the
final one fresh.

Third-party images (Postgres, and etcd under HA) are pinned by digest in the shipped
compose files, so an update never picks up an upstream tag that moved. If you pull
through a registry mirror, copy the images with a digest-preserving tool
(`docker buildx imagetools create`, `skopeo copy --all`, `crane copy`); a mirror that
re-pushed them has other digests, and `update` refuses them unless you pass
`--skip-image-verify`. `--skip-space-check` overrides the disk check. When updating
FROM a release whose updater does not know these flags yet, set them as
`TARANAC_UPDATE_SKIP_IMAGE_VERIFY=1` / `TARANAC_UPDATE_SKIP_SPACE_CHECK=1` instead.

Once the stack is back up on the new images, `update` removes the image versions it superseded —
otherwise every release would leave a full image set (~4.5 GB) on the disk
forever. It keeps the version you just installed **and the one before it**, so a
rollback never depends on the registry being reachable, and it only ever
considers images under this install's `IMAGE_PREFIX` — anything else running on
the host is left strictly alone. Keep the old versions with
`./taranac update --keep-images`.

Air-gapped hosts: `version` prints a notice instead of failing; update offline
with a copied tarball — `./taranac update --from taranac-bundle-<ver>.tar.gz`. The
version installed is the one in the bundle's own `VERSION` file, whatever the file
is called — renaming the tarball does not change what it installs.
On an older bundle that has no `update` yet, copy `taranac` + `taranac-update.sh`
from the new bundle once, then it is self-maintaining.

(Take a backup from the in-app Backup & Recovery tools before upgrading.)

---

## 8a. Backup & recovery

Scheduled backups are **on by default** (daily, last 5 archives kept) — tune them
under **System → Backup & Recovery**. An archive is a *configuration* backup: the
database (logs excluded), the internal CA and certificates, this host's `.env` and
compose file, and your `config/tls` + `config/firebase` files. It is encrypted with
`MASTER_KEY`, so a copied archive is useless to anyone without that key — **and to
you as well**, which is why the key belongs somewhere other than this host.

Archives live in the `backups` Docker volume, mounted into the api container at
`/app/backups`, and are downloadable from the UI. To take them off the box with your
own tooling:

```bash
docker run --rm -v taranac_backups:/b -v "$PWD:/out" busybox \
  sh -c 'cp /b/taranac-backup-*.tar /out/'
```

**Recovery** — from the install directory, giving the archive's path on this host
(it is copied into the `backups` volume), or just its name if it is already there:

```bash
./taranac restore /path/to/taranac-backup-<UTC>.tar   # add --master-key-file <file> if this
                                                      # install runs a different key
```

The key you give is written into `.env`, because the recreated containers take the
key from there. It is given in a file holding only the key (`-` reads it from stdin),
or as `TARANAC_MASTER_KEY` in the environment — never as an argument: the shell
history and `ps` would show it to every user of the host, so `--master-key <key>` is
refused. It verifies the master key against the archive *before* touching anything, overlays
the five values that must survive a rebuild (`MASTER_KEY`, `SECRET_KEY`,
`TARANAC_MFA_API_KEY`, `INTERNAL_API_KEY`, `REPORTS_RENDERER_API_KEY`) onto this
install's `.env`, restores the certificates, loads the database and only then
recreates the stack on the restored key (the api will not start on a database
encrypted with another key). It deliberately does **not** copy the archived `.env` back — the rest of
that file describes the old host.

Deploy the same version first: recovery refuses a version or schema mismatch.
**Archives from 1.3.1 and earlier:** deploy the archive's version, replace
`taranac-restore.sh` in that install directory with the one from this release, and
run it with the archive's absolute path — the script those versions shipped does not
restore the keys.

Two things an archive does not carry, by design: **MFA enrollments** (the MFA service
has its own database and its own key) and the **Active Directory machine account**
(Samba rotates its password, so a restored one would be a broken trust — re-join the
domain after recovery).

---

## 9. High Availability (Pro)

Run Taranac as a 2–4 node cluster — one read-write primary plus read-only
replicas, with automatic failover, where authentication keeps serving on every
node even while a failover happens. HA is a Pro feature (it needs an HA license)
and is layered on top of an existing single-node install with three
`./taranac cluster` commands — `init`, `add-witness`, `add-node`.

**The full deploy + operate runbook is [HA.md](HA.md).** Start there before
touching any HA setting.

---

## 10. (Optional) A captive portal on its own host

Guest / BYOD onboarding for a Registration VLAN can run on a separate host — a
DMZ box or a branch server — instead of the portal container on this node. That
host holds no database; it serves the portal and reaches this core for the guest
API and a heartbeat.

This bundle is the whole client side: copy it to the portal host. On this core,
create the portal under **NAC → Captive Portals**, then **Deployment → Generate
Token** — the tab prints the command with this core's address already filled
in, and the token beside it:

```bash
./taranac captive-portal join --core https://taranac.example.com
```

The command asks for the token at a prompt that does not echo. It is never an
argument: an argument sits in the shell history and is readable in `ps` by every
user of the host, and this token is the portal's standing credential. Without a
terminal, pass `--token-file <path>` (`-` reads stdin) or set
`TARANAC_PORTAL_TOKEN` in the environment.

`portal-join.sh` beside the wrapper is what actually runs, and can still be
called directly; the wrapper exists so that one name covers the install and
everything after it, and so the portal's directory never has to be typed. That
last part is not cosmetic: the directory the installer sits in also holds this
product's own `docker-compose.yml`, so a bare `docker compose ps` there reports
on the wrong stack instead of saying anything is wrong.

Nothing else moves by hand. The host establishes trust in this core (by default
it pins the certificate presented on first contact and accepts only that one
afterwards), fetches **its own** deployment bundle over HTTPS with the token,
unpacks it and starts the container — then waits for the first accepted heartbeat
before reporting success. The **Download Bundle** button on the same tab is the
offline path, for a host with no route here at install time.

The address you give `--core` must appear in this node's certificate SAN — the
portal's nginx verifies the upstream name (step 6). If this core's certificate is
ever legitimately replaced, the portal refuses the new one and names both
fingerprints; re-pin with `./taranac captive-portal reset-trust`.

---

## Troubleshooting

- **A service shows `unhealthy` in `./taranac ps`** — check its logs:
  `./taranac logs --tail=100 <service>`.
- **Browser keeps warning after step 6** — confirm `config/tls/tls.crt` is the
  full chain and the SAN matches your domain, then `./taranac restart edge`.
- **`docker ps` needs sudo** — you didn't start a new login shell after
  `bootstrap.sh`; log out/in or run `newgrp docker`.
- **IPv6 devices are logged or refused with the Docker gateway's address** — run
  `./taranac diagnose`; its `ipv6.txt` shows Docker's version, whether its ip6tables is on, the
  daemons' IPv6 listeners and IPv6 DNAT per published port (the DNAT part needs root or `sudo`),
  and `accept_ra`.
