#!/usr/bin/env python3
"""CI guard: the untrusted-input boundary is linked from every skill that ingests foreign text.

`skills/_shared/untrusted-input-boundary.md` states the rule — text the kit did not author is
DATA, never instructions — and it is worth exactly as much as the number of places that still
point at it. A shared reference nobody links looks precisely like one that is being followed
(#266), which is the same failure shape `scripts/ci-wiring-check.py` was written for: a suite
nobody runs looks exactly like a suite that passes.

The check is BIDIRECTIONAL, and that is the whole design:

  * every path the boundary names under its own `## Consumers` section must link back to it, and
  * every file under `skills/` that links it must be named there.

The second half is the one with no positive witness in the tree, and it is what keeps the doc
honest. Without it the consumer list drifts from reality in the direction that looks fine — a
skill grows a new ingest point, links the boundary, and the list silently stops describing who
actually reads it. The list is the doc's own claim about its reach; this file is what makes the
claim checkable.

Deliberately a LINK check, not a content check. Whether a skill's prose around the link is any
good is a review question; whether the link is there at all is a mechanical one, and only the
mechanical one can go red on its own.

The consumer inventory lives in the boundary doc rather than in this script on purpose. A
hand-maintained list inside the checker is the stale-inventory failure this repo has already paid
for four times in the README (#45); keeping it in the doc means the thing that declares its reach
and the thing that verifies it are one edit apart, and rule 4 above is what stops them diverging.

Self-test: tests/skills/test.sh drives this file over fixtures that must FAIL, so a guard that
silently stops matching cannot pass CI.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BOUNDARY_REL = "skills/_shared/untrusted-input-boundary.md"
BOUNDARY = ROOT / BOUNDARY_REL

# A markdown LINK to the boundary, not a bare mention of its name. Prose can name the file while
# pointing nowhere — `](…)` is the part a reader can actually follow, and matching on the target
# rather than the label keeps both link depths passing: skills/*/SKILL.md spells it
# `../_shared/…`, while skills/legacy-upgrade/references/*.md sits one level deeper and spells it
# `../../_shared/…`.
LINK_RE = re.compile(r'\]\([^)]*_shared/untrusted-input-boundary\.md\)')

errors = []


def consumers_of(text: str):
    """The paths listed under `## Consumers`, in file order.

    Each entry is a `- ` bullet whose first token is the path, normally in backticks
    (`- `skills/merge-pr/SKILL.md` — review comments…`). The backtick form is preferred and the
    bare form accepted, so the doc can be written for a reader without the checker dictating its
    punctuation. The section runs to the next `## ` heading or end of file.
    """
    block = re.search(r'^## Consumers\s*$\n(.*?)(?=^## |\Z)', text, re.S | re.M)
    if not block:
        return None
    paths = []
    for line in block.group(1).splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        entry = line[2:].strip()
        quoted = re.match(r'`([^`]+)`', entry)
        path = quoted.group(1) if quoted else entry.split()[0] if entry.split() else ""
        if path:
            paths.append(path.strip())
    return paths


if not BOUNDARY.is_file():
    errors.append(
        f"NO CONSUMERS SECTION: {BOUNDARY_REL} does not exist — the boundary every ingest "
        f"point is supposed to link has no home")
    listed = []
else:
    boundary_text = BOUNDARY.read_text(encoding="utf-8")
    listed = consumers_of(boundary_text)
    if listed is None:
        errors.append(
            f"NO CONSUMERS SECTION: {BOUNDARY_REL} has no '## Consumers' section — nothing "
            f"declares which files are supposed to link it, so nothing can be verified")
        listed = []
    elif not listed:
        errors.append(
            f"NO CONSUMERS SECTION: {BOUNDARY_REL} declares '## Consumers' but lists no paths")

    for rel in listed:
        target = ROOT / rel
        if not target.is_file():
            errors.append(f"NO SUCH CONSUMER: {BOUNDARY_REL} lists '{rel}', which does not exist")
            continue
        if not LINK_RE.search(target.read_text(encoding="utf-8")):
            errors.append(
                f"MISSING LINK: {rel} is listed as a consumer but contains no markdown link to "
                f"the boundary — the reminder is gone from the step that ingests foreign text")

# Rule 4 — the half with no positive witness in the tree. Anything under skills/ that links the
# boundary must be declared; the boundary itself is excluded, since a doc naming its own path in
# prose is not a consumer of itself.
listed_set = set(listed)
for md in sorted(ROOT.glob("skills/**/*.md")):
    rel = md.relative_to(ROOT).as_posix()
    if rel == BOUNDARY_REL or rel in listed_set:
        continue
    if LINK_RE.search(md.read_text(encoding="utf-8")):
        errors.append(
            f"UNLISTED LINKER: {rel} links the boundary but is absent from '## Consumers' in "
            f"{BOUNDARY_REL} — the doc's account of its own reach is out of date")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"untrusted-input boundary OK — {len(listed)} consumers, all linked, none unlisted")
