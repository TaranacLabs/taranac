# Testing & Quality

Every Taranac release runs the **full** automated test suite — from unit through
sustained-rate load — on a dedicated CI runner before the images are published.

**Release 1.1.0 — 2921 passing, 0 failing:**

| Tier | What it proves | Passing |
|------|----------------|--------:|
| Unit + service + integration | pure logic, async DB (SAVEPOINT-isolated), full HTTP across domains | 2718 |
| End-to-end | real `tac_plus-ng` / FreeRADIUS / NAC daemons, live auth | 189 |
| Load | sustained-rate auth + config-reload under HA failover | 14 |
| **Total** | | **2921 passing** |

Backend line coverage: **77%**  ·  Run 2026-07-17  ·  commit-pinned  ·  dedicated runner.

_Nine end-to-end cases are tracked as expected-fail (documented known gaps), not
regressions — the suite reports zero unexpected failures._
