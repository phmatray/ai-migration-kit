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
# One entry per pinned literal. Two KINDS (#158):
#
#   DERIVED (the default) — a constant somewhere in the repo IS the authority. A marked line must
#                            state what that constant currently holds; that is what "pinned" meant
#                            before #158, and every existing pin stays exactly this shape.
#   AGREED                 — there is no authority. Some literals have no constant to derive from
#                            (a frozen fixture's test-stack versions, restated nowhere but in prose
#                            and scratch fixtures) — an AGREED pin instead collects every MARKED
#                            occurrence and refuses unless they all agree with EACH OTHER. Fewer
#                            than two is refused too: an agreement of one is vacuous, indistinguishable
#                            from a lone, uncorroborated typo.
#
#   name            identifies the pin; keys HISTORICAL entries and refusal messages.
#   marker          the token that means "this line states the pin". Required for both kinds.
#   kind            "DERIVED" (default) or "AGREED".
#   source          DERIVED only: the module that DEFINES the constant. Its own definition line is
#                   skipped: it is what every other spelling is compared against, not a copy of it.
#   package_const / version_const
#                   DERIVED only: the `NAME = "value"` constants `source` defines.
#   package         AGREED only: the literal package id claim_patterns() anchors on — there is no
#                   module to read it from, since there is no authority.
Pin = namedtuple(
    "Pin", "name marker kind source package_const version_const package"
)
Pin.__new__.__defaults__ = ("DERIVED", None, None, None, None)  # kind, source, package_const,
                                                                  # version_const, package

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

    Two definitions are refused rather than resolved. A plain `search` would silently take the
    first, so a module that grew a second definition would have this check comparing the whole repo
    against a value nobody meant. Renovate reads these lines with a regex too and has the same
    blind spot; here it is at least loud.
    """
    pattern = re.compile(r'^%s\s*=\s*"([^"]+)"\s*$' % re.escape(name), re.M)
    found = pattern.findall(source)
    if not found:
        return None
    if len(found) > 1:
        die("pinned-literals-check: %s is defined more than once (%s). One home per constant — "
            "there is no way to tell which one the repo is meant to agree with."
            % (name, ", ".join(found)), 2)
    return found[0]


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


def line_claims(line, next_line, patterns):
    """The claims physical line `line` states — including one that WRAPS onto `next_line`.

    Why this exists (#158). `claim_patterns()` matches within a single physical line, but a claim
    can be typeset across two: the package id ending one line with no trailing separator, the
    version opening the next — `tests/xunit-v3/test.sh:237` had exactly this shape and had to be
    hand-rewrapped to become checkable at all. Joining `line` and `next_line` with a single space
    (standing in for the line break) lets the same patterns see it without changing what they match.

    Returns `(claims, consumed)`. `claims` is every captured version, from `line` alone and from a
    genuine wrap. `consumed` is how many of `next_line`'s LEADING characters a wrap match ate, so the
    caller can exclude that span when it scans `next_line` on its own in the next loop iteration —
    without that, the very same wrapped claim would be reported twice: once here, correctly
    attributed to `line`, and once more at `next_line`, attributed to the wrong physical line.

    A match in the joined text counts as THIS line's claim only when it STARTS inside `line`'s own
    text (the package id begins here) AND reaches past it into `next_line` (`m.end() > len(line)`).
    Without the second half of that test, a match that merely starts on `line` and ends there too
    (an ordinary same-line claim the plain scan of `line` already finds) would be treated as
    "consuming" a next_line that its match never touched. Without the first half, a claim that
    starts and lies entirely within `next_line` — a real, independent claim, not a wrap — would be
    misattributed to `line`; it is left alone here and picked up when `next_line` is scanned as its
    own line on the next iteration. That distinction is what section 12 of the golden test proves:
    a marker on line N must not silently launder an unrelated claim that merely happens to sit on
    line N+1.
    """
    claims = set(m for pattern in patterns for m in pattern.findall(line))
    consumed = 0
    if next_line is not None:
        joined = line + " " + next_line
        for pattern in patterns:
            for m in pattern.finditer(joined):
                if m.start() < len(line) < m.end():
                    claims.add(m.group(1))
                    consumed = max(consumed, m.end() - (len(line) + 1))
    return claims, consumed


def repo_files(repo):
    """Every text file to scan, git-first.

    `git ls-files` rather than a walk because a developer checkout has OTHER WORKING TREES inside
    it — the kit's own convention puts agent worktrees under `.claude/worktrees/` — and walking
    into one would report another branch's files as copies in this one.

    `--others --exclude-standard` puts UNTRACKED-but-not-ignored files in scope too, so a local run
    gives the verdict CI will give once the file is added. Without it a contributor writing a new
    document that copies the pin passes locally and is refused by CI, which is the wrong order to
    learn it in — and this repo's profile names the local suite run as THE fast path. Ignored paths
    stay out, which is what keeps `.claude/worktrees/` (and every build artefact) from being read.

    The walk is the fallback for the golden test's scratch fixtures, which are directories rather
    than repositories, and for a host with no usable `git` at all. It skips any directory carrying
    its own `.git` — at EVERY level, including directly under the root, which is exactly where the
    agent worktrees sit. An earlier draft exempted the root's own children from that test and so
    would have walked straight into them the moment the git path failed.
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
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
            and not pathlib.Path(dirpath, d, ".git").exists()
        ]
        for name in sorted(filenames):
            names.append(str(pathlib.Path(dirpath, name).relative_to(repo)))
    return names


def read_lines(path):
    """The file's lines, or None when there is legitimately nothing to read.

    Only two absences are legitimate: a file that is not utf-8 text (an image, a compiled fixture)
    and a path git lists but the working tree no longer has (a staged deletion, a dangling
    symlink). Every OTHER OSError — unreadable, a device, a permissions problem — is a plumbing
    error and exits 2. A blanket `except OSError: return None` would instead skip the file in
    silence, which is a guard quietly covering less than it claims: the failure this whole script
    exists to make loud.
    """
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        return None
    except OSError as exc:
        die("pinned-literals-check: cannot read %s (%s). Refusing to skip a file in silence — "
            "no verdict is possible about a file that was never read." % (path, exc), 2)


def is_excluded(rel):
    """Exact path, or anything under an excluded DIRECTORY (an entry ending in '/').

    A bare `startswith` on a file entry would also exclude `…-check.py.bak` or `…-check.py2` —
    prefix matching on a name is not the same question as "is this that file", and the direction
    it errs in is the one that hides a copy.
    """
    return any(rel == e or (e.endswith("/") and rel.startswith(e)) for e in EXCLUDED)


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
    """Dispatch to the scan `pin.kind` needs — DERIVED (a constant is the authority) or AGREED (no
    authority; every marked occurrence must agree with every other). Kept as one entry point so
    main()'s loop stays kind-agnostic; the two scans differ enough in what they need (a source
    module vs. none at all) that folding them into one function would read as one function doing
    two things, which is the failure #158's Task 2 spec names AGREED to avoid repeating.
    """
    if pin.kind == "AGREED":
        return check_pin_agreed(repo, files, pin, problems)
    return check_pin_derived(repo, files, pin, problems)


def check_pin_agreed(repo, files, pin, problems):
    """AGREED: no constant is the authority. Collect every MARKED occurrence's claim(s) and refuse
    unless they all agree with EACH OTHER — naming every differing value when they don't, and
    refusing a lone occurrence as vacuous (nothing corroborates a single restatement; a typo there
    would be indistinguishable from a correct value).

    Unlike DERIVED, there is no literal-scan half: with no authority there is no "the version" to
    hunt unmarked spellings of, so an AGREED pin sees only what is explicitly marked. That is a
    real, narrower guarantee than DERIVED's — worth stating plainly rather than leaving implicit,
    since a reader used to DERIVED's "any spelling is judged" behaviour would otherwise assume the
    same holds here.
    """
    patterns = claim_patterns(pin.package)
    occurrences = []  # [(rel, number, claim)], in scan order

    for rel in files:
        if is_excluded(rel):
            continue
        lines = read_lines(repo / rel)
        if lines is None:
            continue
        # A claim can still wrap across two physical lines here (#158 Task 1's line_claims), but
        # unlike check_pin_derived's literal-scan half there is no unmarked-line re-scan to protect
        # from double-counting: AGREED only ever looks at a line THAT CARRIES THE MARKER, so no
        # bookkeeping is needed to exclude a span "already claimed" by a neighbour — each marked
        # line's own line_claims() call is independent of every other.
        for number, line in enumerate(lines, 1):
            if pin.marker not in line:
                continue
            next_line = lines[number] if number < len(lines) else None
            claims, _consumed = line_claims(line, next_line, patterns)
            if not claims:
                problems.append(
                    "%s:%d carries the `%s` marker but states no `%s <version>` claim, so the\n"
                    "      marker verifies nothing. Put it on the line that carries the claim,\n"
                    "      or drop it:\n"
                    "        %s" % (rel, number, pin.marker, pin.package, line.strip())
                )
                continue
            for claim in sorted(claims):
                occurrences.append((rel, number, claim))

    if len(occurrences) < 2:
        if occurrences:
            rel, number, claim = occurrences[0]
            problems.append(
                "the AGREED pin `%s` (package %s) has exactly ONE marked occurrence — %s:%d states\n"
                "      %s %s. An agreement of one is vacuous: nothing corroborates it, so a lone\n"
                "      typo would be indistinguishable from a correct value. Mark a second\n"
                "      restatement, or drop the pin."
                % (pin.name, pin.package, rel, number, pin.package, claim)
            )
        else:
            problems.append(
                "not one line carries the `%s` marker, so the AGREED pin `%s` verified NOTHING.\n"
                "      Reporting 'all accounted for' over an empty set is the failure mode the\n"
                "      kit's other guards were written for; refusing instead."
                % (pin.marker, pin.name)
            )
        return pin.package, None, len(occurrences), 0

    values = sorted(set(claim for _, _, claim in occurrences))
    if len(values) > 1:
        named = "\n".join(
            "        %s:%d states %s" % (rel, number, claim) for rel, number, claim in occurrences
        )
        problems.append(
            "the AGREED pin `%s` (package %s) has occurrences that disagree — there is no\n"
            "      constant here to say which is right, so EVERY value seen is suspect until they\n"
            "      agree:\n%s" % (pin.name, pin.package, named)
        )
        return pin.package, None, len(occurrences), 0

    return pin.package, values[0], len(occurrences), 0


def check_pin_derived(repo, files, pin, problems):
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
    # Keyed by identity, not by value: two entries could legitimately carry the same path and
    # anchor (a copy-paste in the table), and a value key would silently merge their hit counts —
    # hiding exactly the duplicate the "exactly one line" rule below is meant to surface.
    hits = {id(h): [] for h in entries}
    marked = 0

    for rel in files:
        if is_excluded(rel):
            continue
        lines = read_lines(repo / rel)
        if lines is None:
            continue
        # Chars at the START of the CURRENT line already attributed to a wrap match ending on the
        # PREVIOUS line — set at the bottom of the loop body, consumed (and reset to 0) at the top
        # of the next iteration. Without excluding this span, a claim that wraps across two lines
        # would be reported twice: once at the line it starts on (correct), and again here, at the
        # line its tail happens to sit on (wrong — see line_claims()'s docstring).
        consumed_from_prev = 0
        for number, line in enumerate(lines, 1):
            this_consumed, consumed_from_prev = consumed_from_prev, 0
            next_line = lines[number] if number < len(lines) else None

            if rel == pin.source and definition.match(line):
                continue

            if pin.marker in line:
                marked += 1
                claims, consumed_from_prev = line_claims(line, next_line, patterns)
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

            # The literal scan: unlike the marked branch above, this does not require the package
            # id at all — any spelling of the bare version is a claim that needs classifying. A
            # wrap is therefore detected differently here: `line` on its own (minus a span already
            # claimed by the PREVIOUS line's wrap) may simply not contain the version literal at
            # all, because the version itself lives entirely on `next_line`. `line_claims()` still
            # answers that: if a wrap match's captured version equals the pin's `version` and it is
            # not also found by the direct substring test below, the only way it could be in
            # `claims` is via the wrap (a same-line match would already have made `direct_hit` true,
            # since the version text is necessarily present in `line` for the pattern to have
            # matched it there).
            direct_hit = version in line[this_consumed:]
            wrap_hit = False
            if not direct_hit:
                claims, consumed = line_claims(line, next_line, patterns)
                wrap_hit = consumed > 0 and version in claims
                if wrap_hit:
                    consumed_from_prev = consumed
            if not direct_hit and not wrap_hit:
                continue

            # The line printed in a refusal: `line` alone for a direct hit, but `line` joined with
            # `next_line` for a wrap — printing `line` alone there would show the package id and
            # nothing else, since the version this refusal is ABOUT lives on the next physical line.
            shown = line if direct_hit else line + " " + next_line

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
                % (rel, number, pin.name, shown.strip(), package, pin.marker,
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
        # `version` is None only when check_pin_agreed already refused (vacuous or disagreeing) —
        # there is then no single value left to check excluded paths against, and the refusal
        # already above says so. check_exclusions() would otherwise have nothing meaningful to
        # compare and nothing to add.
        if version is not None:
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
