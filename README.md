# Taranac — deployment

![tests](https://img.shields.io/badge/tests-4561%20passing-brightgreen) ![coverage](https://img.shields.io/badge/coverage-80%25-green) &nbsp;·&nbsp; [Testing &amp; quality →](TESTING.md)

Network access control (TACACS+ / RADIUS / 802.1X) with a web UI. This directory
is everything you need to run Taranac from published Docker images — no source.

**Full step-by-step runbook: [INSTALL.md](INSTALL.md).** Quick version below.

## Requirements

- A Linux host (Ubuntu 22.04/24.04 LTS), ≥4 cores, ≥6 GB RAM, ≥20 GB free disk
- A non-root user with `sudo`
- Open inbound ports: **443** (UI/API), plus the AAA/NAC service ports you use
  (TACACS `49`, RADIUS `1812/1813`, NAC `1814/1815`, CoA `3799`)

## Install

> **Prefer a ready-to-run VM?** Taranac also ships as a **virtual appliance** — a
> VMware **OVA** and a QEMU/KVM (Proxmox, libvirt) **qcow2** of the same image, with
> the container images already inside. Import it, power it on, and a wizard on the
> console asks for hostname, network, timezone and a login password, then installs
> Taranac **offline** — no Docker install, no registry access, none of the steps
> below. The appliance images are too large for GitHub release assets, so ask
> TaranacLabs for a download link. See [INSTALL.md](INSTALL.md) → *Option C*.

Copy-paste on a fresh host — download, unpack, install Docker, start Taranac:

```bash
# 1 — download and unpack the latest release
curl -fsSL -O https://github.com/TaranacLabs/taranac/releases/latest/download/taranac-bundle.tar.gz
tar xf taranac-bundle.tar.gz
cd taranac

# 2 — install Docker + compose plugin (skips if already present), then log out and
#     back in so the docker group applies (or run: newgrp docker)
sudo bash bootstrap.sh

# 3 — configure + start Taranac (asks for domain + admin, generates every secret)
./install.sh
```

`install.sh` asks for your domain and admin details, **generates every secret**,
writes `.env`, pulls the images and starts the stack. At the end it prints the
admin login. Re-running `./install.sh` later is the **upgrade** path — it never
regenerates secrets, just pulls and restarts.

It also asks for **other addresses this node answers on** (names and IPs,
comma-separated → `TARANAC_EXTRA_ADDRESSES`). List them: staff open a DNS name
while a remote collector or a DMZ captive portal dials the IP, and both have to
work. The answers widen the certificate's SAN and nginx's `server_name`; the
primary domain stays the address used for links.

Services run with `restart: unless-stopped` and Docker is enabled on boot, so the
whole stack comes back automatically after a server reboot.

> Back up `.env` — especially `MASTER_KEY`. Losing it makes every stored secret
> undecryptable. Never change `MASTER_KEY` after the first start.

## Trusted TLS certificate

No Let's Encrypt automation — you bring your own certificate. Drop it into
[`config/tls/`](config/tls/README.md) as `tls.crt` (full chain) + `tls.key`, then:

```bash
./taranac restart edge
```

Its SAN must cover every address above, with any IP as an `IP:` SAN rather than
`DNS:` — browsers only warn at that difference, but a standalone collector or
captive portal verifies strictly and refuses to connect. Edge names any address
your certificate misses in its startup log.

Until then the edge proxy serves a temporary self-signed cert (browsers warn).

## MFA push (optional)

Without configuration, MFA runs free **poll-only**. To enable instant push, drop
your Firebase service-account JSON into
[`config/firebase/`](config/firebase/README.md) and restart `taranac-mfa`.

## Day-to-day

Use the `taranac` wrapper (short for the full compose invocation):

```bash
./taranac ps            # status
./taranac logs -f api   # logs
./taranac down          # stop (data preserved in volumes)
./taranac up -d         # start
```

**Locked out of the admin UI?** After too many failed logins (e.g. a
brute-force attempt against a public server) an account is locked and the web
UI will keep refusing it. Unlock it from the server console:

```bash
./taranac unlock         # list locked accounts
./taranac unlock admin   # unlock one account
./taranac unlock --all   # unlock every locked account
```

**Forgot the admin password?** Reset it from the server console (prints a new
one-time password; the account is asked to change it at next login):

```bash
./taranac reset-password admin
```

## Backup & recovery

Scheduled backups are **on by default** (daily, last 5 kept) — see
**System → Backup & Recovery**. Archives hold the configuration database, the
certificates, this host's `.env` and compose file, and your `config/tls` +
`config/firebase` files, encrypted with `MASTER_KEY`.

**Keep a copy of `MASTER_KEY` off this host.** The archives are encrypted with it,
so losing the host *and* the key leaves nothing that can open them.

Recovery, on a fresh install of the same version with the archive back in
`./backups/`:

```bash
./taranac restore taranac-backup-<UTC>.tar     # --master-key <key> if this
                                               # install runs a different one
```

Full detail — including what an archive deliberately does not carry (MFA
enrollments, the AD machine account) — is in `INSTALL.md` §8a.

## Rotating the master key

`MASTER_KEY` encrypts every secret Taranac stores. To replace it:

```bash
./taranac rotate-key --confirm LOCAL-ACCESS-VERIFIED
```

Run it without the confirmation first — it prints exactly what goes down and why
the phrase is required. In short: the whole stack stops for the rotation,
**TACACS+ included**, so during the window nobody can log in to your switches and
the admin UI is down too. Make sure the local fallback accounts on your network
gear work before you start; nothing here can check that for you.

You are asked for the current key (proof you still hold it — if you cannot
produce it, your existing archives are already unreadable). A backup is taken
first, the whole database is re-encrypted in one transaction, and the previous
key is kept in `config/retired-keys/` — **keep it**, every archive taken before
the rotation needs it:

```bash
./taranac restore <archive.tar> --master-key <the previous key>
```

Under HA the rotation runs on the leader only (it refuses elsewhere); afterwards
copy the new key to each replica out of band, exactly as at join time. A replica
that has not got it yet **will not start** — that is the safety check working, not
a fault.

## Activating a Pro license

Pro features are unlocked by an **offline, signed license file** — no phone-home.
Taranac Community runs fully without one.

1. Get this installation's **Installation ID** (shown on **Settings → System →
   Licensing** in the UI, or from the console):

   ```bash
   ./taranac installation-id
   ```

2. Send the Installation ID to TaranacLabs; you receive a `.lic` file bound to it.
3. Upload the `.lic` on **Settings → System → Licensing**. Done — no network call
   leaves the install.

The license is verified locally; an invalid or wrong-installation file is rejected
and never disables the running system.

## Captive portal on its own host

A Registration VLAN in a DMZ or a branch can be served by a portal on its own
host. `portal-join.sh` in this bundle is the whole client side — copy that one
file over. Create the portal under **NAC → Captive Portals**, then **Deployment →
Generate Token**; the tab prints the command with this core's address and the
token filled in:

```bash
./portal-join.sh --core https://taranac.example.com --token cp_live_...
```

The host pins this core's certificate, fetches its own deployment bundle over
HTTPS and starts — nothing is copied by hand. Detail, plus the offline path for a
host that cannot reach this core: [INSTALL.md](INSTALL.md) §10.

## High Availability (Pro)

Run Taranac as a 2–4 node cluster: one read-write primary plus read-only replicas,
automatic failover, and authentication that keeps serving on every node even
during a failover. HA is a Pro feature, layered on an existing single-node install
with the bundled `ha-convert.sh` / `ha-join.sh` scripts (a witness host is
required for a 2-node cluster).

**Full deploy + operate runbook: [HA.md](HA.md).**

## Upgrade to a new version

One command updates **both** the container images and the bundle files (this
wrapper, compose, installer, docs) — an image-only `pull` would leave the bundle
stale:

```bash
./taranac version    # show installed version + check if a newer one exists
./taranac update     # update to the latest (no version to type — it picks newest)
```

`update` backs up the current bundle files, swaps in the new ones, **never
touches your `.env` or `config/`** (it only lists any new settings you may want
to add), bumps the pinned version, pulls images, and restarts. DB migrations run
automatically on api start. (Back up first via the in-app Backup & Recovery
tools.) Pin a specific version with `./taranac update --version 1.1.0`.

**Air-gapped / no internet?** `version` just prints a notice (not an error).
Copy `taranac-bundle-<ver>.tar.gz` (from the project releases) onto the host and:

```bash
./taranac update --from taranac-bundle-<ver>.tar.gz
```

**First time on an older bundle** (no `update` subcommand yet): replace the two
files once, then `update` is self-maintaining afterward —
`taranac` and `taranac-update.sh` from the new bundle into this directory.

## What runs

| Service          | Role                                              |
|------------------|---------------------------------------------------|
| `edge`           | Public TLS reverse proxy (the cert browsers see)  |
| `frontend`       | React admin UI (internal, behind edge)            |
| `api`            | FastAPI control plane + config generator          |
| `taranac-mfa`    | Push/TOTP MFA service                             |
| `tacacs`         | TACACS+ daemon (device administration)            |
| `radius`         | RADIUS daemon (AAA)                               |
| `nac`            | RADIUS daemon for 802.1X (port access control)    |
| `captive-portal` | Guest/onboarding portal                           |
| `taranac-renderer` | Report PDF rendering (HTML→PDF, internal)       |
| `taranac-winbind` | Active Directory machine account (MS-CHAPv2 for domain accounts) |
| `postgres`       | Database                                          |

## License

Taranac is licensed under the **Elastic License 2.0** — see [LICENSE](LICENSE).
You may run it for free, including for commercial and internal production use.
You may **not** offer it to others as a hosted/managed service, circumvent its
license-key functionality, or remove its notices. "Taranac" is a trademark of
TaranacLabs.
