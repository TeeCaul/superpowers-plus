#!/usr/bin/env bats
# test/test_dest_name_index.bats
# Tests for skill-naming.sh: _build_dest_name_index, _extract_sp_trigger, _skill_dest_name.
# Verifies alias-aware source→dest mapping used by the doctor's orphan and reference checks.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

# Create shared test fixtures once. Each @test re-sources the library
# and declares fresh arrays — bats runs each test in a subshell.
setup_file() {
  export TEST_TMPDIR
  TEST_TMPDIR=$(mktemp -d)

  _mk_skill() {
    local dir="$1" name_val="$2" triggers_line="$3"
    mkdir -p "$dir"
    printf -- '---\nname: %s\n%s\n---\nBody.\n' "$name_val" "$triggers_line" > "$dir/skill.md"
  }

  # repo-a: one aliased skill (brainstorming→sp-brainstorm), one self-named (codebase-recon)
  _mk_skill "$TEST_TMPDIR/repo-a/skills/brainstorming" "brainstorming" \
      'triggers: ["/sp-brainstorm", "brainstorm"]'
  _mk_skill "$TEST_TMPDIR/repo-a/skills/codebase-recon" "codebase-recon" \
      'triggers: ["recon", "audit"]'

  # repo-b: aliased skill via single-quote inline
  _mk_skill "$TEST_TMPDIR/repo-b/skills/think-twice" "think-twice" \
      "triggers: ['/sp-rethink', 'second opinion']"

  # repo-c: multi-line inline YAML array (the format _extract_sp_trigger must now handle)
  mkdir -p "$TEST_TMPDIR/repo-c/skills/plan-and-execute"
  printf -- '---\nname: plan-and-execute\ntriggers: [\n  "/sp-plan",\n  "plan"\n]\n---\nBody.\n' \
      > "$TEST_TMPDIR/repo-c/skills/plan-and-execute/skill.md"

  # repo-d: block-list format with trailing whitespace (regression guard)
  mkdir -p "$TEST_TMPDIR/repo-d/skills/systematic-debugging"
  printf -- '---\nname: systematic-debugging\ntriggers:\n  - /sp-debug  \n  - debug\n---\nBody.\n' \
      > "$TEST_TMPDIR/repo-d/skills/systematic-debugging/skill.md"

  # repo-e: two skills colliding on same /sp* trigger (collision warning test)
  _mk_skill "$TEST_TMPDIR/repo-e/skills/skill-alpha" "skill-alpha" \
      'triggers: ["/sp-dupe", "alpha"]'
  _mk_skill "$TEST_TMPDIR/repo-e/skills/skill-beta" "skill-beta" \
      'triggers: ["/sp-dupe", "beta"]'
}

teardown_file() {
  rm -rf "$TEST_TMPDIR"
}

# Source the library and declare fresh arrays inside each test.
_setup_index() {
  # shellcheck source=lib/install/skill-naming.sh
  source "$REPO_ROOT/lib/install/skill-naming.sh"
  declare -gA SOURCE_DEST_NAME=() DEST_NAME_SOURCE=() DEST_NAMES_SET=()
}

# ── _build_dest_name_index: single-repo basics ─────────────────────────────

@test "aliased skill: source 'brainstorming' maps to dest 'sp-brainstorm'" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ "${SOURCE_DEST_NAME[brainstorming]}" == "sp-brainstorm" ]]
}

@test "non-aliased skill: 'codebase-recon' maps to itself" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ "${SOURCE_DEST_NAME[codebase-recon]}" == "codebase-recon" ]]
}

@test "reverse lookup: dest 'sp-brainstorm' points back to source 'brainstorming'" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ "${DEST_NAME_SOURCE[sp-brainstorm]}" == "brainstorming" ]]
}

@test "DEST_NAMES_SET contains alias dest name 'sp-brainstorm'" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ "${DEST_NAMES_SET[sp-brainstorm]}" == "1" ]]
}

@test "DEST_NAMES_SET contains self-named dest 'codebase-recon'" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ "${DEST_NAMES_SET[codebase-recon]}" == "1" ]]
}

@test "DEST_NAMES_SET does NOT contain source name 'brainstorming'" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a"
  [[ -z "${DEST_NAMES_SET[brainstorming]:-}" ]]
}

# ── _build_dest_name_index: multiple repos ──────────────────────────────────

@test "multiple repos accumulate: repo-a brainstorming entry survives" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a" "$TEST_TMPDIR/repo-b"
  [[ "${SOURCE_DEST_NAME[brainstorming]}" == "sp-brainstorm" ]]
}

@test "multiple repos accumulate: repo-b think-twice→sp-rethink added" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a" "$TEST_TMPDIR/repo-b"
  [[ "${SOURCE_DEST_NAME[think-twice]}" == "sp-rethink" ]]
}

# ── _build_dest_name_index: path conventions ────────────────────────────────

@test "accepts skills-root path directly (not repo root)" {
  _setup_index
  _build_dest_name_index "$TEST_TMPDIR/repo-a/skills"
  [[ "${SOURCE_DEST_NAME[brainstorming]}" == "sp-brainstorm" ]]
}

@test "empty root is a no-op: SOURCE_DEST_NAME stays empty" {
  _setup_index
  local empty_root
  empty_root=$(mktemp -d)
  _build_dest_name_index "$empty_root"
  rmdir "$empty_root"
  [[ "${#SOURCE_DEST_NAME[@]}" -eq 0 ]]
}

# ── _extract_sp_trigger: multi-line inline YAML (regression for F1) ─────────

@test "_extract_sp_trigger handles multi-line inline YAML array" {
  # shellcheck source=lib/install/skill-naming.sh
  source "$REPO_ROOT/lib/install/skill-naming.sh"
  _build_dest_name_index "$TEST_TMPDIR/repo-c"
  [[ "${SOURCE_DEST_NAME[plan-and-execute]}" == "sp-plan" ]]
}

# ── _extract_sp_trigger: block-list trailing whitespace (regression for F4) ─

@test "_extract_sp_trigger block-list path trims trailing whitespace" {
  # shellcheck source=lib/install/skill-naming.sh
  source "$REPO_ROOT/lib/install/skill-naming.sh"
  _build_dest_name_index "$TEST_TMPDIR/repo-d"
  [[ "${SOURCE_DEST_NAME[systematic-debugging]}" == "sp-debug" ]]
}

# ── _build_dest_name_index: collision detection (regression for F3) ─────────

@test "collision on same /sp* trigger emits warning to stderr" {
  # shellcheck source=lib/install/skill-naming.sh
  source "$REPO_ROOT/lib/install/skill-naming.sh"
  declare -gA SOURCE_DEST_NAME=() DEST_NAME_SOURCE=() DEST_NAMES_SET=()
  # bats 1.5+ merges stderr into $output by default; the warning goes to >&2 but
  # is captured in $output under the default run mode.
  run _build_dest_name_index "$TEST_TMPDIR/repo-e"
  [[ "$output" =~ "WARNING" ]]
}

# --- Nested worktrees -----------------------------------------------------
# A nested worktree inside the scanned tree is skipped; a repo that is itself
# checked out under a ".worktrees/" directory is still indexed.
_wt_index() {  # $1 = root to index; prints the indexed source names, sorted
  bash -c 'source "$REPO_ROOT/lib/install/skill-naming.sh"
    declare -A SOURCE_DEST_NAME DEST_NAME_SOURCE DEST_NAMES_SET
    _build_dest_name_index "$1"
    printf "%s\n" "${!SOURCE_DEST_NAME[@]}" | sort | tr "\n" " "' _ "$1"
}
_wt_skill() { mkdir -p "$1"; printf -- '---\nname: %s\n---\nBody.\n' "${1##*/}" > "$1/skill.md"; }

@test "worktrees: a repo checked out under a .worktrees/ directory is indexed" {
  local d; d="$(mktemp -d)"
  _wt_skill "$d/.worktrees/repo/skills/alpha"
  run _wt_index "$d/.worktrees/repo"
  [ "$output" = "alpha " ]
  run _wt_index "$d/.worktrees/repo/skills/"
  [ "$output" = "alpha " ]
  rm -rf "$d"
}

@test "worktrees: a nested worktree inside skills/ is skipped" {
  local d; d="$(mktemp -d)"
  _wt_skill "$d/repo/skills/alpha"
  _wt_skill "$d/repo/skills/.worktrees/branch/skills/zeta"
  run _wt_index "$d/repo"
  [ "$output" = "alpha " ]
  rm -rf "$d"
}

@test "worktrees: a directory whose name merely ends in .worktrees is still indexed" {
  local d; d="$(mktemp -d)"
  _wt_skill "$d/repo/skills/alpha"
  _wt_skill "$d/repo/skills/my.worktrees/beta"
  run _wt_index "$d/repo"
  [ "$output" = "alpha beta " ]
  rm -rf "$d"
}
