#!/usr/bin/env python3
"""recap-wiring-check.py — the kit's closing recap has one home, and one hand-off table nothing
re-types.

Why this exists (#175). Every skill ends by telling the user what it did, and every one of them
used to invent that ending from scratch: four spelled it out as a numbered `Report` step — each
asking for a different set of things — and four spelled it out nowhere at all. The line the user
actually acts on next (`/implement-issue #N` after `create-issue`) existed as prose in exactly two
of them, while ARCHITECTURE.md drew the same hand-offs as dashed mermaid edges. Two documentations
of one chain, and nothing that could disagree with either.

The failure being closed is the familiar one: **a hand-off nobody wrote down looks exactly like a
skill that has none.** `merge-pr` landed a PR and said nothing about what to do next; that read as
"terminal" rather than as "missing", and no test anywhere could tell the difference. Same shape as
#45 (a suite nobody runs looks like a suite that passes) and #72 (a check nobody registered looks
like a check that holds), and it gets the same treatment — a script, a golden suite that drives its
refusal paths, and a CI step that runs both.

What it checks, against `skills/_shared/recap.md`'s hand-off table:

  1. THE TABLE RESOLVES — every row names an existing `skills/<name>/SKILL.md`; every
     `skills/<name>/` directory except `_shared/` has exactly one row (no skill missing, no row
     orphaned); every `/<command>` named in a `Next command` cell resolves to a skill, directly
     (`skills/<name>/`) or through the command that invokes it (`commands/<name>.md`).

Everything here is `pathlib` + `re`: no shell idioms, so it behaves the same on a Windows checkout
(#174).

Usage:
  recap-wiring-check.py [--repo <path>]

Exit codes:
  0  the table, the skills and the graph agree
  1  REFUSE — one line per violation on stdout, prefixed `REFUSE:`
  2  usage / plumbing error (`ERR:`) — the reference is missing, unreadable, or carries no rows, so
     no verdict is possible. Never conflate this with 1: an absent verdict is not a pass and it is
     not a refusal either.
"""

import argparse
import pathlib
import re
import sys

# The reference that owns the recap shape and the hand-off table.
RECAP_REL = pathlib.PurePosixPath("skills/_shared/recap.md")

# `skills/_shared/` holds shared references, not a skill — it has no SKILL.md and gets no row.
NOT_A_SKILL = {"_shared"}

# The header cells that identify the hand-off table among any other tables in the reference.
TABLE_HEADER = ("skill", "ends with", "next command")

# A backticked `/command` span in a Next-command cell. The leading `/` is what marks it as a command
# rather than an inline mention of a path or a flag, and the name stops at the first space so
# `/implement-issue #<issue>` and `/get-repo-profile --refresh` both resolve to their skill.
COMMAND_RE = re.compile(r"`\s*/([A-Za-z0-9][A-Za-z0-9._-]*)")

# `commands/<name>.md` says which skill it drives in one sentence: Invoke the `followups` skill.
COMMAND_TARGET_RE = re.compile(r"`([A-Za-z0-9][A-Za-z0-9._-]*)`\s+skill")


class PlumbingError(Exception):
    """No verdict is possible — exit 2, never 1."""


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PlumbingError("cannot read %s: %s" % (path, exc))


def strip_code(cell):
    """The bare text of a markdown table cell: backticks and bold markers removed."""
    return cell.replace("`", "").replace("**", "").strip()


def parse_handoff_table(path):
    """The hand-off table as a list of dicts with keys `skill`, `ends_with`, `next`.

    `next` is the cell verbatim (prose included) — the commands are extracted from it separately,
    so rewording the prose around a command can never change the verdict.
    """
    rows = []
    in_fence = False
    header_seen = False
    for line in read_text(path).splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if not stripped.startswith("|"):
            # A blank or prose line ends the table we were reading.
            if header_seen and not stripped.startswith("|"):
                if rows:
                    break
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if not header_seen:
            if len(cells) >= 3 and tuple(c.lower() for c in cells[:3]) == TABLE_HEADER:
                header_seen = True
            continue
        if set(stripped) <= set("|-: "):
            continue  # the header separator
        if len(cells) < 3:
            raise PlumbingError("malformed hand-off row in %s: %s" % (path, stripped))
        rows.append({"skill": strip_code(cells[0]), "ends_with": cells[1], "next": cells[2]})
    if not header_seen:
        raise PlumbingError(
            "%s has no hand-off table (a row `| Skill | Ends with | Next command |`)" % path)
    if not rows:
        raise PlumbingError("%s's hand-off table has no rows — that is not 'every skill wired'" % path)
    return rows


def commands_in(cell):
    """The `/command` names a Next-command cell hands off to, in order. Empty means terminal."""
    return COMMAND_RE.findall(cell)


def skill_dirs(repo):
    skills_root = repo / "skills"
    if not skills_root.is_dir():
        raise PlumbingError("%s has no skills/ directory" % repo)
    found = sorted(
        d.name for d in skills_root.iterdir()
        if d.is_dir() and d.name not in NOT_A_SKILL and (d / "SKILL.md").is_file()
    )
    if not found:
        raise PlumbingError("%s/skills holds no <name>/SKILL.md — nothing to check" % repo)
    return found


def resolve_command(repo, name):
    """The skill a `/name` hand-off lands on, or None when it resolves to nothing.

    Directly when `skills/<name>/SKILL.md` exists; otherwise through `commands/<name>.md`, which
    names the skill it invokes — that indirection is what makes `/migrate-followups` a hand-off to
    `followups` rather than an unresolvable dead end.
    """
    if (repo / "skills" / name / "SKILL.md").is_file():
        return name
    command_file = repo / "commands" / ("%s.md" % name)
    if command_file.is_file():
        for target in COMMAND_TARGET_RE.findall(read_text(command_file)):
            if (repo / "skills" / target / "SKILL.md").is_file():
                return target
    return None


def check_table_resolves(repo, rows):
    """Assertion 1 — the table and the skills/ tree name the same set of skills."""
    refusals = []
    seen = {}
    for row in rows:
        name = row["skill"]
        seen.setdefault(name, 0)
        seen[name] += 1
        if not (repo / "skills" / name / "SKILL.md").is_file():
            refusals.append(
                "REFUSE: %s names `%s`, but skills/%s/SKILL.md does not exist — delete the row or "
                "restore the skill" % (RECAP_REL, name, name))
        for command in commands_in(row["next"]):
            if resolve_command(repo, command) is None:
                refusals.append(
                    "REFUSE: %s's `%s` row hands off to `/%s`, which is neither a skill nor a "
                    "command in this repo" % (RECAP_REL, name, command))
    for name, count in sorted(seen.items()):
        if count > 1:
            refusals.append(
                "REFUSE: %s carries %d rows for `%s` — a skill has exactly one next step"
                % (RECAP_REL, count, name))
    for name in skill_dirs(repo):
        if name not in seen:
            refusals.append(
                "REFUSE: skills/%s has no hand-off row in %s — decide what follows it, `—` if "
                "nothing does" % (name, RECAP_REL))
    return refusals


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--repo", default=str(pathlib.Path(__file__).resolve().parent.parent),
        help="repository root to check (default: the repo this script ships in)")
    args = parser.parse_args(argv)
    repo = pathlib.Path(args.repo).resolve()

    try:
        rows = parse_handoff_table(repo / RECAP_REL)
        refusals = check_table_resolves(repo, rows)
    except PlumbingError as exc:
        print("ERR: %s" % exc)
        return 2

    if refusals:
        for line in refusals:
            print(line)
        return 1
    print("OK: %d skills, one hand-off row each, every next command resolves" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
