# Taranac — deployment

Network access control (TACACS+ / RADIUS / 802.1X) with a web UI. This directory
is everything you need to run Taranac from published Docker images — no source.

**Full step-by-step runbook: [INSTALL.md](INSTALL.md).** Quick version below.

## Requirements

- A Linux host (Ubuntu 22.04/24.04 LTS), ≥4 cores, ≥6 GB RAM, ≥20 GB free disk
- A non-root user with `sudo`
- Open inbound ports: **443** (UI/API), plus the AAA/NAC service ports you use
  (TACACS `49`, RADIUS `1812/1813`, NAC `1814/1815`, CoA `3799`)

## Install

```bash
sudo bash bootstrap.sh   # installs Docker + compose if missing (skip if present)
                         # then log out/in so the docker group applies
./install.sh             # configures + starts Taranac
```

`install.sh` asks for your domain and admin details, **generates every secret**,
writes `.env`, pulls the images and starts the stack. At the end it prints the
admin login. Re-running `./install.sh` later is the **upgrade** path — it never
regenerates secrets, just pulls and restarts.

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
| `postgres`       | Database                                          |
