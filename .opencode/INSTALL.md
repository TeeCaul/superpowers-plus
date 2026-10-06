# Installing Superpowers Plus for OpenCode

125 skills for engineering workflows, code review, wiki editing, issue tracking, security audits, and more. Extends [obra/superpowers](https://github.com/obra/superpowers); all 14 of its core workflow skills are bundled.

## Prerequisites

- [OpenCode.ai](https://opencode.ai) installed
- **bash 4+**: macOS ships bash 3.2; run `brew install bash` first
- **git**: macOS: `xcode-select --install`
- **Node.js 18+**: macOS: `brew install node`

## Installation

```bash
git clone https://github.com/bordenet/superpowers-plus.git ~/.codex/superpowers-plus
cd ~/.codex/superpowers-plus
bash install.sh
```

The installer automatically:

- Includes the 14 bundled obra/superpowers skills (no separate install)
- Deploys skills to `~/.codex/skills/` and `~/.claude/skills/`
- Sets up the bootstrap script and agent configuration
- Auto-fixes CRLF line endings on Windows/WSL

> **Windows/WSL:** Run from within WSL-Ubuntu, not Windows cmd/PowerShell.

### Restart OpenCode

Restart OpenCode after installation to discover the skills.

## Verify Installation

```bash
node ~/.codex/superpowers-augment/superpowers-augment.js find-skills
# Expected: the 125 superpowers-plus skills (14 bundled from obra/superpowers), plus any others installed
```

## Updating

```bash
cd ~/.codex/superpowers-plus
bash install.sh --upgrade
```

## Uninstalling

```bash
bash install.sh --uninstall
```

## What You Get

**From obra/superpowers (bundled):**

- brainstorming, writing-plans, executing-plans
- test-driven-development, systematic-debugging
- subagent-driven-development, using-git-worktrees
- 14 core workflow skills

**Added by superpowers-plus:**

- Wiki: wiki-orchestrator, wiki-verify, link-verification
- Issue Tracking: issue-authoring, issue-link-verification (GitHub and Jira adapters, plus a template for others)
- Security: secret-detection, public-repo-ip-audit
- Writing: AI slop detection, professional language audit
- Engineering: pre-commit gates, blast radius checks
- TODO management, archival, and maintenance

## Getting Help

- superpowers-plus: <https://github.com/bordenet/superpowers-plus/issues>
- obra/superpowers: <https://github.com/obra/superpowers/issues>
