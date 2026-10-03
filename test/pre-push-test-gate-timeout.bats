#!/usr/bin/env bats
# The pre-push test gate wraps tools/test-all.sh --fast in timeout(1). A
# timeout must be reported as a timeout, not as a test failure, and the limit
# must be overridable through PRE_PUSH_TEST_TIMEOUT.

setup() {
    REPO_ROOT_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    WORK="$(mktemp -d)"
    WORK="$(cd "$WORK" && pwd -P)"
    cd "$WORK"
    git init -q --initial-branch=main
    git config user.email "test@test"
    git config user.name "test"
    mkdir -p tools test   # the gate skips itself when test/ is absent
    cp "$REPO_ROOT_REAL/tools/pre-push-test-gate.sh" tools/
    echo x > a.txt
    git add -A
    git commit -q -m base
    export PUSH_INPUT="refs/heads/main $(git rev-parse HEAD) refs/heads/main 0000000000000000000000000000000000000000"
}

teardown() {
    rm -rf "$WORK"
}

stub_suite() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" > tools/test-all.sh
    chmod +x tools/test-all.sh
}

have_timeout() {
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

@test "test gate: a suite that exceeds the limit is reported as a timeout, not a failure" {
    have_timeout || skip "no timeout/gtimeout binary on this machine"
    stub_suite 'sleep 5'
    run bash -c "PRE_PUSH_TEST_TIMEOUT=1 bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out after 1s"* ]]
    [[ "$output" != *"Local test suite failed"* ]]
}

@test "test gate: a failing suite is reported as a failure, not a timeout" {
    stub_suite 'exit 3'
    run bash -c "bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Local test suite failed"* ]]
    [[ "$output" != *"timed out"* ]]
}

@test "test gate: a suite that exits 124 on its own, well inside the limit, is a failure, not a timeout" {
    stub_suite 'exit 124'
    run bash -c "bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Local test suite failed"* ]]
    [[ "$output" != *"timed out"* ]]
}

@test "test gate: a passing suite passes under the default limit" {
    stub_suite 'exit 0'
    run bash -c "bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Local fast test suite passed"* ]]
}

@test "test gate: a non-numeric PRE_PUSH_TEST_TIMEOUT is rejected before running tests" {
    stub_suite 'echo SUITE_RAN; exit 0'
    run bash -c "PRE_PUSH_TEST_TIMEOUT=ten bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"PRE_PUSH_TEST_TIMEOUT must be a positive whole number"* ]]
    [[ "$output" != *"SUITE_RAN"* ]]
}

# A fake timeout(1) first on PATH that records the limit it was given, then
# runs the command without enforcing anything.
fake_timeout_on_path() {
    mkdir -p "$WORK/fakebin"
    printf '#!/usr/bin/env bash\necho "$1" > "%s/limit-seen"\nshift\nexec "$@"\n' "$WORK" > "$WORK/fakebin/timeout"
    chmod +x "$WORK/fakebin/timeout"
    export PATH="$WORK/fakebin:$PATH"
}

@test "test gate: the default limit passed to timeout is 600 seconds" {
    stub_suite 'exit 0'
    fake_timeout_on_path
    run bash -c "bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/limit-seen")" = "600" ]
}

@test "test gate: PRE_PUSH_TEST_TIMEOUT sets the limit passed to timeout" {
    stub_suite 'exit 0'
    fake_timeout_on_path
    run bash -c "PRE_PUSH_TEST_TIMEOUT=42 bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/limit-seen")" = "42" ]
}

@test "test gate: with no timeout binary, a suite exiting 124 is a failure, not a timeout" {
    stub_suite 'exit 124'
    # PATH holding only what the gate and the stub need, with no timeout/gtimeout.
    mkdir -p "$WORK/minbin"
    local cmd
    for cmd in bash git env dirname; do
        ln -s "$(command -v "$cmd")" "$WORK/minbin/$cmd"
    done
    run env PATH="$WORK/minbin" bash -c "bash tools/pre-push-test-gate.sh <<< \"\$PUSH_INPUT\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Local test suite failed"* ]]
    [[ "$output" != *"timed out"* ]]
}
