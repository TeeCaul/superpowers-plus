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

A line warns only when a tool name (whole word, any case) appears together
with a process word such as passed, round, findings, score, verdict,
reviewed or re-stamped. A tool named as the subject of a change ("fix the
sentinel parser") does not warn; "battery passed" does.

Not scanned:
  - lines inside ``` or ~~~ code fences
  - git comment lines (starting with #)
  - trailer lines in the final paragraph (Co-Authored-By:, Signed-off-by: and
    other standard keys)
  - everything below the "# ---- >8 ----" scissors line of git commit -v

Skipped entirely when the change touches the review tooling, its gates,
hooks or tests (see EXEMPT_PATHS), because then the message has to name it.
For a message-only amend the files of the commit being amended are used.

Exit codes:
  0  checked (warnings, if any, are on stderr)
  2  usage error
"""

import fnmatch
import re
import subprocess
import sys

# "superpowers" is left out: it is this product's name, not a process step.
TERMS = [
    "code-review-battery", "cr-battery", "llm-skill-review", "skill-router",
    "harsh review", "harsh-review", "battery", "sentinel", "PHR",
]
TERM_RE = re.compile(
    r"(?<![\w-])(" + "|".join(re.escape(t).replace(r"\ ", r"[\s-]") for t in TERMS) + r")(?![\w-])",
    re.IGNORECASE,
)
# A change to the review tooling, its gates, hooks or tests has to name it.
# A tool name alone is often the topic of a change here (many skills are named
# after these tools). It is process narration when it sits next to one of
# these words on the same line: "battery passed", "PHR round 2", "sentinel
# re-stamped", "reviewed via code-review-battery".
PROCESS_RE = re.compile(
    r"\b(pass(ed|es)?|clear(ed|s)?|green|rounds?|r[0-9]|findings?|scor(e|ed|es)|verdict|"
    r"re-?ran|re-?run|reviewed|stamp(ed)?|re-stamp(ed)?|written|dispatch(ed)?|"
    r"reviewers?|signed off)\b", re.IGNORECASE)
EXEMPT_PATHS = (
    "skills/engineering/*review*", "skills/engineering/*battery*",
    "tools/run-*.sh", "tools/pre-push*", "tools/*review*", "tools/*battery*",
    "tools/*phr*", "tools/*sentinel*", "tools/commit-msg*", "tools/claude-hooks/*",
    "tools/lib/*", "test/*review*", "test/*battery*", "test/*phr*", "test/*sentinel*",
    "test/pre-push*", "tests/tools/commit-msg*", ".agent-gates", "AGENTS.md",
)
# Only known trailer keys, so a last body paragraph like "Note: ..." is still read.
TRAILER_RE = re.compile(
    r"^(Co-Authored-By|Signed-off-by|Reviewed-by|Acked-by|Tested-by|Reported-by|"
    r"Suggested-by|Helped-by|Cc|Fixes|Refs|See-also|Change-Id):\s", re.IGNORECASE)
SCISSORS_RE = re.compile(r"^. -+ >8 -+$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def _paths(cmd):
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        return []
    return [p for p in r.stdout.decode("utf-8", "replace").split("\0") if p]


def staged_paths():
    paths = _paths(["git", "diff", "--cached", "--name-only", "-z"])
    if not paths:
        # A message-only amend stages nothing; the commit being amended is
        # what the message describes.
        paths = _paths(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD"])
    return paths


def touches_review_tooling(paths):
    return any(fnmatch.fnmatch(p, pat) for p in paths for pat in EXEMPT_PATHS)


def scanned_lines(text):
    """Yield (line_number, line) for lines that should be checked."""
    lines = text.split("\n")
    # git commit -v appends the diff below a scissors line; it is not message.
    for i, line in enumerate(lines):
        if SCISSORS_RE.match(line):
            lines = lines[:i]
            break
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
        if terms and PROCESS_RE.search(line):
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
