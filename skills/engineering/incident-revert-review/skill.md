---
name: incident-revert-review
disable-model-invocation: true
source: superpowers-plus
augment_menu: true
triggers: ["review this revert", "reviewing a proposed revert", "should we revert this", "rollback this change", "what does this revert restore", "revert this incident fix"]
anti_triggers: ["revert a skill change", "undo a local edit", "verify a deployed fix", "git revert HEAD"]
description: Review a proposed incident revert for the protection it removes, the failure it may restore, and the adjacent path to check. Produce a read-only risk note before the change decision.
summary: "Use when: evaluating a proposed incident revert or rollback, on any branch or platform."
coordination:
  group: engineering
  order: 3
  requires: ["blast-radius-check"]
  enables: []
  escalates_to: ["systematic-debugging"]
  internal: false
composition:
  consumes: [incident-record, revert-diff]
  produces: [revert-risk-note]
  capabilities: [reviews-revert-risk, identifies-adjacent-paths]
  priority: 45
---

# Incident Revert Review

> **Wrong skill?** Scoping callers/consumers of touched code → `blast-radius-check`. Hotfix branch discipline (symptom, LOC budget, pre-commit verdict) → `hotfix-charter`. Root-causing the original bug → `systematic-debugging`.

Use for a proposed revert or rollback during an incident, whether the change is on a hotfix branch, an ordinary branch, or created directly in the hosting platform's UI. This review informs the change decision; it does not approve, merge, deploy, or block the change.

## Inputs

- The incident or issue, and the symptom users see that the revert is meant to stop.
- Proposed revert PR/MR, commit, or diff, plus the original change it reverses. If the proposed diff does not exist yet, use the stated target commit and label code impact **unverified**.
- Affected repo(s) and any available test or production evidence.

When the original change or the incident record is missing, say so instead of guessing what the change was for, and review only what the diff shows.

## Review

1. **Trace both sides of the change.** Read the original issue/PR and proposed reverse diff. State the original problem, the behavior the change added, and the behavior the revert would restore. Distinguish observed behavior from an inferred risk.
2. **Scope consumers and boundaries.** Apply `blast-radius-check` to touched functions, state transitions, configuration, and callers across affected repos. Inspect the path through the touched boundary before and after the change, including at least one path outside the symptom the revert intends to fix. Record what was searched and what remains unverified.
3. **Inspect change discipline.** If this repo uses a hotfix-branch convention gated by `hotfix-charter`, check for charter evidence and tell the change author to run its gate before commit if it is pending. The authoring hook cannot be run or inferred by this read-only review. For a UI-created or ordinary-branch revert, state the symptom, diff scope, and review/test evidence without claiming any charter ran.
4. **Compare the options.** State the likely impact of reverting and of leaving the current behavior in place. Identify any protection the revert removes, the failure it could restore, and at least one plausible adjacent path that could worsen. If no adjacent path can be identified from the sources, mark that gap **unknown**, not safe.
5. **Prepare verification.** Identify existing tests and the missing scenario, then name immediate checks for both the intended fix and the adjacent path. Name production signals, time windows, and denominators where available. Do not invent a traffic threshold or claim that a successful deploy proves recovery.

## Output: revert risk note

Keep the note short enough to link from the existing incident, PR/MR, or issue record. Render it for the requester; do not write to an external system unless separately asked.

| Row | What it must say |
|---|---|
| Sources | The incident or issue, the original change, and the revert diff or target commit; name any that could not be found |
| Intended outcome | Symptom the revert should resolve |
| What the revert takes away | The behavior the original change guarded, the evidence for it, and how sure that is |
| Adjacent path | Concrete scenario that could worsen, with the affected boundary |
| Revert vs. keep | The risk of each choice, each backed by evidence or marked as inference |
| Checks | Existing tests, missing test, target and adjacent verification steps, production signals and denominators |
| Still unknown | Evidence that is missing and the next check that would settle it |

Keep the decision owner and any later observation handoff in the authoritative incident record; this skill does not infer them.

## Failure Modes

| Failure | Symptom | Recovery |
|---------|---------|----------|
| Treating "deploy succeeded" as "incident resolved" | Risk note claims recovery with no production signal cited | Require a named metric, time window, and denominator before calling it resolved |
| Skipping the adjacent-path check | Risk note only covers the symptom path | Mark the adjacent-path row `unknown`, not safe, until a real scenario is named |
| Assuming the original change's intent from memory | Risk note states a motivation not found in the source issue/PR | Report the missing source explicitly and scope the review to what the diff shows |
| Claiming a hotfix charter ran when it did not | Charter-gated branch but no charter evidence available | State charter status as pending/unknown, not assumed-run |
