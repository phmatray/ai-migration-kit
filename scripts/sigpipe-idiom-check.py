#!/usr/bin/env python3
"""sigpipe-idiom-check.py -- refuse a positive-match `grep -q` fed by a streaming producer (#391).

Why this exists. `awk '/a/,/b/' f | grep -qF x` under `set -o pipefail`: `grep -q` exits the
instant it matches and closes the read end of the pipe; a producer with a RANGE or a full-file
scan (awk's range pattern, `tail -n +N`, a diff --stat, ...) is often still writing when that
happens, gets SIGPIPE (141), and under `pipefail` that 141 -- not grep's real (successful) exit
code -- becomes the pipeline's status. A positive assertion spelled `PIPE || { FAIL; }` then
reports a failure that did not happen. Measured on `tests/survey/test.sh` case 12d: ~22% of runs
(#391).

#48 shipped the general doctrine (`tests/_lib.sh`'s `first_match`/`any_match`) and #123 widened one
anti-recurrence guard (`tests/xunit-v3/test.sh` section 10) -- but only for the literal producer
`find`, in three files. This gate generalises both: any external, streaming producer, anywhere
under `tests/` and `scripts/`.

THE SHAPE IT FLAGS: a line piping an external producer into a `grep` call whose flags include `q`
(quiet -- exit on first match, the thing that races). THE SHAPE IT DOES NOT FLAG: a `grep -q` that
is negated (`if !`, a leading `!`, `|| true`, `|| :` -- its non-match is the outcome nothing acts
on being wrong), a `grep -q` fed by a command SUBSTITUTION rather than a pipe (the substitution
completes before `grep` starts, so there is nothing to race), a comment, or a line tagged
`sigpipe-repro`. The remedy is never `set +o pipefail`: `pipefail` is load-bearing everywhere else
in these suites, and suspending it per-site would reintroduce the swallowed-failure class #48
exists to stop. The remedy is the herestring idiom already used at `tests/lib/test.sh:425` --
capture the pipeline into a variable, then read the variable: `var=$(producer ...); grep -q ...
<<<"$var"`. A variable assignment has nothing to close early, so there is nothing left to race.

Ported alongside `scripts/pinned-literals-check.py` and its three structural siblings -- same
shape: `python3 scripts/sigpipe-idiom-check.py [dir]` exits 0 and prints nothing on a clean tree,
exits 1 naming every offending `path:line` plus the remedy, exits 2 on a usage error.

WHAT IT DELIBERATELY DOES NOT DO. It does not touch `pipefail`, rewrite a call site, or judge
whether a given pipeline has EVER actually raced -- that would need a producer whose output is
large enough, and slow enough, to still be writing when `grep` exits, which is exactly the kind of
thing that is fine 99% of the time and NOT fine on a loaded CI runner. The shape is the hazard;
this gate flags the shape.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PRODUCERS = frozenset(
    "awk sed grep tail head sort uniq tr cat jq find git python3 xargs yq".split()
)

QUIET_LONG = frozenset(("--quiet", "--silent"))

SELF_PATH = "scripts/sigpipe-idiom-check.py"
FIXTURE_PREFIX = "tests/sigpipe-idiom/"

NEGATED_RE = re.compile(r"^\s*(if\s+)?!\s")
DISCARDED_RE = re.compile(r"\|\|\s*(true|:)\s*;?\s*$")
LEADING_KEYWORD_RE = re.compile(r"^\s*(if|elif|while|until)\s+")

_MARK = "\x00"


def split_pipeline_clauses(line):
    clauses = []
    buf = []
    depth = 0
    in_squote = False
    in_dquote = False
    i, n = 0, len(line)

    def flush_clause():
        text = "".join(buf)
        buf.clear()
        clause = text.split(_MARK)
        if any(seg.strip() for seg in clause):
            clauses.append(clause)

    while i < n:
        c = line[i]
        if in_squote:
            buf.append(c)
            if c == "'":
                in_squote = False
            i += 1
            continue
        if in_dquote:
            if c == "\\" and i + 1 < n:
                buf.append(c)
                buf.append(line[i + 1])
                i += 2
                continue
            buf.append(c)
            if c == '"':
                in_dquote = False
            i += 1
            continue
        if c == "'":
            in_squote = True
            buf.append(c)
            i += 1
            continue
        if c == '"':
            in_dquote = True
            buf.append(c)
            i += 1
            continue
        if c == "(":
            depth += 1
            buf.append(c)
            i += 1
            continue
        if c == ")":
            depth = max(0, depth - 1)
            buf.append(c)
            i += 1
            continue
        if depth == 0:
            if c == ";":
                flush_clause()
                i += 1
                continue
            if c == "&":
                flush_clause()
                i += 2 if (i + 1 < n and line[i + 1] == "&") else 1
                continue
            if c == "|":
                if i + 1 < n and line[i + 1] == "|":
                    flush_clause()
                    i += 2
                    continue
                buf.append(_MARK)
                i += 1
                continue
        buf.append(c)
        i += 1
    flush_clause()
    return clauses


def grep_dash_q(segment):
    tokens = segment.strip().split()
    if not tokens or tokens[0] != "grep":
        return False
    for tok in tokens[1:]:
        if tok == "--":
            break
        if tok in QUIET_LONG:
            return True
        if len(tok) > 1 and tok[0] == "-" and tok[1] != "-":
            if "q" in tok[1:]:
                return True
            continue
        if tok.startswith("--"):
            continue
        break
    return False


def producer_word(segment, is_clause_head):
    if is_clause_head:
        segment = LEADING_KEYWORD_RE.sub("", segment, count=1)
    stripped = segment.strip()
    if not stripped:
        return ""
    first = stripped.split()[0].strip("'\"`")
    return os.path.basename(first)


def offending_line(line):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return False
    if "sigpipe-repro" in line:
        return False
    if NEGATED_RE.match(line):
        return False
    if DISCARDED_RE.search(line.rstrip()):
        return False

    for clause in split_pipeline_clauses(line):
        if len(clause) < 2:
            continue
        if not grep_dash_q(clause[-1]):
            continue
        for idx, segment in enumerate(clause[:-1]):
            if producer_word(segment, is_clause_head=(idx == 0)) in PRODUCERS:
                return True
    return False


def _trailing_backslash_count(s):
    n = 0
    for ch in reversed(s):
        if ch != "\\":
            break
        n += 1
    return n


def _is_continuation(line):
    # A line ending in an ODD run of backslashes is a real shell line continuation; an even run
    # is that many literal backslashes (the last one escaped by its neighbour), continuing
    # nothing. A comment line's trailing `\` continues no shell statement either.
    if line.strip().startswith("#"):
        return False
    return _trailing_backslash_count(line) % 2 == 1


def logical_lines(text):
    """Yield (reporting_lineno, joined_text) -- a line-continued pipeline is joined into ONE
    logical line before matching, and reported at the line carrying the tail of the pipeline
    (where `grep -q` actually sits), per the shape a continued `producer | \\` / `  grep -q x`
    pipeline has: the reader is what closes early, and the reader is always last."""
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        if not _is_continuation(lines[i]):
            yield (i + 1, lines[i])
            i += 1
            continue
        group = []
        j = i
        while j < n and _is_continuation(lines[j]):
            seg = lines[j]
            group.append(seg[: -1] if seg.endswith("\\") else seg)
            j += 1
        if j < n:
            group.append(lines[j])
        last_idx = min(j, n - 1)
        yield (last_idx + 1, " ".join(group))
        i = j + 1


def tracked_files(repo):
    gitbin = "git"
    try:
        out = subprocess.run(
            [gitbin, "-C", str(repo), "ls-files", "-z", "--", "tests", "scripts"],
            capture_output=True, check=True,
        ).stdout
        names = [n for n in out.decode("utf-8", "replace").split("\0") if n]
        if names:
            return names
    except (OSError, subprocess.CalledProcessError):
        pass

    names = []
    for sub in ("tests", "scripts"):
        base = repo / sub
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d != ".git")
            for name in sorted(filenames):
                names.append(str(Path(dirpath, name).relative_to(repo)))
    return names


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("dir", nargs="?", default=".", help="repo root to scan (default: cwd)")
    args = ap.parse_args()

    repo = Path(args.dir).resolve()
    if not repo.is_dir():
        print("sigpipe-idiom-check: %s is not a directory." % repo, file=sys.stderr)
        return 2

    findings = []
    for rel in tracked_files(repo):
        if rel == SELF_PATH or rel.startswith(FIXTURE_PREFIX):
            continue
        path = repo / rel
        try:
            text = path.read_text(encoding="utf-8", errors="strict")
        except (OSError, UnicodeDecodeError):
            continue
        for lineno, joined in logical_lines(text):
            if offending_line(joined):
                findings.append((rel, lineno, joined.strip()))

    if not findings:
        return 0

    for rel, lineno, text in findings:
        print("%s:%d: %s" % (rel, lineno, text))
        print(
            "  remedy: capture the pipeline into a variable first, then read the variable via a "
            "herestring -- var=$(producer ...); grep -q ... <<<\"$var\" (tests/lib/test.sh:425). "
            "A variable assignment has nothing to close early, so there is nothing left to race."
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
