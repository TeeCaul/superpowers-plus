#!/usr/bin/env bats
# The staging branch was retired in October 2026 (it only passed content
# through to main). Branch lists, candidate-ref chains, allowlists, and docs
# must not name it. Historical records and unrelated uses of the word
# (staging environments, staged files) are allowed.

@test "no live references to the retired staging branch" {
    cd "$BATS_TEST_DIRNAME/.."
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git checkout"
    run bash -c "git grep -nE '(origin|upstream|remote_name)/staging|dev[|/]staging|staging[|/]main|staging -> main|staging → main|\\[main, staging|== .staging.' -- . \
        ':!CHANGELOG.md' ':!test/retired-staging-references.bats' ':!test/promotion-strict-toggle.bats' \
        ':!docs/maintainers/TODO.md' ':!.ai-guidance/promotion-strict-behind-runbook.md' ':!AGENTS.md'"
    [ -z "$output" ] || { echo "$output"; return 1; }
}
