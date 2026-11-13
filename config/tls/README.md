# Public TLS certificate

Drop your own CA-signed certificate here so browsers and phones trust Taranac.
There is no Let's Encrypt automation — bring your own (commercial CA, your org's
internal CA, or a manually-issued ACME cert).

Two files, exactly these names:

| File      | Contents                                                        |
|-----------|-----------------------------------------------------------------|
| `tls.crt` | Full chain: your server certificate **followed by** any intermediates |
| `tls.key` | The matching private key (unencrypted PEM)                      |

The certificate's SAN must cover `TARANAC_DOMAIN`, every address listed in
`TARANAC_EXTRA_ADDRESSES`, and `TARANAC_MFA_DOMAIN` if set.

**An IP address must appear as an `IP:` SAN, not `DNS:`.** Browsers are lax about
this and will merely warn; standalone collectors and captive portals verify
strictly and will refuse to connect. Most public CAs do not issue certificates
for IP addresses at all — if this node is reached by IP as well as by name, that
is what `TARANAC_EXTRA_ADDRESSES` and an internal CA are for. Edge logs a warning
at startup naming any address your certificate does not cover.

Apply after dropping the files:

```bash
docker compose -f docker-compose.yml --env-file .env restart edge
```

If these files are absent, the edge proxy generates a **temporary self-signed**
certificate so the stack still boots — browsers will warn until you add a real one.
