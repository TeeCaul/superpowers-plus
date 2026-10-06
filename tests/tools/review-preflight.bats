#!/usr/bin/env bats
# review-preflight.bats -- tests for tools/review-preflight.py
#
# Each test builds a throwaway repo with a "main" base commit and a feature
# branch, then reads fields out of the preflight JSON with a small jq-free
# python helper (q). The last test keeps the script's signal table in step with
# the "Signal-driven dispatch" table in code-review-battery/skill.md.
#
# RUN: bats tests/tools/review-preflight.bats

bats_require_minimum_version 1.5.0

setup() {
  # Fixtures must not depend on the developer's git config (commit.gpgsign,
  # diff.noprefix, init.defaultBranch, identity).
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  TOOL="$REPO_ROOT/tools/review-preflight.py"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q -b main
  git config user.email t@example.com
  git config user.name t
  printf 'base\n' > README.md
  git add README.md
  git commit -qm base
  git checkout -qb feat/thing
}

commit_file() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; git add "$1"; git commit -qm "add $1"; }

# q EXPR: evaluate a python expression over the preflight JSON bound to d
q() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$BATS_TEST_TMPDIR/out.json"; }

preflight() { "$TOOL" --base main "$@" > "$BATS_TEST_TMPDIR/out.json"; }

fired() { q "' '.join(r['id'] for r in d['reviewers'] if r['kind'] != 'base')"; }

@test "help prints usage" {
  run "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "missing base ref is a usage error" {
  run "$TOOL" --base nope/nothing
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
}

@test "sentinel missing" {
  commit_file lib/a.js 'const x = 1;\n'
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "missing" ]
}

@test "sentinel valid for HEAD" {
  commit_file lib/a.js 'const x = 1;\n'
  echo "v1|$(git rev-parse HEAD)|PASS|2026-10-05T00:00:00Z" > .code-review-cleared
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "valid" ]
}

@test "sentinel stale after an in-scope change" {
  commit_file lib/a.js 'const x = 1;\n'
  echo "v1|$(git rev-parse HEAD)|PASS|2026-10-05T00:00:00Z" > .code-review-cleared
  commit_file lib/a.js 'const x = 2;\n'
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "stale" ]
  [[ "$(q "d['sentinels']['.code-review-cleared']['detail']")" == *"lib/a.js"* ]]
}

@test "sentinel carried when only out-of-scope files changed" {
  commit_file lib/a.js 'const x = 1;\n'
  echo "v1|$(git rev-parse HEAD)|PASS|2026-10-05T00:00:00Z" > .code-review-cleared
  commit_file NOTES.txt 'just notes\n'
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "valid" ]
  [ "$(q "d['sentinels']['.code-review-cleared'].get('carried')")" = "True" ]
}

@test "sentinel malformed" {
  commit_file lib/a.js 'const x = 1;\n'
  printf 'garbage\nmore\n' > .phr-cleared
  echo "v1|$(git rev-parse HEAD)|PASS|ts|mean=9|x|y" > .llm-skill-review-cleared
  preflight
  [ "$(q "d['sentinels']['.phr-cleared']['state']")" = "malformed" ]
  [ "$(q "d['sentinels']['.llm-skill-review-cleared']['state']")" = "malformed" ]
}

@test "bug-fix branch detection" {
  git checkout -qb fix/PROJ-12-null-check
  commit_file lib/a.js 'const x = 1;\n'
  preflight
  [ "$(q "d['bugfix_mode']")" = "True" ]
  [[ "$(q "d['dispatch']['extra_agents']")" == *"BugPath Verifier"* ]]
  [ "$(q "d['inline_exemption_eligible']")" = "False" ]
}

@test "feature branch is not bug-fix mode" {
  commit_file lib/a.js 'const x = 1;\n'
  preflight
  [ "$(q "d['bugfix_mode']")" = "False" ]
}

@test "shell wrapper signal adds ShellRuntimeAuditor" {
  commit_file tools/wrap.sh '#!/usr/bin/env bash\nset -euo pipefail\nmytool --flag || exit $?\n'
  preflight
  [[ " $(fired) " == *" shell "* ]]
  [[ "$(q "d['dispatch']['extra_agents']")" == *"ShellRuntimeAuditor"* ]]
}

@test "extensionless file with a shell shebang is shell content" {
  commit_file tools/hook '#!/bin/sh\necho hi\n'
  preflight
  [[ "$(q "[r for r in d['reviewers'] if r['id']=='shell'][0]['hits']")" == *"tools/hook (shell file)"* ]]
}

@test "retry logic forces Guardian and blocks the inline exemption" {
  commit_file lib/client.js 'function call() {\n  return withRetry(send, { retries: 3 });\n}\n'
  preflight
  [[ " $(fired) " == *" guardian-mandatory "* ]]
  [[ "$(q "[r for r in d['reviewers'] if r['id']=='guardian-mandatory'][0]['hits']")" == *"lib/client.js:2"* ]]
  [ "$(q "d['inline_exemption_eligible']")" = "False" ]
  [[ "$(q "d['inline_exemption_reasons']")" == *"guardian-mandatory"* ]]
}

@test "docs-only diff gets Standards Enforcer only and no regex signals" {
  commit_file docs/guide.md '# Guide\nWe retry with backoff and store the session token.\n'
  preflight
  [ "$(q "d['diff']['change_class']")" = "docs-only" ]
  [ "$(q "d['reviewers'][0]['reviewers']")" = "['Standards Enforcer']" ]
  [ -z "$(fired)" ]
  [ "$(q "d['dispatch']['combined_reviewer']")" = "False" ]
  [ "$(q "d['judgment_required']")" = "[]" ]
  [[ "$(q "[b.get('skill') for b in d['routes']['blocks']]")" == *"progressive-harsh-review"* ]]
}

@test "inline exemption true for a small, signal-free change" {
  commit_file lib/math.js 'function add(a, b) {\n  return a + b;\n}\n'
  preflight
  [ "$(q "d['inline_exemption_eligible']")" = "True" ]
  [ "$(q "d['diff']['size_class']")" = "small" ]
}

@test "inline exemption false when the diff is too big" {
  mkdir -p lib
  python3 -c 'print("\n".join("const v%d = %d;" % (i, i) for i in range(200)))' > lib/big.js
  git add lib/big.js && git commit -qm big
  preflight
  [ "$(q "d['inline_exemption_eligible']")" = "False" ]
  [[ "$(q "d['inline_exemption_reasons']")" == *"changed lines > 150"* ]]
}

@test "--staged reviews the index, not the branch" {
  commit_file lib/a.js 'const x = 1;\n'
  printf 'try {\n  go();\n} catch (e) {}\n' > lib/b.js
  git add lib/b.js
  "$TOOL" --staged > "$BATS_TEST_TMPDIR/out.json"
  [ "$(q "d['mode']")" = "staged" ]
  [ "$(q "[f['path'] for f in d['diff']['files']]")" = "['lib/b.js']" ]
  [[ " $(fired) " == *" try-catch "* ]]
  [ "$(q "d['worktree_clean']")" = "False" ]
}

@test "rename is reported with its old path" {
  commit_file lib/old.js 'module.exports = 1;\n'
  git checkout -q main && git merge -q --ff-only feat/thing && git checkout -q feat/thing
  git mv lib/old.js lib/new.js && git commit -qm mv
  preflight
  [[ "$(q "[r for r in d['reviewers'] if r['id']=='rename-delete'][0]['hits']")" == *"lib/old.js (renamed)"* ]]
}

@test "sentinel whose verdict does not clear its gate is not-clearing" {
  commit_file lib/a.js 'const x = 1;\n'
  H=$(git rev-parse HEAD)
  echo "v1|$H|REJECT|2026-10-05T00:00:00Z" > .code-review-cleared
  echo "v2|$H|PASS|ts|mean=9|unresolved_s0_s1=3|evidence_replay=ok" > .llm-skill-review-cleared
  echo "v1|$H|PASS||" > .phr-cleared
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "not-clearing" ]
  [ "$(q "d['sentinels']['.llm-skill-review-cleared']['state']")" = "malformed" ]
  [ "$(q "d['sentinels']['.phr-cleared']['state']")" = "malformed" ]
}

@test "unpromoted tree: sentinel is stale for the branch, valid for a matching index" {
  commit_file lib/a.js 'const x = 1;\n'
  printf 'const y = 2;\n' > lib/b.js
  git add lib/b.js
  echo "v1|tree:$(git write-tree)|PASS|2026-10-05T00:00:00Z" > .code-review-cleared
  "$TOOL" --staged > "$BATS_TEST_TMPDIR/out.json"
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "valid" ]
  git commit -qm b
  preflight
  [ "$(q "d['sentinels']['.code-review-cleared']['state']")" = "stale" ]
}

@test "non-UTF-8 content and binary files do not crash the parser" {
  printf '<cfset name = "caf\xe9">\n' > page.cfm
  printf 'a\0b' > blob.bin
  git add page.cfm blob.bin && git commit -qm enc
  preflight
  [ "$(q "sorted(f['path'] for f in d['diff']['files'])")" = "['blob.bin', 'page.cfm']" ]
}

@test "paths with spaces and non-ASCII names are scanned under their real names" {
  printf 'retry auth token\n' > "my notes.md"
  printf 'const password = 1;\n' > café.js
  git add . && git commit -qm names
  preflight
  [ "$(q "d['diff']['change_class']")" = "code" ]
  hits="$(q "[h for r in d['reviewers'] if r['kind'] != 'base' for h in r['hits']]")"
  [[ "$hits" == *"café.js:1"* ]]
  [[ "$hits" != *"my notes"* ]]
}

@test "user diff config cannot hide added lines" {
  commit_file lib/client.js 'retry();\n'
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=diff.external GIT_CONFIG_VALUE_1=/usr/bin/true preflight
  [[ " $(fired) " == *" guardian-mandatory "* ]]
}

@test "a leaked GIT_DIR does not redirect the preflight to another repo" {
  commit_file lib/a.js 'const x = 1;\n'
  other="$BATS_TEST_TMPDIR/other"
  git init -q -b main "$other"
  git -C "$other" commit -q --allow-empty -m other
  GIT_DIR="$other/.git" preflight
  [ "$(q "d['head']")" = "$(git rev-parse HEAD)" ]
}

@test "an added line starting with ++ is content, not a file header" {
  commit_file lib/a.js '++ counter\nretry();\n'
  preflight
  [[ " $(fired) " == *" guardian-mandatory "* ]]
}

@test "bug-fix detection follows the runner's ticket prefix allowlist" {
  git checkout -qb fix/ACME-12-x
  commit_file lib/a.js 'const x = 1;\n'
  preflight
  [ "$(q "d['bugfix_mode']")" = "False" ]
  git checkout -q main && printf 'ACME\n' > .cr-battery-ticket-prefixes && git add . && git commit -qm p
  git checkout -q fix/ACME-12-x && git rebase -q main
  preflight
  [ "$(q "d['bugfix_mode']")" = "True" ]
}

@test "--mode overrides branch detection; --base with --staged is refused" {
  git checkout -qb hotfix/x
  commit_file lib/a.js 'const x = 1;\n'
  preflight --mode feature
  [ "$(q "d['bugfix_mode']")" = "False" ]
  preflight --mode bug-fix
  [ "$(q "d['bugfix_mode']")" = "True" ]
  run "$TOOL" --base main --staged
  [ "$status" -eq 2 ]
  run "$TOOL" --base main --mode other
  [ "$status" -eq 2 ]
}

@test "removals in a deleted code file keep the caller-removal judgment row" {
  commit_file use.js 'only();\n'
  git checkout -q main && git merge -q --ff-only feat/thing && git checkout -q feat/thing
  git rm -q use.js && git commit -qm rm
  preflight
  [[ "$(q "[j['id'] for j in d['judgment_required']]")" == *"caller-removal"* ]]
}

@test "every row of the skill's signal table has exactly one encoded entry" {
  skill="$REPO_ROOT/skills/engineering/code-review-battery/skill.md"
  "$TOOL" --list-signals > "$BATS_TEST_TMPDIR/signals.json"
  run python3 - "$skill" "$BATS_TEST_TMPDIR/signals.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("**Signal-driven dispatch**")
rows = []
for line in text[start:].splitlines()[1:]:
    if rows and not line.startswith("|"):
        break
    if line.startswith("| ") and "Diff signal" not in line:
        rows.append(line.split(" | ")[0])
keys = [s["row"] for s in json.load(open(sys.argv[2]))["signals"]]
bad = [r[:60] for r in rows if sum(k in r for k in keys) != 1]
unused = [k for k in keys if not any(k in r for r in rows)]
print("rows=%d keys=%d bad=%s unused=%s" % (len(rows), len(keys), bad, unused))
sys.exit(1 if bad or unused or len(rows) != len(keys) else 0)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}
