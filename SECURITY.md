# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities by email to **security@taranac.pro**.

Do not open a public GitHub issue, discussion or pull request for a suspected
vulnerability — that discloses it before a fix exists.

A useful report includes:

- the Taranac version (`./taranac version`, or the version shown in the web UI);
- the affected component — web UI / API, TACACS+, RADIUS, NAC (802.1X), captive
  portal, collector, MFA, installer or updater;
- steps to reproduce, with any configuration they depend on;
- what an attacker gains, and what access they need beforehand;
- whether you would like to be credited, and under which name.

## What happens next

| Step | Time |
|---|---|
| We confirm we received the report | within 7 business days |
| We assess it and tell you whether we consider it a vulnerability and how severe | within 14 days |
| Coordinated public disclosure | up to 90 days after the report, or earlier once a fixed release is out |

We keep you informed while the fix is in progress and agree the disclosure date
with you. If a fix needs longer than 90 days, we tell you why before that date.

## Disclosure and credit

Fixed vulnerabilities are listed under **Security** in the release notes
(CHANGELOG) of the release that fixes them. With your permission, we name you
there as the reporter.

There is no bug bounty.

## Supported versions

Security fixes are released for the latest minor version. Older versions are
fixed by updating to it.

## Good-faith research

We will not take action against research done in good faith under this policy:
testing only your own installation, not accessing or changing data that is not
yours, not degrading service for others, and giving us reasonable time to fix
the issue before disclosing it.
