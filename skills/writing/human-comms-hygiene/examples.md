# Human Comms Examples

These are hypothetical examples, not measurements or incidents from a real organization.

| Draft | Assessment | Better wording or reason |
|-------|------------|--------------------------|
| Adds three categories and five handlers | Inventory presented as benefit | Maintainers can register a handler without editing the router. Use only if the change actually enables this. |
| Robust checkout after adversarial review | Unsupported quality and process justification | Prevent duplicate charges when checkout retries. |
| Please investigate: customers are charged twice after retrying checkout; affected count unknown | Pass for an incident ask | Ask, user symptom, and uncertainty are visible. Add onset when known or say it is unknown. |
| Scheduler returns 500 | Insufficient customer context for a customer incident | Customers cannot reserve appointments; the scheduler returns 500. |
| chore: refresh generated dependency metadata | Pass | Honest maintenance description; no invented customer benefit. |
| feat(code-review-battery): report unresolved findings | Pass | The tool is the subject. |
| Fix code-review-battery totals; battery PASS proves it is correct | Mixed | Keep the subject; replace the verdict with an actual test result. |
| See the superpowers-plus project for installation instructions | Pass | A relevant product reference, including in another repository. |
| Confirmed fixed everywhere | Unsupported | State the tested scenario and disclose what remains untested. |
| Rewrite yesterday's incident comment to remove the incorrect claim | Do not erase chronology | Post or preserve an explicit correction with evidence. |
| Test plan: review scored 9.5/10 | Not behavior validation | Retrying the same request creates one order; named regression test passed. |

## Trigger checks

`node test/human-comms-routing.test.js` loads repository frontmatter and checks
20 top-five positive cases: write/draft/compose/prepare/revise a commit message, PR
description, issue, or team message. It also checks for exact trigger/alias
collisions and rejects four near misses: implement a messaging service, parse
commit messages, configure issue tracker, and write agent instructions.

These assertions prove inclusion in the top five router candidates, not
first-place selection or invocation on every assistant platform. Explicit invocation and
the references from the publishing skills remain available.
