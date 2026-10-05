#!/usr/bin/env python3
"""wiki-tree-sweep.py -- search (or list) an Outline page and every page beneath it.

Usage:
  wiki-tree-sweep.py [options] <root> <pattern>   search every page in the tree
  wiki-tree-sweep.py --list [options] <root>      print the tree, no search
  wiki-tree-sweep.py --jsonl [options] <root>     one JSON record per page, with text

  <root>     page id, URL slug, or full page URL
  <pattern>  Python regular expression, matched against each line of page text

Options:
  -i, --ignore-case   case-insensitive pattern match
  --keep-going        skip pages that fail to fetch, print the rest, exit 4
  --max-pages N       refuse trees larger than N pages (default 2000; exit 5)
  --delay SECONDS     pause between API calls (default 0.1)
  -v, --verbose       progress on stderr
  -h, --help          show this help

Output (search mode): one line per match, tab-separated:
  <depth> <title> <url> <line-number> <line>
Nothing is written to stdout until every page has been read, so a run that
exits 3 leaves stdout empty. Only --keep-going prints a known-incomplete result
(exit 4), and stderr names the pages it skipped.

Exit codes:
  0  search found matches, or --list / --jsonl completed
  1  search completed with no matches
  2  usage error
  3  wiki API failure or unexpected response; stdout is empty
  4  --keep-going finished, but one or more pages could not be fetched
  5  tree is larger than --max-pages; re-run with a higher --max-pages

How it works: one collections.documents call returns the collection's whole
published page tree, and the subtree under <root> is cut from it, so the tree
shape never depends on a hand-paginated walk. Page text is then read in batches
with documents.list (one call per 100 children of each parent). The expected
children are already known from the tree, so any page a batch misses is read
on its own with documents.info instead of being dropped. If a batch call fails,
batching stops and every remaining page is read on its own.
Draft pages are not part of the published tree, so a draft root or draft
children are not swept; a draft root exits 3.

Responses are parsed leniently: a raw newline or tab inside page text is kept
as text instead of failing the parse or being deleted.

Environment:
  WIKI_API                 path to the wiki-api wrapper (default: alongside this script)
  WIKI_TREE_SWEEP_BACKOFF  first retry delay in seconds (default 2; tests set 0)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import OrderedDict

EXIT_MATCH, EXIT_NO_MATCH, EXIT_USAGE, EXIT_API, EXIT_PARTIAL, EXIT_TOO_BIG = 0, 1, 2, 3, 4, 5
ATTEMPTS = 4
MAX_BACKOFF = 8.0
CALL_TIMEOUT = 150          # wiki-api caps curl at 120s; this is the backstop
MAX_CONSECUTIVE_FAILURES = 3


class ApiError(Exception):
    pass


def log(msg):
    print(f"[wiki-tree-sweep] {msg}", file=sys.stderr)


def wiki_api_path():
    override = os.environ.get("WIKI_API")
    if override:
        return override
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "wiki-api")


def call(endpoint, body, verbose=False, attempts=ATTEMPTS):
    """POST through wiki-api; retry transport errors and rate limits, then raise."""
    delay = float(os.environ.get("WIKI_TREE_SWEEP_BACKOFF", "2"))
    last = "no attempt made"
    for attempt in range(1, attempts + 1):
        try:
            proc = subprocess.run(
                [wiki_api_path(), endpoint, json.dumps(body)],
                capture_output=True, text=True, timeout=CALL_TIMEOUT,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            last = str(exc)
        else:
            if proc.returncode != 0:
                last = proc.stderr.strip() or f"wiki-api exited {proc.returncode}"
                # wiki-api's own setup checks (missing .env, empty key, endpoint
                # not allowlisted) print "ERROR: ..." and can never succeed on retry.
                if last.startswith("ERROR:"):
                    raise ApiError(f"{endpoint}: {last}")
            else:
                try:
                    # strict=False keeps raw control characters inside strings.
                    resp = json.loads(proc.stdout, strict=False)
                except ValueError as exc:
                    last = f"unparseable response: {exc}"
                else:
                    if isinstance(resp, dict) and resp.get("ok") is True:
                        return resp.get("data")
                    status = resp.get("status") if isinstance(resp, dict) else None
                    err = resp.get("error") if isinstance(resp, dict) else None
                    last = f"{err or 'error'} (status {status})"
                    # Only rate limits and server errors are worth retrying.
                    if status not in (429, 500, 502, 503, 504) and err != "rate_limit_exceeded":
                        raise ApiError(f"{endpoint}: {last}")
        if attempt < attempts:
            if verbose:
                log(f"{endpoint} attempt {attempt}/{attempts} failed ({last}); retrying in {delay:g}s")
            time.sleep(delay)
            delay = min(delay * 2, MAX_BACKOFF)
    raise ApiError(f"{endpoint}: {last} after {attempts} attempt(s)")


def root_ref(raw):
    """Accept an id, a slug, or a page URL; return what documents.info expects."""
    m = re.search(r"/doc/([^/?#]+)", raw)
    return m.group(1) if m else raw.strip()


def find_node(nodes, target):
    stack = list(nodes)
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            raise ApiError("collections.documents returned a malformed tree node")
        if node.get("id") == target:
            return node
        stack.extend(node.get("children") or [])
    return None


def flatten(node, depth=0, parent=None):
    """Pre-order walk; iterative so deep trees cannot hit the recursion limit."""
    out, seen = [], set()
    stack = [(node, depth, parent)]
    while stack:
        cur, d, p = stack.pop()
        if not isinstance(cur, dict) or not cur.get("id"):
            raise ApiError("collections.documents returned a tree node without an id")
        if cur["id"] in seen:
            continue
        seen.add(cur["id"])
        out.append({"id": cur["id"], "title": cur.get("title", ""), "url": cur.get("url", ""),
                    "depth": d, "parentDocumentId": p})
        for child in reversed(cur.get("children") or []):
            stack.append((child, d + 1, cur["id"]))
    return out


def discover(root, verbose):
    info = call("documents.info", {"id": root_ref(root)}, verbose)
    if not isinstance(info, dict) or not info.get("id"):
        raise ApiError("documents.info returned no document for the root")
    if not info.get("collectionId"):
        raise ApiError(f"root '{info.get('title', root)}' has no collection (draft or template?)")
    tree = call("collections.documents", {"id": info["collectionId"]}, verbose)
    if not isinstance(tree, list):
        raise ApiError("collections.documents did not return a list of pages")
    node = find_node(tree, info["id"])
    if node is None:
        raise ApiError(f"root '{info.get('title', root)}' is not in its collection's published "
                       "tree; drafts and unpublished pages cannot be swept")
    return flatten(node), info


def prefetch_text(pages, root_doc, opts):
    """Read child pages in batches of up to 100 per parent.

    Returns {id: document} for every page a batch returned with its text. This
    is only a speed-up: pages missing here are read one by one by the caller,
    so a batch problem never loses a page. The first failed batch call (one
    attempt, no retries) turns batching off for the rest of the run.
    """
    docs = {root_doc["id"]: root_doc} if "text" in root_doc else {}
    expected = OrderedDict()
    for pg in pages:
        if pg["parentDocumentId"]:
            expected.setdefault(pg["parentDocumentId"], set()).add(pg["id"])
    for parent, kids in expected.items():
        offset, previous_ids = 0, None
        while True:
            if opts.delay:
                time.sleep(opts.delay)
            try:
                batch = call("documents.list",
                             {"parentDocumentId": parent, "limit": 100, "offset": offset},
                             opts.verbose, attempts=1)
            except ApiError as exc:
                if opts.verbose:
                    log(f"batch read failed ({exc}); reading remaining pages one by one")
                return docs
            if not isinstance(batch, list):
                return docs
            ids = [d.get("id") for d in batch if isinstance(d, dict)]
            if ids == previous_ids:
                break       # server ignored offset; stop paging this parent
            previous_ids = ids
            for d in batch:
                if isinstance(d, dict) and d.get("id") in kids and isinstance(d.get("text"), str):
                    docs[d["id"]] = d
            if len(batch) < 100 or kids.issubset(docs):
                break
            offset += 100
    return docs


def read_page(pg, opts):
    if opts.delay:
        time.sleep(opts.delay)
    doc = call("documents.info", {"id": pg["id"]}, opts.verbose)
    if not isinstance(doc, dict) or not isinstance(doc.get("text"), str):
        raise ApiError("documents.info returned no page text")
    return doc


def sweep(opts, pattern):
    """Run the sweep; returns (exit_code, output_lines)."""
    pages, root_doc = discover(opts.args[0], opts.verbose)
    if len(pages) > opts.max_pages:
        log(f"ERROR: tree has {len(pages)} pages, over --max-pages {opts.max_pages}; "
            "re-run with a higher --max-pages")
        return EXIT_TOO_BIG, []
    if opts.verbose:
        log(f"{len(pages)} page(s) under '{pages[0]['title']}'")

    if opts.list:
        return 0, [f"{'  ' * pg['depth']}{pg['title']}\t{pg['url']}" for pg in pages]

    docs = prefetch_text(pages, root_doc, opts)
    if opts.verbose:
        log(f"{len(docs)} of {len(pages)} page(s) read in batches")
    out, failed, streak, matches, matched_pages = [], [], 0, 0, 0
    for pg in pages:
        doc = docs.get(pg["id"])
        if doc is None:
            try:
                doc = read_page(pg, opts)
                streak = 0
            except ApiError as exc:
                if not opts.keep_going:
                    log(f"ERROR: reading '{pg['title']}' ({pg['id']}): {exc}")
                    return EXIT_API, []
                failed.append(pg)
                streak += 1
                log(f"WARN: skipped '{pg['title']}' ({pg['id']}): {exc}")
                if streak >= MAX_CONSECUTIVE_FAILURES:
                    log(f"ERROR: {streak} pages in a row failed; the wiki looks unavailable")
                    return EXIT_API, []
                continue
        text = doc["text"]
        if opts.jsonl:
            rec = dict(pg, updatedAt=doc.get("updatedAt"), textLen=len(text), text=text)
            out.append(json.dumps(rec, ensure_ascii=False))
            continue
        hit = False
        for lineno, line in enumerate(text.splitlines(), 1):
            if pattern.search(line):
                hit = True
                matches += 1
                out.append(f"{pg['depth']}\t{pg['title']}\t{pg['url']}\t{lineno}\t{line}")
        matched_pages += hit

    if not opts.jsonl:
        log(f"{len(pages) - len(failed)} of {len(pages)} page(s) searched; "
            f"{matches} match(es) on {matched_pages} page(s)")
    if failed:
        log(f"INCOMPLETE: {len(failed)} page(s) not fetched: "
            + ", ".join(f"{f['title']} ({f['id']})" for f in failed))
        return EXIT_PARTIAL, out
    if opts.jsonl:
        return 0, out
    return (EXIT_MATCH if matches else EXIT_NO_MATCH), out


def main(argv):
    p = argparse.ArgumentParser(add_help=False, usage=argparse.SUPPRESS)
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("--list", action="store_true")
    p.add_argument("--jsonl", action="store_true")
    p.add_argument("-i", "--ignore-case", action="store_true")
    p.add_argument("--keep-going", action="store_true")
    p.add_argument("--max-pages", type=int, default=2000)
    p.add_argument("--delay", type=float, default=0.1)
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("args", nargs="*")
    try:
        opts = p.parse_args(argv)
    except SystemExit:
        return EXIT_USAGE

    if opts.help:
        print(__doc__.strip())
        return 0

    listing = opts.list or opts.jsonl
    if opts.list and opts.jsonl:
        log("--list and --jsonl are mutually exclusive")
        return EXIT_USAGE
    if len(opts.args) != (1 if listing else 2):
        log(f"expected {'<root>' if listing else '<root> <pattern>'}; run with --help")
        return EXIT_USAGE
    if not opts.args[0].strip():
        log("<root> must not be empty")
        return EXIT_USAGE
    if opts.max_pages < 1 or opts.delay < 0:
        log("--max-pages must be >= 1 and --delay must be >= 0")
        return EXIT_USAGE

    pattern = None
    if not listing:
        try:
            pattern = re.compile(opts.args[1], re.IGNORECASE if opts.ignore_case else 0)
        except re.error as exc:
            log(f"invalid pattern: {exc}")
            return EXIT_USAGE

    try:
        code, out = sweep(opts, pattern)
    except ApiError as exc:
        log(f"ERROR: {exc}")
        return EXIT_API
    except Exception as exc:  # an unexpected response shape must never read as "no matches"
        log(f"ERROR: unexpected {exc!r}")
        return EXIT_API
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
