#!/usr/bin/env bats
# review-envelope.bats -- tests for tools/review-envelope.py
#
# Each test runs in a throwaway git repo with one commit, so envelopes land in
# $BATS_TEST_TMPDIR/repo/.cr-battery-runs and never touch the real checkout.
#
# RUN: bats tests/tools/review-envelope.bats

bats_require_minimum_version 1.5.0

setup() {
  # Fixtures must not depend on the developer's git config (commit.gpgsign,
  # diff.noprefix, init.defaultBranch, identity).
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  TOOL="$REPO_ROOT/tools/review-envelope.py"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
  printf 'alpha\nbeta\n' > notes.txt
  git add notes.txt
  git -c user.email=t@example.com -c user.name=t commit -qm init
  HEAD_SHA="$(git rev-parse HEAD)"
}

env_file() { "$TOOL" path "$@"; }

@test "help prints usage and exits 0" {
  run "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "init writes head_sha skeleton at the runner's path" {
  run "$TOOL" init --kind battery
  [ "$status" -eq 0 ]
  [ -f ".cr-battery-runs/$HEAD_SHA.json" ]
  run python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print(e["head_sha"], e["findings"], e["clean_dimensions"])' ".cr-battery-runs/$HEAD_SHA.json"
  [ "$output" = "$HEAD_SHA [] []" ]
}

@test "init refuses to overwrite without --force" {
  "$TOOL" init --kind skill-review
  run "$TOOL" init --kind skill-review
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  run "$TOOL" init --kind skill-review --force
  [ "$status" -eq 0 ]
}

@test "add-clean rejects a failing expectation and shows observed output" {
  "$TOOL" init --kind battery
  run "$TOOL" add-clean --reviewer R --dimension D --claim "three lines" \
    --cmd "cat notes.txt" --expect "count==3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not hold"* ]]
  [[ "$output" == *"non_blank_lines=2"* ]]
  [[ "$output" == *"| alpha"* ]]
  run python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["clean_dimensions"]))' "$(env_file)"
  [ "$output" = "0" ]
}

@test "add-clean accepts a passing expectation" {
  "$TOOL" init --kind battery
  run "$TOOL" add-clean --reviewer R --dimension D --claim "two lines" \
    --cmd "cat notes.txt" --expect "count==2"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean_dimensions"][0]["evidence"]["expectation"]["value"])' "$(env_file)"
  [ "$output" = "==2" ]
}

@test "wrong severity scale for the kind is rejected" {
  "$TOOL" init --kind skill-review
  run "$TOOL" add-finding --severity important --file notes.txt --line 1 \
    --reviewer R --dimension D --claim x --cmd "grep alpha notes.txt" --expect "count=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"battery scale"* ]]
  rm -rf .cr-battery-runs
  "$TOOL" init --kind battery
  run "$TOOL" add-finding --severity S1 --file notes.txt --line 1 \
    --reviewer R --dimension D --claim x --cmd "grep alpha notes.txt" --expect "count=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"skill-review scale"* ]]
}

@test "resolve moves a finding into clean_dimensions" {
  "$TOOL" init --kind battery
  "$TOOL" add-finding --severity important --file notes.txt --line 2 \
    --reviewer "Defect Finder" --dimension Correctness --claim "beta is present" \
    --cmd "grep beta notes.txt" --expect "count==1"
  printf 'alpha\n' > notes.txt
  run "$TOOL" resolve F1 --cmd "grep beta notes.txt" --expect absent --claim "beta removed"
  [ "$status" -eq 0 ]
  run python3 -c '
import json,sys
e=json.load(open(sys.argv[1]))
print(len(e["findings"]), e["clean_dimensions"][0]["claim"], e["clean_dimensions"][0]["reviewer"])' "$(env_file)"
  [ "$output" = "0 F1 (important, fixed): beta removed Defect Finder" ]
}

@test "resolve refuses when the fix is not proven" {
  "$TOOL" init --kind battery
  "$TOOL" add-finding --severity minor --file notes.txt --line 2 --reviewer R \
    --dimension D --claim "beta" --cmd "grep beta notes.txt" --expect "count=1"
  run "$TOOL" resolve F1 --cmd "grep beta notes.txt" --expect absent
  [ "$status" -eq 1 ]
  run python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["findings"]))' "$(env_file)"
  [ "$output" = "1" ]
}

@test "skill-review gate refuses an open S1, then passes after resolve" {
  "$TOOL" init --kind skill-review
  "$TOOL" add-clean --reviewer R --dimension Prose --claim "file exists" \
    --cmd "test -f notes.txt" --expect "exit_code=0"
  "$TOOL" add-finding --severity S1 --file notes.txt --line 2 --reviewer R \
    --dimension Prose --claim "beta" --cmd "grep beta notes.txt" --expect "count=1"
  "$TOOL" set --verdict PASS --mean 8.5
  run "$TOOL" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"open S0/S1 findings block the sentinel: F1"* ]]
  [[ "$output" == *"unresolved S0/S1 findings remain"* ]]
  printf 'alpha\n' > notes.txt
  "$TOOL" resolve F1 --cmd "grep beta notes.txt" --expect absent
  run "$TOOL" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"envelope-gate: ok unresolved_s0_s1=0"* ]]
  [[ "$output" == *"CHECK OK"* ]]
}

@test "check never mutates the envelope" {
  "$TOOL" init --kind battery
  "$TOOL" add-clean --reviewer R --dimension D --claim "alpha" \
    --cmd "grep alpha notes.txt" --expect "count>0"
  "$TOOL" set --verdict PASS --score 9.5
  f="$(env_file)"
  before="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  run "$TOOL" check
  [ "$status" -eq 0 ]
  after="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
  run grep -c verifier_result "$f"
  [ "$output" = "0" ]
}

@test "check fails when verdict is unset" {
  "$TOOL" init --kind battery
  "$TOOL" add-clean --reviewer R --dimension D --claim "alpha" \
    --cmd "grep alpha notes.txt" --expect "count>0"
  run "$TOOL" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdict is not set"* ]]
}

@test "set rejects the other kind's score field" {
  "$TOOL" init --kind battery
  run "$TOOL" set --verdict PASS --mean 8
  [ "$status" -eq 2 ]
  run "$TOOL" set --verdict PASS_WITH_RISKS --score 8
  [ "$status" -eq 2 ]
}

@test "kind is required when both envelopes exist" {
  "$TOOL" init --kind battery
  "$TOOL" init --kind skill-review
  run "$TOOL" path
  [ "$status" -eq 2 ]
  [[ "$output" == *"--kind"* ]]
  run "$TOOL" path --kind battery
  [ "$status" -eq 0 ]
}

@test "unknown expectation type is a usage error" {
  "$TOOL" init --kind battery
  run "$TOOL" add-clean --reviewer R --dimension D --claim x --cmd true --expect "lines=2"
  [ "$status" -eq 2 ]
}

@test "parallel writers lose no claims" {
  "$TOOL" init --kind battery
  for i in 1 2 3 4 5; do
    "$TOOL" add-clean --reviewer "R$i" --dimension D --claim "c$i" \
      --cmd "sleep 1; echo x" --expect "count==1" >/dev/null &
  done
  wait
  run python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["clean_dimensions"]))' "$(env_file)"
  [ "$output" = "5" ]
}

@test "resolve refuses while the finding's own evidence still holds" {
  "$TOOL" init --kind skill-review
  "$TOOL" add-finding --severity S1 --file notes.txt --line 2 --reviewer R \
    --dimension D --claim "beta" --cmd "grep beta notes.txt" --expect "count=1"
  run "$TOOL" resolve F1 --cmd true --expect "exit_code=0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"own evidence still holds"* ]]
  run "$TOOL" resolve F1 --cmd true --expect "exit_code=0" --evidence-unchanged "line kept, wording fixed"
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["clean_dimensions"][0]["claim"])' "$(env_file)"
  [[ "$output" == *"original evidence still holds: line kept, wording fixed"* ]]
}

@test "check fails a verdict that does not clear the gate" {
  "$TOOL" init --kind skill-review
  "$TOOL" add-clean --reviewer R --dimension D --claim c --cmd "cat notes.txt" --expect "count==2"
  "$TOOL" set --verdict REJECT --mean 5
  run "$TOOL" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not clear the skill-review gate"* ]]
}

@test "the skill-review gate itself refuses an envelope with no replayable evidence" {
  "$TOOL" init --kind skill-review
  "$TOOL" add-clean --reviewer R --dimension D --claim c --unverifiable "judgment only"
  "$TOOL" set --verdict PASS --mean 8
  run "$TOOL" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-vacuous review proof required"* ]]
}

@test "set rejects a score outside 1.0-10.0" {
  "$TOOL" init --kind skill-review
  run "$TOOL" set --verdict PASS --mean 0.5
  [ "$status" -eq 2 ]
}

@test "empty match and padded exact values are rejected" {
  "$TOOL" init --kind battery
  run "$TOOL" add-clean --reviewer R --dimension D --claim x --cmd true --expect "match="
  [ "$status" -eq 2 ]
  run "$TOOL" add-clean --reviewer R --dimension D --claim x --cmd "echo hi" --expect "exact=hi "
  [ "$status" -eq 2 ]
}

@test "a refused command runs once and non-UTF-8 output is shown, not a traceback" {
  "$TOOL" init --kind battery
  run "$TOOL" add-clean --reviewer R --dimension D --claim c \
    --cmd "echo run >> '$BATS_TEST_TMPDIR/count'; printf 'a\377b\n'; exit 3" --expect "exit_code=0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" == *"exit=3"* ]]
  [ "$(grep -c run "$BATS_TEST_TMPDIR/count")" = "1" ]
}

@test "a missing envelope is a refusal with or without --kind" {
  run "$TOOL" path
  [ "$status" -eq 1 ]
  run "$TOOL" path --kind battery
  [ "$status" -eq 1 ]
}

@test "add-finding records the schema's optional fields and set records bugpath" {
  "$TOOL" init --kind battery
  "$TOOL" add-finding --severity important --file notes.txt --line 1 --reviewer R \
    --dimension D --claim a --cmd "grep alpha notes.txt" --expect "count=1" \
    --issue "alpha leaks" --durable-check "test added"
  "$TOOL" set --verdict PASS --score 9 --rounds 2 --bugpath '{"path_coverage":"FULL"}'
  run python3 -c '
import json,sys
e=json.load(open(sys.argv[1]))
print(e["findings"][0]["issue"], e["findings"][0]["durable_check"], e["rounds"], e["bugpath_verdict"]["path_coverage"])' "$(env_file)"
  [ "$output" = "alpha leaks test added 2 FULL" ]
}
