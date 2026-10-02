# Selective upstream review — October 1, 2026

Reviewed [obra/superpowers](https://github.com/obra/superpowers) at released
`8ca22dba` (v6.4.2) and development tip `b1f87747`. Our last selective import
was v6.3.0 (`bc453974`); this review compares current implementations, not
commit ancestry alone. Upstream releases squash development history.

## Selected changes

| Upstream change | Decision and local destination |
|---|---|
| [Leaner plans #2333](https://github.com/obra/superpowers/commit/71069323) | Adapt in `writing-plans`: exact interfaces, assertions, and constraints instead of whole implementations; proportional self-review. Preserve our frontmatter and review gates. |
| [Saved-plan review #2258](https://github.com/obra/superpowers/commit/069edf3f) | Adapt the planning handoff and executor: distinguish approval of a saved plan from approval of an unseen idea; retain existing scoped user authorization. |
| [Review implied inputs #2319](https://github.com/obra/superpowers/commit/7474980b) | Add Review Focus to plans and require reviewers to report behavior they declined to judge. Preserve bounded review scope and controller adjudication. |
| [Full-suite GREEN #2110](https://github.com/obra/superpowers/commit/a45ede8d) | Adapt our condensed TDD skill: the project's documented suite defines green, with each failure named. |
| [Workspace ownership #2138](https://github.com/obra/superpowers/commit/6692bd28) | Port ownership markers and deterministic basename disambiguation. Keep the existing ledger identity check for legacy workspaces. |
| [Physical root paths](https://github.com/obra/superpowers/commit/2b7893a1) | Port path normalization so plan ownership uses the same physical spelling as the repository root. |
| [Preserve shared ignore rules #2399](https://github.com/obra/superpowers/commit/19e54c09) | Port create-only `.gitignore` behavior. |
| [Nonempty descendant review ranges #2136](https://github.com/obra/superpowers/commit/99f9f008) | Port range rejection before writing review output. |
| [Helpers without executable bits #2040](https://github.com/obra/superpowers/commit/0be49879) | Port explicit Bash invocation in helper callers and execution guidance. |
| [Literal rendering tokens #2364](https://github.com/obra/superpowers/commit/ddd35ab1) | Port callback replacement in the visual companion so supplied `$&`, `$$`, and related text survives rendering. |
| [Native execution #2318](https://github.com/obra/superpowers/commit/2b89c4c3) | Adapt the execution choice and preserve our current executor and required gates. Do not import a second task ledger/helper subsystem. |

## Changes not imported

| Change | Reason |
|---|---|
| Transcript diagnosis subsystem | Overlaps our failure-autopsy and session tooling but adds transcript collection and redaction interfaces. It needs a separate design and privacy review; no diagnosis skill or transcript collector was copied. |
| New OpenCode, Muse, Devin, Hermes and marketplace adapters | Our installer and native-discovery conventions differ. No matching adapter implementation is changed in this port. |
| Windows hook launcher and PATH lookup fixes | Upstream's `run-hook.cmd` launcher is absent here. Copying it would add a platform interface rather than fix an existing caller. |
| Debugging identity-secret example fix | The unsafe upstream `IDENTITY` diagnostic example is absent from our condensed debugging skill and companions. |
| Remove `CLAUDE.md` | Ours contains project-specific rules and is required by current CI. It is not upstream's obsolete one-line pointer. |
| Code-review positional argument workaround/base SHA example | Our requesting-code-review skill delegates to our review battery and does not contain the affected upstream SHA example. |
| Remove unused plan reviewer prompt | Retain our optional template for compatibility; the writing skill's self-review does not dispatch it. |
| Explicit dispatch-model and plan-checkbox feature branches | Unmerged upstream proposals were inspected as context, not treated as released changes to copy. Native execution now records checked steps; existing model-selection rules remain. |

## Verification scope

Behavior tests exercise workspace ownership, basename collisions, ignore-policy
preservation, invalid review ranges, non-executable helpers, and literal HTML
through the running local server. Regression failures were observed before the
fixes. Planning and reviewer prose requires independent skill review; structural
checks alone do not establish that an agent follows the instructions.

Independent review also found an upstream error-handling defect: failed
workspace creation or owner-marker I/O could be mistaken for a collision and
loop indefinitely. The adapted helper exits explicitly on those errors, with
a blocked-parent regression test. Ownership selection is also serialized with
a bounded workspace lock so concurrent plans cannot claim the same directory.
If a helper is killed without cleanup, verify no helper is active before removing
the named stale lock; automatic deletion could disrupt a live caller.

No upstream claimed time/token savings are asserted for this adapted port.
The exact installed behavior is not verified by source tests; this change does
not modify installed copies or add automatic installation.
