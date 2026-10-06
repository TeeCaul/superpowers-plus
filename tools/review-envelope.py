#!/usr/bin/env python3
"""review-envelope.py -- build a review evidence envelope one checked claim at a time.

Usage:
  review-envelope.py init --kind battery|skill-review [--sha REF] [--force]
  review-envelope.py add-clean --reviewer R --dimension D --claim TEXT
                               (--cmd CMD --expect TYPE[=VALUE] | --unverifiable WHY)
  review-envelope.py add-finding --severity S --file PATH --line N --reviewer R
                               --dimension D --claim TEXT
                               (--cmd CMD --expect TYPE[=VALUE] | --unverifiable WHY)
  review-envelope.py resolve ID --cmd CMD --expect TYPE[=VALUE] [--claim TEXT]
  review-envelope.py set --verdict V (--score N | --mean N)
  review-envelope.py check
  review-envelope.py path

Every subcommand after init also takes [--kind K] [--sha REF]. The kind can be
left out when exactly one envelope exists for the commit.

The envelope lives at .cr-battery-runs/<sha>.json (kind battery, read by
tools/run-battery.sh) or .cr-battery-runs/<sha>-llm-skill-review.json (kind
skill-review, read by tools/run-llm-skill-review.sh). <sha> is the full commit
id of --sha, default HEAD.

What each subcommand guarantees:
  add-clean, add-finding, resolve
      run CMD now, through the same replay code the sentinel runners use
      (tools/verify-cr-battery-evidence.js), and refuse to write the claim
      unless the expectation holds. The observed output is printed either way,
      so a wrong count is fixed when it is written, not at sentinel time.
  add-finding
      records an OPEN finding with an id (F1, F2, ...). Severity scale follows
      the kind: critical|important|minor|possible for battery, S0-S3 for
      skill-review. The other scale is rejected.
  resolve ID
      removes finding ID from findings[] and records the fix as a clean
      dimension "ID (<severity>, fixed): <claim>". findings[] must only hold
      open findings: the skill-review gate counts every S0/S1 entry in it as
      unresolved.
  check
      replays the envelope on a temporary copy (the verifier writes results
      into the file it reads, so the real envelope is never touched), and for
      skill-review also runs tools/lib/llm-skill-review-envelope-gate.js.

Expectation types (semantics are the verifier's, see its header):
  count>0 count==2 count=3     number of non-blank stdout lines
  exit_code=0                  exit status
  match=REGEX                  JS regex against stdout
  absent                       stdout has no non-blank lines
  exact=TEXT                   trimmed stdout equals TEXT

Writes are atomic (temp file in the same directory, then rename).

Exit codes:
  0  success; for check, the envelope would pass the sentinel runner
  1  refused: expectation failed, envelope invalid, or check failed
  2  usage error
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.path.join(SCRIPT_DIR, "verify-cr-battery-evidence.js")
SKILL_GATE = os.path.join(SCRIPT_DIR, "lib", "llm-skill-review-envelope-gate.js")

KINDS = ("battery", "skill-review")
SEVERITIES = {
    "battery": ("critical", "important", "minor", "possible"),
    "skill-review": ("S0", "S1", "S2", "S3"),
}
VERDICTS = {
    "battery": ("PASS", "PASS_WITH_NITS", "PASS_WITH_FIXES", "REJECT"),
    "skill-review": ("PASS", "PASS_WITH_RISKS", "MAJOR_REVISIONS_REQUIRED", "REJECT"),
}
EXPECT_TYPES = ("count", "exit_code", "match", "absent", "exact")

# Replays one claim with the verifier's own replay(), so "accepted here" and
# "verified at sentinel time" cannot disagree.
NODE_REPLAY = (
    "const v=require(process.argv[1]);"
    "const r=v.replay(JSON.parse(process.argv[2]),process.argv[3]);"
    "process.stdout.write(JSON.stringify(r));"
)


class Refused(Exception):
    """The request was understood but must not be applied (exit 1)."""


class UsageError(Exception):
    """Bad arguments (exit 2)."""


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise UsageError("git %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout.strip()


def repo_root():
    return git("rev-parse", "--show-toplevel")


def resolve_sha(ref):
    return git("rev-parse", "--verify", (ref or "HEAD") + "^{commit}")


def envelope_path(root, sha, kind):
    name = sha + (".json" if kind == "battery" else "-llm-skill-review.json")
    return os.path.join(root, ".cr-battery-runs", name)


def locate(args):
    """Return (root, sha, kind, path) for an existing envelope."""
    root = repo_root()
    sha = resolve_sha(args.sha)
    if args.kind:
        path = envelope_path(root, sha, args.kind)
        if not os.path.isfile(path):
            raise Refused("no %s envelope for %s; run init first (%s)" % (args.kind, sha[:8], path))
        return root, sha, args.kind, path
    found = [k for k in KINDS if os.path.isfile(envelope_path(root, sha, k))]
    if len(found) != 1:
        what = "both kinds exist" if found else "no envelope exists"
        raise UsageError("%s for %s; pass --kind battery|skill-review" % (what, sha[:8]))
    return root, sha, found[0], envelope_path(root, sha, found[0])


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            env = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refused("cannot read envelope %s: %s" % (path, e))
    if not isinstance(env, dict):
        raise Refused("envelope %s is not a JSON object" % path)
    env.setdefault("findings", [])
    env.setdefault("clean_dimensions", [])
    return env


def save(path, env):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".envelope-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(env, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def parse_expect(spec):
    # "count>0" and "count<=3" carry the comparator with no "=" separator.
    m = re.fullmatch(r"count\s*((?:<=|>=|<|>)\s*\d+)", spec)
    if m:
        return {"type": "count", "value": m.group(1)}
    typ, sep, value = spec.partition("=")
    if typ not in EXPECT_TYPES:
        raise UsageError("unknown expectation type %r (one of: %s)" % (typ, ", ".join(EXPECT_TYPES)))
    if typ == "absent":
        if sep:
            raise UsageError("absent takes no value")
        return {"type": "absent"}
    if not sep:
        raise UsageError("%s needs a value, e.g. %s" % (typ, {
            "count": "count=>0", "exit_code": "exit_code=0",
            "match": "match=REGEX", "exact": "exact=TEXT"}[typ]))
    # "count==2" splits into value "=2"; read a lone leading "=" as "==".
    if typ == "count" and re.fullmatch(r"=\s*\d+", value):
        value = "=" + value
    return {"type": typ, "value": value}


def build_evidence(args):
    if args.unverifiable is not None:
        if args.cmd or args.expect:
            raise UsageError("--unverifiable cannot be combined with --cmd/--expect")
        if not args.unverifiable.strip():
            raise UsageError("--unverifiable needs a rationale")
        return {"verifiable": False, "rationale": args.unverifiable}
    if not args.cmd or not args.expect:
        raise UsageError("give --cmd and --expect, or --unverifiable WHY")
    return {"command": args.cmd, "expectation": parse_expect(args.expect), "verifiable": True}


def replay(claim, root):
    """Run one claim's evidence through the verifier. Returns its result dict."""
    if shutil.which("node") is None:
        raise Refused("node is not on PATH; it is needed to replay evidence")
    r = subprocess.run(
        ["node", "-e", NODE_REPLAY, VERIFIER, json.dumps(claim), root],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise Refused("verifier replay crashed: %s" % (r.stderr.strip() or r.stdout.strip()))
    return json.loads(r.stdout)


def stdout_preview(cmd, root, limit=20):
    """Re-run CMD to show what it printed. Diagnostics only, never a verdict."""
    try:
        r = subprocess.run(cmd, shell=True, cwd=root, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=30)
    except subprocess.TimeoutExpired:
        return "  (timed out re-running for preview)"
    lines = r.stdout.splitlines()
    shown = ["  | " + line for line in lines[:limit]]
    if len(lines) > limit:
        shown.append("  | ... (%d more lines)" % (len(lines) - limit))
    shown.append("  exit=%d, non-blank lines=%d" % (r.returncode, sum(1 for x in lines if x.strip())))
    return "\n".join(shown)


def require_verified(claim, root):
    """Replay the claim; raise Refused unless it verifies. Judgment claims pass through."""
    ev = claim["evidence"]
    if ev.get("verifiable") is False:
        print("note: judgment claim (verifiable:false); the verifier caps this dimension at 7.0",
              file=sys.stderr)
        return
    result = replay(claim, root)
    status = result.get("status")
    observed = result.get("observed") or result.get("detail") or ""
    if status == "verified":
        print("verified: %s" % observed.strip())
        return
    raise Refused("expectation %s did not hold (%s: %s)\n  command: %s\n%s" % (
        json.dumps(ev["expectation"]), status, observed.strip(), ev["command"],
        stdout_preview(ev["command"], root)))


def next_finding_id(env):
    used = set()
    for f in env["findings"]:
        m = re.fullmatch(r"F(\d+)", str(f.get("id", "")))
        if m:
            used.add(int(m.group(1)))
    for c in env["clean_dimensions"]:
        m = re.match(r"F(\d+) \(", str(c.get("claim", "")))
        if m:
            used.add(int(m.group(1)))
    return "F%d" % (max(used, default=0) + 1)


def normalize_severity(kind, sev):
    if kind == "battery":
        s = sev.lower()
    else:
        s = sev.upper()
    if s not in SEVERITIES[kind]:
        other = "skill-review" if kind == "battery" else "battery"
        hint = " (that is the %s scale)" % other if sev.lower() in [x.lower() for x in SEVERITIES[other]] else ""
        raise UsageError("severity %r is not valid for %s envelopes%s; use one of: %s"
                         % (sev, kind, hint, ", ".join(SEVERITIES[kind])))
    return s


# --- subcommands --------------------------------------------------------------

def cmd_init(args):
    if not args.kind:
        raise UsageError("init needs --kind battery|skill-review")
    root = repo_root()
    sha = resolve_sha(args.sha)
    path = envelope_path(root, sha, args.kind)
    if os.path.exists(path) and not args.force:
        raise Refused("%s already exists; pass --force to replace it" % path)
    env = {"head_sha": sha}
    if args.kind == "battery":
        env.update({"run_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "verdict": None, "score": None, "rounds": 1})
    else:
        env.update({"verdict": None, "mean": None})
    env.update({"findings": [], "clean_dimensions": []})
    save(path, env)
    print(path)


def cmd_add_clean(args):
    root, _sha, _kind, path = locate(args)
    env = load(path)
    claim = {"reviewer": args.reviewer, "dimension": args.dimension,
             "claim": args.claim, "evidence": build_evidence(args)}
    require_verified(claim, root)
    env["clean_dimensions"].append(claim)
    save(path, env)
    print("added clean dimension #%d to %s" % (len(env["clean_dimensions"]), os.path.basename(path)))


def cmd_add_finding(args):
    root, _sha, kind, path = locate(args)
    env = load(path)
    if args.line < 0:
        raise UsageError("--line must be 0 or a positive line number")
    finding = {"id": next_finding_id(env), "reviewer": args.reviewer,
               "dimension": args.dimension, "severity": normalize_severity(kind, args.severity),
               "file": args.file, "line": args.line, "claim": args.claim,
               "evidence": build_evidence(args)}
    require_verified(finding, root)
    env["findings"].append(finding)
    save(path, env)
    print("added open finding %s (%s) to %s" % (finding["id"], finding["severity"], os.path.basename(path)))


def cmd_resolve(args):
    root, _sha, _kind, path = locate(args)
    env = load(path)
    matches = [f for f in env["findings"] if f.get("id") == args.id]
    if not matches:
        open_ids = ", ".join(str(f.get("id")) for f in env["findings"]) or "none"
        raise Refused("no open finding %s (open: %s)" % (args.id, open_ids))
    finding = matches[0]
    text = args.claim or finding.get("claim", "")
    clean = {"reviewer": finding.get("reviewer"), "dimension": finding.get("dimension"),
             "claim": "%s (%s, fixed): %s" % (args.id, finding.get("severity"), text),
             "evidence": {"command": args.cmd, "expectation": parse_expect(args.expect),
                          "verifiable": True}}
    require_verified(clean, root)
    env["findings"] = [f for f in env["findings"] if f is not finding]
    env["clean_dimensions"].append(clean)
    save(path, env)
    print("resolved %s; %d open finding(s) remain" % (args.id, len(env["findings"])))


def cmd_set(args):
    _root, _sha, kind, path = locate(args)
    env = load(path)
    if args.verdict not in VERDICTS[kind]:
        raise UsageError("verdict %r is not valid for %s; use one of: %s"
                         % (args.verdict, kind, ", ".join(VERDICTS[kind])))
    field, value = ("score", args.score) if kind == "battery" else ("mean", args.mean)
    wrong = args.mean if kind == "battery" else args.score
    if wrong is not None:
        raise UsageError("%s envelopes take --%s, not --%s"
                         % (kind, field, "mean" if kind == "battery" else "score"))
    if value is None:
        raise UsageError("set needs --%s for %s envelopes" % (field, kind))
    if not 0.0 <= value <= 10.0:
        raise UsageError("--%s must be between 0 and 10" % field)
    env["verdict"] = args.verdict
    env[field] = value
    save(path, env)
    print("verdict=%s %s=%s" % (args.verdict, field, value))


def cmd_check(args):
    root, sha, kind, path = locate(args)
    env = load(path)
    problems = []
    head = resolve_sha("HEAD")
    if env.get("head_sha") != sha:
        problems.append("head_sha %r does not match %s" % (env.get("head_sha"), sha))
    if sha != head:
        problems.append("envelope is for %s but HEAD is %s; the runner reads HEAD's envelope"
                        % (sha[:8], head[:8]))
    if env.get("verdict") is None:
        problems.append("verdict is not set (run: set --verdict ...)")
    if kind == "skill-review":
        open_blocking = [f.get("id", "?") for f in env["findings"]
                         if f.get("severity") in ("S0", "S1") and not f.get("waiver")]
        if open_blocking:
            problems.append("open S0/S1 findings block the sentinel: %s" % ", ".join(open_blocking))

    with tempfile.TemporaryDirectory(prefix="review-envelope-check-") as tmpdir:
        copy = os.path.join(tmpdir, os.path.basename(path))
        shutil.copyfile(path, copy)
        r = subprocess.run(["node", VERIFIER, copy, "--cwd", root], capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        if r.returncode != 0:
            problems.append("evidence replay failed (verifier exit %d)" % r.returncode)
        if kind == "skill-review":
            g = subprocess.run(["node", SKILL_GATE, copy, "--head-sha", sha],
                               capture_output=True, text=True)
            sys.stdout.write(g.stdout)
            sys.stderr.write(g.stderr)
            if g.returncode != 0:
                problems.append("skill-review envelope gate refused it")

    if problems:
        print("CHECK FAILED: %s" % os.path.basename(path))
        for p in problems:
            print("  - " + p)
        return 1
    print("CHECK OK: %s (%d open finding(s), %d clean dimension(s))"
          % (os.path.basename(path), len(env["findings"]), len(env["clean_dimensions"])))
    return 0


def cmd_path(args):
    _root, _sha, _kind, path = locate(args)
    print(path)


# --- argument parsing ---------------------------------------------------------

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def build_parser():
    common = Parser(add_help=False)
    common.add_argument("--kind", choices=KINDS)
    common.add_argument("--sha", help="commit the envelope is for (default HEAD)")

    evidence = Parser(add_help=False)
    evidence.add_argument("--cmd", help="shell command whose output proves the claim")
    evidence.add_argument("--expect", help="TYPE[=VALUE]: count, exit_code, match, absent, exact")
    evidence.add_argument("--unverifiable", metavar="WHY",
                          help="judgment claim with no replayable command (capped at 7.0)")

    p = Parser(prog="review-envelope.py", add_help=False)
    p.add_argument("-h", "--help", action="store_true")
    sub = p.add_subparsers(dest="command", parser_class=Parser)

    s = sub.add_parser("init", parents=[common])
    s.add_argument("--force", action="store_true")

    for name in ("add-clean", "add-finding"):
        s = sub.add_parser(name, parents=[common, evidence])
        s.add_argument("--reviewer", required=True)
        s.add_argument("--dimension", required=True)
        s.add_argument("--claim", required=True)
        if name == "add-finding":
            s.add_argument("--severity", required=True)
            s.add_argument("--file", required=True)
            s.add_argument("--line", required=True, type=int)

    s = sub.add_parser("resolve", parents=[common])
    s.add_argument("id")
    s.add_argument("--cmd", required=True)
    s.add_argument("--expect", required=True)
    s.add_argument("--claim", help="what the fix did (default: the finding's claim)")

    s = sub.add_parser("set", parents=[common])
    s.add_argument("--verdict", required=True)
    s.add_argument("--score", type=float)
    s.add_argument("--mean", type=float)

    sub.add_parser("check", parents=[common])
    sub.add_parser("path", parents=[common])
    return p


COMMANDS = {"init": cmd_init, "add-clean": cmd_add_clean, "add-finding": cmd_add_finding,
            "resolve": cmd_resolve, "set": cmd_set, "check": cmd_check, "path": cmd_path}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0 if argv else 2
    try:
        args = build_parser().parse_args(argv)
        if args.command is None:
            raise UsageError("missing subcommand")
        return COMMANDS[args.command](args) or 0
    except UsageError as e:
        print("usage error: %s (see --help)" % e, file=sys.stderr)
        return 2
    except Refused as e:
        print("REFUSED: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
