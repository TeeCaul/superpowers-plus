#!/usr/bin/env bats
# Unit tests for tools/ship.sh -- exercises the pure description validation and
# body-generation paths without invoking `gh`, `git push`, or any network.
# Loaded via SHIP_TESTMODE=1 so main body of ship.sh is skipped.

setup() {
  TOOL="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tools/ship.sh"
  WORK="$(mktemp -d)"
  export REPO_ROOT="$WORK"
  export SHIP_TESTMODE=1
}

teardown() {
  rm -rf "$WORK"
  unset REPO_ROOT SHIP_TESTMODE
}

_source_ship() {
  # shellcheck source=/dev/null
  source "$TOOL"
}

@test "generated description starts with the supplied change and observable validation" {
  _source_ship
  run _generate_body "Retries no longer create duplicate orders." "Retry regression: one order created." ""
  [ "$status" -eq 0 ]
  [[ "$output" == "Retries no longer create duplicate orders."* ]]
  [[ "$output" == *"Retry regression: one order created."* ]]
}

@test "review metadata never replaces the summary or leaks into the body" {
  echo "v1|abc123|PASS|2026-04-01|min-score=9.2" > "$WORK/.code-review-cleared"
  _source_ship
  run _generate_body "Restore saved drafts after restart." "" "https://github.com/x/y/issues/42"
  [ "$status" -eq 0 ]
  [[ "$output" == "Restore saved drafts after restart."* ]]
  [[ "$output" == *"https://github.com/x/y/issues/42"* ]]
  [[ "$output" != *"9.2"* && "$output" != *"PASS"* && "$output" != *"abc123"* ]]
  [[ "$output" != *"Test plan"* ]]
}

@test "blank summary is rejected" {
  _source_ship
  run _generate_body "" "" ""
  [ "$status" -eq 1 ]
  run _generate_body $' \t\n' "" ""
  [ "$status" -eq 1 ]
}

# Exercise the real entrypoint using commands that log any remote mutation.
_mock_commands() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  config) echo 'bordenet@users.noreply.github.com' ;;
  rev-parse) echo 'feat/test' ;;
  push) echo push >> "$REPO_ROOT/operations" ;;
esac
EOF
  cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'pr create' ]]; then
  echo create >> "$REPO_ROOT/operations"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == '--body-file' ]]; then cp "$2" "$REPO_ROOT/published"; break; fi
    shift
  done
  echo 'https://github.com/example/project/pull/1'
fi
EOF
  chmod +x "$WORK/bin/git" "$WORK/bin/gh"
}

@test "missing or whitespace summary fails before any push" {
  _mock_commands
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: retries' --no-merge
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/operations" ]
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: retries' --summary '   ' --no-merge
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/operations" ]
}

@test "missing option value produces an actionable error" {
  run env SHIP_TESTMODE=0 bash "$TOOL" --summary
  [ "$status" -eq 1 ]
  [[ "$output" == *'--summary requires a value'* ]]
}

@test "empty and unreadable body files fail before pushing" {
  _mock_commands
  printf ' \n' > "$WORK/blank body"
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: retries' --body-file "$WORK/blank body" --no-merge
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/operations" ]
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: retries' --body-file "$WORK/absent" --no-merge
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/operations" ]
}

@test "caller body survives publication byte for byte including spaces in path" {
  _mock_commands
  printf 'Customers retain saved drafts.\n\nValidated restart recovery.\n' > "$WORK/custom body"
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: drafts' --body-file "$WORK/custom body" --no-merge
  [ "$status" -eq 0 ]
  cmp "$WORK/custom body" "$WORK/published"
  [ "$(cat "$WORK/operations")" = $'push\ncreate' ]
}

@test "generated PR accepts summary alone without invented test results" {
  _mock_commands
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'docs: spelling' --summary 'Correct spelling in the installation guide.' --no-merge
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/published")" = 'Correct spelling in the installation guide.' ]
}

@test "invalid test plan file fails before pushing" {
  _mock_commands
  run env SHIP_TESTMODE=0 PATH="$WORK/bin:$PATH" bash "$TOOL" --title 'fix: retries' --summary 'Retries create one order.' --test-plan-file "$WORK/absent" --no-merge
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/operations" ]
}

# --- _aggregate_check_state -------------------------------------------------
# Regression guard for the CI-bypass bug. ship.sh previously reduced check
# states with:
#     grep -qE '^(pending|in_progress|queued|)$'
# The empty final alternative is rejected by ugrep (a common Homebrew `grep`
# replacement on macOS) as "empty (sub)expression", exiting 2. The non-zero
# exit made that `elif` false, so a PR with checks still RUNNING fell through
# to "success" and ship.sh merged it without waiting for CI. Observed live on
# PR #1210 (2026-08-25). These tests pin every branch of the state machine.

@test "_aggregate_check_state: all pass -> success" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tpass\t2s\turl')"
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "_aggregate_check_state: a pending check -> running (never success)" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tpending\t0\turl')"
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "_aggregate_check_state: in_progress -> running" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tin_progress\t0\turl')"
  [ "$output" = "running" ]
}

@test "_aggregate_check_state: queued -> running" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tqueued\t0\turl')"
  [ "$output" = "running" ]
}

@test "_aggregate_check_state: empty state column -> running" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\t\t0\turl')"
  [ "$output" = "running" ]
}

@test "_aggregate_check_state: a failing check -> failed" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tfail\t3s\turl')"
  [ "$output" = "failed" ]
}

@test "_aggregate_check_state: failure outranks a still-pending check" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpending\t0\turl\nLint\tfail\t3s\turl')"
  [ "$output" = "failed" ]
}

@test "_aggregate_check_state: gh's real 'cancel' bucket -> failed (not success)" {
  # REGRESSION: gh pr checks TSV column 2 emits the BUCKET, and gh's cancelled
  # bucket is "cancel", NOT "cancelled". The first version of this function
  # matched only "cancelled", so a genuinely cancelled check fell through the
  # denylist to "success" and ship.sh merged without passing CI -- the exact
  # failure this function exists to prevent.
  _source_ship
  run _aggregate_check_state "$(printf 'A\tcancel\t0\turl')"
  [ "$output" = "failed" ]
}

@test "_aggregate_check_state: cancel outranks a passing check" {
  _source_ship
  run _aggregate_check_state "$(printf 'A\tpass\t1s\turl\nB\tcancel\t0\turl')"
  [ "$output" = "failed" ]
}

@test "_aggregate_check_state: unknown/future bucket fails CLOSED to running" {
  # The aggregator is an allowlist: anything unrecognized must keep the poll
  # loop waiting (and eventually hit _POLL_TIMEOUT), never resolve to success.
  _source_ship
  run _aggregate_check_state "$(printf 'A\tfuturebucket\t0\turl')"
  [ "$output" = "running" ]
  run _aggregate_check_state "$(printf 'A\tpass\t1s\turl\nB\tstale\t0\turl')"
  [ "$output" = "running" ]
}

@test "_aggregate_check_state: cancelled/action_required/timed_out -> failed" {
  _source_ship
  run _aggregate_check_state "$(printf 'A\tcancelled\t0\turl')"
  [ "$output" = "failed" ]
  run _aggregate_check_state "$(printf 'A\taction_required\t0\turl')"
  [ "$output" = "failed" ]
  run _aggregate_check_state "$(printf 'A\ttimed_out\t0\turl')"
  [ "$output" = "failed" ]
}

@test "_aggregate_check_state: skipping counts as complete -> success" {
  _source_ship
  run _aggregate_check_state "$(printf 'Tests\tpass\t1s\turl\nLint\tskipping\t0\turl')"
  [ "$output" = "success" ]
}

@test "_aggregate_check_state: ALL checks skipping -> success (intentional)" {
  # Pinned decision, not an accident. gh buckets a skipped OR neutral check as
  # "skipping", and path-filtered workflows legitimately skip every check on a
  # docs-only PR. ship.sh mirrors branch protection rather than inventing a
  # stricter rule, so an all-skipped required set counts as satisfied. If that
  # is ever wrong for this repo, the fix is branch protection config, not a
  # divergent rule here. See the --required rationale in tools/ship.sh.
  _source_ship
  run _aggregate_check_state "$(printf 'A\tskipping\t0\turl\nB\tskipping\t0\turl')"
  [ "$output" = "success" ]
}

@test "_aggregate_check_state: no required checks found -> pending, never success" {
  # An empty required set means protection is missing/unreadable. That must
  # stall the poll loop into a timeout (exit 1), never resolve to a merge.
  _source_ship
  run _aggregate_check_state ""
  [ "$output" = "pending" ]
  run _aggregate_check_state "$(printf '\n\n')"
  [ "$output" = "pending" ]
}

@test "_aggregate_check_state: empty input -> pending" {
  _source_ship
  run _aggregate_check_state ""
  [ "$output" = "pending" ]
}
