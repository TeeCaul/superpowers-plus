#!/usr/bin/env bats
# Skill counts are hand-written in several user-facing files. Each must match
# the number of skill.md files on disk, or the docs contradict each other.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    COUNT="$(find "$REPO_ROOT/skills" -name skill.md | wc -l | tr -d ' ')"
}

assert_count() {
    local file="$1" pattern="$2" found
    found="$(grep -oE "$pattern" "$REPO_ROOT/$file" | grep -oE '[0-9]+' | sort -u)"
    [ -n "$found" ] || { echo "no skill count found in $file"; return 1; }
    [ "$found" = "$COUNT" ] || { echo "$file says $found, disk has $COUNT"; return 1; }
}

@test "README.md skill counts match disk" {
    assert_count README.md '[0-9]+ skills'
}

@test "Claude plugin manifests' skill counts match disk" {
    assert_count .claude-plugin/plugin.json '[0-9]+ skills'
    assert_count .claude-plugin/marketplace.json '[0-9]+ skills'
}

@test "Cursor manifest skill count matches disk" {
    assert_count .cursor-plugin/plugin.json '[0-9]+ skills'
}

@test "Codex and OpenCode install guides' skill counts match disk" {
    assert_count .codex/INSTALL.md '[0-9]+ (superpowers-plus )?skills'
    assert_count .opencode/INSTALL.md '[0-9]+ (superpowers-plus )?skills'
}

@test "UPGRADING.md skill count matches disk" {
    assert_count UPGRADING.md 'contributes [0-9]+ skills'
}

@test "docs/INSTALLATION.md skill counts match disk" {
    assert_count docs/INSTALLATION.md '[0-9]+ superpowers-plus skills|contributes [0-9]+ skills'
}

@test "docs/SKILL_TAXONOMY.md skill counts match disk" {
    assert_count docs/SKILL_TAXONOMY.md '[0-9]+ skills (total|across|grouped)|all [0-9]+ skills'
}

@test "CHANGELOG version headings use the bracketed format release notes rely on" {
    # release.yml extracts a version's notes up to the next '## [' heading; an
    # unbracketed version heading would be swallowed into the previous release.
    run grep -nE '^## ' "$REPO_ROOT/CHANGELOG.md"
    local bad
    bad="$(printf '%s\n' "$output" | grep -vE '^[0-9]+:## \[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+)\]' || true)"
    [ -z "$bad" ] || { echo "non-conforming headings: $bad"; return 1; }
}
