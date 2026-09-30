---
name: human-comms-hygiene
disable-model-invocation: true
source: superpowers-plus
augment_menu: true
triggers: ["/sp-human-comms", "write a commit message", "draft a commit message", "write a PR description", "draft a PR description", "write an issue", "draft an issue", "compose an issue", "prepare an issue", "revise an issue", "write a team message", "draft a team message"]
anti_triggers: ["implement a messaging service", "parse commit messages", "configure issue tracker", "write agent instructions"]
description: "Use when drafting or editing commit messages, PR/MR titles and descriptions, issue titles and comments, or team messages a person must act on."
summary: "Use when: writing commits, PRs, issues, comments, or team messages. Lead with the action or material change."
coordination:
  group: writing
  order: 0
  requires: []
  enables: ["eliminating-ai-slop"]
  escalates_to: []
  internal: false
composition:
  consumes: [markdown-content]
  produces: [quality-prose]
  capabilities: [guides-human-communication]
  priority: 36
---

# Human Comms Hygiene

## When to Use

Apply when composing or revising a commit, PR/MR, issue, issue comment, or
team message. This skill governs the draft; it does not authorize sending,
editing another person's text, committing, pushing, or merging.

Use the platform's native structure and repository conventions. Keep required
sections, disclosures, and evidence. This is not a general ban on technical
language, a substitute for factual verification, or a reason to hide mistakes.

## Process

1. Identify the reader, the material change, and any action you need from them.
2. Put the ask first when explicit; otherwise lead with the problem or change.
   A PR already asks for review; a commit needs no manufactured ask.
3. Add at most two context sentences before the detail. These are caps, not
   quotas: a one-line commit or message can be complete.
4. Put evidence, reproduction, observable validation, and material risks below.
   Preserve required templates; apply concision within each section.
5. Check every factual claim against its source. Keep uncertainty, limitations,
   relevant failures, and required disclosures. Do not invent a benefit or a
   metric to make the wording stronger.
6. Apply the checks below, then the format rules. See [examples.md](examples.md)
   for cases where superficially clean wording still fails.

## State What Changes for a Person

Pick a person and an action they can now take or stop having to take. Prefer
that consequence to a list of files, categories, or components. Ask whether
"so the reader can now ..." ends in an actual action rather than merely
"know", "see", or "understand" the text. Apply this to change claims in titles,
headings, and bullets, not to native labels such as "Test plan".

Use familiar terms. Do not make readers learn names coined in the work before
they can judge it. Technical vocabulary is appropriate when it is the reader's
vocabulary. If the work has no direct user benefit, state the maintenance work
plainly; do not dress an inventory up as an invented benefit.

## Put Customer Symptoms Before Causes

For defects reaching users, lead with what they experience: duplicate charges,
lost drafts, or calls ending unexpectedly. On a fix, say what stops happening.
For active incident triage, give known scale and onset in the opening or directly
below it. Label unknowns and suspected causes; never manufacture either.
Routine fix titles need not squeeze incident statistics into every subject.

If the message asks someone to act, keep the ask first and the customer symptom
next, before a component or suspected cause. Example: "Please take incident
ownership: customers cannot complete checkout; affected count is unknown."

## Separate Evidence from Process Narration

Do not justify a change with review-tool names, skill invocations, internal
gate files, review scores, commit accounting, or declarations that an agent
followed instructions. State the problem and observable behavior instead.
"Retries preserve the original request ID" is evidence about the change;
"review scored 9/10" is not. Keep review records in their existing check or
artifact locations and link them only when useful or required.

**Subject exception:** a tool, skill, or guidance file may be named when it is
what the work changes or discusses. "Fix code-review-battery's severity totals"
is valid; "Fix retries after code-review-battery passed" is narration. The
exception applies to the particular occurrence, not an entire repository,
line, or phrase. A product link naming a tool is also legitimate subject matter.
A mixed sentence can contain both a valid subject and invalid justification.

The lexical `scan-ai-process-refs` check reports candidates, not intent.
Review each match: rewrite narration; retain only independently justified
subject occurrences and record that disposition in local review evidence.
Do not call a nonzero lexical scan a clean scan or add a permanent phrase
exception. Unresolved matches block publication. Empty input is an error,
not a pass. File-read or pattern-loading errors also block publication, even
if they share the match exit code; an unsuccessful scan is not an empty list
of candidates. Profanity and factual-verification checks remain separate.

## Per Format

| Format | Required decisions |
|--------|--------------------|
| Commit | Match documented or clearly established human-authored conventions. Otherwise use `<type>(<scope>): <imperative change>` with optional scope and body. Sparse or bot-only history proves no convention. Use ticket trailers only when supported; close only fully resolved items. Never invent sign-offs or coauthors. |
| PR/MR | Title states the whole change. Body starts with the problem and resulting behavior, then only useful validation, rollout, and risks. Explain what the diff means. Refresh the summary when scope changes. Review verdicts are not test results. |
| Issue | For a defect, title states the observed symptom, not an unproven fix. Body gives symptom, impact, reproduction, acceptance criteria; label suspected causes. Feature/task issues describe the desired capability or maintenance need. Preserve tracker-required fields. |
| Comment | One substantive claim with its evidence. Edit repetitive status only if authorized and chronology remains unimportant; retain an explicit correction or new event when changing the record would mislead. Do not edit others' comments without authorization. |
| Team message | Usually lead with the ask, then brief context and usable links. Use absolute URLs for shared artifacts. Number steps only when order matters. A status-only update can be one sentence. |

Test plans state observed or expected behavior and distinguish what actually
ran from what remains planned. A real command, named test, or linked result
supports the statement; a review verdict does not substitute for it.

## Before Publication

Read the first line alone: is the action or material change apparent? Remove
preamble, repeated conclusions, coined shorthand, and detail that does not
affect the decision. Confirm claims and exceptions against evidence. Keep any
required risk, incident chronology, attribution, or disclosure even if it
makes the text longer. Neutral language must remain accurate.

## Companion Skills

- `eliminating-ai-slop`: prose cleanup and preservation of verified meaning.
- `detecting-ai-slop`: read-only prose analysis.
- `professional-language-audit`: profanity checks.
- `issue-authoring` and `issue-comment-debunker`: tracker operations and evidence.
- `unified-commit-gate`: commit and PR publication checks.

## Failure Modes

| Failure | Correction |
|---------|------------|
| A clear first line only lists components | State the consequence for a person, or honestly identify maintenance work. |
| A short subject invents certainty or customer impact | Restore the observed facts and label what is unknown. |
| Tooling repository exempts every process reference | Judge each occurrence; subject matter is allowed, self-congratulation is not. |
| Concision removes a required disclosure | Preserve it; the sentence cap applies only to introductory context. |
| Drafting is treated as permission to send | Obtain authorization from the user's task or the applicable publishing workflow. |
