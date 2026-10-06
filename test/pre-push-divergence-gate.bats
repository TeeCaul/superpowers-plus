#!/usr/bin/env bats
# Tests for tools/pre-push-divergence-gate.sh
# Exit contract: 0 = every pushed branch contains its target (or skipped),
#                1 = a pushed branch is behind its target, 2 = usage error.
#
# Each test has a bare "origin" repo with main and dev, and a clone that
# pushes. Pre-push stdin lines are built by hand: the gate only reads them.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/tools/pre-push-divergence-gate.sh"
ZERO_SHA="0000000000000000000000000000000000000000"

setup() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    WORK="$BATS_TEST_TMPDIR/work"
    OTHER="$BATS_TEST_TMPDIR/other"
    git init -q --bare -b main "$ORIGIN"
    git clone -q "$ORIGIN" "$WORK" 2>/dev/null
    cd "$WORK"
    git commit -q --allow-empty -m root
    git push -q origin main
    git push -q origin main:dev
    git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
}

# land N commits on origin/<branch> from a second clone
advance() {
    local branch="$1" n="${2:-1}" i
    git -C "$OTHER" fetch -q origin
    git -C "$OTHER" checkout -q -B "$branch" "origin/$branch"
    for ((i = 0; i < n; i++)); do git -C "$OTHER" commit -q --allow-empty -m "$branch $i"; done
    git -C "$OTHER" push -q origin "$branch"
}

# pre-push stdin line for pushing HEAD to refs/heads/<branch>
line() { echo "refs/heads/$1 $(git rev-parse HEAD) refs/heads/$1 $ZERO_SHA"; }

@test "--help prints usage" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE"* ]]
}

@test "unknown option is a usage error" {
    run bash "$SCRIPT" --bogus < /dev/null
    [ "$status" -eq 2 ]
}

@test "feature branch that contains dev passes" {
    git checkout -q -b feat/x origin/dev
    git commit -q --allow-empty -m work
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat/x: contains origin/dev"* ]]
}

@test "feature branch behind dev is blocked with the count and rebase command" {
    git checkout -q -b feat/x origin/dev
    git commit -q --allow-empty -m work
    advance dev 3
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing 3 commits that origin/dev already has"* ]]
    [[ "$output" == *"git rebase origin/dev"* ]]
}

@test "the gate fetches: a stale local origin/dev does not hide new commits" {
    git checkout -q -b feat/x origin/dev
    advance dev 1
    # local origin/dev is still the old commit; only a fetch can see the new one
    [ "$(git rev-parse origin/dev)" = "$(git rev-parse HEAD)" ]
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing 1 commit "* ]]
}

@test "dev and promote/* are compared with main" {
    git checkout -q -b promote/r1 origin/dev
    advance main 2
    run bash "$SCRIPT" origin <<< "$(line promote/r1)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"origin/main"* ]]
    run bash "$SCRIPT" origin <<< "$(line dev)"
    [ "$status" -eq 1 ]
}

@test "the sync branch cut from main is compared with main, not dev" {
    advance dev 2
    git fetch -q origin
    git checkout -q -b chore/sync-dev-with-main origin/main
    run bash "$SCRIPT" origin <<< "$(line chore/sync-dev-with-main)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contains origin/main"* ]]
}

@test "pushing main is not compared with anything" {
    advance dev 2
    run bash "$SCRIPT" origin <<< "$(line main)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no target branch"* ]]
}

@test "hotfix, release, backport and tagged-release branches are exempt" {
    advance dev 2
    for b in hotfix/a release/b backport/c tagged-release/d; do
        run bash "$SCRIPT" origin <<< "$(line "$b")"
        [ "$status" -eq 0 ]
        [[ "$output" == *"exempt"* ]]
    done
}

@test "DIVERGENCE_GATE=off skips the check" {
    git checkout -q -b feat/x origin/dev
    advance dev 2
    DIVERGENCE_GATE=off run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not checked"* ]]
}

@test "an unreachable remote warns and lets the push through" {
    git checkout -q -b feat/x origin/dev
    git remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not fetch origin/dev"* ]]
}

@test "deletions, tags and a URL remote are not checked" {
    advance dev 2
    run bash "$SCRIPT" origin <<< "(delete) $ZERO_SHA refs/heads/feat/gone $(git rev-parse HEAD)"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" origin <<< "refs/tags/v1 $(git rev-parse HEAD) refs/tags/v1 $ZERO_SHA"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT" "$ORIGIN" <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a configured remote"* ]]
}

@test "several refs: one behind blocks the push, the other still reported" {
    git checkout -q -b feat/ok origin/dev
    advance dev 1
    git fetch -q origin
    git checkout -q -b feat/fresh origin/dev
    git checkout -q feat/ok
    input="$(line feat/ok)
refs/heads/feat/fresh $(git rev-parse feat/fresh) refs/heads/feat/fresh $ZERO_SHA"
    run bash "$SCRIPT" origin <<< "$input"
    [ "$status" -eq 1 ]
    [[ "$output" == *"feat/ok is missing 1 commit"* ]]
    [[ "$output" == *"feat/fresh: contains origin/dev"* ]]
}

@test "a leaked GIT_DIR does not redirect the gate" {
    git checkout -q -b feat/x origin/dev
    advance dev 1
    decoy="$BATS_TEST_TMPDIR/decoy"
    git init -q "$decoy"
    GIT_DIR="$decoy/.git" run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 1 ]
    [ -z "$(git -C "$decoy" for-each-ref)" ]
}

@test "pre-push composer runs it as Gate 8" {
    grep -q 'Gate 8/8.*divergence' "$REPO_ROOT/tools/pre-push"
    grep -q 'DIVERGENCE_GATE_SCRIPT="$TOOLS_DIR/pre-push-divergence-gate.sh"' "$REPO_ROOT/tools/pre-push"
    grep -q 'bash "$DIVERGENCE_GATE_SCRIPT" "$REMOTE_NAME" < "$STDIN_CAPTURE"' "$REPO_ROOT/tools/pre-push"
}

@test "a real git push from a stale branch is refused by the hook" {
    printf '#!/usr/bin/env bash\nexec bash "%s" "$1"\n' "$SCRIPT" > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
    git checkout -q -b feat/stale origin/dev
    git commit -q --allow-empty -m work
    advance dev 2
    run git push -q origin feat/stale
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing 2 commits"* ]]
    [ -z "$(git ls-remote origin refs/heads/feat/stale)" ]
    git rebase -q origin/dev
    run git push -q origin feat/stale
    [ "$status" -eq 0 ]
    [ -n "$(git ls-remote origin refs/heads/feat/stale)" ]
}

@test "a force-rewritten target is still fetched and compared" {
    git checkout -q -b feat/x origin/dev
    git -C "$OTHER" fetch -q origin
    git -C "$OTHER" checkout -q -B dev origin/dev
    git -C "$OTHER" commit -q --allow-empty --amend -m rewritten-root
    git -C "$OTHER" push -q --force origin dev
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing 1 commit"* ]]
}

@test "a missing target branch prints git's reason and passes" {
    git push -q origin --delete dev
    git checkout -q -b feat/x
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not fetch origin/dev"* ]]
    [[ "$output" == *"git: "* ]]
}

@test "a shallow clone is not checked" {
    advance dev 2
    shallow="$BATS_TEST_TMPDIR/shallow"
    git clone -q --depth 1 --branch dev "file://$ORIGIN" "$shallow" 2>/dev/null
    cd "$shallow"
    git checkout -q -b feat/x
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shallow clone"* ]]
}

@test "sync branch names target main; names that merely contain sync do not" {
    advance dev 2
    git fetch -q origin
    for b in sync/main-into-dev-1 chore/sync-dev-after-retirement chore/sync-dev-with-main-v2; do
        git checkout -q -B "$b" origin/main
        run bash "$SCRIPT" origin <<< "$(line "$b")"
        [ "$status" -eq 0 ]
        [[ "$output" == *"contains origin/main"* ]]
    done
    for b in feat/async-x feat/sync-calendar; do
        git checkout -q -B "$b" origin/main
        run bash "$SCRIPT" origin <<< "$(line "$b")"
        [ "$status" -eq 1 ]
        [[ "$output" == *"origin/dev"* ]]
    done
}

@test "a main target is told to merge, never to rebase" {
    git checkout -q -b promote/r1 origin/dev
    advance main 1
    run bash "$SCRIPT" origin <<< "$(line promote/r1)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git merge origin/main"* ]]
    [[ "$output" != *"git rebase"* ]]
}

@test "a branch already on the remote is told to use a lease-protected force push" {
    git checkout -q -b feat/x origin/dev
    git commit -q --allow-empty -m work
    git push -q origin feat/x
    advance dev 1
    run bash "$SCRIPT" origin <<< "refs/heads/feat/x $(git rev-parse HEAD) refs/heads/feat/x $(git rev-parse origin/feat/x)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"git rebase origin/dev"* ]]
    [[ "$output" == *"with-lease"* ]]
    run bash "$SCRIPT" origin <<< "$(line feat/new)"
    [[ "$output" != *"with-lease"* ]]
}

@test "a configured ssh command is used for the fetch, not replaced" {
    unset GIT_SSH_COMMAND GIT_SSH
    printf '#!/bin/sh\necho used >> "%s/ssh.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/myssh"
    chmod +x "$BATS_TEST_TMPDIR/myssh"
    git remote set-url origin ssh://example.invalid/r.git
    git config core.sshCommand "$BATS_TEST_TMPDIR/myssh"
    run bash "$SCRIPT" origin <<< "$(line feat/x)"
    [ "$status" -eq 0 ]
    grep -q used "$BATS_TEST_TMPDIR/ssh.log"
}
