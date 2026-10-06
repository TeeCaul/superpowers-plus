#!/usr/bin/env python3
"""review-preflight.py -- the mechanical half of code-review-battery triage, as one JSON object.

Usage:
  review-preflight.py [--base REF | --staged]
  review-preflight.py --list-signals
  review-preflight.py --help

  --base REF       review the branch: diff from merge-base(REF, HEAD) to HEAD
                   (default origin/dev)
  --staged         review the index: diff from HEAD to the staged tree
  --list-signals   print the encoded signal table as JSON and exit

Run it before code-review-battery Phases 0, 0.5 and 1 and read its JSON instead
of applying those tables by hand. The skill's tables stay the spec; this script
is checked against them by tests/tools/review-preflight.bats.

Output keys:
  head, branch, base, mode     what was compared
  worktree_clean               false if tracked files have uncommitted changes
  sentinels                    per sentinel file: state valid|stale|missing|malformed,
                               the recorded sha, and "carried": true when the
                               sentinel names another commit but no file in its
                               scope changed (tools/lib/sentinel-scope.sh, the
                               same rule the pre-push gates apply)
  bugfix_mode                  branch matches ^(hotfix/|fix/[A-Z]+-[0-9]+)
  diff                         files with status and line counts, totals,
                               change_class, size_class
  routes                       tools/review.sh route, parsed per review class
  reviewers                    base reviewers for the change class, then each
                               signal row and mandatory rule that fired, with
                               file:line hits; "heuristic": true means a regex
                               can only suggest the row, so confirm it
  dispatch                     whether the combined reviewer runs, and which
                               extra agents the fired rows add
  judgment_required            signal rows no regex can decide; read those
                               rows in the skill
  inline_exemption_eligible    the small-diff inline review exemption, with
                               the reasons for the answer

Exit codes:
  0  JSON printed
  2  usage error, or git could not answer (base ref missing, not a repo)
"""

import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLS_ROOT = os.path.dirname(SCRIPT_DIR)
REVIEW_SH = os.path.join(SCRIPT_DIR, "review.sh")
SCOPE_LIB = os.path.join(SCRIPT_DIR, "lib", "sentinel-scope.sh")

SENTINELS = (".code-review-cleared", ".phr-cleared", ".llm-skill-review-cleared")
SENTINEL_VERSION = {".code-review-cleared": "v1", ".phr-cleared": "v1",
                    ".llm-skill-review-cleared": "v2"}
SENTINEL_FIELDS = {".code-review-cleared": (4, 5), ".phr-cleared": (5, 5),
                   ".llm-skill-review-cleared": (7, 7)}

BUGFIX_BRANCH = re.compile(r"^(hotfix/|fix/[A-Z]+-[0-9]+)")
DOC_FILE = re.compile(r"\.(md|txt|rst)$")
TEST_FILE = re.compile(r"(^|/)(tests?|__tests__)/|\.bats$|\.test\.[jt]sx?$|(^|/)test_[^/]+\.py$")
CONFIG_FILE = re.compile(r"\.(json|ya?ml|toml|ini|cfg|conf)$|(^|/)\.[^/]+$")
SHELL_SHEBANG = re.compile(r"^#!.*\b(ba|z|k|da)?sh\b")

COMBINED_LENSES = ("Defect Finder", "Guardian", "Standards Enforcer")
INLINE_MAX_LINES = 150
INLINE_MAX_FILES = 3
LARGE_LINES = 500
CHUNK_LINES = 3000

# One entry per row of the "Signal-driven dispatch" table in
# skills/engineering/code-review-battery/skill.md. "row" is a substring of that
# row's first cell; the bats suite fails if a table row matches no entry, so a
# new row in the skill cannot be silently missed here.
#   match: "added"  -> regex over added lines of non-doc files
#          "status" -> rename/delete in the file list
#          "class"  -> the diff's change class
#          "judgment" -> no regex can decide it; reported, never fired
SIGNALS = [
    {"id": "metric-emit", "row": "Metric/counter/event definition",
     "reviewers": ["Defect Finder", "Standards Enforcer"], "match": "added", "heuristic": False,
     "regex": r"\.(emit|inc)\(|\bpublish\(|\bdefineMetric\b|\b(Counter|Gauge|Histogram)\("},
    {"id": "alarm", "row": "Alarm/threshold definition",
     "reviewers": ["Guardian", "Standards Enforcer"], "match": "added", "heuristic": True,
     "regex": r"\b[Aa]larms?\b|\bAlarm\w*\(|\bthreshold\b"},
    {"id": "external-error", "row": "External-dependency call",
     "reviewers": ["Guardian"], "match": "added", "heuristic": True,
     "regex": r"\b429\b|\b50[0-4]\b|\bstatus(Code|_code)?\s*[=!<>]=?\s*\d{3}|rate.?limit"
              r"|\bECONNRESET\b|\bETIMEDOUT\b|Throttl"},
    {"id": "field-reset", "row": "Field set to `null`",
     "reviewers": ["Defect Finder", "Guardian"], "match": "added", "heuristic": False,
     "regex": r"^\s*[\w$]+(\.[\w$]+|\[[^\]]+\])+\s*=\s*(null|None|0|false|False|undefined|nil)\s*;?\s*$"},
    {"id": "public-api", "row": "Public signature / interface",
     "reviewers": ["Design Critic", "Guardian"], "match": "added", "heuristic": False,
     "regex": r"^\s*export\s+(default\s+)?(async\s+)?(class|interface|type|function|const|enum)\b"
              r"|^\s*public\s+[\w<>\[\], ]+\s+\w+\s*\(|\bmodule\.exports\b"},
    {"id": "io-loop", "row": "Loop over I/O",
     "reviewers": ["Performance Analyst"], "match": "added", "heuristic": True,
     "regex": r"\b(SELECT|INSERT|UPDATE|DELETE)\s+\S|\.(query|execute)\(|\bfetch\(|\brequests\.(get|post|put)\("
              r"|\bcurl\s|\bfor\b.*\bawait\b|\bawait\b.*\bfor\b|\bcache\b"},
    {"id": "rename-delete", "row": "File rename/move/delete",
     "reviewers": ["Guardian"], "match": "status", "heuristic": False},
    {"id": "test-only", "row": "Test-only change",
     "reviewers": ["Standards Enforcer", "Defect Finder"], "match": "class", "heuristic": False},
    {"id": "ticket-in-comment", "row": "ticket-tracker reference",
     "reviewers": ["Standards Enforcer"], "match": "added", "heuristic": False,
     "regex": r"^\s*(//|/\*|\*\s).*\b[A-Z][A-Z0-9]+-[0-9]+\b"},
    {"id": "security", "row": "Security-class signal",
     "reviewers": ["AttackerPersona"], "match": "added", "heuristic": True,
     "regex": r"\b(secret|password|passwd|api[_-]?key|cookie|session|credential)s?\b"
              r"|\btoken\b|_disabled/|\bmcp\b|\bx-api-key\b"
              r"|[\"'`].*\b(SELECT|FROM|WHERE)\b.*(\$\{|%s|\{\w*\}|\+\s*\w)"},
    {"id": "shell", "row": "Shell-content signal",
     "reviewers": ["ShellRuntimeAuditor"], "match": "added", "heuristic": False,
     "regex": r"^#!|\b(execSync|spawnSync|execFileSync|child_process)\b|\bsubprocess\.(run|call|check_call|check_output|Popen)\b"},
    {"id": "untelemetered-feature", "row": "New user-visible feature",
     "reviewers": ["Standards Enforcer"], "match": "judgment"},
    {"id": "try-catch", "row": "block in the diff",
     "reviewers": ["Defect Finder"], "match": "added", "heuristic": False,
     "regex": r"\btry\s*\{|\}\s*catch\b|^\s*try:\s*$|^\s*except\b"},
    {"id": "caller-removal", "row": "only call site",
     "reviewers": ["Defect Finder"], "match": "judgment"},
    {"id": "sibling-path", "row": "New property added",
     "reviewers": ["Defect Finder", "Guardian"], "match": "judgment"},
]

# "Mandatory activation" bullets under the signal table.
MANDATORY = [
    {"id": "guardian-mandatory", "reviewer": "Guardian",
     "rule": "retry, circuit breaker, rollback, deployment config, feature flag, auth, state machine",
     "regex": r"\bretr(y|ies|ied)\b|\bbackoff\b|circuit.?breaker|\brollback\b|\broll back\b"
              r"|feature.?flag|\bauth[nz]?\b|authenticat|authoriz|state.?machine",
     "path": r"(^|/)\.github/workflows/|(^|/)deploy|Dockerfile$|(^|/)\.env"},
    {"id": "design-critic-mandatory", "reviewer": "Design Critic",
     "rule": "interfaces, public APIs, contracts, message schemas, shared state types",
     "regex": r"^\s*(export\s+)?interface\s+\w|\bschema\b|\bcontract\b",
     "path": None},
]

MAX_HITS = 10


class UsageError(Exception):
    pass


def run(cmd, check=True, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if check and r.returncode != 0:
        raise UsageError("%s failed: %s" % (" ".join(cmd[:3]), r.stderr.strip() or r.stdout.strip()))
    return r


def git(*args, check=True):
    return run(["git", *args], check=check).stdout


# --- diff --------------------------------------------------------------------

def diff_range(base, staged):
    if staged:
        return ["--cached", "HEAD"], "HEAD", "index"
    if run(["git", "rev-parse", "--verify", "--quiet", base + "^{commit}"], check=False).returncode:
        raise UsageError("base ref %r not found; fetch it or pass --base" % base)
    mb = git("merge-base", base, "HEAD").strip()
    return [mb, "HEAD"], mb, "HEAD"


def collect_diff(rng):
    files = {}
    for line in git("diff", "--no-color", "--name-status", "-M", *rng).splitlines():
        parts = line.split("\t")
        status = parts[0][:1]
        path = parts[-1]
        files[path] = {"path": path, "status": status, "added": 0, "removed": 0}
        if status == "R":
            files[path]["renamed_from"] = parts[1]
    for line in git("diff", "--no-color", "--numstat", "-M", *rng).splitlines():
        a, r, path = line.split("\t", 2)
        if " => " in path:  # rename shown as a/{x => y}/b or x => y
            path = re.sub(r"\{[^{}]* => ([^{}]*)\}", r"\1", path)
            path = path.split(" => ")[-1]
            path = path.replace("//", "/")
        if path in files:
            files[path]["added"] = int(a) if a != "-" else 0
            files[path]["removed"] = int(r) if r != "-" else 0
            files[path]["binary"] = a == "-"
    added_lines = []  # (path, line_no, text)
    removed_count_code = 0
    cur, new_no = None, 0
    for line in git("diff", "--no-color", "--unified=0", "-M", *rng).splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            new_no = int(m.group(1)) if m else 0
        elif line.startswith("+") and cur is not None:
            added_lines.append((cur, new_no, line[1:]))
            new_no += 1
        elif line.startswith("-") and not line.startswith("--- ") and cur and not DOC_FILE.search(cur):
            removed_count_code += 1
    return list(files.values()), added_lines, removed_count_code


def change_class(paths):
    if not paths:
        return "empty"
    if all(DOC_FILE.search(p) for p in paths):
        return "docs-only"
    if all(TEST_FILE.search(p) for p in paths):
        return "test-only"
    if all(CONFIG_FILE.search(p) for p in paths):
        return "config-only"
    return "code"


def size_class(changed, nfiles):
    if changed == 0 and nfiles == 0:
        return "empty"
    if changed <= INLINE_MAX_LINES and nfiles <= INLINE_MAX_FILES:
        return "small"
    if changed > CHUNK_LINES:
        return "chunk"
    if changed > LARGE_LINES:
        return "large"
    return "medium"


def is_shell_file(path):
    if re.search(r"\.(sh|bash|bats|zsh)$", path):
        return True
    if "." in os.path.basename(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return bool(SHELL_SHEBANG.match(fh.readline()))
    except OSError:
        return False


# --- sentinels ---------------------------------------------------------------

def scope_unchanged(sentinel, reviewed, head):
    """Ask tools/lib/sentinel-scope.sh, exactly as the pre-push gates do."""
    script = ('source "$1"; c="$(sentinel_scope_classifier_for "$2")" || exit 3; '
              'if sentinel_scope_unchanged "$3" "$4" "$c"; then exit 0; fi; '
              'printf "%s" "$SENTINEL_SCOPE_CHANGED"; exit 1')
    env = dict(os.environ, REPO_ROOT=TOOLS_ROOT)
    for v in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX"):
        env.pop(v, None)
    r = subprocess.run(["bash", "-c", script, "scope", SCOPE_LIB, sentinel, reviewed, head],
                       capture_output=True, text=True, env=env)
    return r.returncode == 0, r.stdout.strip()


def sentinel_state(root, name, head, staged):
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        return {"state": "missing"}
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [x for x in fh.read().splitlines() if x.strip()]
    if len(lines) != 1:
        return {"state": "malformed", "detail": "%d non-blank lines; must be exactly 1" % len(lines)}
    fields = lines[0].split("|")
    lo, hi = SENTINEL_FIELDS[name]
    if fields[0] != SENTINEL_VERSION[name] or not lo <= len(fields) <= hi or not fields[1]:
        return {"state": "malformed", "detail": "unrecognized format: %s" % lines[0][:80]}
    sha, verdict = fields[1], fields[2]
    out = {"sha": sha, "verdict": verdict}
    if sha.startswith("tree:"):
        tree = sha[5:]
        trees = {git("rev-parse", "HEAD^{tree}").strip()}
        if staged:
            trees.add(git("write-tree").strip())
        out["state"] = "valid" if tree in trees else "stale"
        return out
    if sha == head:
        out["state"] = "valid"
        return out
    same, changed = scope_unchanged(name, sha, head)
    if same:
        out.update(state="valid", carried=True)
    else:
        out.update(state="stale", detail=changed or "scope check failed")
    return out


# --- routes ------------------------------------------------------------------

def routes_for(paths):
    if not paths:
        return {"blocks": [], "exit": 0}
    r = run([REVIEW_SH, "route", *paths], check=False)
    blocks, cur = [], None
    for line in r.stdout.splitlines():
        if not line.strip():
            cur = None
            continue
        if line.startswith(("SKILL: ", "EXEMPT: ")) or cur is None:
            cur = {"files": []}
            blocks.append(cur)
        if line.startswith("SKILL: "):
            cur["skill"] = line[7:]
        elif line.startswith("EXEMPT: "):
            cur["exempt"] = line[8:]
        elif line.startswith("RUNNER: "):
            cur["runner"] = line[8:]
        elif line.startswith("SENTINEL: "):
            cur["sentinel"] = line[10:]
        elif line.startswith("  "):
            cur["files"].append(line.strip())
    out = {"blocks": blocks, "exit": r.returncode}
    if r.returncode != 0:
        out["error"] = r.stderr.strip()
    return out


# --- signals -----------------------------------------------------------------

def scan_signals(files, added, cls, changed_lines):
    code_lines = [(p, n, t) for (p, n, t) in added if not DOC_FILE.search(p)]
    fired, judgment = [], []
    for sig in SIGNALS:
        hits = []
        if sig["match"] == "judgment":
            if cls not in ("empty", "docs-only"):
                judgment.append({"id": sig["id"], "row": sig["row"], "reviewers": sig["reviewers"]})
            continue
        if sig["match"] == "added":
            rx = re.compile(sig["regex"])
            hits = ["%s:%d" % (p, n) for (p, n, t) in code_lines if rx.search(t)]
        elif sig["match"] == "status":
            hits = ["%s (%s)" % (f.get("renamed_from", f["path"]), {"R": "renamed", "D": "deleted"}[f["status"]])
                    for f in files if f["status"] in ("R", "D")]
        elif sig["match"] == "class":
            hits = ["all %d changed files are tests" % len(files)] if cls == "test-only" else []
        if sig["id"] == "shell":
            hits = ["%s (shell file)" % f["path"] for f in files
                    if f["status"] != "D" and is_shell_file(f["path"])] + hits
        if sig["id"] == "security":
            hits = ["%s (path)" % f["path"] for f in files if "_disabled/" in f["path"]] + hits
        if sig["id"] == "io-loop" and changed_lines > LARGE_LINES:
            hits = ["%d changed lines (> %d)" % (changed_lines, LARGE_LINES)] + hits
        if hits:
            fired.append({"kind": "signal", "id": sig["id"], "row": sig["row"],
                          "reviewers": sig["reviewers"], "heuristic": sig.get("heuristic", False),
                          "hits": hits[:MAX_HITS], "hit_count": len(hits)})
    mandatory = []
    for rule in MANDATORY:
        rx = re.compile(rule["regex"])
        hits = ["%s:%d" % (p, n) for (p, n, t) in code_lines if rx.search(t)]
        if rule["path"]:
            prx = re.compile(rule["path"])
            hits = ["%s (path)" % f["path"] for f in files if prx.search(f["path"])] + hits
        if hits:
            mandatory.append({"kind": "mandatory", "id": rule["id"], "rule": rule["rule"],
                              "reviewers": [rule["reviewer"]], "heuristic": True,
                              "hits": hits[:MAX_HITS], "hit_count": len(hits)})
    return fired, mandatory, judgment


def base_reviewers(cls):
    if cls == "empty":
        return []
    if cls == "docs-only":
        return [{"kind": "base", "id": "docs-only", "reviewers": ["Standards Enforcer"]}]
    if cls == "config-only":
        return [{"kind": "base", "id": "config-only", "reviewers": ["Guardian"]}]
    return [{"kind": "base", "id": "combined", "reviewers": list(COMBINED_LENSES),
             "note": "one combined reviewer; it must answer the placement question"}]


def dispatch_plan(cls, rows, bugfix):
    combined = cls in ("code", "test-only")
    named = []
    for row in rows:
        for r in row["reviewers"]:
            if r not in named:
                named.append(r)
    extra = [r for r in named if r not in COMBINED_LENSES]
    if bugfix and "BugPath Verifier" not in extra:
        extra.append("BugPath Verifier")
    lenses = [r for r in named if r in COMBINED_LENSES]
    return {"combined_reviewer": combined, "lenses": lenses, "extra_agents": extra}


def inline_exemption(changed, nfiles, bugfix, fired, mandatory, judgment):
    reasons = []
    if changed > INLINE_MAX_LINES:
        reasons.append("%d changed lines > %d" % (changed, INLINE_MAX_LINES))
    if nfiles > INLINE_MAX_FILES:
        reasons.append("%d files > %d" % (nfiles, INLINE_MAX_FILES))
    if bugfix:
        reasons.append("bug-fix branch: BugPath Verifier needs full dispatch")
    for row in fired:
        reasons.append("signal row fired: %s" % row["id"])
    for row in mandatory:
        reasons.append("mandatory activation fired: %s" % row["id"])
    eligible = not reasons
    if eligible:
        reasons.append("<= %d lines, <= %d files, no bug-fix mode, no signal or mandatory row fired"
                       % (INLINE_MAX_LINES, INLINE_MAX_FILES))
        reasons.append("still requires: the reviewing agent wrote or fully re-read this code in this session")
        if judgment:
            reasons.append("still requires: rule out the judgment rows (%s)"
                           % ", ".join(j["id"] for j in judgment))
    return eligible, reasons


# --- main --------------------------------------------------------------------

def preflight(base, staged):
    if run(["git", "rev-parse", "--git-dir"], check=False).returncode:
        raise UsageError("not a git repository")
    root = git("rev-parse", "--show-toplevel").strip()
    os.chdir(root)
    head = git("rev-parse", "HEAD").strip()
    branch = git("branch", "--show-current").strip()
    rng, base_sha, _ = diff_range(base, staged)
    files, added, removed_code = collect_diff(rng)
    paths = [f["path"] for f in files]
    total_added = sum(f["added"] for f in files)
    total_removed = sum(f["removed"] for f in files)
    changed = total_added + total_removed
    cls = change_class(paths)
    bugfix = bool(BUGFIX_BRANCH.match(branch))
    fired, mandatory, judgment = scan_signals(files, added, cls, changed)
    if not removed_code:
        judgment = [j for j in judgment if j["id"] != "caller-removal"]
    rows = base_reviewers(cls) + fired + mandatory
    eligible, reasons = inline_exemption(changed, len(files), bugfix, fired, mandatory, judgment)
    dirty = run(["git", "diff", "--quiet"], check=False).returncode or \
        run(["git", "diff", "--cached", "--quiet"], check=False).returncode
    route_paths = paths + [f["renamed_from"] for f in files if f.get("renamed_from")]
    return {
        "head": head,
        "branch": branch,
        "mode": "staged" if staged else "branch",
        "base": "HEAD" if staged else base,
        "base_sha": base_sha,
        "worktree_clean": not dirty,
        "sentinels": {name: sentinel_state(root, name, head, staged) for name in SENTINELS},
        "bugfix_mode": bugfix,
        "diff": {"files": files, "file_count": len(files), "added": total_added,
                 "removed": total_removed, "changed_lines": changed,
                 "change_class": cls, "size_class": size_class(changed, len(files))},
        "routes": routes_for(route_paths),
        "reviewers": rows,
        "dispatch": dispatch_plan(cls, rows, bugfix),
        "judgment_required": judgment,
        "inline_exemption_eligible": eligible,
        "inline_exemption_reasons": reasons,
    }


def main(argv):
    base, staged = "origin/dev", False
    it = iter(argv)
    try:
        for a in it:
            if a in ("-h", "--help"):
                sys.stdout.write(__doc__)
                return 0
            if a == "--list-signals":
                print(json.dumps({"signals": SIGNALS, "mandatory": MANDATORY}, indent=2))
                return 0
            if a == "--staged":
                staged = True
            elif a == "--base":
                base = next(it, None)
                if not base:
                    raise UsageError("--base needs a ref")
            elif a.startswith("--base="):
                base = a.split("=", 1)[1]
            else:
                raise UsageError("unknown argument %r" % a)
        print(json.dumps(preflight(base, staged), indent=2))
        return 0
    except UsageError as e:
        print("usage error: %s (see --help)" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
