#!/usr/bin/env python3
"""pinned-literals-check.py — every spelling of a pinned package version is marked, or recorded.

Why this exists (#90). `XUNIT_V3_VERSION` in `tests/xunit-v3/apply-transform.py` is the constant
Renovate bumps (#36). The same literal is spelled in a dozen further lines, and #69 covered two
files of them with a sweep (`tests/xunit-v3/test.sh` `[7e]`) while saying, in its own commit, that
the rest needed a policy rather than a wider regex. This is that policy.

THE ASYMMETRY IS THE DESIGN. The remaining copies are not all the same kind of thing:

  * some are DERIVED facts — a claim about the pinned package, which must equal the constant;
  * some are deliberate RECORD — the `xunit.v3.mtp-v2` stable-release enumerations exist precisely
    to show that the MAJOR DOES NOT DETERMINE the Microsoft.Testing.Platform line, which is what
    `MTP_LINE` encodes. Rewriting them into agreement destroys that distinction;
  * and one is an INPUT: the scratch `.csproj` the transform test feeds the transform. Derive it
    from the constant and the test starts asserting against a value it generated itself, so it
    stops detecting the very drift it exists to catch.

So a repo-wide sweep that "fixes" every literal is not merely incomplete, it is wrong. What is
missing — `renovate.json` says so in its own words, "the same invariant is encoded in three other
places with no shared identifier" — is the identifier. This script is its consumer:

    a line carrying the marker `pinned:<pin>`  -> must state the constant, else REFUSE at file:line
    a line matched by a HISTORICAL entry       -> ignored; the entry carries the reason
    any other line spelling the version        -> REFUSE: "mark it, or record it as historical"

The default is therefore LOUD. An exclusion list — enumerate what to skip rather than what to
track — was the other option, and it inverts exactly that default: the next copy to appear is not
on the skip list, so it gets quietly swept into agreement. A wrong edit, not a refusal.

WHY MARKING IS NOT CIRCULAR. The scan has two entry points, and only one of them is the version
literal. Marked lines are found BY THEIR MARKER and then required to state the current version, so
the day Renovate bumps the pin every marked line still spelling the old one is refused by
file:line. That is the drift this exists to catch; the literal-scan half is what stops a NEW copy
from appearing unnoticed in the meantime.

WHAT THE REFUSAL DOES NOT SAY. It never says "edit the number". These are MEASUREMENTS — resolved
through api.nuget.org/v3-flatcontainer — and substituting whatever Renovate last bumped to would
manufacture a measurement nobody took, which is worse than a stale one because it looks current.
`[7e]` made that argument first and this repeats it verbatim.

The full classification, with a reason per historical entry, is in tests/pinned-literals/README.md.

Usage:
  pinned-literals-check.py [--repo <path>]

Exit codes:
  0  every spelling of every pin is accounted for
  1  REFUSE — an unmarked, unrecorded copy; a marked line that disagrees with the constant; a
     HISTORICAL entry that no longer matches anything; or nothing to verify at all
  2  usage / plumbing error — the pin's source, the repo or the file list could not be read, so no
     verdict is possible. NOT a pass: reporting "all accounted for" over an empty set is the #45
     failure exactly.
"""

import argparse
import os
import pathlib
import re
import subprocess
import sys
from collections import namedtuple

# --------------------------------------------------------------------------------------- the pins
#
# One entry per pinned version. A second pin — COVERAGE_EXT_VERSION is the obvious next one — is a
# row here, not a redesign; #90 deliberately scoped this pass to xunit.v3, the leg Renovate bumps
# most visibly.
#
#   source        the module that DEFINES the constant. Its own definition line is skipped: it is
#                 what every other spelling is compared against, not a copy of it.
#   marker        the token that means "this line states the pinned version".
Pin = namedtuple("Pin", "name source package_const version_const marker")

PINS = (
    Pin(
        name="xunit-v3",
        source="tests/xunit-v3/apply-transform.py",
        package_const="XUNIT_V3_PACKAGE",
        version_const="XUNIT_V3_VERSION",
        marker="pinned:xunit-v3",
    ),
)

# ------------------------------------------------------------------------- the historical record
#
# Occurrences that must NOT track the constant. Each entry names the file, a plain substring that
# identifies the ONE line it covers, and why that line is a record rather than a derived fact.
#
# An entry must match exactly one candidate line. Not "at least one": an over-broad anchor that
# happened to cover a second occurrence would silently re-create the exclusion-list failure this
# script was written to avoid, inside the script itself. And an entry matching NOTHING is refused
# too — a stale allowlist entry is a claim about the repo that is no longer true.
#
# ⚠️ The anchors deliberately contain no version literal. This file is excluded from the scan (it
# defines the marker), and an anchor spelling the pin would put a copy somewhere the scan cannot
# see it. `check_exclusions` enforces that rather than trusting it.
Recorded = namedtuple("Recorded", "pin path anchor reason")

HISTORICAL = (
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/apply-transform.py",
        anchor="-> xunit.v3.core.mtp-v2 ->",
        reason="the header table's xunit.v3.mtp-v2 row — the OTHER Microsoft.Testing.Platform "
               "line (MTP_LINE -> 2). Its version is a measurement of a different package.",
    ),
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/apply-transform.py",
        anchor="are STABLE releases",
        reason="the enumeration showing xunit.v3.mtp-v2's 3.2.x releases are stable — the "
               "evidence that the MAJOR does not pick the MTP line. Moving it destroys the point.",
    ),
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/apply-transform.py",
        anchor="'s nuspecs)",
        reason="a measurement of xunit.v3.core.mtp-v{1,2}'s nuspecs — it spans BOTH MTP lines, so "
               "the v2 leg is not this pin's to govern. Re-measure both legs when the pin moves.",
    ),
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/apply-transform.py",
        anchor="as the serving package",
        reason="an ILLUSTRATION of a wrong-answer message — a version string landing in the "
               "package-id slot. The point is the slot; which version it was does not matter.",
    ),
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/test.sh",
        anchor='<PackageReference Include="xunit.v3" Version=',
        reason="⚠️ the scratch .csproj fixture — an INPUT to the transform. Derive it from the "
               "constant and the test asserts against a value it generated itself, so it would "
               "stop detecting the drift it exists to catch.",
    ),
    Recorded(
        pin="xunit-v3",
        path="tests/xunit-v3/test.sh",
        anchor="a version-keyed map would invert",
        reason="section 7's xunit.v3.mtp-v2 half — the other MTP line, quoted to show that a "
               "version-keyed rule would invert every pair.",
    ),
    Recorded(
        pin="xunit-v3",
        path="skills/legacy-upgrade/references/xunit-v3-migration.md",
        anchor="| `xunit.v3.core.mtp-v2` |",
        reason="the measured-resolution table's xunit.v3.mtp-v2 row — the other MTP line.",
    ),
    Recorded(
        pin="xunit-v3",
        path="skills/legacy-upgrade/references/xunit-v3-migration.md",
        anchor="are **stable**, not prerelease",
        reason="the reference's copy of the stable-releases enumeration — same record as the "
               "module's, for the reader running a real migration.",
    ),
)

# ------------------------------------------------------------------------------------- exclusions
#
# Two paths define or exercise the convention, so they are allowed to spell the MARKER without
# being read as marked lines. They are NOT allowed to spell the pinned version — that would be a
# copy in the one place the scan cannot see, so check_exclusions() proves it rather than assuming.
EXCLUDED = (
    "scripts/pinned-literals-check.py",   # this file: it defines the marker and the anchors
    "tests/pinned-literals/",             # its golden test and the classification it documents
)


def die(msg, code=1):
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def read_const(source, name):
    """The value of `NAME = "…"` in a kit module.

    Parsed, never imported. Importing would EXECUTE the module this script audits and — without
    PYTHONDONTWRITEBYTECODE — drop a __pycache__ beside it, which tests/xunit-v3/test.sh section 8
    turns into a suite-wide failure naming a file the suite never touched. It also matches how the
    constant is ALREADY machine-read: renovate.json's customManager captures these very two lines
    with a regex, so anything that breaks this read has already broken Renovate's.
    """
    pattern = re.compile(r'^%s\s*=\s*"([^"]+)"\s*$' % re.escape(name), re.M)
    match = pattern.search(source)
    if match is None:
        return None
    return match.group(1)


def claim_patterns(package):
    """The two shapes in which this repo states "<package> <version>".

    Anchored on the package ID, never on the bare number: a pinned version is short and generic
    (three dotted digits), and a bare-number match would read an SDK version or a coverage version
    as a claim about the pin. The negative lookahead is what keeps `xunit.v3.mtp-v2` — a DIFFERENT
    package, on the opposite MTP line — from being mistaken for `xunit.v3`; that distinction is the
    whole subject of MTP_LINE.

    Note the division of labour with the literal scan in check_pin(): these patterns decide what a
    MARKED line is claiming, and the literal scan decides what still needs classifying. A copy in
    a shape neither pattern recognises is therefore not waved through — it is refused as unmarked.
    """
    pkg = re.escape(package)
    return (
        # Prose and markdown table cells. Backticks and asterisks between the id and the number are
        # markdown decoration, not separation — the shape [7e] settled on.
        re.compile(r"(?<![\w.-])" + pkg + r"(?![\w.-])[ \t`*]*(\d+\.\d+\.\d+)"),
        # A csproj PackageReference, where an attribute sits between the id and the version.
        re.compile(r'Include="' + pkg + r'"[^>]*?Version="(\d+\.\d+\.\d+)"'),
    )


def repo_files(repo):
    """Every text file to scan, git-first.

    `git ls-files` rather than a walk because a developer checkout has OTHER WORKING TREES inside
    it — the kit's own convention puts agent worktrees under `.claude/worktrees/` — and walking
    into one would report another branch's files as copies in this one. The walk is the fallback
    for the golden test's scratch fixtures, which are directories rather than repositories; it
    skips any directory carrying its own `.git`, for the same reason.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z"],
            capture_output=True, check=True,
        ).stdout
        names = [n for n in out.decode("utf-8", "replace").split("\0") if n]
        if names:
            return names
    except (OSError, subprocess.CalledProcessError):
        pass

    names = []
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [
            d for d in sorted(dirnames)
            if d not in (".git", "node_modules")
            and not (pathlib.Path(dirpath, d, ".git").exists() and pathlib.Path(dirpath) != repo)
        ]
        for name in sorted(filenames):
            names.append(str(pathlib.Path(dirpath, name).relative_to(repo)))
    return names


def read_lines(path):
    """The file's lines, or None when it is not utf-8 text (an image, a compiled fixture)."""
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        return None


def is_excluded(rel):
    return any(rel == e or rel.startswith(e) for e in EXCLUDED)


def check_exclusions(repo, files, pin, version, problems):
    """An excluded path may name the marker; it may not spell the pin.

    Without this the exclusions are a hole of exactly the shape this script closes: a copy living
    in the one place nothing looks. Checked here rather than argued for in a comment.
    """
    for rel in files:
        if not is_excluded(rel):
            continue
        lines = read_lines(repo / rel)
        if lines is None:
            continue
        for number, line in enumerate(lines, 1):
            if version in line:
                problems.append(
                    "%s:%d spells the pinned %s version, but this path is EXCLUDED from the scan\n"
                    "      (it defines or exercises the marker convention). A copy here is a copy\n"
                    "      nothing checks — move the claim into a scanned file, or stop spelling\n"
                    "      the version:\n"
                    "        %s" % (rel, number, pin.name, line.strip())
                )


def check_pin(repo, files, pin, problems):
    """Classify every line in the repo that carries the marker or spells the pin's version."""
    source_path = repo / pin.source
    source = read_lines(source_path)
    if source is None:
        die("pinned-literals-check: cannot read %s, which defines %s. No verdict is possible."
            % (pin.source, pin.version_const), 2)
    source_text = "\n".join(source)

    package = read_const(source_text, pin.package_const)
    version = read_const(source_text, pin.version_const)
    if not package or not version:
        die("pinned-literals-check: %s does not define %s / %s in the `NAME = \"value\"` shape "
            "this check (and renovate.json's customManager) reads. No verdict is possible."
            % (pin.source, pin.package_const, pin.version_const), 2)

    patterns = claim_patterns(package)
    # The constant's own definition is the source, not a copy of it.
    definition = re.compile(r'^%s\s*=' % re.escape(pin.version_const))

    entries = [h for h in HISTORICAL if h.pin == pin.name]
    hits = {id(h): [] for h in entries}
    marked = 0

    for rel in files:
        if is_excluded(rel):
            continue
        lines = read_lines(repo / rel)
        if lines is None:
            continue
        for number, line in enumerate(lines, 1):
            if rel == pin.source and definition.match(line):
                continue

            if pin.marker in line:
                marked += 1
                claims = set()
                for pattern in patterns:
                    claims.update(pattern.findall(line))
                if not claims:
                    problems.append(
                        "%s:%d carries the `%s` marker but states no `%s <version>` claim, so the\n"
                        "      marker verifies nothing. Put it on the line that carries the claim,\n"
                        "      or drop it:\n"
                        "        %s" % (rel, number, pin.marker, package, line.strip())
                    )
                    continue
                stale = sorted(c for c in claims if c != version)
                if stale:
                    problems.append(
                        "%s:%d is marked `%s` and states %s %s, but %s writes %s.\n"
                        "      Do NOT simply edit the number: these are MEASUREMENTS (resolved\n"
                        "      through api.nuget.org/v3-flatcontainer), and they carry the\n"
                        "      Microsoft.Testing.Platform version and CodeCoverage major that a\n"
                        "      migration actually depends on. Re-measure how %s %s resolves, then\n"
                        "      update every claim this names:\n"
                        "        %s"
                        % (rel, number, pin.marker, package, ", ".join(stale), pin.source, version,
                           package, version, line.strip())
                    )
                continue

            if version not in line:
                continue

            entry = next((h for h in entries if h.path == rel and h.anchor in line), None)
            if entry is not None:
                hits[id(entry)].append(number)
                continue

            problems.append(
                "%s:%d spells the pinned %s version and is neither marked nor recorded:\n"
                "        %s\n"
                "      If it is a DERIVED fact about %s, mark the line `%s` — the check will then\n"
                "      hold it to %s in %s.\n"
                "      If it is a RECORD that must NOT move (a claim about another package or MTP\n"
                "      line, or an INPUT a test feeds itself), add it to HISTORICAL in\n"
                "      scripts/pinned-literals-check.py with the reason. See\n"
                "      tests/pinned-literals/README.md."
                % (rel, number, pin.name, line.strip(), package, pin.marker,
                   pin.version_const, pin.source)
            )

    for entry in entries:
        found = hits[id(entry)]
        if not found:
            problems.append(
                "the HISTORICAL entry for %s (anchor %r) matches nothing any more.\n"
                "      A recorded occurrence that no longer exists is a claim about this repo that\n"
                "      is no longer true — re-point the anchor, or delete the entry.\n"
                "      Its reason was: %s" % (entry.path, entry.anchor, entry.reason)
            )
        elif len(found) > 1:
            problems.append(
                "the HISTORICAL entry for %s (anchor %r) covers %d lines (%s).\n"
                "      Each entry records ONE occurrence with ONE reason; an anchor this broad\n"
                "      would swallow the next copy silently — the exclusion-list failure this\n"
                "      check exists to avoid. Narrow it, and add an entry per occurrence."
                % (entry.path, entry.anchor, len(found),
                   ", ".join(str(n) for n in found))
            )

    if marked == 0:
        problems.append(
            "not one line carries the `%s` marker, so this check verified NOTHING.\n"
            "      Reporting 'all accounted for' over an empty set is the failure mode the kit's\n"
            "      other guards were written for; refusing instead."
            % pin.marker
        )

    return package, version, marked, sum(len(v) for v in hits.values())


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    args = ap.parse_args()

    repo = pathlib.Path(args.repo).resolve()
    if not repo.is_dir():
        die("pinned-literals-check: %s is not a directory." % repo, 2)
    files = repo_files(repo)
    if not files:
        die("pinned-literals-check: no files under %s — refusing to report 'all accounted for' "
            "over an empty set." % repo, 2)

    problems = []
    summary = []
    for pin in PINS:
        package, version, marked, recorded = check_pin(repo, files, pin, problems)
        check_exclusions(repo, files, pin, version, problems)
        summary.append("%s %s — %d marked spelling(s), %d recorded as historical"
                       % (package, version, marked, recorded))

    if problems:
        print("pinned-literals-check: REFUSED")
        for problem in problems:
            print("  %s" % problem)
            print()
        return 1

    for line in summary:
        print("pinned-literals-check: %s." % line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
