#!/usr/bin/env bats
# commit-msg-jargon.bats -- tests for tools/commit-msg-jargon.py and its
# wiring into tools/commit-msg. Warn-only: every case must exit 0.
#
# RUN: bats tests/tools/commit-msg-jargon.bats

bats_require_minimum_version 1.5.0

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  TOOL="$REPO_ROOT/tools/commit-msg-jargon.py"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q -b main
  git commit -q --allow-empty -m root
  MSG="$BATS_TEST_TMPDIR/msg"
}

stage() { mkdir -p "$(dirname "$1")"; echo x > "$1"; git add "$1"; }

@test "help exits 0" {
  run "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "missing argument is a usage error" {
  run "$TOOL"
  [ "$status" -eq 2 ]
}

@test "clean message prints nothing" {
  stage lib/a.js
  printf 'Fix the parser\n\nHandle empty input.\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "tooling names in subject and body are warned about, with line numbers" {
  stage lib/a.js
  printf 'Fix parser after PHR round 2\n\nThe battery passed; sentinel written.\nReviewed with code-review-battery and harsh review.\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"line 1 [PHR]"* ]]
  [[ "$stderr" == *"line 3 [battery, sentinel]"* ]]
  [[ "$stderr" == *"line 4 [code-review-battery, harsh review]"* ]]
  [[ "$stderr" == *"Not blocking"* ]]
}

@test "code fences, comments and trailers are not scanned" {
  stage lib/a.js
  printf 'Fix parser\n\n```\nrun-battery sentinel output\n```\n# PHR note from the editor template\n\nCo-Authored-By: Superpowers Bot <x@example.com>\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "a Key: value line inside the body is still scanned" {
  stage lib/a.js
  printf 'Fix parser\n\nNote: the battery was rerun.\n\nmore text\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [[ "$stderr" == *"line 3 [battery]"* ]]
}

@test "words that only contain a term are not matched" {
  stage lib/a.js
  printf 'Rename batteryLevel and phrase handling\n\nsentinels_dir is unrelated; my-battery-pack too.\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ -z "$stderr" ]
}

@test "changes to the review tooling itself are exempt" {
  for p in skills/engineering/code-review-battery/skill.md tools/run-battery.sh tools/pre-push-loc-gate.sh; do
    git reset -q
    stage "$p"
    printf 'Teach the battery about X\n' > "$MSG"
    run --separate-stderr "$TOOL" "$MSG"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
  done
}

@test "commit-msg hook runs it and still accepts the commit" {
  mkdir -p tools
  cp "$REPO_ROOT/tools/commit-msg" "$REPO_ROOT/tools/commit-msg-jargon.py" tools/
  stage lib/a.js
  printf 'Fix parser\n\nBattery passed.\n' > "$MSG"
  run --separate-stderr bash tools/commit-msg "$MSG"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"names review tooling"* ]]
}

@test "a tool named as the topic of a change does not warn" {
  stage lib/a.js
  printf 'Fix the sentinel parser for tree: entries\n\nThe PHR skill reads its threshold from one place now.\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "the verbose diff below the scissors line is not scanned" {
  stage lib/a.js
  printf 'Fix parser\n\n# ------------------------ >8 ------------------------\n+battery passed in the diff\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ -z "$stderr" ]
}

@test "a message-only amend uses the amended commit's files for the exemption" {
  stage tools/run-x.sh
  git commit -q -m "add runner"
  printf 'Teach the battery: findings now pass through\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [ -z "$stderr" ]
}

@test "a last paragraph that is not standard trailers is still scanned" {
  stage lib/a.js
  printf 'Fix parser\n\nNote: the battery passed again.\n' > "$MSG"
  run --separate-stderr "$TOOL" "$MSG"
  [[ "$stderr" == *"line 3 [battery]"* ]]
}
