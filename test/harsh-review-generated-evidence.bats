#!/usr/bin/env bats
# .cr-battery-runs/ holds generated, gitignored review-evidence envelopes.
# harsh-review's repo-wide file scans must not lint them: an envelope that
# lacks a trailing newline or has odd formatting is not a source defect, and
# failing the whole battery over it cost repeated reruns.

setup() {
    REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORK="$(mktemp -d)"
    git -C "$WORK" init -q
    git -C "$WORK" config user.email t@t
    git -C "$WORK" config user.name t
    for f in README AGENTS CLAUDE; do printf '# %s\n' "$f" > "$WORK/$f.md"; done
    printf 'root = true\n' > "$WORK/.editorconfig"
    mkdir -p "$WORK/docs" "$WORK/skills" "$WORK/.cr-battery-runs"
    printf '# C\n' > "$WORK/docs/CONTRIBUTING.md"
    printf '# A\n' > "$WORK/docs/ARCHITECTURE.md"
    cp -R "$REPO_ROOT_REAL/tools" "$WORK/tools"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m init
}

teardown() { rm -rf "$WORK"; }

@test "harsh-review ignores an evidence envelope with no trailing newline" {
    printf '{"findings":[]}' > "$WORK/.cr-battery-runs/abc.json"
    run bash "$WORK/tools/harsh-review.sh"
    [[ "$output" != *".cr-battery-runs"* ]]
}

@test "harsh-review still flags a real JSON file with no trailing newline" {
    printf '{"a":1}' > "$WORK/data.json"
    run bash "$WORK/tools/harsh-review.sh"
    [[ "$output" == *"data.json: missing final newline"* ]]
}
