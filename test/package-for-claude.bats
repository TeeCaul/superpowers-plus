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
  [[ "$output" == *"contains non-ZIP files"* ]]
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
  mkdir -p "$OUT"
  : > "$OUT/retired-skill.zip"
  manifest '"debate"'
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet --keep
  [ "$status" -eq 0 ]
  [ -f "$OUT/retired-skill.zip" ]
  run bash "$PKG" --output "$OUT" --manifest "$SANDBOX/manifest.json" --quiet
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/retired-skill.zip" ]
  [ -f "$OUT/debate.zip" ]
}
