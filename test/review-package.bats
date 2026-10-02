#!/usr/bin/env bats

# Behavioral tests for skills/engineering/subagent-driven-development/scripts/review-package.
# Covers the plan-scoped-workspace port: review-package now takes PLAN_FILE
# as its first argument (before the pre-existing BASE HEAD [OUTFILE]) and
# passes it through to sdd-workspace, so its default OUTFILE lands under the
# plan-scoped dir (.superpowers/sdd/<plan-basename>/review-<base7>..<head7>.diff).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/engineering/subagent-driven-development/scripts/review-package"

setup() {
    # Physical path up front -- see sdd-workspace.bats for why (macOS
    # /var/folders symlink vs `git rev-parse --show-toplevel`'s physical
    # output).
    SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
    mkdir -p "$SANDBOX"
    cd "$SANDBOX"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "# plan" > plan.md
    git add plan.md
    git commit -qm "seed"
}

@test "review-package: old 2-arg form (missing PLAN_FILE) -> exit 2 with usage message" {
    run bash "$SCRIPT" HEAD~1 HEAD
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: review-package PLAN_FILE BASE HEAD"* ]]
}

@test "review-package: 0 args -> exit 2 with usage message" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: review-package PLAN_FILE BASE HEAD"* ]]
}

@test "review-package: nonexistent plan file -> exit 2, error mentions the path" {
    run bash "$SCRIPT" nope.md HEAD~1 HEAD
    [ "$status" -eq 2 ]
    [[ "$output" == *"no such plan file: nope.md"* ]]
}

@test "review-package: PLAN_FILE BASE HEAD (valid, two real commits) writes the diff under the plan-scoped dir" {
    echo one > f.txt
    git add f.txt
    git commit -qm "commit1"
    echo two >> f.txt
    git add f.txt
    git commit -qm "commit2"

    run bash "$SCRIPT" plan.md HEAD~1 HEAD
    [ "$status" -eq 0 ]

    base_sha="$(git rev-parse --short HEAD~1)"
    head_sha="$(git rev-parse --short HEAD)"
    expected="$SANDBOX/.superpowers/sdd/plan/review-${base_sha}..${head_sha}.diff"

    [[ "$output" == "wrote ${expected}: 1 commit(s),"* ]]
    [ -f "$expected" ]
    [[ "$(cat "$expected")" == *"## Commits"* ]]
    [[ "$(cat "$expected")" == *"commit2"* ]]
    [[ "$(cat "$expected")" == *"+two"* ]]
}

@test "review-package: empty range is rejected without creating an output" {
    run bash "$SCRIPT" plan.md HEAD HEAD output.diff
    [ "$status" -eq 3 ]
    [[ "$output" == *"empty commit range"* ]]
    [ ! -e output.diff ]
}

@test "review-package: divergent head is rejected without overwriting output" {
    git checkout -qb other
    echo other > other.txt; git add other.txt; git commit -qm other
    other=$(git rev-parse HEAD)
    git checkout -q main
    echo main > main.txt; git add main.txt; git commit -qm main
    echo preserve > output.diff
    run bash "$SCRIPT" plan.md HEAD "$other" output.diff
    [ "$status" -eq 3 ]
    [[ "$output" == *"not a descendant"* ]]
    [ "$(cat output.diff)" = preserve ]
}

@test "review-package: bundled helpers run without executable bits" {
    helpers="$BATS_TEST_TMPDIR/helpers"
    mkdir -p "$helpers"
    cp "$(dirname "$SCRIPT")/review-package" "$(dirname "$SCRIPT")/sdd-workspace" "$helpers/"
    chmod -x "$helpers/"*
    echo changed > f.txt; git add f.txt; git commit -qm change
    run bash "$helpers/review-package" plan.md HEAD~1 HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 commit(s)"* ]]
}

@test "task-brief: bundled workspace helper runs without executable bits" {
    helpers="$BATS_TEST_TMPDIR/helpers"
    mkdir -p "$helpers"
    cp "$(dirname "$SCRIPT")/task-brief" "$(dirname "$SCRIPT")/sdd-workspace" "$helpers/"
    chmod -x "$helpers/"*
    printf '### Task 1: Example\n\nDo the thing.\n' > plan.md
    run bash "$helpers/task-brief" plan.md 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"task-1-brief.md"* ]]
}
