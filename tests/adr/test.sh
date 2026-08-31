#!/usr/bin/env bash
# Golden test for tests/adr/check-adrs.py — the structural CI mirror of AdrMcp's `validate_adr`.
#
# Why a golden test for a checker (#316). The checker exists because CI cannot start the MCP
# server, so nothing else in this repository ever exercises those rules. A mirror whose refusal
# paths are untested is the failure it was written to prevent, one level up: it would pass on a
# clean tree, pass on a broken one, and nobody would learn the difference until an ADR set had
# already gone stale. So every rule below is asserted by BREAKING a valid ADR set in exactly ONE
# way and requiring the named marker to fire — never by reading the checker and believing it.
#
# What this suite guards:
#   1.  the fixture set, untouched                      -> accept
#   2.  two ADRs claiming the same id                   -> REFUSE  (duplicate id)
#   3.  a status outside the wire vocabulary            -> REFUSE  (unknown status)
#   4.  a filename that is not {id:04d}-{kebab(title)}  -> REFUSE  (filename does not match)
#   5.  a links[].target naming no ADR in the root      -> REFUSE  (dangling link)
#   6.  `superseded` with no `superseded-by` link       -> REFUSE  (superseded without superseded-by)
#   7.  an id absent from the rendered README index     -> REFUSE  (missing from README index)
#   8.  a body missing one of the three MADR sections   -> REFUSE  (missing required section)
#   9.  a missing README.md                             -> REFUSE  (missing README index)
#  10.  a root that does not exist / holds no ADRs      -> REFUSE  (never a vacuous pass)
#  11.  TWO defects at once                             -> BOTH reported, not just the first
#  12.  the seven titles docs/adr will carry            -> accept, at the exact filenames the
#                                                         rendered index links to
#
# Case 11 is the one that is easy to lose: a checker that stops at the first failure turns a review
# of an ADR set into N round trips, and this suite is the only thing that says it must not.
#
# Case 12 pins the kebab derivation against the REAL titles rather than against the fixtures'
# convenient ones — colons, semicolons, commas and a trailing `-p` all land in that set, and each
# one is a place where a slug rule can silently disagree with the filename on disk.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT="$PWD"
CHECK="$KIT/tests/adr/check-adrs.py"
FIXTURES="$KIT/tests/adr/fixtures"

[ -r "$CHECK" ] || { echo "FAIL: $CHECK missing — the suite has nothing to drive"; exit 1; }

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# kit_guard_samples_unchanged NOT registered, deliberately: this suite never reads or writes
# samples/ — it copies tests/adr/fixtures/ into scratch and mutates only there. Said explicitly so
# "decided it does not apply" cannot be mistaken for "forgot to call it" (tests/_lib.sh).
OUT="$(kit_scratch)/out.txt"

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A fresh copy of the valid fixture set, in its own scratch directory. Every case mutates its OWN
# copy, so a case can never inherit the previous one's damage.
fixture_root() {
  local d
  d="$(kit_scratch)/adr"
  mkdir -p "$d"
  cp "$FIXTURES"/*.md "$d/"
  printf '%s\n' "$d"
}

accept() {   # accept <root> <label>
  if python3 "$CHECK" "$1" > "$OUT" 2>&1; then
    ok "$2"
  else
    bad "$2 — expected exit 0, got $?; output:"
    sed 's/^/          /' "$OUT"
  fi
}

# refuse <root> <marker> <label>: exit 1 AND the named marker present. Both halves matter — an
# exit code alone would pass on a checker that refused for an unrelated reason, which is exactly
# how a rule stops being tested without any case going red.
refuse() {
  local root="$1" marker="$2" label="$3" rc=0
  python3 "$CHECK" "$root" > "$OUT" 2>&1 || rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "$label — expected exit 1 (refusal), got $rc; output:"
    sed 's/^/          /' "$OUT"
    return
  fi
  if grep -qF "$marker" "$OUT"; then
    ok "$label"
  else
    bad "$label — refused, but no line carried the marker \"$marker\"; output:"
    sed 's/^/          /' "$OUT"
  fi
}

# ---------------------------------------------------------------- 1. the fixture set is valid

root=$(fixture_root)
accept "$root" "baseline — the untouched fixture set is accepted"

# ---------------------------------------------------------------- 2. duplicate id
#
# A FOURTH file rather than an edit of an existing one: re-numbering an ADR in place would also
# break its filename and orphan a link, and three markers firing at once would not prove which
# rule saw the duplicate.
root=$(fixture_root)
cat > "$root/0001-another-decision.md" <<'ADR'
---
id: 1
title: Another decision
status: accepted
date: 2026-08-31
tags:
  - example
---

# Another decision

## Context and Problem Statement

Claims an id that ADR-0001 already holds.

## Decision Outcome

Nothing; this file exists to be refused.

## Consequences

The run goes red.
ADR
refuse "$root" "duplicate id" "duplicate-id — two ADRs claiming id 1 are refused"

# ---------------------------------------------------------------- 3. unknown status

root=$(fixture_root)
sed 's/^status: accepted$/status: approved/' "$root/0001-an-example-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0001-an-example-decision.md"
refuse "$root" "unknown status" "unknown-status — 'approved' is not in the wire vocabulary"

# ---------------------------------------------------------------- 4. filename slug drift
#
# The file is RENAMED, the frontmatter left alone: this is what a hand-typed filename, or a title
# edited without renaming the file, actually looks like.
root=$(fixture_root)
mv "$root/0001-an-example-decision.md" "$root/0001-an-exemple-decision.md"
refuse "$root" "filename does not match" "filename-slug — the slug must be the kebab-case of the title"

# ---------------------------------------------------------------- 5. dangling link

root=$(fixture_root)
sed 's/^    target: 2$/    target: 99/' "$root/0003-the-replacement-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0003-the-replacement-decision.md"
refuse "$root" "dangling link" "dangling-link — a target naming no ADR in the root is refused"

# ---------------------------------------------------------------- 6. superseded without the link
#
# The link is RETYPED rather than deleted, so the ADR still has a resolvable target and rule 5
# stays quiet: only rule 6 can be what fires here.
root=$(fixture_root)
sed 's/^  - type: superseded-by$/  - type: relates-to/' "$root/0002-a-superseded-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0002-a-superseded-decision.md"
refuse "$root" "superseded without superseded-by" "superseded-link — a superseded ADR must say what superseded it"

# ---------------------------------------------------------------- 7. stale README index

root=$(fixture_root)
grep -v '0003' "$root/README.md" > "$root/tmp"
mv "$root/tmp" "$root/README.md"
refuse "$root" "missing from README index" "readme-stale — an ADR the index never mentions is refused"

# ---------------------------------------------------------------- 8. a missing MADR section

root=$(fixture_root)
grep -v '^## Consequences$' "$root/0001-an-example-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0001-an-example-decision.md"
refuse "$root" "missing required section" "madr-sections — the three required sections are mirrored from validate_adr"

# ---------------------------------------------------------------- 9. no README at all

root=$(fixture_root)
rm "$root/README.md"
refuse "$root" "missing README index" "readme-absent — a missing index is itself a failure"

# ---------------------------------------------------------------- 10. nothing to check
#
# Both spellings of "no verdict is possible", because the dangerous outcome for a checker with
# nothing to read is a PASS: a wrong --root argument, or a directory the ADRs never landed in,
# would otherwise report a clean set forever.
missing="$(kit_scratch)/not-here"
refuse "$missing" "does not exist" "absent-root — a root that is not there is refused, never passed"

empty="$(kit_scratch)/empty"
mkdir -p "$empty"
refuse "$empty" "no ADR files" "empty-root — a root with no ADRs is refused, never passed vacuously"

# ---------------------------------------------------------------- 11. every failure at once
#
# TWO unrelated defects, in two different files. A checker that exits at the first one reports
# half the work and sends the reader back for a second round; this is the case that says no.
root=$(fixture_root)
sed 's/^status: accepted$/status: approved/' "$root/0001-an-example-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0001-an-example-decision.md"
sed 's/^    target: 2$/    target: 99/' "$root/0003-the-replacement-decision.md" > "$root/tmp"
mv "$root/tmp" "$root/0003-the-replacement-decision.md"
rc=0
python3 "$CHECK" "$root" > "$OUT" 2>&1 || rc=$?
if [ "$rc" -ne 1 ]; then
  bad "all-failures — expected exit 1, got $rc"
elif grep -qF "unknown status" "$OUT" && grep -qF "dangling link" "$OUT"; then
  ok "all-failures — both defects are reported in one run, not just the first"
else
  bad "all-failures — only one of the two defects was reported; output:"
  sed 's/^/          /' "$OUT"
fi

# ---------------------------------------------------------------- 12. the real titles
#
# The kebab rule has to agree with the filenames docs/adr actually carries. These are those seven
# titles, verbatim; if the derivation drifts, case 4's marker fires here instead of on a contrived
# fixture. Titles are QUOTED in the frontmatter: `title: Squash-only merges: the PR title …` is not
# valid YAML — a colon-space inside a plain scalar is a mapping, not text.
seven="$(kit_scratch)/seven"
mkdir -p "$seven"
printf '# Architecture Decision Records\n\n' > "$seven/README.md"
while IFS='|' read -r sid stitle sname; do
  [ -n "$sid" ] || continue
  cat > "$seven/$sname" <<ADR
---
id: $sid
title: "$stitle"
status: accepted
date: 2026-08-31
tags:
  - kit
---

# $stitle

## Context and Problem Statement

Pinned by tests/adr/test.sh case 12.

## Decision Outcome

Pinned by tests/adr/test.sh case 12.

## Consequences

Pinned by tests/adr/test.sh case 12.
ADR
  printf '| [%04d](%s) | %s |\n' "$sid" "$sname" "$stitle" >> "$seven/README.md"
done <<'ROWS'
1|The repo profile is committed data, not a skill|0001-the-repo-profile-is-committed-data-not-a-skill.md
2|The roseline gate fails open, always|0002-the-roseline-gate-fails-open-always.md
3|One plugin version; no per-skill version|0003-one-plugin-version-no-per-skill-version.md
4|Squash-only merges: the PR title is the release commit|0004-squash-only-merges-the-pr-title-is-the-release-commit.md
5|The lifecycle skills run hands-off; triage-backlog does not|0005-the-lifecycle-skills-run-hands-off-triage-backlog-does-not.md
6|The kit targets Claude Code only|0006-the-kit-targets-claude-code-only.md
7|Workers are in-process sub-agents, never claude -p|0007-workers-are-in-process-sub-agents-never-claude-p.md
ROWS
accept "$seven" "real-titles — the kebab rule produces the seven filenames docs/adr will carry"

# ---------------------------------------------------------------- verdict

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %d case(s) failed\n' "$fails"
  exit 1
fi
echo "OK tests/adr — check-adrs.py accepts a valid set and refuses every rule it mirrors"
