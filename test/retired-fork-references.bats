#!/usr/bin/env bats
# obra/superpowers skills have been bundled in this repo since v2.6.0; the
# bordenet/superpowers fork and the separate "superpowers-core" install step
# are retired. Docs, skills, and tools must not send users or agents to them.
# Historical notes ("no longer clones ...") and the CHANGELOG are allowed.

@test "no live references to the retired bordenet/superpowers fork or superpowers-core" {
    cd "$BATS_TEST_DIRNAME/.."
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git checkout"
    run bash -c "git grep -nE 'bordenet/superpowers([^-]|\$)|superpowers-core' -- . \
        ':!CHANGELOG.md' ':!test/golden-compression' ':!test/retired-fork-references.bats' \
        | grep -v 'no longer clones'"
    [ -z "$output" ] || { echo "$output"; return 1; }
}
