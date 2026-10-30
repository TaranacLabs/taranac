# Testing & Quality

Every Taranac release runs the **full** automated test suite — from unit through
sustained-rate load — on a dedicated CI runner before the images are published.

**Release 1.3.4 — 11591 passing, 0 failing:**

| Tier | What it proves | Passing |
|------|----------------|--------:|
| Unit + service + integration | pure logic, async DB (SAVEPOINT-isolated), full HTTP across domains | 11211 |
| End-to-end | real `tac_plus-ng` / FreeRADIUS / NAC daemons, live auth | 360 |
| Load | sustained-rate auth on all three daemons, plus config reload and dynamic-client add while the load runs | 20 |
| **Total** | | **11591 passing** |

Backend line coverage: **90%**  ·  Run 2026-10-29  ·  commit-pinned  ·  dedicated runner.

High availability is tested, and not in this count. The steady state of a
cluster is covered by the suite above; its behaviour under a real failover is
covered by scenarios that need actual Patroni, etcd and a witness host, so they
run against a stand rather than on the release runner and their results are
recorded with the scenario. They are the reason the HA claims in `HA.md` are
made — but a number in the table above would say they had run here, and they
had not.

_Seven end-to-end cases are tracked as expected-fail (documented known gaps), not
regressions — the suite reports zero unexpected failures. Four cases skipped on this
run, each for a state the run did not have:

- Three TACACS+ port cases. They prove what happens before the first render and
  after a port change over an old config; a stack whose config already names the
  port has neither window.
- One AD CS CRL replay. It replays CRLs captured from a lab CA, and radiusd checks
  their dates against the real clock; the CI replay of the same sequence ran.

Two time-window cases can skip, and only in the UTC hours 22 and 23: they build a
cron window around the current hour that must still hold if the hour ticks over
mid-test, and in those two hours no window of the required shape can do that. They
ran on this run._
