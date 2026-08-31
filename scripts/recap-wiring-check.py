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
  2. EVERY SKILL LINKS THE REFERENCE — each `skills/<name>/SKILL.md` points at
     `_shared/recap.md`, so a skill cannot quietly grow a hand-written ending again. The link is
     what the check can see; whether a given RUN filled the four blocks is a judgement call and
     stays one, exactly as it does for `preconditions.md`.
  3. ARCHITECTURE.md AGREES — the dashed edges of the skill call graph (`A -. "…" .-> B`) form
     exactly the same set of `(skill, next-skill)` pairs as the table's non-terminal rows. Extra on
     either side refuses, naming which side lacks it. SOLID edges are ignored on purpose: they mean
     "invokes during its own run" (`MP --> CI` files follow-ups through create-issue), and reading
     one as a hand-off would contradict merge-pr's own row, which points at implement-issue.
     Only the `(from, to)` pair is compared, never the edge's label — so rewording the prose on an
     arrow can never produce a false refusal.

Everything here is `pathlib` + `re`: no shell idioms, so it behaves the same on a Windows checkout
(#174).

Usage:
  recap-wiring-check.py [--repo <path>]

Exit codes:
  0  the table, the skills and the graph agree
  1  REFUSE — one line per violation on stdout, prefixed `REFUSE:`
  2  usage / plumbing error (`ERR:`) — no verdict is possible: the reference is missing, unreadable,
     carries no rows or a row with fewer than three columns; `skills/` is absent or empty;
     ARCHITECTURE.md is missing, or has no `## Skill call graph` section or no fence under it.
     Never conflate this with 1: an absent verdict is not a pass and it is not a refusal either.
     Refusals already found by the earlier assertions are still PRINTED before the `ERR:` line —
     losing a verdict you had is its own way of failing open.
"""

import argparse
import pathlib
import re
import sys

# The reference that owns the recap shape and the hand-off table.
RECAP_REL = pathlib.PurePosixPath("skills/_shared/recap.md")

# The graph the hand-offs are drawn in. Only the fence under this heading is read: ARCHITECTURE.md
# carries a second mermaid graph (external dependencies) whose dashed arrows mean "recommended
# dependency" — a different relation entirely, and one whose endpoints are MCP servers and CLI
# tools rather than skills.
ARCHITECTURE_REL = pathlib.PurePosixPath("ARCHITECTURE.md")
CALL_GRAPH_HEADING = "## Skill call graph"

# `skills/_shared/` holds shared references, not a skill — it has no SKILL.md and gets no row.
NOT_A_SKILL = {"_shared"}

# The header cells that identify the hand-off table among any other tables in the reference.
TABLE_HEADER = ("skill", "ends with", "next command")

# A backticked `/command` span in a Next-command cell. The leading `/` is what marks it as a command
# rather than an inline mention of a path or a flag, and the name stops at the first space so
# `/implement-issue #<issue>` and `/get-repo-profile --refresh` both resolve to their skill.
COMMAND_RE = re.compile(r"`\s*/([A-Za-z0-9][A-Za-z0-9._-]*)")

# The reference, as a skill's `## Recap` links it. Only the tail is pinned: `../_shared/recap.md`
# from a skill, `skills/_shared/recap.md` from the repo root, and a bare mention all satisfy it —
# what matters is that the skill points at the one home rather than restating the shape.
RECAP_LINK_RE = re.compile(r"_shared/recap\.md")

# A mermaid node declaration: `CI[create-issue]`, `SH["_shared/<br/>…"]`, `PROF[("repo-profile.md…")]`.
# Scanned with `finditer` ANYWHERE on a line, never anchored to a line of its own: mermaid also
# accepts `A[alpha] -. "next" .-> B[beta]`, and an anchored pattern resolved neither id, dropped the
# edge, and let a hand-off the table never declared pass unnoticed — the vacuous pass this whole
# script exists to make impossible.
NODE_RE = re.compile(r"([A-Za-z][A-Za-z0-9_]*)\[([^\[\]]+)\]")

# A mermaid comment. Commenting an edge out is the natural way to stage a graph edit, and reading
# one as live produced a refusal for an edge nobody draws.
COMMENT_PREFIX = "%%"

# A DOTTED mermaid link, in both spellings mermaid accepts: `A -.-> B` and `A -. "label" .-> B`.
# `-->` and `-- "label" -->` cannot match — the literal `-.` is what separates the two families.
# Either endpoint may carry its declaration inline (`A[alpha] -. "next" .-> B[beta]`), so the
# optional `[…]` suffix is part of the pattern rather than something the node scan alone can
# recover: without it the identifier is not adjacent to the arrow and the edge is dropped whole —
# a hand-off the table never declared then passes unnoticed.
NODE_SUFFIX = r"(?:\[[^\[\]]+\])?"
DASHED_EDGE_RE = re.compile(
    r"([A-Za-z][A-Za-z0-9_]*)" + NODE_SUFFIX + r"\s*-\.(?:[^\n]*?\.)?->\s*"
    r"([A-Za-z][A-Za-z0-9_]*)" + NODE_SUFFIX)

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
            # The first non-table line after the header ends the table — even with ZERO rows.
            # "Keep scanning until some rows turn up" silently absorbed the NEXT table in the file,
            # header row included, turning an empty hand-off table into a page of nonsense refusals
            # instead of the honest "no verdict" it is.
            if header_seen:
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
        found = commands_in(row["next"])
        if not found and not strip_code(row["next"]).startswith("—"):
            refusals.append(
                "REFUSE: %s's `%s` row names no `/command` and does not say `—` — an empty or "
                "prose-only cell is exactly the 'skill with no hand-off' that must not look like a "
                "skill that has none" % (RECAP_REL, name))
        for command in found:
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


def parse_handoff_edges(path, known_skills):
    """The `(from-skill, to-skill)` pairs the call graph draws as DASHED edges.

    Node ids are resolved through the `id[label]` declarations in the same fence, and an edge whose
    endpoints do not BOTH resolve to a skill is dropped: `AW`, `M`, `PROF` and `SH` are real nodes
    in that graph and none of them is a skill with a recap to hand off from.
    """
    text = read_text(path)
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(CALL_GRAPH_HEADING):
            start = i
            break
    if start is None:
        raise PlumbingError("%s has no '%s' section" % (path, CALL_GRAPH_HEADING))
    fence = None
    for i in range(start + 1, len(lines)):
        if lines[i].strip().startswith("```mermaid"):
            fence = i
            break
        if lines[i].startswith("## "):
            break
    if fence is None:
        raise PlumbingError("%s's '%s' section carries no ```mermaid fence"
                            % (path, CALL_GRAPH_HEADING))
    body = []
    for line in lines[fence + 1:]:
        if line.strip().startswith("```"):
            break
        body.append(line)

    body = [line for line in body if not line.lstrip().startswith(COMMENT_PREFIX)]

    node_skill = {}
    for line in body:
        for node_id, raw in NODE_RE.findall(line):
            label = raw.strip().strip("()").strip('"').split("<br")[0].strip()
            if label in known_skills:
                node_skill[node_id] = label

    edges = set()
    for line in body:
        for src, dst in DASHED_EDGE_RE.findall(line):
            if src in node_skill and dst in node_skill:
                edges.add((node_skill[src], node_skill[dst]))
    return edges


def declared_edges(repo, rows):
    """The `(from-skill, to-skill)` pairs the hand-off table declares."""
    edges = set()
    for row in rows:
        for command in commands_in(row["next"]):
            target = resolve_command(repo, command)
            if target is not None:
                edges.add((row["skill"], target))
    return edges


def check_architecture_agrees(repo, rows):
    """Assertion 3 — the graph and the table describe the same hand-off chain."""
    known = set(skill_dirs(repo))
    drawn = parse_handoff_edges(repo / ARCHITECTURE_REL, known)
    declared = declared_edges(repo, rows)
    refusals = []
    for src, dst in sorted(declared - drawn):
        refusals.append(
            "REFUSE: %s hands `%s` off to `%s`, but %s draws no dashed edge for it — add "
            "`<%s> -. \"next step\" .-> <%s>` to the skill call graph"
            % (RECAP_REL, src, dst, ARCHITECTURE_REL, src, dst))
    for src, dst in sorted(drawn - declared):
        refusals.append(
            "REFUSE: %s draws a dashed `%s` -> `%s` hand-off that %s declares no row for — make it "
            "a solid edge if it is an invocation, or give the table the row"
            % (ARCHITECTURE_REL, src, dst, RECAP_REL))
    return refusals


def check_skills_link(repo, rows):
    """Assertion 2 — every skill points at the shared reference instead of restating it."""
    refusals = []
    for name in skill_dirs(repo):
        skill_md = repo / "skills" / name / "SKILL.md"
        if not RECAP_LINK_RE.search(read_text(skill_md)):
            refusals.append(
                "REFUSE: skills/%s/SKILL.md never links %s — close it with a `## Recap` section "
                "that points at the shared shape rather than inventing one" % (name, RECAP_REL))
    return refusals


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--repo", default=str(pathlib.Path(__file__).resolve().parent.parent),
        help="repository root to check (default: the repo this script ships in)")
    args = parser.parse_args(argv)
    repo = pathlib.Path(args.repo).resolve()

    refusals = []
    try:
        rows = parse_handoff_table(repo / RECAP_REL)
        refusals += check_table_resolves(repo, rows)
        refusals += check_skills_link(repo, rows)
        refusals += check_architecture_agrees(repo, rows)
    except PlumbingError as exc:
        # Print what WAS decided before saying what could not be. A run that reached a real refusal
        # and then hit a missing ARCHITECTURE.md used to report only "no verdict", hiding the
        # verdict it already held.
        for line in refusals:
            print(line)
        print("ERR: %s" % exc)
        return 2

    if refusals:
        for line in refusals:
            print(line)
        return 1
    print("OK: %d skills, one hand-off row each, every next command resolves, "
          "every skill links the reference, ARCHITECTURE.md's dashed edges agree" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
