# Firebase service-account key (optional — MFA push tier)

Without a key, the MFA service runs in **free poll-only mode**: the mobile app
periodically checks for pending approvals. No Firebase, no setup — works out of
the box.

To enable **instant push** (paid tier), drop your Firebase service-account JSON
here as:

```
firebase-credentials.json
```

Then restart the MFA service:

```bash
docker compose -f docker-compose.yml --env-file .env up -d taranac-mfa
```

The key is mounted read-only. Keep it secret and never commit it. Use a
least-privilege service account (FCM send only) and rotate it periodically.
