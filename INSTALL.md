# Installing Taranac

This is the full, step-by-step install runbook. For a one-page overview see
[README.md](README.md). Every step below was verified on a clean Ubuntu 24.04 host.

---

## 1. Prepare a host

| Requirement | Minimum |
|-------------|---------|
| OS          | Ubuntu 22.04 / 24.04 LTS (any modern Linux with systemd works) |
| CPU         | 4 cores |
| RAM         | 6 GB |
| Disk        | 20 GB free |
| Access      | a non-root user with `sudo` |
| Network     | inbound **443** (UI), plus the AAA/NAC ports you use — TACACS `49`, RADIUS `1812/1813`, NAC `1814/1815`, CoA `3799`; outbound HTTPS to pull images |

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
tar xf taranac-bundle-<ver>.tar.gz   # unpacks into its own folder taranac-<ver>/
cd taranac-<ver>
```

**Option B — git clone** (always the latest bundle scripts):

```bash
git clone https://github.com/TaranacLabs/taranac.git
cd taranac
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
group. **Log out and back in** (or run `newgrp docker`) so the group takes
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
   - **MFA push domain** — leave blank unless MFA runs on its own hostname
   - **Admin username / email** — defaults `admin` / `admin@<domain>`
   - **Image registry / version** — defaults are correct for the public release
2. **Generate every secret** (database password, JWT key, encryption master key,
   internal API keys, and the admin password).
3. Pull the images and start the whole stack.

When it finishes it prints the **admin login** (URL, username, generated
password). Copy that password now.

> **Back up `.env`.** It holds `MASTER_KEY`; if you lose it, every stored secret
> becomes permanently undecryptable. Never edit `MASTER_KEY` after first start.
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

The certificate's SAN must cover your domain. Then apply it:

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
./taranac update            # update to the latest (picks the newest, no version to type)
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

`update` backs up the current bundle files, swaps in the new ones, leaves your
`.env` and `config/` untouched (only listing any new settings worth adding),
bumps the pinned version, pulls images and restarts; DB migrations run
automatically. Specific version: `./taranac update --version 1.1.0`.

Air-gapped hosts: `version` prints a notice instead of failing; update offline
with a copied tarball — `./taranac update --from taranac-bundle-<ver>.tar.gz`.
On an older bundle that has no `update` yet, copy `taranac` + `taranac-update.sh`
from the new bundle once, then it is self-maintaining.

(Take a backup from the in-app Backup & Recovery tools before upgrading.)

---

## 9. High Availability (Pro)

Run Taranac as a 2–4 node cluster — one read-write primary plus read-only
replicas, with automatic failover, where authentication keeps serving on every
node even while a failover happens. HA is a Pro feature (it needs an HA license)
and is layered on top of an existing single-node install with the bundled
`ha-convert.sh` / `ha-join.sh` scripts.

**The full deploy + operate runbook is [HA.md](HA.md).** Start there before
touching any HA setting.

---

## Troubleshooting

- **A service shows `unhealthy` in `./taranac ps`** — check its logs:
  `./taranac logs --tail=100 <service>`.
- **Browser keeps warning after step 6** — confirm `config/tls/tls.crt` is the
  full chain and the SAN matches your domain, then `./taranac restart edge`.
- **`docker ps` needs sudo** — you didn't start a new login shell after
  `bootstrap.sh`; log out/in or run `newgrp docker`.
