#!/usr/bin/env bats
# Tests for slop-dictionary.js's scan-ai-process-refs / seed-ai-process-refs
# commands: catches this toolkit's own process vocabulary (harsh-review,
# cr-battery, PHR, etc.) leaking into a downstream adopter's PR/commit text,
# with occurrence-level subject exceptions reviewed separately.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/slop-dictionary.js"

setup() {
    FAKE_REPO="$(mktemp -d)"
    cd "$FAKE_REPO" || return 1
    git init -q
    git remote add origin git@github.com:someorg/some-product-repo.git
    echo "# Some Product Repo" > AGENTS.md
}

teardown() {
    cd /
    rm -rf "$FAKE_REPO"
}

@test "scan-ai-process-refs: clean text passes" {
    run bash -c "echo 'This PR fixes a null pointer bug in the parser.' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No ai-process reference detected"* ]]
}

@test "scan-ai-process-refs: planted self-reference is caught (exit 1)" {
    run bash -c "echo 'Ran a harsh-review pass and got a phr score of 9.2 before this cr-battery run.' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AI-PROCESS REFERENCE DETECTED"* ]]
    [[ "$output" == *"harsh-review"* ]]
}

@test "scan-ai-process-refs: multi-word pattern split across a line wrap is still caught" {
    run bash -c "printf 'a phr\nscore of 9\n' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 1 ]
}

@test "scan-ai-process-refs: empty input exits 2, distinct from a clean pass" {
    run bash -c "printf '' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 2 ]
    [[ "$output" == *"input is empty"* ]]
}

@test "scan-ai-process-refs: toolkit repository does not exempt narration" {
    run bash -c "cd '$REPO_ROOT' && echo 'a harsh-review pass' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Review each occurrence"* ]]
}

@test "scan-ai-process-refs: empty toolkit input remains an error" {
    run bash -c "cd '$REPO_ROOT' && printf '' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 2 ]
}

@test "scan-ai-process-refs: legitimate subject is reported for contextual review" {
    run bash -c "echo 'feat(code-review-battery): report unresolved findings' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 1 ]
    [[ "$output" == *"legitimate subject exceptions"* ]]
}

@test "scan-ai-process-refs: mixed subject and narration cannot bypass scanning" {
    run bash -c "echo 'Fix code-review-battery totals after harsh-review passed.' | node '$SCRIPT' scan-ai-process-refs -"
    [ "$status" -eq 1 ]
    [[ "$output" == *"code-review-battery"* && "$output" == *"harsh-review"* ]]
}

@test "scan-profanity still works after the shared-helper refactor (regression check)" {
    run bash -c "echo 'clean text here' | node '$SCRIPT' scan-profanity -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No profanity detected"* ]]
}

@test "list rejects an invalid category" {
    run node "$SCRIPT" list bogus-category-name
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid category"* ]]
}
