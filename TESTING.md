# Testing & Quality

Every Taranac release runs the **full** automated test suite — from unit through
sustained-rate load — on a dedicated CI runner before the images are published.

**Release 1.2.7 — 4706 passing, 0 failing:**

| Tier | What it proves | Passing |
|------|----------------|--------:|
| Unit + service + integration | pure logic, async DB (SAVEPOINT-isolated), full HTTP across domains | 4472 |
| End-to-end | real `tac_plus-ng` / FreeRADIUS / NAC daemons, live auth | 220 |
| Load | sustained-rate auth + config-reload under HA failover | 14 |
| **Total** | | **4706 passing** |

Backend line coverage: **81%**  ·  Run 2026-08-18  ·  commit-pinned  ·  dedicated runner.

_Eight end-to-end cases are tracked as expected-fail (documented known gaps), not
regressions — the suite reports zero unexpected failures. Nine time-window cases
skipped on this run: they build a cron window around the current hour, and in the
single 23:00-24:00 UTC hour the shape they need cannot be expressed at all. They
skip with that reason rather than assert a window that cannot hold._
