# Tools and Quality Gates

Return to the [README](../README.md).

## Quality Gates Policy

The commit-gate chain (`unified-commit-gate` → pre-commit → style → code review → language → IP audit) runs automatically on every `git commit` when hooks are installed. The IP audit blocks commits containing proprietary identifiers, internal hostnames, or credentials. If a push is blocked, run `bash tools/public-repo-ip-check.sh` to see exactly what matched; if it's a false positive, add an exception pattern to `.ip-patterns`.

The red-autonomy, internal-terms, and git-identity hooks write privacy-limited records to `~/.claude/hooks/hook-audit.log`. Run `python3 tools/hook-block-report.py` for fired-but-unadjudicated and unknown counts grouped by hook and exit code. A fired gate is not automatically a true positive; false-positive claims require local reproduction. Detailed output is local-only; commit timestamped aggregates only. See [Hook Block Audit](hook-block-audit.md) for the record format and review workflow.

**`git commit --no-verify` exists but bypassing gates is prohibited.** If a gate is genuinely broken, fix the gate; don't disable it. Changes to `skills/` additionally require a passing `code-review-battery` sentinel before the commit hook allows the commit. The sentinel format is `v1|SHA|VERDICT|TIMESTAMP|min-score=N`; write it only via `tools/run-battery.sh [--min-score N] --verdict PASS`. The primary slash command is `/sp-cr-battery`.

**Skill priority when installed and git-cloned versions coexist:** The agent runtime loads skills from `~/.codex/skills/` (installed copy). If you are developing new skills in the git clone, run `bash install.sh --upgrade` to sync the installed copy, or point `SUPERPOWERS_SKILLS_DIR` to the git checkout for live reloading (see `docs/ARCHITECTURE.md`). If `SUPERPOWERS_SKILLS_DIR` points to a nonexistent or incomplete directory the runtime falls back to `~/.codex/skills/`; verify with `node ~/.codex/superpowers-augment/superpowers-augment.js find-skills` after setting the variable.

> **Token budget:** A wiki-orchestrator pipeline (de-dup → content → coherence → links → secrets → slop → fact-check → publish) typically costs 30–50k tokens per edit. Run `bash tools/skill-cost-analyzer.sh` before scheduling bulk changes to estimate impact.
>
> **Compression:** Skills are compressed before injection via `lib/compress.js` (20–40% token reduction). Boilerplate sections (`When to Use`, `Examples`, etc.) are stripped. Operative content (`<EXTREMELY_IMPORTANT>` blocks, `Failure Modes`, `Incident Log`, `References`, `Hallucination Prevention`) is preserved unconditionally. Add `compress: false` to a skill's YAML frontmatter to opt out. See `docs/ARCHITECTURE.md § Skill Content Compression` for details.

## Tools

Utility scripts in `tools/`:

| Tool | Purpose |
|------|---------|
| `run-battery.sh` | Runs the automated quality suite (harsh-review, trigger tests, export integrity, skill router tests); writes the `.code-review-cleared` sentinel. Accepts `--verdict PASS\|PASS_WITH_NITS` and optional `--min-score N` (1.0–10.0, default 7.0). |
| `commit-gate.sh` | Runs lint/test/harsh-review and mints a short-lived review token consumed by the pre-commit hook. |
| `try-sentinel-fast-forward.sh` | Re-stamps an already-passed `.code-review-cleared`/`.phr-cleared` sentinel onto a new HEAD without a full re-review, but only for changes where every touched file is a registered mechanical fixture proven byte-for-byte reproducible from its generator. |
| `doctor-checks.sh` | 30-check diagnostic across all installed skills |
| `harsh-review.sh` | Enforces file endings, shebangs, syntax, ShellCheck |
| `harsh-review-loop.sh` | Iterative harsh review until clean |
| `dangerous-pattern-scan.sh` | Pre-commit scanner for `rm -rf`, `chmod 777`, `curl\|bash` |
| `install-hooks.sh` | Installs git hooks (pre-commit, pre-push) |
| `todo-preflight.sh` | Resolves `TODO_FILE_PATH` from `~/.codex/.env` |
| `todo-lock.sh` | Advisory file locking for TODO.md (cross-machine) |
| `todo-crud.sh` | TODO.md create/read/update/delete operations |
| `todo-maintenance.sh` | Archival and cleanup of completed tasks |
| `investigation-crud.sh` | Investigation state CRUD (hypotheses, evidence, verdicts) |
| `public-repo-ip-check.sh` | Scans for proprietary content before public push |
| `hook-block-report.py` | Reads one bounded tail across retained hook-audit generations and reports fired-but-unadjudicated and unknown events |
| `skill-trigger-validator.sh` | Audits trigger overlaps and missing triggers |
| `skill-cost-analyzer.sh` | Reports token cost per skill |
| `skill-size-audit.sh` | Context-budget sensor: ranks every `skill.md` by byte count, flags any over the fleet threshold |
| `skill-partitioner` | Kernel/reference actuator behind `kernel-split` |
| `measure-artifact-sizes.sh` | Context-budget regulator: measures always-on artifacts against `tests/harness/artifact-baselines.json` |
| `generate-skill-dag.js` | Generates skill dependency graph (Mermaid) |
| `skill-metrics-analyzer.sh` | Analyzes skill usage metrics |
| `router-precision.py` | Reports advisory-router hint rate, hints per prompt, precision, and automatic versus explicit skill invocation from bounded local JSONL parsing. See [Skill Router Precision](router-precision.md). |
| `parse-frontmatter.sh` | Extracts YAML frontmatter from skill files |
| `slop-check.sh` | Centralized AI slop gate -- blocking check for em-dash, boosters, buzzwords, and filler openers; advisory warnings for weak intensifiers and terms with a high false-positive rate in engineering prose. Shared by wiki, PHR, Linear, and recruiting paths. See `skills/writing/detecting-ai-slop/reference.md` for the pattern catalog. |
