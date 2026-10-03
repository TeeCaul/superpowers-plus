#!/usr/bin/env bash
# package-for-claude.sh -- Package superpowers-plus skills for the Claude Desktop app (Chat and Cowork)
#
# Each skill becomes <name>.zip -> <name>/SKILL.md plus every companion file in
# the skill's folder. claude.ai uploads accept only six frontmatter keys (name,
# description, license, compatibility, metadata, allowed-tools) and reject the
# upload on any other key, so the packaged SKILL.md keeps only those. The source
# skill.md in this repo is never modified. The packaged copy also gets a short
# note telling Claude to skip steps that need this repo's scripts, since Chat
# and Cowork don't have a copy of the repo.
# Rules: https://code.claude.com/docs/en/skills#using-skill-frontmatter-outside-claude-code
#
# Usage: ./tools/package-for-claude.sh [--output DIR] [--manifest FILE] [--keep] [--quiet]
#   --output DIR     Write ZIPs here (default: ~/superpowers-plus-claude-desktop)
#   --manifest FILE  Skill list to package (default: tools/claude-desktop-skills.json)
#   --keep           Keep ZIPs for skills no longer in the manifest
#   --quiet          Print only the summary line and errors (used by install.sh)
# Requires: bash 3.2+, python3, zip, unzip
# Exit codes: 0 packaged, 1 a skill failed to package, 2 usage error or safety refusal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_MANIFEST="$SCRIPT_DIR/claude-desktop-skills.json"
DEFAULT_OUTDIR="$HOME/superpowers-plus-claude-desktop"
# Written into every packaged SKILL.md; how this script recognizes its own ZIPs.
PACKAGED_MARKER="Packaged for Claude Desktop Chat and Cowork"

# ── CLI args ──────────────────────────────────────────────────────────────────
MANIFEST="$DEFAULT_MANIFEST"
OUTDIR="$DEFAULT_OUTDIR"
KEEP=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output=*)
      OUTDIR="${1#--output=}"
      [[ -n "$OUTDIR" ]] || { echo "ERROR: --output= requires a non-empty value" >&2; exit 2; }
      shift ;;
    --output)
      [[ $# -ge 2 ]] || { echo "ERROR: --output requires a value" >&2; exit 2; }
      OUTDIR="$2"; shift 2 ;;
    --manifest=*)
      MANIFEST="${1#--manifest=}"
      [[ -n "$MANIFEST" ]] || { echo "ERROR: --manifest= requires a non-empty value" >&2; exit 2; }
      shift ;;
    --manifest)
      [[ $# -ge 2 ]] || { echo "ERROR: --manifest requires a value" >&2; exit 2; }
      MANIFEST="$2"; shift 2 ;;
    --keep)     KEEP=1;  shift ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { [[ $QUIET -eq 1 ]] || echo "$@"; }

# ── Validate inputs before any side effects ────────────────────────────────────
[[ -d "$REPO_ROOT/skills" ]] || {
  echo "ERROR: $REPO_ROOT/skills not found -- is this the superpowers-plus repo?" >&2; exit 1
}
[[ -f "$MANIFEST" ]] || { echo "ERROR: Manifest not found: $MANIFEST" >&2; exit 2; }
for _cmd in python3 zip unzip; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "ERROR: $_cmd is required" >&2; exit 1; }
done

# ── Parse manifest (python3: bash 3.2 compatible, no jq dependency) ────────────
SKILLS_RAW=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    sys.exit(f'ERROR: manifest is not valid JSON: {e}')
if not isinstance(data.get('skills'), list):
    sys.exit('ERROR: manifest needs a \"skills\" list')
for s in data['skills']:
    print(s)
" "$MANIFEST") || { echo "ERROR: Failed to parse manifest: $MANIFEST" >&2; exit 2; }

SKILLS=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # Names become file paths below, so validate them before any filesystem use.
  [[ "$line" =~ ^[a-z0-9-]+$ ]] || {
    echo "ERROR: Invalid skill name in manifest (lowercase letters, digits, hyphens only): '$line'" >&2; exit 2
  }
  SKILLS+=("$line")
done <<< "$SKILLS_RAW"
[[ ${#SKILLS[@]} -gt 0 ]] || { echo "ERROR: No skills found in manifest: $MANIFEST" >&2; exit 2; }

# ── Pre-flight: every skill must resolve to exactly one skill.md ───────────────
skill_md_for() {
  find "$REPO_ROOT/skills" -type f -name "skill.md" -path "*/$1/skill.md" 2>/dev/null
}
MISSING=()
for name in "${SKILLS[@]}"; do
  _found="$(skill_md_for "$name")" || _found=""
  _count=0
  [[ -z "$_found" ]] || _count=$(printf '%s\n' "$_found" | grep -c .)
  if [[ $_count -eq 0 ]]; then
    MISSING+=("$name")
  elif [[ $_count -gt 1 ]]; then
    echo "ERROR: '$name' matches $_count skill folders; rename one so the ZIP is unambiguous:" >&2
    printf '%s\n' "$_found" | sed 's/^/  - /' >&2
    exit 1
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Skills not found in source tree (fix the manifest before packaging):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  exit 1
fi

# ── Resolve OUTDIR (no side effects yet) ──────────────────────────────────────
# pwd -P resolves symlinks, so a symlinked --output is checked and written as
# the real directory it points at.
if [[ -e "$OUTDIR" ]]; then
  [[ -d "$OUTDIR" ]] || { echo "ERROR: '$OUTDIR' exists and is not a directory" >&2; exit 2; }
  OUTDIR="$(cd "$OUTDIR" && pwd -P)"
elif [[ -d "$(dirname "$OUTDIR")" ]]; then
  OUTDIR="$(cd "$(dirname "$OUTDIR")" && pwd -P)/$(basename "$OUTDIR")"
fi

# is_our_zip ZIP: true when every entry sits under <name>/, <name>/SKILL.md
# exists, and that SKILL.md carries the note this script writes. Only those are
# ever overwritten or pruned, so neither a mistyped --output nor a skill ZIP the
# user made elsewhere gets deleted. uninstall.sh applies the same rule.
is_our_zip() {
  local base listing
  base="$(basename "$1" .zip)"
  listing="$(unzip -Z1 "$1" 2>/dev/null)" || return 1
  local line has_skill=0
  while IFS= read -r line; do
    [[ "$line" == "$base/"* ]] || return 1
    [[ "$line" == "$base/SKILL.md" ]] && has_skill=1
  done <<< "$listing"
  [[ $has_skill -eq 1 ]] || return 1
  # Capture, then match: piping into grep -q under pipefail can fail on a
  # match, because grep exits early and unzip dies of SIGPIPE.
  local body
  body="$(unzip -p "$1" "$base/SKILL.md" 2>/dev/null)" || return 1
  [[ "$body" == *"$PACKAGED_MARKER"* ]]
}

# ── OUTDIR must be new, empty, or hold only ZIPs this script made ─────────────
if [[ -d "$OUTDIR" ]]; then
  _unsafe=$(find "$OUTDIR" -mindepth 1 -maxdepth 1 \
    ! -name "*.zip" ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "desktop.ini" \
    -print -quit 2>/dev/null)
  if [[ -z "$_unsafe" ]]; then
    for _f in "$OUTDIR"/*.zip; do
      [[ -e "$_f" ]] || continue
      is_our_zip "$_f" || { _unsafe="$_f"; break; }
    done
  fi
  if [[ -n "$_unsafe" ]]; then
    echo "ERROR: Refusing to write to '$OUTDIR' -- it holds files this script did not make (e.g. $_unsafe)." >&2
    echo "       Use an empty or new directory, or pass --output with a dedicated path." >&2
    exit 2
  fi
fi

# ── Helpers (python3) ──────────────────────────────────────────────────────────
# write_upload_skill SRC DEST NAME: write DEST/SKILL.md from SRC with frontmatter
# reduced to the upload-safe keys; fail if name/description break upload rules.
write_upload_skill() {
  python3 - "$1" "$2" "$3" "$PACKAGED_MARKER" <<'PY'
import re, sys
src, dest, name, marker = sys.argv[1:5]
ALLOWED = ("name", "description", "license", "compatibility", "metadata", "allowed-tools")
text = open(src, encoding="utf-8").read()
m = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
if not m:
    sys.exit(f"ERROR: {src} has no YAML frontmatter")
blocks, order, cur = {}, [], None
for line in m.group(1).split("\n"):
    k = re.match(r"^([A-Za-z0-9_-]+):", line)
    if k:
        cur = k.group(1); order.append(cur); blocks[cur] = [line]
    elif cur is not None:
        blocks[cur].append(line)
if blocks.get("name", [""])[0].split(":", 1)[-1].strip().strip("'\"") != name:
    sys.exit(f"ERROR: {src}: frontmatter name must equal the folder name '{name}'")
if "description" not in blocks:
    sys.exit(f"ERROR: {src}: frontmatter has no description")
desc = " ".join(blocks["description"]).split(":", 1)[1].strip().strip("'\"")
if len(desc) > 1024:
    sys.exit(f"ERROR: {src}: description is {len(desc)} chars; uploads allow 1024")
if "<" in desc or ">" in desc:
    sys.exit(f"ERROR: {src}: description contains < or >, which uploads reject")
kept = [l for k in order if k in ALLOWED for l in blocks[k]]
NOTE = (f"\n> **{marker}.** These tabs have no superpowers-plus "
        "checkout and no access to your machine's shell. Skip any step that runs a repo script (`tools/...`, "
        "`~/.codex/...`) or calls a skill you don't have, say in one line that you skipped it, "
        "and carry out the rest.\n")
open(f"{dest}/SKILL.md", "w", encoding="utf-8").write("---\n" + "\n".join(kept) + "\n---\n" + NOTE + text[m.end():])
PY
}

# digest PATH: stable hash of a skill's packaged content, from a folder or a ZIP,
# so a rebuild can say which skills changed and need re-uploading.
digest() {
  python3 - "$1" <<'PY'
import hashlib, os, sys, zipfile
p, h, items = sys.argv[1], hashlib.sha256(), []
if os.path.isdir(p):
    for root, _, files in os.walk(p):
        for f in files:
            full = os.path.join(root, f)
            items.append((os.path.relpath(full, os.path.dirname(p)), open(full, "rb").read()))
else:
    try:
        with zipfile.ZipFile(p) as z:
            items = [(i.filename, z.read(i)) for i in z.infolist() if not i.is_dir()]
    except (zipfile.BadZipFile, OSError):
        print("unreadable"); sys.exit(0)
for rel, data in sorted(items):
    h.update(rel.encode() + b"\0" + hashlib.sha256(data).digest())
print(h.hexdigest())
PY
}

# ── Package each skill ─────────────────────────────────────────────────────────
TMPWORK="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMPWORK"' EXIT
mkdir -p "$OUTDIR" || { echo "ERROR: Cannot create output dir: $OUTDIR" >&2; exit 2; }
# Absolute from here on: zip runs from inside $TMPWORK.
OUTDIR="$(cd "$OUTDIR" && pwd -P)"

FAIL=0
PACKED=()
CHANGED=()
for name in "${SKILLS[@]}"; do
  src_md="$(skill_md_for "$name")"
  src_dir="$(dirname "$src_md")"
  work_dir="$TMPWORK/$name"
  zip_path="$OUTDIR/$name.zip"

  # -L copies symlink targets, so the ZIP never holds a link Desktop can't follow.
  if ! cp -RL "$src_dir" "$work_dir"; then
    echo "ERROR: copy failed for '$name'" >&2; FAIL=1; continue
  fi
  rm -f "$work_dir/skill.md"
  if ! write_upload_skill "$src_md" "$work_dir" "$name"; then
    FAIL=1; continue
  fi

  new_digest="$(digest "$work_dir")" || { echo "ERROR: could not hash '$name'" >&2; FAIL=1; continue; }
  old_digest=""
  if [[ -f "$zip_path" ]]; then
    old_digest="$(digest "$zip_path")" || old_digest=""
  fi

  rm -f "$zip_path"
  if ! (cd "$TMPWORK" && zip -qrX "$zip_path" "$name/"); then
    echo "ERROR: zip failed for '$name'" >&2; rm -f "$zip_path"; FAIL=1; continue
  fi

  # Validate from the archive listing, not the filesystem: macOS is
  # case-insensitive, so a stray skill.md would pass a file-exists check.
  listing="$(unzip -Z1 "$zip_path")" \
    || { echo "ERROR: cannot list '$name' ZIP (unzip -Z1 failed)" >&2; rm -f "$zip_path"; FAIL=1; continue; }
  expected="$(cd "$TMPWORK" && find "$name" -type f | sort)"
  if ! grep -qx "$name/SKILL.md" <<< "$listing"; then
    echo "ERROR: '$name' ZIP has no $name/SKILL.md entry" >&2; rm -f "$zip_path"; FAIL=1; continue
  fi
  if [[ "$(grep -v '/$' <<< "$listing" | sort)" != "$expected" ]]; then
    echo "ERROR: '$name' ZIP contents differ from the skill folder" >&2; rm -f "$zip_path"; FAIL=1; continue
  fi

  PACKED+=("$name")
  if [[ "$new_digest" != "$old_digest" ]]; then
    CHANGED+=("$name")
    say "  $name.zip  (new or changed: upload it)"
  else
    say "  $name.zip  (unchanged)"
  fi
done

# ── Remove ZIPs for skills dropped from the manifest ───────────────────────────
if [[ $KEEP -eq 0 ]]; then
  for _f in "$OUTDIR"/*.zip; do
    [[ -f "$_f" ]] || continue
    _base="$(basename "$_f" .zip)"
    _listed=0
    for name in "${SKILLS[@]}"; do [[ "$name" == "$_base" ]] && _listed=1; done
    if [[ $_listed -eq 0 ]] && is_our_zip "$_f"; then
      rm -f "$_f"; say "  removed $_base.zip (no longer in the manifest)"
    fi
  done
fi

# ── Result ─────────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
  echo "ERROR: One or more skills failed to package. Fix the errors above and re-run." >&2
  exit 1
fi

_changed_list=""
[[ ${#CHANGED[@]} -eq 0 ]] || _changed_list=": $(printf '%s, ' "${CHANGED[@]}" | sed 's/, $//')"
echo "Claude Desktop: packaged ${#PACKED[@]} skills into $OUTDIR (${#CHANGED[@]} new or changed${_changed_list})"
if [[ $QUIET -eq 0 ]]; then
  echo ""
  echo "To use them in the Claude Desktop Chat and Cowork tabs:"
  echo "  1. Open https://claude.ai/customize/skills (or Customize in the Desktop sidebar)"
  echo "  2. Upload each new or changed .zip from: $OUTDIR"
  echo "  3. Turn each skill on after upload"
fi
