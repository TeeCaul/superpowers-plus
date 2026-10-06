#!/usr/bin/env python3
"""commit-msg-jargon.py -- warn when a commit message names the review tooling.

Usage:
  commit-msg-jargon.py <commit-message-file>
  commit-msg-jargon.py --help

Commit messages should say what changed and why. Naming the process that
reviewed the change ("battery passed", "PHR round 2", "sentinel written")
tells a later reader nothing about the code, so this prints a warning for
each line of the subject or body that does. It never blocks: exit is always
0 unless the arguments are wrong.

Terms are matched as whole words, case-insensitively, so an ordinary use of
"battery" or "sentinel" also warns; that is the cost of a check that never
blocks.

Not scanned:
  - lines inside ``` or ~~~ code fences
  - git comment lines (starting with #)
  - trailer lines in the final paragraph (Co-Authored-By:, Signed-off-by:, ...)

Skipped entirely when the staged change touches the review tooling itself,
because then the message has to name it:
  skills/engineering/*review*   tools/run-*.sh   tools/pre-push*

Exit codes:
  0  checked (warnings, if any, are on stderr)
  2  usage error
"""

import fnmatch
import re
import subprocess
import sys

TERMS = [
    "code-review-battery", "cr-battery", "llm-skill-review", "skill-router",
    "superpowers", "harsh review", "harsh-review", "battery", "sentinel", "PHR",
]
TERM_RE = re.compile(
    r"(?<![\w-])(" + "|".join(re.escape(t).replace(r"\ ", r"[\s-]") for t in TERMS) + r")(?![\w-])",
    re.IGNORECASE,
)
EXEMPT_PATHS = ("skills/engineering/*review*", "tools/run-*.sh", "tools/pre-push*")
TRAILER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*:\s")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def staged_paths():
    r = subprocess.run(["git", "diff", "--cached", "--name-only", "-z"],
                       capture_output=True)
    if r.returncode != 0:
        return []
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def touches_review_tooling(paths):
    return any(fnmatch.fnmatch(p, pat) for p in paths for pat in EXEMPT_PATHS)


def scanned_lines(text):
    """Yield (line_number, line) for lines that should be checked."""
    lines = text.split("\n")
    # Trailers: the last non-blank paragraph, when every line in it is Key: value.
    end = len(lines)
    while end > 0 and not lines[end - 1].strip():
        end -= 1
    start = end
    while start > 0 and lines[start - 1].strip():
        start -= 1
    trailer_block = set()
    block = [l for l in lines[start:end] if not l.startswith("#")]
    if start > 0 and block and all(TRAILER_RE.match(l) for l in block):
        trailer_block = set(range(start, end))
    in_fence = False
    for i, line in enumerate(lines):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence or line.startswith("#") or i in trailer_block:
            continue
        yield i + 1, line


def find_jargon(text):
    hits = []
    for n, line in scanned_lines(text):
        terms = sorted({m.group(1) for m in TERM_RE.finditer(line)}, key=str.lower)
        if terms:
            hits.append((n, terms, line.strip()))
    return hits


def main(argv):
    if len(argv) != 1 or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    try:
        with open(argv[0], encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        print("commit-msg-jargon: cannot read %s: %s" % (argv[0], e), file=sys.stderr)
        return 2
    if touches_review_tooling(staged_paths()):
        return 0
    hits = find_jargon(text)
    if hits:
        print("", file=sys.stderr)
        print("  WARNING: the commit message names review tooling. Say what changed and why;", file=sys.stderr)
        print("  how it was reviewed does not belong in history. (Not blocking.)", file=sys.stderr)
        for n, terms, line in hits:
            print("    line %d [%s]: %s" % (n, ", ".join(terms), line[:100]), file=sys.stderr)
        print("", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
