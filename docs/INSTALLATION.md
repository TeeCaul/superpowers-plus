# Installation, Configuration, and Troubleshooting

Return to the [README](../README.md).

## Install

**Prerequisites:** bash 4+, git, Node.js 18+, Python 3. npm is only required for the optional MCP server below. On Windows, `install.ps1` installs these for you.

> **macOS note:** macOS ships bash 3.2 (frozen at GPLv2 since 2007). Install modern bash first: `brew install bash`. The installer will detect the old version and tell you exactly how to fix it.

### Choose Your Path

- **Most users:** core install below (`git clone` + `bash install.sh`)
- **Augment Agent only:** one-liner bootstrap for Ubuntu / Debian / WSL
- **Claude Code:** use `install.sh` for complete setup, or `/plugin install` for plugin-only mode
- **Windows without WSL:** `install.ps1` (full install under Git Bash; see [Windows (native)](#windows-native))
- **Codex:** see [Codex](#codex) below
- **OpenCode:** use the platform-specific instructions below
- **Claude Desktop:** the core install covers the Code tab and builds ZIPs to upload for the Chat and Cowork tabs; see [Claude Desktop](../README.md#claude-desktop)
- **Another MCP client:** do the core install first, then add the optional MCP server

### macOS / Linux / WSL

```bash
git clone https://github.com/bordenet/superpowers-plus.git
cd superpowers-plus
bash install.sh      # use 'bash' explicitly; macOS default shell is zsh; ./install.sh may pick the wrong interpreter
```

The installer:

- Detects wrong shell (sh, zsh, dash) and tells you to use bash
- Detects old bash (3.2) with platform-specific install instructions
- Checks for missing commands (git, node, python3) with remediation steps
- Auto-detects your platform and offers to install missing dependencies
- Auto-fixes Windows CRLF line endings if detected

**WSL:** Run the commands above from within WSL. If you cloned superpowers-plus on Windows *before* running the installer, repair line endings with: `bash tools/harsh-review.sh --fix`

### Windows (native)

On Windows, superpowers runs its bash hooks and scripts with Git Bash, the shell Claude Code also uses on Windows. No WSL is needed. Requires Windows PowerShell 5.1 or PowerShell 7 and winget.

```powershell
git clone https://github.com/bordenet/superpowers-plus.git $HOME\superpowers-plus
cd $HOME\superpowers-plus
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` does four things:

1. Installs missing prerequisites with winget: `Git.Git` (Git Bash), `OpenJS.NodeJS.LTS`, `Python.Python.3.12`, `jqlang.jq`. With `-NoPrereqInstall` it stops instead.
2. Writes `python3` (for Git Bash) and `python3.cmd` (for PowerShell and CMD) shims to `~\.local\bin` and puts that folder first on the user `PATH`. Python on Windows ships only `python.exe`, and the `python3` in `WindowsApps` opens the Microsoft Store.
3. Sets user environment variables `CLAUDE_CODE_GIT_BASH_PATH` (Git Bash path, read by Claude Code) and `PYTHONUTF8=1` (Windows Python otherwise reads files in the ANSI code page).
4. Runs `install.sh --yes` under Git Bash, which does the full install. `sp-*` commands are written as small wrapper scripts (usually to `~\.local\bin`), because Git Bash's `ln -s` makes copies.

Open a new terminal afterwards so the changes take effect. If WSL is also installed, `bash` typed in PowerShell starts WSL, because `C:\Windows\System32\bash.exe` comes first on the system `PATH`. To open Git Bash, use Git Bash from the Start menu or run `& $env:CLAUDE_CODE_GIT_BASH_PATH`. Claude Code is not affected.

Options: `-Categories <a,b>`, `-SkipAugment`, `-Force` (passed through as the matching `install.sh` flags), `-NoPrereqInstall`, `-SkillsOnly`, and `-Uninstall`. `-Force` (via `install.sh --force`) can run `git reset --hard origin/main` and `git clean -fd` in `~\.codex\superpowers-plus` if that checkout is ahead of or has diverged from `origin/main`. `-Uninstall` runs `uninstall.sh` under Git Bash and removes the `python3` shims; it installs nothing, and leaves the `~\.local\bin` PATH entry, `CLAUDE_CODE_GIT_BASH_PATH`, `PYTHONUTF8`, and winget packages in place. With `-SkillsOnly`, `-Categories` is not remembered between runs.

`-SkillsOnly` deploys skills with PowerShell only, with no Git Bash or other prerequisites. It writes the same locations and manifest as `install.sh`:

| Path | Contents |
|------|----------|
| `~\.codex\skills` | All skills plus `_shared` (Augment Agent) |
| `~\.claude\skills` | All skills plus `_shared` (Claude Code) |
| `~\.agents\skills` | Skills tagged `augment_menu: true`, as `SKILL.md` (Augment slash menu, Codex) |
| `~\.codex\superpowers-augment` | `superpowers-augment.js` and `lib/` |
| `~\.codex\superpowers-plus\install-state\skills.manifest` | Deployed skill names, used to prune removed skills on the next run |
| `~\.codex\.superpowers-ecosystem` | Which superpowers ecosystem owns this install (checked on every install; `-Force` overrides) |

With `-SkillsOnly`, lifecycle hooks, git gates, tools, rules, templates, and Claude Desktop ZIPs are not installed, and `-Uninstall` removes only what this table lists. On macOS and Linux, `install.ps1` runs `bash install.sh`.

**Linux containers (Docker/CI):** Works as root without sudo. The installer detects the environment automatically.

### Augment Agent (One-Liner: Ubuntu / Debian / WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/bordenet/superpowers-plus/main/install-augment-superpowers.sh | bash
```

> **Security note:** Review the script before piping: `curl -fsSL <url> | less`, then re-run with `| bash` once satisfied.

Sets up the Augment adapter and a skills directory. Does **not** install the full skill suite; use git clone above for that.

### Claude Code

```bash
/plugin install https://github.com/bordenet/superpowers-plus
```

Plugin mode installs skills only. For the complete setup with lifecycle hooks and git gates, use the `install.sh` path above.

When Claude Code lifecycle guardrails are enabled, the SessionStart hook bounds its local logs. It rotates `~/.claude/hooks/hook-audit.log` above 1 MiB and keeps `.1` and `.2`. The block reporter reads those retained generations with the live log as one bounded chronological window. It rotates the metrics file selected by `CLAUDE_SKILL_ROUTER_METRICS` above 5 MiB and keeps `.1`; the default is `~/.claude/hooks/skill-router-metrics.jsonl`. Rotation is best-effort: missing, unreadable, symlinked, or unexpected file entries do not stop a Claude Code session. A recent empty rotation lock is preserved, while an empty lock older than five minutes is reclaimed.

### Codex

Codex loads personal skills from `~/.agents/skills` ([Codex skills docs](https://developers.openai.com/codex/skills)). Both installers put the skills tagged `augment_menu: true` there.

```bash
git clone https://github.com/bordenet/superpowers-plus.git ~/.codex/superpowers-plus
cd ~/.codex/superpowers-plus
bash install.sh                                          # macOS / Linux / WSL
powershell -ExecutionPolicy Bypass -File .\install.ps1   # Windows, from PowerShell
```

Restart Codex, then run `/skills` or type `$` and a skill name (for example `$systematic-debugging`). Update with `git pull` and a re-run; remove with `bash install.sh --uninstall` or `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall`.

### OpenCode

```text
Fetch and follow instructions from https://raw.githubusercontent.com/bordenet/superpowers-plus/main/.opencode/INSTALL.md
```

### MCP Server (Optional)

After completing the core install above, you can optionally expose the installed skills over MCP.

Use this only if your client supports MCP and you want `superpowers-plus` skills exposed as MCP tools: `find_skills`, `use_skill`, and `match_skills`.

If you're using the install paths above without an MCP client, you can skip this section.

**Do I need this?**

- **No**: if you're using the CLI or one of the install methods above (git clone + bash)
- **Yes**: if you're using Claude Desktop or another MCP-compatible client and want the skills available as MCP tools
- **Yes**: if you're using Claude Code plugin and want skills exposed as tools (not just rules)

**Requires:** Node.js 18+. Verify: `node --version` (npm is bundled with Node.js; no separate install needed)

> **Security scope:** The MCP server communicates over stdio, not a network socket (see the `StdioServerTransport` import in `mcp/superpowers-mcp.js`); there is no port or bind address at all. It has no authentication of its own, so anything able to spawn the process gets the same file-read access it has.

1. `cd mcp && npm install`, then review `mcp/package-lock.json` for unexpected transitive dependencies before running in sensitive environments
2. Add this to your MCP client configuration. For Claude Code, run `claude mcp add` or put the block below in `~/.claude.json` (user scope) or a project's `.mcp.json`. Claude Code does not read `mcpServers` from `~/.claude/settings.json`. For Claude Desktop, put the same block in `claude_desktop_config.json`: `~/Library/Application Support/Claude/` on macOS, `%APPDATA%\Claude\` on Windows (for Linux, see [Claude Desktop on Linux](https://code.claude.com/docs/en/desktop-linux)). A server added there shows up in the Chat tab and in local Code tab sessions, but not in Cowork. The Code tab already has every skill natively, so the server mainly helps Chat. Other MCP clients use their own config file with the same block. Replace `/absolute/path/to/superpowers-plus` with the absolute path from `pwd` in your checkout (no trailing slash, no `~/` shorthand; use the full path):

   ```json
   {
     "mcpServers": {
       "superpowers-plus": {
         "command": "node",
         "args": ["/absolute/path/to/superpowers-plus/mcp/superpowers-mcp.js"]
       }
     }
   }
   ```

3. Restart your client. Verify: run `find_skills` in the MCP client. Expected output includes the 125 superpowers-plus skills, plus any other skills installed on the machine.

If `find_skills` returns an error or is missing: check `node --version` (must be 18+), rerun `cd mcp && npm install`, and confirm the args path is absolute (not `~/` or relative).

**Error responses:** `use_skill` and `match_skills` return `{ isError: true }` alongside a plain-text explanation for invalid input (missing/empty `skill_name` or `query`, or a `query` over 2000 characters) rather than throwing, so check `isError` before treating a tool result as skill content.

### Using as a Dependency

See [docs/examples/adopter-install-example.sh](examples/adopter-install-example.sh) for an install script template.

### Updating

```bash
bash install.sh --upgrade
```

### Verify Installation

After running `install.sh`, confirm skills loaded successfully:

```bash
node ~/.codex/superpowers-augment/superpowers-augment.js find-skills
# Expected: skill catalog printed without errors (superpowers-plus contributes 125 skills)
```

Run the full 30-check diagnostic:

```bash
bash tools/doctor-checks.sh
# Expected: "All 30 checks passed. Your superpowers are in perfect health."
```

If skills aren't loading, see [Troubleshooting](#troubleshooting).

## Configuration

**Data egress:** `PERPLEXITY_API_KEY` and `OPENAI_API_KEY` send context to external APIs, and any issue-tracker or wiki adapter credentials send content to those services when used. Check your data classification before enabling them in sensitive workflows. The core skills (`systematic-debugging`, `code-review-battery`, `feature-development`, `think-twice`, `verification-before-completion`) need no API keys or external integrations beyond your assistant and git.

Copy `.env.example` to `~/.codex/.env` for runtime integrations, then set permissions: `chmod 600 ~/.codex/.env`. All variables are optional unless noted. Invalid values for adapter keys cause runtime errors when those features are invoked; check `skills/issue-tracking/_adapters/` and `skills/wiki/_adapters/` for the list of valid values. If `~/.codex/.env` does not exist when a skill tries to read it, the skill will emit a `source: no such file` error. Run `bash tools/todo-preflight.sh --create-if-missing` to initialize it.

| Variable | Required? | Purpose |
|----------|-----------|---------|
| `ISSUE_TRACKER_TYPE` | Optional | Adapter key; shipped adapters: `github`, `jira`; see `skills/issue-tracking/_adapters/platform-template.md` for others |
| `WIKI_PLATFORM` | Optional | Adapter key; see `skills/wiki/_adapters/platform-template.md` to add yours |
| `TODO_FILE_PATH` | Optional | Path to your persistent TODO.md file; used by `todo-crud.sh` and all todo-management tools |
| `PERPLEXITY_API_KEY` | Optional | Enables deep research escalation (~$0.01/query); a stuck agent can trigger many queries, so monitor spend and disable in shared environments |
| `THINK_TWICE_USE_PERPLEXITY` | Optional | `false` by default; set `true` to let think-twice escalate to Perplexity when stuck |
| `OPENAI_API_KEY` | Optional | Enables embedding-based skill matching; TF-IDF runs without it (free but slower) |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `bash 3.2 is too old` | macOS Apple Silicon: `brew install bash`, then `/opt/homebrew/bin/bash install.sh`. Intel Mac: `/usr/local/bin/bash install.sh` |
| `This script requires bash` | You ran with sh or zsh. Use: `bash install.sh` |
| `Missing required commands: git` | macOS: `xcode-select --install`. Linux: `sudo apt install git` |
| `Missing required commands: node` | macOS: `brew install node`. Linux: `sudo apt install nodejs` |
| Install partially failed | Run `bash install.sh --verbose` to see which step failed; then `bash tools/doctor-checks.sh` for full diagnosis. Re-running `bash install.sh` is safe: it skips already-completed steps. |
| `.env missing / source error` | Run `bash tools/todo-preflight.sh --create-if-missing` to initialize `~/.codex/.env` from `.env.example`. Then `chmod 600 ~/.codex/.env`. |
| Perplexity tools not found | Verify `PERPLEXITY_API_KEY` in `~/.codex/.env`, then run `bash setup/mcp-perplexity.sh` |
| Issue tracking fails | Set `ISSUE_TRACKER_TYPE` in `.env`; verify adapter exists in `skills/issue-tracking/_adapters/` |
| Wiki operations fail | Set `WIKI_PLATFORM` in `.env`; verify adapter exists in `skills/wiki/_adapters/` |
| Push blocked by IP audit | Run `bash tools/public-repo-ip-check.sh` to see what matched; if a false positive, add an exception pattern to `.ip-patterns` |
| CRLF errors on WSL | Cloned on Windows before running installer: `bash tools/harsh-review.sh --fix` |
| Skills not loading | Run `bash tools/doctor-checks.sh` to diagnose; then `bash install.sh --upgrade` if checks fail |
| Stale skill count | `bash install.sh --upgrade`; verify with `node ... find-skills`; the catalog should print without errors |
| TODO lock timeout | Another agent holds the lock; `todo-lock.sh steal` |
| Doctor reports drift | `bash tools/doctor-checks.sh --fix-safe` |
