#!/usr/bin/env bats
# package-for-claude.bats -- tools/package-for-claude.sh builds ZIPs that
# claude.ai accepts for the Claude Desktop Chat and Cowork tabs, and never
# touches files it did not create.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PKG="$REPO/tools/package-for-claude.sh"

setup() {
  SANDBOX="$(mktemp -d -t package-for-claude.XXXXXX)"
  OUT="$SANDBOX/zips"
}

teardown() {
  rm -rf "$SANDBOX"
}

manifest() {
  printf '{"skills": [%s]}\n' "$1" > "$SANDBOX/manifest.json"
}

@test "every manifest skill packs as NAME/SKILL.md with upload-safe frontmatter only" {
  run bash "$PKG" --output "$OUT" --quiet
  [ "$status" -eq 0 ]
  run python3 - "$REPO/tools/claude-desktop-skills.json" "$OUT" <<'PY'
import json, re, sys, zipfile
allowed = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
for name in json.load(open(sys.argv[1]))["skills"]:
    z = zipfile.ZipFile(f"{sys.argv[2]}/{name}.zip")
    names = z.namelist()
    assert f"{name}/SKILL.md" in names, f"{name}: no SKILL.md"
    assert f"{name}/skill.md" not in names, f"{name}: lowercase skill.md shipped"
    fm = re.match(r"\A---\n(.*?)\n---\n", z.read(f"{name}/SKILL.md").decode(), re.S).group(1)
    keys = set(re.findall(r"^([A-Za-z0-9_-]+):", fm, re.M))
    assert keys <= allowed, f"{name}: disallowed keys {sorted(keys - allowed)}"
    assert "name" in keys and "description" in keys, f"{name}: missing name/description"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "companion files ship with the skill" {
  manifest '"debate"'
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 0 ]
  unzip -Z1 "$OUT/debate.zip" | grep -qx 'debate/reference.md'
}

@test "a rebuild with no source changes reports nothing to re-upload" {
  manifest '"debate", "think-twice"'
  bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(0 new or changed)"* ]]
  [[ "$output" == *"debate.zip  (unchanged)"* ]]
}

@test "refuses an output dir holding non-ZIP files and leaves them alone" {
  mkdir -p "$OUT"
  echo keep > "$OUT/notes.txt"
  run bash "$PKG" --output "$OUT" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"did not make"* ]]
  [ "$(cat "$OUT/notes.txt")" = keep ]
}

@test "rejects a manifest name that could escape the skills tree" {
  manifest '"../etc"'
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid skill name"* ]]
  [ ! -e "$OUT" ]
}

@test "drops ZIPs for skills removed from the manifest unless --keep" {
  mkdir -p "$SANDBOX/retired-skill"
  echo x > "$SANDBOX/retired-skill/SKILL.md"
  mkdir -p "$OUT"
  (cd "$SANDBOX" && zip -qr "$OUT/retired-skill.zip" retired-skill)
  manifest '"debate"'
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet --keep
  [ "$status" -eq 0 ]
  [ -f "$OUT/retired-skill.zip" ]
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/retired-skill.zip" ]
  [ -f "$OUT/debate.zip" ]
}

@test "refuses an output dir holding a ZIP it did not make and keeps it" {
  mkdir -p "$OUT"
  echo photo > "$SANDBOX/photo.txt"
  (cd "$SANDBOX" && zip -q "$OUT/photos-2024.zip" photo.txt)
  run bash "$PKG" --output "$OUT" --quiet
  [ "$status" -eq 2 ]
  [ -f "$OUT/photos-2024.zip" ]
}

@test "a symlinked output dir gets the same safety check as the real one" {
  mkdir -p "$SANDBOX/real"
  echo keep > "$SANDBOX/real/notes.txt"
  ln -s "$SANDBOX/real" "$OUT"
  run bash "$PKG" --output "$OUT" --quiet
  [ "$status" -eq 2 ]
  [ -f "$SANDBOX/real/notes.txt" ]
}

@test "a refused run creates no directories" {
  manifest '"../etc"'
  run bash "$PKG" --output "$SANDBOX/a/b/out" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 2 ]
  [ ! -e "$SANDBOX/a" ]
}

@test "packaged SKILL.md tells Chat to skip repo-script steps; the summary names changed skills" {
  manifest '"debate"'
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"(1 new or changed: debate)"* ]]
  unzip -p "$OUT/debate.zip" debate/SKILL.md | grep -q 'Packaged for Claude Desktop Chat and Cowork'
}

@test "runs under macOS's stock bash 3.2" {
  [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" = 3 ] || skip "no bash 3.2 at /bin/bash"
  manifest '"debate", "think-twice"'
  run /bin/bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"packaged 2 skills"* ]]
}

# install.sh must finish even when packaging fails. Run the real function body,
# extracted from install.sh, against a stub packager that always fails.
@test "install.sh: a failing packager warns and does not fail the install" {
  mkdir -p "$SANDBOX/repo/tools"
  printf '#!/usr/bin/env bash\necho "ERROR: boom" >&2\nexit 2\n' > "$SANDBOX/repo/tools/package-for-claude.sh"
  run bash -c '
    set -euo pipefail
    source "'"$REPO"'/lib/install/logging.sh"
    SCRIPT_DIR="'"$SANDBOX"'/repo"; CLAUDE_DESKTOP_ZIP_DIR="'"$OUT"'"; CLAUDE_DESKTOP_ZIPS="not built"
    eval "$(sed -n "/^package_claude_desktop_skills()/,/^}/p" "'"$REPO"'/install.sh")"
    package_claude_desktop_skills
    echo "status=$CLAUDE_DESKTOP_ZIPS"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not rebuilt (exit 2)"* ]]
  [[ "$output" == *"output: ERROR: boom"* ]]
  [[ "$output" == *"status=failed (exit 2)"* ]]
}

@test "uninstall.sh --purge removes the Desktop ZIPs and keeps the user's other files" {
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/superpowers-plus-claude-desktop"
  : > "$HOME/superpowers-plus-claude-desktop/debate.zip"
  echo mine > "$HOME/superpowers-plus-claude-desktop/notes.txt"
  run bash "$REPO/uninstall.sh" --yes --purge
  [ ! -e "$HOME/superpowers-plus-claude-desktop/debate.zip" ]
  [ -f "$HOME/superpowers-plus-claude-desktop/notes.txt" ]
}
