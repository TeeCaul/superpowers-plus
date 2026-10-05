#!/usr/bin/env bats
# wiki-tree-sweep.bats -- tests for tools/wiki-tree-sweep.py
#
# A stub wiki-api (WIKI_API) answers from fixture files named
# <endpoint>__<key>.json in $FIX, where <key> is the request's "id", or
# "<parentDocumentId>@<offset>" for documents.list. A sibling
# <endpoint>__<key>.fail file holding a number N makes the next N calls
# return a 429 body first. No documents.list fixture = 404, so by default
# every page falls back to a one-page documents.info read.
#
# RUN: bats tests/tools/wiki-tree-sweep.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  TOOL="$REPO_ROOT/tools/wiki-tree-sweep.py"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"
  export FIX
  export WIKI_TREE_SWEEP_BACKOFF=0

  cat > "$BATS_TEST_TMPDIR/wiki-api" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
endpoint="$1"
id=$(printf '%s' "$2" | python3 -c '
import json,sys
b=json.load(sys.stdin)
print(b["id"] if "id" in b else "%s@%s" % (b["parentDocumentId"], b.get("offset", 0)))')
echo "$endpoint $id" >> "$FIX/calls.log"
fail="$FIX/${endpoint}__${id}.fail"
if [[ -f "$fail" ]]; then
  n=$(cat "$fail")
  if (( n > 0 )); then
    echo $((n - 1)) > "$fail"
    echo '{"ok":false,"error":"rate_limit_exceeded","status":429}'
    exit 0
  fi
fi
f="$FIX/${endpoint}__${id}.json"
if [[ -f "$f" ]]; then cat "$f"; else echo '{"ok":false,"error":"not_found","status":404}'; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/wiki-api"
  export WIKI_API="$BATS_TEST_TMPDIR/wiki-api"

  # Collection tree:  other-root
  #                   root -> a -> a1 -> a1x      (a1x is four levels down)
  #                        -> b
  cat > "$FIX/collections.documents__col1.json" <<'JSON'
{"ok":true,"data":[
 {"id":"other-root","title":"Other","url":"/doc/other","children":[]},
 {"id":"root","title":"Root","url":"/doc/root","children":[
   {"id":"a","title":"A","url":"/doc/a","children":[
     {"id":"a1","title":"A1","url":"/doc/a1","children":[
       {"id":"a1x","title":"A1X","url":"/doc/a1x","children":[]}]}]},
   {"id":"b","title":"B","url":"/doc/b","children":[]}]}]}
JSON
  page root Root "intro line\nnothing here"
  page a    A    "alpha\nneedle in A"
  page a1   A1   "plain"
  page a1x  A1X  "deep needle"
  page b    B    "beta"
  page other-root Other "needle outside the tree"
}

# page ID TITLE TEXT -- TEXT uses JSON escapes (\n) and is stored escaped.
page() {
  printf '{"ok":true,"data":{"id":"%s","title":"%s","collectionId":"col1","text":"%s","updatedAt":"2026-10-01T00:00:00Z"}}\n' \
    "$1" "$2" "$3" > "$FIX/documents.info__$1.json"
}

@test "search finds matches at every depth and nothing outside the root" {
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tA\t/doc/a\t2\tneedle in A'* ]]
  [[ "$output" == *$'3\tA1X\t/doc/a1x\t1\tdeep needle'* ]]
  [[ "$output" != *"outside the tree"* ]]
  [[ "$stderr" == *"5 of 5 page(s) searched; 2 match(es) on 2 page(s)"* ]]
}

@test "tree shape comes from one collections.documents call" {
  run python3 "$TOOL" --list root
  [ "$status" -eq 0 ]
  [ "$(grep -c '^collections.documents' "$FIX/calls.log")" -eq 1 ]
  ! grep -q '^documents.list' "$FIX/calls.log"
}

@test "--list prints the subtree indented by depth in page order" {
  run --separate-stderr python3 "$TOOL" --list root
  [ "$status" -eq 0 ]
  expected=$'Root\t/doc/root\n  A\t/doc/a\n    A1\t/doc/a1\n      A1X\t/doc/a1x\n  B\t/doc/b'
  [ "$output" = "$expected" ]
}

@test "no matches exits 1" {
  run python3 "$TOOL" root 'zzz-not-present'
  [ "$status" -eq 1 ]
}

@test "-i matches case-insensitively" {
  run --separate-stderr python3 "$TOOL" -i root 'NEEDLE IN'
  [ "$status" -eq 0 ]
  [[ "$output" == *"needle in A"* ]]
}

@test "a page URL is accepted as the root" {
  run python3 "$TOOL" --list "https://wiki.example.test/doc/root?x=1"
  [ "$status" -eq 0 ]
  grep -q '^documents.info root$' "$FIX/calls.log"
}

@test "raw newline inside page text is kept as a line break, not deleted" {
  # Invalid JSON on purpose: a literal newline byte inside the text string.
  printf '{"ok":true,"data":{"id":"b","title":"B","collectionId":"col1","text":"first\nsecond needle"}}' \
    > "$FIX/documents.info__b.json"
  run --separate-stderr python3 "$TOOL" root 'second needle'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'B\t/doc/b\t2\tsecond needle'* ]]
  [[ "$output" != *"firstsecond"* ]]
}

@test "a rate-limited page is retried and the sweep completes" {
  echo 2 > "$FIX/documents.info__a1x.fail"
  run --separate-stderr python3 "$TOOL" root 'deep needle'
  [ "$status" -eq 0 ]
  [[ "$output" == *"deep needle"* ]]
  [ "$(grep -c '^documents.info a1x$' "$FIX/calls.log")" -eq 3 ]
}

@test "a page that keeps failing aborts with exit 3 and no partial success" {
  echo 99 > "$FIX/documents.info__b.fail"
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"fetching 'B' (b)"* ]]
  [[ "$stderr" == *"aborting"* ]]
}

@test "--keep-going reports the skipped page and exits 4" {
  echo 99 > "$FIX/documents.info__b.fail"
  run --separate-stderr python3 "$TOOL" --keep-going root needle
  [ "$status" -eq 4 ]
  [[ "$output" == *"deep needle"* ]]
  [[ "$stderr" == *"INCOMPLETE: 1 page(s) not fetched: B (b)"* ]]
}

@test "a non-retryable API error is not retried" {
  rm "$FIX/documents.info__a1.json"
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 3 ]
  [ "$(grep -c '^documents.info a1$' "$FIX/calls.log")" -eq 1 ]
}

@test "a root missing from the published tree (draft) exits 3" {
  printf '{"ok":true,"data":{"id":"draft","title":"Draft","collectionId":"col1","text":""}}' \
    > "$FIX/documents.info__draft.json"
  run --separate-stderr python3 "$TOOL" --list draft
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not in its collection's published tree"* ]]
}

@test "a root with no collection exits 3" {
  printf '{"ok":true,"data":{"id":"loose","title":"Loose","collectionId":null,"text":""}}' \
    > "$FIX/documents.info__loose.json"
  run --separate-stderr python3 "$TOOL" --list loose
  [ "$status" -eq 3 ]
}

@test "--jsonl emits one record per page with text and parent" {
  run --separate-stderr python3 "$TOOL" --jsonl root
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
  rec=$(printf '%s\n' "$output" | python3 -c '
import json,sys
r=[json.loads(l) for l in sys.stdin][3]
print(r["id"], r["depth"], r["parentDocumentId"], r["textLen"], r["updatedAt"])')
  [ "$rec" = "a1x 3 a1 11 2026-10-01T00:00:00Z" ]
}

# listing PARENT OFFSET ID:TEXT... -- a documents.list page of children
listing() {
  local parent="$1" offset="$2" items="" sep="" pair
  shift 2
  for pair in "$@"; do
    items+="$sep{\"id\":\"${pair%%:*}\",\"title\":\"${pair%%:*}\",\"text\":\"${pair#*:}\"}"
    sep=","
  done
  printf '{"ok":true,"data":[%s]}\n' "$items" > "$FIX/documents.list__${parent}@${offset}.json"
}

@test "batched reads cover the tree without per-page fetches" {
  listing root 0 "a:needle in A" "b:beta"
  listing a 0 "a1:plain"
  listing a1 0 "a1x:deep needle"
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"needle in A"* && "$output" == *"deep needle"* ]]
  # Only the root lookup during discovery uses documents.info.
  [ "$(grep -c '^documents.info' "$FIX/calls.log")" -eq 1 ]
}

@test "a page missing from its batch is fetched on its own, not dropped" {
  listing root 0 "a:needle in A"          # b is missing from the batch
  listing a 0 "a1:plain"
  listing a1 0 "a1x:deep needle"
  page b B "needle only in B"
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"needle only in B"* ]]
  grep -q '^documents.info b$' "$FIX/calls.log"
}

@test "a parent with more than 100 children is paged until every child is read" {
  local fill=() i
  for i in $(seq 1 99); do fill+=("x$i:filler"); done
  listing root 0 "a:needle in A" "${fill[@]}"     # 100 entries, b not yet seen
  listing root 100 "b:needle in B"
  listing a 0 "a1:plain"
  listing a1 0 "a1x:deep needle"
  run --separate-stderr python3 "$TOOL" root needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"needle in B"* ]]
  grep -q '^documents.list root@100$' "$FIX/calls.log"
  ! grep -q '^documents.info b$' "$FIX/calls.log"
  [[ "$output" != *"filler"* ]]
}

@test "--max-pages refuses an oversized tree before fetching any page text" {
  run --separate-stderr python3 "$TOOL" --max-pages 3 root needle
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"over --max-pages 3"* ]]
  ! grep -q '^documents.info a$' "$FIX/calls.log"
}

@test "usage errors exit 2" {
  run python3 "$TOOL" root
  [ "$status" -eq 2 ]
  run python3 "$TOOL" --list --jsonl root
  [ "$status" -eq 2 ]
  run python3 "$TOOL" root '('
  [ "$status" -eq 2 ]
  run python3 "$TOOL" --bogus root x
  [ "$status" -eq 2 ]
  run python3 "$TOOL" --list ''
  [ "$status" -eq 2 ]
  [ ! -f "$FIX/calls.log" ]
}

@test "--help prints usage and exits 0" {
  run python3 "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}
