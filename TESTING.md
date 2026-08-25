# Testing & Quality

Every Taranac release runs the **full** automated test suite — from unit through
sustained-rate load — on a dedicated CI runner before the images are published.

**Release 1.2.8 — 5067 passing, 0 failing:**

| Tier | What it proves | Passing |
|------|----------------|--------:|
| Unit + service + integration | pure logic, async DB (SAVEPOINT-isolated), full HTTP across domains | 4820 |
| End-to-end | real `tac_plus-ng` / FreeRADIUS / NAC daemons, live auth | 233 |
| Load | sustained-rate auth on all three daemons, plus config reload and dynamic-client add while the load runs | 14 |
| **Total** | | **5067 passing** |

Backend line coverage: **81%**  ·  Run 2026-08-25  ·  commit-pinned  ·  dedicated runner.

High availability is tested, and not in this count. The steady state of a
cluster is covered by the suite above; its behaviour under a real failover is
covered by scenarios that need actual Patroni, etcd and a witness host, so they
run against a stand rather than on the release runner and their results are
recorded with the scenario. They are the reason the HA claims in `HA.md` are
made — but a number in the table above would say they had run here, and they
had not.

_Eight end-to-end cases are tracked as expected-fail (documented known gaps), not
regressions — the suite reports zero unexpected failures. Nothing skipped on this
run. Four time-window cases can skip, and only in the UTC hours 22 and 23: they
build a cron window around the current hour that must still hold if the hour ticks
over mid-test, and in those two hours no window of the required shape can do that.
They skip with that reason rather than assert a window that cannot hold._
