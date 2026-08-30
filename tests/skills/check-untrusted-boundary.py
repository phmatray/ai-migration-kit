#!/usr/bin/env python3
"""CI guard: the untrusted-input boundary is linked from every place that ingests foreign text.

`skills/_shared/untrusted-input-boundary.md` states the rule — text the kit did not author is
DATA, never instructions — and it is worth exactly as much as the number of places that still
point at it. A shared reference nobody links looks precisely like one that is being followed
(#266), which is the same failure shape `scripts/ci-wiring-check.py` was written for: a suite
nobody runs looks exactly like a suite that passes.

The check is BIDIRECTIONAL, and that is the whole design:

  * every path the boundary names under its own `## Consumers` section must link back to it, and
  * every file in the scanned tree that points at it must be named there.

The second half is the one with no positive witness in the tree, and it is what keeps the doc
honest. Without it the consumer list drifts from reality in the direction that looks fine — a
skill grows a new ingest point, links the boundary, and the list silently stops describing who
actually reads it.

**The link must RESOLVE, not merely read well.** A consumer whose relative link sits at the wrong
depth (`../_shared/…` from a file that needs `../../_shared/…`) still contains every character a
substring test looks for, while the reminder it is supposed to reach is unreachable — which is the
one regression that empties this guard of meaning while leaving all its text in place. So targets
are resolved against the linking file's own directory and compared to the boundary's real path,
and a link that names the boundary but lands somewhere else is reported as BROKEN, not missing.

The scan is deliberately wider than `skills/` (#266 review). `commands/auto-dev-worker.md` is
read by a fresh `claude -p` worker that never opens `skills/auto-dev/SKILL.md`, so it is a first-
class consumer; a reverse check that stopped at `skills/` would forward-check it and never notice
the list going stale in the other direction, while the CI step's name promises both.

The consumer inventory lives in the boundary doc rather than in this script on purpose. A
hand-maintained list inside the checker is the stale-inventory failure this repo has already paid
for four times in the README (#45); keeping it in the doc means the thing that declares its reach
and the thing that verifies it are one edit apart, and the reverse rule is what stops them
diverging.

Self-test: tests/skills/test.sh drives this file over fixtures that must FAIL, so a guard that
silently stops matching cannot pass CI.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BOUNDARY_REL = "skills/_shared/untrusted-input-boundary.md"
BOUNDARY = ROOT / BOUNDARY_REL
BOUNDARY_NAME = "untrusted-input-boundary.md"

# Where a link to the boundary can legitimately come from. Wider than skills/ so the reverse rule
# covers every surface that can carry one — commands/ above all, which is what a dispatched worker
# actually reads. Root-level prose is included because ARCHITECTURE.md already links _shared/.
SCAN_DIRS = ("skills", "commands", "templates", "docs")

# Any markdown link target. The boundary filter happens after extraction, so a link that NAMES the
# boundary but resolves elsewhere is still seen — that is the BROKEN case, and a `.md`-suffix
# substring test could not tell it from a working one.
LINK_TARGET_RE = re.compile(r'\]\(([^)\s]+)')

errors = []


def read(path: Path):
    """File text, or None when it cannot be decoded or read.

    A single stray non-UTF-8 byte anywhere under the scanned tree would otherwise turn this gate
    into a Python traceback instead of a verdict. tests/skills/test.sh's sibling scanner over the
    same tree takes the same precaution.
    """
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def boundary_links(path: Path, text: str):
    """(names_it, resolves_to_it) for the boundary links in `text`.

    `names_it` answers "was this file trying to point at the boundary" — the question the reverse
    rule asks, and one a broken link still answers yes to. `resolves_to_it` answers "can a reader
    actually get there", which is what a consumer has to satisfy.
    """
    names_it = False
    resolves = False
    for target in LINK_TARGET_RE.findall(text):
        target = target.split('#', 1)[0]
        if not target.endswith(BOUNDARY_NAME):
            continue
        names_it = True
        try:
            if (path.parent / target).resolve() == BOUNDARY.resolve():
                resolves = True
        except (OSError, ValueError):
            continue
    return names_it, resolves


def consumers_of(text: str):
    """The paths listed under `## Consumers`, in file order, or None if there is no section.

    Only a bullet whose first token is BACKTICKED counts as an entry: `- `skills/x/SKILL.md` — …`.
    Prose bullets are skipped rather than read as paths — the section is written for a human, and
    a reflowed sentence turning into `NO SUCH CONSUMER: … lists 'Anything'` would be the checker
    dictating the doc's punctuation instead of verifying its claim (#266 review).
    """
    block = re.search(r'^## Consumers\s*$\n(.*?)(?=^## |\Z)', text, re.S | re.M)
    if not block:
        return None
    paths = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        quoted = re.match(r'`([^`]+)`', line[2:].strip())
        if quoted:
            paths.append(quoted.group(1).strip())
    return paths


# ---------------------------------------------------------------------------------------------
# Read the inventory. `listed is None` means it could NOT be read — a different answer from "it
# is empty", and the reason the reverse rule below is skipped in that case rather than run against
# an inventory nobody has. Reporting five files as "absent from ## Consumers in <file>" when that
# file does not exist is a refusal that contradicts itself; ci-wiring-check.py tracks the same
# distinction for the same reason (#238).
listed = None

if not BOUNDARY.is_file():
    errors.append(
        f"NO BOUNDARY FILE: {BOUNDARY_REL} does not exist — the reference every ingest point is "
        f"supposed to link has no home, so nothing about its reach can be checked")
else:
    boundary_text = read(BOUNDARY)
    if boundary_text is None:
        errors.append(f"NO BOUNDARY FILE: {BOUNDARY_REL} could not be read as UTF-8")
    else:
        listed = consumers_of(boundary_text)
        if listed is None:
            errors.append(
                f"NO CONSUMERS SECTION: {BOUNDARY_REL} has no '## Consumers' section — nothing "
                f"declares which files are supposed to link it, so nothing can be verified")
        elif not listed:
            errors.append(
                f"EMPTY CONSUMERS SECTION: {BOUNDARY_REL} declares '## Consumers' and lists no "
                f"backticked path — every ingest point below is therefore undeclared")

for rel in listed or []:
    target = ROOT / rel
    try:
        target.resolve().relative_to(ROOT.resolve())
    except ValueError:
        errors.append(
            f"CONSUMER OUTSIDE THE REPO: {BOUNDARY_REL} lists '{rel}', which resolves outside "
            f"the repository — the inventory is malformed, not merely wrong")
        continue
    if not target.is_file():
        errors.append(f"NO SUCH CONSUMER: {BOUNDARY_REL} lists '{rel}', which does not exist")
        continue
    text = read(target)
    if text is None:
        errors.append(f"NO SUCH CONSUMER: '{rel}' could not be read as UTF-8")
        continue
    names_it, resolves = boundary_links(target, text)
    if resolves:
        continue
    if names_it:
        errors.append(
            f"BROKEN LINK: {rel} links the boundary by name, but the target does not resolve to "
            f"{BOUNDARY_REL} — the reminder reads correctly and is unreachable")
    else:
        errors.append(
            f"MISSING LINK: {rel} is listed as a consumer but contains no link to the boundary — "
            f"the reminder is gone from the step that ingests foreign text")

# The reverse rule. Skipped entirely when the inventory could not be read (above): with no list to
# be absent from, every hit here would be a contradiction rather than a finding.
if listed is not None:
    listed_set = set(listed)
    candidates = []
    for d in SCAN_DIRS:
        candidates.extend((ROOT / d).glob("**/*.md"))
    candidates.extend(ROOT.glob("*.md"))
    for md in sorted(set(candidates)):
        rel = md.relative_to(ROOT).as_posix()
        if rel == BOUNDARY_REL or rel in listed_set:
            continue
        text = read(md)
        if text is None:
            continue
        names_it, _ = boundary_links(md, text)
        if names_it:
            errors.append(
                f"UNLISTED LINKER: {rel} points at the boundary but is absent from "
                f"'## Consumers' in {BOUNDARY_REL} — the doc's account of its own reach is out "
                f"of date")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"untrusted-input boundary OK — {len(listed)} consumers, all resolving, none unlisted")
