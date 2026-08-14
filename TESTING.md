# Testing & Quality

Every Taranac release runs the **full** automated test suite — from unit through
sustained-rate load — on a dedicated CI runner before the images are published.

**Release 1.2.6 — 4561 passing, 0 failing:**

| Tier | What it proves | Passing |
|------|----------------|--------:|
| Unit + service + integration | pure logic, async DB (SAVEPOINT-isolated), full HTTP across domains | 4318 |
| End-to-end | real `tac_plus-ng` / FreeRADIUS / NAC daemons, live auth | 229 |
| Load | sustained-rate auth + config-reload under HA failover | 14 |
| **Total** | | **4561 passing** |

Backend line coverage: **80%**  ·  Run 2026-08-14  ·  commit-pinned  ·  dedicated runner.

_Eight end-to-end cases are tracked as expected-fail (documented known gaps), not
regressions — the suite reports zero unexpected failures._
